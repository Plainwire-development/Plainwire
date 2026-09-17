-module(pw_message_bucket_tests).
-include_lib("eunit/include/eunit.hrl").

day_bucket_test() ->
    T = 1767225600000 + 12345,
    B = pw_message_bucket:for_timestamp(T, day),
    ?assert(B =< T),
    ?assertEqual(B + 86400000, hd(tl(pw_message_bucket:next(B, 2, day)))).

month_boundary_test() ->
    Jan = pw_message_bucket:for_timestamp(1768435200000, month),
    [Jan, Feb] = pw_message_bucket:next(Jan, 2, month),
    ?assert(Feb > Jan),
    [Feb, Jan2] = pw_message_bucket:previous(Feb, 2, month),
    ?assertEqual(Jan, Jan2).
