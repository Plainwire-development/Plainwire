-module(pw_hub).
-behaviour(gen_server).
-export([
    start_link/0, connect/2, connect/3, disconnect/1, subscribe/2, unsubscribe_all/1, watch_presence/2,
    revoke_server_access/3, revoke_conversation_access/2,
    notify_user/2, broadcast/2, status_update/2,
    voice_join/4, voice_leave/3, voice_state/5, voice_signal/5, voice_activity/5,
    call_ring/5, call_decline/2, call_cancel/3, call_accept/5,
    call_join/5, call_rejoin/5, call_leave/3, call_state/5, call_signal/5,
    room_capacity/0, share_capacity/0, status_update/3, stats/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(RING_MS, 45000).
-define(JOIN_TIMEOUT, 5000).
-define(RECONNECT_GRACE_MS, 15000).

%% full mesh gets expensive fast. browsers are not tiny SFUs.
room_capacity() -> min(32, max(2, pw_util:env_int("PLAINWIRE_VOICE_MAX_PARTICIPANTS", 8))).
share_capacity() -> min(8, max(1, pw_util:env_int("PLAINWIRE_VOICE_MAX_SHARES", 2))).

-record(st, {users = #{}, pids = #{}, pid_statuses = #{}, subs = #{}, voices = #{}, calls = #{}, rings = #{}, online = #{}, watches = #{}, watchers = #{}}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
connect(Uid, Pid) -> connect(Uid, Pid, <<"online">>).
connect(Uid, Pid, Status) -> gen_server:cast(?MODULE, {connect, Uid, Pid, Status}).
disconnect(Pid) -> gen_server:cast(?MODULE, {disconnect, Pid}).
subscribe(Pid, Key) -> gen_server:cast(?MODULE, {subscribe, Pid, Key}).
unsubscribe_all(Pid) -> gen_server:cast(?MODULE, {unsubscribe_all, Pid}).
watch_presence(Pid, Uids) -> gen_server:cast(?MODULE, {watch_presence, Pid, Uids}).
revoke_server_access(Uid, ServerId, ChannelIds) -> gen_server:cast(?MODULE, {revoke_server_access, Uid, ServerId, ChannelIds}).
revoke_conversation_access(Uid, ConversationId) -> gen_server:cast(?MODULE, {revoke_conversation_access, Uid, ConversationId}).
notify_user(Uid, Event) -> pw_cluster:send_user(Uid, Event).
broadcast(Key, Event) -> pw_cluster:broadcast(Key, Event).
status_update(Uid, Status) -> gen_server:cast(?MODULE, {status_update, Uid, undefined, Status}).
status_update(Uid, Pid, Status) -> gen_server:cast(?MODULE, {status_update, Uid, Pid, Status}).
%% join must answer before the browser starts grabbing media.
voice_join(ChannelId, Uid, Pid, Profile) -> join_call({voice_join, ChannelId, Uid, Pid, Profile}).
voice_leave(ChannelId, Uid, Pid) -> gen_server:cast(?MODULE, {voice_leave, ChannelId, Uid, Pid}).
voice_state(ChannelId, Uid, Pid, Patch, Profile) -> gen_server:cast(?MODULE, {voice_state, ChannelId, Uid, Pid, Patch, Profile}).
voice_signal(ChannelId, From, FromPid, To, Signal) -> gen_server:cast(?MODULE, {voice_signal, ChannelId, From, FromPid, To, Signal}).
voice_activity(Kind, Id, Uid, Pid, Active) -> gen_server:cast(?MODULE, {room_activity, Kind, Id, Uid, Pid, Active}).
call_ring(Cid, Uid, Pid, Profile, Targets) -> gen_server:cast(?MODULE, {call_ring, Cid, Uid, Pid, Profile, Targets}).
call_decline(Cid, Uid) -> gen_server:cast(?MODULE, {call_decline, Cid, Uid}).
call_cancel(Cid, Uid, Pid) -> gen_server:cast(?MODULE, {call_cancel, Cid, Uid, Pid}).
call_accept(Cid, Uid, Pid, Profile, Audience) -> join_call({call_accept, Cid, Uid, Pid, Profile, Audience}).
call_join(ConversationId, Uid, Pid, Profile, Audience) -> join_call({call_join, ConversationId, Uid, Pid, Profile, Audience}).
%% Browser-side Join/Rejoin is only valid while a room still exists. Keeping this
%% separate from call_join/5 preserves the low-level primitive used by tests and
%% internal setup while preventing stale UI from resurrecting an ended call.
call_rejoin(ConversationId, Uid, Pid, Profile, Audience) -> join_call({call_rejoin, ConversationId, Uid, Pid, Profile, Audience}).
call_leave(ConversationId, Uid, Pid) -> gen_server:cast(?MODULE, {call_leave, ConversationId, Uid, Pid}).
call_state(ConversationId, Uid, Pid, Patch, Profile) -> gen_server:cast(?MODULE, {call_state, ConversationId, Uid, Pid, Patch, Profile}).
call_signal(ConversationId, From, FromPid, To, Signal) -> gen_server:cast(?MODULE, {call_signal, ConversationId, From, FromPid, To, Signal}).
stats() ->
    try gen_server:call(?MODULE, stats, 500)
    catch exit:_ -> #{available => false} end.

%% don't wedge the socket if the hub is having a day.
join_call(Msg) ->
    try gen_server:call(?MODULE, Msg, ?JOIN_TIMEOUT)
    catch
        exit:{timeout, _} -> {error, unavailable};
        exit:{noproc, _} -> {error, unavailable};
        exit:{{shutdown, _}, _} -> {error, unavailable}
    end.

init([]) -> {ok, #st{}}.

handle_call({voice_join, ChannelId, Uid, Pid, Profile}, _From, St0) ->
    Room = maps:get({voice, ChannelId}, St0#st.voices, #{}),
    case room_admits(Room, Uid) of
        false ->
            log("voice_join_rejected", #{uid => Uid, channel_id => ChannelId, participants => map_size(Room)}),
            {reply, {error, room_full}, St0};
        true ->
            St1 = evict_other_rooms(Uid, Pid, {voice, ChannelId}, St0),
            {reply, ok, do_voice_join(ChannelId, Uid, Pid, Profile, St1)}
    end;
handle_call({call_join, ConversationId, Uid, Pid, Profile, Audience}, _From, St0) ->
    Room = maps:get({call, ConversationId}, St0#st.calls, #{}),
    case room_admits(Room, Uid) of
        false ->
            log("call_join_rejected", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
            {reply, {error, room_full}, St0};
        true ->
            St1 = evict_other_rooms(Uid, Pid, {call, ConversationId}, St0),
            {reply, ok, do_call_join(ConversationId, Uid, Pid, Profile, Audience, St1)}
    end;
handle_call({call_rejoin, ConversationId, Uid, Pid, Profile, Audience}, _From, St0) ->
    case maps:find({call, ConversationId}, St0#st.calls) of
        error ->
            log("call_rejoin_rejected", #{uid => Uid, conversation_id => ConversationId, reason => no_active_call}),
            {reply, {error, no_active_call}, St0};
        {ok, Room} ->
            case room_admits(Room, Uid) of
                false ->
                    log("call_rejoin_rejected", #{uid => Uid, conversation_id => ConversationId, reason => room_full, participants => map_size(Room)}),
                    {reply, {error, room_full}, St0};
                true ->
                    St1 = evict_other_rooms(Uid, Pid, {call, ConversationId}, St0),
                    {reply, ok, do_call_join(ConversationId, Uid, Pid, Profile, Audience, St1)}
            end
    end;
handle_call({call_accept, Cid, Uid, Pid, Profile, Audience0}, _From, St0) ->
    {Reply, St} = accept_ring(Cid, Uid, Pid, Profile, Audience0, St0),
    {reply, Reply, St};
handle_call(stats, _From, St) ->
    VoiceRooms = maps:values(St#st.voices),
    CallRooms = maps:values(St#st.calls),
    SubscriptionCount = lists:sum([length(Pids) || Pids <- maps:values(St#st.subs)]),
    {reply, #{available => true,
              websocket_connections => map_size(St#st.pids),
              online_users => map_size(St#st.online),
              subscription_links => SubscriptionCount,
              voice_rooms => length(VoiceRooms),
              voice_participants => lists:sum([map_size(Room) || Room <- VoiceRooms]),
              call_rooms => length(CallRooms),
              call_participants => lists:sum([map_size(Room) || Room <- CallRooms]),
              ringing_calls => map_size(St#st.rings)}, St};
handle_call(_, _, St) -> {reply, ok, St}.

%% reconnecting users don't count against themselves.
room_admits(Room, Uid) ->
    maps:is_key(Uid, Room) orelse map_size(Room) < room_capacity().

accept_ring(Cid, Uid, Pid, Profile, Audience0, St0) ->
    Room = maps:get({call, Cid}, St0#st.calls, #{}),
    case room_admits(Room, Uid) of
        false ->
            {{error, room_full}, St0};
        true ->
            StBase = evict_other_rooms(Uid, Pid, {call, Cid}, St0),
            Key = {ring, Cid},
            case maps:get(Key, StBase#st.rings, undefined) of
                #{caller_id := Caller, caller_pid := CPid, caller_profile := CProfile, targets := Targets, timer := Ref} ->
                    cancel_timer(Ref),
                    notify_ring_parties(Targets, #{type => call_ended, conversation_id => Cid, reason => accepted}, Uid),
                    notify_user(Caller, #{type => call_accepted, conversation_id => Cid, user_id => Uid, profile => strip_profile(Profile)}),
                    notify_user(Uid, #{type => call_accepted, conversation_id => Cid, user_id => Caller, profile => strip_profile(CProfile)}),
                    St1 = StBase#st{rings = maps:remove(Key, StBase#st.rings)},
                    Audience = lists:usort([Uid, Caller | Targets ++ Audience0]),
                    St2 = do_call_join(Cid, Uid, Pid, Profile, Audience, St1),
                    St3 = do_call_join(Cid, Caller, CPid, CProfile, Audience, St2),
                    {ok, St3};
                _ ->
                    {{error, no_active_call}, StBase}
            end
    end.

handle_cast({connect, Uid, Pid, Status0}, St) ->
    monitor(process, Pid),
    Users = add_to_set(Uid, Pid, St#st.users),
    Pids = maps:put(Pid, Uid, St#st.pids),
    Status = normalize_status(Status0),
    PidStatuses = maps:put(Pid, Status, St#st.pid_statuses),
    Prev = maps:get(Uid, St#st.online, undefined),
    Effective = effective_status(Uid, Users, PidStatuses),
    Online = update_presence(Uid, Prev, Effective, St#st.watchers, Pid, St#st.online),
    %% Seed the new socket with the account-wide effective status immediately.
    %% A second tab being idle or invisible must not make an active tab look
    %% offline to itself or to other presence watchers.
    Visible = case visible_status(Effective) of true -> [Uid]; false -> [] end,
    Statuses = case Visible of [] -> #{}; _ -> #{Uid => Effective} end,
    Pid ! {hub_json, #{type => presence_state, online => Visible, statuses => Statuses}},
    send_active_calls(Pid, Uid, St#st.calls),
    log("client_connected", #{uid => Uid, sessions => length(maps:get(Uid, Users, [])), online_users => map_size(Online)}),
    {noreply, St#st{users = Users, pids = Pids, pid_statuses = PidStatuses, online = Online}};
handle_cast({disconnect, Pid}, St) ->
    log("client_disconnected", #{uid => maps:get(Pid, St#st.pids, undefined)}),
    {noreply, remove_pid(Pid, St)};
handle_cast({unsubscribe_all, Pid}, St) -> {noreply, St#st{subs = remove_from_all(Pid, St#st.subs)}};
handle_cast({subscribe, Pid, Key}, St) -> {noreply, St#st{subs = add_to_set(Key, Pid, St#st.subs)}};
handle_cast({revoke_server_access, Uid, ServerId, ChannelIds0}, St0) ->
    ChannelIds = lists:usort([Id || Id <- ChannelIds0, is_integer(Id), Id > 0]),
    Pids = maps:get(Uid, St0#st.users, []),
    Keys = [{server, ServerId} | [{channel, Id} || Id <- ChannelIds]],
    Subs = lists:foldl(fun(Key, Acc) -> remove_pids_from_key(Key, Pids, Acc) end, St0#st.subs, Keys),
    Voices = lists:foldl(fun(ChannelId, Acc) -> remove_user_from_room_now(voice, ChannelId, Uid, Acc, St0#st.users) end, St0#st.voices, ChannelIds),
    send_many(Pids, #{type => access_revoked, scope => server, server_id => ServerId, channel_ids => ChannelIds}),
    log("server_access_revoked", #{uid => Uid, server_id => ServerId, tabs => length(Pids), channels => length(ChannelIds)}),
    {noreply, St0#st{subs = Subs, voices = Voices}};
handle_cast({revoke_conversation_access, Uid, ConversationId}, St0) ->
    Pids = maps:get(Uid, St0#st.users, []),
    Subs = remove_pids_from_key({direct, ConversationId}, Pids, St0#st.subs),
    Calls = remove_user_from_room_now(call, ConversationId, Uid, St0#st.calls, St0#st.users),
    send_many(Pids, #{type => access_revoked, scope => direct, conversation_id => ConversationId}),
    log("conversation_access_revoked", #{uid => Uid, conversation_id => ConversationId, tabs => length(Pids)}),
    {noreply, St0#st{subs = Subs, calls = Calls}};
handle_cast({watch_presence, Pid, Uids0}, St0) ->
    Requested = [U || U <- Uids0, is_integer(U), U > 0],
    %% include self. older clients somehow made themselves look offline.
    Uids = case maps:get(Pid, St0#st.pids, undefined) of
        SelfUid when is_integer(SelfUid), SelfUid > 0 -> lists:usort([SelfUid | Requested]);
        _ -> lists:usort(Requested)
    end,
    Old = maps:get(Pid, St0#st.watches, []),
    Watchers0 = lists:foldl(fun(U, Acc) -> update_set(U, Pid, Acc) end, St0#st.watchers, Old),
    Watchers = lists:foldl(fun(U, Acc) -> add_to_set(U, Pid, Acc) end, Watchers0, Uids),
    Watches = case Uids of [] -> maps:remove(Pid, St0#st.watches); _ -> maps:put(Pid, Uids, St0#st.watches) end,
    Statuses = maps:from_list([{U, S} || U <- Uids, {ok, S} <- [maps:find(U, St0#st.online)]]),
    Pid ! {hub_json, #{type => presence_state, online => maps:keys(Statuses), statuses => Statuses}},
    {noreply, St0#st{watches = Watches, watchers = Watchers}};
handle_cast(cluster_resync, St) ->
    send_many(maps:keys(St#st.pids), #{type => realtime_resync}),
    {noreply, St};
handle_cast({notify_user, Uid, Event}, St) ->
    Payload = case maps:get(type, Event, undefined) of
        call_incoming -> Event;
        call_ended -> Event;
        call_declined -> Event;
        call_accepted -> Event;
        call_cancelled -> Event;
        call_missed -> Event;
        call_presence -> Event;
        mention -> Event;
        direct_message -> Event;
        channel_message -> Event;
        _ -> #{type => notification, event => Event}
    end,
    send_many(maps:get(Uid, St#st.users, []), Payload),
    {noreply, St};
handle_cast({broadcast, Key, Event}, St) ->
    send_many(maps:get(Key, St#st.subs, []), Event),
    {noreply, St};
handle_cast({voice_leave, ChannelId, Uid, Pid}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    case member_owned(Room0, Uid, Pid) of
        false -> {noreply, St0};
        true ->
            Room = maps:remove(Uid, Room0),
            log("voice_leave", #{uid => Uid, channel_id => ChannelId, participants => map_size(Room)}),
            send_many(room_pids(Room), #{type => voice_peer_left, channel_id => ChannelId, user_id => Uid}),
            Voices = put_or_remove(Key, Room, St0#st.voices),
            {noreply, St0#st{voices = Voices}}
    end;
handle_cast({voice_state, ChannelId, Uid, Pid, Patch, Profile}, St0) ->
    {noreply, apply_room_state(voice, ChannelId, Uid, Pid, Patch, Profile, St0)};
handle_cast({room_activity, Kind, Id, Uid, Pid, Active}, St) ->
    Room = maps:get({Kind, Id}, rooms(Kind, St), #{}),
    case member_owned(Room, Uid, Pid) of
        true -> send_many(room_pids(maps:remove(Uid, Room)), activity_event(Kind, Id, Uid, Active));
        false -> ok
    end,
    {noreply, St};
handle_cast({voice_signal, ChannelId, From, FromPid, To, Signal}, St) ->
    Key = {voice, ChannelId},
    Room = maps:get(Key, St#st.voices, #{}),
    logger:debug("[plainwire:hub] voice_signal ~p", [#{channel_id => ChannelId, from => From, to => To, kind => signal_kind(Signal)}]),
    relay_signal(Room, From, FromPid, To, #{type => voice_signal, channel_id => ChannelId, from_user_id => From, signal => Signal}),
    {noreply, St};
handle_cast({call_ring, Cid, Uid, Pid, Profile, Targets}, St0) ->
    case maps:get({ring, Cid}, St0#st.rings, undefined) of
        #{caller_id := Caller, targets := RingTargets} when Caller =/= Uid ->
            case lists:member(Uid, RingTargets) of
                %% both people pressed call. answer instead of cancelling each other.
                true -> {noreply, answer_crossed_ring(Cid, Uid, Pid, Profile, Targets, St0)};
                false -> {noreply, start_ring(Cid, Uid, Pid, Profile, Targets, St0)}
            end;
        _ ->
            {noreply, start_ring(Cid, Uid, Pid, Profile, Targets, St0)}
    end;
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
handle_cast({call_cancel, Cid, Uid, _Pid}, St0) ->
    Key = {ring, Cid},
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Uid} ->
            {noreply, end_ring(St0, Key, call_cancelled, cancelled)};
        _ ->
            {noreply, St0}
    end;
handle_cast({call_leave, ConversationId, Uid, Pid}, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    case member_owned(Room0, Uid, Pid) of
        false -> {noreply, St0};
        true ->
            Audience = room_audience(Room0),
            Room = maps:remove(Uid, Room0),
            log("call_leave", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
            send_many(room_pids(Room), #{type => call_peer_left, conversation_id => ConversationId, user_id => Uid}),
            send_many(room_pids(Room), #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
            Calls = put_or_remove(Key, Room, St0#st.calls),
            send_call_presence(ConversationId, Room, Audience, St0#st.users),
            {noreply, St0#st{calls = Calls}}
    end;
handle_cast({call_state, ConversationId, Uid, Pid, Patch, Profile}, St0) ->
    {noreply, apply_room_state(call, ConversationId, Uid, Pid, Patch, Profile, St0)};
handle_cast({call_signal, ConversationId, From, FromPid, To, Signal}, St) ->
    Key = {call, ConversationId},
    Room = maps:get(Key, St#st.calls, #{}),
    relay_signal(Room, From, FromPid, To, #{type => call_signal, conversation_id => ConversationId, from_user_id => From, signal => Signal}),
    {noreply, St};
handle_cast({status_update, Uid, Pid0, Status0}, St) ->
    Status = normalize_status(Status0),
    Pid = case Pid0 of
        P when is_pid(P) ->
            case maps:get(P, St#st.pids, undefined) of
                Uid -> P;
                _ -> first_user_pid(Uid, St#st.users)
            end;
        _ -> first_user_pid(Uid, St#st.users)
    end,
    case Pid of
        undefined ->
            {noreply, St};
        _ ->
            Prev = maps:get(Uid, St#st.online, undefined),
            PidStatuses = maps:put(Pid, Status, St#st.pid_statuses),
            Effective = effective_status(Uid, St#st.users, PidStatuses),
            Online = update_presence(Uid, Prev, Effective, St#st.watchers, undefined, St#st.online),
            {noreply, St#st{pid_statuses = PidStatuses, online = Online}}
    end;
handle_cast(_, St) -> {noreply, St}.

answer_crossed_ring(Cid, Uid, Pid, Profile, Audience, St0) ->
    log("call_ring_crossed", #{uid => Uid, conversation_id => Cid}),
    St1 = end_user_rings(St0, Uid, {ring, Cid}),
    case accept_ring(Cid, Uid, Pid, Profile, Audience, St1) of
        {ok, St} -> St;
        {{error, Reason}, St} -> notify_pid(Pid, #{type => error, error => Reason}), St
    end.

%% ringing the same conversation again from the same socket replaces the ring
%% quietly. "your call was cancelled" would tear down the call being placed.
replace_own_ring(St, Key, Pid) ->
    case maps:get(Key, St#st.rings, undefined) of
        #{caller_pid := Pid, timer := Ref} ->
            cancel_timer(Ref),
            St#st{rings = maps:remove(Key, St#st.rings)};
        _ ->
            end_ring(St, Key, call_cancelled, missed)
    end.

start_ring(Cid, Uid, Pid, Profile, Targets, St0) ->
    Key = {ring, Cid},
    StBase = evict_other_rooms(Uid, Pid, Key, St0),
    St1 = end_user_rings(replace_own_ring(StBase, Key, Pid), Uid, Key),
    RingMs = ring_timeout_ms(),
    Ref = erlang:send_after(RingMs, self(), {ring_timeout, Cid, Uid}),
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
    ExpiresAt = pw_util:now_ms() + RingMs,
    Pid ! {hub_json, #{type => call_ringing, conversation_id => Cid, targets => length(Targets1),
        profile => strip_profile(Profile), timeout_ms => RingMs, expires_at => ExpiresAt}},
    [notify_user(T, #{type => call_incoming, conversation_id => Cid, from_user_id => Uid,
        profile => strip_profile(Profile), timeout_ms => RingMs, expires_at => ExpiresAt}) || T <- Targets1],
    St1#st{rings = maps:put(Key, Ring, St1#st.rings)}.

handle_info({ring_timeout, Cid, Uid}, St0) ->
    Key = {ring, Cid},
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Uid} ->
            persist_missed_call(Uid, Cid),
            {noreply, end_ring(St0, Key, call_missed, timeout)};
        _ ->
            {noreply, St0}
    end;
handle_info({room_reconnect_expired, Kind, Id, Uid, Token}, St0) ->
    {noreply, expire_reconnecting_member(Kind, Id, Uid, Token, St0)};
handle_info({'DOWN', _, process, Pid, _}, St) -> {noreply, remove_pid(Pid, St)};
handle_info(_, St) -> {noreply, St}.

terminate(_, _) -> ok.
code_change(_, St, _) -> {ok, St}.

do_voice_join(ChannelId, Uid, Pid, Profile, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    notify_superseded(Room0, Uid, Pid, #{type => voice_superseded, channel_id => ChannelId}),
    send_many(room_pids(maps:remove(Uid, Room0)),
        #{type => voice_peer_joined, channel_id => ChannelId, user_id => Uid, profile => strip_profile(Profile)}),
    Room = maps:put(Uid, new_member(Pid, Profile, maps:get(Uid, Room0, #{})), Room0),
    log("voice_join", #{uid => Uid, channel_id => ChannelId, participants => map_size(Room)}),
    send_many(room_pids(Room), #{type => voice_state, channel_id => ChannelId, users => room_users(Room)}),
    St0#st{voices = maps:put(Key, Room, St0#st.voices)}.

do_call_join(ConversationId, Uid, Pid, Profile, Audience0, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    notify_superseded(Room0, Uid, Pid, #{type => call_superseded, conversation_id => ConversationId}),
    send_many(room_pids(maps:remove(Uid, Room0)),
        #{type => call_peer_joined, conversation_id => ConversationId, user_id => Uid, profile => strip_profile(Profile)}),
    Audience = lists:usort([Uid | [U || U <- Audience0, is_integer(U), U > 0]]),
    Room = maps:put(Uid, new_call_member(Pid, Profile, Audience, maps:get(Uid, Room0, #{})), Room0),
    log("call_join", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
    send_many(room_pids(Room), #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
    send_call_presence(ConversationId, Room, room_audience(Room), St0#st.users),
    St0#st{calls = maps:put(Key, Room, St0#st.calls)}.

%% a second tab takes the seat and tells the first to drop its mic.
notify_superseded(Room, Uid, Pid, Event) ->
    case maps:get(Uid, Room, undefined) of
        #{pid := Old} when is_pid(Old), Old =/= Pid -> Old ! {hub_json, Event}, ok;
        _ -> ok
    end.

new_member(Pid, Profile, Previous) ->
    cancel_member_reconnect(Previous),
    #{pid => Pid, profile => Profile,
      muted => maps:get(muted, Previous, false),
      deafened => maps:get(deafened, Previous, false),
      screen => false, screen_audio => false, reconnecting => false}.

new_call_member(Pid, Profile, Audience, Previous) ->
    (new_member(Pid, Profile, Previous))#{
        audience => lists:usort(Audience ++ maps:get(audience, Previous, []))
    }.

%% one user, one RTC room. enforce it here too; tabs are sneaky.
evict_other_rooms(Uid, NewPid, KeepKey, St0) ->
    Voices = evict_from_rooms(Uid, NewPid, KeepKey, St0#st.voices, voice, St0#st.users),
    Calls = evict_from_rooms(Uid, NewPid, KeepKey, St0#st.calls, call, St0#st.users),
    St0#st{voices = Voices, calls = Calls}.

evict_from_rooms(Uid, NewPid, KeepKey, Rooms, Kind, Users) ->
    maps:fold(fun(Key, Room0, Acc) ->
        case Key =:= KeepKey orelse not maps:is_key(Uid, Room0) of
            true -> maps:put(Key, Room0, Acc);
            false ->
                Info = maps:get(Uid, Room0),
                OldPid = maps:get(pid, Info, undefined),
                Id = element(2, Key),
                Room = maps:remove(Uid, Room0),
                case OldPid =/= NewPid of
                    true -> notify_pid(OldPid, superseded_event(Kind, Id));
                    false -> ok
                end,
                send_many(room_pids(Room), peer_left_event(Kind, Id, Uid)),
                send_many(room_pids(Room), state_event(Kind, Id, Room)),
                case Kind of
                    call -> send_call_presence(Id, Room, room_audience(Room0), Users);
                    voice -> ok
                end,
                put_or_remove(Key, Room, Acc)
        end
    end, #{}, Rooms).

superseded_event(voice, Id) -> #{type => voice_superseded, channel_id => Id};
superseded_event(call, Id) -> #{type => call_superseded, conversation_id => Id}.

peer_left_event(voice, Id, Uid) -> #{type => voice_peer_left, channel_id => Id, user_id => Uid};
peer_left_event(call, Id, Uid) -> #{type => call_peer_left, conversation_id => Id, user_id => Uid}.

rooms(voice, St) -> St#st.voices;
rooms(call, St) -> St#st.calls.

set_rooms(voice, Rooms, St) -> St#st{voices = Rooms};
set_rooms(call, Rooms, St) -> St#st{calls = Rooms}.

state_event(voice, Id, Room) -> #{type => voice_state, channel_id => Id, users => room_users(Room)};
state_event(call, Id, Room) -> #{type => call_state, conversation_id => Id, users => room_users(Room)}.

activity_event(voice, Id, Uid, Active) ->
    #{type => voice_activity, channel_id => Id, user_id => Uid, active => Active};
activity_event(call, Id, Uid, Active) ->
    #{type => call_activity, conversation_id => Id, user_id => Uid, active => Active}.

apply_room_state(Kind, Id, Uid, Pid, Patch, Profile, St0) ->
    Key = {Kind, Id},
    Rooms0 = rooms(Kind, St0),
    Room0 = maps:get(Key, Rooms0, #{}),
    case maps:get(Uid, Room0, undefined) of
        #{pid := Pid} = Info0 ->
            apply_member_state(Kind, Id, Uid, Patch, Profile, Key, Rooms0, Room0, Info0, St0);
        _ ->
            %% no join, no ghost participant.
            St0
    end.

apply_member_state(Kind, Id, Uid, Patch, Profile, Key, Rooms0, Room0, Info0, St0) ->
    Requested = maps:get(screen, Patch, maps:get(screen, Info0, false)),
    {Screen, Denied} = clamp_screen(Room0, Uid, Requested),
    ScreenAudio = Screen andalso maps:get(screen_audio, Patch, maps:get(screen_audio, Info0, false)),
    Deafened = maps:get(deafened, Patch, maps:get(deafened, Info0, false)),
    %% Deafening always closes the microphone too. Keep that invariant at the
    %% room boundary so older or modified clients cannot publish impossible UI.
    Muted = Deafened orelse maps:get(muted, Patch, maps:get(muted, Info0, false)),
    Info = maps:merge(Info0, Patch#{profile => Profile, muted => Muted, deafened => Deafened,
                                   screen => Screen, screen_audio => ScreenAudio}),
    Room = maps:put(Uid, Info, Room0),
    case Denied of
        true ->
            log("share_denied", #{uid => Uid, kind => Kind, id => Id, limit => share_capacity()}),
            notify_pid(maps:get(pid, Info, undefined), share_denied_event(Kind, Id));
        false -> ok
    end,
    send_many(room_pids(Room), state_event(Kind, Id, Room)),
    set_rooms(Kind, maps:put(Key, Room, Rooms0), St0).

share_denied_event(voice, Id) -> #{type => share_denied, channel_id => Id, reason => share_limit};
share_denied_event(call, Id) -> #{type => share_denied, conversation_id => Id, reason => share_limit}.

%% each share multiplies mesh work, so yes, there is a cap.
clamp_screen(_Room, _Uid, false) -> {false, false};
clamp_screen(Room, Uid, _Requested) ->
    Others = [U || {U, Info} <- maps:to_list(Room), U =/= Uid, maps:get(screen, Info, false)],
    case length(Others) < share_capacity() of
        true -> {true, false};
        false -> {false, true}
    end.

notify_pid(Pid, Event) when is_pid(Pid) -> Pid ! {hub_json, Event}, ok;
notify_pid(_, _) -> ok.

room_pids(Room) -> [maps:get(pid, Info) || {_Uid, Info} <- maps:to_list(Room), is_pid(maps:get(pid, Info, undefined))].

room_audience(Room) ->
    lists:usort(lists:flatten([
        [Uid | maps:get(audience, Info, [])]
        || {Uid, Info} <- maps:to_list(Room)
    ])).

send_call_presence(ConversationId, Room, Audience, Users) ->
    Event = #{type => call_presence, conversation_id => ConversationId,
        active => map_size(Room) > 0, users => room_users(Room)},
    Pids = lists:usort(lists:flatten([maps:get(Uid, Users, []) || Uid <- Audience])),
    send_many(Pids, Event).

send_active_calls(Pid, Uid, Calls) ->
    maps:foreach(fun({call, ConversationId}, Room) ->
        case lists:member(Uid, room_audience(Room)) of
            true -> Pid ! {hub_json, #{type => call_presence, conversation_id => ConversationId,
                active => true, users => room_users(Room)}};
            false -> ok
        end
    end, Calls).

end_ring(St0, Key, EventType, Reason) ->
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Caller, caller_pid := CPid, caller_profile := Profile,
          targets := Targets, timer := Ref} ->
            cancel_timer(Ref),
            Event = #{type => EventType, conversation_id => element(2, Key), reason => Reason,
                from_user_id => Caller, profile => strip_profile(Profile)},
            CPid ! {hub_json, Event},
            notify_ring_parties(Targets, Event, undefined),
            St0#st{rings = maps:remove(Key, St0#st.rings)};
        undefined ->
            St0
    end.

end_user_rings(St0, Uid, KeepKey) ->
    Keys = [Key || {Key, Ring} <- maps:to_list(St0#st.rings),
        Key =/= KeepKey, maps:get(caller_id, Ring, undefined) =:= Uid],
    lists:foldl(fun(Key, St) -> end_ring(St, Key, call_cancelled, switched_room) end, St0, Keys).

notify_ring_parties(Targets, Event, Skip) ->
    [notify_user(T, Event) || T <- Targets, T =/= Skip],
    ok.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref), ok.

ring_timeout_ms() ->
    min(120000, max(10000, pw_util:env_int("PLAINWIRE_CALL_RING_MS", ?RING_MS))).

persist_missed_call(Uid, Cid) ->
    spawn(fun() ->
        case pw_db:record_missed_call(Uid, Cid) of
            {ok, _} -> ok;
            {error, Reason} ->
                logger:warning("[plainwire:hub] missed_call_not_persisted ~p",
                    [#{uid => Uid, conversation_id => Cid, reason => Reason}])
        end
    end),
    ok.

relay_signal(Room, From, FromPid, To, Event) ->
    case {member_owned(Room, From, FromPid), maps:get(To, Room, undefined)} of
        %% reconnecting members have no pid yet. atoms make poor WebSockets.
        {true, #{pid := TargetPid}} when is_pid(TargetPid) ->
            TargetPid ! {hub_json, Event};
        _ -> ok
    end,
    ok.

member_owned(Room, Uid, Pid) ->
    case maps:get(Uid, Room, undefined) of
        #{pid := Pid} -> true;
        _ -> false
    end.

send_many([], _Event) -> ok;
send_many(Pids, Event) ->
    %% encode once. recipients do not need artisanal JSON.
    Payload = pw_util:json(Event),
    Type = maps:get(type, Event, unknown),
    [Pid ! {hub_text, Payload, Type} || Pid <- Pids, is_pid(Pid)],
    ok.
send_presence_watchers(Watchers, Uid, Event, Skip) ->
    send_many([Pid || Pid <- maps:get(Uid, Watchers, []), Pid =/= Skip], Event).

signal_kind(Signal) when is_map(Signal) -> maps:get(<<"kind">>, Signal, unknown);
signal_kind(_) -> unknown.

log(Event, Data) -> logger:notice("[plainwire:hub] ~s ~p", [Event, Data]).
add_to_set(Key, Pid, Map) -> maps:put(Key, lists:usort([Pid | maps:get(Key, Map, [])]), Map).
remove_from_all(Pid, Map) ->
    maps:fold(fun(Key, List, Acc) ->
        case lists:delete(Pid, List) of
            [] -> Acc;
            Remaining -> maps:put(Key, Remaining, Acc)
        end
    end, #{}, Map).
remove_pids_from_key(Key, Pids, Map) ->
    case maps:get(Key, Map, []) of
        [] -> Map;
        Existing ->
            Remaining = [Pid || Pid <- Existing, not lists:member(Pid, Pids)],
            case Remaining of
                [] -> maps:remove(Key, Map);
                _ -> maps:put(Key, Remaining, Map)
            end
    end.

remove_user_from_room_now(Kind, Id, Uid, Rooms0, Users) ->
    Key = {Kind, Id},
    Room0 = maps:get(Key, Rooms0, #{}),
    case maps:take(Uid, Room0) of
        error -> Rooms0;
        {Info, Room} ->
            cancel_member_reconnect(Info),
            send_many(room_pids(Room), peer_left_event(Kind, Id, Uid)),
            send_many(room_pids(Room), state_event(Kind, Id, Room)),
            case Kind of
                call -> send_call_presence(Id, Room, room_audience(Room0), Users);
                voice -> ok
            end,
            put_or_remove(Key, Room, Rooms0)
    end.
put_or_remove(Key, Room, Map) when map_size(Room) =:= 0 -> maps:remove(Key, Map);
put_or_remove(Key, Room, Map) -> maps:put(Key, Room, Map).
room_users(Room) ->
    [#{user_id => Uid,
       muted => maps:get(muted, Info, false),
       deafened => maps:get(deafened, Info, false),
       screen => maps:get(screen, Info, false),
       screen_audio => maps:get(screen_audio, Info, false),
       reconnecting => maps:get(reconnecting, Info, false),
       profile => strip_profile(maps:get(profile, Info, #{}))}
     || {Uid, Info} <- maps:to_list(Room)].

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
    PidStatuses = maps:remove(Pid, St0#st.pid_statuses),
    Online = case Uid of
        undefined -> St0#st.online;
        _ ->
            Prev = maps:get(Uid, St0#st.online, undefined),
            Effective = effective_status(Uid, Users, PidStatuses),
            update_presence(Uid, Prev, Effective, St0#st.watchers, Pid, St0#st.online)
    end,
    Subs = remove_from_all(Pid, St0#st.subs),
    Voices = detach_pid_from_rooms(Pid, St0#st.voices, voice, Users),
    Calls = detach_pid_from_rooms(Pid, St0#st.calls, call, Users),
    Rings = drop_caller_rings(Pid, St0#st.rings, St0#st.users),
    OldWatches = maps:get(Pid, St0#st.watches, []),
    Watchers = lists:foldl(fun(WatchedUid, Acc) -> update_set(WatchedUid, Pid, Acc) end, St0#st.watchers, OldWatches),
    Watches = maps:remove(Pid, St0#st.watches),
    St0#st{users = Users, pids = Pids, pid_statuses = PidStatuses, online = Online, subs = Subs, voices = Voices, calls = Calls, rings = Rings, watches = Watches, watchers = Watchers}.


first_user_pid(Uid, Users) ->
    case maps:get(Uid, Users, []) of
        [Pid | _] when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

effective_status(Uid, Users, PidStatuses) ->
    Statuses = [normalize_status(maps:get(Pid, PidStatuses, <<"online">>)) || Pid <- maps:get(Uid, Users, [])],
    case Statuses of
        [] -> <<"invisible">>;
        _ ->
            case lists:member(<<"busy">>, Statuses) of
                true -> <<"busy">>;
                false ->
                    case lists:member(<<"online">>, Statuses) of
                        true -> <<"online">>;
                        false ->
                            case lists:member(<<"away">>, Statuses) of
                                true -> <<"away">>;
                                false -> <<"invisible">>
                            end
                    end
            end
    end.

update_presence(Uid, Prev, Effective, Watchers, Skip, Online0) ->
    Visible = visible_status(Effective),
    case {Prev, Visible} of
        {undefined, false} -> Online0;
        {undefined, true} ->
            send_presence_watchers(Watchers, Uid, #{type => presence_online, user_id => Uid, status => Effective}, Skip),
            maps:put(Uid, Effective, Online0);
        {_, false} ->
            send_presence_watchers(Watchers, Uid, #{type => presence_offline, user_id => Uid, status => Effective}, Skip),
            maps:remove(Uid, Online0);
        {Effective, true} ->
            Online0;
        {_, true} ->
            send_presence_watchers(Watchers, Uid, #{type => presence_status, user_id => Uid, status => Effective}, Skip),
            maps:put(Uid, Effective, Online0)
    end.

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

%% refresh gets a short grace window; an explicit leave does not.
detach_pid_from_rooms(Pid, Rooms, Kind, Users) ->
    maps:fold(fun(Key, Room0, Acc) ->
        Audience = room_audience(Room0),
        Gone = [U || {U, Info} <- maps:to_list(Room0), maps:get(pid, Info, undefined) =:= Pid],
        case Gone of
            [] -> maps:put(Key, Room0, Acc);
            [U | _] ->
                IdKey = element(2, Key),
                Room = lists:foldl(fun(GoneUid, R) ->
                    Info0 = maps:get(GoneUid, R),
                    cancel_member_reconnect(Info0),
                    Token = make_ref(),
                    Timer = erlang:send_after(reconnect_grace_ms(), self(),
                        {room_reconnect_expired, Kind, IdKey, GoneUid, Token}),
                    Info = Info0#{pid => undefined, screen => false, screen_audio => false,
                        reconnecting => true, reconnect_token => Token,
                        reconnect_timer => Timer},
                    maps:put(GoneUid, Info, R)
                end, Room0, Gone),
                EventType = case Kind of voice -> voice_peer_left; call -> call_peer_left end,
                IdName = case Kind of voice -> channel_id; call -> conversation_id end,
                Pids = room_pids(Room),
                send_many(Pids, #{type => EventType, IdName => IdKey, user_id => U}),
                send_many(Pids, state_event(Kind, IdKey, Room)),
                case Kind of
                    call -> send_call_presence(IdKey, Room, Audience, Users);
                    voice -> ok
                end,
                maps:put(Key, Room, Acc)
        end
    end, #{}, Rooms).

expire_reconnecting_member(Kind, Id, Uid, Token, St0) ->
    Key = {Kind, Id},
    Rooms0 = rooms(Kind, St0),
    Room0 = maps:get(Key, Rooms0, #{}),
    case maps:get(Uid, Room0, undefined) of
        #{reconnecting := true, reconnect_token := Token} ->
            Audience = room_audience(Room0),
            Room = maps:remove(Uid, Room0),
            send_many(room_pids(Room), state_event(Kind, Id, Room)),
            case Kind of
                call -> send_call_presence(Id, Room, Audience, St0#st.users);
                voice -> ok
            end,
            log("room_reconnect_expired", #{uid => Uid, kind => Kind, id => Id,
                participants => map_size(Room)}),
            set_rooms(Kind, put_or_remove(Key, Room, Rooms0), St0);
        _ ->
            St0
    end.

cancel_member_reconnect(Info) when is_map(Info) ->
    cancel_timer(maps:get(reconnect_timer, Info, undefined));
cancel_member_reconnect(_) -> ok.

reconnect_grace_ms() ->
    min(60000, max(50, pw_util:env_int("PLAINWIRE_RTC_RECONNECT_GRACE_MS", ?RECONNECT_GRACE_MS))).
