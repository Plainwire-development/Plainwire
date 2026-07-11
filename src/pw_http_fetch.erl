-module(pw_http_fetch).
-export([get/2]).

get(Url, MaxBytes) when is_binary(Url), is_integer(MaxBytes), MaxBytes > 0 ->
    Headers = [{"user-agent", "PlainwireRelay/1.1"}, {"accept-encoding", "identity"}],
    HttpOptions = [{timeout, 15000}, {connect_timeout, 5000}, {autoredirect, true}],
    Options = [{sync, false}, {stream, {self, once}}],
    case httpc:request(get, {binary_to_list(Url), Headers}, HttpOptions, Options) of
        {ok, RequestId} -> await_start(RequestId, MaxBytes);
        {error, Reason} -> {error, Reason}
    end.

await_start(RequestId, MaxBytes) ->
    receive
        {http, {RequestId, stream_start, Headers, HandlerPid}} ->
            case content_length_ok(Headers, MaxBytes) of
                true -> httpc:stream_next(HandlerPid), collect(RequestId, HandlerPid, Headers, MaxBytes, [], 0);
                false -> cancel(RequestId), {error, too_large}
            end;
        {http, {RequestId, {{_, Code, _}, Headers, Body}}} ->
            Bin = iolist_to_binary(Body),
            case byte_size(Bin) =< MaxBytes of
                true -> {ok, Code, Headers, Bin};
                false -> {error, too_large}
            end;
        {http, {RequestId, {error, Reason}}} -> {error, Reason}
    after 16000 ->
        cancel(RequestId),
        {error, timeout}
    end.

collect(RequestId, HandlerPid, Headers, MaxBytes, Chunks, Size) ->
    receive
        {http, {RequestId, stream, Chunk}} ->
            NewSize = Size + byte_size(Chunk),
            case NewSize =< MaxBytes of
                true ->
                    httpc:stream_next(HandlerPid),
                    collect(RequestId, HandlerPid, Headers, MaxBytes, [Chunk | Chunks], NewSize);
                false ->
                    cancel(RequestId),
                    {error, too_large}
            end;
        {http, {RequestId, stream_end, EndHeaders}} ->
            {ok, 200, Headers ++ EndHeaders, iolist_to_binary(lists:reverse(Chunks))};
        {http, {RequestId, {error, Reason}}} -> {error, Reason}
    after 16000 ->
        cancel(RequestId),
        {error, timeout}
    end.

content_length_ok(Headers, MaxBytes) ->
    case header_value("content-length", Headers) of
        undefined -> true;
        Len ->
            try list_to_integer(string:trim(Len)) =< MaxBytes
            catch _:_ -> false
            end
    end.

header_value(Name, Headers) ->
    case [V || {K, V} <- Headers, string:lowercase(K) =:= Name] of
        [V | _] -> V;
        [] -> undefined
    end.

cancel(RequestId) ->
    try httpc:cancel_request(RequestId) catch _:_ -> ok end,
    ok.
