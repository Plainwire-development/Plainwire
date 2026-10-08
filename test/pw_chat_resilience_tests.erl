-module(pw_chat_resilience_tests).
-include_lib("eunit/include/eunit.hrl").

nonce_validation_test() ->
    ?assertEqual(undefined, pw_db:test_message_nonce(undefined)),
    ?assertEqual(undefined, pw_db:test_message_nonce(null)),
    ?assertEqual(nonce(), pw_db:test_message_nonce(nonce())),
    [?assertEqual(invalid, pw_db:test_message_nonce(Value)) || Value <- [<<>>, <<"short">>, 42, #{}, binary:copy(<<"a">>, 97), <<"abcdefghijklmnop\n">>]].

scylla_hydration_metadata_test() ->
    Row = [10, <<"direct">>, 3, 4, <<"name">>, <<"Name">>, <<>>, <<"old">>, null, 1, null, null, <<"text">>, null, null, null, null, <<"#abcabc">>, false, true, nonce()],
    Core = #{id => 10, scope => <<"direct">>, scope_id => 3, user_id => 4, body => <<"current">>, created_at => 9},
    Hydrated = pw_db:test_overlay_scylla_row(Row, Core),
    ?assertEqual(21, length(Hydrated)),
    ?assertEqual(<<"current">>, lists:nth(8, Hydrated)),
    ?assertEqual(9, lists:nth(10, Hydrated)),
    ?assertEqual([true, nonce()], lists:nthtail(19, Hydrated)),
    ?assertEqual(19, length(pw_db:test_overlay_scylla_row(lists:sublist(Row, 19), Core))).

immediate_revocation_test() ->
    {Registry, Own} = case whereis(pw_realtime_registry) of
        undefined -> {ok, Pid} = pw_realtime_registry:start_link(), unlink(Pid), {Pid, true};
        Pid -> {Pid, false}
    end,
    try
        pw_realtime_registry:register(451, self()),
        pw_realtime_registry:subscribe(self(), {direct, 12}),
        pw_realtime_registry:subscribe(self(), {server, 3}),
        pw_realtime_registry:subscribe(self(), {channel, 9}),
        Epoch = pw_realtime_registry:access_epoch(self()),
        pw_cluster_local:deliver({control, revoke_conversation_access}, #{uid => 451, conversation_id => 12}),
        ?assertNot(lists:member({direct, 12}, pw_realtime_registry:subscriptions(self()))),
        ?assert(lists:member({channel, 9}, pw_realtime_registry:subscriptions(self()))),
        ?assertEqual({error, access_changed}, pw_realtime_registry:subscribe(self(), {direct, 12}, Epoch)),
        ?assertEqual(ok, pw_realtime_registry:subscribe(self(), {channel, 9}, pw_realtime_registry:access_epoch(self()))),
        pw_cluster_local:deliver({control, revoke_server_access}, #{uid => 451, server_id => 3, channel_ids => [9]}),
        ?assertEqual([], pw_realtime_registry:subscriptions(self()))
    after
        pw_realtime_registry:unregister(self()),
        ?assertEqual(unavailable, pw_realtime_registry:access_epoch(self())),
        case Own of true -> gen_server:stop(Registry); false -> ok end
    end.

delayed_hub_subscription_test() ->
    {Registry, OwnRegistry} = case whereis(pw_realtime_registry) of
        undefined -> {ok, R} = pw_realtime_registry:start_link(), unlink(R), {R, true};
        R -> {R, false}
    end,
    {Hub, OwnHub} = case whereis(pw_hub) of
        undefined -> {ok, H} = pw_hub:start_link(), unlink(H), {H, true};
        H -> {H, false}
    end,
    try
        pw_hub:connect(452, self(), <<"online">>),
        _ = gen_server:call(Hub, sync),
        Epoch = pw_realtime_registry:access_epoch(self()),
        InitialSubscriptions = pw_realtime_registry:subscriptions(self()),
        ?assert(is_integer(Epoch)),
        sys:suspend(Hub),
        pw_cluster_local:deliver({control, revoke_conversation_access}, #{uid => 452, conversation_id => 12}),
        %% This models an authorization result arriving after block cleanup was
        %% queued, while the hub still has not processed either operation.
        pw_hub:subscribe(self(), {direct, 12}, Epoch),
        sys:resume(Hub),
        _ = gen_server:call(Hub, sync),
        ?assertEqual(InitialSubscriptions, pw_realtime_registry:subscriptions(self())),
        receive {retry_subscription, {direct, 12}} -> ok after 1000 -> erlang:error(missing_reauthorization) end,
        pw_hub:subscribe(self(), {channel, 9}, pw_realtime_registry:access_epoch(self())),
        _ = gen_server:call(Hub, sync),
        ?assert(lists:member({channel, 9}, pw_realtime_registry:subscriptions(self())))
    after
        try sys:resume(Hub) catch _:_ -> ok end,
        pw_hub:disconnect(self()),
        _ = gen_server:call(Hub, sync),
        case OwnHub of true -> gen_server:stop(Hub); false -> ok end,
        case OwnRegistry of true -> gen_server:stop(Registry); false -> ok end
    end.

postgres_regressions_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port -> {setup, fun() -> setup(list_to_integer(Port)) end, fun cleanup/1,
            fun(Fixture) -> [?_test(nonce_identity(Fixture)), ?_test(concurrent_nonce(Fixture)), ?_test(block_privacy(Fixture))] end}
    end.

setup(Port) ->
    Schema = "pw_chat_audit_" ++ integer_to_list(erlang:unique_integer([positive])),
    Conn = connect(Port),
    sql(Conn, "CREATE SCHEMA " ++ Schema),
    sql(Conn, "SET search_path=" ++ Schema),
    sql(Conn, "CREATE TABLE messages(id bigint PRIMARY KEY,user_id integer,scope text,scope_id integer,body text,reply_to_id bigint,deleted_at bigint,client_nonce text,UNIQUE(user_id,client_nonce))"),
    sql(Conn, "CREATE TABLE direct_members(thread_id integer,user_id integer,request_state text,muted boolean)"),
    sql(Conn, "CREATE TABLE friendships(user_low integer,user_high integer,requester_id integer,addressee_id integer,status text,created_at bigint,updated_at bigint,PRIMARY KEY(user_low,user_high))"),
    sql(Conn, "INSERT INTO direct_members VALUES(1,1,'accepted',false),(1,2,'accepted',false),(1,3,'accepted',false),(1,4,'accepted',false)"),
    {Conn, Port, Schema}.

cleanup({Conn, _, Schema}) -> sql(Conn, "DROP SCHEMA " ++ Schema ++ " CASCADE"), epgsql:close(Conn).
connect(Port) ->
    {ok, Conn} = epgsql:connect("127.0.0.1", os:getenv("PLAINWIRE_TEST_POSTGRES_USER"), "", [{port, Port}, {database, os:getenv("PLAINWIRE_TEST_POSTGRES_DB")}, {timeout, 5000}]),
    Conn.

nonce_identity({Conn, _, _}) ->
    sql(Conn, "BEGIN"),
    try
        ?assertEqual(new, state(Conn, 1, <<"direct">>, 1, <<"hello">>, undefined, nonce())),
        {ok, 1} = epgsql:equery(Conn, "INSERT INTO messages VALUES(1,1,'direct',1,'hello',NULL,NULL,$1)", [nonce()]),
        ?assertEqual({replay, 1}, state(Conn, 1, <<"direct">>, 1, <<"hello">>, undefined, nonce())),
        ?assertEqual(new, state(Conn, 2, <<"direct">>, 1, <<"hello">>, undefined, nonce())),
        ?assertThrow({plainwire_error, client_nonce_conflict}, state(Conn, 1, <<"direct">>, 2, <<"hello">>, undefined, nonce())),
        ?assertThrow({plainwire_error, client_nonce_conflict}, state(Conn, 1, <<"channel">>, 1, <<"hello">>, undefined, nonce())),
        ?assertThrow({plainwire_error, client_nonce_conflict}, state(Conn, 1, <<"direct">>, 1, <<"changed">>, undefined, nonce())),
        ?assertThrow({plainwire_error, client_nonce_conflict}, state(Conn, 1, <<"direct">>, 1, <<"hello">>, 99, nonce())),
        sql(Conn, "UPDATE messages SET deleted_at=1 WHERE id=1"),
        ?assertThrow({plainwire_error, message_removed}, state(Conn, 1, <<"direct">>, 1, <<"hello">>, undefined, nonce()))
    after sql(Conn, "ROLLBACK") end.

concurrent_nonce({Conn, Port, Schema}) ->
    Parent = self(),
    [spawn(fun() ->
        C = connect(Port),
        try
            sql(C, "SET search_path=" ++ Schema), sql(C, "BEGIN"),
            Result = state(C, 8, <<"direct">>, 1, <<"concurrent">>, undefined, nonce()),
            case Result of new -> {ok, 1} = epgsql:equery(C, "INSERT INTO messages VALUES($1,8,'direct',1,'concurrent',NULL,NULL,$2)", [Id, nonce()]); _ -> ok end,
            sql(C, "COMMIT"), Parent ! {nonce_result, Result}
        catch Class:Reason -> Parent ! {nonce_error, Class, Reason}
        after epgsql:close(C) end
    end) || Id <- [10, 11]],
    Results = [receive {nonce_result, Result} -> Result; Error -> erlang:error(Error) after 5000 -> erlang:error(nonce_timeout) end || _ <- [1,2]],
    ?assertEqual(1, length([new || new <- Results])),
    ?assertEqual(1, length([Id || {replay, Id} <- Results])),
    ?assertEqual([[1]], query(Conn, "SELECT count(*) FROM messages WHERE user_id=8", [])).

block_privacy({Conn, _, _}) ->
    ?assertEqual({ok, [[1, <<"accepted">>], [2, <<"accepted">>], [4, <<"accepted">>]]}, pw_db:test_direct_notification_members(Conn, 1, 3)),
    ?assertMatch({ok, _}, pw_db:test_chat_route(Conn, {friend_block, 1, 2})),
    ?assertEqual({ok, [[4, <<"accepted">>]]}, pw_db:test_direct_notification_members(Conn, 1, 3)),
    ?assertEqual({error, forbidden}, pw_db:test_chat_route(Conn, {friend_block, 2, 1})),
    ?assertEqual({error, forbidden}, pw_db:test_chat_route(Conn, {friend_unblock, 2, 1})),
    ?assertEqual([[1]], query(Conn, "SELECT requester_id FROM friendships WHERE status='blocked'", [])).

nonce() -> <<"0123456789abcdef0123456789abcdef:-1">>.
state(Conn, Uid, Scope, Cid, Body, Reply, Nonce) -> pw_db:test_message_nonce_state(Conn, Uid, Scope, Cid, Body, Reply, Nonce).
query(Conn, Sql, Params) -> {ok, _, Rows} = epgsql:equery(Conn, Sql, Params), [tuple_to_list(R) || R <- Rows].
sql(Conn, Sql) -> case epgsql:squery(Conn, Sql) of {ok, _, _} -> ok; {ok, _} -> ok; Other -> erlang:error({fixture_sql, Other}) end.
