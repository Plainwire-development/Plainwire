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
route_bucket([First | _]) ->
    %% The bucket becomes part of an ETS rate-limit key. Never let arbitrary 404
    %% path components create unbounded attacker-controlled key cardinality.
    case lists:member(First, [
        <<"register">>, <<"login">>, <<"system">>, <<"webhooks">>, <<"bot">>,
        <<"health">>, <<"version">>, <<"apps">>, <<"me">>, <<"rtc-config">>,
        <<"voice-processing-config">>, <<"logout">>, <<"sessions">>, <<"password">>,
        <<"email">>, <<"account">>, <<"sync">>, <<"profile">>, <<"notifications">>, <<"forums">>,
        <<"forum">>, <<"servers">>, <<"server">>, <<"channels">>, <<"messages">>,
        <<"conversation">>, <<"search">>, <<"friends">>, <<"friend">>, <<"users">>,
        <<"uploads">>, <<"files">>, <<"github">>, <<"klipy">>, <<"developer">>
    ]) of
        true -> First;
        false -> other
    end.

api_path(Path) ->
    Segs = [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>],
    case Segs of [<<"api">>|Rest] -> Rest; _ -> Segs end.
qs(Req, Key) -> proplists:get_value(Key, cowboy_req:parse_qs(Req)).

auth_attempt_allowed(Kind, Req, Username0) ->
    Username = pw_util:normalize_username(Username0),
    Ip = pw_util:ip(Req),
    pw_rate:allow_shared({Kind, ip, Ip}, 30, 600000) andalso
        pw_rate:allow_shared({Kind, username, Username}, 12, 600000) andalso
        pw_rate:allow_shared({Kind, pair, Ip, Username}, 8, 600000).

