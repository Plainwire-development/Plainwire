-module(pw_realtime_delivery).

-export([send_user/2, send_many/2, send_event/2, send_text/3,
         normalize_user_event/1, droppable/1, queue_limits/0]).

send_user(Pids, Event) -> send_many(Pids, normalize_user_event(Event)).

normalize_user_event(Event) when is_map(Event) ->
    case maps:get(type, Event, undefined) of
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
    end;
normalize_user_event(Event) -> #{type => notification, event => Event}.

send_event(Pid, Event) when is_pid(Pid), is_map(Event) ->
    send_text(Pid, pw_util:json(Event), maps:get(type, Event, unknown));
send_event(_, _) -> ignored.

send_many([], _Event) -> ok;
send_many(Pids, Event) when is_list(Pids), is_map(Event) ->
    Payload = pw_util:json(Event),
    Type = maps:get(type, Event, unknown),
    lists:foreach(fun(Pid) -> send_text(Pid, Payload, Type) end, Pids),
    ok;
send_many(_, _) -> ignored.

%% Reserve one outstanding application delivery atomically. This avoids a
%% process_info/2 call for every recipient of every fanout while keeping slow
%% consumer memory bounded. The WebSocket callback acknowledges hub_text as it
%% begins processing it, so a socket blocked on network output still accumulates
%% reservations and is shed at the hard limit.
send_text(Pid, Payload, Type) when is_pid(Pid), is_binary(Payload) ->
    case pw_realtime_registry:reserve_delivery(Pid) of
        unavailable -> degraded_send_text(Pid, Payload, Type);
        gone -> gone;
        QueueLen when is_integer(QueueLen) ->
            {Soft, Hard} = queue_limits(),
            case QueueLen >= Hard of
                true ->
                    _ = pw_realtime_registry:ack_delivery(Pid),
                    pw_realtime_registry:count(slow_consumers_evicted, 1),
                    logger:warning("[plainwire:realtime] slow_client_evicted pid=~p pending=~p", [Pid, QueueLen]),
                    
try exit(Pid, {shutdown, slow_consumer}) catch _:_ -> ok end,
                    evicted;
                false when QueueLen >= Soft ->
                    case droppable(Type) of
                        true ->
                            _ = pw_realtime_registry:ack_delivery(Pid),
                            pw_realtime_registry:count(dropped_ephemeral, 1),
                            dropped;
                        false -> deliver(Pid, Payload, Type)
                    end;
                false -> deliver(Pid, Payload, Type)
            end
    end;
send_text(_, _, _) -> ignored.

deliver(Pid, Payload, Type) ->
    Pid ! {hub_text, Payload, Type},
    pw_realtime_registry:count(delivered, 1),
    sent.

degraded_send_text(Pid, Payload, Type) ->
    %% Registry restarts are rare, but the hub/cluster fallback must still be
    %% able to deliver bounded traffic while ETS indexes are being rebuilt.
    %% Sampling process_info/2 is deliberately restricted to this degraded path;
    %% the normal hot path uses atomic registry reservations.
    case process_info(Pid, message_queue_len) of
        undefined -> gone;
        {message_queue_len, QueueLen} ->
            {Soft, Hard} = queue_limits(),
            case QueueLen >= Hard of
                true ->
                    logger:warning("[plainwire:realtime] degraded_slow_client_evicted pid=~p pending=~p", [Pid, QueueLen]),
                    try exit(Pid, {shutdown, slow_consumer}) catch _:_ -> ok end,
                    evicted;
                false when QueueLen >= Soft ->
                    case droppable(Type) of
                        true -> dropped;
                        false -> degraded_deliver(Pid, Payload, Type)
                    end;
                false -> degraded_deliver(Pid, Payload, Type)
            end
    end.

degraded_deliver(Pid, Payload, Type) ->
    Pid ! {hub_text, Payload, Type},
    sent.

queue_limits() ->
    case persistent_term:get({plainwire, realtime_queue_limits}, undefined) of
        {Soft, Hard} -> {Soft, Hard};
        undefined ->
            Soft0 = max(10, pw_util:env_int("PLAINWIRE_WS_SOFT_QUEUE", 500)),
            Hard0 = max(Soft0 + 1, pw_util:env_int("PLAINWIRE_WS_HARD_QUEUE", 2000)),
            Limits = {min(Soft0, 100000), min(Hard0, 200000)},
            persistent_term:put({plainwire, realtime_queue_limits}, Limits),
            Limits
    end.

droppable(presence_state) -> true;
droppable(presence_online) -> true;
droppable(presence_offline) -> true;
droppable(presence_status) -> true;
%% Roster snapshots are how a call learns who to connect to. Dropping one
%% leaves a pair silent until somebody reloads. Mute and join updates are
%% rare; speaking indicators stay droppable below.
droppable(voice_activity) -> true;
droppable(call_activity) -> true;
droppable(typing) -> true;
droppable(_) -> false.
