-module(pw_account_recovery_tests).
-include_lib("eunit/include/eunit.hrl").

%% Optional real PostgreSQL regressions. Fixtures are TEMP tables on a single
%% connection, so no existing application tables are modified.
account_recovery_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port ->
            {setup, fun() -> setup(list_to_integer(Port)) end, fun cleanup/1,
                fun({Conn, _}) -> [
                    ?_test(weak_password_preserves_token(Conn)),
                    ?_test(failed_password_write_rolls_back(Conn)),
                    ?_test(failed_session_revocation_rolls_back(Conn)),
                    ?_test(success_revokes_all_sessions(Conn)),
                    ?_test(password_change_revokes_recovery_credentials(Conn)),
                    ?_test(stale_recovery_address_is_rejected(Conn)),
                    ?_test(ineligible_account_is_rejected(Conn)),
                    ?_test(email_write_failure_preserves_token(Conn)),
                    ?_test(email_verification_is_one_time(Conn)),
                    ?_test(email_change_revokes_reset_link(Conn)),
                    ?_test(email_change_failure_rolls_back(Conn)),
                    ?_test(email_removal_revokes_all_links(Conn)),
                    ?_test(email_removal_failure_rolls_back(Conn))
                ] end}
    end.

setup(Port) ->
    {ok, Conn} = epgsql:connect(#{host => "127.0.0.1", port => Port,
        username => os:getenv("PLAINWIRE_TEST_POSTGRES_USER", "plainwire_audit"),
        database => os:getenv("PLAINWIRE_TEST_POSTGRES_DB", "postgres"), timeout => 5000}),
    sql(Conn, "CREATE TEMP TABLE users(id integer PRIMARY KEY, username text, password_hash text, password_salt text, email text, email_verified boolean DEFAULT false, email_verified_at bigint DEFAULT 0, updated_at bigint, account_state text DEFAULT 'active', is_bot boolean DEFAULT false)"),
    sql(Conn, "CREATE TEMP TABLE account_tokens(id serial PRIMARY KEY, user_id integer, purpose text, token_hash text, email text, expires_at bigint, used_at bigint, created_at bigint)"),
    sql(Conn, "CREATE TEMP TABLE sessions(token_hash text PRIMARY KEY, user_id integer)"),
    sql(Conn, "CREATE TEMP TABLE admin_sessions(token_hash text PRIMARY KEY, user_id integer)"),
    OwnCache = case ets:whereis(pw_session_cache) of
        undefined -> ets:new(pw_session_cache, [named_table, public, set]), true;
        _ -> false
    end,
    {Conn, OwnCache}.

cleanup({Conn, OwnCache}) ->
    epgsql:close(Conn),
    case OwnCache of true -> ets:delete(pw_session_cache); false -> ok end.

