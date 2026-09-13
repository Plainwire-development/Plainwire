-module(pw_db_tests).
-include_lib("eunit/include/eunit.hrl").

extract_file_ids_basic_test() ->
    ?assertEqual([], pw_db:extract_file_ids(<<>>)),
    ?assertEqual([], pw_db:extract_file_ids(<<"hello world">>)).

extract_file_ids_single_test() ->
    Id = <<"abcdefghijklmnopqrstuvwxyz1234">>,
    Body = <<"check out /api/files/", Id/binary, "/download">>,
    ?assertEqual([Id], pw_db:extract_file_ids(Body)).

extract_file_ids_multiple_test() ->
    Id1 = <<"abcdefghijklmnopqrstuvwx">>,
    Id2 = <<"ABCDEFGHIJKLMNOPQRSTUVWX">>,
    Id3 = <<"0123456789abcdefghijklmnop">>,
    Body = <<"/api/files/", Id1/binary, " /api/files/", Id2/binary, " /api/files/", Id3/binary>>,
    Result = pw_db:extract_file_ids(Body),
    ?assertEqual(3, length(Result)),
    ?assert(lists:member(Id1, Result)),
    ?assert(lists:member(Id2, Result)),
    ?assert(lists:member(Id3, Result)).

extract_file_ids_rejects_short_id_test() ->
    ?assertEqual([], pw_db:extract_file_ids(<<"/api/files/short">>)).

extract_file_ids_rejects_empty_after_prefix_test() ->
    ?assertEqual([], pw_db:extract_file_ids(<<"/api/files/">>)).

extract_file_ids_dedup_test() ->
    Id = <<"abcdefghijklmnopqrstuvwx">>,
    Body = <<"/api/files/", Id/binary, " /api/files/", Id/binary>>,
    Result = pw_db:extract_file_ids(Body),
    ?assertEqual([Id], Result).

session_cache_unavailable_is_controlled_test() ->
    ?assertEqual({error, database_unavailable}, pw_db:session_fast(<<"missing-cache-token">>)).

idle_websocket_expires_without_incoming_frames_test() ->
    State = #{uid => 999, token => <<"expired-test-token">>, subs => [],
        voice => undefined, call => undefined,
        last_auth_check => erlang:monotonic_time(millisecond) - 61000},
    ?assertEqual({stop, State}, pw_ws:websocket_info(revalidate_auth, State)).

invite_options_test() ->
    ?assertEqual({ok, 1, 86400}, pw_db:invite_options(1, 86400)),
    ?assertEqual({ok, 0, 0}, pw_db:invite_options(0, 0)),
    [ ?assertMatch({error, invalid_invite_options}, pw_db:invite_options(M, E))
      || {M, E} <- [{-1, 86400}, {10001, 86400}, {0, -1}, {0, 1}, {0, 2592001}, {<<"1">>, 3600}, {1, null}] ].
