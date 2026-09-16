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
    pw_rate:allow({api, Ip, Method, route_bucket(Path)}, Limit, 60000).

route_bucket([]) -> root;
route_bucket([First | _]) -> First.

api_path(Path) ->
    Segs = [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>],
    case Segs of [<<"api">>|Rest] -> Rest; _ -> Segs end.
qs(Req, Key) -> proplists:get_value(Key, cowboy_req:parse_qs(Req)).

auth_attempt_allowed(Kind, Req, Username0) ->
    Username = pw_util:normalize_username(Username0),
    Ip = pw_util:ip(Req),
    pw_rate:allow({Kind, ip, Ip}, 30, 600000) andalso
        pw_rate:allow({Kind, username, Username}, 12, 600000) andalso
        pw_rate:allow({Kind, pair, Ip, Username}, 8, 600000).

handle(<<"POST">>, [<<"register">>], Req0, _) ->
    case pw_util:env_bool("PLAINWIRE_REGISTRATION_ENABLED", true) of
        false ->
            pw_util:err_json(Req0, 403, <<"registration_disabled">>);
        true ->
            with_json_public(Req0, fun(M, Req) ->
                U = maps:get(<<"username">>, M, <<>>),
                D = maps:get(<<"display_name">>, M, U),
                P = maps:get(<<"password">>, M, <<>>),
                case auth_attempt_allowed(register, Req, U) of
                    false ->
                        pw_util:err_json(Req, 429, <<"rate_limited">>);
                    true ->
                        case pw_db:register(U, D, P) of
                            {ok, #{token := Token} = Data} ->
                                pw_util:ok_json(
                                    pw_util:set_cookie(Req, <<"pw_session">>, Token),
                                    #{ok => true, data => maps:remove(token, Data)}
                                );
                            {error, username_taken} -> pw_util:err_json(Req, 409, <<"username_taken">>);
                            {error, database_unavailable} -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
                            {error, database_busy} -> pw_util:err_json(Req, 503, <<"database_busy">>);
                            {error, timeout} -> pw_util:err_json(Req, 503, <<"database_timeout">>);
                            {error, E} -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8))
                        end
                end
            end)
    end;
handle(<<"POST">>, [<<"login">>], Req0, _) ->
    with_json_public(Req0, fun(M, Req) ->
        U = maps:get(<<"username">>,M,<<>>),
        case auth_attempt_allowed(login, Req, U) of
            false ->
                pw_util:err_json(Req, 429, <<"rate_limited">>);
            true ->
                case pw_db:login(U, maps:get(<<"password">>,M,<<>>)) of
                    {ok, #{token:=Token}=Data} -> pw_util:ok_json(pw_util:set_cookie(Req, <<"pw_session">>, Token), #{ok=>true,data=>maps:remove(token,Data)});
                    {error, database_unavailable} -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
                    {error, database_busy} -> pw_util:err_json(Req, 503, <<"database_busy">>);
                    {error, timeout} -> pw_util:err_json(Req, 503, <<"database_timeout">>);
                    {error,E} -> pw_util:err_json(Req, 401, atom_to_binary(E, utf8))
                end
        end
    end);
handle(<<"GET">>, [<<"version">>], Req0, _) ->
    pw_util:ok_json(Req0, #{ok => true, data => #{
        name => <<"Plainwire">>,
        version => pw_client_config:version(),
        asset_version => pw_client_config:asset_version(),
        api_version => 1
    }});
