-module(pw_server_workspace_tests).
-include_lib("eunit/include/eunit.hrl").

server_workspace_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port -> {setup, fun() -> setup(list_to_integer(Port)) end, fun epgsql:close/1,
            fun(Conn) -> [?_test(workspace(Conn))] end}
    end.

setup(Port) ->
    {ok, Conn} = epgsql:connect(#{host => "127.0.0.1", port => Port,
        username => os:getenv("PLAINWIRE_TEST_POSTGRES_USER", "plainwire_audit"),
        database => os:getenv("PLAINWIRE_TEST_POSTGRES_DB", "postgres"), timeout => 5000}),
    sql(Conn, "CREATE TEMP TABLE users(id integer PRIMARY KEY,group_dm_count bigint DEFAULT 0,server_layout text DEFAULT '[]',server_layout_revision integer DEFAULT 0)"),
    sql(Conn, "CREATE TEMP TABLE servers(id serial PRIMARY KEY,owner_id integer,name text,description text,icon_url text,created_at bigint,updated_at bigint,default_permissions bigint DEFAULT " ++ integer_to_list(pw_permissions:member_default()) ++ ")"),
    sql(Conn, "CREATE TEMP TABLE server_members(server_id integer,user_id integer,role text,muted boolean,joined_at bigint)"),
    sql(Conn, "CREATE TEMP TABLE channel_categories(id serial PRIMARY KEY,server_id integer,name text,position integer,created_at bigint)"),
    sql(Conn, "CREATE TEMP TABLE channels(id serial PRIMARY KEY,server_id integer,name text,kind text,position integer,topic text,created_at bigint,category_id integer,slowmode_seconds integer DEFAULT 0)"),
    sql(Conn, "CREATE TEMP TABLE server_roles(id serial PRIMARY KEY,server_id integer,name text,color text,permissions bigint,position integer,hoist boolean,mentionable boolean,created_at bigint,updated_at bigint)"),
    sql(Conn, "CREATE TEMP TABLE server_member_roles(server_id integer,user_id integer,role_id integer)"),
    sql(Conn, "CREATE TEMP TABLE direct_threads(id serial PRIMARY KEY,name text,avatar_url text,owner_id integer,created_at bigint,updated_at bigint)"),
    sql(Conn, "CREATE TEMP TABLE direct_members(thread_id integer,user_id integer,last_read_message_id bigint,muted boolean,nickname text,joined_at bigint,request_state text,group_role text,UNIQUE(thread_id,user_id))"),
    sql(Conn, "CREATE TEMP TABLE friendships(user_low integer,user_high integer,status text)"),
    sql(Conn, "SET search_path=pg_temp"),
    sql(Conn, "INSERT INTO users(id) VALUES(1),(2),(3)"),
    sql(Conn, "INSERT INTO friendships VALUES(1,2,'accepted')"),
    Conn.

workspace(Conn) ->
    {ok, #{id := First}} = run(Conn, {create_server, 1, <<"First">>, <<>>, null}),
    {ok, #{id := Second}} = run(Conn, {create_server, 1, <<"Second">>, <<>>, <<"gaming">>}),
    {ok, #{id := Foreign}} = run(Conn, {create_server, 2, <<"Other account">>, <<>>, null}),
    ?assertEqual({error, server_exists}, run(Conn, {create_server, 1, <<"FIRST">>, <<>>, null})),
    ?assertEqual({error, invalid_channel_kind}, run(Conn, {create_channel, 1, First, <<"unsupported">>, <<"stage">>, null})),
    ?assertEqual({error, invalid_server_template}, run(Conn, {create_server, 1, <<"Bad import">>, <<>>, #{<<"channels">> => []}})),
    ?assertEqual({error, forbidden}, run(Conn, {server_template, 2, First})),
    {ok, BlankExport} = run(Conn, {server_template, 1, First}),
    ?assertMatch({ok, _, true}, pw_server_template:normalize(jsx:decode(pw_util:json(BlankExport), [return_maps]))),
    Folder = #{<<"id">> => <<"folder-1">>, <<"name">> => <<"Friends">>, <<"server_ids">> => [First,Second], <<"collapsed">> => false},
    ?assertMatch({ok, #{revision := 1}}, run(Conn, {save_server_layout, 1, [Folder], 0})),
    ?assertEqual({error, server_layout_changed}, run(Conn, {save_server_layout, 1, [], 0})),
    ?assertEqual({error, invalid_server_layout}, run(Conn, {save_server_layout, 1, [#{<<"server_id">> => Foreign}], 1})),
    ?assertMatch({ok, #{items := [Folder], revision := 1}}, run(Conn, {server_layout, 1})),
    ?assertMatch({ok, #{items := [#{<<"server_id">> := Foreign}], revision := 0}}, run(Conn, {server_layout, 2})),
    Import = #{<<"channels">> => [#{<<"name">> => <<"planning">>, <<"kind">> => <<"text">>, <<"category">> => 0}],
        <<"categories">> => [#{<<"name">> => <<"Project">>}],
        <<"roles">> => [#{<<"name">> => <<"Staff">>, <<"permissions">> => 1073741824}], <<"permissions_review">> => false, <<"default_permissions">> => 1073741824},
    {ok, #{id := Imported, permissions_review := true}} = run(Conn, {create_server, 1, <<"Imported">>, <<>>, Import}),
    ?assertEqual([[0]], query(Conn, "SELECT default_permissions FROM servers WHERE id=$1", [Imported])),
    ?assertEqual([[0]], query(Conn, "SELECT permissions FROM server_roles WHERE server_id=$1", [Imported])),
    {ok, Export} = run(Conn, {server_template, 1, Imported}),
    ?assertMatch({ok, _, true}, pw_server_template:normalize(jsx:decode(pw_util:json(Export), [return_maps]))),
    ?assertMatch({ok, #{items := [Folder, #{<<"server_id">> := Imported}]}}, run(Conn, {server_layout, 1})),
    sql(Conn, "DELETE FROM server_members WHERE user_id=1 AND server_id=" ++ integer_to_list(First)),
    ?assertMatch({ok, #{items := [#{<<"server_ids">> := [Second]}, #{<<"server_id">> := Imported}]}}, run(Conn, {server_layout, 1})),
    {ok, #{id := G1}} = run(Conn, {create_group, 1, <<>>, [2,3]}),
    ?assertEqual([[<<"group dm 1">>]], query(Conn, "SELECT name FROM direct_threads WHERE id=$1", [G1])),
    {ok, _} = run(Conn, {create_group, 1, <<"Custom group">>, [2,3]}),
    {ok, _} = run(Conn, {create_group, 1, <<>>, [2]}),
    sql(Conn, "DELETE FROM direct_threads WHERE id=" ++ integer_to_list(G1)),
    {ok, #{id := G3}} = run(Conn, {create_group, 1, <<>>, [2,3]}),
    ?assertEqual([[<<"group dm 3">>]], query(Conn, "SELECT name FROM direct_threads WHERE id=$1", [G3])),
    ?assertEqual([[3]], query(Conn, "SELECT group_dm_count FROM users WHERE id=1", [])).

run(Conn, Msg) -> pw_db:test_server_workspace(Msg, Conn).
query(Conn, Sql, Params) -> {ok, _, Rows} = epgsql:equery(Conn, Sql, Params), [tuple_to_list(R) || R <- Rows].
sql(Conn, Sql) ->
    case epgsql:squery(Conn, Sql) of
        {ok, _, _} -> ok;
        {ok, _} -> ok;
        Other -> erlang:error({fixture_sql, Other})
    end.
