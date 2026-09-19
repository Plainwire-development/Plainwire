-module(pw_load_sim).
-export([run/3]).

%% In-process realtime stress harness. It deliberately avoids PostgreSQL and
%% network setup so `make load` can drive the exact fanout/backpressure/RTC
%% machinery with tens of thousands of fake socket processes on a developer
%% machine. End-to-end HTTP/browser tests remain separate release gates.
run(Users, DurationSec, RequestedRate)
  when is_integer(Users), Users >= 10,
       is_integer(DurationSec), DurationSec >= 1,
       is_integer(RequestedRate), RequestedRate >= 0 ->
    process_flag(trap_exit, true),
    {ok, RegistryPid, OwnRegistry} = ensure_registry(),
    Rate = case RequestedRate of 0 -> max(1000, Users * 4); _ -> RequestedRate end,
    Schedulers = erlang:system_info(schedulers_online),
    Workers = min(64, max(2, Schedulers * 2)),
    SlowEvery = case Users >= 500 of true -> 100; false -> 0 end,
    BeforeMemory = erlang:memory(total),
    BeforeStats = pw_realtime_registry:stats(),
    io:format("Plainwire synthetic load: users=~p duration=~ps target_ops_per_sec=~p workers=~p~n",
              [Users, DurationSec, Rate, Workers]),
    Pids = spawn_clients(Users, SlowEvery),
    PidTuple = list_to_tuple(Pids),
    setup_realtime(Users, PidTuple),
    StartedAt = erlang:monotonic_time(millisecond),
    Deadline = StartedAt + DurationSec * 1000,
    Parent = self(),
    [spawn(fun() -> traffic_worker(Parent, Worker, Workers, Users, PidTuple, Rate, Deadline) end)
        || Worker <- lists:seq(1, Workers)],
    Operations = await_workers(Workers, 0, DurationSec * 1000 + 30000),
    timer:sleep(250),
    FinishedAt = erlang:monotonic_time(millisecond),
    AfterStats = pw_realtime_registry:stats(),
    AfterMemory = erlang:memory(total),
    QueueStats = queue_stats(Pids),
    ElapsedMs = max(1, FinishedAt - StartedAt),
    OpsPerSec = round(Operations * 1000 / ElapsedMs),
    Delivered = delta(delivered, BeforeStats, AfterStats),
    Dropped = delta(dropped_ephemeral, BeforeStats, AfterStats),
    Evicted = delta(slow_consumers_evicted, BeforeStats, AfterStats),
    Result = #{users => Users, duration_ms => ElapsedMs, operations => Operations,
               operations_per_sec => OpsPerSec, delivered_messages => Delivered,
               dropped_ephemeral => Dropped, slow_consumers_evicted => Evicted,
               live_clients => maps:get(live, QueueStats),
               p50_mailbox => maps:get(p50, QueueStats),
               p95_mailbox => maps:get(p95, QueueStats),
               p99_mailbox => maps:get(p99, QueueStats),
               max_mailbox => maps:get(max, QueueStats),
               max_delivery_pending => maps:get(max_pending, QueueStats),
               memory_delta_bytes => AfterMemory - BeforeMemory,
               registry => AfterStats},
    io:format("~n=== Plainwire load result ===~n~p~n", [Result]),
    cleanup(Pids, RegistryPid, OwnRegistry),
    case validate(Result) of
        ok ->
            io:format("PASS: realtime fanout stayed bounded under synthetic load.~n"),
            {ok, Result};
        {error, Reasons} ->
            io:format("FAIL: ~p~n", [Reasons]),
            {error, Result#{failures => Reasons}}
    end;
run(_, _, _) -> {error, invalid_load_parameters}.

ensure_registry() ->
    case whereis(pw_realtime_registry) of
        Pid when is_pid(Pid) -> {ok, Pid, false};
        _ ->
            case pw_realtime_registry:start_link() of
                {ok, Pid} -> {ok, Pid, true};
                Other -> Other
            end
    end.

spawn_clients(Users, SlowEvery) ->
    [spawn(fun() -> client_loop(client_delay(Uid, SlowEvery), 0) end)
        || Uid <- lists:seq(1, Users)].

client_delay(_Uid, 0) -> 0;
client_delay(Uid, Every) ->
    case Uid rem Every of 0 -> 40; _ -> 0 end.

client_loop(DelayMs, Received) ->
    receive
        {hub_text, _Payload, _Type} ->
            _ = pw_realtime_registry:ack_delivery(self()),
            case DelayMs of 0 -> ok; _ -> timer:sleep(DelayMs) end,
            client_loop(DelayMs, Received + 1);
        {load_report, From, Ref} ->
            From ! {load_report, Ref, Received},
            client_loop(DelayMs, Received);
        stop -> ok;
        _ -> client_loop(DelayMs, Received)
    end.

setup_realtime(Users, PidTuple) ->
    ChannelCount = max(1, (Users + 49) div 50),
    ServerCount = max(1, (Users + 499) div 500),
    lists:foreach(fun(Uid) ->
        Pid = element(Uid, PidTuple),
        pw_realtime_registry:register(Uid, Pid),
        pw_realtime_registry:subscribe(Pid, {system, global}),
        pw_realtime_registry:subscribe(Pid, {channel, 1 + ((Uid - 1) rem ChannelCount)}),
        pw_realtime_registry:subscribe(Pid, {server, 1 + ((Uid - 1) rem ServerCount)}),
        %% Presence watchers are a high-cardinality relationship in real chat
        %% clients. Keep a bounded neighborhood per synthetic user so the load
        %% grows linearly rather than creating an unrealistic all-to-all graph.
        WatchCount = min(25, Users),
        Watches = [1 + ((Uid + Offset - 2) rem Users) || Offset <- lists:seq(1, WatchCount)],
        pw_realtime_registry:replace_presence_watch(Pid, Watches)
    end, lists:seq(1, Users)),
    setup_rtc(Users, PidTuple).

setup_rtc(Users, PidTuple) ->
    RtcUsers = Users div 5,
    setup_rtc_group(1, RtcUsers, PidTuple, 1).

setup_rtc_group(Start, RtcUsers, _PidTuple, _RoomId) when Start > RtcUsers -> ok;
setup_rtc_group(Start, RtcUsers, PidTuple, RoomId) ->
    Last = min(RtcUsers, Start + 3),
    Members = lists:seq(Start, Last),
    Room = maps:from_list([{Uid, #{pid => element(Uid, PidTuple), profile => #{}, muted => false,
                                   deafened => false, screen => false, screen_audio => false,
                                   reconnecting => false}}
                           || Uid <- Members]),
    pw_realtime_registry:sync_room(voice, RoomId, Room),
    setup_rtc_group(Last + 1, RtcUsers, PidTuple, RoomId + 1).

