-module(pw_app_http).
-export([post_json/4]).

%% Small, policy-checked HTTP client for developer interactions and hosted AI
%% commands. It deliberately does not follow redirects: a redirect is a second
%% outbound destination and must never bypass Plainwire's SSRF policy.
post_json(Url0, ExtraHeaders0, Payload0, Timeout0) ->
    Url = pw_util:clean_text(Url0, 2048),
    Payload = iolist_to_binary(Payload0),
    Timeout = min(60000, max(2000, int_or(Timeout0, 10000))),
    MaxRequest = min(1048576, max(4096, pw_util:env_int("PLAINWIRE_APP_REQUEST_MAX_BYTES", 65536))),
    MaxResponse = min(1048576, max(4096, pw_util:env_int("PLAINWIRE_APP_RESPONSE_MAX_BYTES", 131072))),
    case byte_size(Payload) =< MaxRequest of
        false -> {error, request_too_large};
        true ->
            case pw_outbound_url:resolve_app_allowed(Url) of
                {ok, Target} -> post_target(Target, sanitize_headers(ExtraHeaders0), Payload, Timeout, MaxResponse);
                {error, _} -> {error, blocked_url}
            end
    end.

post_target(#{host := Host, address := Address, port := Port, scheme := Scheme, path := Path}, Headers0, Payload, Timeout, MaxResponse) ->
    Transport = case Scheme of <<"https">> -> tls; _ -> tcp end,
    Open0 = #{transport => Transport, connect_timeout => min(3000, Timeout)},
    Open = case Transport of tls -> Open0#{tls_opts => tls_options(Host)}; tcp -> Open0 end,
    case gun:open(Address, Port, Open) of
        {ok, ConnPid} ->
            try
                case gun:await_up(ConnPid, min(3000, Timeout)) of
                    {ok, _} ->
                        Headers = [{<<"host">>, host_header(Host, Scheme, Port)},
                                   {<<"content-type">>, <<"application/json">>},
                                   {<<"accept">>, <<"application/json">>},
                                   {<<"user-agent">>, <<"Plainwire-App/2.1">>} | Headers0],
                        Ref = gun:request(ConnPid, <<"POST">>, Path, Headers, Payload),
                        Deadline = erlang:monotonic_time(millisecond) + Timeout,
                        await_response(ConnPid, Ref, Deadline, MaxResponse);
                    {error, Reason} -> {error, format_reason(Reason)}
                end
            after catch gun:close(ConnPid) end;
        {error, Reason} -> {error, format_reason(Reason)}
    end.

await_response(ConnPid, Ref, Deadline, MaxResponse) ->
    case gun_await(ConnPid, Ref, Deadline) of
        {inform, _Code, _Headers} -> await_response(ConnPid, Ref, Deadline, MaxResponse);
        {response, fin, Code, Headers} -> {ok, Code, Headers, <<>>};
        {response, nofin, Code, Headers} ->
            case content_length_ok(Headers, MaxResponse) of
                true -> collect(ConnPid, Ref, Deadline, MaxResponse, Code, Headers, [], 0);
                false -> catch gun:cancel(ConnPid, Ref), {error, response_too_large}
            end;
        {error, Reason} -> {error, format_reason(Reason)};
        Other -> {error, format_reason(Other)}
    end.

collect(ConnPid, Ref, Deadline, MaxResponse, Code, Headers, Chunks, Size) ->
    case gun_await(ConnPid, Ref, Deadline) of
        {data, Fin, Chunk} when is_binary(Chunk) ->
            NewSize = Size + byte_size(Chunk),
            case NewSize =< MaxResponse of
                false -> catch gun:cancel(ConnPid, Ref), {error, response_too_large};
                true when Fin =:= fin -> {ok, Code, Headers, iolist_to_binary(lists:reverse([Chunk | Chunks]))};
                true -> collect(ConnPid, Ref, Deadline, MaxResponse, Code, Headers, [Chunk | Chunks], NewSize)
            end;
        {error, Reason} -> {error, format_reason(Reason)};
        Other -> {error, format_reason(Other)}
    end.

gun_await(ConnPid, Ref, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of 0 -> {error, timeout}; _ -> gun:await(ConnPid, Ref, Remaining) end.

content_length_ok(Headers, MaxBytes) ->
    case [V || {K,V} <- Headers, string:lowercase(pw_util:bin(K)) =:= <<"content-length">>] of
        [V | _] ->
            case pw_util:int(pw_util:bin(V)) of N when is_integer(N), N >= 0 -> N =< MaxBytes; _ -> false end;
        [] -> true
    end.

sanitize_headers(Headers) when is_list(Headers) ->
    [{Name, Value} || {Name0, Value0} <- Headers,
                      Name <- [string:lowercase(pw_util:bin(Name0))], Value <- [pw_util:bin(Value0)],
                      byte_size(Name) > 0, byte_size(Name) =< 128, byte_size(Value) =< 4096,
                      binary:match(Value, <<"\r">>) =:= nomatch, binary:match(Value, <<"\n">>) =:= nomatch,
                      not lists:member(Name, [<<"host">>, <<"content-length">>, <<"transfer-encoding">>, <<"connection">>])];
sanitize_headers(_) -> [].

host_header(Host, Scheme, Port) ->
    Default = case Scheme of <<"https">> -> 443; _ -> 80 end,
    Authority = case binary:match(Host, <<":">>) of nomatch -> Host; _ -> <<"[", Host/binary, "]">> end,
    case Port =:= Default of true -> Authority; false -> <<Authority/binary, ":", (integer_to_binary(Port))/binary>> end.

tls_options(Host) ->
    CAs = try public_key:cacerts_get() catch _:_ -> [] end,
    Base = [{verify, verify_peer}, {cacerts, CAs},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _} -> Base;
        _ -> [{server_name_indication, binary_to_list(Host)} | Base]
    end.

format_reason(Reason) -> pw_util:clean_text(io_lib:format("~p", [Reason]), 500).
int_or(I, _Default) when is_integer(I) -> I;
int_or(_, Default) -> Default.
