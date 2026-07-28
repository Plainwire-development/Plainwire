-module(pw_hub).
-behaviour(gen_server).
-export([
    start_link/0, connect/2, connect/3, disconnect/1, subscribe/2, unsubscribe_all/1, watch_presence/2,
    notify_user/2, broadcast/2, status_update/2,
    voice_join/4, voice_leave/2, voice_state/4, voice_signal/4, voice_activity/4,
    call_ring/5, call_decline/2, call_cancel/2, call_accept/4,
    call_join/4, call_leave/2, call_state/4, call_signal/4,
    room_capacity/0, share_capacity/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(RING_MS, 45000).
-define(JOIN_TIMEOUT, 5000).

%% Audio and screen media are relayed peer to peer in a full mesh, so every
%% additional participant costs each existing participant another encode and
%% upload. These caps keep a room inside what a browser mesh can carry.
room_capacity() -> min(32, max(2, pw_util:env_int("PLAINWIRE_VOICE_MAX_PARTICIPANTS", 8))).
share_capacity() -> min(8, max(1, pw_util:env_int("PLAINWIRE_VOICE_MAX_SHARES", 2))).

-record(st, {users = #{}, pids = #{}, subs = #{}, voices = #{}, calls = #{}, rings = #{}, online = #{}, watches = #{}, watchers = #{}}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
connect(Uid, Pid) -> connect(Uid, Pid, <<"online">>).
connect(Uid, Pid, Status) -> gen_server:cast(?MODULE, {connect, Uid, Pid, Status}).
disconnect(Pid) -> gen_server:cast(?MODULE, {disconnect, Pid}).
subscribe(Pid, Key) -> gen_server:cast(?MODULE, {subscribe, Pid, Key}).
unsubscribe_all(Pid) -> gen_server:cast(?MODULE, {unsubscribe_all, Pid}).
watch_presence(Pid, Uids) -> gen_server:cast(?MODULE, {watch_presence, Pid, Uids}).
notify_user(Uid, Event) -> gen_server:cast(?MODULE, {notify_user, Uid, Event}).
broadcast(Key, Event) -> gen_server:cast(?MODULE, {broadcast, Key, Event}).
status_update(Uid, Status) -> gen_server:cast(?MODULE, {status_update, Uid, Status}).
%% Joining is synchronous because the caller has to know whether the room had
%% room for it before the browser starts capturing and negotiating media.
voice_join(ChannelId, Uid, Pid, Profile) -> join_call({voice_join, ChannelId, Uid, Pid, Profile}).
voice_leave(ChannelId, Uid) -> gen_server:cast(?MODULE, {voice_leave, ChannelId, Uid}).
voice_state(ChannelId, Uid, Patch, Profile) -> gen_server:cast(?MODULE, {voice_state, ChannelId, Uid, Patch, Profile}).
voice_signal(ChannelId, From, To, Signal) -> gen_server:cast(?MODULE, {voice_signal, ChannelId, From, To, Signal}).
voice_activity(Kind, Id, Uid, Active) -> gen_server:cast(?MODULE, {room_activity, Kind, Id, Uid, Active}).
call_ring(Cid, Uid, Pid, Profile, Targets) -> gen_server:cast(?MODULE, {call_ring, Cid, Uid, Pid, Profile, Targets}).
call_decline(Cid, Uid) -> gen_server:cast(?MODULE, {call_decline, Cid, Uid}).
call_cancel(Cid, Uid) -> gen_server:cast(?MODULE, {call_cancel, Cid, Uid}).
call_accept(Cid, Uid, Pid, Profile) -> join_call({call_accept, Cid, Uid, Pid, Profile}).
call_join(ConversationId, Uid, Pid, Profile) -> join_call({call_join, ConversationId, Uid, Pid, Profile}).
call_leave(ConversationId, Uid) -> gen_server:cast(?MODULE, {call_leave, ConversationId, Uid}).
call_state(ConversationId, Uid, Patch, Profile) -> gen_server:cast(?MODULE, {call_state, ConversationId, Uid, Patch, Profile}).
call_signal(ConversationId, From, To, Signal) -> gen_server:cast(?MODULE, {call_signal, ConversationId, From, To, Signal}).

%% A hub that is overloaded or restarting must not wedge the socket process.
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
            {reply, ok, do_voice_join(ChannelId, Uid, Pid, Profile, St0)}
    end;
handle_call({call_join, ConversationId, Uid, Pid, Profile}, _From, St0) ->
    Room = maps:get({call, ConversationId}, St0#st.calls, #{}),
    case room_admits(Room, Uid) of
        false ->
            log("call_join_rejected", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
            {reply, {error, room_full}, St0};
        true ->
            {reply, ok, do_call_join(ConversationId, Uid, Pid, Profile, St0)}
    end;
handle_call({call_accept, Cid, Uid, Pid, Profile}, _From, St0) ->
    Room = maps:get({call, Cid}, St0#st.calls, #{}),
    case room_admits(Room, Uid) of
        false ->
            {reply, {error, room_full}, St0};
        true ->
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
                    {reply, ok, St3};
                _ ->
                    {reply, ok, do_call_join(Cid, Uid, Pid, Profile, St0)}
            end
    end;
handle_call(_, _, St) -> {reply, ok, St}.

%% A user already present is always readmitted so a reconnect or a second tab
%% taking over is never refused by its own occupancy.
room_admits(Room, Uid) ->
    maps:is_key(Uid, Room) orelse map_size(Room) < room_capacity().

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
                    send_presence_watchers(St#st.watchers, Uid, #{type => presence_online, user_id => Uid, status => Status}, Pid),
                    maps:put(Uid, Status, St#st.online);
                false ->
                    St#st.online
            end;
        false ->
            St#st.online
    end,
    Pid ! {hub_json, #{type => presence_state, online => [], statuses => #{}}},
    log("client_connected", #{uid => Uid, sessions => length(maps:get(Uid, Users, [])), online_users => map_size(Online)}),
    {noreply, St#st{users = Users, pids = Pids, online = Online}};
handle_cast({disconnect, Pid}, St) ->
    log("client_disconnected", #{uid => maps:get(Pid, St#st.pids, undefined)}),
    {noreply, remove_pid(Pid, St)};
handle_cast({unsubscribe_all, Pid}, St) -> {noreply, St#st{subs = remove_from_all(Pid, St#st.subs)}};
handle_cast({subscribe, Pid, Key}, St) -> {noreply, St#st{subs = add_to_set(Key, Pid, St#st.subs)}};
handle_cast({watch_presence, Pid, Uids0}, St0) ->
    Requested = [U || U <- Uids0, is_integer(U), U > 0],
    %% Always include the authenticated socket's own account. Older clients
    %% excluded it and therefore rendered themselves offline even though peers
    %% received the correct presence broadcasts.
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
handle_cast({voice_leave, ChannelId, Uid}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    Room = maps:remove(Uid, Room0),
    log("voice_leave", #{uid => Uid, channel_id => ChannelId, participants => map_size(Room)}),
    send_many(room_pids(Room), #{type => voice_peer_left, channel_id => ChannelId, user_id => Uid}),
    Voices = put_or_remove(Key, Room, St0#st.voices),
    {noreply, St0#st{voices = Voices}};
handle_cast({voice_state, ChannelId, Uid, Patch, Profile}, St0) ->
    {noreply, apply_room_state(voice, ChannelId, Uid, Patch, Profile, St0)};
handle_cast({room_activity, Kind, Id, Uid, Active}, St) ->
    Room = maps:get({Kind, Id}, rooms(Kind, St), #{}),
    case maps:is_key(Uid, Room) of
        true -> send_many(room_pids(maps:remove(Uid, Room)), activity_event(Kind, Id, Uid, Active));
        false -> ok
    end,
    {noreply, St};
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
handle_cast({call_leave, ConversationId, Uid}, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    Room = maps:remove(Uid, Room0),
    log("call_leave", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
    send_many(room_pids(Room), #{type => call_peer_left, conversation_id => ConversationId, user_id => Uid}),
    send_many(room_pids(Room), #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
    Calls = put_or_remove(Key, Room, St0#st.calls),
    {noreply, St0#st{calls = Calls}};
handle_cast({call_state, ConversationId, Uid, Patch, Profile}, St0) ->
    {noreply, apply_room_state(call, ConversationId, Uid, Patch, Profile, St0)};
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
            send_presence_watchers(St#st.watchers, Uid, #{type => presence_offline, user_id => Uid, status => Status}, undefined),
            {noreply, St#st{online = maps:remove(Uid, Online0)}};
        {true, false, true} ->
            send_presence_watchers(St#st.watchers, Uid, #{type => presence_online, user_id => Uid, status => Status}, undefined),
            {noreply, St#st{online = maps:put(Uid, Status, Online0)}};
        {true, true, true} ->
            send_presence_watchers(St#st.watchers, Uid, #{type => presence_status, user_id => Uid, status => Status}, undefined),
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

do_call_join(ConversationId, Uid, Pid, Profile, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    notify_superseded(Room0, Uid, Pid, #{type => call_superseded, conversation_id => ConversationId}),
    send_many(room_pids(maps:remove(Uid, Room0)),
        #{type => call_peer_joined, conversation_id => ConversationId, user_id => Uid, profile => strip_profile(Profile)}),
    Room = maps:put(Uid, new_member(Pid, Profile, maps:get(Uid, Room0, #{})), Room0),
    log("call_join", #{uid => Uid, conversation_id => ConversationId, participants => map_size(Room)}),
    send_many(room_pids(Room), #{type => call_state, conversation_id => ConversationId, users => room_users(Room)}),
    St0#st{calls = maps:put(Key, Room, St0#st.calls)}.

%% Only one socket per user occupies a room. When a second tab joins it replaces
%% the first, and the first is told so it can release its microphone instead of
%% holding an orphaned peer connection the room no longer knows about.
notify_superseded(Room, Uid, Pid, Event) ->
    case maps:get(Uid, Room, undefined) of
        #{pid := Old} when is_pid(Old), Old =/= Pid -> Old ! {hub_json, Event}, ok;
        _ -> ok
    end.

new_member(Pid, Profile, Previous) ->
    #{pid => Pid, profile => Profile,
      muted => maps:get(muted, Previous, false),
      deafened => maps:get(deafened, Previous, false),
      screen => false}.

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

apply_room_state(Kind, Id, Uid, Patch, Profile, St0) ->
    Key = {Kind, Id},
    Rooms0 = rooms(Kind, St0),
    Room0 = maps:get(Key, Rooms0, #{}),
    Info0 = maps:get(Uid, Room0, #{pid => undefined, profile => Profile, muted => false, deafened => false, screen => false}),
    Requested = maps:get(screen, Patch, maps:get(screen, Info0, false)),
    {Screen, Denied} = clamp_screen(Room0, Uid, Requested),
    Info = maps:merge(Info0, Patch#{profile => Profile, screen => Screen}),
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

%% Every concurrent screen share multiplies upstream bandwidth for the sharer and
%% decode work for everyone else, so the count is capped per room.
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

send_many([], _Event) -> ok;
send_many(Pids, Event) ->
    %% Encode a broadcast once instead of making every recipient encode the
    %% same message independently (a major reduction for large channels).
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
put_or_remove(Key, Room, Map) when map_size(Room) =:= 0 -> maps:remove(Key, Map);
put_or_remove(Key, Room, Map) -> maps:put(Key, Room, Map).
room_users(Room) ->
    [#{user_id => Uid,
       muted => maps:get(muted, Info, false),
       deafened => maps:get(deafened, Info, false),
       screen => maps:get(screen, Info, false),
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
    Online = case Uid of
        undefined -> St0#st.online;
        _ ->
            case maps:find(Uid, Users) of
                error -> % no longer any PIDs for this user
                    case maps:find(Uid, St0#st.online) of
                        {ok, PrevStatus} ->
                            send_presence_watchers(St0#st.watchers, Uid, #{type => presence_offline, user_id => Uid, status => PrevStatus}, Pid);
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
    OldWatches = maps:get(Pid, St0#st.watches, []),
    Watchers = lists:foldl(fun(WatchedUid, Acc) -> update_set(WatchedUid, Pid, Acc) end, St0#st.watchers, OldWatches),
    Watches = maps:remove(Pid, St0#st.watches),
    St0#st{users = Users, pids = Pids, online = Online, subs = Subs, voices = Voices, calls = Calls, rings = Rings, watches = Watches, watchers = Watchers}.

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
                Pids = room_pids(R),
                send_many(Pids, #{type => EventType, IdName => IdKey, user_id => U}),
                %% Also resend the roster so a client that missed the peer_left
                %% still converges on the correct participant list.
                send_many(Pids, state_event(Kind, IdKey, R)),
                maps:put(Key, R, Acc)
        end
    end, #{}, Rooms).