handle(<<"POST">>, [<<"register">>], Req0, _) ->
    case pw_client_config:registration_enabled() of
        false ->
            pw_util:err_json(Req0, 403, <<"registration_disabled">>);
        true ->
            with_json_public(Req0, fun(M, Req) ->
                U = maps:get(<<"username">>, M, <<>>),
                D = maps:get(<<"display_name">>, M, U),
                P = maps:get(<<"password">>, M, <<>>),
                Email = maps:get(<<"email">>, M, <<>>),
                case auth_attempt_allowed(register, Req, U) of
                    false ->
                        pw_util:err_json(Req, 429, <<"rate_limited">>);
                    true ->
                        case pw_db:register(U, D, P, Email) of
                            {ok, #{token := Token} = Data} ->
                                Public = maps:remove(token, maybe_dispatch_mail(Data)),
                                pw_util:ok_json(
                                    pw_util:set_cookie(Req, <<"pw_session">>, Token),
                                    #{ok => true, data => Public}
                                );
                            {error, username_taken} -> pw_util:err_json(Req, 409, <<"username_taken">>);
                            {error, invalid_email} -> pw_util:err_json(Req, 400, <<"invalid_email">>);
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
                    {error, {account_restricted, Restriction}} ->
                        pw_util:json_reply(Req, 403, #{ok => false, error => <<"account_restricted">>, data => Restriction});
                    {error,E} -> pw_util:err_json(Req, 401, atom_to_binary(E, utf8))
                end
        end
    end);
handle(<<"POST">>, [<<"password">>, <<"forgot">>], Req0, _) ->
    with_json_public(Req0, fun(M, Req) ->
        Identity = maps:get(<<"username">>, M, maps:get(<<"email">>, M, maps:get(<<"identity">>, M, <<>>))),
        IdentityKey = case pw_util:normalize_email(Identity) of
            <<>> -> pw_util:normalize_username(Identity);
            NormalizedEmail -> NormalizedEmail
        end,
        case pw_rate:allow_shared({password_forgot, ip, pw_util:ip(Req)}, 8, 600000) andalso
             pw_rate:allow_shared({password_forgot, identity, IdentityKey}, 4, 600000) of
            false -> pw_util:err_json(Req, 429, <<"rate_limited">>);
            true ->
                case pw_db:request_password_reset(Identity) of
                    {ok, Data} ->
                        Public = maybe_dispatch_mail(Data, async),
                        pw_util:ok_json(Req, #{ok => true, data => maps:with([accepted], Public#{accepted => true})});
                    {error, database_unavailable} -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
                    {error, database_busy} -> pw_util:err_json(Req, 503, <<"database_busy">>);
                    {error, timeout} -> pw_util:err_json(Req, 503, <<"database_timeout">>);
                    {error, _} -> pw_util:ok_json(Req, #{ok => true, data => #{accepted => true}})
                end
        end
    end);
handle(<<"POST">>, [<<"password">>, <<"reset">>], Req0, _) ->
    with_json_public(Req0, fun(M, Req) ->
        case pw_rate:allow_shared({password_reset, ip, pw_util:ip(Req)}, 12, 600000) of
            false -> pw_util:err_json(Req, 429, <<"rate_limited">>);
            true ->
                case pw_db:reset_password(maps:get(<<"token">>, M, <<>>), maps:get(<<"password">>, M, maps:get(<<"new_password">>, M, <<>>))) of
                    {ok, Data} -> pw_util:ok_json(Req, #{ok => true, data => Data});
                    {error, invalid_token} -> pw_util:err_json(Req, 400, <<"invalid_token">>);
                    {error, weak_password} -> pw_util:err_json(Req, 400, <<"weak_password">>);
                    {error, database_unavailable} -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
                    {error, database_busy} -> pw_util:err_json(Req, 503, <<"database_busy">>);
                    {error, timeout} -> pw_util:err_json(Req, 503, <<"database_timeout">>);
                    {error, E} -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8))
                end
        end
    end);
handle(<<"POST">>, [<<"email">>, <<"verify">>], Req0, _) ->
    with_json_public(Req0, fun(M, Req) ->
        case pw_rate:allow_shared({email_verify, ip, pw_util:ip(Req)}, 20, 600000) of
            false -> pw_util:err_json(Req, 429, <<"rate_limited">>);
            true ->
                case pw_db:verify_email_token(maps:get(<<"token">>, M, <<>>)) of
                    {ok, Data} -> pw_util:ok_json(Req, #{ok => true, data => Data});
                    {error, invalid_token} -> pw_util:err_json(Req, 400, <<"invalid_token">>);
                    {error, email_taken} -> pw_util:err_json(Req, 409, <<"email_taken">>);
                    {error, database_unavailable} -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
                    {error, database_busy} -> pw_util:err_json(Req, 503, <<"database_busy">>);
                    {error, timeout} -> pw_util:err_json(Req, 503, <<"database_timeout">>);
                    {error, E} -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8))
                end
        end
    end);
handle(<<"GET">>, [<<"system">>, <<"banners">>], Req0, _) ->
    case pw_db:global_banners() of
        {ok, Data} -> pw_util:ok_json(Req0, #{ok => true, data => Data});
        {error, database_busy} -> pw_util:err_json(Req0, 503, <<"database_busy">>);
        {error, database_unavailable} -> pw_util:err_json(Req0, 503, <<"database_unavailable">>);
        _ -> pw_util:err_json(Req0, 500, <<"internal_error">>)
    end;
handle(<<"GET">>, [<<"version">>], Req0, _) ->
    pw_util:ok_json(Req0, #{ok => true, data => #{
        name => <<"Plainwire">>,
        version => pw_client_config:version(),
        asset_version => pw_client_config:asset_version(),
        api_version => 1
    }});
handle(<<"GET">>, [<<"apps">>], Req0, _) ->
    %% Public application directory. Only install-facing metadata is returned;
    %% developer identity, credentials and connector configuration remain private.
    result(Req0, pw_db:public_developer_apps(qs(Req0, <<"q">>), qs(Req0, <<"limit">>)));
handle(<<"GET">>, [<<"apps">>, PublicId], Req0, _) ->
    %% Public application cards contain only install-facing metadata. Secrets,
    %% owner ids and raw upload/source references never cross this boundary.
    result(Req0, pw_db:public_developer_app(PublicId));
%% public gets alive/dead; signed-in users get the nerdy bits.
handle(<<"POST">>, [<<"webhooks">>, WebhookId, Token], Req0, _) ->
    Ip = pw_util:ip(Req0),
    case pw_rate:allow_shared({incoming_webhook, WebhookId}, 300, 60000) andalso
         pw_rate:allow_shared({incoming_webhook, WebhookId, Ip}, 60, 60000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true -> with_json_public(Req0, fun(M, Req) ->
            case pw_db:execute_incoming_webhook(WebhookId, Token, maps:get(<<"content">>, M, maps:get(<<"body">>, M, <<>>)), maps:get(<<"reply_to_id">>, M, undefined)) of
                {ok, Data} -> pw_util:ok_json(Req, #{ok => true, data => Data});
                {error, invalid_webhook_token} -> pw_util:err_json(Req, 404, <<"not_found">>);
                Other -> result(Req, Other)
            end
        end)
    end;
handle(Method, [<<"bot">>, <<"v1">> | Rest], Req0, _) ->
    handle_bot_v1(Method, Rest, Req0);
handle(<<"GET">>, [<<"bot">>, <<"me">>], Req0, _) ->
    with_bot(Req0, fun(Bot, Req) -> pw_util:ok_json(Req, #{ok => true, data => Bot}) end);
handle(<<"GET">>, [<<"bot">>, <<"server">>], Req0, _) ->
    with_bot(Req0, fun(Bot, Req) ->
        case pw_db:server(maps:get(user_id, Bot), maps:get(server_id, Bot)) of
            {ok, Data} ->
                %% Bot applications do not need the full server member directory
                %% for basic operation. Keep this endpoint intentionally narrow.
                Public = maps:with([server, channels, categories], Data),
                pw_util:ok_json(Req, #{ok => true, data => Public});
            {error, E} -> pw_util:err_json(Req, 403, atom_to_binary(E, utf8))
        end
    end);
handle(<<"GET">>, [<<"bot">>, <<"channels">>], Req0, _) ->
    with_bot(Req0, fun(Bot, Req) ->
        case pw_db:server(maps:get(user_id, Bot), maps:get(server_id, Bot)) of
            {ok, #{channels := Channels}} -> pw_util:ok_json(Req, #{ok => true, data => Channels});
            {error, E} -> pw_util:err_json(Req, 403, atom_to_binary(E, utf8))
        end
    end);
handle(<<"GET">>, [<<"bot">>, <<"channels">>, ChannelId, <<"messages">>], Req0, _) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>);
            true -> result(Req, pw_db:messages(maps:get(user_id, Bot), <<"channel">>, ChannelId, qs(Req, <<"before">>), qs(Req, <<"after">>)))
        end
    end);
handle(<<"POST">>, [<<"bot">>, <<"channels">>, ChannelId, <<"messages">>], Req0, _) ->
    with_bot(Req0, fun(Bot, Req1) ->
        BotUid = maps:get(user_id, Bot),
        case bot_rate_allow(Bot, message) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:bot_post_channel_message(BotUid, ChannelId, maps:get(<<"body">>, M, <<>>), maps:get(<<"reply_to_id">>, M, undefined)))
            end)
        end
    end);
handle(<<"POST">>, [<<"bot">>, <<"messages">>, MessageId, <<"delete">>], Req0, _) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>);
            true -> result(Req, pw_db:delete_message(maps:get(user_id, Bot), MessageId))
        end
    end);
handle(<<"POST">>, [<<"bot">>, <<"messages">>, MessageId, <<"reaction">>], Req0, _) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:toggle_message_reaction(maps:get(user_id, Bot), MessageId, maps:get(<<"emoji">>, M, <<>>)))
            end)
        end
    end);
