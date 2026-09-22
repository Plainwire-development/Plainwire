-module(pw_storage_outbox).

%% Bound both the encoded row and the decompressed External Term Format size.
%% storage_outbox is internal-only, but a malformed/corrupted row must never be
%% able to turn one worker into an unbounded BEAM allocation.
-define(MAX_OUTBOX_PAYLOAD_BYTES, 2097152).
-define(MAX_OUTBOX_DECODED_BYTES, 8388608).
%% A scoped privacy erase can perform: locator lookup + four bounded message-row
%% deletes (live locator plus day/week/month candidates) + locator delete. Keep
%% the worker budget aligned with that worst-case serial CQL path.
-define(MAX_CQL_OPS_PER_DELIVERY, 6).
-behaviour(gen_server).
-export([start_link/0, wake/0, flush_once/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {timer = undefined, interval_ms = 250, batch = 25, concurrency = 8,
             operation_timeout_ms = 8000, last_prune_ms = 0}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
wake() -> gen_server:cast(?MODULE, wake).
flush_once() -> gen_server:call(?MODULE, flush_once, flush_call_timeout()).
stats() -> #{scylla => pw_scylla:health(), gate => pw_scylla_gate:stats()}.

init([]) ->
    Interval = clamp(pw_util:env_int("PLAINWIRE_STORAGE_OUTBOX_INTERVAL_MS", 250), 50, 5000),
    Batch = clamp(pw_util:env_int("PLAINWIRE_STORAGE_OUTBOX_BATCH", 25), 1, 100),
    Concurrency = clamp(pw_util:env_int("PLAINWIRE_STORAGE_OUTBOX_CONCURRENCY", 8), 1, 32),
    OpTimeout = maps:get(operation_timeout_ms, pw_scylla_config:config(), 8000),
    {ok, schedule(#st{interval_ms=Interval,batch=Batch,concurrency=Concurrency,
                      operation_timeout_ms=OpTimeout}, 100)}.

handle_call(flush_once, _From, S) ->
    {reply, drain(S#st.batch, S#st.concurrency, S#st.operation_timeout_ms), S};
handle_call(_Req, _From, S) -> {reply, {error, bad_request}, S}.
handle_cast(wake, S0) -> self() ! tick, {noreply, S0};
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(tick, S0) ->
    _ = drain(S0#st.batch, S0#st.concurrency, S0#st.operation_timeout_ms),
    S1 = maybe_prune(S0),
    {noreply, schedule(S1, S1#st.interval_ms)};
handle_info(_Info, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

schedule(S, Delay) ->
    case S#st.timer of undefined -> ok; Ref -> erlang:cancel_timer(Ref), ok end,
    S#st{timer=erlang:send_after(Delay, self(), tick)}.

%% A batch is bounded both by claim size and worker concurrency. This avoids a
%% slow Scylla node turning one serialized outbox process into minutes of head-
%% of-line blocking while still keeping pressure behind pw_scylla_gate.
drain(Batch, Concurrency, OpTimeout) ->
    case pw_scylla_config:enabled() andalso pw_scylla:ready() of
        false -> {error, scylla_unavailable};
        true ->
            %% Claim at most one executable wave at a time. Claiming the entire
            %% batch up front makes later rows age in the `running` state while
            %% earlier waves are still using Scylla; on a slow cluster a second
            %% Plainwire node could then reclaim those not-yet-started rows as
            %% stale. Wave-sized claiming keeps the PostgreSQL lease aligned with
            %% actual execution while preserving the configured per-drain bound.
            drain_claims(Batch, Concurrency, OpTimeout, [], 0)
    end.

drain_claims(Remaining, _Concurrency, _OpTimeout, Results, Claimed) when Remaining =< 0 ->
    drain_result(Results, Claimed);
drain_claims(Remaining, Concurrency, OpTimeout, Results0, Claimed0) ->
    ClaimLimit = erlang:min(Remaining, Concurrency),
    case pw_db:storage_outbox_claim(ClaimLimit) of
        {ok, []} ->
            drain_result(Results0, Claimed0);
        {ok, Items} ->
            Delivered = deliver_parallel(Items, Concurrency, OpTimeout),
            Count = length(Items),
            Results = Results0 ++ Delivered,
            Claimed = Claimed0 + Count,
            case Count < ClaimLimit of
                true -> drain_result(Results, Claimed);
                false -> drain_claims(Remaining - Count, Concurrency, OpTimeout, Results, Claimed)
            end;
        Error ->
            drain_result([{error, {outbox_claim_failed, Error}} | Results0], Claimed0)
    end.

drain_result(Results, Claimed) ->
    pw_storage_metrics:set_gauge(storage_outbox_last_batch, Claimed),
    Failures = [F || F = {error, _} <- Results],
    case Failures of
        [] -> ok;
        _ -> {error, {delivery_failures, lists:sublist(Failures, 10)}}
    end.

deliver_parallel([], _Concurrency, _OpTimeout) -> [];
deliver_parallel(Items, Concurrency, OpTimeout) ->
    N = erlang:min(Concurrency, length(Items)),
    {Chunk, Rest} = lists:split(N, Items),
    run_delivery_chunk(Chunk, OpTimeout) ++ deliver_parallel(Rest, Concurrency, OpTimeout).

run_delivery_chunk(Items, OpTimeout) ->
    Parent = self(),
    Tag = make_ref(),
    Workers = [begin
        {Pid, MRef} = spawn_monitor(fun() ->
            Result = safe_deliver_and_finish(Item),
            Parent ! {storage_outbox_delivery_result, Tag, self(), Result}
        end),
        {Pid, MRef}
    end || Item <- Items],
    %% Most deliveries are one CQL operation, but a privacy hard-delete can
    %% intentionally perform several bounded serial CQL operations so it remains
    %% correct even if its locator was lost after an ambiguous write. Budget for
    %% the true worst case, then leave room for PostgreSQL finalization and
    %% scheduler delay without allowing a stuck worker to pin the outbox forever.
    Deadline = erlang:monotonic_time(millisecond) + delivery_worker_timeout(OpTimeout),
    collect_delivery_chunk(Tag, Workers, Deadline, []).

collect_delivery_chunk(_Tag, [], _Deadline, Acc) -> lists:reverse(Acc);
collect_delivery_chunk(Tag, Workers, Deadline, Acc) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {storage_outbox_delivery_result, Tag, Pid, Result} ->
            case lists:keytake(Pid, 1, Workers) of
                {value, {Pid, MRef}, Rest} ->
                    erlang:demonitor(MRef, [flush]),
                    collect_delivery_chunk(Tag, Rest, Deadline, [Result | Acc]);
                false -> collect_delivery_chunk(Tag, Workers, Deadline, Acc)
            end;
        {'DOWN', MRef, process, Pid, Reason} ->
            case lists:keytake(Pid, 1, Workers) of
                {value, {Pid, MRef}, Rest} ->
                    pw_storage_metrics:incr(storage_outbox_worker_crash),
                    collect_delivery_chunk(Tag, Rest, Deadline,
                                           [{error, {delivery_worker_crash, safe_reason(Reason)}} | Acc]);
                false -> collect_delivery_chunk(Tag, Workers, Deadline, Acc)
            end
    after Remaining ->
        [begin catch exit(Pid, kill), erlang:demonitor(MRef, [flush]) end || {Pid, MRef} <- Workers],
        pw_storage_metrics:add(storage_outbox_worker_timeout, length(Workers)),
        lists:reverse(Acc) ++ [{error, delivery_worker_timeout} || _ <- Workers]
    end.

safe_deliver_and_finish(Item) ->
    try deliver_and_finish(Item)
    catch
        Class:Reason ->
            pw_storage_metrics:incr(storage_outbox_worker_exception),
            {error, {delivery_worker_exception, Class, safe_reason(Reason)}}
    end.

deliver_and_finish(#{id := Id} = Item) ->
    Delivery = deliver(Item),
    LockedAt = maps:get(locked_at, Item, 0),
    case pw_db:storage_outbox_finish(Id, LockedAt, normalize_result(Delivery)) of
        {ok, _} -> Delivery;
        ok -> Delivery;
        FinishError ->
            %% A delivered item whose PostgreSQL state could not be finalized will
            %% be reclaimed and delivered again later; every supported operation is
            %% idempotent. Surface the failure so operator flushes fail closed.
            {error, {outbox_finalize_failed, FinishError, normalize_result(Delivery)}}
    end;
deliver_and_finish(_) -> {error, malformed_outbox_item}.

deliver(#{kind := Kind0, entity_id := EntityId, payload := Bin} = Item) ->
    Kind = pw_util:bin(Kind0),
    case Kind of
        <<"message.hard_delete">> -> deliver_hard_delete(Item, EntityId);
        _ -> deliver_payload(Kind, Bin)
    end;
deliver(_) -> {error, malformed_outbox_item}.

deliver_hard_delete(#{entity_scope := Scope, entity_scope_id := ScopeId,
                       entity_created_at := CreatedAt}, EntityId)
  when is_binary(Scope), byte_size(Scope) > 0, is_integer(ScopeId), ScopeId > 0,
       is_integer(CreatedAt), CreatedAt >= 0 ->
    pw_message_store_scylla:hard_delete_scoped(EntityId, Scope, ScopeId, CreatedAt);
deliver_hard_delete(_Item, EntityId) ->
    %% Compatibility with outbox rows created before the scoped erase columns
    %% existed. New privacy jobs always use hard_delete_scoped/4.
    pw_message_store_scylla:hard_delete(EntityId).

deliver_payload(Kind, Bin) ->
    case safe_term(Bin) of
        {ok, Payload} ->
            case Kind of
                <<"message.upsert">> -> pw_message_store_scylla:insert(Payload);
                <<"message.event">> -> pw_event_store:append(Payload);
                <<"audit.event">> -> pw_audit_store:append(Payload);
                <<"delivery.event">> -> pw_delivery_store:append(Payload);
                _ -> {error, unknown_outbox_kind}
            end;
        Error -> Error
    end.

safe_term(Bin) when is_binary(Bin), byte_size(Bin) =< ?MAX_OUTBOX_PAYLOAD_BYTES ->
    case external_term_decoded_size(Bin) of
        Size when is_integer(Size), Size > ?MAX_OUTBOX_DECODED_BYTES -> {error, payload_too_large};
        _ ->
            try {ok, binary_to_term(Bin, [safe])}
            catch _:_ -> {error, malformed_payload} end
    end;
safe_term(Bin) when is_binary(Bin) -> {error, payload_too_large};
safe_term(_) -> {error, malformed_payload}.

%% COMPRESSED_EXT: version=131, tag=80, then a 32-bit uncompressed-size field.
%% For ordinary ETF values the encoded byte bound above is already sufficient.
external_term_decoded_size(<<131, 80, Size:32/unsigned-big, _/binary>>) -> Size;
external_term_decoded_size(_) -> unknown.

maybe_prune(S = #st{last_prune_ms = Last}) ->
    Now = pw_util:now_ms(),
    case Now - Last >= 3600000 of
        true ->
            case pw_db:storage_outbox_prune() of
                {ok, #{delivered_deleted := D, failed_deleted := F}} ->
                    pw_storage_metrics:set_gauge(storage_outbox_pruned_delivered, D),
                    pw_storage_metrics:set_gauge(storage_outbox_pruned_failed, F);
                _ -> ok
            end,
            S#st{last_prune_ms = Now};
        false -> S
    end.

normalize_result(ok) -> ok;
normalize_result({ok, _}) -> ok;
normalize_result({error, Reason}) -> {error, Reason};
normalize_result(Other) -> {error, {unexpected_result, Other}}.

flush_call_timeout() ->
    Batch = clamp(pw_util:env_int("PLAINWIRE_STORAGE_OUTBOX_BATCH", 25), 1, 100),
    Concurrency = clamp(pw_util:env_int("PLAINWIRE_STORAGE_OUTBOX_CONCURRENCY", 8), 1, 32),
    OpTimeout = maps:get(operation_timeout_ms, pw_scylla_config:config(), 8000),
    Waves = (Batch + Concurrency - 1) div Concurrency,
    erlang:max(30000, Waves * delivery_worker_timeout(OpTimeout) + 5000).

delivery_worker_timeout(OpTimeout) ->
    ?MAX_CQL_OPS_PER_DELIVERY * OpTimeout + 30000.

safe_reason(Reason) -> pw_storage_sanitize:safe_reason(Reason).

clamp(V, Min, Max) -> erlang:min(Max, erlang:max(Min, V)).
