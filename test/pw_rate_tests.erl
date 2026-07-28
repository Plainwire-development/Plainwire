-module(pw_rate_tests).

-include_lib("eunit/include/eunit.hrl").

fixed_window_allows_until_limit_and_resets_test() ->
    OldTrap = process_flag(trap_exit, true),
    stop_if_running(),
    {ok, _} = pw_rate:start_link(),
    try
        Key = {test, self()},
        ?assert(pw_rate:allow(Key, 2, 10)),
        ?assert(pw_rate:allow(Key, 2, 10)),
        ?assertNot(pw_rate:allow(Key, 2, 10)),
        timer:sleep(15),
        ?assert(pw_rate:allow(Key, 2, 10))
    after
        stop_if_running(),
        process_flag(trap_exit, OldTrap)
    end.

concurrent_checks_enforce_exact_limit_test() ->
    OldTrap = process_flag(trap_exit, true),
    stop_if_running(),
    {ok, _} = pw_rate:start_link(),
    try
        Parent = self(),
        Key = {concurrent_test, make_ref()},
        [spawn(fun() -> Parent ! {allowed, pw_rate:allow(Key, 100, 60000)} end)
            || _ <- lists:seq(1, 1000)],
        Results = [receive {allowed, Allowed} -> Allowed after 5000 -> timeout end
            || _ <- lists:seq(1, 1000)],
        ?assertEqual(100, length([true || true <- Results])),
        ?assertEqual(0, length([timeout || timeout <- Results]))
    after
        stop_if_running(),
        process_flag(trap_exit, OldTrap)
    end.

stop_if_running() ->
    case whereis(pw_rate) of
        undefined -> ok;
        Pid ->
            exit(Pid, shutdown),
            wait_down(Pid)
    end.

wait_down(Pid) ->
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        erlang:demonitor(Ref, [flush]),
        ok
    end.
