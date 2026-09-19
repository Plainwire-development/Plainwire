-module(pw_cluster).
-behaviour(gen_server).
-export([start_link/0, send_user/2, broadcast/2,
         revoke_server_access/3, revoke_conversation_access/2,
         status/0, members/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([start_link/2]).
start_link(C, Transport) -> gen_server:start_link({local, ?MODULE}, ?MODULE, {C, Transport}, []).
-endif.

-define(OUTBOX, pw_cluster_outbox).
-define(SEEN, pw_cluster_seen).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE,
                                      {pw_cluster_config:get(), pw_cluster_partisan}, []).
send_user(Uid, Event) -> publish({user, Uid}, Event).
broadcast(Key, Event) -> publish({topic, Key}, Event).
%% Access revocations are control-plane events: unlike an ordinary user notification,
%% they must mutate the realtime hub state on the websocket-owning node.  Routing
%% them through the same authenticated cluster envelope keeps kicks immediate even
%% when the HTTP/API request was handled by another node.
revoke_server_access(Uid, ServerId, ChannelIds) ->
    publish({control, revoke_server_access}, #{uid => Uid, server_id => ServerId, channel_ids => ChannelIds}).
revoke_conversation_access(Uid, ConversationId) ->
    publish({control, revoke_conversation_access}, #{uid => Uid, conversation_id => ConversationId}).

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
                N ->
                    Limit = ets:lookup_element(?OUTBOX, limit, 2),
                    case N =< Limit of
                        true ->
                    Key = erlang:unique_integer([monotonic, positive]),
                    ets:insert(?OUTBOX, {Key, erlang:system_time(millisecond), Target, Event}),
                            ensure_drain(),
                            ok;
                        false ->
                            ets:update_counter(?OUTBOX, count, -1),
                            {error, overloaded}
                    end
            catch error:badarg -> {error, unavailable} end
    end.

status() ->
    try gen_server:call(?MODULE, status, 500) catch exit:_ -> #{backend => unavailable} end.
members() -> maps:get(members, status(), []).

init({C, Transport}) ->
    process_flag(message_queue_data, off_heap),
    ets:new(?OUTBOX, [named_table, public, ordered_set, {read_concurrency, true}, {write_concurrency, auto}]),
    ets:new(?SEEN, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}]),
    ets:insert(?OUTBOX, {count, 0}),
    ets:insert(?OUTBOX, {limit, env_range("PLAINWIRE_CLUSTER_OUTBOX_LIMIT", 8192, 256, 131072)}),
    %% Cluster envelopes are accepted by pw_cluster_wire for 15 seconds. Keep
    %% the local outbox inside that authenticated replay window so a retried
    %% event cannot age into an envelope the owner must reject.
    ets:insert(?OUTBOX, {max_age_ms, env_range("PLAINWIRE_CLUSTER_EVENT_MAX_AGE_MS", 12000, 1000, 15000)}),
    ets:insert(?OUTBOX, {retry_ms, env_range("PLAINWIRE_CLUSTER_RETRY_MS", 500, 100, 5000)}),
    ets:insert(?OUTBOX, {drain_batch, env_range("PLAINWIRE_CLUSTER_DRAIN_BATCH", 128, 1, 4096)}),
    self() ! start_transport,
    {ok, #{config => C, transport => Transport, ready => false,
           boot => crypto:strong_rand_bytes(16), seq => 0, peers => #{}, known_peers => #{},
           seen_limit => env_range("PLAINWIRE_CLUSTER_DEDUP_LIMIT", 262144, 4096, 1048576),
           sent => 0, received => 0, dropped => 0, send_failures => 0}}.

