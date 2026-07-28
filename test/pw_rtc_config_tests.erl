-module(pw_rtc_config_tests).

-include_lib("eunit/include/eunit.hrl").

default_config_test() ->
    with_env([], fun() ->
        ?assertEqual(#{iceServers => [#{urls => [<<"stun:stun.l.google.com:19302">>]}],
                iceTransportPolicy => <<"all">>},
            pw_rtc_config:get())
    end).

temporary_credentials_test() ->
    with_env([
        {"PLAINWIRE_TURN_URLS", "turn:relay.example:3478"},
        {"PLAINWIRE_TURN_SECRET", "01234567890123456789012345678901"},
        {"PLAINWIRE_TURN_USERNAME", "plainwire"}
    ], fun() ->
        #{iceServers := [_, Turn]} = pw_rtc_config:get(42),
        Username = maps:get(username, Turn),
        [Expiry, <<"plainwire-42">>] = binary:split(Username, <<":">>),
        ?assert(binary_to_integer(Expiry) > erlang:system_time(second)),
        ?assert(byte_size(base64:decode(maps:get(credential, Turn))) =:= 20)
    end).

turn_config_test() ->
    with_env([
        {"PLAINWIRE_STUN_URLS", "stun:one.example:3478, stun:two.example:3478"},
        {"PLAINWIRE_TURN_URLS", "turn:relay.example:3478,turns:relay.example:5349"},
        {"PLAINWIRE_TURN_USERNAME", "alice"},
        {"PLAINWIRE_TURN_CREDENTIAL", "secret"}
    ], fun() ->
        #{iceServers := [Stun, Turn]} = pw_rtc_config:get(),
        ?assertEqual([<<"stun:one.example:3478">>, <<"stun:two.example:3478">>], maps:get(urls, Stun)),
        ?assertEqual([<<"turn:relay.example:3478">>, <<"turns:relay.example:5349">>], maps:get(urls, Turn)),
        ?assertEqual(<<"alice">>, maps:get(username, Turn)),
        ?assertEqual(<<"secret">>, maps:get(credential, Turn))
    end).

with_env(Pairs, Fun) ->
    Names = ["PLAINWIRE_STUN_URLS", "PLAINWIRE_TURN_URLS",
        "PLAINWIRE_TURN_USERNAME", "PLAINWIRE_TURN_CREDENTIAL", "PLAINWIRE_TURN_SECRET",
        "PLAINWIRE_TURN_TTL_SECONDS", "PLAINWIRE_ICE_TRANSPORT_POLICY"],
    Old = [{Name, os:getenv(Name)} || Name <- Names],
    lists:foreach(fun os:unsetenv/1, Names),
    lists:foreach(fun({Name, Value}) -> os:putenv(Name, Value) end, Pairs),
    try Fun()
    after
        lists:foreach(fun
            ({Name, false}) -> os:unsetenv(Name);
            ({Name, Value}) -> os:putenv(Name, Value)
        end, Old)
    end.