seed(Conn, Purpose) ->
    sql(Conn, "TRUNCATE users, account_tokens, sessions, admin_sessions"),
    Hash = pw_util:pbkdf2(<<"original-password">>, <<"test-salt">>),
    query(Conn, "INSERT INTO users(id,username,password_hash,password_salt,email,email_verified,updated_at) VALUES(1,'audit',$1,'test-salt','old@example.test',true,0)", [Hash]),
    Email = case Purpose of <<"password_reset">> -> <<"old@example.test">>; _ -> <<"new@example.test">> end,
    query(Conn, "INSERT INTO account_tokens(user_id,purpose,token_hash,email,expires_at) VALUES(1,$1,$2,$3,$4)",
        [Purpose, pw_util:sha256_hex(token()), Email, pw_util:now_ms() + 60000]),
    query(Conn, "INSERT INTO sessions VALUES($1,1)", [pw_util:sha256_hex(<<"current-session">>)]),
    query(Conn, "INSERT INTO sessions VALUES($1,1)", [pw_util:sha256_hex(<<"other-session">>)]),
    sql(Conn, "INSERT INTO admin_sessions VALUES('admin-session',1)"),
    ets:insert(pw_session_cache, {pw_util:sha256_hex(<<"other-session">>), #{user => #{id => 1}}, pw_util:now_ms() + 60000}),
    Hash.

weak_password_preserves_token(Conn) ->
    seed(Conn, <<"password_reset">>),
    ?assertEqual({error, weak_password}, recover(Conn, <<"short">>)),
    ?assertEqual([[null]], rows(Conn, "SELECT used_at FROM account_tokens")),
    ?assertMatch({ok, #{reset := true}}, recover(Conn, <<"replacement-password">>)).

failed_password_write_rolls_back(Conn) ->
    OldHash = seed(Conn, <<"password_reset">>),
    sql(Conn, "ALTER TABLE users ADD CONSTRAINT reject_password CHECK (updated_at=0)"),
    try ?assertException(error, _, recover(Conn, <<"replacement-password">>))
    after sql(Conn, "ALTER TABLE users DROP CONSTRAINT reject_password") end,
    ?assertEqual([[null]], rows(Conn, "SELECT used_at FROM account_tokens")),
    ?assertEqual([[OldHash]], rows(Conn, "SELECT password_hash FROM users")),
    ?assertMatch({ok, #{reset := true}}, recover(Conn, <<"replacement-password">>)).

failed_session_revocation_rolls_back(Conn) ->
    OldHash = seed(Conn, <<"password_reset">>),
    %% A restrictive FK forces an error after the password UPDATE succeeds.
    sql(Conn, "CREATE TEMP TABLE session_guard(token_hash text REFERENCES sessions(token_hash))"),
    query(Conn, "INSERT INTO session_guard VALUES($1)", [pw_util:sha256_hex(<<"other-session">>)]),
    try ?assertException(error, _, recover(Conn, <<"replacement-password">>))
    after sql(Conn, "DROP TABLE session_guard") end,
    ?assertEqual([[null]], rows(Conn, "SELECT used_at FROM account_tokens")),
    ?assertEqual([[OldHash]], rows(Conn, "SELECT password_hash FROM users")),
    ?assertEqual([[2]], rows(Conn, "SELECT count(*) FROM sessions")),
    ?assertMatch([_], ets:lookup(pw_session_cache, pw_util:sha256_hex(<<"other-session">>))).

success_revokes_all_sessions(Conn) ->
    seed(Conn, <<"password_reset">>),
    ?assertEqual({ok, #{reset => true, revoked_sessions => 2}}, recover(Conn, <<"replacement-password">>)),
    ?assertEqual([[0]], rows(Conn, "SELECT count(*) FROM sessions")),
    ?assertEqual([[0]], rows(Conn, "SELECT count(*) FROM admin_sessions")),
    ?assertEqual([], ets:lookup(pw_session_cache, pw_util:sha256_hex(<<"other-session">>))),
    [[Hash, Salt]] = rows(Conn, "SELECT password_hash,password_salt FROM users"),
    ?assert(pw_util:verify_password(<<"replacement-password">>, Salt, Hash)),
    ?assertEqual({error, invalid_token}, recover(Conn, <<"replacement-password">>)).

password_change_revokes_recovery_credentials(Conn) ->
    seed(Conn, <<"password_reset">>),
    ?assertMatch({ok, #{changed := true}}, pw_db:test_account_recovery(
        {change_password, 1, <<"current-session">>, <<"original-password">>, <<"replacement-password">>}, Conn)),
    ?assertEqual([[1]], rows(Conn, "SELECT count(*) FROM sessions")),
    ?assertEqual([[0]], rows(Conn, "SELECT count(*) FROM admin_sessions")),
    ?assertEqual({error, invalid_token}, recover(Conn, <<"replacement-password">>)).

stale_recovery_address_is_rejected(Conn) ->
    OldHash = seed(Conn, <<"password_reset">>),
    sql(Conn, "UPDATE account_tokens SET email='former@example.test'"),
    ?assertEqual({error, invalid_token}, recover(Conn, <<"replacement-password">>)),
    ?assertEqual([[OldHash]], rows(Conn, "SELECT password_hash FROM users")),
    ?assertEqual([[null]], rows(Conn, "SELECT used_at FROM account_tokens")).

ineligible_account_is_rejected(Conn) ->
    lists:foreach(fun(Update) ->
        seed(Conn, <<"password_reset">>),
        sql(Conn, Update),
        ?assertEqual({error, invalid_token}, recover(Conn, <<"replacement-password">>)),
        ?assertEqual([[null]], rows(Conn, "SELECT used_at FROM account_tokens"))
    end, ["UPDATE users SET email_verified=false", "UPDATE users SET account_state='disabled'", "UPDATE users SET is_bot=true"]).

email_write_failure_preserves_token(Conn) ->
    seed(Conn, <<"email_verify">>),
    sql(Conn, "ALTER TABLE users ADD CONSTRAINT reject_email CHECK (email='old@example.test')"),
    try ?assertException(error, _, verify(Conn))
    after sql(Conn, "ALTER TABLE users DROP CONSTRAINT reject_email") end,
    ?assertEqual([[null]], rows(Conn, "SELECT used_at FROM account_tokens")),
    ?assertEqual([[<<"old@example.test">>]], rows(Conn, "SELECT email FROM users")),
    ?assertEqual({ok, #{verified => true}}, verify(Conn)).

email_verification_is_one_time(Conn) ->
    seed(Conn, <<"email_verify">>),
    ?assertEqual({ok, #{verified => true}}, verify(Conn)),
    ?assertEqual({error, invalid_token}, verify(Conn)).

email_change_revokes_reset_link(Conn) ->
    seed(Conn, <<"password_reset">>),
    ?assertMatch({ok, #{updated := true, mail := #{to := <<"next@example.test">>}}}, change_email(Conn)),
    ?assertEqual([[<<"next@example.test">>, false]], rows(Conn, "SELECT email,email_verified FROM users")),
    ?assertEqual({error, invalid_token}, recover(Conn, <<"replacement-password">>)),
    ?assertEqual([[<<"email_verify">>]], rows(Conn, "SELECT purpose FROM account_tokens")).

email_change_failure_rolls_back(Conn) ->
    seed(Conn, <<"password_reset">>),
    guard_token(Conn),
    try ?assertException(error, _, change_email(Conn))
    after sql(Conn, "DROP TABLE token_guard") end,
    assert_original_email(Conn),
    ?assertMatch({ok, #{reset := true}}, recover(Conn, <<"replacement-password">>)).

email_removal_revokes_all_links(Conn) ->
    seed(Conn, <<"password_reset">>),
    sql(Conn, "INSERT INTO account_tokens(user_id,purpose,token_hash,email,expires_at) VALUES(1,'email_verify','unused','next@example.test',9999999999999)"),
    ?assertEqual({ok, #{removed => true}}, remove_email(Conn)),
    ?assertEqual([[<<>>, false]], rows(Conn, "SELECT email,email_verified FROM users")),
    ?assertEqual([[0]], rows(Conn, "SELECT count(*) FROM account_tokens")).

email_removal_failure_rolls_back(Conn) ->
    seed(Conn, <<"password_reset">>),
    guard_token(Conn),
    try ?assertException(error, _, remove_email(Conn))
    after sql(Conn, "DROP TABLE token_guard") end,
    assert_original_email(Conn),
    ?assertMatch({ok, #{reset := true}}, recover(Conn, <<"replacement-password">>)).

guard_token(Conn) ->
    sql(Conn, "CREATE TEMP TABLE token_guard(token_id integer REFERENCES account_tokens(id))"),
    sql(Conn, "INSERT INTO token_guard SELECT id FROM account_tokens").

assert_original_email(Conn) ->
    ?assertEqual([[<<"old@example.test">>, true]], rows(Conn, "SELECT email,email_verified FROM users")),
    ?assertMatch([_], ets:lookup(pw_session_cache, pw_util:sha256_hex(<<"other-session">>))).

change_email(Conn) -> pw_db:test_account_recovery({set_account_email, 1, <<"next@example.test">>, <<"original-password">>}, Conn).
remove_email(Conn) -> pw_db:test_account_recovery({remove_account_email, 1, <<"original-password">>}, Conn).

token() -> <<"audit-recovery-token-123456789">>.
recover(Conn, Password) -> pw_db:test_account_recovery({reset_password, token(), Password}, Conn).
verify(Conn) -> pw_db:test_account_recovery({verify_email_token, token()}, Conn).

sql(Conn, Statement) ->
    case epgsql:squery(Conn, Statement) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> erlang:error({fixture_sql, Other})
    end.
query(Conn, Statement, Args) ->
    case epgsql:equery(Conn, Statement, Args) of
        {ok, _} -> ok;
        Other -> erlang:error({fixture_sql, Other})
    end.
rows(Conn, Statement) ->
    {ok, _, Tuples} = epgsql:equery(Conn, Statement, []),
    [tuple_to_list(Row) || Row <- Tuples].
