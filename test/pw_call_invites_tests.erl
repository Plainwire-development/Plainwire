-module(pw_call_invites_tests).
-include_lib("eunit/include/eunit.hrl").

targeted_invitation_accept_and_duplicate_tab_test() ->
    with_room(fun(#{cid := Cid, a := A, b := B, c := C, pa := PA, pb := PB, pc := PC, profile := Profile}) ->
        {ok, Ack} = pw_hub:call_invite(Cid, A, PA, Profile, C),
        Token = maps:get(invite_id, Ack),
        ?assertEqual({ok, A}, pw_hub:call_invite_caller(Cid, C, Token)),
        ?assertEqual({error, no_active_call}, pw_hub:call_invite_caller(Cid, B, Token)),
        ?assertEqual({error, no_active_call}, pw_hub:call_invite_caller(Cid, C, <<"forged">>)),
        Incoming = event(c, <<"call_incoming">>, Cid),
        ?assertEqual(Token, maps:get(<<"invite_id">>, Incoming)),
        ?assertEqual(A, maps:get(<<"from_user_id">>, Incoming)),
        ?assertNot(maps:is_key(<<"avatar_source_url">>, maps:get(<<"profile">>, Incoming))),
        {ok, Again} = pw_hub:call_invite(Cid, A, PA, Profile, C),
        ?assertEqual(Ack, Again),
        no_event(c, <<"call_incoming">>, Cid),
        no_event(b, <<"call_incoming">>, Cid),
        ?assertEqual({error, already_ringing}, pw_hub:call_invite(Cid, B, PB, #{id => B}, C)),
        ?assertEqual({error, no_active_call}, pw_hub:call_accept_invite(Cid, B, PB, #{id => B}, [A,C], Token)),
        ?assertEqual({error, no_active_call}, pw_hub:call_accept_invite(Cid, C, PC, #{id => C}, [A,B], <<"forged">>)),
        Parent = self(), Alt = spawn(fun() -> socket(Parent, alt) end),
        try
            pw_hub:connect(C, Alt),
            _ = gen_server:call(pw_hub, sync),
            ?assertEqual(Token, maps:get(<<"invite_id">>, event(alt, <<"call_incoming">>, Cid))),
            ok = pw_hub:call_accept_invite(Cid, C, PC, #{id => C}, [A,B], Token),
            ?assertEqual(3, maps:get(call_participants, pw_hub:stats())),
            ?assertEqual(0, maps:get(call_invitations, pw_hub:stats())),
            ?assertEqual({error, no_active_call}, pw_hub:call_invite_caller(Cid, C, Token)),
            _ = event(c, <<"call_accepted">>, Cid),
            ?assertEqual(<<"accepted">>, maps:get(<<"reason">>, event(alt, <<"call_invite_ended">>, Cid))),
            no_event(alt, <<"call_accepted">>, Cid),
            ?assertEqual({error, no_active_call}, pw_hub:call_accept_invite(Cid, C, Alt, #{id => C}, [A,B], Token)),
            pw_hub:call_signal(Cid, A, PA, B, #{kind => offer}),
            _ = event(b, <<"call_signal">>, Cid)
        after exit(Alt, kill) end
    end).

decline_preserves_call_and_limits_repeated_rings_test() ->
    with_room(fun(#{cid := Cid, a := A, b := B, c := C, pa := PA, profile := Profile}) ->
        {ok, Ack} = pw_hub:call_invite(Cid, A, PA, Profile, C),
        Token = maps:get(invite_id, Ack),
        _ = event(c, <<"call_incoming">>, Cid),
        pw_hub:call_decline_invite(Cid, C, <<"stale">>),
        ?assertEqual(1, maps:get(call_invitations, pw_hub:stats())),
        pw_hub:call_decline_invite(Cid, C, Token),
        ?assertEqual(2, maps:get(call_participants, pw_hub:stats())),
        ?assertEqual(<<"declined">>, maps:get(<<"status">>, event(a, <<"call_invite_status">>, Cid))),
        ?assertEqual({error, rate_limited}, pw_hub:call_invite(Cid, A, PA, Profile, C)),
        no_event(a, <<"call_cancelled">>, Cid),
        no_event(b, <<"call_ended">>, Cid),
        pw_hub:call_signal(Cid, A, PA, B, #{kind => offer}),
        _ = event(b, <<"call_signal">>, Cid)
    end).

caller_leave_and_late_accept_test() ->
    with_room(fun(#{cid := Cid, a := A, b := B, c := C, pa := PA, pc := PC, profile := Profile}) ->
        {ok, Ack} = pw_hub:call_invite(Cid, A, PA, Profile, C),
        _ = event(c, <<"call_incoming">>, Cid),
        pw_hub:call_leave(Cid, A, PA),
        ?assertEqual(1, maps:get(call_participants, pw_hub:stats())),
        ?assertEqual(<<"caller_left">>, maps:get(<<"reason">>, event(c, <<"call_invite_ended">>, Cid))),
        ?assertEqual({error, no_active_call}, pw_hub:call_accept_invite(Cid, C, PC, #{id => C}, [A,B], maps:get(invite_id, Ack)))
    end).

stale_timeout_cannot_end_replacement_invitation_test() ->
    with_room(fun(#{cid := Cid, a := A, b := B, c := C, pa := PA, pb := PB, pc := PC, profile := Profile}) ->
        {ok, First} = pw_hub:call_invite(Cid, A, PA, Profile, C),
        _ = event(c, <<"call_incoming">>, Cid),
        pw_hub:call_decline_invite(Cid, C, maps:get(invite_id, First)),
        _ = event(c, <<"call_invite_ended">>, Cid),
        {ok, Second} = pw_hub:call_invite(Cid, B, PB, #{id => B}, C),
        _ = event(c, <<"call_incoming">>, Cid),
        whereis(pw_hub) ! {call_invite_timeout, C, maps:get(invite_id, First)},
        ?assertEqual(1, maps:get(call_invitations, pw_hub:stats())),
        no_event(c, <<"call_invite_ended">>, Cid),
        ok = pw_hub:call_accept_invite(Cid, C, PC, #{id => C}, [A,B], maps:get(invite_id, Second))
    end).

busy_target_and_sender_socket_ownership_test() ->
    with_room(fun(#{cid := Cid, a := A, c := C, pa := PA, pc := PC, profile := Profile}) ->
        ?assertEqual({error, not_in_call}, pw_hub:call_invite(Cid, A, PC, Profile, C)),
        ?assertEqual({error, already_joined}, pw_hub:call_invite(Cid, A, PA, Profile, A + 1)),
        ?assertEqual({error, not_in_call}, pw_hub:call_invite(Cid + 1, A, PA, Profile, C)),
        ok = pw_hub:voice_join(202, C, PC, #{id => C}),
        ?assertEqual({error, user_unavailable}, pw_hub:call_invite(Cid, A, PA, Profile, C)),
        ?assertEqual(2, maps:get(call_participants, pw_hub:stats()))
    end).

joining_elsewhere_clears_invitation_test() ->
    with_room(fun(#{cid := Cid, a := A, c := C, pa := PA, pc := PC, profile := Profile}) ->
        {ok, _} = pw_hub:call_invite(Cid, A, PA, Profile, C),
        _ = event(c, <<"call_incoming">>, Cid),
        ok = pw_hub:voice_join(203, C, PC, #{id => C}),
        ?assertEqual(0, maps:get(call_invitations, pw_hub:stats())),
        ?assertEqual(<<"joined">>, maps:get(<<"reason">>, event(c, <<"call_invite_ended">>, Cid))),
        ?assertEqual(2, maps:get(call_participants, pw_hub:stats()))
    end).

disconnect_revoke_and_timeout_cleanup_test() ->
    lists:foreach(fun(How) ->
        with_room(fun(#{cid := Cid, a := A, c := C, pa := PA, profile := Profile}) ->
            {ok, Ack} = pw_hub:call_invite(Cid, A, PA, Profile, C),
            _ = event(c, <<"call_incoming">>, Cid),
            case How of
                disconnect -> pw_hub:disconnect(PA);
                revoke -> pw_hub:revoke_conversation_access(C, Cid);
                timeout -> whereis(pw_hub) ! {call_invite_timeout, C, maps:get(invite_id, Ack)}
            end,
            ?assertEqual(0, maps:get(call_invitations, pw_hub:stats())),
            _ = event(c, <<"call_invite_ended">>, Cid),
            no_event(a, <<"call_cancelled">>, Cid)
        end)
    end, [disconnect, revoke, timeout]).

capacity_is_rechecked_when_accepting_test() ->
    with_room(fun(#{cid := Cid, a := A, b := B, c := C, pa := PA, pc := PC, profile := Profile}) ->
        Previous = os:getenv("PLAINWIRE_VOICE_MAX_PARTICIPANTS"),
        Parent = self(), D = C + 1000000, PD = spawn(fun() -> socket(Parent, d) end),
        try
            os:putenv("PLAINWIRE_VOICE_MAX_PARTICIPANTS", "2"),
            ?assertEqual({error, room_full}, pw_hub:call_invite(Cid, A, PA, Profile, C)),
            os:putenv("PLAINWIRE_VOICE_MAX_PARTICIPANTS", "3"),
            {ok, Ack} = pw_hub:call_invite(Cid, A, PA, Profile, C),
            pw_hub:connect(D, PD),
            ok = pw_hub:call_join(Cid, D, PD, #{id => D}, [A,B,C]),
            ?assertEqual({error, room_full}, pw_hub:call_accept_invite(Cid, C, PC, #{id => C}, [A,B,D], maps:get(invite_id, Ack))),
            ?assertEqual(3, maps:get(call_participants, pw_hub:stats())),
            ?assertEqual(0, maps:get(call_invitations, pw_hub:stats())),
            ?assertEqual(<<"room_full">>, maps:get(<<"reason">>, event(c, <<"call_invite_ended">>, Cid))),
            pw_hub:call_signal(Cid, A, PA, B, #{kind => offer}),
            _ = event(b, <<"call_signal">>, Cid)
        after
            exit(PD, kill),
            case Previous of false -> os:unsetenv("PLAINWIRE_VOICE_MAX_PARTICIPANTS"); _ -> os:putenv("PLAINWIRE_VOICE_MAX_PARTICIPANTS", Previous) end
        end
    end).

socket_handoff_and_sender_revocation_cancel_invites_test() ->
    lists:foreach(fun(How) ->
        with_room(fun(#{cid := Cid, a := A, b := B, c := C, pa := PA, pc := PC, profile := Profile}) ->
            {ok, Ack} = pw_hub:call_invite(Cid, A, PA, Profile, C),
            _ = event(c, <<"call_incoming">>, Cid),
            Parent = self(), Alt = spawn(fun() -> socket(Parent, alt) end),
            try
                case How of
                    handoff -> pw_hub:connect(A, Alt), ok = pw_hub:call_join(Cid, A, Alt, Profile, [B,C]);
                    revoke -> pw_hub:revoke_conversation_access(A, Cid)
                end,
                ?assertEqual(0, maps:get(call_invitations, pw_hub:stats())),
                _ = event(c, <<"call_invite_ended">>, Cid),
                ?assertEqual({error, no_active_call}, pw_hub:call_accept_invite(Cid, C, PC, #{id => C}, [A,B], maps:get(invite_id, Ack)))
            after exit(Alt, kill) end
        end)
    end, [handoff, revoke]).

recipient_disconnect_and_offline_target_test() ->
    with_room(fun(#{cid := Cid, a := A, c := C, pa := PA, pc := PC, profile := Profile}) ->
        {ok, _} = pw_hub:call_invite(Cid, A, PA, Profile, C),
        pw_hub:disconnect(PC),
        ?assertEqual(0, maps:get(call_invitations, pw_hub:stats())),
        ?assertEqual(<<"offline">>, maps:get(<<"status">>, event(a, <<"call_invite_status">>, Cid))),
        ?assertEqual({error, user_unavailable}, pw_hub:call_invite(Cid, A, PA, Profile, C)),
        ?assertEqual(2, maps:get(call_participants, pw_hub:stats()))
    end).

malformed_invites_and_bots_preserve_socket_state_test() ->
    with_room(fun(#{cid := Cid, a := A, c := C, profile := Profile}) ->
        State = #{uid => A, session => #{user => Profile}, call => Cid, voice => undefined,
                  last_auth_check => erlang:monotonic_time(millisecond)},
        lists:foreach(fun({Type, Token}) ->
            Payload = pw_util:json(#{type => Type, conversation_id => Cid, invite_id => Token}),
            {reply, {text, Reply}, State} = pw_ws:websocket_handle({text, Payload}, State),
            ?assertEqual(<<"invalid_invite">>, maps:get(<<"error">>, jsx:decode(Reply, [return_maps])))
        end, [{Type, Token} || Type <- [call_accept, call_decline], Token <- [<<>>, [], 3, binary:copy(<<"x">>, 97)]]),
        BotState = State#{auth_kind => bot},
        {reply, {text, BotReply}, BotState} = pw_ws:websocket_handle(
            {text, pw_util:json(#{type => call_invite, conversation_id => Cid, to_user_id => C})}, BotState),
        ?assertEqual(<<"forbidden">>, maps:get(<<"error">>, jsx:decode(BotReply, [return_maps]))),
        ?assertEqual(2, maps:get(call_participants, pw_hub:stats()))
    end).

recipient_budget_is_shared_across_callers_test() ->
    with_room(fun(#{cid := Cid, a := A, b := B, c := C, pa := PA, pb := PB, profile := Profile}) ->
        Parent = self(), D = C + 1000000, E = D + 1,
        PD = spawn(fun() -> socket(Parent, d) end), PE = spawn(fun() -> socket(Parent, e) end),
        try
            [pw_hub:connect(U, P) || {U, P} <- [{D,PD},{E,PE}]],
            ok = pw_hub:call_join(Cid, D, PD, #{id => D}, [A,B,C,E]),
            ok = pw_hub:call_join(Cid, E, PE, #{id => E}, [A,B,C,D]),
            lists:foreach(fun({U,P,Prof}) ->
                {ok, Ack} = pw_hub:call_invite(Cid, U, P, Prof, C),
                pw_hub:call_decline_invite(Cid, C, maps:get(invite_id, Ack)),
                ?assertEqual(0, maps:get(call_invitations, pw_hub:stats()))
            end, [{A,PA,Profile},{B,PB,#{id=>B}},{D,PD,#{id=>D}}]),
            ?assertEqual({error, rate_limited}, pw_hub:call_invite(Cid, E, PE, #{id=>E}, C))
        after exit(PD, kill), exit(PE, kill) end
    end).

with_room(Fun) ->
    stop(pw_hub), stop(pw_realtime_registry),
    RateOwned = case whereis(pw_rate) of undefined -> {ok, _} = pw_rate:start_link(), true; _ -> false end,
    {ok, _} = pw_realtime_registry:start_link(),
    {ok, _} = pw_hub:start_link(),
    A = 10000 + erlang:unique_integer([positive, monotonic]) * 3, B = A + 1, C = A + 2,
    Cid = A, Parent = self(),
    PA = spawn(fun() -> socket(Parent, a) end),
    PB = spawn(fun() -> socket(Parent, b) end),
    PC = spawn(fun() -> socket(Parent, c) end),
    Profile = #{id => A, display_name => <<"Caller">>, avatar_source_url => <<"private">>},
    try
        [pw_hub:connect(U, P) || {U, P} <- [{A, PA}, {B, PB}, {C, PC}]],
        ok = pw_hub:call_join(Cid, A, PA, Profile, [B,C]),
        ok = pw_hub:call_join(Cid, B, PB, #{id => B}, [A,C]),
        Fun(#{cid => Cid, a => A, b => B, c => C, pa => PA, pb => PB, pc => PC, profile => Profile})
    after
        stop(pw_hub), stop(pw_realtime_registry),
        [exit(P, kill) || P <- [PA, PB, PC]],
        case RateOwned of true -> stop(pw_rate); false -> ok end,
        flush()
    end.

socket(Parent, Tag) ->
    receive
        {hub_json, Event} -> Parent ! {event, Tag, jsx:decode(pw_util:json(Event), [return_maps])}, socket(Parent, Tag);
        {hub_text, Payload, _} -> Parent ! {event, Tag, jsx:decode(Payload, [return_maps])}, socket(Parent, Tag)
    end.

event(Tag, Type, Cid) ->
    receive
        {event, Tag, #{<<"type">> := Type, <<"conversation_id">> := Cid} = Event} -> Event
    after 1000 -> erlang:error({missing_event, Tag, Type, Cid}) end.

no_event(Tag, Type, Cid) ->
    receive {event, Tag, #{<<"type">> := Type, <<"conversation_id">> := Cid}} -> ?assert(false)
    after 40 -> ok end.

stop(Name) -> case whereis(Name) of undefined -> ok; Pid -> gen_server:stop(Pid) end.
flush() -> receive {event, _, _} -> flush() after 0 -> ok end.
