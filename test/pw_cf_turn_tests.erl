-module(pw_cf_turn_tests).
-include_lib("eunit/include/eunit.hrl").

credentials_validation_test() ->
    Good = #{<<"iceServers">> => [#{<<"urls">> => [<<"stun:stun.cloudflare.com:3478">>]},
                                 #{<<"urls">> => [<<"turns:turn.cloudflare.com:443?transport=tcp">>],
                                   <<"username">> => <<"temporary-user">>, <<"credential">> => <<"temporary-password">>}]},
    ?assertMatch({ok, #{urls := [_]}}, pw_cf_turn:parse_credentials(jsx:encode(Good))),
    ?assertMatch({error, _}, pw_cf_turn:parse_credentials(<<"{}">>)),
    ?assertMatch({error, _}, pw_cf_turn:parse_credentials(binary:copy(<<"x">>, 262145))),
    [_, Turn] = maps:get(<<"iceServers">>, Good),
    lists:foreach(fun(Urls) ->
        Bad = Good#{<<"iceServers">> => [Turn#{<<"urls">> => Urls}]},
        ?assertMatch({error, _}, pw_cf_turn:parse_credentials(jsx:encode(Bad)))
    end, [[], [<<"turn:evil.example:3478?transport=udp">>], [<<"javascript:alert(1)">>], <<"not-an-array">>]),
    ?assertMatch({error, _}, pw_cf_turn:parse_credentials(jsx:encode(Good#{<<"iceServers">> => [Turn#{<<"credential">> => <<>>}]}))).

analytics_validation_test() ->
    Good = #{<<"data">> => #{<<"viewer">> => #{<<"accounts">> => [#{<<"callsTurnUsageAdaptiveGroups">> => [#{<<"sum">> => #{<<"egressBytes">> => 12000}}]}]}}, <<"errors">> => null},
    ?assertEqual({ok, 12000}, pw_cf_turn:parse_usage(jsx:encode(Good))),
    ?assertMatch({error, _}, pw_cf_turn:parse_usage(jsx:encode(Good#{<<"errors">> => [#{<<"message">> => <<"denied">>}]}))),
    ?assertMatch({error, _}, pw_cf_turn:parse_usage(<<"{\"data\":{\"viewer\":{\"accounts\":[]}}}">>)),
    ?assertMatch({error, _}, pw_cf_turn:parse_usage(<<"{\"data\":{\"viewer\":{\"accounts\":[{\"callsTurnUsageAdaptiveGroups\":[{\"sum\":{}}]}]}}}">>)).

budget_fail_closed_test() ->
    Now = erlang:monotonic_time(second),
    {{Y, M, _}, _} = calendar:universal_time(),
    Month = iolist_to_binary(io_lib:format("~4..0B-~2..0B-01", [Y, M])),
    ?assertEqual(ok, pw_cf_turn:budget_state(unknown, Now, false)),
    ?assertEqual(usage_unavailable, pw_cf_turn:budget_state(unknown, Now, true)),
    ?assertEqual(ok, pw_cf_turn:budget_state({false, Now, Month}, Now, true)),
    ?assertEqual(over_limit, pw_cf_turn:budget_state({true, Now, Month}, Now, true)),
    ?assertEqual(usage_unavailable, pw_cf_turn:budget_state({false, Now - 901, Month}, Now, true)),
    ?assertEqual(usage_unavailable, pw_cf_turn:budget_state({false, Now, <<"2000-01-01">>}, Now, true)).

per_user_cache_and_coalescing_test() ->
    with_env(fun() ->
        Parent = self(),
        {ok, Server} = pw_cf_turn:start_link(fun(Uid) -> Parent ! {mint, Uid}, timer:sleep(40), {ok, entry(Uid)} end),
        try
            [spawn(fun() -> Parent ! {reply, pw_cf_turn:ice_entry(1)} end) || _ <- lists:seq(1, 8)],
            receive {mint, 1} -> ok after 500 -> ?assert(false) end,
            [receive {reply, {ok, #{username := <<"1">>}, TTL}} -> ?assert(TTL > 300) after 1000 -> ?assert(false) end || _ <- lists:seq(1, 8)],
            receive {mint, 1} -> ?assert(false) after 0 -> ok end,
            ?assertMatch({ok, #{username := <<"1">>}, _}, pw_cf_turn:ice_entry(1)),
            ?assertMatch({ok, #{username := <<"2">>}, _}, pw_cf_turn:ice_entry(2)),
            receive {mint, 2} -> ok after 500 -> ?assert(false) end,
            ?assertEqual({error, unauthorized}, pw_cf_turn:ice_entry(undefined))
        after gen_server:stop(Server) end
    end).

worker_failure_backoff_test() ->
    with_env(fun() ->
        Parent = self(),
        {ok, Server} = pw_cf_turn:start_link(fun(_) -> Parent ! attempted, exit(simulated_failure) end),
        try
            ?assertEqual({error, unavailable}, pw_cf_turn:ice_entry(1)),
            receive attempted -> ok after 500 -> ?assert(false) end,
            ?assertEqual({error, unavailable}, pw_cf_turn:ice_entry(2)),
            receive attempted -> ?assert(false) after 0 -> ok end,
            ?assert(is_process_alive(Server))
        after gen_server:stop(Server) end
    end).

with_env(Fun) ->
    Values = [{"PLAINWIRE_CF_TURN_KEY_ID", "key-123456789"}, {"PLAINWIRE_CF_TURN_API_TOKEN", "test-token-123456789012345"}, {"PLAINWIRE_CF_ACCOUNT_ID", ""}],
    Old = [{K, os:getenv(K)} || {K, _} <- Values],
    [os:putenv(K, V) || {K, V} <- Values],
    try ?assertEqual(ok, pw_cf_turn:validate()), Fun()
    after [case V of false -> os:unsetenv(K); _ -> os:putenv(K, V) end || {K, V} <- Old] end.
entry(Uid) -> #{urls => [<<"turns:turn.cloudflare.com:443?transport=tcp">>], username => integer_to_binary(Uid), credential => <<"test-secret">>}.