handle(<<"GET">>, [<<"health">>], Req0, _) ->
    case pw_db:health() of
        {ok, Data} ->
            Body = case auth(Req0) of
                {ok, _} ->
                    Storage = pw_storage_health:snapshot(),
                    Data#{app => ok,
                        schedulers => erlang:system_info(schedulers_online),
                        processes => erlang:system_info(process_count),
                        process_limit => erlang:system_info(process_limit),
                        rate_limiter => pw_rate:stats(),
                        realtime => realtime_health(),
                        async_workers => pw_async_pool:stats(),
                        storage => Storage,
                        redis => maps:get(redis, Storage)};
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
authed(<<"POST">>, [<<"email">>], Req0, Session, _) ->
    Uid = uid(Session),
    case pw_rate:allow({account_email, Uid}, 8, 600000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true ->
            with_json(Req0, fun(M, Req) ->
                case pw_db:set_account_email(Uid, maps:get(<<"email">>, M, <<>>), maps:get(<<"password">>, M, maps:get(<<"current_password">>, M, <<>>))) of
                    {ok, Data} -> result(Req, {ok, maybe_dispatch_mail(Data)});
                    Other -> result(Req, Other)
                end
            end)
    end;
authed(<<"POST">>, [<<"email">>, <<"resend">>], Req0, Session, _) ->
    Uid = uid(Session),
    case pw_rate:allow({account_email_resend, Uid}, 4, 600000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true ->
            case pw_db:resend_email_verification(Uid) of
                {ok, Data} -> result(Req0, {ok, maybe_dispatch_mail(Data)});
                Other -> result(Req0, Other)
            end
    end;
authed(<<"POST">>, [<<"email">>, <<"remove">>], Req0, Session, _) ->
    Uid = uid(Session),
    case pw_rate:allow({account_email_remove, Uid}, 6, 600000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true ->
            with_json(Req0, fun(M, Req) ->
                result(Req, pw_db:remove_account_email(Uid, maps:get(<<"password">>, M, maps:get(<<"current_password">>, M, <<>>))))
            end)
    end;
authed(<<"POST">>, [<<"account">>, <<"disable">>], Req0, Session, _) ->
    Uid = uid(Session),
    case pw_rate:allow_shared({account_disable, Uid}, 4, 3600000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true -> with_json(Req0, fun(M, Req) ->
            case pw_db:disable_account(Uid, maps:get(<<"password">>, M, <<>>)) of
                {ok, Data} -> pw_util:ok_json(pw_util:clear_cookie(Req), #{ok => true, data => Data});
                {error, bad_password} -> pw_util:err_json(Req, 401, <<"bad_password">>);
                {error, E} -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8))
            end
        end)
    end;
authed(<<"POST">>, [<<"account">>, <<"delete">>], Req0, Session, _) ->
    Uid = uid(Session),
    case pw_rate:allow_shared({account_delete, Uid}, 3, 3600000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true -> with_json(Req0, fun(M, Req) ->
            case pw_db:delete_account(Uid, maps:get(<<"password">>, M, <<>>)) of
                {ok, Data} -> pw_util:ok_json(pw_util:clear_cookie(Req), #{ok => true, data => Data});
                {error, bad_password} -> pw_util:err_json(Req, 401, <<"bad_password">>);
                {error, E} -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8))
            end
        end)
    end;
authed(<<"POST">>, [<<"username">>], Req0, Session, _) ->
    Uid = uid(Session),
    case pw_rate:allow({username_change, Uid}, 5, 3600000) of
        false -> pw_util:err_json(Req0, 429, <<"rate_limited">>);
        true ->
            with_json(Req0, fun(M, Req) ->
                result(Req, pw_db:change_username(Uid, maps:get(<<"current_password">>, M, <<>>), maps:get(<<"username">>, M, <<>>), maps:get(<<"expected_username">>, M, <<>>)))
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
authed(<<"POST">>, [<<"server">>, Id, <<"member">>, UserId, <<"ban">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:ban_server_member(uid(Session), Id, UserId, maps:get(<<"reason">>, M, <<>>))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"member">>, UserId, <<"unban">>], Req, Session, _) ->
    result(Req, pw_db:unban_server_member(uid(Session), Id, UserId));
authed(<<"GET">>, [<<"server">>, Id, <<"bans">>], Req, Session, _) ->
    result(Req, pw_db:server_bans(uid(Session), Id));
authed(<<"GET">>, [<<"developer">>, <<"permissions">>], Req, _Session, _) ->
    pw_util:ok_json(Req, #{ok => true, data => pw_permissions:catalog()});
authed(<<"GET">>, [<<"developer">>, <<"apps">>], Req, Session, _) ->
    result(Req, pw_db:developer_apps(uid(Session)));
authed(<<"POST">>, [<<"developer">>, <<"apps">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_developer_app(uid(Session), maps:get(<<"name">>, M, <<>>))) end);
authed(<<"GET">>, [<<"developer">>, <<"apps">>, AppId], Req, Session, _) ->
    result(Req, pw_db:developer_app(uid(Session), AppId));
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId], Req0, Session, _) ->
    with_json_large(Req0, fun(M, Req) -> result(Req, pw_db:update_developer_app(uid(Session), AppId, M)) end);
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"delete">>], Req, Session, _) ->
    result(Req, pw_db:delete_developer_app(uid(Session), AppId));
authed(<<"GET">>, [<<"developer">>, <<"apps">>, AppId, <<"installations">>], Req, Session, _) ->
    result(Req, pw_db:developer_app_installations(uid(Session), AppId));
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"install">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:install_developer_app(uid(Session), AppId, maps:get(<<"server_id">>, M, undefined))) end);
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"installation">>, InstallationId, <<"rotate">>], Req, Session, _) ->
    result(Req, pw_db:rotate_developer_app_installation(uid(Session), AppId, InstallationId));
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"installation">>, InstallationId, <<"uninstall">>], Req, Session, _) ->
    result(Req, pw_db:uninstall_developer_app(uid(Session), AppId, InstallationId));
