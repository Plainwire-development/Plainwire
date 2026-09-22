-module(pw_media_hdl).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, _) ->
    %% Keep the authenticated media endpoint read-only. Cowboy routes do not
    %% constrain HTTP methods by themselves, so accepting arbitrary verbs here
    %% would make POST/DELETE behave like GET and create surprising cache/CSRF
    %% semantics. HEAD intentionally follows GET headers without a body.
    case cowboy_req:method(Req0) of
        <<"GET">> -> authenticate_and_serve(Req0, false);
        <<"HEAD">> -> authenticate_and_serve(Req0, true);
        _ ->
            Req = cowboy_req:reply(405,
                maps:merge(pw_util:security_headers(), #{<<"allow">> => <<"GET, HEAD">>}),
                <<>>, Req0),
            {ok, Req, undefined}
    end.

authenticate_and_serve(Req0, HeadOnly) ->
    case auth(Req0) of
        {ok, Uid} ->
            Path = cowboy_req:path(Req0),
            Token = extract_token(Path),
            MediaLimit = min(5000, max(120, pw_util:env_int("PLAINWIRE_MEDIA_REQUESTS_PER_MINUTE", 1200))),
            case pw_rate:allow({media, pw_util:ip(Req0), Uid}, MediaLimit, 60000) of
                false ->
                    pw_util:err_json(Req0, 429, <<"rate_limited">>);
                true ->
                    serve(Req0, Uid, Token, HeadOnly)
            end;
        {error, no_session} ->
            pw_util:err_json(Req0, 401, <<"not_authenticated">>);
        {error, _} ->
            pw_util:err_json(Req0, 503, <<"database_unavailable">>)
    end.

serve(Req0, Uid, Token, HeadOnly) ->
    %% The proxy token identifies the upstream URL, not its current bytes. Fetch
    %% first (normally an ETS cache hit), then derive the validator from the
    %% actual representation so a remote avatar changed in-place can refresh.
    %% Responses are private because this endpoint is authenticated; a shared
    %% reverse proxy must never replay one user's media response anonymously.
    %% HEAD never pulls the origin: a cache miss answers from the token alone.
    Result = case HeadOnly of
        true -> pw_media:fetch_head(Token);
        false -> pw_media:fetch(Uid, Token)
    end,
    case Result of
        uncached ->
            Headers = maps:without([<<"content-length">>, <<"etag">>],
                media_headers(<<"application/octet-stream">>, <<>>, 0)),
            {ok, cowboy_req:reply(200, Headers, <<>>, Req0), undefined};
        {ok, Body, Type} ->
            ETag = <<"\"", (pw_util:sha256_hex(Body))/binary, "\"">>,
            Headers = media_headers(Type, ETag, byte_size(Body)),
            case cowboy_req:header(<<"if-none-match">>, Req0, <<>>) =:= ETag of
                true ->
                    Req = cowboy_req:reply(304, maps:remove(<<"content-length">>, Headers), <<>>, Req0),
                    {ok, Req, undefined};
                false ->
                    ResponseBody = case HeadOnly of true -> <<>>; false -> Body end,
                    Req = cowboy_req:reply(200, Headers, ResponseBody, Req0),
                    {ok, Req, undefined}
            end;
        {error, blocked_url} ->
            pw_util:err_json(Req0, 403, <<"blocked_url">>);
        {error, invalid_url} ->
            pw_util:err_json(Req0, 400, <<"invalid_url">>);
        {error, too_large} ->
            pw_util:err_json(Req0, 413, <<"media_too_large">>);
        {error, unsupported_type} ->
            pw_util:err_json(Req0, 415, <<"unsupported_media_type">>);
        {error, timeout} ->
            pw_util:err_json(Req0, 504, <<"media_timeout">>);
        {error, overloaded} ->
            pw_util:err_json(Req0, 503, <<"media_overloaded">>);
        {error, _} ->
            pw_util:err_json(Req0, 502, <<"fetch_failed">>)
    end.

auth(Req) ->
    case pw_util:cookie_value(Req, <<"pw_session">>) of
        undefined -> {error, no_session};
        Token ->
            case pw_db:session_fast(Token) of
                {ok, Session} -> {ok, maps:get(id, maps:get(user, Session))};
                %% ETS expired, not necessarily the session. check the DB.
                _ ->
                    case pw_db:session(Token) of
                        {ok, Session} -> {ok, maps:get(id, maps:get(user, Session))};
                        Error -> Error
                    end
            end
    end.

extract_token(Path) ->
    Segs = [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>],
    case lists:reverse(Segs) of
        [Token | _] -> Token;
        _ -> <<>>
    end.

media_headers(Type, ETag, Size) ->
    maps:merge(pw_util:security_headers(), #{
        <<"content-type">> => Type,
        <<"content-length">> => integer_to_binary(Size),
        <<"cache-control">> => <<"private, max-age=3600, stale-while-revalidate=300">>,
        <<"etag">> => ETag,
        <<"x-content-type-options">> => <<"nosniff">>
    }).
