-module(pw_storage_bench).
-export([run/1]).

%% Operator benchmark harness for the Scylla storage path. It is intentionally
%% bounded and uses a caller-provided synthetic scope ID. Insert samples are
%% hard-deleted after timing so a run does not leave benchmark messages behind.

run(Opts) when is_map(Opts) ->
    case pw_scylla_config:enabled() andalso pw_scylla:ready() of
        false -> {error, scylla_unavailable};
        true ->
            Scope = normalize_scope(maps:get(scope, Opts, <<"channel">>)),
            ScopeId = bounded_int(maps:get(scope_id, Opts, 9000000000000), 1, 9007199254740991, 9000000000000),
            ServerId = bounded_int(maps:get(server_id, Opts, ScopeId), 1, 9007199254740991, ScopeId),
            Iterations = bounded_int(maps:get(iterations, Opts, 100), 1, 10000, 100),
            Concurrency = bounded_int(maps:get(concurrency, Opts, 8), 1, 64, 8),
            case Scope of
                invalid -> {error, invalid_scope};
                _ ->
                    Ops = [insert, hot_partition_insert, recent, pagination, bulk_get,
                           event_append, event_history, audit_append, audit_history,
                           delivery_append, delivery_history],
                    GateBefore = pw_scylla_gate:stats(),
                    RedisBefore = pw_redis:stats(),
                    MetricsBefore = pw_storage_metrics:snapshot(),
                    OpTimeout = maps:get(operation_timeout_ms, pw_scylla_config:config(), 8000),
                    WorkerTimeout = erlang:max(120000, OpTimeout * 3 + 10000),
                    Results = maps:from_list([{Op, bench(Op, Iterations, Concurrency, WorkerTimeout,
                                                         operation_fun(Op, Scope, ScopeId, ServerId))} || Op <- Ops]),
                    {ok, #{scope => Scope, scope_id => ScopeId, server_id => ServerId,
                           iterations => Iterations, concurrency => Concurrency,
                           worker_timeout_ms => WorkerTimeout, results => Results,
                           gate_before => GateBefore, gate_after => pw_scylla_gate:stats(),
                           redis_before => RedisBefore, redis_after => pw_redis:stats(),
                           storage_metrics_before => MetricsBefore,
                           storage_metrics_after => pw_storage_metrics:snapshot()}}
            end
    end;
run(_) -> {error, bad_request}.

operation_fun(insert, Scope, ScopeId, _ServerId) ->
    fun() ->
        case pw_message_id:next() of
            {ok, Id} ->
                Now = pw_util:now_ms(),
                Msg = #{id => Id, scope => Scope, scope_id => ScopeId, user_id => 1,
                        body => <<"plainwire-storage-benchmark">>, created_at => Now, kind => <<"text">>},
                Result = pw_message_store_scylla:insert(Msg),
                _ = case Result of ok -> pw_message_store_scylla:hard_delete(Id); _ -> ok end,
                Result;
            Error -> Error
        end
    end;
operation_fun(hot_partition_insert, Scope, ScopeId, ServerId) ->
    %% Same physical partition target as the normal insert benchmark, kept as a
    %% separate operation so operators can tune per-partition backpressure
    %% independently from mixed read/write latency.
    operation_fun(insert, Scope, ScopeId, ServerId);
operation_fun(recent, Scope, ScopeId, _ServerId) ->
    fun() -> normalize_read(pw_message_store_scylla:get_recent(Scope, ScopeId, 50)) end;
operation_fun(pagination, Scope, ScopeId, _ServerId) ->
    fun() ->
        case pw_message_store_scylla:get_recent(Scope, ScopeId, 10) of
            {ok, []} -> ok;
            {ok, Rows} ->
                Cursor = maps:get(id, lists:last(Rows)),
                normalize_read(pw_message_store_scylla:get_before(Scope, ScopeId, Cursor, 50));
            Error -> Error
        end
    end;