authed(<<"GET">>, [<<"developer">>, <<"apps">>, AppId, <<"commands">>], Req, Session, _) ->
    result(Req, pw_db:developer_app_commands(uid(Session), AppId));
authed(<<"GET">>, [<<"developer">>, <<"apps">>, AppId, <<"activity">>], Req, Session, _) ->
    result(Req, pw_db:developer_app_activity(uid(Session), AppId, qs(Req, <<"limit">>)));
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"commands">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) ->
        result(Req, pw_db:upsert_developer_app_command(uid(Session), AppId,
            maps:get(<<"name">>, M, <<>>), maps:get(<<"description">>, M, <<>>),
            maps:get(<<"options">>, M, []), maps:get(<<"handler">>, M, <<"queue">>)))
    end);
authed(<<"DELETE">>, [<<"developer">>, <<"apps">>, AppId, <<"commands">>, CommandId], Req, Session, _) ->
    result(Req, pw_db:delete_developer_app_command(uid(Session), AppId, CommandId));
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"interactions">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_developer_app_interactions(uid(Session), AppId, M)) end);
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"interactions">>, <<"rotate">>], Req, Session, _) ->
    result(Req, pw_db:rotate_developer_app_interaction_secret(uid(Session), AppId));
authed(<<"POST">>, [<<"developer">>, <<"apps">>, AppId, <<"ai">>], Req0, Session, _) ->
    with_json_large(Req0, fun(M, Req) -> result(Req, pw_db:update_developer_app_ai(uid(Session), AppId, M)) end);
authed(<<"GET">>, [<<"server">>, Id, <<"apps">>], Req, Session, _) ->
    result(Req, pw_db:server_apps(uid(Session), Id));
authed(<<"GET">>, [<<"server">>, Id, <<"app">>, InstallationId, <<"commands">>], Req, Session, _) ->
    result(Req, pw_db:server_app_commands(uid(Session), Id, InstallationId));
authed(<<"POST">>, [<<"server">>, Id, <<"app">>, InstallationId, <<"command">>, CommandId, <<"permissions">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) ->
        result(Req, pw_db:set_server_command_permissions(uid(Session), Id, InstallationId, CommandId, maps:get(<<"permissions">>, M, [])))
    end);
authed(<<"POST">>, [<<"server">>, Id, <<"app">>, InstallationId, <<"uninstall">>], Req, Session, _) ->
    result(Req, pw_db:uninstall_server_app(uid(Session), Id, InstallationId));
authed(<<"POST">>, [<<"apps">>, PublicId, <<"install">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:install_public_developer_app(uid(Session), PublicId, maps:get(<<"server_id">>, M, undefined))) end);
authed(<<"GET">>, [<<"server">>, Id, <<"webhooks">>], Req, Session, _) ->
    result(Req, pw_db:server_webhooks(uid(Session), Id));
authed(<<"POST">>, [<<"server">>, Id, <<"webhooks">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_server_webhook(uid(Session), Id, maps:get(<<"name">>, M, <<>>), maps:get(<<"url">>, M, <<>>), maps:get(<<"events">>, M, []))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"webhook">>, WebhookId], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_server_webhook(uid(Session), Id, WebhookId, M, maps:get(<<"updated_at">>, M, 0))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"webhook">>, WebhookId, <<"delete">>], Req, Session, _) ->
    result(Req, pw_db:delete_server_webhook(uid(Session), Id, WebhookId));
authed(<<"POST">>, [<<"server">>, Id, <<"webhook">>, WebhookId, <<"rotate">>], Req, Session, _) ->
    result(Req, pw_db:rotate_server_webhook(uid(Session), Id, WebhookId));
