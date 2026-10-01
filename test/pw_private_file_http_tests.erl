-module(pw_private_file_http_tests).
-include_lib("eunit/include/eunit.hrl").

%% Exercise the real file handler and sendfile/range/conditional responses.
%% Cached identity/ACL fixtures stand in for the database authority here.
private_download_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(F) -> ?_test(downloads(F)) end}.

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    OwnRate = case whereis(pw_rate) of undefined -> {ok, _} = pw_rate:start_link(), true; _ -> false end,
    Tables = [T || T <- [pw_session_cache, pw_upload_metadata_cache, pw_upload_authz_cache],
        ets:whereis(T) =:= undefined],
    [ets:new(T, [named_table, public, set]) || T <- Tables],
    Token = pw_util:random_token(24), Id = pw_util:random_token(24), Uid = 2000000000,
    Hash = pw_util:sha256_hex(Token),
    Path = filename:join("/tmp", "plainwire-private-http-" ++ binary_to_list(Id)),
    Bytes = <<"private attachment">>, FileHash = pw_util:sha256_hex(Bytes),
    ok = file:write_file(Path, Bytes),
    ets:insert(pw_session_cache, {Hash, #{user => #{id => Uid}}, pw_util:now_ms() + 60000}),
    Expires = erlang:monotonic_time(millisecond) + 60000,
    ets:insert(pw_upload_authz_cache, {{Uid, Id}, true, Expires}),
    ets:insert(pw_upload_metadata_cache, {Id, {ok, #{path => list_to_binary(Path),
        name => <<"private.txt">>, content_type => <<"text/plain">>,
        size => byte_size(Bytes), sha256 => FileHash}}, Expires}),
    Ref = make_ref(),
    Routes = cowboy_router:compile([{'_', [{"/api/files/[...]", pw_file_hdl, []},
        {"/api/uploads", pw_upload_hdl, []}]}]),
    {ok, _} = cowboy:start_clear(Ref, #{socket_opts => [{ip, {127,0,0,1}}, {port, 0}]},
        #{env => #{dispatch => Routes}}),
    #{ref => Ref, port => ranch:get_port(Ref), tables => Tables, rate => OwnRate,
      id => Id, token => Token, session_hash => Hash, path => Path, uid => Uid,
      bytes => Bytes, etag => <<"\"", FileHash/binary, "\"">>}.

cleanup(#{ref := Ref, tables := Tables, rate := OwnRate, id := Id,
          session_hash := Hash, path := Path, uid := Uid}) ->
    cowboy:stop_listener(Ref), file:delete(Path),
    ets:delete(pw_session_cache, Hash), ets:delete(pw_upload_metadata_cache, Id),
    ets:delete(pw_upload_authz_cache, {Uid, Id}),
    [ets:delete(T) || T <- Tables],
    case OwnRate of true -> gen_server:stop(pw_rate); false -> ok end.

downloads(F = #{id := Id, uid := Uid, bytes := Bytes, etag := Etag}) ->
    Path = <<"/api/files/", Id/binary>>,
    {200, Headers, Bytes} = request(F, Path, get, []),
    Policy = proplists:get_value(<<"cache-control">>, Headers),
    ?assertNotEqual(nomatch, binary:match(Policy, <<"no-cache">>)),
    ?assertNotEqual(nomatch, binary:match(Policy, <<"must-revalidate">>)),
    ?assertEqual(nomatch, binary:match(Policy, <<"immutable">>)),
    ?assertEqual(<<"cookie">>, proplists:get_value(<<"vary">>, Headers)),
    {304, _, <<>>} = request(F, Path, get, [{<<"if-none-match">>, Etag}]),
    {206, _, <<"private">>} = request(F, Path, get, [{<<"range">>, <<"bytes=0-6">>}]),
    {200, _, <<>>} = request(F, Path, head, []),
    %% Removing authorization must reject even a matching validator. Neither
    %% range nor HEAD may turn a revoked file back into a readable resource.
    pw_upload_gc:invalidate_user(Uid),
    [begin {Status, _, _} = request(F, Path, Method, Extra), ?assertEqual(404, Status) end ||
        {Method, Extra} <- [{get, [{<<"if-none-match">>, Etag}]}, {head, []},
                           {get, [{<<"range">>, <<"bytes=0-6">>}]}]],
    %% A database outage during upload authentication is retryable, not a
    %% logout instruction. A missing cookie remains unauthenticated.
    Unknown = F#{token => <<"expired-session">>},
    {503, _, _} = request(Unknown, <<"/api/uploads">>, post, []),
    {401, _, _} = request(F#{token => <<>>}, <<"/api/uploads">>, post, []).

request(#{port := Port, token := Token}, Path, Method, Extra) ->
    {ok, Conn} = gun:open({127,0,0,1}, Port, #{transport => tcp, protocols => [http]}),
    try
        {ok, http} = gun:await_up(Conn),
        Cookie = case Token of <<>> -> []; _ -> [{<<"cookie">>, <<"pw_session=", Token/binary>>}] end,
        Stream = case Method of
            get -> gun:get(Conn, Path, Cookie ++ Extra);
            head -> gun:head(Conn, Path, Cookie ++ Extra);
            post -> gun:post(Conn, Path, Cookie ++ Extra, <<>>)
        end,
        {response, Fin, Status, Headers} = gun:await(Conn, Stream),
        Body = case Fin of fin -> <<>>; nofin -> {ok, Data} = gun:await_body(Conn, Stream), Data end,
        {Status, Headers, Body}
    after gun:close(Conn) end.
