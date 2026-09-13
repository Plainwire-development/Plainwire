-module(pw_cluster).
-behaviour(gen_server).
-export([start_link/0, send_user/2, broadcast/2, status/0, members/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([start_link/2]).
start_link(C, Transport) -> gen_server:start_link({local, ?MODULE}, ?MODULE, {C, Transport}, []).
-endif.

-define(OUTBOX, pw_cluster_outbox).
-define(LIMIT, 256).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE,
                                      {pw_cluster_config:get(), pw_cluster_partisan}, []).
send_user(Uid, Event) -> publish({user, Uid}, Event).
broadcast(Key, Event) -> publish({topic, Key}, Event).

publish(Target, Event) ->
    %% Local delivery never waits on the cluster manager or a network connection.
    pw_cluster_local:deliver(Target, Event),
    case pw_cluster_config:websocket_owner() of
        true -> ok;
        false -> enqueue(Target, Event)
    end.

enqueue(Target, Event) ->
    case pw_cluster_wire:allowed(Target, Event) andalso erlang:external_size(Event) =< 131072 of
        false -> {error, unsupported_event};
        true ->
            try ets:update_counter(?OUTBOX, count, 1) of
                N when N =< ?LIMIT ->
                    Key = erlang:unique_integer([monotonic, positive]),
                    ets:insert(?OUTBOX, {Key, erlang:system_time(millisecond), Target, Event}),
                    ?MODULE ! drain,
                    ok;
                _ -> ets:update_counter(?OUTBOX, count, -1), {error, overloaded}
            catch error:badarg -> {error, unavailable} end
    end.

status() ->
    try gen_server:call(?MODULE, status, 500) catch exit:_ -> #{backend => unavailable} end.
members() -> maps:get(members, status(), []).

init({C, Transport}) ->
    process_flag(message_queue_data, off_heap),
    ets:new(?OUTBOX, [named_table, public, ordered_set, {write_concurrency, true}]),
    ets:insert(?OUTBOX, {count, 0}),
    self() ! start_transport,
    {ok, #{config => C, transport => Transport, ready => false,
           boot => crypto:strong_rand_bytes(16), seq => 0, seen => #{}, peers => #{},
           sent => 0, received => 0, dropped => 0}}.

handle_call(status, _, S) ->
    C = maps:get(config, S), T = maps:get(transport, S),
    Nodes = case maps:get(ready, S) of true -> T:members(); false -> [] end,
    {reply, #{backend => maps:get(backend, C), ready => maps:get(ready, S),
              members => Nodes, queue => ets:lookup_element(?OUTBOX, count, 2),
              sent => maps:get(sent, S), received => maps:get(received, S),
              dropped => maps:get(dropped, S)}, S};
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(start_transport, S = #{config := #{backend := local}}) -> {noreply, S};
handle_info(start_transport, S = #{config := C, transport := T}) ->
    Result = try T:start(C) catch _:_ -> {error, transport_start_failed} end,
    case Result of
        ok -> erlang:send_after(5000, self(), tick), {noreply, S#{ready => true}};
        {error, Reason} ->
            logger:warning("[plainwire:cluster] transport unavailable: ~p; local service continues", [Reason]),
            erlang:send_after(30000, self(), start_transport),
            {noreply, S}
    end;
handle_info(drain, S) -> {noreply, drain_one(S)};
handle_info(tick, S = #{config := C, seen := Seen, peers := Peers}) ->
    Now = erlang:system_time(millisecond),
    S1 = S#{seen => maps:filter(fun(_, At) -> At >= Now - 20000 end, Seen),
            peers => maps:filter(fun(_, {_, At}) -> At >= Now - 15000 end, Peers)},
    S2 = case maps:get(name, C) =:= maps:get(realtime_node, C) of
        true -> S1;
        false -> transmit(heartbeat, #{type => heartbeat}, Now, realtime, S1)
    end,
    erlang:send_after(5000, self(), tick),
    {noreply, S2};
handle_info(Envelope, S = #{config := #{backend := partisan} = C}) ->
    Now = erlang:system_time(millisecond),
    Allowed = [maps:get(name, P) || P <- maps:get(peers, C)],
    case maps:get(name, C) =:= maps:get(realtime_node, C) andalso
         pw_cluster_wire:decode(Envelope, Allowed, Now) of
        {ok, Id = {Origin, Boot, _}, Target, Event} ->
            Seen = maps:get(seen, S),
            case maps:is_key(Id, Seen) orelse map_size(Seen) >= 4096 of
                true -> {noreply, count(dropped, S)};
                false ->
                    S1 = S#{seen => maps:put(Id, Now, Seen)},
                    case Target of
                        heartbeat ->
                            Peers = maps:get(peers, S1),
                            case maps:get(Origin, Peers, undefined) of
                                {Boot, At} when At >= Now - 10000 -> ok;
                                _ -> gen_server:cast(pw_hub, cluster_resync)
                            end,
                            {noreply, S1#{peers => maps:put(Origin, {Boot, Now}, Peers)}};
                        _ -> pw_cluster_local:deliver(Target, Event), {noreply, count(received, S1)}
                    end
            end;
        _ -> {noreply, count(dropped, S)}
    end;
handle_info(_, S) -> {noreply, S}.

terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
count(Key, S) -> S#{Key := maps:get(Key, S) + 1}.

drain_one(S) ->
    case ets:first(?OUTBOX) of
        Key when is_integer(Key) ->
            [{Key, Time, Target, Event}] = ets:take(?OUTBOX, Key),
            ets:update_counter(?OUTBOX, count, -1),
            case erlang:system_time(millisecond) - Time =< 15000 of
                true -> transmit(Target, Event, Time, events, S);
                false -> count(dropped, S)
            end;
        _ -> S
    end.
transmit(_, _, _, _, S = #{ready := false}) -> count(dropped, S);
transmit(Target, Event, Time, Channel, S = #{config := C, transport := T, seq := Seq, boot := Boot}) ->
    Envelope = pw_cluster_wire:encode(maps:get(name, C), Boot, Seq + 1, Time, Target, Event),
    Result = T:send(maps:get(realtime_node, C), Channel, Envelope),
    count(case Result of ok -> sent; _ -> dropped end, S#{seq => Seq + 1}).