handle_call(status, _, S) ->
    C = maps:get(config, S), T = maps:get(transport, S),
    Nodes = case maps:get(ready, S) of
        true -> try T:members() catch _:_ -> [] end;
        false -> []
    end,
    {reply, #{backend => maps:get(backend, C), ready => maps:get(ready, S),
              members => Nodes, queue => ets:lookup_element(?OUTBOX, count, 2),
              queue_limit => ets:lookup_element(?OUTBOX, limit, 2),
              dedup_entries => ets:info(?SEEN, size),
              sent => maps:get(sent, S), received => maps:get(received, S),
              dropped => maps:get(dropped, S), send_failures => maps:get(send_failures, S)}, S};
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(start_transport, S = #{config := #{backend := local}}) -> {noreply, S};
handle_info(start_transport, S = #{config := C, transport := T}) ->
    Result = try T:start(C) catch _:_ -> {error, transport_start_failed} end,
    case Result of
        ok ->
            erlang:send_after(5000, self(), tick),
            %% A bounded outbox may have accumulated while the transport was
            %% unavailable. Resume draining instead of dropping the outage burst.
            case ets:lookup_element(?OUTBOX, count, 2) > 0 of true -> ensure_drain(); false -> ok end,
            {noreply, S#{ready => true}};
        {error, Reason} ->
            logger:warning("[plainwire:cluster] transport unavailable: ~p; local service continues", [Reason]),
            erlang:send_after(30000, self(), start_transport),
            {noreply, S}
    end;
handle_info(drain, S = #{ready := false}) ->
    %% Keep recent events through a transient cluster outage, but evict expired
    %% head rows even while transport is down. Otherwise a long partition could
    %% leave the bounded outbox filled entirely with undeliverable stale events
    %% and reject newer control traffic until Partisan returned.
    _ = prune_expired_outbox(ets:lookup_element(?OUTBOX, drain_batch, 2)),
    erlang:send_after(1000, self(), drain),
    {noreply, S};
handle_info(drain, S) ->
    Batch = ets:lookup_element(?OUTBOX, drain_batch, 2),
    {S1, Blocked} = drain_batch(Batch, S),
    ets:delete(?OUTBOX, drain_scheduled),
    case ets:lookup_element(?OUTBOX, count, 2) > 0 of
        true ->
            Delay = case Blocked of
                true -> ets:lookup_element(?OUTBOX, retry_ms, 2);
                false -> 0
            end,
            schedule_drain(Delay);
        false -> ok
    end,
    {noreply, S1};
handle_info(tick, S = #{config := C, peers := Peers}) ->
    Now = erlang:system_time(millisecond),
    _ = ets:select_delete(?SEEN, [{{'_', '$1'}, [{'<', '$1', Now - 20000}], [true]}]),
    S1 = S#{peers => maps:filter(fun(_, {_, At}) -> At >= Now - 15000 end, Peers)},
    S2 = case maps:get(name, C) =:= maps:get(realtime_node, C) of
        true -> S1;
        false -> transmit(heartbeat, #{type => heartbeat}, Now, realtime, S1)
    end,
    erlang:send_after(5000, self(), tick),
    {noreply, S2};
handle_info(Envelope, S = #{config := #{backend := partisan} = C, seen_limit := SeenMax}) ->
    Now = erlang:system_time(millisecond),
    Allowed = [maps:get(name, P) || P <- maps:get(peers, C)],
    case maps:get(name, C) =:= maps:get(realtime_node, C) andalso
         pw_cluster_wire:decode(Envelope, Allowed, Now) of
        {ok, Id = {Origin, Boot, _}, Target, Event} ->
            case ets:info(?SEEN, size) >= SeenMax orelse not ets:insert_new(?SEEN, {Id, Now}) of
                true -> {noreply, count(dropped, S)};
                false ->
                    S1 = S,
                    case Target of
                        heartbeat ->
                            Peers = maps:get(peers, S1),
                            Known = maps:get(known_peers, S1, #{}),
                            %% The first heartbeat from a configured API node is normal
                            %% discovery. A changed boot id or a peer that has gone stale
                            %% and then returned means realtime control events may have
                            %% been missed while the link was unavailable. Ask sockets to
                            %% revalidate durable authorization, but do not reconnect them.
                            NeedsResync = case maps:get(Origin, Known, undefined) of
                                undefined -> false;
                                Boot ->
                                    case maps:get(Origin, Peers, undefined) of
                                        {Boot, At} when At >= Now - 10000 -> false;
                                        _ -> true
                                    end;
                                _OtherBoot -> true
                            end,
                            case NeedsResync of
                                true -> gen_server:cast(pw_hub, cluster_resync);
                                false -> ok
                            end,
                            {noreply, S1#{
                                peers => maps:put(Origin, {Boot, Now}, Peers),
                                known_peers => maps:put(Origin, Boot, Known)
                            }};
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
            case ets:lookup(?OUTBOX, Key) of
                [{Key, Time, Target, Event}] ->
                    drain_queued(Key, Time, Target, Event, undefined, S);
                [{Key, Time, Target, Event, Envelope}] ->
                    drain_queued(Key, Time, Target, Event, Envelope, S);
                _ -> {progress, S}
            end;
        _ -> {empty, S}
    end.

drain_queued(Key, Time, Target, Event, ExistingEnvelope, S0) ->
    MaxAge = ets:lookup_element(?OUTBOX, max_age_ms, 2),
    case erlang:system_time(millisecond) - Time =< MaxAge of
        false ->
            delete_outbox(Key),
            {progress, count(dropped, S0)};
        true ->
            {Envelope, S1} = case ExistingEnvelope of
                undefined ->
                    {Built, SNext} = make_envelope(Target, Event, Time, S0),
                    %% Persist the exact envelope before the first send. If a
                    %% send result is ambiguous, retries reuse the same
                    %% {origin,boot,seq} id and the owner deduplicates it.
                    ets:insert(?OUTBOX, {Key, Time, Target, Event, Built}),
                    {Built, SNext};
                Built -> {Built, S0}
            end,
            case send_envelope(events, Envelope, S1) of
                {ok, S2} ->
                    delete_outbox(Key),
                    {progress, S2};
                {error, S2} ->
                    %% Preserve ordered delivery and the bounded row. Do not
                    %% spin through later events while the transport rejects the
                    %% head event; a delayed drain retries it with the same id.
                    {blocked, S2}
            end
    end.

delete_outbox(Key) ->
    case ets:take(?OUTBOX, Key) of
        [] -> ok;
        [_] -> ets:update_counter(?OUTBOX, count, -1), ok
    end.

prune_expired_outbox(0) -> ok;
prune_expired_outbox(N) when N > 0 ->
    case ets:first(?OUTBOX) of
        Key when is_integer(Key) ->
            Now = erlang:system_time(millisecond),
            MaxAge = ets:lookup_element(?OUTBOX, max_age_ms, 2),
            case ets:lookup(?OUTBOX, Key) of
                [{Key, Time, _, _}] when Now - Time > MaxAge ->
                    delete_outbox(Key),
                    prune_expired_outbox(N - 1);
                [{Key, Time, _, _, _}] when Now - Time > MaxAge ->
                    delete_outbox(Key),
                    prune_expired_outbox(N - 1);
                _ -> ok
            end;
        _ -> ok
    end.

drain_batch(0, S) -> {S, false};
drain_batch(N, S0) when N > 0 ->
    case ets:lookup_element(?OUTBOX, count, 2) of
        0 -> {S0, false};
        _ ->
            case drain_one(S0) of
                {progress, S1} -> drain_batch(N - 1, S1);
                {empty, S1} -> {S1, false};
                {blocked, S1} -> {S1, true}
            end
    end.

ensure_drain() -> schedule_drain(0).

schedule_drain(DelayMs) ->
    try ets:insert_new(?OUTBOX, {drain_scheduled, true}) of
        true when DelayMs =< 0 -> ?MODULE ! drain, ok;
        true -> erlang:send_after(DelayMs, ?MODULE, drain), ok;
        false -> ok
    catch error:badarg -> ok end.

make_envelope(Target, Event, Time, S = #{config := C, seq := Seq, boot := Boot}) ->
    Next = Seq + 1,
    {pw_cluster_wire:encode(maps:get(name, C), Boot, Next, Time, Target, Event), S#{seq => Next}}.

send_envelope(_, _, S = #{ready := false}) -> {error, S};
send_envelope(Channel, Envelope, S = #{config := C, transport := T}) ->
    Result = try T:send(maps:get(realtime_node, C), Channel, Envelope)
             catch _:_ -> {error, unavailable} end,
    case Result of
        ok -> {ok, count(sent, S)};
        _ -> {error, count(send_failures, S)}
    end.

transmit(_, _, _, _, S = #{ready := false}) -> count(dropped, S);
transmit(Target, Event, Time, Channel, S0) ->
    {Envelope, S1} = make_envelope(Target, Event, Time, S0),
    case send_envelope(Channel, Envelope, S1) of
        {ok, S2} -> S2;
        {error, S2} -> count(dropped, S2)
    end.

env_range(Name, Default, Min, Max) ->
    min(Max, max(Min, pw_util:env_int(Name, Default))).
