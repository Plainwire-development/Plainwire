-module(pw_admin_api).
-behaviour(cowboy_handler).
-export([init/2]).

-define(MAX_BODY, 32768).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    Path = api_path(cowboy_req:path(Req0)),
    Ip = pw_util:ip(Req0),
    case pw_rate:allow({admin_http, Ip}, 600, 60000) of
        false -> reply_error(Req0, 429, <<"rate_limited">>, State);
        true -> dispatch(Method, Path, Req0, State)
    end.

api_path(Path) ->
    Parts = [P || P <- binary:split(Path, <<"/">>, [global]), P =/= <<>>],
    case Parts of [<<"api">> | Rest] -> Rest; _ -> Parts end.

dispatch(<<"GET">>, [<<"status">>], Req, State) ->
    reply_ok(Req, #{instance_id => pw_admin_identity:instance_id(),
                    bootstrap_available => pw_admin_identity:bootstrap_available(),
                    recovery_available => pw_admin_identity:recovery_available(),
                    privacy => privacy_contract()}, State);
dispatch(<<"POST">>, [<<"bootstrap">>], Req0, State) ->
    public_json(Req0, bootstrap, 5, fun(M, Req) ->
        Code = maps:get(<<"bootstrap_code">>, M, <<>>),
        Username = maps:get(<<"username">>, M, <<>>),
        Password = maps:get(<<"password">>, M, <<>>),
        case pw_admin_identity:claim_bootstrap(Code, Username, Password) of
            {ok, Data} -> reply_ok(Req, Data, State);
            Error -> reply_result(Req, Error, State)
        end
    end, State);
dispatch(<<"POST">>, [<<"recover">>], Req0, State) ->
    public_json(Req0, recovery, 3, fun(M, Req) ->
        Code = maps:get(<<"recovery_code">>, M, <<>>),
        Username = maps:get(<<"username">>, M, <<>>),
        Password = maps:get(<<"password">>, M, <<>>),
        case pw_admin_identity:claim_recovery(Code, Username, Password) of
            {ok, Data} -> reply_ok(clear_admin_cookie(Req), Data, State);
            Error -> reply_result(Req, Error, State)
        end
    end, State);
dispatch(<<"POST">>, [<<"login">>], Req0, State) ->
    public_json(Req0, login, 10, fun(M, Req) ->
        Username = maps:get(<<"username">>, M, <<>>),
        Password = maps:get(<<"password">>, M, <<>>),
        Key = pw_util:clean_text(maps:get(<<"verification_key">>, M, <<>>), 256),
        case valid_token(Key, <<"op">>) of
            false -> reply_error(Req, 401, <<"bad_login">>, State);
            true ->
                SessionToken = pw_util:random_token(32),
                SessionHash = pw_admin_identity:hash_secret(SessionToken),
                KeyHash = pw_admin_identity:hash_secret(Key),
                Csrf = pw_util:random_token(24),
                Expires = pw_util:now_ms() + session_ttl_ms(),
                IpHash = request_ip_hash(Req),
                UaHash = request_ua_hash(Req),
                case pw_db:admin_login(Username, Password, KeyHash, SessionHash, Csrf, Expires, IpHash, UaHash) of
                    {ok, Data} -> reply_ok(set_admin_cookie(Req, SessionToken), Data, State);
                    Error -> reply_result(Req, Error, State)
                end
        end
    end, State);