authed(<<"POST">>, [<<"server">>, Id, <<"webhook">>, WebhookId, <<"test">>], Req, Session, _) ->
    result(Req, pw_db:test_server_webhook(uid(Session), Id, WebhookId));
authed(<<"GET">>, [<<"server">>, Id, <<"webhook">>, WebhookId, <<"deliveries">>], Req, Session, _) ->
    result(Req, pw_db:server_webhook_deliveries(uid(Session), Id, WebhookId, qs(Req, <<"limit">>)));
authed(<<"POST">>, [<<"server">>, Id, <<"webhook">>, WebhookId, <<"delivery">>, DeliveryId, <<"retry">>], Req, Session, _) ->
    result(Req, pw_db:retry_server_webhook_delivery(uid(Session), Id, WebhookId, DeliveryId));
authed(<<"GET">>, [<<"server">>, Id, <<"incoming-webhooks">>], Req, Session, _) ->
    result(Req, pw_db:incoming_webhooks(uid(Session), Id));
authed(<<"POST">>, [<<"server">>, Id, <<"incoming-webhooks">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_incoming_webhook(uid(Session), Id, maps:get(<<"channel_id">>,M,undefined), maps:get(<<"name">>,M,<<>>))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"incoming-webhook">>, WebhookId, <<"rotate">>], Req, Session, _) ->
    result(Req, pw_db:rotate_incoming_webhook(uid(Session), Id, WebhookId));
authed(<<"POST">>, [<<"server">>, Id, <<"incoming-webhook">>, WebhookId, <<"delete">>], Req, Session, _) ->
    result(Req, pw_db:delete_incoming_webhook(uid(Session), Id, WebhookId));
authed(<<"GET">>, [<<"server">>, Id, <<"bots">>], Req, Session, _) ->
    result(Req, pw_db:server_bots(uid(Session), Id));
authed(<<"POST">>, [<<"server">>, Id, <<"bots">>], Req0, Session, _) ->
    with_json(Req0, fun(M, Req) -> result(Req, pw_db:create_server_bot(uid(Session), Id, maps:get(<<"name">>, M, <<>>))) end);
authed(<<"POST">>, [<<"server">>, Id, <<"bot">>, BotId, <<"rotate">>], Req, Session, _) ->
    result(Req, pw_db:rotate_server_bot(uid(Session), Id, BotId));
authed(<<"POST">>, [<<"server">>, Id, <<"bot">>, BotId, <<"delete">>], Req, Session, _) ->
    result(Req, pw_db:delete_server_bot(uid(Session), Id, BotId));
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
authed(<<"POST">>, [<<"channel">>, ChannelId, <<"settings">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:update_channel_settings(uid(Session), ChannelId, M)) end);
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
authed(<<"GET">>, [<<"development">>, <<"overview">>], Req, Session, _) ->
    github_request(Req, Session, fun pw_github:overview/0);
authed(<<"GET">>, [<<"development">>, <<"repository">>], Req, Session, _) ->
    github_request(Req, Session, fun() -> pw_github:repository(qs(Req, <<"repo">>)) end);
authed(<<"GET">>, [<<"development">>, <<"commit">>], Req, Session, _) ->
    github_request(Req, Session, fun() -> pw_github:commit(qs(Req, <<"repo">>), qs(Req, <<"sha">>)) end);
authed(<<"GET">>, [<<"development">>, <<"profile">>], Req, Session, _) ->
    github_request(Req, Session, fun() -> pw_github:profile(qs(Req, <<"login">>)) end);
authed(<<"GET">>, [<<"development">>, <<"content">>], Req, Session, _) ->
    github_request(Req, Session, fun() -> pw_github:content(qs(Req, <<"repo">>), qs(Req, <<"path">>), qs(Req, <<"ref">>)) end);
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
authed(<<"GET">>, [<<"message">>, MsgId, <<"context">>], Req, Session, _) ->
    result(Req, pw_db:message_context(uid(Session), MsgId));
authed(<<"GET">>, [<<"channel">>, ChannelId, <<"pins">>], Req, Session, _) ->
    result(Req, pw_db:channel_pins(uid(Session), ChannelId));
authed(<<"POST">>, [<<"message">>, MsgId, <<"pin">>], Req0, Session, _) ->
    case pw_rate:allow_shared({message_pin, uid(Session)}, 120, 60000) of
        false -> pw_util:err_json(Req0, 429, <<"pin_rate_limited">>);
        true -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:set_message_pin(uid(Session), MsgId, maps:get(<<"pinned">>, M, true))) end)
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
authed(<<"GET">>, [<<"search">>, <<"messages">>], Req, Session, _) ->
    case pw_rate:allow_shared({message_search, uid(Session)}, 60, 60000) of
        false -> pw_util:err_json(Req, 429, <<"search_rate_limited">>);
        true -> result(Req, pw_db:search_messages(uid(Session), qs(Req, <<"q">>), qs(Req, <<"before">>), qs(Req, <<"limit">>)))
    end;
authed(<<"GET">>, [<<"commands">>], Req, Session, _) ->
    result(Req, pw_db:commands_for_channel(uid(Session), qs(Req, <<"channel_id">>)));
