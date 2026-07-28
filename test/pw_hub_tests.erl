-module(pw_hub_tests).

-include_lib("eunit/include/eunit.hrl").

self_is_included_in_presence_watch_test() ->
    stop_existing_hub(),
    {ok, Hub} = pw_hub:start_link(),
    try
        pw_hub:connect(42, self(), <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        flush_presence_state(),
        pw_hub:watch_presence(self(), []),
        _ = gen_server:call(pw_hub, sync),
        receive
            {hub_json, #{type := presence_state, statuses := Statuses}} ->
                ?assertEqual(<<"online">>, maps:get(42, Statuses))
        after 1000 ->
            ?assert(false)
        end
    after
        gen_server:stop(Hub)
    end.

flush_presence_state() ->
    receive
        {hub_json, #{type := presence_state}} -> ok
    after 1000 ->
        ?assert(false)
    end.

stop_existing_hub() ->
    case whereis(pw_hub) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end.