dispatch(<<"POST">>, [<<"enroll">>], Req0, State) ->
    public_json(Req0, enroll, 8, fun(M, Req) ->
        Username = maps:get(<<"username">>, M, <<>>),
        Password = maps:get(<<"password">>, M, <<>>),
        Enrollment = pw_util:clean_text(maps:get(<<"enrollment_code">>, M, <<>>), 256),
        case valid_token(Enrollment, <<"enroll">>) of
            false -> reply_error(Req, 400, <<"invalid_enrollment">>, State);
            true ->
                OperatorKey = pw_admin_identity:new_operator_key(),
                VerificationHash = pw_admin_identity:hash_secret(OperatorKey),
                EnrollmentHash = pw_admin_identity:hash_secret(Enrollment),
                SessionToken = pw_util:random_token(32),
                SessionHash = pw_admin_identity:hash_secret(SessionToken),
                Csrf = pw_util:random_token(24),
                Expires = pw_util:now_ms() + session_ttl_ms(),
                case pw_db:admin_redeem_enrollment(Username, Password, EnrollmentHash, VerificationHash,
                                                   SessionHash, Csrf, Expires, request_ip_hash(Req), request_ua_hash(Req)) of
                    {ok, Data} -> reply_ok(set_admin_cookie(Req, SessionToken), Data#{verification_key => OperatorKey}, State);
                    Error -> reply_result(Req, Error, State)
                end
        end
    end, State);
dispatch(Method, Path, Req0, State) ->
    case admin_session(Req0) of
        {error, _} -> reply_error(clear_admin_cookie(Req0), 401, <<"not_authenticated">>, State);
        {ok, Session, SessionHash} ->
            case Method =:= <<"GET">> orelse valid_csrf(Req0, Session) of
                false -> reply_error(Req0, 403, <<"bad_csrf">>, State);
                true -> authed(Method, Path, Req0, Session, SessionHash, State)
            end
    end.

authed(<<"GET">>, [<<"me">>], Req, Session, _Hash, State) ->
    reply_ok(Req, Session#{instance_id => pw_admin_identity:instance_id()}, State);
authed(<<"POST">>, [<<"logout">>], Req, _Session, Hash, State) ->
    _ = pw_db:admin_logout(Hash),
    reply_ok(clear_admin_cookie(Req), #{logged_out => true}, State);
authed(<<"GET">>, [<<"overview">>], Req, _Session, _Hash, State) ->
    case pw_db:admin_overview() of
        {ok, Data} -> reply_ok(Req, Data#{runtime => pw_admin_runtime:snapshot(), privacy => privacy_contract()}, State);
        Error -> reply_result(Req, Error, State)
    end;
authed(<<"GET">>, [<<"host">>], Req, _Session, _Hash, State) ->
    reply_ok(Req, pw_admin_runtime:snapshot(), State);
authed(<<"GET">>, [<<"users">>], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        reply_result(Req, pw_db:admin_users(qs(Req, <<"q">>, <<>>), qs(Req, <<"limit">>, <<"50">>), qs(Req, <<"offset">>, <<"0">>)), State)
    end, State);
authed(<<"GET">>, [<<"users">>, IdBin, <<"moderation">>], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        case positive_int(IdBin) of
            undefined -> reply_error(Req, 400, <<"invalid_user_id">>, State);
            Id -> reply_result(Req, pw_db:admin_user_moderation(maps:get(user_id, Session), Id), State)
        end
    end, State);
authed(<<"GET">>, [<<"users">>, IdBin, <<"moderation">>, <<"history">>], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        case positive_int(IdBin) of
            undefined -> reply_error(Req, 400, <<"invalid_user_id">>, State);
            Id -> reply_result(Req, pw_db:admin_user_moderation_history(maps:get(user_id, Session), Id), State)
        end
    end, State);
authed(<<"POST">>, [<<"users">>, IdBin, <<"moderation">>], Req0, Session, _Hash, State) ->
    operator_json(Req0, Session, fun(M, Req) ->
        case positive_int(IdBin) of
            undefined -> reply_error(Req, 400, <<"invalid_user_id">>, State);
            Id -> reply_result(Req, pw_db:admin_apply_user_moderation(maps:get(user_id, Session), Id,
                maps:get(<<"action">>, M, <<>>), M), State)
        end
    end, State);
authed(<<"GET">>, [<<"users">>, IdBin], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        case positive_int(IdBin) of undefined -> reply_error(Req, 400, <<"invalid_user_id">>, State); Id -> reply_result(Req, pw_db:admin_user(Id), State) end
    end, State);
authed(<<"GET">>, [<<"servers">>], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        reply_result(Req, pw_db:admin_servers(qs(Req, <<"q">>, <<>>), qs(Req, <<"limit">>, <<"50">>), qs(Req, <<"offset">>, <<"0">>)), State)
    end, State);
authed(<<"GET">>, [<<"servers">>, IdBin], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        case positive_int(IdBin) of undefined -> reply_error(Req, 400, <<"invalid_server_id">>, State); Id -> reply_result(Req, pw_db:admin_server(Id), State) end
    end, State);
authed(<<"GET">>, [<<"audit">>], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        reply_result(Req, pw_db:admin_audit(qs(Req, <<"limit">>, <<"80">>), qs(Req, <<"before">>, undefined)), State)
    end, State);
authed(<<"GET">>, [<<"operators">>], Req, Session, _Hash, State) ->
    inspect_only(Req, Session, fun() ->
        reply_result(Req, pw_db:admin_operators(maps:get(user_id, Session)), State)
    end, State);
authed(<<"GET">>, [<<"banners">>], Req, _Session, _Hash, State) ->
    reply_result(Req, pw_db:admin_banners(), State);
authed(<<"POST">>, [<<"banners">>], Req0, Session, _Hash, State) ->
    operator_json(Req0, Session, fun(M, Req) ->
        case pw_db:admin_create_banner(maps:get(user_id, Session), M) of
            {ok, Data} ->
                ok = pw_db:invalidate_global_banners_cache(),
                _ = pw_hub:broadcast({system, global}, #{type => system_banners_changed}),
                reply_ok(Req, Data, State);
            Error -> reply_result(Req, Error, State)
        end
    end, State);
authed(<<"POST">>, [<<"banners">>, IdBin], Req0, Session, _Hash, State) ->
    case positive_int(IdBin) of
        undefined -> reply_error(Req0, 400, <<"invalid_banner_id">>, State);
        BannerId -> operator_json(Req0, Session, fun(M, Req) ->
            case pw_db:admin_update_banner(maps:get(user_id, Session), BannerId, M) of
                {ok, Data} ->
                    ok = pw_db:invalidate_global_banners_cache(),
                    _ = pw_hub:broadcast({system, global}, #{type => system_banners_changed}),
                    reply_ok(Req, Data, State);
                Error -> reply_result(Req, Error, State)
            end
        end, State)
    end;
authed(<<"DELETE">>, [<<"banners">>, IdBin], Req, Session, _Hash, State) ->
    case {can_operate(Session), positive_int(IdBin)} of
        {false, _} -> reply_error(Req, 403, <<"forbidden">>, State);
        {_, undefined} -> reply_error(Req, 400, <<"invalid_banner_id">>, State);
        {true, BannerId} ->
            ExpectedUpdatedAt = qs(Req, <<"expected_updated_at">>, undefined),
            case pw_db:admin_delete_banner(maps:get(user_id, Session), BannerId, ExpectedUpdatedAt) of
                {ok, Data} ->
                    ok = pw_db:invalidate_global_banners_cache(),
                    _ = pw_hub:broadcast({system, global}, #{type => system_banners_changed}),
                    reply_ok(Req, Data, State);
                Error -> reply_result(Req, Error, State)
            end
    end;
authed(<<"GET">>, [<<"controls">>], Req, _Session, _Hash, State) ->
    case pw_db:instance_registration_mode() of
        {ok, Mode} -> reply_ok(Req, #{registration_mode => Mode,
                                      registration_enabled => pw_client_config:registration_enabled()}, State);
        Error -> reply_result(Req, Error, State)
    end;
authed(<<"POST">>, [<<"controls">>, <<"registration">>], Req0, Session, _Hash, State) ->
    operator_json(Req0, Session, fun(M, Req) ->
        Mode = maps:get(<<"mode">>, M, <<"inherit">>),
        case pw_db:admin_set_registration_mode(maps:get(user_id, Session), Mode) of
            {ok, Data} ->
                _ = pw_hub:broadcast({system, global}, #{type => service_settings_changed}),
                reply_ok(Req, Data#{registration_enabled => pw_client_config:registration_enabled()}, State);
            Error -> reply_result(Req, Error, State)
        end
    end, State);
authed(<<"POST">>, [<<"controls">>, <<"reconcile">>], Req, Session, _Hash, State) ->
    ActorUid = maps:get(user_id, Session),
    case {can_operate(Session), pw_rate:allow({admin_reconcile_clients, ActorUid}, 6, 60000)} of
        {false, _} -> reply_error(Req, 403, <<"forbidden">>, State);
        {true, false} -> reply_error(Req, 429, <<"rate_limited">>, State);
        {true, true} ->
            _ = pw_db:admin_record_audit(ActorUid, <<"service.reconcile_clients">>, <<"instance">>, <<>>, <<"requested realtime client reconciliation">>, request_ip_hash(Req)),
            _ = pw_hub:broadcast({system, global}, #{type => realtime_resync}),
            reply_ok(Req, #{broadcast => true}, State)
    end;
authed(<<"POST">>, [<<"operators">>, <<"enrollment">>], Req0, Session, _Hash, State) ->
    owner_json(Req0, Session, fun(M, Req) ->
        Username = maps:get(<<"username">>, M, <<>>),
        Role = maps:get(<<"role">>, M, <<"viewer">>),
        Note = maps:get(<<"note">>, M, <<>>),
        Code = pw_admin_identity:new_enrollment_code(),
        Hash = pw_admin_identity:hash_secret(Code),
        Expires = pw_util:now_ms() + enrollment_ttl_ms(),
        case pw_db:admin_create_enrollment(maps:get(user_id, Session), Username, Role, Hash, Expires, Note) of
            {ok, Data} -> reply_ok(Req, Data#{enrollment_code => Code}, State);
            Error -> reply_result(Req, Error, State)
        end
    end, State);
authed(<<"POST">>, [<<"operators">>, IdBin, <<"role">>], Req0, Session, _Hash, State) ->
    case positive_int(IdBin) of
        undefined -> reply_error(Req0, 400, <<"invalid_user_id">>, State);
        TargetUid -> owner_json(Req0, Session, fun(M, Req) ->
            reply_result(Req, pw_db:admin_set_operator_role(maps:get(user_id, Session), TargetUid, maps:get(<<"role">>, M, <<>>)), State)
        end, State)
    end;
authed(<<"DELETE">>, [<<"operators">>, IdBin], Req, Session, _Hash, State) ->
    case {is_owner(Session), positive_int(IdBin)} of
        {false, _} -> reply_error(Req, 403, <<"forbidden">>, State);
        {_, undefined} -> reply_error(Req, 400, <<"invalid_user_id">>, State);
        {true, TargetUid} -> reply_result(Req, pw_db:admin_remove_operator(maps:get(user_id, Session), TargetUid), State)
    end;
authed(<<"POST">>, [<<"security">>, <<"rotate-key">>], Req0, Session, _Hash, State) ->
    with_json(Req0, fun(M, Req) ->
        Password = maps:get(<<"password">>, M, <<>>),
        CurrentKey = pw_util:clean_text(maps:get(<<"current_verification_key">>, M, <<>>), 256),
        case valid_token(CurrentKey, <<"op">>) of
            false -> reply_error(Req, 401, <<"bad_login">>, State);
            true ->
                NewKey = pw_admin_identity:new_operator_key(),
                case pw_db:admin_rotate_key(maps:get(user_id, Session), Password,
                                            pw_admin_identity:hash_secret(CurrentKey),
                                            pw_admin_identity:hash_secret(NewKey), request_ip_hash(Req)) of
                    {ok, Data} -> reply_ok(clear_admin_cookie(Req), Data#{verification_key => NewKey, reauthenticate => true}, State);
                    Error -> reply_result(Req, Error, State)
                end
        end
    end, State);
authed(_, _, Req, _Session, _Hash, State) -> reply_error(Req, 404, <<"not_found">>, State).

public_json(Req0, Kind, Limit, Fun, State) ->
    Ip = pw_util:ip(Req0),
    case pw_rate:allow_shared({admin_auth, Kind, Ip}, Limit, 300000) of
        false -> reply_error(Req0, 429, <<"rate_limited">>, State);
        true -> with_json(Req0, Fun, State)
    end.

inspect_only(Req, Session, Fun, State) ->
    case can_inspect(Session) of
        true -> Fun();
        false -> reply_error(Req, 403, <<"forbidden">>, State)
    end.

can_inspect(Session) ->
    Role = maps:get(role, Session, <<>>),
    Role =:= <<"owner">> orelse Role =:= <<"operator">>.

owner_json(Req0, Session, Fun, State) ->
    case is_owner(Session) of
        true -> with_json(Req0, Fun, State);
        false -> reply_error(Req0, 403, <<"forbidden">>, State)
    end.

operator_json(Req0, Session, Fun, State) ->
    case can_operate(Session) of
        true -> with_json(Req0, Fun, State);
        false -> reply_error(Req0, 403, <<"forbidden">>, State)
    end.

can_operate(Session) ->
    Role = maps:get(role, Session, <<>>),
    Role =:= <<"owner">> orelse Role =:= <<"operator">>.

with_json(Req0, Fun, State) ->
    case pw_util:read_json(Req0, ?MAX_BODY) of
        {ok, M, Req1} -> Fun(M, Req1);
        {error, too_large, Req1} -> reply_error(Req1, 413, <<"body_too_large">>, State);
        {error, _, Req1} -> reply_error(Req1, 400, <<"invalid_json">>, State)
    end.

admin_session(Req) ->
    case pw_util:cookie_value(Req, <<"pw_admin_session">>) of
        undefined -> {error, no_session};
        <<>> -> {error, no_session};
        Token when byte_size(Token) =< 256 ->
            Hash = pw_admin_identity:hash_secret(Token),
            case pw_db:admin_session(Hash) of
                {ok, Session} -> {ok, Session, Hash};
                Error -> Error
            end;
        _ -> {error, no_session}
    end.

valid_csrf(Req, Session) ->
    Expected = maps:get(csrf, Session, <<>>),
    Header = cowboy_req:header(<<"x-csrf-token">>, Req, <<>>),
    Expected =/= <<>> andalso pw_util:constant_time(Header, Expected).

is_owner(Session) -> maps:get(role, Session, <<>>) =:= <<"owner">>.

valid_token(Token, Kind) when is_binary(Token), byte_size(Token) >= 40, byte_size(Token) =< 256 ->
    Prefix = <<"pwadm1.", Kind/binary, ".", (pw_admin_identity:instance_id())/binary, ".">>,
    binary:match(Token, Prefix) =:= {0, byte_size(Prefix)};
valid_token(_, _) -> false.

request_ip_hash(Req) -> pw_admin_identity:hash_secret(pw_util:ip(Req)).
request_ua_hash(Req) ->
    Ua = cowboy_req:header(<<"user-agent">>, Req, <<>>),
    pw_admin_identity:hash_secret(pw_util:clean_text(Ua, 512)).

set_admin_cookie(Req, Token) ->
    cowboy_req:set_resp_cookie(<<"pw_admin_session">>, Token, Req,
        #{http_only => true, secure => admin_cookie_secure(), same_site => strict, path => <<"/">>, max_age => session_ttl_ms() div 1000}).

clear_admin_cookie(Req) ->
    cowboy_req:set_resp_cookie(<<"pw_admin_session">>, <<>>, Req,
        #{http_only => true, secure => admin_cookie_secure(), same_site => strict, path => <<"/">>, max_age => 0}).

admin_cookie_secure() ->
    Default = case os:getenv("PLAINWIRE_ADMIN_PUBLIC_URL") of "https://" ++ _ -> true; _ -> false end,
    pw_util:env_bool("PLAINWIRE_ADMIN_COOKIE_SECURE", Default).

session_ttl_ms() ->
    Hours = min(168, max(1, pw_util:env_int("PLAINWIRE_ADMIN_SESSION_HOURS", 12))),
    Hours * 3600000.

enrollment_ttl_ms() ->
    Minutes = min(10080, max(5, pw_util:env_int("PLAINWIRE_ADMIN_ENROLLMENT_MINUTES", 60))),
    Minutes * 60000.

qs(Req, Key, Default) ->
    case proplists:get_value(Key, cowboy_req:parse_qs(Req)) of undefined -> Default; Value -> Value end.

positive_int(Bin) ->
    case pw_util:int(Bin) of I when is_integer(I), I > 0 -> I; _ -> undefined end.

privacy_contract() ->
    #{content_access => false,
      excluded => [<<"message_bodies">>, <<"direct_message_text">>, <<"attachment_contents">>,
                   <<"message_search">>, <<"private_profile_text">>, <<"verification_secrets">>],
      note => <<"The service admin plane exposes operational metadata and aggregate counts, not communication contents.">>}.

reply_result(Req, {ok, Data}, State) -> reply_ok(Req, Data, State);
reply_result(Req, ok, State) -> reply_ok(Req, #{ok => true}, State);
reply_result(Req, {error, Error}, State) ->
    {Code, Public} = error_status(Error),
    reply_error(Req, Code, Public, State);
reply_result(Req, _, State) -> reply_error(Req, 500, <<"internal_error">>, State).

error_status(bad_login) -> {401, <<"bad_login">>};
error_status(no_session) -> {401, <<"not_authenticated">>};
error_status(forbidden) -> {403, <<"forbidden">>};
error_status(last_owner) -> {409, <<"last_owner">>};
error_status(bootstrap_unavailable) -> {409, <<"bootstrap_unavailable">>};
error_status(bad_bootstrap) -> {401, <<"bad_bootstrap">>};
error_status(recovery_unavailable) -> {409, <<"recovery_unavailable">>};
error_status(bad_recovery) -> {401, <<"bad_recovery">>};
error_status(invalid_enrollment) -> {400, <<"invalid_enrollment">>};
error_status(invalid_role) -> {400, <<"invalid_role">>};
error_status(invalid_banner) -> {400, <<"invalid_banner">>};
error_status(invalid_banner_window) -> {400, <<"invalid_banner_window">>};
error_status(invalid_banner_link) -> {400, <<"invalid_banner_link">>};
error_status(banner_conflict) -> {409, <<"banner_conflict">>};
error_status(invalid_action) -> {400, <<"invalid_action">>};
error_status(invalid_moderation) -> {400, <<"invalid_moderation">>};
error_status(invalid_severity) -> {400, <<"invalid_severity">>};
error_status(invalid_expiry) -> {400, <<"invalid_expiry">>};
error_status(moderation_reason_required) -> {400, <<"moderation_reason_required">>};
error_status(cannot_moderate_self) -> {409, <<"cannot_moderate_self">>};
error_status(owner_protected) -> {409, <<"owner_protected">>};
error_status(operator_protected) -> {403, <<"operator_protected">>};
error_status(invalid_registration_mode) -> {400, <<"invalid_registration_mode">>};
error_status(user_not_found) -> {404, <<"user_not_found">>};
error_status(not_found) -> {404, <<"not_found">>};
error_status(database_busy) -> {503, <<"database_busy">>};
error_status(database_unavailable) -> {503, <<"database_unavailable">>};
error_status(_) -> {500, <<"internal_error">>}.

reply_ok(Req0, Data, State) ->
    Body = pw_util:json(#{ok => true, data => Data}),
    Req = cowboy_req:reply(200, json_headers(), Body, Req0),
    {ok, Req, State}.

reply_error(Req0, Code, Error, State) ->
    Body = pw_util:json(#{ok => false, error => Error}),
    Req = cowboy_req:reply(Code, json_headers(), Body, Req0),
    {ok, Req, State}.

json_headers() -> maps:merge(admin_security_headers(), #{<<"content-type">> => <<"application/json; charset=utf-8">>}).

admin_security_headers() ->
    Base = pw_util:security_headers(),
    Base#{<<"content-security-policy">> => <<"default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'">>,
          <<"permissions-policy">> => <<"camera=(), microphone=(), display-capture=(), geolocation=(), payment=(), usb=(), browsing-topics=()">>}.
