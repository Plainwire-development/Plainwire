-module(pw_redis_tests).

-include_lib("eunit/include/eunit.hrl").

encode_command_uses_resp2_test() ->
    Packet = iolist_to_binary(pw_redis:encode_command([<<"SET">>, <<"hello">>, <<"world">>])),
    ?assertEqual(<<"*3\r\n$3\r\nSET\r\n$5\r\nhello\r\n$5\r\nworld\r\n">>, Packet).

parse_simple_and_integer_responses_test() ->
    ?assertEqual({ok, <<"PONG">>, <<>>}, pw_redis:parse_resp(<<"+PONG\r\n">>)),
    ?assertEqual({ok, 42, <<>>}, pw_redis:parse_resp(<<":42\r\n">>)).

parse_bulk_and_null_test() ->
    ?assertEqual({ok, <<"hello">>, <<>>}, pw_redis:parse_resp(<<"$5\r\nhello\r\n">>)),
    ?assertEqual({ok, undefined, <<>>}, pw_redis:parse_resp(<<"$-1\r\n">>)).

parse_array_response_test() ->
    ?assertEqual({ok, [<<"one">>, 2, undefined], <<>>},
        pw_redis:parse_resp(<<"*3\r\n$3\r\none\r\n:2\r\n$-1\r\n">>)).

partial_response_waits_for_more_test() ->
    ?assertEqual(more, pw_redis:parse_resp(<<"$5\r\nhel">>)),
    ?assertEqual(more, pw_redis:parse_resp(<<"*2\r\n$3\r\none\r\n">>)).

keys_are_prefixed_hashed_and_namespace_isolated_test() ->
    Previous = os:getenv("PLAINWIRE_REDIS_PREFIX"),
    os:putenv("PLAINWIRE_REDIS_PREFIX", "pwtest"),
    try
        A = pw_redis:redis_key(<<"cache">>, <<"same logical value">>),
        B = pw_redis:redis_key(<<"presence">>, <<"same logical value">>),
        ?assertMatch(<<"pwtest:cache:", _/binary>>, A),
        ?assertMatch(<<"pwtest:presence:", _/binary>>, B),
        ?assertNotEqual(A, B),
        ?assertEqual(nomatch, binary:match(A, <<"same logical value">>))
    after
        case Previous of false -> os:unsetenv("PLAINWIRE_REDIS_PREFIX"); V -> os:putenv("PLAINWIRE_REDIS_PREFIX", V) end
    end.
