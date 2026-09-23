-module(pw_hub).
-behaviour(gen_server).
-export([
    start_link/0, connect/2, connect/3, connect/4, disconnect/1, disconnect/2, subscribe/2, unsubscribe_all/1, watch_presence/2,
    revoke_server_access/3, revoke_conversation_access/2,
    notify_user/2, broadcast/2, status_update/2,
    voice_join/4, voice_leave/3, voice_state/5, voice_signal/5, voice_activity/5,
    call_ring/5, call_decline/2, call_cancel/3, call_accept/5,
    call_join/5, call_rejoin/5, call_leave/3, call_state/5, call_signal/5,
    room_capacity/0, share_capacity/0, status_update/3, stats/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-ifdef(TEST).
-export([track_call_session/2, completed_call/2]).
-endif.

-define(RING_MS, 45000).
-define(JOIN_TIMEOUT, 5000).
-define(RECONNECT_GRACE_MS, 15000).
-define(REDIS_PRESENCE_TTL_MS, 45000).
-define(REDIS_PRESENCE_REFRESH_MS, 15000).

%% Capacity is centralized so the call state machine is not coupled to a
%% particular media topology. Plainwire 2.4.0 intentionally remains mesh-only.
room_capacity() -> pw_media_topology:room_capacity().
share_capacity() -> pw_media_topology:share_capacity().

-record(st, {users = #{}, pids = #{}, pid_statuses = #{}, pid_platforms = #{},
             subs = #{}, voices = #{}, calls = #{}, rings = #{}, online = #{}, mac_online = #{}}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
connect(Uid, Pid) -> connect(Uid, Pid, <<"online">>).
connect(Uid, Pid, Status) -> connect(Uid, Pid, Status, undefined).
connect(Uid, Pid, Status, Platform) -> gen_server:cast(?MODULE, {connect, Uid, Pid, Status, Platform}).
disconnect(Pid) -> gen_server:cast(?MODULE, {disconnect, Pid}).
disconnect(Pid, RtcMemberships) when is_list(RtcMemberships) ->
    gen_server:cast(?MODULE, {disconnect, Pid, RtcMemberships});
disconnect(Pid, _) -> disconnect(Pid).
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
voice_signal(ChannelId, From, FromPid, To, Signal) ->
    Event = #{type => voice_signal, channel_id => ChannelId, from_user_id => From, signal => Signal},
    case pw_realtime_registry:relay_signal(voice, ChannelId, From, FromPid, To, Event) of
        unavailable -> gen_server:cast(?MODULE, {voice_signal, ChannelId, From, FromPid, To, Signal});
        _ -> ok
    end.
voice_activity(Kind, Id, Uid, Pid, Active) ->
    Event = activity_event(Kind, Id, Uid, Active),
    case pw_realtime_registry:relay_activity(Kind, Id, Uid, Pid, Event) of
        unavailable -> gen_server:cast(?MODULE, {room_activity, Kind, Id, Uid, Pid, Active});
        _ -> ok
    end.
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
call_signal(ConversationId, From, FromPid, To, Signal) ->
    Event = #{type => call_signal, conversation_id => ConversationId, from_user_id => From, signal => Signal},
    case pw_realtime_registry:relay_signal(call, ConversationId, From, FromPid, To, Event) of
        unavailable -> gen_server:cast(?MODULE, {call_signal, ConversationId, From, FromPid, To, Signal});
        _ -> ok
    end.
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

init([]) ->
    erlang:send_after(?REDIS_PRESENCE_REFRESH_MS, self(), redis_presence_refresh),
    {ok, #st{}}.

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

handle_cast({connect, Uid, Pid, Status0, Platform0}, St) ->
    monitor(process, Pid),
    pw_realtime_registry:register(Uid, Pid),
    pw_realtime_registry:subscribe(Pid, {system, global}),
    Users = add_to_set(Uid, Pid, St#st.users),
    Pids = maps:put(Pid, Uid, St#st.pids),
    Subs = add_to_set({system, global}, Pid, St#st.subs),
    Status = normalize_status(Status0),
    Platform = normalize_platform(Platform0),
    PidStatuses = maps:put(Pid, Status, St#st.pid_statuses),
    PidPlatforms = maps:put(Pid, Platform, St#st.pid_platforms),
    Prev = maps:get(Uid, St#st.online, undefined),
    PrevMac = maps:is_key(Uid, St#st.mac_online),
    Effective = effective_status(Uid, Users, PidStatuses),
    Mac = effective_mac(Uid, Users, PidStatuses, PidPlatforms),
    Online = update_presence(Uid, Prev, Effective, PrevMac, Mac, Pid, St#st.online),
    MacOnline = update_mac_online(Uid, Mac, St#st.mac_online),
    pw_redis:presence_set(Uid, Effective, Mac, ?REDIS_PRESENCE_TTL_MS),
    %% Seed the new socket with the account-wide effective status immediately.
    %% A second tab being idle or invisible must not make an active tab look
    %% offline to itself or to other presence watchers.
    Visible = case visible_status(Effective) of true -> [Uid]; false -> [] end,
    Statuses = case Visible of [] -> #{}; _ -> #{Uid => Effective} end,
    Platforms = case Mac andalso Visible =/= [] of true -> #{Uid => <<"macos">>}; false -> #{} end,
    pw_realtime_delivery:send_event(Pid, #{type => presence_state, online => Visible,
                                          statuses => Statuses, platforms => Platforms}),
    send_active_calls(Pid, Uid, St#st.calls),
    log("client_connected", #{uid => Uid, sessions => length(maps:get(Uid, Users, [])), online_users => map_size(Online)}),
    {noreply, St#st{users = Users, pids = Pids, pid_statuses = PidStatuses,
                    pid_platforms = PidPlatforms, online = Online, mac_online = MacOnline, subs = Subs}};
handle_cast({disconnect, Pid}, St) ->
    log("client_disconnected", #{uid => maps:get(Pid, St#st.pids, undefined)}),
    {noreply, remove_pid(Pid, St, registry)};
handle_cast({disconnect, Pid, RtcMemberships}, St) when is_list(RtcMemberships) ->
    log("client_disconnected", #{uid => maps:get(Pid, St#st.pids, undefined)}),
    {noreply, remove_pid(Pid, St, RtcMemberships)};
handle_cast({unsubscribe_all, Pid}, St) ->
    Keys = pw_realtime_registry:subscriptions(Pid),
    pw_realtime_registry:unsubscribe_all(Pid),
    Subs = case Keys of
        unavailable -> remove_from_all(Pid, St#st.subs);
        _ -> remove_pid_from_keys(Pid, Keys, St#st.subs)
    end,
    {noreply, St#st{subs = Subs}};
handle_cast({subscribe, Pid, Key}, St) ->
    pw_realtime_registry:subscribe(Pid, Key),
    {noreply, St#st{subs = add_to_set(Key, Pid, St#st.subs)}};
handle_cast({revoke_server_access, Uid, ServerId, ChannelIds0}, St0) ->
    ChannelIds = lists:usort([Id || Id <- ChannelIds0, is_integer(Id), Id > 0]),
    Pids = maps:get(Uid, St0#st.users, []),
    Keys = [{server, ServerId} | [{channel, Id} || Id <- ChannelIds]],
    pw_realtime_registry:remove_subscriptions(Pids, Keys),
    Subs = lists:foldl(fun(Key, Acc) -> remove_pids_from_key(Key, Pids, Acc) end, St0#st.subs, Keys),
    Voices = lists:foldl(fun(ChannelId, Acc) -> remove_user_from_room_now(voice, ChannelId, Uid, Acc, St0#st.users) end, St0#st.voices, ChannelIds),
    send_many(Pids, #{type => access_revoked, scope => server, server_id => ServerId, channel_ids => ChannelIds}),
    log("server_access_revoked", #{uid => Uid, server_id => ServerId, tabs => length(Pids), channels => length(ChannelIds)}),
    {noreply, St0#st{subs = Subs, voices = Voices}};
handle_cast({revoke_conversation_access, Uid, ConversationId}, St0) ->
    Pids = maps:get(Uid, St0#st.users, []),
    pw_realtime_registry:remove_subscriptions(Pids, [{direct, ConversationId}]),
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
    _ = pw_realtime_registry:replace_presence_watch(Pid, Uids),
    LocalStatuses = maps:from_list([{U, S} || U <- Uids, {ok, S} <- [maps:find(U, St0#st.online)]]),
    LocalPlatforms = local_mac_platforms(Uids, St0#st.mac_online),
    %% Redis may be remote or briefly slow. Never block the hub control-plane
    %% mailbox on a presence read; a bounded worker fills in cross-node state.
    Tag = {presence_snapshot, Pid, Uids},
    case pw_async_pool:submit(Tag, fun() ->
        {pw_redis:presence_get(Uids), pw_redis:presence_platform_get(Uids)}
    end, self()) of
        ok -> ok;
        {error, _} ->
            pw_realtime_delivery:send_event(Pid, #{type => presence_state,
                online => maps:keys(LocalStatuses), statuses => LocalStatuses,
                platforms => LocalPlatforms})
    end,
    {noreply, St0};
handle_cast(cluster_resync, St) ->
    Pids = maps:keys(St#st.pids),
    send_many(Pids, #{type => realtime_resync}),
    %% A recovered API-node link may have missed a durable access revocation
    %% after the bounded cluster replay window expired. Re-check subscriptions
    %% and media membership against PostgreSQL on each socket. The websocket
    %% process jitters this work so recovery cannot stampede the DB pool.
    lists:foreach(fun(Pid) -> Pid ! cluster_revalidate_access end, Pids),
    {noreply, St};
handle_cast(realtime_registry_ready, St) ->
    _ = pw_realtime_registry:replace_snapshot(St#st.users, St#st.subs, St#st.voices, St#st.calls),
    %% Presence-watch links intentionally live only in the scalable registry.
    %% After a registry restart, ask clients to replay their current watch set.
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
            sync_room(voice, ChannelId, Room),
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
    case pw_util:env_bool_cached("PLAINWIRE_WS_TRACE", false) of
        true -> logger:debug("[plainwire:hub] voice_signal ~p", [#{channel_id => ChannelId, from => From, to => To, kind => signal_kind(Signal)}]);
        false -> ok
    end,
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
            sync_room(call, ConversationId, Room),
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
            PrevMac = maps:is_key(Uid, St#st.mac_online),
            PidStatuses = maps:put(Pid, Status, St#st.pid_statuses),
            Effective = effective_status(Uid, St#st.users, PidStatuses),
            Mac = effective_mac(Uid, St#st.users, PidStatuses, St#st.pid_platforms),
            Online = update_presence(Uid, Prev, Effective, PrevMac, Mac, undefined, St#st.online),
            MacOnline = update_mac_online(Uid, Mac, St#st.mac_online),
            pw_redis:presence_set(Uid, Effective, Mac, ?REDIS_PRESENCE_TTL_MS),
            {noreply, St#st{pid_statuses = PidStatuses, online = Online, mac_online = MacOnline}}
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
    pw_realtime_delivery:send_event(Pid, #{type => call_ringing, conversation_id => Cid, targets => length(Targets1),
        profile => strip_profile(Profile), timeout_ms => RingMs, expires_at => ExpiresAt}),
    [notify_user(T, #{type => call_incoming, conversation_id => Cid, from_user_id => Uid,
        profile => strip_profile(Profile), timeout_ms => RingMs, expires_at => ExpiresAt}) || T <- Targets1],
    St1#st{rings = maps:put(Key, Ring, St1#st.rings)}.

handle_info(redis_presence_refresh, St) ->
    pw_redis:presence_set_many(
        [{Uid, Status, maps:is_key(Uid, St#st.mac_online)} || {Uid, Status} <- maps:to_list(St#st.online)],
        ?REDIS_PRESENCE_TTL_MS),
    erlang:send_after(?REDIS_PRESENCE_REFRESH_MS, self(), redis_presence_refresh),
    {noreply, St};
handle_info({pw_async_result, {presence_snapshot, Pid, Uids}, Remote0}, St) ->
    CurrentWatch = pw_realtime_registry:presence_watches(Pid),
    case CurrentWatch =/= unavailable andalso lists:sort(CurrentWatch) =:= Uids of
        true ->
            {Remote, RemotePlatforms} = case Remote0 of
                {S, P} when is_map(S), is_map(P) -> {S, P};
                _ -> {#{}, #{}}
            end,
            Local = maps:from_list([{U, S} || U <- Uids, {ok, S} <- [maps:find(U, St#st.online)]]),
            Statuses = maps:merge(Remote, Local),
            Platforms = maps:merge(RemotePlatforms, local_mac_platforms(Uids, St#st.mac_online)),
            pw_realtime_delivery:send_event(Pid, #{type => presence_state,
                online => maps:keys(Statuses), statuses => Statuses, platforms => Platforms}),
            {noreply, St};
        false ->
            %% The socket changed its watch set (or disconnected) while the
            %% remote lookup was in flight. Discard the stale snapshot.
            {noreply, St}
    end;
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

handle_info({'DOWN', _, process, Pid, _}, St) -> {noreply, remove_pid(Pid, St, registry)};
handle_info(_, St) -> {noreply, St}.

terminate(_, _) -> ok.
code_change(_, St, _) -> {ok, St}.

do_voice_join(ChannelId, Uid, Pid, Profile, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    notify_superseded(Room0, Uid, Pid, #{type => voice_superseded, channel_id => ChannelId}),
    Room = maps:put(Uid, new_member(Pid, Profile, maps:get(Uid, Room0, #{})), Room0),
    %% Register the seat before anyone is told. An offer that races the
    %% registry lookup is dropped, and that pair stays silent.
    sync_room(voice, ChannelId, Room),
    send_many(room_pids(maps:remove(Uid, Room)),
        #{type => voice_peer_joined, channel_id => ChannelId, user_id => Uid, profile => strip_profile(Profile)}),
    log("voice_join", #{uid => Uid, channel_id => ChannelId, participants => map_size(Room)}),
    send_many(room_pids(Room), #{type => voice_state, channel_id => ChannelId, users => room_users(Room)}),
    St0#st{voices = maps:put(Key, Room, St0#st.voices)}.

do_call_join(ConversationId, Uid, Pid, Profile, Audience0, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    notify_superseded(Room0, Uid, Pid, #{type => call_superseded, conversation_id => ConversationId}),
    Audience = lists:usort([Uid | [U || U <- Audience0, is_integer(U), U > 0]]),
    Joined = maps:put(Uid, new_call_member(Pid, Profile, Audience, maps:get(Uid, Room0, #{})), Room0),
    Room = track_call_session(Room0, Joined),
    sync_room(call, ConversationId, Room),
    send_many(room_pids(maps:remove(Uid, Room)),
        #{type => call_peer_joined, conversation_id => ConversationId, user_id => Uid, profile => strip_profile(Profile)}),
    log("call_join", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
    send_many(room_pids(Room), #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
    send_call_presence(ConversationId, Room, room_audience(Room), St0#st.users),
    St0#st{calls = maps:put(Key, Room, St0#st.calls)}.

%% a second tab takes the seat and tells the first to drop its mic.
notify_superseded(Room, Uid, Pid, Event) ->
    case maps:get(Uid, Room, undefined) of
        #{pid := Old} when is_pid(Old), Old =/= Pid -> pw_realtime_delivery:send_event(Old, Event), ok;
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

%% Session timing is shared by every member, so it survives the starter leaving,
%% reconnects, and device replacement. Ringing and solitary rooms do not count.
track_call_session(Previous, Joined) ->
    Existing = [Session || #{call_session := Session} <- maps:values(Previous)],
    case Existing of
        [Session | _] -> maps:map(fun(_, Info) -> Info#{call_session => Session} end, Joined);
        [] when map_size(Joined) >= 2 ->
            Session = #{started => erlang:monotonic_time(millisecond)},
            maps:map(fun(_, Info) -> Info#{call_session => Session} end, Joined);
        [] -> Joined
    end.

completed_call(Previous, Ended) ->
    case maps:to_list(Previous) of
        [{Uid, #{call_session := #{started := Started}}} | _] -> {Uid, max(0, (Ended - Started) div 1000)};
        _ -> none
    end.

persist_completed_call(Cid, Previous) ->
    case completed_call(Previous, erlang:monotonic_time(millisecond)) of
        {Uid, Seconds} ->
            Job = fun() ->
                case pw_db:record_completed_call(Uid, Cid, Seconds) of
                    {ok, _} -> ok;
                    {error, Reason} -> logger:warning("[plainwire:hub] completed_call_not_persisted ~p", [Reason])
                end
            end,
            case pw_async_pool:submit(Job) of
                ok -> ok;
                {error, Reason} -> logger:warning("[plainwire:hub] completed_call_queue_full ~p", [Reason])
            end;
        _ -> ok
    end.

%% one user, one RTC room. enforce it here too; tabs are sneaky.
evict_other_rooms(Uid, NewPid, KeepKey, St0) ->
    Memberships = pw_realtime_registry:user_rtc_memberships(Uid),
    Voices = evict_from_rooms(Uid, NewPid, KeepKey, St0#st.voices, voice, St0#st.users, Memberships),
    Calls = evict_from_rooms(Uid, NewPid, KeepKey, St0#st.calls, call, St0#st.users, Memberships),
    St0#st{voices = Voices, calls = Calls}.

evict_from_rooms(Uid, NewPid, KeepKey, Rooms, Kind, Users, Memberships) when is_list(Memberships) ->
    Entries = [{Id, OldPid} || {Kind0, Id, OldPid} <- Memberships, Kind0 =:= Kind, {Kind, Id} =/= KeepKey],
    lists:foldl(fun({Id, OldPid}, Acc) ->
        evict_one_room(Uid, NewPid, OldPid, Id, Acc, Kind, Users)
    end, Rooms, Entries);
evict_from_rooms(Uid, NewPid, KeepKey, Rooms, Kind, Users, _) ->
    %% Registry restarts are rare; preserve correctness with the original scan
    %% fallback until the mirrored indexes have been rebuilt.
    maps:fold(fun(Key, Room0, Acc) ->
        case Key =:= KeepKey orelse not maps:is_key(Uid, Room0) of
            true -> Acc;
            false ->
                OldPid = maps:get(pid, maps:get(Uid, Room0), undefined),
                evict_one_room(Uid, NewPid, OldPid, element(2, Key), Acc, Kind, Users)
        end
    end, Rooms, Rooms).

evict_one_room(Uid, NewPid, OldPid, Id, Rooms, Kind, Users) ->
    Key = {Kind, Id},
    case maps:get(Key, Rooms, undefined) of
        Room0 when is_map(Room0) ->
            case maps:is_key(Uid, Room0) of
                false -> Rooms;
                true ->
                    Room = maps:remove(Uid, Room0),
                    sync_room(Kind, Id, Room),
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
                    put_or_remove(Key, Room, Rooms)
            end;
        _ -> Rooms
    end.

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
    sync_room(Kind, Id, Room),
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

notify_pid(Pid, Event) when is_pid(Pid) -> pw_realtime_delivery:send_event(Pid, Event), ok;
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
    case pw_realtime_registry:active_calls(Uid) of
        unavailable ->
            %% Correctness fallback during registry restart.
            maps:foreach(fun({call, ConversationId}, Room) ->
                case lists:member(Uid, room_audience(Room)) of
                    true -> send_active_call(Pid, ConversationId, Room);
                    false -> ok
                end
            end, Calls);
        ConversationIds when is_list(ConversationIds) ->
            lists:foreach(fun(ConversationId) ->
                case maps:get({call, ConversationId}, Calls, undefined) of
                    Room when is_map(Room) -> send_active_call(Pid, ConversationId, Room);
                    _ -> ok
                end
            end, lists:usort(ConversationIds))
    end.

send_active_call(Pid, ConversationId, Room) ->
    pw_realtime_delivery:send_event(Pid, #{type => call_presence, conversation_id => ConversationId,
        active => true, users => room_users(Room)}).

end_ring(St0, Key, EventType, Reason) ->
    case maps:get(Key, St0#st.rings, undefined) of
        #{caller_id := Caller, caller_pid := CPid, caller_profile := Profile,
          targets := Targets, timer := Ref} ->
            cancel_timer(Ref),
            Event = #{type => EventType, conversation_id => element(2, Key), reason => Reason,
                from_user_id => Caller, profile => strip_profile(Profile)},
            pw_realtime_delivery:send_event(CPid, Event),
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
    Job = fun() ->
        case pw_db:record_missed_call(Uid, Cid) of
            {ok, _} -> ok;
            {error, Reason} ->
                logger:warning("[plainwire:hub] missed_call_not_persisted ~p",
                    [#{uid => Uid, conversation_id => Cid, reason => Reason}])
        end
    end,
    case pw_async_pool:submit(Job) of
        ok -> ok;
        {error, Reason} ->
            logger:warning("[plainwire:hub] missed_call_queue_full ~p",
                [#{uid => Uid, conversation_id => Cid, reason => Reason}])
    end,
    ok.

relay_signal(Room, From, FromPid, To, Event) ->
    case {member_owned(Room, From, FromPid), maps:get(To, Room, undefined)} of
        %% reconnecting members have no pid yet. atoms make poor WebSockets.
        {true, #{pid := TargetPid}} when is_pid(TargetPid) ->
            pw_realtime_delivery:send_event(TargetPid, Event);
        _ -> ok
    end,
    ok.

member_owned(Room, Uid, Pid) ->
    case maps:get(Uid, Room, undefined) of
        #{pid := Pid} -> true;
        _ -> false
    end.

send_many([], _Event) -> ok;
send_many(Pids, Event) -> pw_realtime_delivery:send_many(Pids, Event).
send_presence_watchers(Uid, Event, Skip) ->
    case pw_realtime_registry:presence_watchers(Uid) of
        unavailable -> ok;
        Pids when is_list(Pids) -> send_many([Pid || Pid <- Pids, Pid =/= Skip], Event)
    end.

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

remove_pid_from_keys(Pid, Keys, Map) ->
    lists:foldl(fun(Key, Acc) ->
        case maps:get(Key, Acc, []) of
            [] -> Acc;
            Existing ->
                case lists:delete(Pid, Existing) of
                    [] -> maps:remove(Key, Acc);
                    Remaining -> maps:put(Key, Remaining, Acc)
                end
        end
    end, Map, Keys).

sync_room(Kind, Id, Room) ->
    _ = pw_realtime_registry:sync_room(Kind, Id, Room),
    ok.

remove_user_from_room_now(Kind, Id, Uid, Rooms0, Users) ->
    Key = {Kind, Id},
    Room0 = maps:get(Key, Rooms0, #{}),
    case maps:take(Uid, Room0) of
        error -> Rooms0;
        {Info, Room} ->
            cancel_member_reconnect(Info),
            sync_room(Kind, Id, Room),
            send_many(room_pids(Room), peer_left_event(Kind, Id, Uid)),
            send_many(room_pids(Room), state_event(Kind, Id, Room)),
            case Kind of
                call -> send_call_presence(Id, Room, room_audience(Room0), Users);
                voice -> ok
            end,
            put_or_remove(Key, Room, Rooms0)
    end.
put_or_remove({call, Cid} = Key, Room, Map) when map_size(Room) =:= 0 ->
    persist_completed_call(Cid, maps:get(Key, Map, #{})),
    maps:remove(Key, Map);
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

remove_pid(Pid, St0, RtcHint) ->
    SubKeys = pw_realtime_registry:subscriptions(Pid),
    RtcMemberships = case RtcHint of
        registry -> pw_realtime_registry:rtc_memberships(Pid);
        
HintMemberships when is_list(HintMemberships) -> HintMemberships;
        _ -> unavailable
    end,
    pw_realtime_registry:unregister(Pid),
    Uid = maps:get(Pid, St0#st.pids, undefined),
    Users = case Uid of undefined -> St0#st.users; _ -> update_set(Uid, Pid, St0#st.users) end,
    Pids = maps:remove(Pid, St0#st.pids),
    PidStatuses = maps:remove(Pid, St0#st.pid_statuses),
    PidPlatforms = maps:remove(Pid, St0#st.pid_platforms),
    {Online, MacOnline} = case Uid of
        undefined -> {St0#st.online, St0#st.mac_online};
        _ ->
            Prev = maps:get(Uid, St0#st.online, undefined),
            PrevMac = maps:is_key(Uid, St0#st.mac_online),
            Effective = effective_status(Uid, Users, PidStatuses),
            Mac = effective_mac(Uid, Users, PidStatuses, PidPlatforms),
            Updated = update_presence(Uid, Prev, Effective, PrevMac, Mac, Pid, St0#st.online),
            %% Clear only this node's Redis presence slot when its last visible
            %% session disappears; another Plainwire node may still be online.
            pw_redis:presence_set(Uid, Effective, Mac, ?REDIS_PRESENCE_TTL_MS),
            {Updated, update_mac_online(Uid, Mac, St0#st.mac_online)}
    end,
    Subs = case {SubKeys, RtcHint} of
        {unavailable, _} -> remove_from_all(Pid, St0#st.subs);
        %% The registry monitor removes its ETS links before asking the hub to
        %% clean up a hard-killed socket, so an empty exact lookup in that path
        %% means "already removed from the registry", not "had no topics".
        %% Connected sockets always own the system subscription; fall back to
        %% the bounded legacy map scan so a dead PID cannot remain there.
        
{[], KnownMemberships} when is_list(KnownMemberships) -> remove_from_all(Pid, St0#st.subs);
        _ -> remove_pid_from_keys(Pid, SubKeys, St0#st.subs)
    end,
    Voices = detach_pid_from_rooms(Pid, St0#st.voices, voice, Users, RtcMemberships),
    Calls = detach_pid_from_rooms(Pid, St0#st.calls, call, Users, RtcMemberships),
    Rings = drop_caller_rings(Pid, St0#st.rings, St0#st.users),
    St0#st{users = Users, pids = Pids, pid_statuses = PidStatuses,
           pid_platforms = PidPlatforms, online = Online, mac_online = MacOnline,
           subs = Subs, voices = Voices, calls = Calls, rings = Rings}.


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

normalize_platform(<<"macos">>) -> <<"macos">>;
normalize_platform(_) -> undefined.

effective_mac(Uid, Users, PidStatuses, PidPlatforms) ->
    lists:any(fun(Pid) ->
        maps:get(Pid, PidPlatforms, undefined) =:= <<"macos">> andalso
        visible_status(normalize_status(maps:get(Pid, PidStatuses, <<"invisible">>)))
    end, maps:get(Uid, Users, [])).

update_mac_online(Uid, true, MacOnline) -> maps:put(Uid, true, MacOnline);
update_mac_online(Uid, false, MacOnline) -> maps:remove(Uid, MacOnline).

local_mac_platforms(Uids, MacOnline) ->
    maps:from_list([{Uid, <<"macos">>} || Uid <- Uids, maps:is_key(Uid, MacOnline)]).

platform_value(true) -> <<"macos">>;
platform_value(false) -> null.

update_presence(Uid, Prev, Effective, PrevMac, Mac, Skip, Online0) ->
    Visible = visible_status(Effective),
    Platform = platform_value(Mac),
    case {Prev, Visible} of
        {undefined, false} -> Online0;
        {undefined, true} ->
            send_presence_watchers(Uid, #{type => presence_online, user_id => Uid,
                                          status => Effective, client_platform => Platform}, Skip),
            maps:put(Uid, Effective, Online0);
        {_, false} ->
            send_presence_watchers(Uid, #{type => presence_offline, user_id => Uid,
                                          status => Effective, client_platform => null}, Skip),
            maps:remove(Uid, Online0);
        {Effective, true} when PrevMac =:= Mac ->
            Online0;
        {_, true} ->
            send_presence_watchers(Uid, #{type => presence_status, user_id => Uid,
                                          status => Effective, client_platform => Platform}, Skip),
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

%% refresh gets a short grace window; an explicit leave does not.  The hot
%% disconnect path uses the registry's reverse RTC index, so a reconnect storm
%% touches only rooms owned by this socket rather than folding every live room.
detach_pid_from_rooms(Pid, Rooms, Kind, Users, unavailable) ->
    detach_pid_from_rooms_scan(Pid, Rooms, Kind, Users);
detach_pid_from_rooms(Pid, Rooms, Kind, Users, Memberships) when is_list(Memberships) ->
    Entries = [{Id, Uid} || {Kind0, Id, Uid} <- Memberships, Kind0 =:= Kind],
    lists:foldl(fun({Id, Uid}, Acc) -> detach_one_room(Pid, Acc, Kind, Id, Uid, Users) end, Rooms, Entries);
detach_pid_from_rooms(Pid, Rooms, Kind, Users, _) ->
    detach_pid_from_rooms_scan(Pid, Rooms, Kind, Users).

detach_pid_from_rooms_scan(Pid, Rooms, Kind, Users) ->
    maps:fold(fun({Kind0, Id}, Room0, Acc) when Kind0 =:= Kind ->
        Gone = [U || {U, Info} <- maps:to_list(Room0), maps:get(pid, Info, undefined) =:= Pid],
        lists:foldl(fun(Uid, Acc0) -> detach_one_room(Pid, Acc0, Kind, Id, Uid, Users) end, Acc, Gone);
       (_Key, _Room0, Acc) -> Acc
    end, Rooms, Rooms).

detach_one_room(Pid, Rooms, Kind, Id, Uid, Users) ->
    Key = {Kind, Id},
    case maps:get(Key, Rooms, undefined) of
        Room0 when is_map(Room0) ->
            case maps:get(Uid, Room0, undefined) of
                Info0 when is_map(Info0) ->
                    case maps:get(pid, Info0, undefined) =:= Pid of
                        false -> Rooms;
                        true ->
                            Audience = room_audience(Room0),
                            cancel_member_reconnect(Info0),
                            Token = make_ref(),
                            Timer = erlang:send_after(reconnect_grace_ms(), self(),
                                {room_reconnect_expired, Kind, Id, Uid, Token}),
                            Info = Info0#{pid => undefined, screen => false, screen_audio => false,
                                reconnecting => true, reconnect_token => Token, reconnect_timer => Timer},
                            Room = maps:put(Uid, Info, Room0),
                            sync_room(Kind, Id, Room),
                            EventType = case Kind of voice -> voice_peer_left; call -> call_peer_left end,
                            IdName = case Kind of voice -> channel_id; call -> conversation_id end,
                            Pids = room_pids(Room),
                            send_many(Pids, #{type => EventType, IdName => Id, user_id => Uid}),
                            send_many(Pids, state_event(Kind, Id, Room)),
                            case Kind of
                                call -> send_call_presence(Id, Room, Audience, Users);
                                voice -> ok
                            end,
                            maps:put(Key, Room, Rooms)
                    end;
                _ -> Rooms
            end;
        _ -> Rooms
    end.

expire_reconnecting_member(Kind, Id, Uid, Token, St0) ->
    Key = {Kind, Id},
    Rooms0 = rooms(Kind, St0),
    Room0 = maps:get(Key, Rooms0, #{}),
    case maps:get(Uid, Room0, undefined) of
        #{reconnecting := true, reconnect_token := Token} ->
            Audience = room_audience(Room0),
            Room = maps:remove(Uid, Room0),
            sync_room(Kind, Id, Room),
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