%% public gets alive/dead; signed-in users get the nerdy bits.
handle(<<"GET">>, [<<"health">>], Req0, _) ->
    case pw_db:health() of
        {ok, Data} ->
            Body = case auth(Req0) of
                {ok, _} ->
                    Data#{app => ok,
                        schedulers => erlang:system_info(schedulers_online),
                        processes => erlang:system_info(process_count),
                        process_limit => erlang:system_info(process_limit),
                        rate_limiter => pw_rate:stats()};
                _ ->
                    #{app => ok, database => maps:get(database, Data, ok)}
            end,
            pw_util:ok_json(Req0, #{ok=>true, data=>Body});
        {error, _} -> pw_util:err_json(Req0, 503, <<"unhealthy">>)
    end;
handle(Method, Path, Req0, State) ->
    case auth(Req0) of
        {ok, Session} ->
            UserLimit = case Method of <<"GET">> -> 1200; _ -> 240 end,
            case pw_rate:allow({api_user, uid(Session), Method}, UserLimit, 60000) of
                false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
                true ->
                    case Method =:= <<"GET">> orelse pw_util:require_csrf(Req0, Session) of
                        true -> authed(Method, Path, Req0, Session, State);
                        false -> pw_util:err_json(Req0, 403, <<"bad_csrf">>)
                    end
            end;
        {error, database_unavailable} -> pw_util:err_json(Req0, 503, <<"database_unavailable">>);
        {error, database_busy} -> pw_util:err_json(Req0, 503, <<"database_busy">>);
        {error, timeout} -> pw_util:err_json(Req0, 503, <<"database_timeout">>);
        {error, internal_error} -> pw_util:err_json(Req0, 500, <<"internal_error">>);
        {error,_} -> pw_util:err_json(Req0, 401, <<"not_authenticated">>)
    end.

auth(Req) ->
    case pw_util:cookie_value(Req, <<"pw_session">>) of
        undefined -> {error, no_session};
        Token ->
            case pw_db:session_fast(Token) of
                {ok, Session} -> {ok, Session};
                _ -> pw_db:session(Token)
            end
    end.
uid(Session) -> maps:get(id, maps:get(user, Session)).

authed(<<"GET">>, [<<"me">>], Req, Session, _) -> pw_util:ok_json(Req, #{ok=>true,data=>Session});
authed(<<"GET">>, [<<"rtc-config">>], Req, Session, _) ->
    pw_util:ok_json(Req, #{ok=>true,data=>pw_rtc_config:get(uid(Session))});
authed(<<"GET">>, [<<"voice-processing-config">>], Req, _Session, _) ->
    pw_util:ok_json(Req, #{ok=>true,data=>pw_rtc_config:voice_processing()});
authed(<<"POST">>, [<<"logout">>], Req0, _, _) ->
    Token = pw_util:cookie_value(Req0, <<"pw_session">>),
    _ = case Token of undefined -> ok; _ -> pw_db:logout(Token) end,
    pw_util:ok_json(pw_util:clear_cookie(Req0), #{ok=>true});
authed(<<"GET">>, [<<"sessions">>], Req, Session, _) ->
    Token = pw_util:cookie_value(Req, <<"pw_session">>),
    result(Req, pw_db:sessions(uid(Session), Token));
authed(<<"POST">>, [<<"sessions">>, <<"logout-others">>], Req, Session, _) ->
    Token = pw_util:cookie_value(Req, <<"pw_session">>),
    result(Req, pw_db:logout_other_sessions(uid(Session), Token));
authed(<<"POST">>, [<<"password">>], Req0, Session, _) ->
    Uid = uid(Session),
    case pw_rate:allow({password_change, Uid}, 8, 600000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true ->
            Token = pw_util:cookie_value(Req0, <<"pw_session">>),
            with_json(Req0, fun(M, Req) ->
                result(Req, pw_db:change_password(Uid, Token, maps:get(<<"current_password">>, M, <<>>), maps:get(<<"new_password">>, M, <<>>)))
            end)
    end;
authed(<<"GET">>, [<<"sync">>], Req, Session, _) -> result(Req, pw_db:sync(uid(Session), qs(Req, <<"since">>)));
authed(<<"POST">>, [<<"profile">>], Req0, Session, _) -> with_json_large(Req0, fun(M, Req) -> result(Req, pw_db:update_profile(uid(Session), maps:get(<<"display_name">>, M, maps:get(display_name, maps:get(user,Session))), M)) end);
authed(<<"POST">>, [<<"profile">>, <<"theme">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_theme(uid(Session), maps:get(<<"theme">>, M, <<"system">>))) end);
authed(<<"POST">>, [<<"notifications">>, <<"clear">>], Req, Session, _) -> result(Req, pw_db:clear_notifications(uid(Session)));
authed(<<"GET">>, [<<"forums">>], Req, Session, _) -> result(Req, pw_db:forums(uid(Session)));
authed(<<"POST">>, [<<"forums">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_forum(uid(Session), maps:get(<<"name">>,M,<<>>), maps:get(<<"slug">>,M,<<>>), maps:get(<<"description">>,M,<<>>))) end);
authed(<<"POST">>, [<<"forum">>, Id, <<"join">>], Req, Session, _) -> result(Req, pw_db:join_forum(uid(Session), Id));
authed(<<"POST">>, [<<"forum">>, Id, <<"leave">>], Req, Session, _) -> result(Req, pw_db:leave_forum(uid(Session), Id));
authed(<<"POST">>, [<<"forum">>, Id, <<"delete">>], Req, Session, _) -> result(Req, pw_db:delete_forum(uid(Session), Id));
authed(<<"GET">>, [<<"threads">>], Req, Session, _) -> result(Req, pw_db:threads(uid(Session), qs(Req, <<"forum_id">>), qs(Req, <<"q">>)));
authed(<<"POST">>, [<<"threads">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_thread(uid(Session), maps:get(<<"forum_id">>,M,undefined), maps:get(<<"title">>,M,<<>>), maps:get(<<"body">>,M,<<>>))) end);
authed(<<"GET">>, [<<"thread">>, Id], Req, Session, _) -> result(Req, pw_db:thread(uid(Session), Id));
authed(<<"POST">>, [<<"thread">>, Id, <<"replies">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:reply_thread(uid(Session), Id, maps:get(<<"body">>,M,<<>>))) end);
authed(<<"POST">>, [<<"thread">>, Id, <<"vote">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:vote_thread(uid(Session), Id, maps:get(<<"value">>,M,0))) end);
authed(<<"POST">>, [<<"thread">>, Id, <<"edit">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:edit_thread(uid(Session), Id, maps:get(<<"title">>,M,<<>>), maps:get(<<"body">>,M,<<>>))) end);
authed(<<"POST">>, [<<"thread">>, Id, <<"moderate">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:moderate_thread(uid(Session), Id, maps:get(<<"action">>,M,<<>>), maps:get(<<"value">>,M,false))) end);
authed(<<"POST">>, [<<"thread">>, ThreadId, <<"reply">>, ReplyId, <<"edit">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:edit_reply(uid(Session), ThreadId, ReplyId, maps:get(<<"body">>,M,<<>>))) end);
authed(<<"POST">>, [<<"thread">>, ThreadId, <<"reply">>, ReplyId, <<"delete">>], Req, Session, _) ->
    result(Req, pw_db:delete_reply(uid(Session), ThreadId, ReplyId));
authed(<<"POST">>, [<<"thread">>, Id, <<"delete">>], Req, Session, _) -> result(Req, pw_db:delete_thread(uid(Session), Id));
authed(<<"GET">>, [<<"users">>], Req, _, _) -> result(Req, pw_db:users(qs(Req, <<"q">>)));
authed(<<"GET">>, [<<"profile">>, Id], Req, Session, _) -> result(Req, pw_db:profile(uid(Session), Id));
authed(<<"GET">>, [<<"profile-by-username">>], Req, Session, _) -> result(Req, pw_db:profile_by_username(uid(Session), qs(Req, <<"username">>)));
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
authed(<<"GET">>, [<<"server">>, Id, <<"permissions">>], Req, Session, _) -> result(Req, pw_db:server_permissions(uid(Session), Id));
authed(<<"POST">>, [<<"server">>, Id, <<"default-permissions">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_server_default_permissions(uid(Session), Id, maps:get(<<"permissions">>, M, 0))) end);
authed(<<"GET">>, [<<"server">>, Id, <<"roles">>], Req, Session, _) -> result(Req, pw_db:server_roles(uid(Session), Id));
authed(<<"POST">>, [<<"server">>, Id, <<"roles">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_server_role(uid(Session), Id, maps:get(<<"name">>,M,<<>>), M)) end);
authed(<<"POST">>, [<<"server">>, Id, <<"role">>, RoleId], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_server_role(uid(Session), Id, RoleId, M)) end);
authed(<<"POST">>, [<<"server">>, Id, <<"role">>, RoleId, <<"delete">>], Req, Session, _) ->
    result(Req, pw_db:delete_server_role(uid(Session), Id, RoleId));
authed(<<"POST">>, [<<"server">>, Id, <<"member">>, UserId, <<"roles">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:set_server_member_roles(uid(Session), Id, UserId, maps:get(<<"role_ids">>,M,[]))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"member">>, UserId, <<"kick">>], Req, Session, _) ->
    result(Req, pw_db:kick_server_member(uid(Session), Id, UserId));
authed(<<"GET">>, [<<"server">>, Id, <<"member">>, UserId, <<"profile">>], Req, Session, _) ->
    result(Req, pw_db:server_member_profile(uid(Session), Id, UserId));
authed(<<"POST">>, [<<"server">>, Id, <<"member">>, UserId, <<"profile">>], Req0, Session, _) ->
    with_json_large(Req0, fun(M, Req) -> result(Req, pw_db:update_server_member_profile(uid(Session), Id, UserId, M)) end);
authed(<<"POST">>, [<<"server">>, Id, <<"delete">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:delete_server(uid(Session), Id, maps:get(<<"confirm_name">>, M, <<>>))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"channels">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_channel(uid(Session), Id, maps:get(<<"name">>,M,<<>>), maps:get(<<"kind">>,M,<<"text">>), maps:get(<<"category_id">>,M,undefined))) end);
authed(<<"GET">>, [<<"server">>, Id, <<"categories">>], Req, Session, _) -> result(Req, pw_db:categories(uid(Session), Id));
authed(<<"POST">>, [<<"server">>, Id, <<"categories">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_category(uid(Session), Id, maps:get(<<"name">>,M,<<>>))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"category">>, CatId], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_category(uid(Session), Id, CatId, M)) end);
authed(<<"POST">>, [<<"server">>, Id, <<"categories">>, <<"reorder">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:reorder_categories(uid(Session), Id, maps:get(<<"order">>,M,[]))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"category">>, CatId, <<"delete">>], Req, Session, _) -> result(Req, pw_db:delete_category(uid(Session), Id, CatId));
authed(<<"POST">>, [<<"channel">>, ChannelId, <<"move">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:move_channel(uid(Session), ChannelId, maps:get(<<"category_id">>,M,undefined), maps:get(<<"position">>,M,undefined))) end);
authed(<<"GET">>, [<<"server">>, Id, <<"wires">>], Req, Session, _) -> result(Req, pw_db:list_invites(uid(Session), Id));
authed(<<"DELETE">>, [<<"server">>, Id, <<"wires">>, Code], Req, Session, _) -> result(Req, pw_db:revoke_invite(uid(Session), Id, Code));
authed(<<"POST">>, [<<"server">>, Id, <<"wires">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_invite(uid(Session), Id, maps:get(<<"channel_id">>,M,undefined), maps:get(<<"max_uses">>,M,0), maps:get(<<"expires_in">>,M,86400))) end);
authed(<<"POST">>, [<<"wires">>, Code, <<"join">>], Req, Session, _) -> result(Req, pw_db:join_invite(uid(Session), Code));
authed(<<"GET">>, [<<"wires">>, Code], Req, _, _) -> result(Req, pw_db:invite_preview(Code));
authed(<<"GET">>, [<<"server">>, Id, <<"invites">>], Req, Session, _) -> result(Req, pw_db:list_invites(uid(Session), Id));
authed(<<"DELETE">>, [<<"server">>, Id, <<"invites">>, Code], Req, Session, _) -> result(Req, pw_db:revoke_invite(uid(Session), Id, Code));
authed(<<"POST">>, [<<"server">>, Id, <<"invites">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_invite(uid(Session), Id, maps:get(<<"channel_id">>,M,undefined), maps:get(<<"max_uses">>,M,0), maps:get(<<"expires_in">>,M,86400))) end);
authed(<<"POST">>, [<<"invites">>, Code, <<"join">>], Req, Session, _) -> result(Req, pw_db:join_invite(uid(Session), Code));
authed(<<"GET">>, [<<"invites">>, Code], Req, _, _) -> result(Req, pw_db:invite_preview(Code));
authed(<<"GET">>, [<<"onboarding">>], Req, Session, _) ->
    result(Req, pw_db:onboarding(uid(Session)));
authed(<<"POST">>, [<<"onboarding">>, <<"start">>], Req, Session, _) ->
    result(Req, pw_db:start_onboarding(uid(Session)));
authed(<<"POST">>, [<<"onboarding">>, <<"progress">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_onboarding(uid(Session), maps:get(<<"step">>, M, -1))) end);
authed(<<"POST">>, [<<"onboarding">>, <<"complete">>], Req, Session, _) ->
    result(Req, pw_db:complete_onboarding(uid(Session)));
authed(<<"POST">>, [<<"onboarding">>, <<"dismiss">>], Req, Session, _) ->
    result(Req, pw_db:dismiss_onboarding(uid(Session)));
authed(<<"POST">>, [<<"onboarding">>, <<"replay">>], Req, Session, _) ->
    result(Req, pw_db:replay_onboarding(uid(Session)));
authed(<<"GET">>, [<<"gifs">>, <<"search">>], Req, Session, _) ->
    result(Req, pw_klipy:search(uid(Session), qs(Req, <<"q">>), qs(Req, <<"pos">>)));
authed(<<"POST">>, [<<"gifs">>, <<"share">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_klipy:register_share(uid(Session), maps:get(<<"id">>,M,<<>>), maps:get(<<"q">>,M,<<>>))) end);
authed(<<"GET">>, [<<"embed">>], Req, Session, _) ->
    case qs(Req, <<"url">>) of
        undefined -> pw_util:err_json(Req, 400, <<"missing_url">>);
        Url when byte_size(Url) > 2048 -> pw_util:err_json(Req, 414, <<"url_too_long">>);
        Url ->
            case pw_rate:allow({embed, uid(Session)}, 60, 60000) of
                false -> pw_util:err_json(Req, 429, <<"embed_rate_limited">>);
                true ->
                    case pw_embed:fetch(Url) of
                        {ok, Meta} -> pw_util:ok_json(Req, #{ok => true, data => Meta});
                        {error, blocked_url} -> pw_util:err_json(Req, 403, <<"blocked_url">>);
                        {error, _} -> pw_util:err_json(Req, 502, <<"embed_failed">>)
                    end
            end
    end;
authed(<<"GET">>, [<<"messages">>], Req, Session, _) -> result(Req, pw_db:messages(uid(Session), qs(Req, <<"scope">>), qs(Req, <<"scope_id">>), qs(Req, <<"before">>), qs(Req, <<"after">>)));
authed(<<"POST">>, [<<"channels">>, Id, <<"messages">>], Req0, Session, _) ->
    with_message_limit(Req0, uid(Session), fun(M, Req) -> result(Req, pw_db:post_channel_message(uid(Session), Id, maps:get(<<"body">>,M,<<>>), maps:get(<<"reply_to_id">>,M,undefined))) end);
authed(<<"POST">>, [<<"delete_message">>, MsgId], Req, Session, _) -> result(Req, pw_db:delete_message(uid(Session), MsgId));
authed(<<"POST">>, [<<"edit_message">>, MsgId], Req0, Session, _) ->
    with_message_limit(Req0, uid(Session), fun(M, Req) -> result(Req, pw_db:edit_message(uid(Session), MsgId, maps:get(<<"body">>, M, <<>>))) end);
authed(<<"POST">>, [<<"forward_message">>, MsgId], Req0, Session, _) ->
    with_message_limit(Req0, uid(Session), fun(M, Req) -> result(Req, pw_db:forward_message(uid(Session), MsgId, maps:get(<<"target_scope">>, M, <<>>), maps:get(<<"target_id">>, M, undefined))) end);
authed(<<"POST">>, [<<"message">>, MsgId, <<"reactions">>], Req0, Session, _) ->
    case pw_rate:allow({reaction, uid(Session)}, 180, 60000) of
        true -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:toggle_message_reaction(uid(Session), MsgId, maps:get(<<"emoji">>, M, <<>>))) end);
        false -> pw_util:err_json(Req0, 429, <<"reaction_rate_limited">>)
    end;
authed(<<"GET">>, [<<"conversations">>], Req, Session, _) -> result(Req, pw_db:conversations(uid(Session)));
authed(<<"POST">>, [<<"conversations">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) ->
    Name = maps:get(<<"name">>, M, <<>>),
    Result = case maps:get(<<"usernames">>, M, []) of
        Names when is_list(Names), Names =/= [] -> pw_db:create_conversation_usernames(uid(Session), Name, Names);
        _ -> pw_db:create_conversation(uid(Session), Name, maps:get(<<"user_ids">>, M, []))
    end,
    result(Req, Result)
end);
authed(<<"GET">>, [<<"conversation">>, Id], Req, Session, _) -> result(Req, pw_db:conversation(uid(Session), Id));
authed(<<"POST">>, [<<"conversation">>, Id], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_conversation(uid(Session), Id, maps:get(<<"name">>,M,<<>>), M)) end);
authed(<<"POST">>, [<<"conversation">>, Id, <<"members">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) ->
    Result = case maps:get(<<"usernames">>, M, []) of
        Names when is_list(Names), Names =/= [] -> pw_db:add_conversation_members_usernames(uid(Session), Id, Names);
        _ -> pw_db:add_conversation_members(uid(Session), Id, maps:get(<<"user_ids">>, M, []))
    end,
    result(Req, Result)
end);
authed(<<"POST">>, [<<"conversation">>, Id, <<"read">>], Req, Session, _) -> result(Req, pw_db:mark_conversation_read(uid(Session), Id));
authed(<<"POST">>, [<<"conversation">>, Id, <<"messages">>], Req0, Session, _) ->
    with_message_limit(Req0, uid(Session), fun(M, Req) -> result(Req, pw_db:post_direct_message(uid(Session), Id, maps:get(<<"body">>,M,<<>>), maps:get(<<"reply_to_id">>,M,undefined))) end);
authed(<<"POST">>, [<<"conversation">>, Id, <<"leave">>], Req, Session, _) -> result(Req, pw_db:leave_conversation(uid(Session), Id));
authed(<<"POST">>, [<<"conversation">>, Id, <<"close">>], Req, Session, _) -> result(Req, pw_db:close_conversation(uid(Session), Id));
authed(<<"POST">>, [<<"conversation">>, Id, <<"member">>, UserId, <<"role">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:set_conversation_member_role(uid(Session), Id, UserId, maps:get(<<"role">>,M,<<"member">>))) end);
authed(<<"POST">>, [<<"conversation">>, Id, <<"member">>, UserId, <<"kick">>], Req, Session, _) ->
    result(Req, pw_db:kick_conversation_member(uid(Session), Id, UserId));
authed(<<"POST">>, [<<"conversation">>, Id, <<"request">>, <<"accept">>], Req, Session, _) -> result(Req, pw_db:accept_message_request(uid(Session), Id));
authed(<<"POST">>, [<<"conversation">>, Id, <<"request">>, <<"deny">>], Req, Session, _) -> result(Req, pw_db:deny_message_request(uid(Session), Id));
authed(<<"GET">>, [<<"notifications">>], Req, Session, _) -> result(Req, pw_db:notifications(uid(Session)));
authed(<<"POST">>, [<<"notifications">>, <<"seen">>], Req, Session, _) -> result(Req, pw_db:mark_notifications_seen(uid(Session)));
authed(<<"POST">>, [<<"friends">>, <<"unblock">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:friend_unblock(uid(Session), maps:get(<<"user_id">>,M,undefined))) end);
authed(_, _, Req, _, _) -> pw_util:err_json(Req, 404, <<"not_found">>).

with_json_public(Req0, Fun) ->
    case pw_util:read_json(Req0) of
        {ok, M, Req} -> Fun(M, Req);
        {error, too_large, Req} -> pw_util:err_json(Req, 413, <<"body_too_large">>);
        {error, _, Req} -> pw_util:err_json(Req, 400, <<"invalid_json">>)
    end.
with_json(Req0, Fun) -> with_json_public(Req0, Fun).

with_message_limit(Req0, Uid, Fun) ->
    %% chat gets a tighter limit. bursts are fine; floods can go outside.
    case pw_rate:allow({message, Uid, burst}, 12, 5000) andalso
         pw_rate:allow({message, Uid, sustained}, 90, 60000) of
        true -> with_json(Req0, Fun);
        false -> pw_util:err_json(Req0, 429, <<"message_rate_limited">>)
    end.

with_json_large(Req0, Fun) ->
    %% two 8 MiB images balloon in base64. leave a little room for JSON.
    case pw_util:read_json(Req0, 25165824) of
        {ok, M, Req} -> Fun(M, Req);
        {error, too_large, Req} -> pw_util:err_json(Req, 413, <<"profile_images_too_large">>);
        {error, _, Req} -> pw_util:err_json(Req, 400, <<"invalid_json">>)
    end.

result(Req, {ok, Data}) -> pw_util:ok_json(Req, #{ok=>true,data=>Data});
result(Req, ok) -> pw_util:ok_json(Req, #{ok=>true});
result(Req, {error, database_unavailable}) -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
result(Req, {error, database_busy}) -> pw_util:err_json(Req, 503, <<"database_busy">>);
result(Req, {error, timeout}) -> pw_util:err_json(Req, 503, <<"database_timeout">>);
result(Req, {error, internal_error}) -> pw_util:err_json(Req, 500, <<"internal_error">>);
result(Req, {error, forbidden}) -> pw_util:err_json(Req, 403, <<"forbidden">>);
result(Req, {error, not_found}) -> pw_util:err_json(Req, 404, <<"not_found">>);
result(Req, {error, E}) when is_atom(E) -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8));
result(Req, {error, E}) -> pw_util:err_json(Req, 400, pw_util:bin(E));
result(Req, Other) -> pw_util:ok_json(Req, #{ok=>true,data=>Other}).
