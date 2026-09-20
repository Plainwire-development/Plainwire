-module(pw_media_quality_tests).
-include_lib("eunit/include/eunit.hrl").

sample_validation_test() ->
    ?assertMatch({ok, _}, pw_media_quality:validate(rows())),
    ?assertMatch({error, _}, pw_media_quality:validate([])),
    ?assertMatch({error, _}, pw_media_quality:validate(lists:duplicate(25, hd(rows())))),
    ?assertMatch({error, _}, pw_media_quality:validate([[0, 101, 1, 1, 1, 1, 1, 1, 1]])),
    ?assertMatch({error, _}, pw_media_quality:validate([[0, -0.5, 1, 1, 1, 1, 1, 1, 1]])),
    ?assertMatch({error, _}, pw_media_quality:validate([[0, 0]])),
    ?assertMatch({error, _}, pw_media_quality:validate([hd(rows()), hd(rows())])).

native_output_and_policy_test() ->
    ?assertMatch({error, _}, pw_media_quality:decode(<<1,2,3>>)),
    ?assertMatch({error, _}, pw_media_quality:decode(binary:copy(<<255>>, 104))),
    ?assertEqual(insufficient_data, pw_media_quality:policy(#{score => null})),
    ?assertEqual(reduce_screen_bitrate, pw_media_quality:policy(#{score => 40, upstream_loss_pct => 8})),
    ?assertEqual(audio_gaps, pw_media_quality:policy(#{score => 50, upstream_loss_pct => null, concealment_pct => 8})),
    ?assertEqual(healthy, pw_media_quality:policy(#{score => 96, upstream_loss_pct => null})).

extended_output_test() ->
    Legacy = [99, 99, 0, 5, 40, 0, 20, -1, -1000000000, -1000000000, 8, 100, 6],
    Encode = fun(Vs) -> << <<(float(V)):64/float-big>> || V <- Vs >> end,
    ?assertMatch({ok, #{recent_score := null}}, pw_media_quality:decode(Encode(Legacy))),
    Extended = Legacy ++ [95, 60, 0, 0, 45, 100],
    ?assertMatch({ok, #{recommendation := reduce_screen_bitrate, upstream_score := 60.0}},
                 pw_media_quality:decode(Encode(Extended))),
    ?assertMatch({error, _}, pw_media_quality:decode(Encode(Legacy ++ [101, 60, 0, 0, 45, 100]))),
    ?assertEqual(reduce_screen_bitrate, pw_media_quality:policy(#{score => null, upstream_score => 60, upstream_loss_pct => 8})),
    ?assertEqual(burst_packet_loss, pw_media_quality:policy(#{score => 70, loss_burst_seconds => 15, loss_burst_pct => 30})),
    ?assertEqual(deteriorating_connection, pw_media_quality:policy(#{score => 85, recent_score => 60,
        confidence_pct => 80, jitter_trend => 10, loss_trend => 2})).

missing_worker_fallback_test() ->
    {ok, Worker} = pw_media_quality:start_link("/no/such/plainwire-quality"),
    try
        ?assertEqual(false, pw_media_quality:available()),
        ?assertEqual({error, unavailable}, pw_media_quality:submit(self(), <<"req">>, 2, rows())),
        ?assert(is_process_alive(Worker))
    after gen_server:stop(Worker) end.

native_crash_isolation_test() ->
    {ok, Worker} = pw_media_quality:start_link("/bin/cat"),
    try
        ?assert(pw_media_quality:available()),
        ?assertEqual(ok, pw_media_quality:submit(self(), <<"bad-worker">>, 2, rows())),
        receive {quality_result, <<"bad-worker">>, 2, #{unavailable := true}} -> ok after 1500 -> ?assert(false) end,
        ?assert(is_process_alive(Worker)),
        ?assertNot(pw_media_quality:available())
    after gen_server:stop(Worker) end.

native_calculation_test_() ->
    case os:getenv("PLAINWIRE_TEST_NATIVE") of
        "1" -> fun native_calculation/0;
        _ -> []
    end.
native_calculation() ->
    {ok, Worker} = pw_media_quality:start_link(filename:absname("priv/bin/pw-media-quality")),
    try
        ?assert(pw_media_quality:available()),
        ok = pw_media_quality:submit(self(), <<"good">>, 2, rows()),
        receive
            {quality_result, <<"good">>, 2, R} ->
                ?assert(maps:get(score, R) >= 95),
                ?assertEqual(healthy, maps:get(recommendation, R)),
                ?assert(maps:get(recent_score, R) >= 95),
                ?assert(maps:get(confidence_pct, R) < 34),
                ?assertEqual(5.0, maps:get(jitter_p95_ms, R))
        after 1500 -> ?assert(false) end,
        Poor = [[T, 10, 90, 500, 15, 150, 24, 24, 10] || T <- [0,5,10]],
        ok = pw_media_quality:submit(self(), <<"poor">>, 2, Poor),
        receive
            {quality_result, <<"poor">>, 2, R2} ->
                ?assert(maps:get(score, R2) < 40),
                ?assertEqual(reduce_screen_bitrate, maps:get(recommendation, R2))
        after 1500 -> ?assert(false) end
    after gen_server:stop(Worker) end.
rows() -> [[T, 0, 5, 40, 0, 20, 24, 24, -1] || T <- [0,5,10]].

recovery_policy_test() ->
    ?assertEqual(connection_recovered, pw_media_quality:policy(#{score => 60, recent_score => 95, confidence_pct => 80})),
    ?assertNotEqual(connection_recovered, pw_media_quality:policy(#{score => 60, recent_score => 95, confidence_pct => 10})).
