-module(pw_realtime_registry).
-behaviour(gen_server).

-export([
    start_link/0,
    register/2, unregister/1,
    subscribe/2, unsubscribe_all/1, remove_subscriptions/2,
    subscriptions/1, user_pids/1, topic_pids/1, all_pids/0,
    replace_presence_watch/2, presence_watches/1, presence_watchers/1,
    sync_room/3, rtc_memberships/1, user_rtc_memberships/1, active_calls/1, relay_signal/6, relay_activity/5,
    send_user/2, broadcast/2, send_many/2,
    reserve_delivery/1, ack_delivery/1, delivery_pending/1,
    replace_snapshot/4, stats/0, count/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(USER_TAB, pw_rt_users).
-define(PID_TAB, pw_rt_pids).
-define(SUB_TAB, pw_rt_subscriptions).
-define(PID_SUB_TAB, pw_rt_pid_subscriptions).
-define(RTC_TAB, pw_rt_room_members).
-define(RTC_ROOM_TAB, pw_rt_room_index).
-define(RTC_PID_TAB, pw_rt_pid_rooms).
-define(RTC_USER_TAB, pw_rt_user_rooms).
-define(CALL_AUDIENCE_TAB, pw_rt_call_audience).
-define(CALL_USER_TAB, pw_rt_user_calls).
-define(PRESENCE_WATCH_TAB, pw_rt_presence_watchers).
-define(PID_PRESENCE_TAB, pw_rt_pid_presence).
-define(COUNTER_TAB, pw_rt_counters).
-define(DELIVERY_TAB, pw_rt_delivery_pending).
-define(MONITOR_TAB, pw_rt_monitors).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Uid, Pid) when is_integer(Uid), Uid > 0, is_pid(Pid) ->
    safe(fun() ->
        case ets:insert_new(?PID_TAB, {Pid, Uid}) of
            true ->
                ets:insert(?DELIVERY_TAB, {Pid, 0}),
                ets:insert(?USER_TAB, {Uid, Pid}),
                count(websocket_connections, 1);
            false -> ok
        end,
        gen_server:cast(?MODULE, {monitor_pid, Pid}),
        ok
    end, unavailable);
register(_, _) -> ignored.

unregister(Pid) when is_pid(Pid) ->
    safe(fun() ->
        unregister_ets(Pid),
        gen_server:cast(?MODULE, {unmonitor_pid, Pid}),
        ok
    end, unavailable);
unregister(_) -> ignored.

subscribe(Pid, Key) when is_pid(Pid) ->
    safe(fun() ->
        ets:insert(?SUB_TAB, {Key, Pid}),
        ets:insert(?PID_SUB_TAB, {Pid, Key}),
        ok
    end, unavailable);
subscribe(_, _) -> ignored.

unsubscribe_all(Pid) when is_pid(Pid) -> safe(fun() -> unsubscribe_all_ets(Pid) end, unavailable);
unsubscribe_all(_) -> ignored.

remove_subscriptions(Pids, Keys) when is_list(Pids), is_list(Keys) ->
    safe(fun() ->
        lists:foreach(fun(Pid) ->
            lists:foreach(fun(Key) ->
                ets:delete_object(?SUB_TAB, {Key, Pid}),
                ets:delete_object(?PID_SUB_TAB, {Pid, Key})
            end, Keys)
        end, Pids),
        ok
    end, unavailable).

subscriptions(Pid) when is_pid(Pid) ->
    safe(fun() -> [Key || {Pid0, Key} <- ets:lookup(?PID_SUB_TAB, Pid), Pid0 =:= Pid] end, unavailable);
subscriptions(_) -> [].

user_pids(Uid) ->
    safe(fun() -> [Pid || {Uid0, Pid} <- ets:lookup(?USER_TAB, Uid), Uid0 =:= Uid] end, unavailable).

topic_pids(Key) ->
    safe(fun() -> [Pid || {Key0, Pid} <- ets:lookup(?SUB_TAB, Key), Key0 =:= Key] end, unavailable).

all_pids() -> safe(fun() -> [Pid || {Pid, _Uid} <- ets:tab2list(?PID_TAB)] end, []).

replace_presence_watch(Pid, Uids0) when is_pid(Pid), is_list(Uids0) ->
    safe(fun() ->
        %% Bound cardinality at the registry trust boundary as well as at the
        %% WebSocket parser. Future transports/internal callers cannot create an
        %% unbounded number of reverse-index rows for a single connection.
        Limit = presence_watch_limit(),
        Uids = lists:sublist(lists:usort([Uid || Uid <- Uids0, is_integer(Uid), Uid > 0]), Limit),
        clear_presence_watch_ets(Pid),
        lists:foreach(fun(Uid) ->
            ets:insert(?PRESENCE_WATCH_TAB, {Uid, Pid}),
            ets:insert(?PID_PRESENCE_TAB, {Pid, Uid})
        end, Uids),
        ok
    end, unavailable);
replace_presence_watch(_, _) -> ignored.

presence_watches(Pid) when is_pid(Pid) ->
    safe(fun() -> [Uid || {Pid0, Uid} <- ets:lookup(?PID_PRESENCE_TAB, Pid), Pid0 =:= Pid] end, unavailable);
presence_watches(_) -> [].

presence_watchers(Uid) when is_integer(Uid), Uid > 0 ->
    safe(fun() -> [Pid || {Uid0, Pid} <- ets:lookup(?PRESENCE_WATCH_TAB, Uid), Uid0 =:= Uid] end, unavailable);
presence_watchers(_) -> [].

%% Room maps remain authoritative in pw_hub. This compact index mirrors only
%% live socket ownership so high-frequency WebRTC signaling never has to queue
%% behind unrelated hub work.
sync_room(Kind, Id, Room) when (Kind =:= voice orelse Kind =:= call), is_integer(Id), is_map(Room) ->
    safe(fun() ->
        %% Remove the previous room membership by exact room-key lookup. Avoid
        %% ets:match_delete/2 here: disconnect/reconnect storms must not scan
        %% every active RTC participant on the instance.
        Old = ets:lookup(?RTC_ROOM_TAB, {Kind, Id}),
        lists:foreach(fun({{Kind0, Id0}, Uid0, Pid0}) ->
            ets:delete(?RTC_TAB, {Kind0, Id0, Uid0}),
            case is_pid(Pid0) of
                true -> ets:delete_object(?RTC_PID_TAB, {Pid0, {Kind0, Id0, Uid0}});
                false -> ok
            end,
            ets:delete_object(?RTC_USER_TAB, {Uid0, {Kind0, Id0, Pid0}})
        end, Old),
        ets:delete(?RTC_ROOM_TAB, {Kind, Id}),
        maps:foreach(fun(Uid, Info) ->
            Pid = maps:get(pid, Info, undefined),
            %% Room/user reverse indexes include reconnecting members (pid =
            %% undefined); the live-member table remains pid-only for signaling.
            ets:insert(?RTC_ROOM_TAB, {{Kind, Id}, Uid, Pid}),
            ets:insert(?RTC_USER_TAB, {Uid, {Kind, Id, Pid}}),
            case is_pid(Pid) of
                true ->
                    ets:insert(?RTC_TAB, {{Kind, Id, Uid}, Pid}),
                    ets:insert(?RTC_PID_TAB, {Pid, {Kind, Id, Uid}});
                false -> ok
            end
        end, Room),
        sync_call_audience(Kind, Id, Room),
        ok
    end, unavailable);
sync_room(_, _, _) -> ignored.

rtc_memberships(Pid) when is_pid(Pid) ->
    safe(fun() -> [Entry || {Pid0, Entry} <- ets:lookup(?RTC_PID_TAB, Pid), Pid0 =:= Pid] end, unavailable);
rtc_memberships(_) -> [].

user_rtc_memberships(Uid) when is_integer(Uid), Uid > 0 ->
    safe(fun() -> [Entry || {Uid0, Entry} <- ets:lookup(?RTC_USER_TAB, Uid), Uid0 =:= Uid] end, unavailable);
user_rtc_memberships(_) -> [].

active_calls(Uid) when is_integer(Uid), Uid > 0 ->
    safe(fun() -> [Cid || {Uid0, Cid} <- ets:lookup(?CALL_USER_TAB, Uid), Uid0 =:= Uid] end, unavailable);
active_calls(_) -> [].

sync_call_audience(call, Id, Room) ->
    Old = ets:lookup(?CALL_AUDIENCE_TAB, Id),
    lists:foreach(fun({Id0, Uid}) -> ets:delete_object(?CALL_USER_TAB, {Uid, Id0}) end, Old),
    ets:delete(?CALL_AUDIENCE_TAB, Id),
    Audience = lists:usort(lists:flatten([
        [Uid | maps:get(audience, Info, [])] || {Uid, Info} <- maps:to_list(Room)
    ])),
    lists:foreach(fun(Uid) when is_integer(Uid), Uid > 0 ->
        ets:insert(?CALL_AUDIENCE_TAB, {Id, Uid}),
        ets:insert(?CALL_USER_TAB, {Uid, Id});
       (_) -> ok
    end, Audience),
    ok;
sync_call_audience(_, _, _) -> ok.

relay_signal(Kind, Id, From, FromPid, To, Event)
  when (Kind =:= voice orelse Kind =:= call), is_pid(FromPid), is_integer(From), is_integer(To) ->
    safe(fun() ->
        case {ets:lookup(?RTC_TAB, {Kind, Id, From}), ets:lookup(?RTC_TAB, {Kind, Id, To})} of
            {[{{Kind, Id, From}, FromPid}], [{{Kind, Id, To}, TargetPid}]} when is_pid(TargetPid) ->
                pw_realtime_delivery:send_event(TargetPid, Event),
                sent;
            _ -> rejected
        end
    end, unavailable);
relay_signal(_, _, _, _, _, _) -> rejected.

relay_activity(Kind, Id, Uid, Pid, Event)
  when (Kind =:= voice orelse Kind =:= call), is_pid(Pid), is_integer(Uid) ->
    safe(fun() ->
        case ets:lookup(?RTC_TAB, {Kind, Id, Uid}) of
            [{{Kind, Id, Uid}, Pid}] ->
                %% Exact-key lookup on the room index is O(room size), not O(all
                %% active RTC members). Voice activity is intentionally a hot path.
                Pids = [OtherPid || {{Kind0, Id0}, OtherUid, OtherPid} <- ets:lookup(?RTC_ROOM_TAB, {Kind, Id}),
                                   Kind0 =:= Kind, Id0 =:= Id, OtherUid =/= Uid, is_pid(OtherPid)],
                pw_realtime_delivery:send_many(Pids, Event),
                sent;
            _ -> rejected
        end
    end, unavailable);
relay_activity(_, _, _, _, _) -> rejected.

send_user(Uid, Event) ->
    case user_pids(Uid) of
        unavailable -> unavailable;
        Pids -> pw_realtime_delivery:send_user(Pids, Event)
    end.
broadcast(Key, Event) ->
    case topic_pids(Key) of
        unavailable -> unavailable;
        Pids -> pw_realtime_delivery:send_many(Pids, Event)
    end.
send_many(Pids, Event) -> pw_realtime_delivery:send_many(Pids, Event).

%% Realtime backpressure uses an explicit outstanding-delivery counter instead
%% of process_info/2 on every fanout recipient. Each hub_text reservation is
%% acknowledged by the WebSocket callback when it begins processing the frame.
reserve_delivery(Pid) when is_pid(Pid) ->
    safe(fun() ->
        case ets:lookup(?DELIVERY_TAB, Pid) of
            [{Pid, _}] -> ets:update_counter(?DELIVERY_TAB, Pid, {2, 1});
            [] -> gone
        end
    end, unavailable);
reserve_delivery(_) -> gone.

ack_delivery(Pid) when is_pid(Pid) ->
    safe(fun() -> ets:update_counter(?DELIVERY_TAB, Pid, {2, -1, 0, 0}) end, gone);
ack_delivery(_) -> gone.

delivery_pending(Pid) when is_pid(Pid) ->
    safe(fun() -> case ets:lookup(?DELIVERY_TAB, Pid) of [{Pid, N}] -> N; [] -> 0 end end, 0);
delivery_pending(_) -> 0.

replace_snapshot(Users, Subs, Voices, Calls)
  when is_map(Users), is_map(Subs), is_map(Voices), is_map(Calls) ->
    try gen_server:call(?MODULE, {replace_snapshot, Users, Subs, Voices, Calls}, 2000)
    catch exit:_ -> {error, unavailable} end.

stats() ->
    safe(fun() ->
        #{available => true,
          websocket_connections => counter(websocket_connections),
          user_links => ets:info(?USER_TAB, size),
          subscription_links => ets:info(?SUB_TAB, size),
          presence_watch_links => ets:info(?PRESENCE_WATCH_TAB, size),
          rtc_members => ets:info(?RTC_TAB, size),
          rtc_pid_links => ets:info(?RTC_PID_TAB, size),
          delivered => counter(delivered),
          dropped_ephemeral => counter(dropped_ephemeral),
          slow_consumers_evicted => counter(slow_consumers_evicted)}
    end, #{available => false}).

count(_Key, N) when not is_integer(N); N =:= 0 -> ok;
count(Key, N) ->
    safe(fun() -> ets:update_counter(?COUNTER_TAB, Key, {2, N}, {Key, 0}), ok end, ok).

init([]) ->
    process_flag(message_queue_data, off_heap),
    ets:new(?USER_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?PID_TAB, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?SUB_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?PID_SUB_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?RTC_TAB, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?RTC_ROOM_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?RTC_PID_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?RTC_USER_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?CALL_AUDIENCE_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?CALL_USER_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?PRESENCE_WATCH_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?PID_PRESENCE_TAB, [named_table, public, bag, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?COUNTER_TAB, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?DELIVERY_TAB, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    ets:new(?MONITOR_TAB, [named_table, protected, set, {read_concurrency, true}, {write_concurrency, auto}]),
    ets:insert(?COUNTER_TAB, {websocket_connections, 0}),
    case whereis(pw_hub) of
        Pid when is_pid(Pid) -> gen_server:cast(pw_hub, realtime_registry_ready);
        _ -> ok
    end,
    {ok, #{}}.

handle_call({replace_snapshot, Users, Subs, Voices, Calls}, _From, State) ->
    clear_indexes(),
    maps:foreach(fun(Uid, Pids) ->
        lists:foreach(fun(Pid) ->
            ets:insert(?DELIVERY_TAB, {Pid, 0}),
            ets:insert(?USER_TAB, {Uid, Pid}),
            ets:insert(?PID_TAB, {Pid, Uid})
        end, Pids)
    end, Users),
    maps:foreach(fun(Key, Pids) ->
        lists:foreach(fun(Pid) ->
            ets:insert(?SUB_TAB, {Key, Pid}),
            ets:insert(?PID_SUB_TAB, {Pid, Key})
        end, Pids)
    end, Subs),
    maps:foreach(fun({voice, Id}, Room) -> sync_room(voice, Id, Room) end, Voices),
    maps:foreach(fun({call, Id}, Room) -> sync_room(call, Id, Room) end, Calls),
    ets:insert(?COUNTER_TAB, {websocket_connections, ets:info(?PID_TAB, size)}),
    %% Rebuild process monitors in one control-plane message instead of queuing
    %% one gen_server cast per live socket after a registry restart.
    self() ! rebuild_monitors,
    {reply, ok, State};
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

handle_cast({monitor_pid, Pid}, State) ->
    ensure_monitor(Pid),
    {noreply, State};
handle_cast({unmonitor_pid, Pid}, State) ->
    unmonitor_pid(Pid),
    {noreply, State};
handle_cast(_, State) -> {noreply, State}.
handle_info(rebuild_monitors, State) ->
    rebuild_monitors(),
    {noreply, State};
handle_info({'DOWN', Ref, process, Pid, _Reason}, State) ->
    case ets:lookup(?MONITOR_TAB, Pid) of
        [{Pid, Ref}] ->
            %% Capture exact RTC ownership before removing reverse indexes. A
            %% hard-killed socket may never execute cowboy_websocket:terminate/3;
            %% handing the snapshot to the hub prevents stale/reconnecting rooms
            %% without an O(all rooms) recovery scan.
            Memberships = [Entry || {Pid0, Entry} <- ets:lookup(?RTC_PID_TAB, Pid), Pid0 =:= Pid],
            ets:delete(?MONITOR_TAB, Pid),
            unregister_ets(Pid),
            gen_server:cast(pw_hub, {disconnect, Pid, Memberships}),
            {noreply, State};
        _ -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

clear_indexes() ->
    [erlang:demonitor(Ref, [flush]) || {_Pid, Ref} <- ets:tab2list(?MONITOR_TAB)],
    ets:delete_all_objects(?MONITOR_TAB),
    [ets:delete_all_objects(Tab) || Tab <- [?USER_TAB, ?PID_TAB, ?SUB_TAB, ?PID_SUB_TAB, ?RTC_TAB, ?RTC_ROOM_TAB, ?RTC_PID_TAB, ?RTC_USER_TAB, ?CALL_AUDIENCE_TAB, ?CALL_USER_TAB, ?PRESENCE_WATCH_TAB, ?PID_PRESENCE_TAB, ?DELIVERY_TAB]],
    ets:insert(?COUNTER_TAB, {websocket_connections, 0}),
    ok.

ensure_monitor(Pid) ->
    case ets:lookup(?MONITOR_TAB, Pid) of
        [_] -> ok;
        [] ->
            case is_process_alive(Pid) of
                false ->
                    %% A socket can die between register/2 and this cast. Preserve
                    %% its RTC ownership before deleting the reverse indexes and
                    %% notify the hub exactly as a DOWN message would.
                    Memberships = [Entry || {Pid0, Entry} <- ets:lookup(?RTC_PID_TAB, Pid), Pid0 =:= Pid],
                    unregister_ets(Pid),
                    gen_server:cast(pw_hub, {disconnect, Pid, Memberships});
                true ->
                    Ref = erlang:monitor(process, Pid),
                    case ets:insert_new(?MONITOR_TAB, {Pid, Ref}) of
                        true -> ok;
                        false -> erlang:demonitor(Ref, [flush]), ok
                    end
            end
    end.

unmonitor_pid(Pid) ->
    case ets:take(?MONITOR_TAB, Pid) of
        [{Pid, Ref}] -> erlang:demonitor(Ref, [flush]), ok;
        [] -> ok
    end.

rebuild_monitors() ->
    LivePids = [Pid || {Pid, _Uid} <- ets:tab2list(?PID_TAB)],
    lists:foreach(fun ensure_monitor/1, LivePids),
    ok.

unsubscribe_all_ets(Pid) ->
    Keys = [Key || {Pid0, Key} <- ets:lookup(?PID_SUB_TAB, Pid), Pid0 =:= Pid],
    lists:foreach(fun(Key) -> ets:delete_object(?SUB_TAB, {Key, Pid}) end, Keys),
    ets:delete(?PID_SUB_TAB, Pid),
    ok.

unregister_ets(Pid) ->
    case ets:take(?PID_TAB, Pid) of
        [{Pid, Uid}] ->
            ets:delete_object(?USER_TAB, {Uid, Pid}),
            count(websocket_connections, -1);
        [] -> ok
    end,
    ets:delete(?DELIVERY_TAB, Pid),
    unsubscribe_all_ets(Pid),
    clear_presence_watch_ets(Pid),
    %% Exact reverse lookup keeps reconnect storms O(rooms-for-this-socket),
    %% rather than O(all active RTC members).
    Memberships = [Entry || {Pid0, Entry} <- ets:lookup(?RTC_PID_TAB, Pid), Pid0 =:= Pid],
    lists:foreach(fun({Kind, Id, Uid}) ->
        ets:delete(?RTC_TAB, {Kind, Id, Uid}),
        ets:delete_object(?RTC_ROOM_TAB, {{Kind, Id}, Uid, Pid}),
        ets:delete_object(?RTC_USER_TAB, {Uid, {Kind, Id, Pid}})
    end, Memberships),
    ets:delete(?RTC_PID_TAB, Pid),
    ok.

clear_presence_watch_ets(Pid) ->
    Uids = [Uid || {Pid0, Uid} <- ets:lookup(?PID_PRESENCE_TAB, Pid), Pid0 =:= Pid],
    lists:foreach(fun(Uid) -> ets:delete_object(?PRESENCE_WATCH_TAB, {Uid, Pid}) end, Uids),
    ets:delete(?PID_PRESENCE_TAB, Pid),
    ok.

presence_watch_limit() ->
    min(10000, max(100, pw_util:env_int_cached("PLAINWIRE_PRESENCE_WATCH_MAX", 2000))).

counter(Key) ->
    case ets:lookup(?COUNTER_TAB, Key) of [{Key, N}] -> N; _ -> 0 end.

safe(Fun, Fallback) ->
    try Fun() catch error:badarg -> Fallback; exit:_ -> Fallback end.
