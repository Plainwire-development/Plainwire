-module(pw_http_fetch).
-export([get/2, get/3, get_pinned/4]).
-ifdef(TEST).
-export([test_normalize_extra_headers/1]).
-endif.

get(Url, MaxBytes) -> get(Url, MaxBytes, #{}).

%% Fetch a URL while connecting to an address that the caller already resolved
%% and policy-checked. This closes the DNS-rebinding gap between URL validation
%% and connect(2) while still verifying HTTPS against the original hostname.
get_pinned(Url, Address, MaxBytes, Opts) when is_binary(Url), is_tuple(Address),
                                             is_integer(MaxBytes), MaxBytes > 0, is_map(Opts) ->
    Truncate = maps:get(truncate, Opts, false) =:= true,
    case pw_outbound_url:public_ip(Address) of
        false -> {error, blocked_address};
        true ->
            case pinned_target(Url) of
                {ok, Target} -> pinned_request(Target#{address => Address}, MaxBytes, Truncate, Opts);
                Error -> Error
            end
    end.

pinned_target(Url) ->
    try uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Parts ->
            Scheme = string:lowercase(pw_util:bin(Scheme0)),
            Host = string:lowercase(pw_util:bin(Host0)),
            case (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>) andalso Host =/= <<>> of
                false -> {error, invalid_url};
                true ->
                    DefaultPort = case Scheme of <<"https">> -> 443; _ -> 80 end,
                    Port = maps:get(port, Parts, DefaultPort),
                    case is_integer(Port) andalso Port > 0 andalso Port =< 65535 of
                        false -> {error, invalid_url};
                        true ->
                            RawPath = case maps:get(path, Parts, <<>>) of <<>> -> <<"/">>; P -> pw_util:bin(P) end,
                            Path = case maps:get(query, Parts, undefined) of
                                undefined -> RawPath;
                                <<>> -> RawPath;
                                Q -> <<RawPath/binary, "?", (pw_util:bin(Q))/binary>>
                            end,
                            {ok, #{scheme => Scheme, host => Host, port => Port, path => Path}}
                    end
            end;
        _ -> {error, invalid_url}
    catch _:_ -> {error, invalid_url} end.

pinned_request(#{scheme := Scheme, host := Host, port := Port, path := Path, address := Address},
               MaxBytes, Truncate, Opts) ->
    Timeout = clamp_timeout(pw_util:env_int("PLAINWIRE_HTTP_FETCH_TIMEOUT_MS", 8000), 2000, 30000),
    ConnectTimeout = min(Timeout - 250, clamp_timeout(pw_util:env_int("PLAINWIRE_HTTP_CONNECT_TIMEOUT_MS", 2500), 500, 10000)),
    Transport = case Scheme of <<"https">> -> tls; _ -> tcp end,
    Open0 = #{transport => Transport, connect_timeout => ConnectTimeout},
    Open = case Transport of
        tls -> Open0#{tls_opts => gun_tls_options(Host)};
        tcp -> Open0
    end,
    Headers = pinned_headers(Host, Scheme, Port, Opts),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case gun:open(Address, Port, Open) of
        {ok, ConnPid} ->
            try
                case gun:await_up(ConnPid, ConnectTimeout) of
                    {ok, _Protocol} ->
                        Ref = gun:request(ConnPid, <<"GET">>, Path, Headers),
                        pinned_await_response(ConnPid, Ref, Deadline, MaxBytes, Truncate);
                    {error, Reason} -> {error, Reason}
                end
            after
                catch gun:close(ConnPid)
            end;
        {error, Reason} -> {error, Reason}
    end.

pinned_headers(Host, Scheme, Port, Opts) ->
    Base = [
        {<<"host">>, host_header(Host, Scheme, Port)},
        {<<"user-agent">>, pw_util:bin(maps:get(user_agent, Opts, "PlainwireRelay/2.0"))},
        {<<"accept-encoding">>, <<"identity">>}
    ],
    Accept = case maps:get(accept, Opts, undefined) of undefined -> []; V -> [{<<"accept">>, pw_util:bin(V)}] end,
    Extra = [{pw_util:bin(K), pw_util:bin(V)} || {K,V} <- normalize_extra_headers(maps:get(headers, Opts, []))],
    Base ++ Accept ++ Extra.

host_header(Host, Scheme, Port) ->
    Default = case Scheme of <<"https">> -> 443; _ -> 80 end,
    Authority = case binary:match(Host, <<":">>) of nomatch -> Host; _ -> <<"[", Host/binary, "]">> end,
    case Port =:= Default of true -> Authority; false -> <<Authority/binary, ":", (integer_to_binary(Port))/binary>> end.

gun_tls_options(Host) ->
    %% Trust-store lookup can fail on a damaged/minimal host. Keep verification
    %% enabled with an empty CA set so the request fails closed instead of
    %% crashing the media worker or silently weakening TLS.
    CAs = try public_key:cacerts_get() catch _:_ -> [] end,
    Base = [{verify, verify_peer},
            {cacerts, CAs},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _} -> Base;
        _ -> [{server_name_indication, binary_to_list(Host)} | Base]
    end.

pinned_await_response(ConnPid, Ref, Deadline, MaxBytes, Truncate) ->
    case gun_await(ConnPid, Ref, Deadline) of
        {inform, _Code, _Headers} -> pinned_await_response(ConnPid, Ref, Deadline, MaxBytes, Truncate);
        {response, fin, Code, Headers} -> {ok, Code, Headers, <<>>};
        {response, nofin, Code, Headers} ->
            case Truncate orelse content_length_ok(Headers, MaxBytes) of
                true -> pinned_collect(ConnPid, Ref, Deadline, Code, Headers, MaxBytes, Truncate, [], 0);
                false -> {error, too_large}
            end;
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_response, bounded_term(Other)}}
    end.

pinned_collect(ConnPid, Ref, Deadline, Code, Headers, MaxBytes, Truncate, Chunks, Size) ->
    case gun_await(ConnPid, Ref, Deadline) of
        {data, Fin, Chunk} when is_binary(Chunk) ->
            NewSize = Size + byte_size(Chunk),
            case NewSize =< MaxBytes of
                true when Fin =:= fin -> {ok, Code, Headers, iolist_to_binary(lists:reverse([Chunk|Chunks]))};
                true -> pinned_collect(ConnPid, Ref, Deadline, Code, Headers, MaxBytes, Truncate, [Chunk|Chunks], NewSize);
                false when Truncate ->
                    Body = iolist_to_binary(lists:reverse([Chunk|Chunks])),
                    {ok, Code, Headers, binary:part(Body, 0, MaxBytes)};
                false -> {error, too_large}
            end;
        {error, Reason} -> {error, Reason};
        Other -> {error, {unexpected_body, bounded_term(Other)}}
    end.

gun_await(ConnPid, Ref, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of 0 -> {error, timeout}; _ -> gun:await(ConnPid, Ref, Remaining) end.

bounded_term(Term) ->
    pw_util:clean_text(io_lib:format("~p", [Term]), 256).

%% truncate => true keeps the first MaxBytes of an oversized body instead of
%% failing. Page metadata lives near the top; media must arrive whole.
get(Url, MaxBytes, Opts) when is_binary(Url), is_integer(MaxBytes), MaxBytes > 0, is_map(Opts) ->
    Truncate = maps:get(truncate, Opts, false) =:= true,
    ExtraHeaders = normalize_extra_headers(maps:get(headers, Opts, [])),
    Headers = [{"user-agent", maps:get(user_agent, Opts, "PlainwireRelay/1.4")}, {"accept-encoding", "identity"}]
        ++ [{"accept", Accept} || Accept <- [maps:get(accept, Opts, undefined)], Accept =/= undefined]
        ++ ExtraHeaders,
    %% no redirects here; they sidestep the SSRF check. rude. Keep media/page
    %% fetches bounded so one dead avatar host cannot make a refresh feel frozen.
    Timeout = clamp_timeout(pw_util:env_int("PLAINWIRE_HTTP_FETCH_TIMEOUT_MS", 8000), 2000, 30000),
    ConnectTimeout = min(Timeout - 250, clamp_timeout(pw_util:env_int("PLAINWIRE_HTTP_CONNECT_TIMEOUT_MS", 2500), 500, 10000)),
    HttpOptions = [{timeout, Timeout}, {connect_timeout, ConnectTimeout}, {autoredirect, false}] ++ tls_options(Url),
    Options = [{sync, false}, {stream, {self, once}}],
    Deadline = erlang:monotonic_time(millisecond) + Timeout + 1000,
    case httpc:request(get, {binary_to_list(Url), Headers}, HttpOptions, Options) of
        {ok, RequestId} -> await_start(RequestId, MaxBytes, Truncate, Deadline);
        {error, Reason} -> {error, Reason}
    end.


tls_options(<<"https://", _/binary>>) ->
    %% Keep certificate and HTTPS hostname verification explicit even on the
    %% OTP 27+ baseline so future runtime defaults cannot silently weaken it
    %% explicit instead of relying on the runtime's changing defaults.
    try
        [{ssl, [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
        ]}]
    catch
        _:_ ->
            %% Fail closed if the host trust store cannot be loaded. An empty CA
            %% set makes TLS verification fail rather than silently downgrading.
            [{ssl, [
                {verify, verify_peer},
                {cacerts, []},
                {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
            ]}]
    end;
tls_options(_) -> [].

await_start(RequestId, MaxBytes, Truncate, Deadline) ->
    receive
        {http, {RequestId, stream_start, Headers, HandlerPid}} ->
            case Truncate orelse content_length_ok(Headers, MaxBytes) of
                true -> httpc:stream_next(HandlerPid), collect(RequestId, HandlerPid, Headers, MaxBytes, Truncate, [], 0, Deadline);
                false -> cancel(RequestId), {error, too_large}
            end;
        {http, {RequestId, {{_, Code, _}, Headers, Body}}} ->
            Bin = iolist_to_binary(Body),
            case byte_size(Bin) =< MaxBytes of
                true -> {ok, Code, Headers, Bin};
                false when Truncate -> {ok, Code, Headers, binary:part(Bin, 0, MaxBytes)};
                false -> {error, too_large}
            end;
        {http, {RequestId, {error, Reason}}} -> {error, Reason}
    after remaining_ms(Deadline) ->
        cancel(RequestId),
        {error, timeout}
    end.

collect(RequestId, HandlerPid, Headers, MaxBytes, Truncate, Chunks, Size, Deadline) ->
    receive
        {http, {RequestId, stream, Chunk}} ->
            NewSize = Size + byte_size(Chunk),
            case NewSize =< MaxBytes of
                true ->
                    httpc:stream_next(HandlerPid),
                    collect(RequestId, HandlerPid, Headers, MaxBytes, Truncate, [Chunk | Chunks], NewSize, Deadline);
                false when Truncate ->
                    cancel(RequestId),
                    Body = iolist_to_binary(lists:reverse([Chunk | Chunks])),
                    {ok, 200, Headers, binary:part(Body, 0, MaxBytes)};
                false ->
                    cancel(RequestId),
                    {error, too_large}
            end;
        {http, {RequestId, stream_end, EndHeaders}} ->
            {ok, 200, Headers ++ EndHeaders, iolist_to_binary(lists:reverse(Chunks))};
        {http, {RequestId, {error, Reason}}} -> {error, Reason}
    after remaining_ms(Deadline) ->
        cancel(RequestId),
        {error, timeout}
    end.

remaining_ms(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

clamp_timeout(N, Min, Max) when is_integer(N) -> min(Max, max(Min, N));
clamp_timeout(_, Min, _Max) -> Min.

content_length_ok(Headers, MaxBytes) ->
    case header_value(<<"content-length">>, Headers) of
        undefined -> true;
        Len ->
            case pw_util:int(string:trim(pw_util:bin(Len))) of
                N when is_integer(N), N >= 0 -> N =< MaxBytes;
                _ -> false
            end
    end.

%% OTP/httpc may expose header names and values as binaries or iolists depending
%% on OTP version and request mode. Normalize only the name for comparison and
%% leave the value untouched for the caller to interpret.
header_value(Name0, Headers) ->
    Name = string:lowercase(pw_util:bin(Name0)),
    case [V || {K, V} <- Headers, string:lowercase(pw_util:bin(K)) =:= Name] of
        [V | _] -> V;
        [] -> undefined
    end.

cancel(RequestId) ->
    try httpc:cancel_request(RequestId) catch _:_ -> ok end,
    ok.

normalize_extra_headers(Headers) when is_list(Headers) ->
    [
        {binary_to_list(NameBin), binary_to_list(ValueBin)}
     || {Name, Value} <- Headers,
        NameBin <- [pw_util:bin(Name)],
        ValueBin <- [pw_util:bin(Value)],
        byte_size(NameBin) > 0,
        byte_size(NameBin) =< 128,
        byte_size(ValueBin) =< 4096,
        valid_header_name(NameBin),
        safe_extra_header_name(NameBin),
        binary:match(ValueBin, <<"\r">>) =:= nomatch,
        binary:match(ValueBin, <<"\n">>) =:= nomatch
    ];
normalize_extra_headers(_) -> [].

valid_header_name(<<>>) -> true;
valid_header_name(<<C, Rest/binary>>) when (C >= $a andalso C =< $z) orelse
                                            (C >= $A andalso C =< $Z) orelse
                                            (C >= $0 andalso C =< $9) orelse
                                            C =:= $! orelse C =:= $# orelse C =:= $$ orelse
                                            C =:= $% orelse C =:= $& orelse C =:= $' orelse
                                            C =:= $* orelse C =:= $+ orelse C =:= $- orelse
                                            C =:= $. orelse C =:= $^ orelse C =:= $_ orelse
                                            C =:= $` orelse C =:= $| orelse C =:= $~ ->
    valid_header_name(Rest);
valid_header_name(_) -> false.
%% These fields are owned by the transport/request builder. Letting a generic
%% caller duplicate them can desynchronize policy (Host) or framing
%% (Content-Length/Transfer-Encoding) from the bytes Gun/httpc actually sends.
safe_extra_header_name(Name0) ->
    Name = string:lowercase(Name0),
    not lists:member(Name, [<<"host">>, <<"connection">>, <<"content-length">>,
                            <<"transfer-encoding">>, <<"te">>, <<"upgrade">>,
                            <<"proxy-authorization">>, <<"proxy-authenticate">>]).

-ifdef(TEST).
test_normalize_extra_headers(Headers) -> normalize_extra_headers(Headers).
-endif.
