-module(pw_file_hdl).
-behaviour(cowboy_handler).
-export([init/2]).
-ifdef(TEST).
-export([range_bounds/2]).
-endif.

init(Req0, _) ->
    Id = lists:last([S || S <- binary:split(cowboy_req:path(Req0), <<"/">>, [global]), S =/= <<>>]),
    case {cowboy_req:method(Req0), authenticated_uid(Req0)} of
        {<<"GET">>, {ok, Uid}} -> serve(Req0, Uid, Id, false);
        {<<"HEAD">>, {ok, Uid}} -> serve(Req0, Uid, Id, true);
        {_, {error, _}} -> pw_util:err_json(Req0, 401, <<"not_authenticated">>);
        _ -> pw_util:err_json(Req0, 405, <<"method_not_allowed">>)
    end.

serve(Req0, Uid, Id, Head) ->
    Allowed = pw_rate:allow({file_download, Uid, pw_util:ip(Req0)}, 600, 60000),
    Result = case Allowed andalso valid_id(Id) of
        true -> pw_upload_gc:lookup(Uid, Id);
        false -> denied
    end,
    case {Allowed, Result} of
        {false, _} -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        {true, {ok, #{path := Path, name := Name, content_type := Type, size := Size, sha256 := Hash}}} ->
            Headers = maps:merge(pw_util:security_headers(), #{
                <<"content-type">> => Type, <<"content-length">> => integer_to_binary(Size),
                <<"content-disposition">> => disposition(Type, Name),
                <<"cache-control">> => <<"private, max-age=86400, immutable">>,
                <<"etag">> => <<"\"", Hash/binary, "\"">>,
                <<"accept-ranges">> => <<"bytes">>
            }),
            Range = range_bounds(cowboy_req:header(<<"range">>, Req0, <<>>), Size),
            case {Range, cowboy_req:header(<<"if-none-match">>, Req0, <<>>), Head} of
                {full, E, _} when E =:= <<"\"", Hash/binary, "\"">> ->
                    {ok, cowboy_req:reply(304, Headers, <<>>, Req0), undefined};
                {full, _, true} ->
                    {ok, cowboy_req:reply(200, Headers, <<>>, Req0), undefined};
                {full, _, false} ->
                    {ok, cowboy_req:reply(200, Headers, {sendfile, 0, Size, binary_to_list(Path)}, Req0), undefined};
                {{partial, Start, Length, End}, _, IsHead} ->
                    PartialHeaders = Headers#{
                        <<"content-length">> => integer_to_binary(Length),
                        <<"content-range">> => <<"bytes ", (integer_to_binary(Start))/binary, "-",
                            (integer_to_binary(End))/binary, "/", (integer_to_binary(Size))/binary>>
                    },
                    Body = case IsHead of true -> <<>>; false -> {sendfile, Start, Length, binary_to_list(Path)} end,
                    {ok, cowboy_req:reply(206, PartialHeaders, Body, Req0), undefined};
                {invalid, _, _} ->
                    InvalidHeaders = Headers#{<<"content-length">> => <<"0">>,
                        <<"content-range">> => <<"bytes */", (integer_to_binary(Size))/binary>>},
                    {ok, cowboy_req:reply(416, InvalidHeaders, <<>>, Req0), undefined}
            end;
        _ -> pw_util:err_json(Req0, 404, <<"file_not_found">>)
    end.

valid_id(Id) when byte_size(Id) >= 24, byte_size(Id) =< 64 ->
    lists:all(fun(C) ->
        (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_
    end, binary_to_list(Id));
valid_id(_) -> false.

authenticated_uid(Req) ->
    case pw_util:cookie_value(Req, <<"pw_session">>) of
        undefined -> {error, no_session};
        Token ->
            Result = case pw_db:session_fast(Token) of {ok, Cached} -> {ok, Cached}; _ -> pw_db:session(Token) end,
            case Result of {ok, Session} -> {ok, maps:get(id, maps:get(user, Session))}; Error -> Error end
    end.

disposition(Type, Name) ->
    %% only passive formats render inline. SVG/XML/HTML stay downloads.
    Kind = case inline_type(Type) of true -> <<"inline">>; false -> <<"attachment">> end,
    Safe0 = binary:replace(binary:replace(Name, <<"\"">>, <<>>, [global]), <<"\r">>, <<>>, [global]),
    Safe = binary:replace(Safe0, <<"\n">>, <<>>, [global]),
    <<Kind/binary, "; filename=\"", Safe/binary, "\"">>.

inline_type(<<"image/jpeg">>) -> true;
inline_type(<<"image/png">>) -> true;
inline_type(<<"image/gif">>) -> true;
inline_type(<<"image/webp">>) -> true;
inline_type(<<"image/avif">>) -> true;
inline_type(<<"video/mp4">>) -> true;
inline_type(<<"video/webm">>) -> true;
inline_type(<<"video/ogg">>) -> true;
inline_type(<<"video/quicktime">>) -> true;
inline_type(<<"video/x-m4v">>) -> true;
inline_type(<<"audio/mpeg">>) -> true;
inline_type(<<"audio/ogg">>) -> true;
inline_type(<<"audio/wav">>) -> true;
inline_type(<<"audio/webm">>) -> true;
inline_type(<<"audio/mp4">>) -> true;
inline_type(<<"audio/x-m4a">>) -> true;
inline_type(<<"audio/aac">>) -> true;
inline_type(<<"audio/flac">>) -> true;
inline_type(<<"audio/opus">>) -> true;
inline_type(_) -> false.

%% one range is enough for seeking. multipart can stay somebody else's hobby.
range_bounds(<<>>, _Size) -> full;
range_bounds(<<"bytes=", Spec/binary>>, Size) when is_integer(Size), Size > 0 ->
    case {binary:match(Spec, <<",">>), binary:split(Spec, <<"-">>, [global])} of
        {nomatch, [<<>>, SuffixBin]} ->
            case pw_util:int(SuffixBin) of
                Suffix when is_integer(Suffix), Suffix > 0 ->
                    Length = min(Suffix, Size),
                    Start = Size - Length,
                    {partial, Start, Length, Size - 1};
                _ -> invalid
            end;
        {nomatch, [StartBin, <<>>]} ->
            case pw_util:int(StartBin) of
                Start when is_integer(Start), Start >= 0, Start < Size ->
                    {partial, Start, Size - Start, Size - 1};
                _ -> invalid
            end;
        {nomatch, [StartBin, EndBin]} ->
            case {pw_util:int(StartBin), pw_util:int(EndBin)} of
                {Start, End0} when is_integer(Start), is_integer(End0), Start >= 0, Start < Size, End0 >= Start ->
                    End = min(End0, Size - 1),
                    {partial, Start, End - Start + 1, End};
                _ -> invalid
            end;
        _ -> invalid
    end;
range_bounds(_, _) -> invalid.
