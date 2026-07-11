-module(pw_file_hdl).
-behaviour(cowboy_handler).
-export([init/2]).

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
                <<"etag">> => <<"\"", Hash/binary, "\"">>
            }),
            case cowboy_req:header(<<"if-none-match">>, Req0, <<>>) of
                E when E =:= <<"\"", Hash/binary, "\"">> ->
                    {ok, cowboy_req:reply(304, Headers, <<>>, Req0), undefined};
                _ when Head -> {ok, cowboy_req:reply(200, Headers, <<>>, Req0), undefined};
                _ -> {ok, cowboy_req:reply(200, Headers, {sendfile, 0, Size, binary_to_list(Path)}, Req0), undefined}
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
    %% Only passive, browser-native formats are safe to render inline. In
    %% particular, SVG/XML/HTML remain downloads even if a client supplied an
    %% image-like Content-Type.
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
inline_type(<<"audio/mpeg">>) -> true;
inline_type(<<"audio/ogg">>) -> true;
inline_type(<<"audio/wav">>) -> true;
inline_type(<<"audio/webm">>) -> true;
inline_type(_) -> false.