traffic_worker(Parent, Worker, WorkerCount, Users, PidTuple, TotalRate, Deadline) ->
    PerWorker = max(1, TotalRate div WorkerCount),
    PerTick = max(1, (PerWorker + 9) div 10),
    Seed = Worker * 1000003,
    traffic_ticks(Parent, Worker, Users, PidTuple, PerTick, Deadline, Seed, 0).

traffic_ticks(Parent, Worker, Users, PidTuple, PerTick, Deadline, Seq0, Count0) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
        true -> Parent ! {load_worker_done, Count0};
        false ->
            TickStart = erlang:monotonic_time(millisecond),
            {Seq, Count} = run_ops(PerTick, Worker, Users, PidTuple, Seq0, Count0),
            Spent = erlang:monotonic_time(millisecond) - TickStart,
            case 100 - Spent of Wait when Wait > 0 -> timer:sleep(Wait); _ -> ok end,
            traffic_ticks(Parent, Worker, Users, PidTuple, PerTick, Deadline, Seq, Count)
    end.

run_ops(0, _Worker, _Users, _PidTuple, Seq, Count) -> {Seq, Count};
run_ops(N, Worker, Users, PidTuple, Seq0, Count0) ->
    Seq = Seq0 + 1,
    Uid = 1 + ((Seq + Worker) rem Users),
    ChannelCount = max(1, (Users + 49) div 50),
    Channel = 1 + ((Uid - 1) rem ChannelCount),
    case Seq rem 20 of
        0 ->
            pw_realtime_registry:send_user(Uid, #{type => direct_message, message_id => Seq,
                author_id => 1 + (Seq rem Users), content => <<"synthetic direct-message payload">>});
        1 ->
            pw_realtime_registry:broadcast({channel, Channel}, #{type => typing, user_id => Uid});
        2 ->
            pw_realtime_registry:broadcast({channel, Channel}, #{type => presence_status,
                user_id => Uid, status => <<"online">>});
        3 ->
            maybe_rtc_signal(Users, PidTuple, Uid, Seq);
        4 ->
            maybe_rtc_activity(Users, PidTuple, Uid, Seq);
        5 ->
            presence_fanout(Uid, Seq);
        _ ->
            pw_realtime_registry:broadcast({channel, Channel}, #{type => channel_message,
                message_id => Seq, channel_id => Channel, author_id => Uid,
                content => <<"synthetic channel-message payload for sustained fanout">>})
    end,
    run_ops(N - 1, Worker, Users, PidTuple, Seq, Count0 + 1).

