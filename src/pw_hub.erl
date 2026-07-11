-module(pw_hub).
-behaviour(gen_server).
-export([
    start_link/0, connect/2, connect/3, disconnect/1, subscribe/2, unsubscribe_all/1,
    notify_user/2, broadcast/2, status_update/2,
    voice_join/4, voice_leave/2, voice_state/4, voice_signal/4,
    call_ring/5, call_decline/2, call_cancel/2, call_accept/4,
    call_join/4, call_leave/2, call_state/4, call_signal/4
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(RING_MS, 45000).

-record(st, {users = #{}, pids = #{}, subs = #{}, voices = #{}, calls = #{}, rings = #{}, online = #{}}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
connect(Uid, Pid) -> connect(Uid, Pid, <<"online">>).
connect(Uid, Pid, Status) -> gen_server:cast(?MODULE, {connect, Uid, Pid, Status}).
disconnect(Pid) -> gen_server:cast(?MODULE, {disconnect, Pid}).
subscribe(Pid, Key) -> gen_server:cast(?MODULE, {subscribe, Pid, Key}).
unsubscribe_all(Pid) -> gen_server:cast(?MODULE, {unsubscribe_all, Pid}).
notify_user(Uid, Event) -> gen_server:cast(?MODULE, {notify_user, Uid, Event}).
broadcast(Key, Event) -> gen_server:cast(?MODULE, {broadcast, Key, Event}).
status_update(Uid, Status) -> gen_server:cast(?MODULE, {status_update, Uid, Status}).
voice_join(ChannelId, Uid, Pid, Profile) -> gen_server:cast(?MODULE, {voice_join, ChannelId, Uid, Pid, Profile}).
voice_leave(ChannelId, Uid) -> gen_server:cast(?MODULE, {voice_leave, ChannelId, Uid}).
voice_state(ChannelId, Uid, Patch, Profile) -> gen_server:cast(?MODULE, {voice_state, ChannelId, Uid, Patch, Profile}).
voice_signal(ChannelId, From, To, Signal) -> gen_server:cast(?MODULE, {voice_signal, ChannelId, From, To, Signal}).
call_ring(Cid, Uid, Pid, Profile, Targets) -> gen_server:cast(?MODULE, {call_ring, Cid, Uid, Pid, Profile, Targets}).
call_decline(Cid, Uid) -> gen_server:cast(?MODULE, {call_decline, Cid, Uid}).
call_cancel(Cid, Uid) -> gen_server:cast(?MODULE, {call_cancel, Cid, Uid}).
call_accept(Cid, Uid, Pid, Profile) -> gen_server:cast(?MODULE, {call_accept, Cid, Uid, Pid, Profile}).
call_join(ConversationId, Uid, Pid, Profile) -> gen_server:cast(?MODULE, {call_join, ConversationId, Uid, Pid, Profile}).
call_leave(ConversationId, Uid) -> gen_server:cast(?MODULE, {call_leave, ConversationId, Uid}).
call_state(ConversationId, Uid, Patch, Profile) -> gen_server:cast(?MODULE, {call_state, ConversationId, Uid, Patch, Profile}).
call_signal(ConversationId, From, To, Signal) -> gen_server:cast(?MODULE, {call_signal, ConversationId, From, To, Signal}).

init([]) -> {ok, #st{}}.

handle_call(_, _, St) -> {reply, ok, St}.

handle_cast({connect, Uid, Pid, Status0}, St) ->
    monitor(process, Pid),
    Users = add_to_set(Uid, Pid, St#st.users),
    Pids = maps:put(Pid, Uid, St#st.pids),
    WasOffline = not maps:is_key(Uid, St#st.online),
    Status = normalize_status(Status0),
    Online = case WasOffline of
        true ->
            case visible_status(Status) of
                true ->
                    send_to_others(Pids, #{type => presence_online, user_id => Uid, status => Status}, Pid),
                    maps:put(Uid, Status, St#st.online);
                false ->
                    St#st.online
            end;
        false ->
            St#st.online
    end,
    Pid ! {hub_json, #{type => presence_state, online => maps:keys(Online),
        statuses => maps:from_list([{U, S} || {U, S} <- maps:to_list(Online)])}},
    log("client_connected", #{uid => Uid, sessions => length(maps:get(Uid, Users, [])), online_users => map_size(Online)}),
    {noreply, St#st{users = Users, pids = Pids, online = Online}};
handle_cast({disconnect, Pid}, St) ->
    log("client_disconnected", #{uid => maps:get(Pid, St#st.pids, undefined)}),
    {noreply, remove_pid(Pid, St)};
handle_cast({unsubscribe_all, Pid}, St) -> {noreply, St#st{subs = remove_from_all(Pid, St#st.subs)}};
handle_cast({subscribe, Pid, Key}, St) -> {noreply, St#st{subs = add_to_set(Key, Pid, St#st.subs)}};
handle_cast({notify_user, Uid, Event}, St) ->
    Payload = case maps:get(type, Event, undefined) of
        call_incoming -> Event;
        call_ended -> Event;
        call_declined -> Event;
        call_accepted -> Event;
        call_cancelled -> Event;
        call_missed -> Event;
        _ -> #{type => notification, event => Event}
    end,
    send_many(maps:get(Uid, St#st.users, []), Payload),
    {noreply, St};
handle_cast({broadcast, Key, Event}, St) ->
    send_many(maps:get(Key, St#st.subs, []), Event),
    {noreply, St};
handle_cast({voice_join, ChannelId, Uid, Pid, Profile}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room0)], #{type => voice_peer_joined, channel_id => ChannelId, user_id => Uid, profile => strip_profile(Profile)}),
    Room = maps:put(Uid, #{pid => Pid, profile => Profile, muted => false, deafened => false}, Room0),
    log("voice_join", #{uid => Uid, channel_id => ChannelId, participants => map_size(Room)}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room)], #{type => voice_state, channel_id => ChannelId, users => room_users(Room)}),
    {noreply, St0#st{voices = maps:put(Key, Room, St0#st.voices)}};
handle_cast({voice_leave, ChannelId, Uid}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    Room = maps:remove(Uid, Room0),
    log("voice_leave", #{uid => Uid, channel_id => ChannelId, participants => map_size(Room)}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room)], #{type => voice_peer_left, channel_id => ChannelId, user_id => Uid}),
    Voices = put_or_remove(Key, Room, St0#st.voices),
    {noreply, St0#st{voices = Voices}};
handle_cast({voice_state, ChannelId, Uid, Patch, Profile}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    Info0 = maps:get(Uid, Room0, #{pid => undefined, profile => Profile}),
    Info = maps:merge(Info0, Patch#{profile => Profile}),
    Room = maps:put(Uid, Info, Room0),
    log("voice_state", #{uid => Uid, channel_id => ChannelId, patch => Patch}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room)], #{type => voice_state, channel_id => ChannelId, users => room_users(Room)}),
    {noreply, St0#st{voices = maps:put(Key, Room, St0#st.voices)}};
handle_cast({voice_signal, ChannelId, From, To, Signal}, St) ->
    Key = {voice, ChannelId},
    Room = maps:get(Key, St#st.voices, #{}),
    logger:debug("[plainwire:hub] voice_signal ~p", [#{channel_id => ChannelId, from => From, to => To, kind => signal_kind(Signal)}]),
    relay_signal(Room, From, To, #{type => voice_signal, channel_id => ChannelId, from_user_id => From, signal => Signal}),
    {noreply, St};
handle_cast({call_ring, Cid, Uid, Pid, Profile, Targets}, St0) ->
    Key = {ring, Cid},
    St1 = end_ring(St0, Key, call_cancelled, missed),
    Ref = erlang:send_after(?RING_MS, self(), {ring_timeout, Cid, Uid}),
    Targets1 = lists:filter(fun(T) -> T =/= Uid end, Targets),
    log("call_ring", #{uid => Uid, conversation_id => Cid, target_count => length(Targets1)}),
    Ring = #{
        caller_id => Uid,
        caller_pid => Pid,
        caller_profile => Profile,
        targets => Targets1,
        declined => [],
        accepted => undefined,
        timer => Ref
    },
    Pid ! {hub_json, #{type => call_ringing, conversation_id => Cid, targets => length(Targets1), profile => strip_profile(Profile)}},
    [notify_user(T, #{type => call_incoming, conversation_id => Cid, from_user_id => Uid, profile => strip_profile(Profile)}) || T <- Targets1],
    {noreply, St1#st{rings = maps:put(Key, Ring, St1#st.rings)}};
handle_cast({call_decline, Cid, Uid}, St0) ->
    Key = {ring, Cid},
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Caller, targets := Targets, declined := Declined} ->
            Ring = maps:get(Key, St0#st.rings),
            Declined1 = lists:usort([Uid | Declined]),
            Ring1 = Ring#{declined => Declined1},
            notify_user(Caller, #{type => call_declined, conversation_id => Cid, user_id => Uid}),
            notify_user(Uid, #{type => call_ended, conversation_id => Cid, reason => declined}),
            case lists:sort(Targets -- Declined1) of
                [] ->
                    {noreply, end_ring(St0, Key, call_cancelled, all_declined)};
                _ ->
                    {noreply, St0#st{rings = maps:put(Key, Ring1, St0#st.rings)}}
            end;
        _ ->
            {noreply, St0}
    end;
handle_cast({call_cancel, Cid, Uid}, St0) ->
    Key = {ring, Cid},
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Uid} ->
            {noreply, end_ring(St0, Key, call_cancelled, cancelled)};
        _ ->
            {noreply, St0}
    end;
handle_cast({call_accept, Cid, Uid, Pid, Profile}, St0) ->
    Key = {ring, Cid},
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Caller, caller_pid := CPid, caller_profile := CProfile, targets := Targets, timer := Ref} ->
            cancel_timer(Ref),
            notify_ring_parties(Targets, #{type => call_ended, conversation_id => Cid, reason => accepted}, Uid),
            notify_user(Caller, #{type => call_accepted, conversation_id => Cid, user_id => Uid, profile => strip_profile(Profile)}),
            notify_user(Uid, #{type => call_accepted, conversation_id => Cid, user_id => Caller, profile => strip_profile(CProfile)}),
            St1 = St0#st{rings = maps:remove(Key, St0#st.rings)},
            St2 = do_call_join(Cid, Uid, Pid, Profile, St1),
            St3 = do_call_join(Cid, Caller, CPid, CProfile, St2),
            {noreply, St3};
        _ ->
            {noreply, do_call_join(Cid, Uid, Pid, Profile, St0)}
    end;
handle_cast({call_join, ConversationId, Uid, Pid, Profile}, St0) ->
    {noreply, do_call_join(ConversationId, Uid, Pid, Profile, St0)};
handle_cast({call_leave, ConversationId, Uid}, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    Room = maps:remove(Uid, Room0),
    log("call_leave", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room)], #{type => call_peer_left, conversation_id => ConversationId, user_id => Uid}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room)], #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
    Calls = put_or_remove(Key, Room, St0#st.calls),
    {noreply, St0#st{calls = Calls}};
handle_cast({call_state, ConversationId, Uid, Patch, Profile}, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    Info0 = maps:get(Uid, Room0, #{pid => undefined, profile => Profile}),
    Info = maps:merge(Info0, Patch#{profile => Profile}),
    Room = maps:put(Uid, Info, Room0),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room)], #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
    {noreply, St0#st{calls = maps:put(Key, Room, St0#st.calls)}};
handle_cast({call_signal, ConversationId, From, To, Signal}, St) ->
    Key = {call, ConversationId},
    Room = maps:get(Key, St#st.calls, #{}),
    relay_signal(Room, From, To, #{type => call_signal, conversation_id => ConversationId, from_user_id => From, signal => Signal}),
    {noreply, St};
handle_cast({status_update, Uid, Status0}, St) ->
    Status = normalize_status(Status0),
    Online0 = St#st.online,
    WasVisible = maps:is_key(Uid, Online0),
    IsConnected = maps:is_key(Uid, St#st.users),
    case {IsConnected, WasVisible, visible_status(Status)} of
        {false, _, _} ->
            {noreply, St};
        {true, true, false} ->
            send_to_others(St#st.pids, #{type => presence_offline, user_id => Uid, status => Status}, undefined),
            {noreply, St#st{online = maps:remove(Uid, Online0)}};
        {true, false, true} ->
            send_to_others(St#st.pids, #{type => presence_online, user_id => Uid, status => Status}, undefined),
            {noreply, St#st{online = maps:put(Uid, Status, Online0)}};
        {true, true, true} ->
            send_to_others(St#st.pids, #{type => presence_status, user_id => Uid, status => Status}, undefined),
            {noreply, St#st{online = maps:put(Uid, Status, Online0)}};
        {true, false, false} ->
            {noreply, St}
    end;
handle_cast(_, St) -> {noreply, St}.

handle_info({ring_timeout, Cid, Uid}, St0) ->
    Key = {ring, Cid},
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Uid} ->
            {noreply, end_ring(St0, Key, call_missed, timeout)};
        _ ->
            {noreply, St0}
    end;
handle_info({'DOWN', _, process, Pid, _}, St) -> {noreply, remove_pid(Pid, St)};
handle_info(_, St) -> {noreply, St}.

terminate(_, _) -> ok.
code_change(_, St, _) -> {ok, St}.

do_call_join(ConversationId, Uid, Pid, Profile, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room0)], #{type => call_peer_joined, conversation_id => ConversationId, user_id => Uid, profile => strip_profile(Profile)}),
    Room = maps:put(Uid, #{pid => Pid, profile => Profile, muted => false, deafened => false}, Room0),
    log("call_join", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
    send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(Room)], #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
    St0#st{calls = maps:put(Key, Room, St0#st.calls)}.

end_ring(St0, Key, EventType, Reason) ->
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_pid := CPid, targets := Targets, timer := Ref} ->
            cancel_timer(Ref),
            Event = #{type => EventType, conversation_id => element(2, Key), reason => Reason},
            CPid ! {hub_json, Event},
            notify_ring_parties(Targets, Event, undefined),
            St0#st{rings = maps:remove(Key, St0#st.rings)};
        undefined ->
            St0
    end.

notify_ring_parties(Targets, Event, Skip) ->
    [notify_user(T, Event) || T <- Targets, T =/= Skip],
    ok.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref), ok.

relay_signal(Room, From, To, Event) ->
    case {maps:is_key(From, Room), maps:get(To, Room, undefined)} of
        {true, Info} when is_map(Info) -> maps:get(pid, Info) ! {hub_json, Event};
        _ -> ok
    end,
    ok.

send_many(Pids, Event) -> [Pid ! {hub_json, Event} || Pid <- Pids, is_pid(Pid)], ok.
send_to_others(Pids, Event, Skip) -> [Pid ! {hub_json, Event} || Pid <- maps:keys(Pids), Pid =/= Skip, is_pid(Pid)], ok.

signal_kind(Signal) when is_map(Signal) -> maps:get(<<"kind">>, Signal, unknown);
signal_kind(_) -> unknown.

log(Event, Data) -> logger:notice("[plainwire:hub] ~s ~p", [Event, Data]).
add_to_set(Key, Pid, Map) -> maps:put(Key, lists:usort([Pid | maps:get(Key, Map, [])]), Map).
remove_from_all(Pid, Map) -> maps:map(fun(_, L) -> lists:delete(Pid, L) end, Map).
put_or_remove(Key, Room, Map) when map_size(Room) =:= 0 -> maps:remove(Key, Map);
put_or_remove(Key, Room, Map) -> maps:put(Key, Room, Map).
room_users(Room) -> [#{user_id => Uid, muted => maps:get(muted, Info, false), deafened => maps:get(deafened, Info, false)} || {Uid, Info} <- maps:to_list(Room)].

strip_profile(Info) when is_map(Info) ->
    maps:remove(avatar_source_url, maps:remove(banner_source_url, Info));
strip_profile(Other) -> Other.

normalize_status(<<"busy">>) -> <<"busy">>;
normalize_status(<<"away">>) -> <<"away">>;
normalize_status(<<"invisible">>) -> <<"invisible">>;
normalize_status(_) -> <<"online">>.

visible_status(<<"invisible">>) -> false;
visible_status(_) -> true.

remove_pid(Pid, St0) ->
    Uid = maps:get(Pid, St0#st.pids, undefined),
    Users = case Uid of undefined -> St0#st.users; _ -> update_set(Uid, Pid, St0#st.users) end,
    Pids = maps:remove(Pid, St0#st.pids),
    Online = case Uid of
        undefined -> St0#st.online;
        _ ->
            case maps:find(Uid, Users) of
                error -> % no longer any PIDs for this user
                    case maps:find(Uid, St0#st.online) of
                        {ok, PrevStatus} ->
                            send_to_others(Pids, #{type => presence_offline, user_id => Uid, status => PrevStatus}, Pid);
                        error ->
                            ok
                    end,
                    maps:remove(Uid, St0#st.online);
                _ -> St0#st.online
            end
    end,
    Subs = remove_from_all(Pid, St0#st.subs),
    Voices = drop_pid_from_rooms(Pid, St0#st.voices, voice),
    Calls = drop_pid_from_rooms(Pid, St0#st.calls, call),
    Rings = drop_caller_rings(Pid, St0#st.rings, St0#st.users),
    St0#st{users = Users, pids = Pids, online = Online, subs = Subs, voices = Voices, calls = Calls, rings = Rings}.

update_set(Key, Pid, Map) ->
    L = lists:delete(Pid, maps:get(Key, Map, [])),
    case L of [] -> maps:remove(Key, Map); _ -> maps:put(Key, L, Map) end.

drop_caller_rings(Pid, Rings, Users) ->
    maps:fold(fun(Key, #{caller_pid := CPid, targets := Targets, timer := Ref}, Acc) ->
        case CPid of
            Pid ->
                cancel_timer(Ref),
                Event = #{type => call_cancelled, conversation_id => element(2, Key), reason => caller_offline},
                send_many(lists:flatten([maps:get(T, Users, []) || T <- Targets]), Event),
                maps:remove(Key, Acc);
            _ ->
                Acc
        end
    end, Rings, Rings).

drop_pid_from_rooms(Pid, Rooms, Kind) ->
    maps:fold(fun(Key, Room0, Acc) ->
        Gone = [U || {U, Info} <- maps:to_list(Room0), maps:get(pid, Info, undefined) =:= Pid],
        Room = lists:foldl(fun(U, R) -> maps:remove(U, R) end, Room0, Gone),
        case {Gone, Room} of
            {[], _} -> maps:put(Key, Room, Acc);
            {_, R} when map_size(R) =:= 0 -> Acc;
            {[U | _], R} ->
                EventType = case Kind of voice -> voice_peer_left; call -> call_peer_left end,
                IdKey = case Key of {_, Id} -> Id end,
                IdName = case Kind of voice -> channel_id; call -> conversation_id end,
                send_many([maps:get(pid, V) || {_K, V} <- maps:to_list(R)], #{type => EventType, IdName => IdKey, user_id => U}),
                maps:put(Key, R, Acc)
        end
    end, #{}, Rooms).
