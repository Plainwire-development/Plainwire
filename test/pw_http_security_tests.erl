-module(pw_http_security_tests).
-include_lib("eunit/include/eunit.hrl").

http_security_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun({_, Port, _}) -> [
        ?_test(begin
            {Status, _, _} = request(Port, <<"/api/login">>,
                [{<<"content-type">>, <<"text/plain">>}], <<"{\"username\":\"audit\",\"password\":\"password\",\"padding\":\"=\"}">>),
            ?assertEqual(415, Status)
        end),
        ?_test(begin
            {Status, _, _} = request(Port, <<"/api/login">>, [], <<"{}">>),
            ?assertEqual(415, Status)
        end),
        ?_test(begin
            {Status, _, _} = request(Port, <<"/api/login">>,
                [{<<"content-type">>, <<"Application/JSON; charset=utf-8">>}], <<"not JSON">>),
            ?assertEqual(400, Status)
        end),
        ?_test(begin
            Body = <<"{}", (binary:copy(<<" ">>, 1048575))/binary>>,
            {Status, _, _} = request(Port, <<"/api/login">>,
                [{<<"content-type">>, <<"application/json">>}], Body),
            ?assertEqual(413, Status)
        end),
        ?_test(begin
            {Status, _, _} = request(Port, <<"/api/enroll">>,
                [{<<"content-type">>, <<"text/plain">>}], <<"{}">>),
            ?assertEqual(415, Status)
        end),
        ?_test(begin
            {Status, _, _} = request(Port, <<"/api/enroll">>,
                [{<<"content-type">>, <<"application/json">>}], <<"not JSON">>),
            ?assertEqual(400, Status)
        end),
        ?_test(begin
            {Status, Headers, Body} = request(Port, <<"/assets/plugin-worker.js">>, get, <<>>),
            ?assertEqual(200, Status),
            Csp = proplists:get_value(<<"content-security-policy">>, Headers),
            ?assertNotEqual(nomatch, binary:match(Csp, <<"connect-src 'none'">>)),
            ?assertNotEqual(nomatch, binary:match(Csp, <<"worker-src 'none'">>)),
            ?assertNotEqual(nomatch, binary:match(Body, <<"initialize">>)),
            PageCsp = maps:get(<<"content-security-policy">>, pw_util:security_headers()),
            ?assertEqual(nomatch, binary:match(PageCsp, <<"'unsafe-eval'">>))
        end)
    ] end}.

setup() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    OwnRate = case whereis(pw_rate) of
        undefined -> {ok, _} = pw_rate:start_link(), true;
        _ -> false
    end,
    Ref = make_ref(),
    Dispatch = cowboy_router:compile([{'_', [
        {"/assets/plugin-worker.js", pw_plugin_worker, []},
        {"/api/enroll", pw_admin_api, []},
        {"/api/[...]", pw_api, []}
    ]}]),
    {ok, _} = cowboy:start_clear(Ref, #{socket_opts => [{ip, {127,0,0,1}}, {port, 0}]},
        #{env => #{dispatch => Dispatch}}),
    {Ref, ranch:get_port(Ref), OwnRate}.

cleanup({Ref, _, OwnRate}) ->
    cowboy:stop_listener(Ref),
    case OwnRate of true -> gen_server:stop(pw_rate); false -> ok end.

request(Port, Path, Headers, Body) ->
    {ok, Conn} = gun:open({127,0,0,1}, Port, #{transport => tcp, protocols => [http]}),
    try
        {ok, http} = gun:await_up(Conn),
        Stream = case Headers of
            get -> gun:get(Conn, Path);
            _ -> gun:post(Conn, Path, Headers, Body)
        end,
        {response, Fin, Status, ResponseHeaders} = gun:await(Conn, Stream),
        ResponseBody = case Fin of
            fin -> <<>>;
            nofin -> {ok, Bytes} = gun:await_body(Conn, Stream), Bytes
        end,
        {Status, ResponseHeaders, ResponseBody}
    after gun:close(Conn) end.