presence_fanout(Uid, Seq) ->
    Event = #{type => presence_status, user_id => Uid,
              status => case Seq rem 3 of 0 -> <<"busy">>; 1 -> <<"away">>; _ -> <<"online">> end},
    case pw_realtime_registry:presence_watchers(Uid) of
        unavailable -> ok;
        Pids -> pw_realtime_registry:send_many(Pids, Event)
    end.

maybe_rtc_activity(Users, PidTuple, Uid0, Seq) ->
    RtcUsers = Users div 5,
    case RtcUsers >= 2 of
        false -> ok;
        true ->
            Uid = 1 + ((Uid0 - 1) rem RtcUsers),
            RoomId = 1 + ((Uid - 1) div 4),
            Event = #{type => voice_activity, channel_id => RoomId, user_id => Uid, active => (Seq rem 2 =:= 0)},
            _ = pw_realtime_registry:relay_activity(voice, RoomId, Uid, element(Uid, PidTuple), Event),
            ok
    end.

maybe_rtc_signal(Users, PidTuple, Uid0, Seq) ->
    RtcUsers = Users div 5,
    case RtcUsers >= 2 of
        false -> ok;
        true ->
            Uid = 1 + ((Uid0 - 1) rem RtcUsers),
            RoomId = 1 + ((Uid - 1) div 4),
            First = ((RoomId - 1) * 4) + 1,
            Last = min(RtcUsers, First + 3),
            To = case Uid < Last of true -> Uid + 1; false -> First end,
            case To =:= Uid of
                true -> ok;
                false ->
                    Event = #{type => voice_signal, channel_id => RoomId, from_user_id => Uid,
                              signal => #{<<"kind">> => <<"candidate">>, <<"candidate">> => #{<<"candidate">> => <<"load">>, <<"seq">> => Seq}}},
                    pw_realtime_registry:relay_signal(voice, RoomId, Uid, element(Uid, PidTuple), To, Event)
            end
    end.

await_workers(0, Count, _Timeout) -> Count;
await_workers(N, Count, Timeout) ->
    receive
        {load_worker_done, WorkerCount} -> await_workers(N - 1, Count + WorkerCount, Timeout)
    after Timeout ->
        exit({load_workers_timed_out, N})
    end.

queue_stats(Pids) ->
    Queues = [N || Pid <- Pids,
                   {message_queue_len, N} <- [process_info(Pid, message_queue_len)]],
    Pending = [pw_realtime_registry:delivery_pending(Pid) || Pid <- Pids, is_process_alive(Pid)],
    Sorted = lists:sort(Queues),
    #{live => length(Sorted), p50 => percentile(Sorted, 50), p95 => percentile(Sorted, 95),
      p99 => percentile(Sorted, 99), max => case Sorted of [] -> 0; _ -> lists:last(Sorted) end,
      max_pending => case Pending of [] -> 0; _ -> lists:max(Pending) end}.

percentile([], _) -> 0;
percentile(Sorted, Percent) ->
    N = length(Sorted),
    Index = max(1, min(N, (N * Percent + 99) div 100)),
    lists:nth(Index, Sorted).

delta(Key, Before, After) -> maps:get(Key, After, 0) - maps:get(Key, Before, 0).

validate(Result) ->
    {_Soft, Hard} = pw_realtime_delivery:queue_limits(),
    Reasons0 = [],
    Reasons1 = case maps:get(max_mailbox, Result) >= Hard of
        true -> [{mailbox_not_bounded, maps:get(max_mailbox, Result), Hard} | Reasons0];
        false -> Reasons0
    end,
    Reasons2 = case maps:get(max_delivery_pending, Result) >= Hard of
        true -> [{delivery_reservations_not_bounded, maps:get(max_delivery_pending, Result), Hard} | Reasons1];
        false -> Reasons1
    end,
    Reasons3 = case maps:get(operations, Result) > 0 of
        true -> Reasons2;
        false -> [no_operations_executed | Reasons2]
    end,
    case Reasons3 of [] -> ok; _ -> {error, lists:reverse(Reasons3)} end.

cleanup(Pids, RegistryPid, OwnRegistry) ->
    lists:foreach(fun(Pid) ->
        pw_realtime_registry:unregister(Pid),
        catch Pid ! stop
    end, Pids),
    case {OwnRegistry, whereis(pw_realtime_registry)} of
        {true, RegistryPid} -> gen_server:stop(RegistryPid, normal, 2000);
        _ -> ok
    end.
