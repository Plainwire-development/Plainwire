-module(pw_hub_tests).

-include_lib("eunit/include/eunit.hrl").

self_is_included_in_presence_watch_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
    try
        pw_hub:connect(42, self(), <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        flush_presence_state(),
        pw_hub:watch_presence(self(), []),
        _ = gen_server:call(pw_hub, sync),
        Presence = await_presence_state(),
        ?assertEqual(<<"online">>, maps:get(42, maps:get(statuses, Presence)))
    after
        stop_test_hub(Hub)
    end.


connect_seeds_own_presence_state_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
    try
        pw_hub:connect(84, self(), <<"away">>),
        _ = gen_server:call(pw_hub, sync),
        Presence = await_presence_state(),
        ?assert(lists:member(84, maps:get(online, Presence))),
        ?assertEqual(<<"away">>, maps:get(84, maps:get(statuses, Presence)))
    after
        stop_test_hub(Hub)
    end.


voice_roster_carries_profile_and_normalizes_media_state_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
    Parent = self(),
    Socket = spawn(fun() -> socket_loop(Parent, voice_member) end),
    Profile = #{id => 71, username => <<"casey">>, display_name => <<"Casey Nguyen">>,
                avatar_url => <<"/avatar/casey">>, avatar_source_url => <<"private-source">>},
    try
        pw_hub:connect(71, Socket, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        ok = pw_hub:voice_join(901, 71, Socket, Profile),
        Initial = only_voice_user(await_voice_roster(voice_member, 901)),
        WireProfile = maps:get(profile, Initial),
        ?assertEqual(<<"Casey Nguyen">>, maps:get(<<"display_name">>, WireProfile)),
        ?assertEqual(<<"/avatar/casey">>, maps:get(<<"avatar_url">>, WireProfile)),
        ?assertEqual(false, maps:is_key(<<"avatar_source_url">>, WireProfile)),
        ?assertEqual(false, maps:get(screen_audio, Initial)),

        %% Invalid combinations are normalized at the hub boundary: deafened
        %% users are muted, and screen audio cannot outlive a screen share.
        pw_hub:voice_state(901, 71, Socket,
            #{deafened => true, muted => false, screen_audio => true}, Profile),
        _ = gen_server:call(pw_hub, sync),
        Deafened = only_voice_user(await_voice_roster(voice_member, 901)),
        ?assertEqual(true, maps:get(deafened, Deafened)),
        ?assertEqual(true, maps:get(muted, Deafened)),
        ?assertEqual(false, maps:get(screen_audio, Deafened)),

        pw_hub:voice_state(901, 71, Socket,
            #{deafened => false, muted => false, screen => true, screen_audio => true}, Profile),
        _ = gen_server:call(pw_hub, sync),
        Sharing = only_voice_user(await_voice_roster(voice_member, 901)),
        ?assertEqual(true, maps:get(screen, Sharing)),
        ?assertEqual(true, maps:get(screen_audio, Sharing)),

        pw_hub:voice_state(901, 71, Socket, #{screen => false}, Profile),
        _ = gen_server:call(pw_hub, sync),
        Stopped = only_voice_user(await_voice_roster(voice_member, 901)),
        ?assertEqual(false, maps:get(screen, Stopped)),
        ?assertEqual(false, maps:get(screen_audio, Stopped))
    after
        exit(Socket, kill),
        stop_test_hub(Hub)
    end.


multi_session_presence_prefers_visible_session_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
    P1 = spawn(fun idle_socket/0),
    P2 = spawn(fun idle_socket/0),
    try
        pw_hub:connect(7, P1, <<"online">>),
        pw_hub:connect(7, P2, <<"away">>),
        pw_hub:connect(9, self(), <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        flush_hub_messages(),
        pw_hub:watch_presence(self(), [7]),
        _ = gen_server:call(pw_hub, sync),
        Presence = await_presence_state(),
        ?assertEqual(<<"online">>, maps:get(7, maps:get(statuses, Presence))),

        %% Making one tab invisible must not hide the account while another
        %% connected tab is still visible.
        pw_hub:status_update(7, P1, <<"invisible">>),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(<<"away">>, await_presence_status(7)),

        %% Only when every connected session is invisible does the account go
        %% offline. Bringing any session back makes it visible again.
        pw_hub:status_update(7, P2, <<"invisible">>),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(offline, await_presence_status(7)),
        pw_hub:status_update(7, P1, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(<<"online">>, await_presence_status(7))
    after
        exit(P1, kill),
        exit(P2, kill),
        stop_test_hub(Hub)
    end.

call_accept_establishes_bidirectional_signaling_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
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
        ?assertEqual(
            #{<<"kind">> => <<"offer">>,
              <<"sdp">> => #{<<"type">> => <<"offer">>, <<"sdp">> => <<"v=0">>}},
            maps:get(signal, await_event(rtc_callee, call_signal, 501))),
        pw_hub:call_signal(501, 2, Callee, 1, Answer),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(
            #{<<"kind">> => <<"answer">>,
              <<"sdp">> => #{<<"type">> => <<"answer">>, <<"sdp">> => <<"v=0">>}},
            maps:get(signal, await_event(rtc_caller, call_signal, 501)))
    after
        exit(Caller, kill),
        exit(Callee, kill),
        stop_test_hub(Hub)
    end.

missed_call_ends_ring_and_rejects_late_accept_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
    Parent = self(),
    Caller = spawn(fun() -> socket_loop(Parent, missed_caller) end),
    Callee = spawn(fun() -> socket_loop(Parent, missed_callee) end),
    CallerProfile = #{id => 1, display_name => <<"Caller">>, avatar_url => <<>>},
    CalleeProfile = #{id => 2, display_name => <<"Callee">>, avatar_url => <<>>},
    try
        pw_hub:connect(1, Caller, <<"online">>),
        pw_hub:connect(2, Callee, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        pw_hub:call_ring(502, 1, Caller, CallerProfile, [2]),
        _ = gen_server:call(pw_hub, sync),

        Hub ! {ring_timeout, 502, 1},
        _ = gen_server:call(pw_hub, sync),
        CallerEvent = await_event(missed_caller, call_missed, 502),
        CalleeEvent = await_event(missed_callee, call_missed, 502),
        ?assertEqual(<<"timeout">>, maps:get(reason, CallerEvent)),
        ?assertEqual(1, maps:get(from_user_id, CallerEvent)),
        ?assertEqual(<<"Caller">>, maps:get(display_name, maps:get(profile, CallerEvent))),
        ?assertEqual(1, maps:get(from_user_id, CalleeEvent)),
        ?assertEqual(<<"timeout">>, maps:get(reason, CalleeEvent)),
        ?assertEqual({error, no_active_call},
            pw_hub:call_accept(502, 2, Callee, CalleeProfile, [1])),
        assert_no_event(missed_caller, call_state, 502),
        assert_no_event(missed_callee, call_state, 502)
    after
        exit(Caller, kill),
        exit(Callee, kill),
        stop_test_hub(Hub)
    end.

crossed_ring_connects_both_callers_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
    Parent = self(),
    One = spawn(fun() -> socket_loop(Parent, crossed_one) end),
    Two = spawn(fun() -> socket_loop(Parent, crossed_two) end),
    Profile1 = #{id => 1, display_name => <<"One">>, avatar_url => <<>>},
    Profile2 = #{id => 2, display_name => <<"Two">>, avatar_url => <<>>},
    try
        pw_hub:connect(1, One, <<"online">>),
        pw_hub:connect(2, Two, <<"online">>),
        _ = gen_server:call(pw_hub, sync),
        pw_hub:call_ring(503, 1, One, Profile1, [2]),
        %% a repeated ring from the same socket must not cancel the call being placed
        pw_hub:call_ring(503, 1, One, Profile1, [2]),
        _ = gen_server:call(pw_hub, sync),
        assert_no_event(crossed_one, call_cancelled, 503),

        %% the callee presses call instead of accept: that answers the ring
        pw_hub:call_ring(503, 2, Two, Profile2, [1]),
        _ = gen_server:call(pw_hub, sync),
        OneState = await_call_roster(crossed_one, 503, 2),
        TwoState = await_call_roster(crossed_two, 503, 2),
        ?assertEqual([1, 2], lists:sort([maps:get(user_id, U) || U <- maps:get(users, OneState)])),
        ?assertEqual([1, 2], lists:sort([maps:get(user_id, U) || U <- maps:get(users, TwoState)])),
        assert_no_event(crossed_two, call_cancelled, 503),

        Offer = #{kind => offer, sdp => #{type => offer, sdp => <<"v=0">>}},
        pw_hub:call_signal(503, 2, Two, 1, Offer),
        _ = gen_server:call(pw_hub, sync),
        ?assertEqual(
            #{<<"kind">> => <<"offer">>,
              <<"sdp">> => #{<<"type">> => <<"offer">>, <<"sdp">> => <<"v=0">>}},
            maps:get(signal, await_event(crossed_one, call_signal, 503)))
    after
        exit(One, kill),
        exit(Two, kill),
        stop_test_hub(Hub)
    end.

call_presence_and_cross_room_eviction_test() ->
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
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
        ?assertEqual(#{<<"kind">> => <<"current_offer">>}, maps:get(signal, Signal))
    after
        exit(P1, kill),
        exit(P1b, kill),
        exit(P2, kill),
        stop_test_hub(Hub)
    end.

call_refresh_reconnect_grace_test() ->
    Previous = os:getenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS"),
    os:putenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS", "250"),
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
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
        ?assertEqual({error, no_active_call}, pw_hub:call_rejoin(201, 1, P1b, Profile1, [2])),
        ok = pw_hub:call_join(201, 1, P1, Profile1, [2]),
        _ = await_event(observer, call_presence, 201),
        ok = pw_hub:call_join(201, 2, P2, Profile2, [1]),
        _ = await_event(observer, call_presence, 201),

        %% keep the seat warm while the page reloads
        pw_hub:disconnect(P1),
        _ = gen_server:call(pw_hub, sync),
        DuringRefresh = await_event(observer, call_presence, 201),
        ?assertEqual(true, maps:get(active, DuringRefresh)),
        RefreshUsers = maps:get(users, DuringRefresh),
        RefreshingUser = hd([U || U <- RefreshUsers, maps:get(user_id, U) =:= 1]),
        ?assertEqual(true, maps:get(reconnecting, RefreshingUser)),

        %% no pid yet; signal gets ignored, hub keeps breathing
        pw_hub:call_signal(201, 2, P2, 1, #{kind => offer}),
        _ = gen_server:call(pw_hub, sync),
        ?assert(is_process_alive(Hub)),

        pw_hub:connect(1, P1b, <<"online">>),
        ok = pw_hub:call_rejoin(201, 1, P1b, Profile1, [2]),
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
        stop_test_hub(Hub),
        restore_env("PLAINWIRE_RTC_RECONNECT_GRACE_MS", Previous)
    end.

call_refresh_grace_expires_test() ->
    Previous = os:getenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS"),
    os:putenv("PLAINWIRE_RTC_RECONNECT_GRACE_MS", "50"),
    stop_existing_hub(),
    {ok, Hub} = start_test_hub(),
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
        stop_test_hub(Hub),
        restore_env("PLAINWIRE_RTC_RECONNECT_GRACE_MS", Previous)
    end.

socket_loop(Parent, Tag) ->
    receive
        {hub_json, Event} -> Parent ! {socket_event, Tag, Event}, socket_loop(Parent, Tag);
        {hub_text, Payload, call_presence} ->
            Json = jsx:decode(Payload, [return_maps]),
            Users = [#{user_id => maps:get(<<"user_id">>, U),
                       reconnecting => maps:get(<<"reconnecting">>, U, false)}
                     || U <- maps:get(<<"users">>, Json, [])],
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
        {hub_text, Payload, voice_state} ->
            Json = jsx:decode(Payload, [return_maps]),
            Users = [#{user_id => maps:get(<<"user_id">>, U),
                       muted => maps:get(<<"muted">>, U, false),
                       deafened => maps:get(<<"deafened">>, U, false),
                       screen => maps:get(<<"screen">>, U, false),
                       screen_audio => maps:get(<<"screen_audio">>, U, false),
                       profile => maps:get(<<"profile">>, U, #{})}
                     || U <- maps:get(<<"users">>, Json, [])],
            Parent ! {socket_event, Tag, #{type => voice_state,
                channel_id => maps:get(<<"channel_id">>, Json), users => Users}},
            socket_loop(Parent, Tag);
        {hub_text, Payload, call_signal} ->
            Json = jsx:decode(Payload, [return_maps]),
            Parent ! {socket_event, Tag, #{type => call_signal,
                conversation_id => maps:get(<<"conversation_id">>, Json), signal => maps:get(<<"signal">>, Json)}},
            socket_loop(Parent, Tag);
        {hub_text, Payload, call_cancelled} ->
            Json = jsx:decode(Payload, [return_maps]),
            Parent ! {socket_event, Tag, #{type => call_cancelled,
                conversation_id => maps:get(<<"conversation_id">>, Json)}},
            socket_loop(Parent, Tag);
        {hub_text, Payload, call_missed} ->
            Json = jsx:decode(Payload, [return_maps]),
            Profile0 = maps:get(<<"profile">>, Json, #{}),
            Profile = #{display_name => maps:get(<<"display_name">>, Profile0, <<>>)},
            Parent ! {socket_event, Tag, #{type => call_missed,
                conversation_id => maps:get(<<"conversation_id">>, Json),
                from_user_id => maps:get(<<"from_user_id">>, Json),
                reason => maps:get(<<"reason">>, Json), profile => Profile}},
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

await_voice_roster(Tag, Id) ->
    receive
        {socket_event, Tag, #{type := voice_state, channel_id := Id} = Event} -> Event;
        {socket_event, Tag, _Other} -> await_voice_roster(Tag, Id)
    after 1000 ->
        ?assert(false)
    end.

only_voice_user(Event) ->
    [User] = maps:get(users, Event),
    User.

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


idle_socket() ->
    receive
        stop -> ok;
        _ -> idle_socket()
    end.

flush_hub_messages() ->
    receive
        {hub_json, _} -> flush_hub_messages();
        {hub_text, _, _} -> flush_hub_messages()
    after 0 ->
        ok
    end.

await_presence_status(Uid) ->
    receive
        {hub_text, Payload, Type} when Type =:= presence_status; Type =:= presence_online; Type =:= presence_offline ->
            Json = jsx:decode(Payload, [return_maps]),
            case maps:get(<<"user_id">>, Json, undefined) of
                Uid ->
                    case Type of
                        presence_offline -> offline;
                        _ -> maps:get(<<"status">>, Json)
                    end;
                _ -> await_presence_status(Uid)
            end;
        {hub_json, #{type := Type, user_id := Uid} = Event}
                when Type =:= presence_status; Type =:= presence_online ->
            maps:get(status, Event);
        {hub_json, #{type := presence_offline, user_id := Uid}} ->
            offline;
        _ -> await_presence_status(Uid)
    after 1000 ->
        ?assert(false)
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).

flush_presence_state() ->
    _ = await_presence_state(),
    ok.

await_presence_state() ->
    receive
        {hub_text, Payload, presence_state} ->
            Json = jsx:decode(Payload, [return_maps]),
            Statuses0 = maps:get(<<"statuses">>, Json, #{}),
            Statuses = maps:from_list([
                {presence_uid(Key), Value} || {Key, Value} <- maps:to_list(Statuses0)
            ]),
            #{type => presence_state,
              online => maps:get(<<"online">>, Json, []),
              statuses => Statuses}
    after 1000 ->
        ?assert(false)
    end.

presence_uid(Key) when is_binary(Key) ->
    try binary_to_integer(Key) catch _:_ -> Key end;
presence_uid(Key) -> Key.

stop_existing_hub() ->
    stop_named(pw_hub),
    stop_named(pw_realtime_registry).

start_test_hub() ->
    stop_existing_hub(),
    {ok, _Registry} = pw_realtime_registry:start_link(),
    pw_hub:start_link().

stop_test_hub(Hub) ->
    case is_process_alive(Hub) of
        true -> gen_server:stop(Hub);
        false -> ok
    end,
    stop_named(pw_realtime_registry).

stop_named(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            try gen_server:stop(Pid, normal, 1000)
            catch exit:_ -> exit(Pid, kill), ok end
    end.
