-module(pw_call_invite_authorization_tests).
-include_lib("eunit/include/eunit.hrl").

call_invite_authorization_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port -> {setup, fun() -> setup(list_to_integer(Port)) end, fun epgsql:close/1,
            fun(Conn) -> [
                ?_test(?assert(allowed(Conn, 1, 10, 3))),
                ?_test(?assert(allowed(Conn, 2, 10, 3))),
                ?_test(?assertNot(allowed(Conn, 4, 10, 3))),
                ?_test(?assertNot(allowed(Conn, 1, 10, 4))),
                ?_test(?assertNot(allowed(Conn, 1, 10, 1))),
                ?_test(?assertNot(allowed(Conn, 1, 999, 3))),
                ?_test(?assertNot(allowed(Conn, 1, 20, 2))),
                ?_test(?assertNot(allowed(Conn, 1, 10, <<"invalid">>))),
                ?_test(changed(Conn, "UPDATE direct_members SET request_state='pending' WHERE user_id=3", "UPDATE direct_members SET request_state='accepted' WHERE user_id=3")),
                ?_test(changed(Conn, "UPDATE direct_members SET request_state='pending' WHERE user_id=1", "UPDATE direct_members SET request_state='accepted' WHERE user_id=1")),
                ?_test(changed(Conn, "UPDATE users SET account_state='disabled' WHERE id=3", "UPDATE users SET account_state='active' WHERE id=3")),
                ?_test(changed(Conn, "UPDATE users SET is_bot=true WHERE id=3", "UPDATE users SET is_bot=false WHERE id=3")),
                ?_test(changed(Conn, "UPDATE users SET account_state='disabled' WHERE id=1", "UPDATE users SET account_state='active' WHERE id=1")),
                ?_test(changed(Conn, "UPDATE users SET is_bot=true WHERE id=1", "UPDATE users SET is_bot=false WHERE id=1")),
                ?_test(changed(Conn, "INSERT INTO friendships VALUES(1,3,1,'blocked')", "DELETE FROM friendships")),
                ?_test(changed(Conn, "INSERT INTO friendships VALUES(1,3,3,'blocked')", "DELETE FROM friendships")),
                ?_test(changed(Conn, "INSERT INTO friendships VALUES(2,3,2,'blocked')", "DELETE FROM friendships")),
                ?_test(changed(Conn, "INSERT INTO friendships VALUES(1,2,2,'blocked')", "DELETE FROM friendships")),
                ?_test(changed(Conn, "DELETE FROM direct_members WHERE thread_id=10 AND user_id=3", "INSERT INTO direct_members VALUES(10,3,'accepted')")),
                ?_test(changed(Conn, "ALTER TABLE friendships RENAME TO unavailable_friendships", "ALTER TABLE unavailable_friendships RENAME TO friendships"))
            ] end}
    end.

setup(Port) ->
    {ok, Conn} = epgsql:connect(#{host => "127.0.0.1", port => Port,
        username => os:getenv("PLAINWIRE_TEST_POSTGRES_USER", "plainwire_audit"),
        database => os:getenv("PLAINWIRE_TEST_POSTGRES_DB", "postgres"), timeout => 5000}),
    sql(Conn, "CREATE TEMP TABLE users(id integer PRIMARY KEY, account_state text, is_bot boolean)"),
    sql(Conn, "CREATE TEMP TABLE direct_members(thread_id integer, user_id integer, request_state text)"),
    sql(Conn, "CREATE TEMP TABLE friendships(user_low integer,user_high integer,requester_id integer,status text)"),
    %% The unavailable-table case must not fall back to a real public table
    %% when this suite runs against an already initialized development database.
    sql(Conn, "SET search_path=pg_temp"),
    sql(Conn, "INSERT INTO users VALUES(1,'active',false),(2,'active',false),(3,'active',false),(4,'active',false)"),
    sql(Conn, "INSERT INTO direct_members VALUES(10,1,'accepted'),(10,2,'accepted'),(10,3,'accepted'),(20,1,'accepted'),(20,2,'accepted')"),
    Conn.

allowed(Conn, Uid, Cid, Target) -> pw_db:test_call_invite_target(Conn, Uid, Cid, Target).
changed(Conn, Change, Restore) ->
    sql(Conn, Change),
    try ?assertNot(allowed(Conn, 1, 10, 3)) after sql(Conn, Restore) end.
sql(Conn, Statement) ->
    case epgsql:squery(Conn, Statement) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> erlang:error({fixture_sql, Other})
    end.