authed(<<"POST">>, [<<"commands">>, Name, <<"invoke">>], Req0, Session, _) ->
    case pw_rate:allow_shared({command_invoke, uid(Session)}, 90, 60000) of
        false -> pw_util:err_json(Req0, 429, <<"command_rate_limited">>);
        true -> with_json(Req0, fun(M, Req) ->
            result(Req, pw_db:invoke_bot_command(uid(Session), maps:get(<<"channel_id">>, M, undefined), Name, invoke_command_args(M)))
        end)
    end;
authed(<<"GET">>, [<<"notifications">>], Req, Session, _) -> result(Req, pw_db:notifications(uid(Session)));
authed(<<"POST">>, [<<"notifications">>, <<"seen">>], Req, Session, _) -> result(Req, pw_db:mark_notifications_seen(uid(Session)));
authed(<<"POST">>, [<<"friends">>, <<"unblock">>], Req0, Session, _) -> with_json(Req0, fun(M, Req) -> result(Req, pw_db:friend_unblock(uid(Session), maps:get(<<"user_id">>,M,undefined))) end);
authed(_, _, Req, _, _) -> pw_util:err_json(Req, 404, <<"not_found">>).


handle_bot_v1(<<"GET">>, [], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        pw_util:ok_json(Req, #{ok => true, data => #{
            api => <<"plainwire-bot">>, version => 1, bot => Bot,
            authentication => <<"Authorization: Bot pwb_...">>, websocket => <<"/ws">>,
            features => [<<"messages">>, <<"message_editing">>, <<"reactions">>, <<"pins">>, <<"message_context">>,
                         <<"commands">>, <<"command_sync">>, <<"durable_command_claims">>, <<"renewable_command_claims">>,
                         <<"typed_command_options">>, <<"realtime_events">>, <<"members">>, <<"paginated_members">>,
                         <<"roles">>, <<"moderation">>, <<"channel_management">>, <<"wires">>, <<"ai_commands">>],
            command_claim => #{lease_ms => bot_command_lease_ms(), max_batch => 50, renewable => true, max_lease_ms => 120000},
            command_sync => #{max_commands => 100}, member_page => #{default_limit => 50, max_limit => 200},
            limits_per_minute => bot_limits()
        }})
    end);
handle_bot_v1(<<"GET">>, [<<"me">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) -> pw_util:ok_json(Req, #{ok => true, data => Bot#{is_bot => true, api_version => 1}}) end);
handle_bot_v1(<<"GET">>, [<<"server">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>);
            true ->
                case pw_db:bot_server(maps:get(user_id, Bot), maps:get(server_id, Bot)) of
                    {ok, Data} -> pw_util:ok_json(Req, #{ok => true, data => Data});
                    {error, E} -> pw_util:err_json(Req, 403, pw_util:bin(E))
                end
        end
    end);
handle_bot_v1(<<"GET">>, [<<"channels">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>);
            true ->
                case pw_db:bot_server(maps:get(user_id, Bot), maps:get(server_id, Bot)) of
                    {ok, #{channels := Channels}} -> pw_util:ok_json(Req, #{ok => true, data => Channels});
                    {error, E} -> pw_util:err_json(Req, 403, pw_util:bin(E))
                end
        end
    end);
handle_bot_v1(<<"POST">>, [<<"channels">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:create_channel(maps:get(user_id, Bot), maps:get(server_id, Bot),
                    maps:get(<<"name">>, M, <<>>), maps:get(<<"kind">>, M, <<"text">>), maps:get(<<"category_id">>, M, undefined)))
            end)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"channels">>, ChannelId, <<"messages">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:messages(maps:get(user_id, Bot), <<"channel">>, ChannelId, qs(Req, <<"before">>), qs(Req, <<"after">>)));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"channels">>, ChannelId, <<"messages">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, message) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:bot_post_channel_message(maps:get(user_id, Bot), ChannelId,
                    maps:get(<<"body">>, M, <<>>), maps:get(<<"reply_to_id">>, M, undefined)))
            end)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"messages">>, MessageId, <<"delete">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, mutation) of
            true -> result(Req, pw_db:delete_message(maps:get(user_id, Bot), MessageId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"messages">>, MessageId, <<"reaction">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:toggle_message_reaction(maps:get(user_id, Bot), MessageId, maps:get(<<"emoji">>, M, <<>>)))
            end)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"channels">>, ChannelId, <<"pins">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:channel_pins(maps:get(user_id, Bot), ChannelId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"messages">>, MessageId, <<"context">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:message_context(maps:get(user_id, Bot), MessageId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"messages">>, MessageId, <<"edit">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, message) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) -> result(Req, pw_db:edit_message(maps:get(user_id, Bot), MessageId, maps:get(<<"body">>, M, <<>>))) end)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"messages">>, MessageId, <<"pin">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) -> result(Req, pw_db:set_message_pin(maps:get(user_id, Bot), MessageId, maps:get(<<"pinned">>, M, true))) end)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"roles">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:server_roles(maps:get(user_id, Bot), maps:get(server_id, Bot)));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"roles">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:create_server_role(maps:get(user_id, Bot), maps:get(server_id, Bot), maps:get(<<"name">>, M, <<>>), M))
            end)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"roles">>, RoleId], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:update_server_role(maps:get(user_id, Bot), maps:get(server_id, Bot), RoleId, M))
            end)
        end
    end);
