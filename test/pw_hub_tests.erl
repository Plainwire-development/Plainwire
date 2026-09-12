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


connect_seeds_own_presence_state_test() ->
    stop_existing_hub(),
    {ok, Hub} = pw_hub:start_link(),
    try
        pw_hub:connect(84, self(), <<"away">>),
        _ = gen_server:call(pw_hub, sync),
        receive
            {hub_json, #{type := presence_state, online := Online, statuses := Statuses}} ->
                ?assert(lists:member(84, Online)),
                ?assertEqual(<<"away">>, maps:get(84, Statuses))
        after 1000 ->
            ?assert(false)
        end
    after
        gen_server:stop(Hub)
    end.

call_accept_establishes_bidirectional_signaling_test() ->
    stop_existing_hub(),
    {ok, Hub} = pw_hub:start_link(),
    Parent = self(),
    Caller = spawn(fun() -> socket_loop(Parent, rtc_caller) end),
    Callee = spawn(fun() -> socket_loop(Parent, rtc_callee) end),
    Profile1 = #{id => 1, display_name => <<"Caller">>, avatar_url => <<>>},
    Profile2 = #{id => 2, display_name => <<"Callee">>, avatar_url => <<>>},
    try
        pw_hub:connect(1, Caller, <<"online">>),
        pw_hub:connect(2, Callee, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        pw_hub:call_ring(501, 1, Caller, Profile1, [2]),
        _ = gen_server:call(pw_hub, sync),
        ok = pw_hub:call_accept(501, 2, Callee, Profile2, [1]),

        CallerState = await_call_roster(rtc_caller, 501, 2),
        CalleeState = await_call_roster(rtc_callee, 501, 2),
        ?assertEqual([1, 2], lists:sort([maps:get(user_id, U) || U <- maps:get(users, CallerState)])),
        ?assertEqual([1, 2], lists:sort([maps:get(user_id, U) || U <- maps:get(users, CalleeState)])),

        Offer = #{kind => offer, sdp => #{type => offer, sdp => <<"v=0">>}},
        Answer = #{kind => answer, sdp => #{type => answer, sdp => <<"v=0">>}},
        pw_hub:call_signal(501, 1, Caller, 2, Offer),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(Offer, maps:get(signal, await_event(rtc_callee, call_signal, 501))),
        pw_hub:call_signal(501, 2, Callee, 1, Answer),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(Answer, maps:get(signal, await_event(rtc_caller, call_signal, 501)))
    after
        exit(Caller, kill),
        exit(Callee, kill),
        gen_server:stop(Hub)
    end.

call_presence_and_cross_room_eviction_test() ->
    stop_existing_hub(),
    {ok, Hub} = pw_hub:start_link(),
    Parent = self(),
    P1 = spawn(fun() -> socket_loop(Parent, one) end),
    P1b = spawn(fun() -> socket_loop(Parent, one_b) end),
    P2 = spawn(fun() -> socket_loop(Parent, two) end),
    try
        pw_hub:connect(1, P1, <<"online">>),
        pw_hub:connect(2, P2, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        Profile = #{id => 1, display_name => <<"One">>, avatar_url => <<>>},
        ok = pw_hub:call_join(77, 1, P1, Profile, [2]),
        First = await_event(two, call_presence, 77),
        ?assertEqual(true, maps:get(active, First)),
        ?assertEqual([1], [maps:get(user_id, U) || U <- maps:get(users, First)]),

        %% new call evicts the old one
        ok = pw_hub:call_join(88, 1, P1, Profile, [2]),
        Old = await_event(two, call_presence, 77),
        ?assertEqual(false, maps:get(active, Old)),
        New = await_event(two, call_presence, 88),
        ?assertEqual(true, maps:get(active, New)),

        %% voice evicts the DM call too
        ok = pw_hub:voice_join(9, 1, P1, Profile),
        Left = await_event(two, call_presence, 88),
        ?assertEqual(false, maps:get(active, Left)),

        %% random state packets don't summon users
        pw_hub:call_state(99, 1, P1, #{screen => true}, Profile),
        _ = gen_server:call(pw_hub, sync),
        Profile2 = #{id => 2, display_name => <<"Two">>, avatar_url => <<>>},
        ok = pw_hub:call_join(99, 2, P2, Profile2, [1]),
        State99 = await_event(two, call_state, 99),
        ?assertEqual([2], [maps:get(user_id, U) || U <- maps:get(users, State99)]),

        %% the stale tab no longer owns this slot
        ok = pw_hub:call_join(123, 1, P1, Profile, [2]),
        ok = pw_hub:call_join(123, 1, P1b, Profile, [2]),
        pw_hub:call_leave(123, 1, P1),
        _ = gen_server:call(pw_hub, sync),
        ok = pw_hub:call_join(123, 2, P2, Profile2, [1]),
        State123 = await_event(two, call_state, 123),
        ?assertEqual([1, 2], lists:sort([maps:get(user_id, U) || U <- maps:get(users, State123)])),

        %% stale-tab signaling goes nowhere
        pw_hub:call_signal(123, 1, P1, 2, #{kind => stale_offer}),
        _ = gen_server:call(pw_hub, sync),
        assert_no_event(two, call_signal, 123),
        pw_hub:call_signal(123, 1, P1b, 2, #{kind => current_offer}),
        Signal = await_event(two, call_signal, 123),
        ?assertEqual(#{kind => current_offer}, maps:get(signal, Signal))
    after
        exit(P1, kill),
        exit(P1b, kill),
        exit(P2, kill),
        gen_server:stop(Hub)
    end.

call_refresh_reconnect_grace_test() ->
    Previous = os:getenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS"),
    os:putenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS", "250"),
    stop_existing_hub(),
    {ok, Hub} = pw_hub:start_link(),
    Parent = self(),
    P1 = spawn(fun() -> socket_loop(Parent, first_tab) end),
    P1b = spawn(fun() -> socket_loop(Parent, refreshed_tab) end),
    P2 = spawn(fun() -> socket_loop(Parent, observer) end),
    try
        pw_hub:connect(1, P1, <<"online">>),
        pw_hub:connect(2, P2, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        Profile1 = #{id => 1, display_name => <<"One">>, avatar_url => <<>>},
        Profile2 = #{id => 2, display_name => <<"Two">>, avatar_url => <<>>},
        ok = pw_hub:call_join(201, 1, P1, Profile1, [2]),
        _ = await_event(observer, call_presence, 201),
        ok = pw_hub:call_join(201, 2, P2, Profile2, [1]),
        _ = await_event(observer, call_presence, 201),

        %% keep the seat warm while the page reloads
        pw_hub:disconnect(P1),
        _ = gen_server:call(pw_hub, sync),
        DuringRefresh = await_event(observer, call_presence, 201),
        ?assertEqual(true, maps:get(active, DuringRefresh)),

        %% no pid yet; signal gets ignored, hub keeps breathing
        pw_hub:call_signal(201, 2, P2, 1, #{kind => offer}),
        _ = gen_server:call(pw_hub, sync),
        ?assert(is_process_alive(Hub)),

        pw_hub:connect(1, P1b, <<"online">>),
        ok = pw_hub:call_join(201, 1, P1b, Profile1, [2]),
        Rejoined = await_event(observer, call_presence, 201),
        ?assertEqual(true, maps:get(active, Rejoined)),
        ?assertEqual([1, 2], lists:sort([maps:get(user_id, U) || U <- maps:get(users, Rejoined)])),

        timer:sleep(300),
        _ = gen_server:call(pw_hub, sync),
        assert_no_inactive_call(observer, 201)
    after
        exit(P1, kill),
        exit(P1b, kill),
        exit(P2, kill),
        gen_server:stop(Hub),
        restore_env("PLAINWIRE_RTC_RECONNECT_GRACE_MS", Previous)
    end.

call_refresh_grace_expires_test() ->
    Previous = os:getenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS"),
    os:putenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS", "50"),
    stop_existing_hub(),
    {ok, Hub} = pw_hub:start_link(),
    Parent = self(),
    P1 = spawn(fun() -> socket_loop(Parent, expiring) end),
    P2 = spawn(fun() -> socket_loop(Parent, expiry_observer) end),
    try
        pw_hub:connect(1, P1, <<"online">>),
        pw_hub:connect(2, P2, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        Profile = #{id => 1, display_name => <<"One">>, avatar_url => <<>>},
        ok = pw_hub:call_join(202, 1, P1, Profile, [2]),
        _ = await_event(expiry_observer, call_presence, 202),
        pw_hub:disconnect(P1),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(true, maps:get(active, await_event(expiry_observer, call_presence, 202))),
        Expired = await_event(expiry_observer, call_presence, 202),
        ?assertEqual(false, maps:get(active, Expired))
    after
        exit(P1, kill),
        exit(P2, kill),
        gen_server:stop(Hub),
        restore_env("PLAINWIRE_RTC_RECONNECT_GRACE_MS", Previous)
    end.

socket_loop(Parent, Tag) ->
    receive
        {hub_json, Event} -> Parent ! {socket_event, Tag, Event}, socket_loop(Parent, Tag);
        {hub_text, Payload, call_presence} ->
            Json = jsx:decode(Payload, [return_maps]),
            Users = [#{user_id => maps:get(<<"user_id">>, U)} || U <- maps:get(<<"users">>, Json, [])],
            Parent ! {socket_event, Tag, #{type => call_presence,
                conversation_id => maps:get(<<"conversation_id">>, Json),
                active => maps:get(<<"active">>, Json), users => Users}},
            socket_loop(Parent, Tag);
        {hub_text, Payload, call_state} ->
            Json = jsx:decode(Payload, [return_maps]),
            Users = [#{user_id => maps:get(<<"user_id">>, U)} || U <- maps:get(<<"users">>, Json, [])],
            Parent ! {socket_event, Tag, #{type => call_state,
                conversation_id => maps:get(<<"conversation_id">>, Json), users => Users}},
            socket_loop(Parent, Tag);
        {hub_text, Payload, call_signal} ->
            Json = jsx:decode(Payload, [return_maps]),
            Parent ! {socket_event, Tag, #{type => call_signal,
                conversation_id => maps:get(<<"conversation_id">>, Json), signal => maps:get(<<"signal">>, Json)}},
            socket_loop(Parent, Tag);
        {hub_text, _Payload, _Type} ->
            socket_loop(Parent, Tag)
    end.

await_event(Tag, Type, Id) ->
    receive
        {socket_event, Tag, #{type := Type, conversation_id := Id} = Event} -> Event;
        {socket_event, Tag, _Other} -> await_event(Tag, Type, Id)
    after 1000 ->
        ?assert(false)
    end.

await_call_roster(Tag, Id, Count) ->
    Event = await_event(Tag, call_state, Id),
    case length(maps:get(users, Event)) of
        Count -> Event;
        _ -> await_call_roster(Tag, Id, Count)
    end.

assert_no_event(Tag, Type, Id) ->
    receive
        {socket_event, Tag, #{type := Type, conversation_id := Id}} -> ?assert(false);
        {socket_event, Tag, _Other} -> assert_no_event(Tag, Type, Id)
    after 80 ->
        ok
    end.

assert_no_inactive_call(Tag, Id) ->
    receive
        {socket_event, Tag, #{type := call_presence, conversation_id := Id, active := false}} -> ?assert(false);
        {socket_event, Tag, _Other} -> assert_no_inactive_call(Tag, Id)
    after 80 ->
        ok
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).

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
