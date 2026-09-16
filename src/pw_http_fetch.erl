-module(pw_http_fetch).
-export([get/2, get/3]).

get(Url, MaxBytes) -> get(Url, MaxBytes, #{}).

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
    %% OTP 25 still defaulted httpc TLS verification to verify_none. Plainwire
    %% supports OTP 25+, so make certificate + HTTPS hostname verification
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