handle_bot_v1(<<"DELETE">>, [<<"roles">>, RoleId], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, mutation) of
            true -> result(Req, pw_db:delete_server_role(maps:get(user_id, Bot), maps:get(server_id, Bot), RoleId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"members">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:bot_members(maps:get(user_id, Bot), maps:get(server_id, Bot),
                qs(Req, <<"after">>), qs(Req, <<"limit">>)));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"members">>, UserId], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:server_member_profile(maps:get(user_id, Bot), maps:get(server_id, Bot), UserId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"members">>, UserId, <<"roles">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) -> result(Req, pw_db:set_server_member_roles(maps:get(user_id, Bot), maps:get(server_id, Bot), UserId, maps:get(<<"role_ids">>, M, []))) end)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"members">>, UserId, <<"kick">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, mutation) of
            true -> result(Req, pw_db:kick_server_member(maps:get(user_id, Bot), maps:get(server_id, Bot), UserId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"members">>, UserId, <<"ban">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) -> result(Req, pw_db:ban_server_member(maps:get(user_id, Bot), maps:get(server_id, Bot), UserId, maps:get(<<"reason">>, M, <<>>))) end)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"members">>, UserId, <<"unban">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, mutation) of
            true -> result(Req, pw_db:unban_server_member(maps:get(user_id, Bot), maps:get(server_id, Bot), UserId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"bans">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:server_bans(maps:get(user_id, Bot), maps:get(server_id, Bot)));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"channels">>, ChannelId, <<"settings">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) -> result(Req, pw_db:update_channel_settings(maps:get(user_id, Bot), ChannelId, M)) end)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"wires">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:list_invites(maps:get(user_id, Bot), maps:get(server_id, Bot)));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"wires">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:create_invite(maps:get(user_id, Bot), maps:get(server_id, Bot), maps:get(<<"channel_id">>, M, undefined), maps:get(<<"max_uses">>, M, 0), maps:get(<<"expires_in">>, M, 86400)))
            end)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"commands">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, read) of
            true -> result(Req, pw_db:bot_commands(maps:get(id, Bot)));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"commands">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:bot_register_command(maps:get(id, Bot), maps:get(<<"name">>, M, <<>>),
                    maps:get(<<"description">>, M, <<>>), maps:get(<<"options">>, M, [])))
            end)
        end
    end);
handle_bot_v1(<<"PUT">>, [<<"commands">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, mutation) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:bot_sync_commands(maps:get(id, Bot), maps:get(<<"commands">>, M, invalid)))
            end)
        end
    end);
handle_bot_v1(<<"DELETE">>, [<<"commands">>, CommandId], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, mutation) of
            true -> result(Req, pw_db:bot_delete_command(maps:get(id, Bot), CommandId));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"GET">>, [<<"commands">>, <<"claims">>], Req0) ->
    with_bot(Req0, fun(Bot, Req) ->
        case bot_rate_allow(Bot, command_claim) of
            true -> result(Req, pw_db:bot_claim_commands(maps:get(id, Bot), qs(Req, <<"limit">>)));
            false -> pw_util:err_json(Req, 429, <<"bot_rate_limited">>)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"commands">>, <<"claims">>, InvocationId, <<"defer">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, command_claim) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:bot_defer_command(maps:get(id, Bot), InvocationId,
                    maps:get(<<"claim_token">>, M, <<>>), maps:get(<<"lease_ms">>, M, bot_command_lease_ms())))
            end)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"commands">>, <<"claims">>, InvocationId, <<"respond">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, command_claim) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:bot_respond_command(maps:get(id, Bot), InvocationId,
                    maps:get(<<"claim_token">>, M, <<>>), maps:get(<<"body">>, M, <<>>)))
            end)
        end
    end);
handle_bot_v1(<<"POST">>, [<<"commands">>, <<"claims">>, InvocationId, <<"fail">>], Req0) ->
    with_bot(Req0, fun(Bot, Req1) ->
        case bot_rate_allow(Bot, command_claim) of
            false -> pw_util:err_json(Req1, 429, <<"bot_rate_limited">>);
            true -> with_json_public(Req1, fun(M, Req) ->
                result(Req, pw_db:bot_fail_command(maps:get(id, Bot), InvocationId,
                    maps:get(<<"claim_token">>, M, <<>>), maps:get(<<"reason">>, M, <<"command failed">>)))
            end)
        end
    end);
handle_bot_v1(_, _, Req0) -> pw_util:err_json(Req0, 404, <<"not_found">>).

bot_limits() -> #{
    read => bot_limit("PLAINWIRE_BOT_READ_PER_MINUTE", 1200, 60, 10000),
    message => bot_limit("PLAINWIRE_BOT_MESSAGE_PER_MINUTE", 300, 30, 3000),
    mutation => bot_limit("PLAINWIRE_BOT_MUTATION_PER_MINUTE", 600, 30, 5000),
    command_claim => bot_limit("PLAINWIRE_BOT_COMMAND_CLAIM_PER_MINUTE", 2400, 60, 20000)
}.

bot_limit(Name, Default, Min, Max) -> min(Max, max(Min, pw_util:env_int(Name, Default))).

bot_rate_allow(Bot, Kind) ->
    Limits = bot_limits(),
    Limit = maps:get(Kind, Limits),
    pw_rate:allow_shared({bot_api, Kind, maps:get(id, Bot)}, Limit, 60000).

bot_command_lease_ms() -> min(120000, max(5000, pw_util:env_int("PLAINWIRE_BOT_COMMAND_LEASE_MS", 30000))).

