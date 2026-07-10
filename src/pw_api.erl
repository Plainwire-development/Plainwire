-module(pw_api).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = api_path(cowboy_req:path(Req0)),
    case allowed(Req0, Method, Path) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true -> handle(Method, Path, Req0, State)
    end.

allowed(Req, Method, Path) ->
    Ip = pw_util:ip(Req),
    Limit = case Method of <<"GET">> -> 900; _ -> 180 end,
    pw_rate:allow({Ip, Method, Path}, Limit, 60000).

api_path(Path) ->
    Segs = [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>],
    case Segs of [<<"api">>|Rest] -> Rest; _ -> Segs end.
qs(Req, Key) -> proplists:get_value(Key, cowboy_req:parse_qs(Req)).

handle(<<"POST">>, [<<"register">>], Req0, _) ->
    with_json_public(Req0, fun(M, Req) ->
        U=maps:get(<<"username">>,M,<<>>), D=maps:get(<<"display_name">>,M,U), P=maps:get(<<"password">>,M,<<>>),
        case pw_db:register(U,D,P) of
            {ok, #{token:=Token}=Data} -> pw_util:ok_json(pw_util:set_cookie(Req, <<"pw_session">>, Token), #{ok=>true,data=>maps:remove(token,Data)});
            {error, username_taken} -> pw_util:err_json(Req, 409, <<"username_taken">>);
            {error, database_unavailable} -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
            {error, timeout} -> pw_util:err_json(Req, 503, <<"database_timeout">>);
            {error,E} -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8))
        end
    end);
