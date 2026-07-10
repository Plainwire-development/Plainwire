-module(pw_media_hdl).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, _) ->
    case auth(Req0) of
        {ok, Uid} ->
            Path = cowboy_req:path(Req0),
            Token = extract_token(Path),
            case pw_rate:allow({media, pw_util:ip(Req0), Uid}, 120, 60000) of
                false ->
                    pw_util:err_json(Req0, 429, <<"rate_limited">>);
                true ->
            case pw_media:fetch(Uid, Token) of
                {ok, Body, Type} ->
                    Headers = maps:merge(pw_util:security_headers(), #{
                        <<"content-type">> => Type,
                        <<"cache-control">> => <<"private, max-age=3600">>
                    }),
                    Req = cowboy_req:reply(200, Headers, Body, Req0),
                    {ok, Req, undefined};
                {error, blocked_url} ->
                    pw_util:err_json(Req0, 403, <<"blocked_url">>);
                {error, invalid_url} ->
                    pw_util:err_json(Req0, 400, <<"invalid_url">>);
                {error, _} ->
                    pw_util:err_json(Req0, 502, <<"fetch_failed">>)
            end
            end;
        {error, _} ->
            pw_util:err_json(Req0, 401, <<"not_authenticated">>)
    end.

auth(Req) ->
    case pw_util:cookie_value(Req, <<"pw_session">>) of
        undefined -> {error, no_session};
        Token ->
            case pw_db:session(Token) of
                {ok, Session} -> {ok, maps:get(id, maps:get(user, Session))};
                _ -> {error, no_session}
            end
    end.

extract_token(Path) ->
    Segs = [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>],
    case lists:reverse(Segs) of
        [Token | _] -> Token;
        _ -> <<>>
    end.