with_bot(Req0, Fun) ->
    case cowboy_req:header(<<"authorization">>, Req0) of
        <<"Bot ", Token/binary>> when byte_size(Token) >= 16, byte_size(Token) =< 256 ->
            case pw_db:authenticate_bot(Token) of
                {ok, Bot} -> Fun(Bot, Req0);
                _ -> pw_util:err_json(Req0, 401, <<"invalid_bot_token">>)
            end;
        <<"Bearer ", Token/binary>> when byte_size(Token) >= 16, byte_size(Token) =< 256 ->
            case pw_db:authenticate_bot(Token) of
                {ok, Bot} -> Fun(Bot, Req0);
                _ -> pw_util:err_json(Req0, 401, <<"invalid_bot_token">>)
            end;
        _ -> pw_util:err_json(Req0, 401, <<"bot_auth_required">>)
    end.

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


github_request(Req, Session, Fun) ->
    case pw_rate:allow({github_source, uid(Session)}, 90, 60000) of
        false -> pw_util:err_json(Req, 429, <<"source_rate_limited">>);
        true ->
            case Fun() of
                {ok, Data} -> pw_util:ok_json(Req, #{ok => true, data => Data});
                {error, not_found} -> pw_util:err_json(Req, 404, <<"source_not_found">>);
                {error, rate_limited} -> pw_util:err_json(Req, 503, <<"github_rate_limited">>);
                {error, invalid_repository} -> pw_util:err_json(Req, 400, <<"invalid_repository">>);
                {error, invalid_commit} -> pw_util:err_json(Req, 400, <<"invalid_commit">>);
                {error, invalid_profile} -> pw_util:err_json(Req, 400, <<"invalid_profile">>);
                {error, invalid_path} -> pw_util:err_json(Req, 400, <<"invalid_path">>);
                {error, invalid_ref} -> pw_util:err_json(Req, 400, <<"invalid_ref">>);
                {error, _} -> pw_util:err_json(Req, 502, <<"github_unavailable">>)
            end
    end.

realtime_health() ->
    Registry = pw_realtime_registry:stats(),
    HubQueue = case whereis(pw_hub) of
        Pid when is_pid(Pid) ->
            case process_info(Pid, [message_queue_len, memory, reductions]) of
                Info when is_list(Info) -> maps:from_list(Info);
                _ -> #{}
            end;
        _ -> #{}
    end,
    Registry#{hub => HubQueue,
              listener => listener_health(plainwire_http),
              cluster => pw_cluster:status()}.

listener_health(Ref) ->
    try ranch:info(Ref) of
        Info when is_map(Info) ->
            maps:with([status, active_connections, all_connections, max_connections, metrics], Info);
        _ -> #{status => unavailable}
    catch _:_ -> #{status => unavailable}
    end.

invoke_command_args(M) when is_map(M) ->
    case maps:get(<<"options">>, M, undefined) of
        Options when is_map(Options) -> Options;
        _ -> maps:get(<<"args">>, M, <<>>)
    end;
invoke_command_args(_) -> <<>>.

result(Req, {ok, Data}) -> pw_util:ok_json(Req, #{ok=>true,data=>Data});
result(Req, ok) -> pw_util:ok_json(Req, #{ok=>true});
result(Req, {error, database_unavailable}) -> pw_util:err_json(Req, 503, <<"database_unavailable">>);
result(Req, {error, database_busy}) -> pw_util:err_json(Req, 503, <<"database_busy">>);
result(Req, {error, timeout}) -> pw_util:err_json(Req, 503, <<"database_timeout">>);
result(Req, {error, internal_error}) -> pw_util:err_json(Req, 500, <<"internal_error">>);
result(Req, {error, forbidden}) -> pw_util:err_json(Req, 403, <<"forbidden">>);
result(Req, {error, username_changed_elsewhere}) -> pw_util:err_json(Req, 409, <<"username_changed_elsewhere">>);
result(Req, {error, email_taken}) -> pw_util:err_json(Req, 409, <<"email_taken">>);
result(Req, {error, bad_password}) -> pw_util:err_json(Req, 401, <<"bad_password">>);
result(Req, {error, not_found}) -> pw_util:err_json(Req, 404, <<"not_found">>);
result(Req, {error, {slowmode, Retry}}) -> pw_util:json_reply(Req, 429, #{ok => false, error => <<"slowmode">>, data => #{retry_after_seconds => Retry}});
result(Req, {error, E}) when is_atom(E) -> pw_util:err_json(Req, 400, atom_to_binary(E, utf8));
result(Req, {error, E}) -> pw_util:err_json(Req, 400, pw_util:bin(E));
result(Req, Other) -> pw_util:ok_json(Req, #{ok=>true,data=>Other}).

maybe_dispatch_mail(Data) -> maybe_dispatch_mail(Data, await).
maybe_dispatch_mail(Data, Mode) when is_map(Data), (Mode =:= await orelse Mode =:= async) ->
    case maps:take(mail, Data) of
        {Mail, Rest} ->
            Delivered = case Mode of
                async -> pw_mail:send(Mail) =:= ok;
                await -> pw_mail:deliver_now(Mail) =:= ok
            end,
            Rest#{email_delivery => Delivered};
        error -> Data
    end;
maybe_dispatch_mail(Data, _) -> Data.
