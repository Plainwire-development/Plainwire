-module(pw_message_id_tests).
-include_lib("eunit/include/eunit.hrl").

layout_is_js_safe_test() ->
    ?assertEqual(9007199254740991, pw_message_id:max_id()),
    ?assert(pw_message_id:epoch_ms() > 0).

same_millisecond_sequence_test() ->
    Now = pw_message_id:epoch_ms() + 1000,
    {ok, A, Now, 0} = pw_message_id:test_generate(3, Now-1, 0, 2000, Now),
    {ok, B, Now, 1} = pw_message_id:test_generate(3, Now, 0, 2000, Now),
    ?assert(B > A),
    ?assert(B =< pw_message_id:max_id()),
    ?assertEqual(Now, pw_message_id:decode_timestamp(B)).

small_clock_rollback_uses_logical_time_test() ->
    Last = pw_message_id:epoch_ms() + 5000,
    {ok, _Id, Last, 8} = pw_message_id:test_generate(1, Last, 7, 2000, Last-25).

large_clock_rollback_is_rejected_test() ->
    Last = pw_message_id:epoch_ms() + 5000,
    {error, {clock_rollback, Delta}, Last, 7} = pw_message_id:test_generate(1, Last, 7, 2000, Last-2501),
    ?assert(Delta >= 2501).

node_bits_change_id_test() ->
    Now = pw_message_id:epoch_ms() + 9000,
    {ok, A, _, _} = pw_message_id:test_generate(1, Now-1, 0, 2000, Now),
    {ok, B, _, _} = pw_message_id:test_generate(2, Now-1, 0, 2000, Now),
    ?assert(A =/= B).

postgres_clock_anchor_ignores_wall_clock_test() ->
    DbNow = pw_message_id:epoch_ms() + 120000,
    ?assertEqual(DbNow + 37, pw_message_id:test_anchored_now(DbNow, 1000, 1037)),
    %% Monotonic time itself must never move the logical clock backwards.
    ?assertEqual(DbNow, pw_message_id:test_anchored_now(DbNow, 1000, 900)).
