-module(pw_upload_authorization_tests).
-include_lib("eunit/include/eunit.hrl").

upload_authorization_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port -> {setup, fun() -> setup(list_to_integer(Port)) end, fun epgsql:close/1,
            fun(Conn) -> [
                ?_test(?assertEqual(ok, validate(Conn, 1, own_id()))),
                ?_test(?assertThrow({plainwire_error, attachment_unavailable}, validate(Conn, 1, private_id()))),
                ?_test(?assertThrow({plainwire_error, attachment_unavailable}, validate(Conn, 1, pending_id()))),
                ?_test(?assertThrow({plainwire_error, attachment_unavailable}, validate(Conn, 1, <<"unknown-file-123456789012">>))),
                ?_test(readable_shared_file_can_be_shared(Conn)),
                ?_test(stale_reference_does_not_grant_access(Conn)),
                ?_test(edit_rebuilding_refs_cannot_publish_private_file(Conn))
            ] end}
    end.

setup(Port) ->
    {ok, Conn} = epgsql:connect(#{host => "127.0.0.1", port => Port,
        username => os:getenv("PLAINWIRE_TEST_POSTGRES_USER", "plainwire_audit"),
        database => os:getenv("PLAINWIRE_TEST_POSTGRES_DB", "postgres"), timeout => 5000}),
    sql(Conn, "CREATE TEMP TABLE uploads(id text PRIMARY KEY, user_id integer, status text)"),
    sql(Conn, "CREATE TEMP TABLE upload_refs(upload_id text,scope text,scope_id integer,created_at bigint)"),
    sql(Conn, "CREATE TEMP TABLE threads(id integer PRIMARY KEY,user_id integer,forum_id integer,title text,body text,raw_body text,updated_at bigint)"),
    sql(Conn, "CREATE TEMP TABLE forum_members(forum_id integer,user_id integer)"),
    insert(Conn, "INSERT INTO uploads VALUES($1,1,'ready'),($2,2,'ready'),($3,1,'pending')", [own_id(), private_id(), pending_id()]),
    insert(Conn, "INSERT INTO threads VALUES(1,1,1,'Original',$1,$1,0)", [url(own_id())]),
    sql(Conn, "INSERT INTO forum_members VALUES(1,1)"),
    Conn.

readable_shared_file_can_be_shared(Conn) ->
    insert(Conn, "INSERT INTO upload_refs VALUES($1,'thread',1,0)", [private_id()]),
    try ?assertEqual(ok, validate(Conn, 1, private_id()))
    after sql(Conn, "DELETE FROM upload_refs") end.

stale_reference_does_not_grant_access(Conn) ->
    insert(Conn, "INSERT INTO upload_refs VALUES($1,'thread',999,0)", [private_id()]),
    try ?assertThrow({plainwire_error, attachment_unavailable}, validate(Conn, 1, private_id()))
    after sql(Conn, "DELETE FROM upload_refs") end.

edit_rebuilding_refs_cannot_publish_private_file(Conn) ->
    %% Replacing an old attachment takes the full ref-rebuild branch. It must
    %% perform the same authorization as the append-only branch, before UPDATE.
    ?assertThrow({plainwire_error, attachment_unavailable},
        pw_db:test_edit_thread({edit_thread, 1, 1, <<"Edited title">>, url(private_id())}, Conn)),
    {ok, _, [{Body}]} = epgsql:equery(Conn, "SELECT body FROM threads WHERE id=1", []),
    ?assertEqual(url(own_id()), Body),
    {ok, _, [{0}]} = epgsql:equery(Conn, "SELECT count(*) FROM upload_refs", []).

own_id() -> <<"owned-file-123456789012345">>.
private_id() -> <<"private-file-1234567890123">>.
pending_id() -> <<"pending-file-1234567890123">>.
url(Id) -> <<"/api/files/", Id/binary>>.
validate(Conn, Uid, Id) -> pw_db:test_validate_upload_refs(Conn, Uid, url(Id)).

sql(Conn, Statement) ->
    case epgsql:squery(Conn, Statement) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> erlang:error({fixture_sql, Other})
    end.
insert(Conn, Statement, Args) ->
    {ok, _} = epgsql:equery(Conn, Statement, Args), ok.
