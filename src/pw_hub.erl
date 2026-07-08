-module(pw_hub).
-behaviour(gen_server).
-export([
    start_link/0, connect/2, disconnect/1, subscribe/2, unsubscribe_all/1,
    notify_user/2, broadcast/2, voice_join/4, voice_leave/2, voice_state/4, voice_signal/4,
    call_join/4, call_leave/2, call_state/4, call_signal/4
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {users=#{}, pids=#{}, subs=#{}, voices=#{}, calls=#{}}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []). 
connect(Uid, Pid) -> gen_server:cast(?MODULE, {connect, Uid, Pid}).
disconnect(Pid) -> gen_server:cast(?MODULE, {disconnect, Pid}).
subscribe(Pid, Key) -> gen_server:cast(?MODULE, {subscribe, Pid, Key}).
unsubscribe_all(Pid) -> gen_server:cast(?MODULE, {unsubscribe_all, Pid}).
notify_user(Uid, Event) -> gen_server:cast(?MODULE, {notify_user, Uid, Event}).
broadcast(Key, Event) -> gen_server:cast(?MODULE, {broadcast, Key, Event}).
voice_join(ChannelId, Uid, Pid, Profile) -> gen_server:cast(?MODULE, {voice_join, ChannelId, Uid, Pid, Profile}).
voice_leave(ChannelId, Uid) -> gen_server:cast(?MODULE, {voice_leave, ChannelId, Uid}).
voice_state(ChannelId, Uid, Patch, Profile) -> gen_server:cast(?MODULE, {voice_state, ChannelId, Uid, Patch, Profile}).
voice_signal(ChannelId, From, To, Signal) -> gen_server:cast(?MODULE, {voice_signal, ChannelId, From, To, Signal}).
call_join(ConversationId, Uid, Pid, Profile) -> gen_server:cast(?MODULE, {call_join, ConversationId, Uid, Pid, Profile}).
call_leave(ConversationId, Uid) -> gen_server:cast(?MODULE, {call_leave, ConversationId, Uid}).
call_state(ConversationId, Uid, Patch, Profile) -> gen_server:cast(?MODULE, {call_state, ConversationId, Uid, Patch, Profile}).
call_signal(ConversationId, From, To, Signal) -> gen_server:cast(?MODULE, {call_signal, ConversationId, From, To, Signal}).

init([]) -> {ok, #st{}}.

handle_call(_, _, St) -> {reply, ok, St}.

handle_cast({connect, Uid, Pid}, St) ->
    monitor(process, Pid),
    Users = add_to_set(Uid, Pid, St#st.users),
    Pids = maps:put(Pid, Uid, St#st.pids),
    {noreply, St#st{users=Users, pids=Pids}};
handle_cast({disconnect, Pid}, St) -> {noreply, remove_pid(Pid, St)};
handle_cast({unsubscribe_all, Pid}, St) -> {noreply, St#st{subs=remove_from_all(Pid, St#st.subs)}};
handle_cast({subscribe, Pid, Key}, St) -> {noreply, St#st{subs=add_to_set(Key, Pid, St#st.subs)}};
handle_cast({notify_user, Uid, Event}, St) ->
    send_many(maps:get(Uid, St#st.users, []), #{type => notification, event => Event}),
    {noreply, St};
handle_cast({broadcast, Key, Event}, St) ->
    send_many(maps:get(Key, St#st.subs, []), Event),
    {noreply, St};
handle_cast({voice_join, ChannelId, Uid, Pid, Profile}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    send_many([maps:get(pid, V) || {_K,V} <- maps:to_list(Room0)], #{type=>voice_peer_joined, channel_id=>ChannelId, user_id=>Uid, profile=>Profile}),
    Room = maps:put(Uid, #{pid=>Pid, profile=>Profile, muted=>false, deafened=>false}, Room0),
    Pid ! {hub_json, #{type=>voice_state, channel_id=>ChannelId, users=>room_users(Room)}},
    {noreply, St0#st{voices=maps:put(Key, Room, St0#st.voices)}};
handle_cast({voice_leave, ChannelId, Uid}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    Room = maps:remove(Uid, Room0),
    send_many([maps:get(pid, V) || {_K,V} <- maps:to_list(Room)], #{type=>voice_peer_left, channel_id=>ChannelId, user_id=>Uid}),
    Voices = put_or_remove(Key, Room, St0#st.voices),
    {noreply, St0#st{voices=Voices}};
handle_cast({voice_state, ChannelId, Uid, Patch, Profile}, St0) ->
    Key = {voice, ChannelId},
    Room0 = maps:get(Key, St0#st.voices, #{}),
    Info0 = maps:get(Uid, Room0, #{pid=>undefined, profile=>Profile}),
    Info = maps:merge(Info0, Patch#{profile=>Profile}),
    Room = maps:put(Uid, Info, Room0),
    send_many([maps:get(pid, V) || {_K,V} <- maps:to_list(Room)], #{type=>voice_state, channel_id=>ChannelId, users=>room_users(Room)}),
    {noreply, St0#st{voices=maps:put(Key, Room, St0#st.voices)}};
handle_cast({voice_signal, ChannelId, From, To, Signal}, St) ->
    Key = {voice, ChannelId},
    Room = maps:get(Key, St#st.voices, #{}),
    case maps:get(To, Room, undefined) of
        undefined -> ok;
        Info -> maps:get(pid, Info) ! {hub_json, #{type=>voice_signal, channel_id=>ChannelId, from_user_id=>From, signal=>Signal}}
    end,
    {noreply, St};
handle_cast({call_join, ConversationId, Uid, Pid, Profile}, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    send_many([maps:get(pid, V) || {_K,V} <- maps:to_list(Room0)], #{type=>call_peer_joined, conversation_id=>ConversationId, user_id=>Uid, profile=>Profile}),
    Room = maps:put(Uid, #{pid=>Pid, profile=>Profile, muted=>false, deafened=>false}, Room0),
    Pid ! {hub_json, #{type=>call_state, conversation_id=>ConversationId, users=>room_users(Room)}},
    {noreply, St0#st{calls=maps:put(Key, Room, St0#st.calls)}};
handle_cast({call_leave, ConversationId, Uid}, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    Room = maps:remove(Uid, Room0),
    send_many([maps:get(pid, V) || {_K,V} <- maps:to_list(Room)], #{type=>call_peer_left, conversation_id=>ConversationId, user_id=>Uid}),
    Calls = put_or_remove(Key, Room, St0#st.calls),
    {noreply, St0#st{calls=Calls}};
handle_cast({call_state, ConversationId, Uid, Patch, Profile}, St0) ->
    Key = {call, ConversationId},
    Room0 = maps:get(Key, St0#st.calls, #{}),
    Info0 = maps:get(Uid, Room0, #{pid=>undefined, profile=>Profile}),
    Info = maps:merge(Info0, Patch#{profile=>Profile}),
    Room = maps:put(Uid, Info, Room0),
    send_many([maps:get(pid, V) || {_K,V} <- maps:to_list(Room)], #{type=>call_state, conversation_id=>ConversationId, users=>room_users(Room)}),
    {noreply, St0#st{calls=maps:put(Key, Room, St0#st.calls)}};
handle_cast({call_signal, ConversationId, From, To, Signal}, St) ->
    Key = {call, ConversationId},
    Room = maps:get(Key, St#st.calls, #{}),
    case maps:get(To, Room, undefined) of
        undefined -> ok;
        Info -> maps:get(pid, Info) ! {hub_json, #{type=>call_signal, conversation_id=>ConversationId, from_user_id=>From, signal=>Signal}}
    end,
    {noreply, St};
handle_cast(_, St) -> {noreply, St}.

handle_info({'DOWN', _, process, Pid, _}, St) -> {noreply, remove_pid(Pid, St)};
handle_info(_, St) -> {noreply, St}.
terminate(_, _) -> ok.
code_change(_, St, _) -> {ok, St}.

send_many(Pids, Event) -> [Pid ! {hub_json, Event} || Pid <- Pids, is_pid(Pid)], ok.
add_to_set(Key, Pid, Map) -> maps:put(Key, lists:usort([Pid | maps:get(Key, Map, [])]), Map).
remove_from_all(Pid, Map) -> maps:map(fun(_, L) -> lists:delete(Pid, L) end, Map).
put_or_remove(Key, Room, Map) when map_size(Room) =:= 0 -> maps:remove(Key, Map);
put_or_remove(Key, Room, Map) -> maps:put(Key, Room, Map).
room_users(Room) -> [maps:merge(#{user_id=>Uid}, maps:remove(pid, Info)) || {Uid,Info} <- maps:to_list(Room)].

remove_pid(Pid, St0) ->
    Uid = maps:get(Pid, St0#st.pids, undefined),
    Users = case Uid of undefined -> St0#st.users; _ -> update_set(Uid, Pid, St0#st.users) end,
    Pids = maps:remove(Pid, St0#st.pids),
    Subs = remove_from_all(Pid, St0#st.subs),
    Voices = drop_pid_from_rooms(Pid, St0#st.voices, voice),
    Calls = drop_pid_from_rooms(Pid, St0#st.calls, call),
    St0#st{users=Users,pids=Pids,subs=Subs,voices=Voices,calls=Calls}.

update_set(Key, Pid, Map) ->
    L = lists:delete(Pid, maps:get(Key, Map, [])),
    case L of [] -> maps:remove(Key, Map); _ -> maps:put(Key, L, Map) end.

drop_pid_from_rooms(Pid, Rooms, Kind) ->
    maps:fold(fun(Key, Room0, Acc) ->
        Gone = [Uid || {Uid,Info} <- maps:to_list(Room0), maps:get(pid, Info, undefined) =:= Pid],
        Room = lists:foldl(fun(U, R) -> maps:remove(U, R) end, Room0, Gone),
        case {Gone, Room} of
            {[], _} -> maps:put(Key, Room, Acc);
            {_, R} when map_size(R) =:= 0 -> Acc;
            {[U|_], R} ->
                EventType = case Kind of voice -> voice_peer_left; call -> call_peer_left end,
                IdKey = case Key of {_, Id} -> Id end,
                IdName = case Kind of voice -> channel_id; call -> conversation_id end,
                send_many([maps:get(pid, V) || {_K,V} <- maps:to_list(R)], #{type=>EventType, IdName=>IdKey, user_id=>U}),
                maps:put(Key, R, Acc)
        end
    end, #{}, Rooms).