operation_fun(bulk_get, Scope, ScopeId, _ServerId) ->
    fun() ->
        case pw_message_store_scylla:get_recent(Scope, ScopeId, 25) of
            {ok, Rows} -> normalize_read(pw_message_store_scylla:bulk_get([maps:get(id, M) || M <- Rows]));
            Error -> Error
        end
    end;
operation_fun(event_append, Scope, ScopeId, _ServerId) ->
    fun() ->
        case pw_message_id:next() of
            {ok, EventId} ->
                pw_event_store:append(#{event_id => EventId, type => <<"benchmark.event">>,
                                        scope => Scope, scope_id => ScopeId, server_id => 0,
                                        actor_id => 0, entity_id => 0, timestamp => pw_util:now_ms(),
                                        payload => #{benchmark => true}});
            Error -> Error
        end
    end;
operation_fun(event_history, Scope, ScopeId, _ServerId) ->
    fun() -> normalize_read(pw_event_store:recent(Scope, ScopeId, undefined, 80)) end;
operation_fun(audit_append, _Scope, _ScopeId, ServerId) ->
    fun() ->
        case pw_message_id:next() of
            {ok, EventId} ->
                pw_audit_store:append(#{event_id => EventId, server_id => ServerId,
                                        actor_id => 0, type => <<"benchmark.audit">>,
                                        entity_id => <<"storage-benchmark">>, timestamp => pw_util:now_ms(),
                                        payload => #{benchmark => true}});
            Error -> Error
        end
    end;

operation_fun(audit_history, _Scope, _ScopeId, ServerId) ->
    fun() -> normalize_read(pw_audit_store:recent(ServerId, undefined, 80)) end;
operation_fun(delivery_append, _Scope, _ScopeId, ServerId) ->
    fun() ->
        case pw_message_id:next() of
            {ok, EventId} ->
                pw_delivery_store:append(#{event_id => EventId, server_id => ServerId,
                                           timestamp => pw_util:now_ms(), target_type => <<"benchmark">>,
                                           target_id => ServerId, status => <<"ok">>, http_status => 204,
                                           attempt => 1, latency_ms => 1, error_code => <<>>});
            Error -> Error
        end
    end;
operation_fun(delivery_history, _Scope, _ScopeId, ServerId) ->
    fun() -> normalize_read(pw_delivery_store:recent(ServerId, undefined, 80)) end.

normalize_read({ok, _}) -> ok;
normalize_read(ok) -> ok;
normalize_read(Error) -> Error.

bench(Op, Iterations, Concurrency, WorkerTimeout, Fun) ->
    Started = erlang:monotonic_time(microsecond),
    Samples = run_batches(Iterations, Concurrency, WorkerTimeout, Fun, []),
    ElapsedUs = erlang:max(1, erlang:monotonic_time(microsecond) - Started),
    Durations = lists:sort([Us || {ok, Us} <- Samples]),
    Errors = [Reason || {{error, Reason}, _Us} <- Samples] ++
             [Other || {Other, _Us} <- Samples, not is_ok_result(Other), not is_error_result(Other)],
    Successes = length(Durations),
    #{operation => Op, attempted => Iterations, successes => Successes, errors => length(Errors),
      error_samples => lists:sublist([printable(E) || E <- Errors], 10),
      p50_us => percentile(Durations, 50), p95_us => percentile(Durations, 95), p99_us => percentile(Durations, 99),
      max_us => case Durations of [] -> 0; _ -> lists:last(Durations) end,
      throughput_per_sec => (Successes * 1000000) / ElapsedUs,
      elapsed_ms => ElapsedUs div 1000}.

