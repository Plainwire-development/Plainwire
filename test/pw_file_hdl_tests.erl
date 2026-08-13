-module(pw_file_hdl_tests).
-include_lib("eunit/include/eunit.hrl").

full_file_without_range_test() ->
    ?assertEqual(full, pw_file_hdl:range_bounds(<<>>, 1000)).

bounded_range_test() ->
    ?assertEqual({partial, 100, 100, 199}, pw_file_hdl:range_bounds(<<"bytes=100-199">>, 1000)).

open_ended_range_test() ->
    ?assertEqual({partial, 900, 100, 999}, pw_file_hdl:range_bounds(<<"bytes=900-">>, 1000)).

suffix_range_test() ->
    ?assertEqual({partial, 900, 100, 999}, pw_file_hdl:range_bounds(<<"bytes=-100">>, 1000)).

range_is_clamped_to_file_test() ->
    ?assertEqual({partial, 950, 50, 999}, pw_file_hdl:range_bounds(<<"bytes=950-5000">>, 1000)).

invalid_and_multiple_ranges_test() ->
    ?assertEqual(invalid, pw_file_hdl:range_bounds(<<"bytes=100-50">>, 1000)),
    ?assertEqual(invalid, pw_file_hdl:range_bounds(<<"bytes=0-1,4-5">>, 1000)),
    ?assertEqual(invalid, pw_file_hdl:range_bounds(<<"items=0-5">>, 1000)).
