-module(pw_db_recovery_tests).
-include_lib("eunit/include/eunit.hrl").

database_recovery_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port -> [
            {"upload backfill preserves large message IDs", fun() -> large_cursor(list_to_integer(Port)) end},
            {"dead DB connection is replaced without replaying a write", fun() -> dead_connection(Port) end}
        ]
    end.

large_cursor(Port) ->
    {ok, Conn} = epgsql:connect(#{host => "127.0.0.1", port => Port,
        username => os:getenv("PLAINWIRE_TEST_POSTGRES_USER", "plainwire_audit"),
        database => os:getenv("PLAINWIRE_TEST_POSTGRES_DB", "postgres"), timeout => 5000}),
    try
        sql(Conn, "CREATE TEMP TABLE upload_ref_backfill(id integer PRIMARY KEY,cursor integer NOT NULL DEFAULT 0,done boolean NOT NULL DEFAULT false)"),
        sql(Conn, "CREATE TEMP TABLE messages(id bigint PRIMARY KEY,scope text,scope_id integer,body text,created_at bigint,deleted_at bigint)"),
        sql(Conn, "INSERT INTO upload_ref_backfill(id) VALUES(1)"),
        sql(Conn, "INSERT INTO messages VALUES(96346551137728,'direct',1,'plain text',1,NULL)"),
        {57, Statements} = lists:keyfind(57, 1, pw_db_schema:migrations()),
        lists:foreach(fun(Statement) -> sql(Conn, Statement) end, Statements),
        ?assertEqual({ok, continue}, pw_db:test_upload_backfill(Conn, 1)),
        ?assertMatch({ok, _, [{96346551137728}]}, epgsql:equery(Conn, "SELECT cursor FROM upload_ref_backfill WHERE id=1", [])),
        ?assertEqual({ok, done}, pw_db:test_upload_backfill(Conn, 1)),
        %% Finished backfills must not start reading message rows again.
        sql(Conn, "ALTER TABLE messages RENAME TO completed_messages"),
        sql(Conn, "SET search_path=pg_temp"),
        ?assertEqual({ok, done}, pw_db:test_upload_backfill(Conn, 1))
    after epgsql:close(Conn) end.

dead_connection(Port) ->
    Values = [{"PLAINWIRE_DB_HOST", "127.0.0.1"}, {"PLAINWIRE_DB_PORT", Port},
        {"PLAINWIRE_DB_USER", os:getenv("PLAINWIRE_TEST_POSTGRES_USER", "plainwire_audit")},
        {"PLAINWIRE_DB_NAME", os:getenv("PLAINWIRE_TEST_POSTGRES_DB", "postgres")},
        {"PLAINWIRE_DB_PASS", ""}, {"PLAINWIRE_DB_SSL", "false"}],
    Previous = [{Name, os:getenv(Name)} || {Name, _} <- Values],
    try
        [os:putenv(Name, Value) || {Name, Value} <- Values],
        {Dead, Monitor} = spawn_monitor(fun() -> ok end),
        receive {'DOWN', Monitor, process, Dead, normal} -> ok after 1000 -> erlang:error(dead_connection_timeout) end,
        {{error, database_unavailable}, Recovered} = pw_db:test_route_with_reconnect({upload_ref_backfill, 1}, Dead),
        try
            ?assert(is_process_alive(Recovered)),
            sql(Recovered, "CREATE TEMP TABLE upload_ref_backfill(id integer PRIMARY KEY,cursor bigint,done boolean)"),
            sql(Recovered, "INSERT INTO upload_ref_backfill VALUES(1,0,true)"),
            ?assertEqual({{ok, done}, Recovered}, pw_db:test_route_with_reconnect({upload_ref_backfill, 1}, Recovered))
        after epgsql:close(Recovered) end
    after
        [case Value of false -> os:unsetenv(Name); _ -> os:putenv(Name, Value) end || {Name, Value} <- Previous]
    end.

sql(Conn, Statement) ->
    case epgsql:squery(Conn, Statement) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> erlang:error({fixture_sql, Other})
    end.