handle(<<"POST">>, [<<"login">>], Req0, _) ->
    with_json_public(Req0, fun(M, Req) ->
        case pw_db:login(maps:get(<<"username">>,M,<<>>), maps:get(<<"password">>,M,<<>>)) of
            {ok, #{token:=Token}=Data} -> pw_util:ok_json(pw_util:set_cookie(Req, <<"pw_session">>, Token), #{ok=>true,data=>maps:remove(token,Data)});
            {error, database_unavailable} -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
            {error, timeout} -> pw_util:err_json(Req, 503, <<"database_timeout">>);
            {error,E} -> pw_util:err_json(Req, 401, atom_to_binary(E, utf8))
        end
    end);
handle(<<"POST">>, [<<"logout">>], Req0, _) ->
    Token = pw_util:cookie_value(Req0, <<"pw_session">>),
    _ = case Token of undefined -> ok; _ -> pw_db:logout(Token) end,
    pw_util:ok_json(pw_util:clear_cookie(Req0), #{ok=>true});
handle(Method, Path, Req0, State) ->
    case auth(Req0) of
        {ok, Session} ->
            case Method =:= <<"GET">> orelse pw_util:require_csrf(Req0, Session) of
                true -> authed(Method, Path, Req0, Session, State);
                false -> pw_util:err_json(Req0, 403, <<"bad_csrf">>)
            end;
        {error, database_unavailable} -> pw_util:err_json(Req0, 503, <<"database_unavailable">>);
        {error, timeout} -> pw_util:err_json(Req0, 503, <<"database_timeout">>);
        {error,_} -> pw_util:err_json(Req0, 401, <<"not_authenticated">>)
    end.

auth(Req) ->
    case pw_util:cookie_value(Req, <<"pw_session">>) of
        undefined -> {error, no_session};
        Token -> pw_db:session(Token)
    end.
uid(Session) -> maps:get(id, maps:get(user, Session)).

authed(<<"GET">>, [<<"me">>], Req, Session, _) -> pw_util:ok_json(Req, #{ok=>true,data=>Session});
authed(<<"GET">>, [<<"sync">>], Req, Session, _) -> result(Req, pw_db:sync(uid(Session), qs(Req, <<"since">>)));
authed(<<"POST">>, [<<"profile">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_profile(uid(Session), maps:get(<<"display_name">>, M, maps:get(display_name, maps:get(user,Session))), M)) end);
authed(<<"GET">>, [<<"forums">>], Req, Session, _) -> result(Req, pw_db:forums(uid(Session)));
authed(<<"POST">>, [<<"forums">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_forum(uid(Session), maps:get(<<"name">>,M,<<>>), maps:get(<<"slug">>,M,<<>>), maps:get(<<"description">>,M,<<>>))) end);
authed(<<"POST">>, [<<"forum">>, Id, <<"join">>], Req, Session, _) -> result(Req, pw_db:join_forum(uid(Session), Id));
authed(<<"POST">>, [<<"forum">>, Id, <<"leave">>], Req, Session, _) -> result(Req, pw_db:leave_forum(uid(Session), Id));
authed(<<"GET">>, [<<"threads">>], Req, Session, _) -> result(Req, pw_db:threads(uid(Session), qs(Req, <<"forum_id">>), qs(Req, <<"q">>)));
authed(<<"POST">>, [<<"threads">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_thread(uid(Session), maps:get(<<"forum_id">>,M,undefined), maps:get(<<"title">>,M,<<>>), maps:get(<<"body">>,M,<<>>))) end);
authed(<<"GET">>, [<<"thread">>, Id], Req, Session, _) -> result(Req, pw_db:thread(uid(Session), Id));
authed(<<"POST">>, [<<"thread">>, Id, <<"replies">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:reply_thread(uid(Session), Id, maps:get(<<"body">>,M,<<>>))) end);
authed(<<"POST">>, [<<"thread">>, Id, <<"vote">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:vote_thread(uid(Session), Id, maps:get(<<"value">>,M,0))) end);
authed(<<"GET">>, [<<"users">>], Req, _, _) -> result(Req, pw_db:users(qs(Req, <<"q">>)));
authed(<<"GET">>, [<<"profile">>, Id], Req, Session, _) -> result(Req, pw_db:profile(uid(Session), Id));
authed(<<"GET">>, [<<"friends">>], Req, Session, _) -> result(Req, pw_db:friends(uid(Session)));
authed(<<"POST">>, [<<"friends">>, <<"request">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:friend_request(uid(Session), maps:get(<<"user_id">>,M,undefined))) end);
authed(<<"POST">>, [<<"friends">>, <<"accept">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:friend_accept(uid(Session), maps:get(<<"user_id">>,M,undefined))) end);
authed(<<"POST">>, [<<"friends">>, <<"remove">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:friend_remove(uid(Session), maps:get(<<"user_id">>,M,undefined))) end);
authed(<<"POST">>, [<<"friends">>, <<"block">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:friend_block(uid(Session), maps:get(<<"user_id">>,M,undefined))) end);
authed(<<"GET">>, [<<"servers">>], Req, Session, _) -> result(Req, pw_db:servers(uid(Session)));
authed(<<"POST">>, [<<"servers">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_server(uid(Session), maps:get(<<"name">>,M,<<>>), maps:get(<<"description">>,M,<<>>))) end);
authed(<<"GET">>, [<<"server">>, Id], Req, Session, _) -> result(Req, pw_db:server(uid(Session), Id));
authed(<<"POST">>, [<<"server">>, Id], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_server(uid(Session), Id, M)) end);
authed(<<"POST">>, [<<"server">>, Id, <<"channels">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_channel(uid(Session), Id, maps:get(<<"name">>,M,<<>>), maps:get(<<"kind">>,M,<<"text">>))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"invites">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_invite(uid(Session), Id, maps:get(<<"channel_id">>,M,undefined), maps:get(<<"max_uses">>,M,0))) end);
authed(<<"POST">>, [<<"invites">>, Code, <<"join">>], Req, Session, _) -> result(Req, pw_db:join_invite(uid(Session), Code));
authed(<<"GET">>, [<<"invites">>, Code], Req, _, _) -> result(Req, pw_db:invite_preview(Code));
authed(<<"GET">>, [<<"embed">>], Req, _, _) ->
    case qs(Req, <<"url">>) of
        undefined -> pw_util:err_json(Req, 400, <<"missing_url">>);
        Url ->
            case pw_embed:fetch(Url) of
                {ok, Meta} -> pw_util:ok_json(Req, #{ok => true, data => Meta});
                {error, blocked_url} -> pw_util:err_json(Req, 403, <<"blocked_url">>);
                {error, _} -> pw_util:err_json(Req, 502, <<"embed_failed">>)
            end
    end;
authed(<<"GET">>, [<<"messages">>], Req, Session, _) -> result(Req, pw_db:messages(uid(Session), qs(Req, <<"scope">>), qs(Req, <<"scope_id">>), qs(Req, <<"before">>), qs(Req, <<"after">>)));
authed(<<"POST">>, [<<"channels">>, Id, <<"messages">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:post_channel_message(uid(Session), Id, maps:get(<<"body">>,M,<<>>), maps:get(<<"reply_to_id">>,M,undefined))) end);
authed(<<"POST">>, [<<"delete_message">>, MsgId], Req, Session, _) -> result(Req, pw_db:delete_message(uid(Session), MsgId));
authed(<<"GET">>, [<<"conversations">>], Req, Session, _) -> result(Req, pw_db:conversations(uid(Session)));
authed(<<"POST">>, [<<"conversations">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_conversation(uid(Session), maps:get(<<"name">>,M,<<>>), maps:get(<<"user_ids">>,M,[]))) end);
authed(<<"GET">>, [<<"conversation">>, Id], Req, Session, _) -> result(Req, pw_db:conversation(uid(Session), Id));
authed(<<"POST">>, [<<"conversation">>, Id], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_conversation(uid(Session), Id, maps:get(<<"name">>,M,<<>>), M)) end);
authed(<<"POST">>, [<<"conversation">>, Id, <<"members">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:add_conversation_members(uid(Session), Id, maps:get(<<"user_ids">>,M,[]))) end);
authed(<<"POST">>, [<<"conversation">>, Id, <<"read">>], Req, Session, _) -> result(Req, pw_db:mark_conversation_read(uid(Session), Id));
authed(<<"POST">>, [<<"conversation">>, Id, <<"messages">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:post_direct_message(uid(Session), Id, maps:get(<<"body">>,M,<<>>), maps:get(<<"reply_to_id">>,M,undefined))) end);
authed(<<"POST">>, [<<"conversation">>, Id, <<"leave">>], Req, Session, _) -> result(Req, pw_db:leave_conversation(uid(Session), Id));
authed(<<"GET">>, [<<"notifications">>], Req, Session, _) -> result(Req, pw_db:notifications(uid(Session)));
authed(<<"POST">>, [<<"notifications">>, <<"seen">>], Req, Session, _) -> result(Req, pw_db:mark_notifications_seen(uid(Session)));
authed(_, _, Req, _, _) -> pw_util:err_json(Req, 404, <<"not_found">>).

with_json_public(Req0, Fun) ->
    case pw_util:read_json(Req0) of
        {ok, M, Req} -> Fun(M, Req);
        {error, too_large, Req} -> pw_util:err_json(Req, 413, <<"body_too_large">>);
        {error, _, Req} -> pw_util:err_json(Req, 400, <<"invalid_json">>)
    end.
with_json(Req0, Fun) -> with_json_public(Req0, Fun).

result(Req, {ok, Data}) -> pw_util:ok_json(Req, #{ok=>true,data=>Data});
result(Req, ok) -> pw_util:ok_json(Req, #{ok=>true});
result(Req, {error, database_unavailable}) -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
result(Req, {error, timeout}) -> pw_util:err_json(Req, 503, <<"database_timeout">>);
result(Req, {error, forbidden}) -> pw_util:err_json(Req, 403, <<"forbidden">>);
result(Req, {error, not_found}) -> pw_util:err_json(Req, 404, <<"not_found">>);
result(Req, {error, E}) when is_atom(E) -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8));
result(Req, {error, E}) -> pw_util:err_json(Req, 400, pw_util:bin(E));
result(Req, Other) -> pw_util:ok_json(Req, #{ok=>true,data=>Other}).