run_batches(0, _Concurrency, _WorkerTimeout, _Fun, Acc) -> lists:reverse(Acc);
run_batches(Remaining, Concurrency, WorkerTimeout, Fun, Acc0) ->
    N = erlang:min(Remaining, Concurrency),
    Parent = self(),
    Pending = maps:from_list([begin
                Ref = make_ref(),
                {Pid, Mon} = spawn_monitor(fun() ->
                    T0 = erlang:monotonic_time(microsecond),
                    Result = try Fun() catch C:R -> {error, {C, sanitize(R)}} end,
                    Parent ! {bench_result, Ref, Result, erlang:monotonic_time(microsecond) - T0}
                end),
                {Ref, {Pid, Mon}}
            end || _ <- lists:seq(1, N)]),
    Deadline = erlang:monotonic_time(millisecond) + WorkerTimeout,
    Acc1 = collect_batch(Pending, Acc0, Deadline, WorkerTimeout),
    run_batches(Remaining - N, Concurrency, WorkerTimeout, Fun, Acc1).

collect_batch(Pending, Acc, _Deadline, _WorkerTimeout) when map_size(Pending) =:= 0 -> Acc;
collect_batch(Pending, Acc, Deadline, WorkerTimeout) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {bench_result, Ref, Result, Us} ->
            case maps:take(Ref, Pending) of
                {{_Pid, Mon}, Rest} ->
                    erlang:demonitor(Mon, [flush]),
                    Sample = case Result of ok -> {ok, Us}; {ok, _} -> {ok, Us}; _ -> {Result, Us} end,
                    collect_batch(Rest, [Sample | Acc], Deadline, WorkerTimeout);
                error ->
                    collect_batch(Pending, Acc, Deadline, WorkerTimeout)
            end;
        {'DOWN', Mon, process, _Pid, Reason} ->
            case take_pending_monitor(Mon, Pending) of
                {ok, Ref, Rest} ->
                    Sample = case Reason of
                        normal -> {{error, worker_exited_before_result}, 0};
                        _ -> {{error, {worker_crash, sanitize(Reason)}}, 0}
                    end,
                    collect_batch(Rest, [Sample | Acc], Deadline, WorkerTimeout);
                error ->
                    collect_batch(Pending, Acc, Deadline, WorkerTimeout)
            end
    after Remaining ->
        maps:fold(fun(_Ref, {Pid, Mon}, A) ->
                          catch exit(Pid, kill),
                          erlang:demonitor(Mon, [flush]),
                          [{{error, timeout}, WorkerTimeout * 1000} | A]
                  end, Acc, Pending)
    end.

take_pending_monitor(Mon, Pending) ->
    case [Ref || {Ref, {_Pid, M}} <- maps:to_list(Pending), M =:= Mon] of
        [Ref | _] -> {ok, Ref, maps:remove(Ref, Pending)};
        [] -> error
    end.

percentile([], _P) -> 0;
percentile(Sorted, P) ->
    N = length(Sorted),
    Index = erlang:max(1, (N * P + 99) div 100),
    lists:nth(erlang:min(N, Index), Sorted).

is_ok_result(ok) -> true;
is_ok_result({ok, _}) -> true;
is_ok_result(_) -> false.
is_error_result({error, _}) -> true;
is_error_result(_) -> false.

normalize_scope(<<"channel">>) -> <<"channel">>;
normalize_scope(<<"direct">>) -> <<"direct">>;
normalize_scope(channel) -> <<"channel">>;
normalize_scope(direct) -> <<"direct">>;
normalize_scope(_) -> invalid.

bounded_int(V, Min, Max, _Default) when is_integer(V) -> erlang:min(Max, erlang:max(Min, V));
bounded_int(_, _Min, _Max, Default) -> Default.

sanitize(R) when is_atom(R); is_integer(R); is_binary(R) -> R;
sanitize(_) -> internal_error.
printable(V) when is_binary(V) -> V;
printable(V) when is_atom(V) -> atom_to_binary(V, utf8);
printable(V) -> pw_util:clean_text(io_lib:format("~0p", [V]), 200).
