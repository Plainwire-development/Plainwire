-module(pw_e2ee_tests).
-include_lib("eunit/include/eunit.hrl").

framing_test() ->
    Key = key(), Envelope = envelope(Key),
    ?assert(pw_e2ee:valid_key_id(Key)),
    ?assert(pw_e2ee:valid_envelope(Envelope, Key)),
    ?assertNot(pw_e2ee:valid_envelope(Envelope, other_key())),
    ?assertNot(pw_e2ee:valid_key_id(<<"password">>)),
    ?assertNot(pw_e2ee:valid_key_id(binary:copy(<<"A">>, 64))),
    ?assertNot(pw_e2ee:valid_envelope(<<Envelope/binary, "=">>, Key)),
    ?assertNot(pw_e2ee:valid_envelope(<<Envelope/binary, ":extra">>, Key)),
    ?assertNot(pw_e2ee:valid_envelope(binary:copy(<<"x">>, 8193), Key)),
    ?assertNot(pw_e2ee:valid_envelope(<<"pw-e2ee-v1:", Key/binary, ":AA:AA">>, Key)),
    ?assertEqual(<<"Encrypted text message">>, pw_e2ee:preview(Envelope)),
    ?assertEqual(<<"legacy text">>, pw_e2ee:preview(<<"legacy text">>)).

message_limits_test() ->
    ?assert(pw_db:test_e2ee({body, envelope(key())}, undefined)),
    ?assert(pw_db:test_e2ee({body, binary:copy(<<"a">>, 5000)}, undefined)),
    ?assertNot(pw_db:test_e2ee({body, binary:copy(<<"a">>, 5001)}, undefined)),
    ?assertNot(pw_db:test_e2ee({body, binary:copy(<<"x">>, 8193)}, undefined)),
    ?assertNot(pw_db:test_e2ee({body, <<"pw-e2ee-v1:broken">>}, undefined)),
    ?assertNot(pw_db:test_e2ee({body, <<" \n\t">>}, undefined)),
    ?assertNot(pw_db:test_e2ee({body, <<255, 254>>}, undefined)).

enforcement_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port -> {setup, fun() -> setup(list_to_integer(Port)) end, fun epgsql:close/1,
            fun(Conn) -> [
                ?_test(?assertEqual(ok, validate(Conn, 10, <<"legacy">>))),
                ?_test(?assertThrow({plainwire_error, encryption_not_enabled}, validate(Conn, 10, envelope(key())))),
                ?_test(?assertEqual({error, encryption_requires_private_dm}, enable(Conn, 4, 10))),
                ?_test(?assertEqual({error, encryption_requires_private_dm}, enable(Conn, 1, 20))),
                ?_test(?assertEqual({error, encryption_requires_private_dm}, enable(Conn, 1, 30))),
                ?_test(changed(Conn, "UPDATE users SET is_bot=true WHERE id=2", "UPDATE users SET is_bot=false WHERE id=2")),
                ?_test(changed(Conn, "INSERT INTO friendships VALUES(1,2,'blocked')", "DELETE FROM friendships")),
                ?_test(activation_and_downgrade(Conn)),
                ?_test(?assertThrow({plainwire_error, encryption_requires_private_dm}, pw_db:test_e2ee({validate, <<"channel">>, 1, envelope(key())}, Conn))),
                ?_test(?assertThrow({plainwire_error, encrypted_dm_members_locked}, pw_db:test_e2ee({add_conversation_members, 1, 10, [3]}, Conn))),
                ?_test(?assertThrow({plainwire_error, encrypted_message_required}, pw_db:test_e2ee({post_direct_message, 1, 10, <<"older client plaintext">>, null}, Conn)))
            ] end}
    end.

activation_and_downgrade(Conn) ->
    ?assertMatch({ok, #{e2ee_key_id := _}}, enable(Conn, 1, 10)),
    ?assertMatch({ok, _}, enable(Conn, 2, 10)),
    ?assertEqual({error, encryption_key_locked}, pw_db:test_e2ee({enable_conversation_encryption, 1, 10, other_key()}, Conn)),
    ?assertEqual({error, invalid_encryption_key_id}, pw_db:test_e2ee({enable_conversation_encryption, 1, 10, <<>>}, Conn)),
    ?assertEqual(ok, validate(Conn, 10, envelope(key()))),
    ?assertThrow({plainwire_error, encrypted_message_required}, validate(Conn, 10, <<"plaintext">>)),
    ?assertThrow({plainwire_error, encrypted_message_required}, validate(Conn, 10, envelope(other_key()))).

setup(Port) ->
    {ok, Conn} = epgsql:connect(#{host => "127.0.0.1", port => Port,
        username => os:getenv("PLAINWIRE_TEST_POSTGRES_USER", "plainwire_audit"),
        database => os:getenv("PLAINWIRE_TEST_POSTGRES_DB", "postgres"), timeout => 5000}),
    sql(Conn, "CREATE TEMP TABLE direct_threads(id integer PRIMARY KEY)"),
    {55, Statements} = lists:keyfind(55, 1, pw_db_schema:migrations()),
    lists:foreach(fun(Statement) -> sql(Conn, Statement) end, Statements),
    sql(Conn, "CREATE TEMP TABLE direct_members(thread_id integer,user_id integer,request_state text)"),
    sql(Conn, "CREATE TEMP TABLE users(id integer PRIMARY KEY,is_bot boolean)"),
    sql(Conn, "CREATE TEMP TABLE friendships(user_low integer,user_high integer,status text)"),
    sql(Conn, "INSERT INTO users VALUES(1,false),(2,false),(3,false),(4,false)"),
    sql(Conn, "INSERT INTO direct_threads(id) VALUES(10),(20),(30)"),
    sql(Conn, "INSERT INTO direct_members VALUES(10,1,'accepted'),(10,2,'accepted'),(20,1,'accepted'),(20,2,'accepted'),(20,3,'accepted'),(30,1,'accepted'),(30,2,'pending')"),
    Conn.

changed(Conn, Change, Restore) ->
    sql(Conn, Change),
    try ?assertEqual({error, encryption_requires_private_dm}, enable(Conn, 1, 10))
    after sql(Conn, Restore) end.
enable(Conn, Uid, Cid) -> pw_db:test_e2ee({enable_conversation_encryption, Uid, Cid, key()}, Conn).
validate(Conn, Cid, Body) -> pw_db:test_e2ee({validate, <<"direct">>, Cid, Body}, Conn).
key() -> binary:copy(<<"a">>, 64).
other_key() -> binary:copy(<<"b">>, 64).
envelope(Key) -> <<"pw-e2ee-v1:", Key/binary, ":", (pw_util:base64url(<<0:96>>))/binary, ":", (pw_util:base64url(<<0:208>>))/binary>>.
sql(Conn, Statement) ->
    case epgsql:squery(Conn, Statement) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> erlang:error({fixture_sql, Other})
    end.
