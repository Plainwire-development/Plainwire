-module(pw_message_store_scylla_tests).
-include_lib("eunit/include/eunit.hrl").

live_message_visibility_test() ->
    ?assert(pw_message_store_scylla:test_message_visible(#{deleted_at => undefined})),
    ?assert(pw_message_store_scylla:test_message_visible(#{deleted_at => null})),
    ?assert(pw_message_store_scylla:test_message_visible(#{deleted_at => 0})),
    ?assert(pw_message_store_scylla:test_message_visible(#{})).

deleted_message_visibility_test() ->
    ?assertNot(pw_message_store_scylla:test_message_visible(#{deleted_at => 1767225600000})),
    ?assertNot(pw_message_store_scylla:test_message_visible(not_a_message)).
