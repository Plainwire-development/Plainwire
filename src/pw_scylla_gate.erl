-module(pw_scylla_gate).
-behaviour(gen_server).
-export([start_link/0, run/3, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {active = 0, by_key = #{}, queued = queue:new(), queued_by_key = #{}, workers = #{}, cfg = #{}}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

run(Key, Fun, Timeout) when is_function(Fun, 0), is_integer(Timeout), Timeout > 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    try gen_server:call(?MODULE, {run, normalize_key(Key), Fun, Deadline}, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, overloaded_timeout};
        exit:{noproc, _} -> {error, unavailable}
    end.

stats() ->
    try gen_server:call(?MODULE, stats, 2000)
    catch _:_ -> #{active => 0, queued => 0, status => unavailable} end.

init([]) ->
    C = pw_scylla_config:config(),
    {ok, #state{cfg = C}}.

handle_call(stats, _From, S) ->
    {reply, #{active => S#state.active, queued => queue:len(S#state.queued), status => healthy,
              partitions_active => maps:size(S#state.by_key), partitions_queued => maps:size(S#state.queued_by_key)}, S};
handle_call({run, Key, Fun, Deadline}, From, S0) ->
    Max = maps:get(max_inflight, S0#state.cfg),
    PartMax = maps:get(max_partition_inflight, S0#state.cfg),
    ActiveKey = maps:get(Key, S0#state.by_key, 0),
    case S0#state.active < Max andalso ActiveKey < PartMax of
        true -> {noreply, start_worker(Key, Fun, From, Deadline, S0)};
        false ->
            QLen = queue:len(S0#state.queued),
            KeyQLen = maps:get(Key, S0#state.queued_by_key, 0),
            case QLen < maps:get(max_queue, S0#state.cfg) andalso KeyQLen < maps:get(max_partition_queue, S0#state.cfg) of
                true ->
                    Q1 = queue:in({Key, Fun, From, Deadline}, S0#state.queued),
                    KQ1 = maps:put(Key, KeyQLen + 1, S0#state.queued_by_key),
                    pw_storage_metrics:set_gauge(scylla_queue_depth, QLen + 1),
                    {noreply, S0#state{queued = Q1, queued_by_key = KQ1}};
                false ->
                    pw_storage_metrics:incr(scylla_load_shed),
                    {reply, {error, overloaded}, S0}
            end
    end;
handle_call(_Req, _From, S) -> {reply, {error, bad_request}, S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info({'DOWN', Ref, process, _Pid, Reason}, S0) ->
    case maps:take(Ref, S0#state.workers) of
        error -> {noreply, S0};
        {{Key, From, _Pid, TimerRef}, Workers1} ->
            _ = erlang:cancel_timer(TimerRef),
            Reply = case Reason of
                {pw_scylla_result, Result} -> Result;
                normal -> {error, worker_no_result};
                _ -> {error, {worker_crash, sanitize_reason(Reason)}}
            end,
            gen_server:reply(From, Reply),
            S1 = release(Key, S0#state{workers = Workers1}),
            {noreply, dispatch_queued(S1)}
    end;
handle_info({worker_timeout, Ref}, S0) ->
    case maps:take(Ref, S0#state.workers) of
        error -> {noreply, S0};
        {{Key, From, Pid, _TimerRef}, Workers1} ->
            %% The caller's timeout is also bounded, but killing the worker is
            %% essential: otherwise a wedged driver request can permanently
            %% consume an in-flight slot after its caller has gone away.
            catch exit(Pid, kill),
            erlang:demonitor(Ref, [flush]),
            gen_server:reply(From, {error, operation_timeout}),
            pw_storage_metrics:incr(scylla_active_timeout),
            S1 = release(Key, S0#state{workers = Workers1}),
            {noreply, dispatch_queued(S1)}
    end;
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, S) ->
    maps:foreach(fun(Ref, {_Key, From, Pid, TimerRef}) ->
                         _ = erlang:cancel_timer(TimerRef),
                         catch exit(Pid, shutdown),
                         erlang:demonitor(Ref, [flush]),
                         gen_server:reply(From, {error, shutting_down})
                 end, S#state.workers),
    lists:foreach(fun({_Key, _Fun, From, _Deadline}) -> gen_server:reply(From, {error, shutting_down}) end, queue:to_list(S#state.queued)),
    ok.
code_change(_Old, State, _Extra) -> {ok, State}.

start_worker(Key, Fun, From, Deadline, S0) ->
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = try Fun() catch C:R -> {error, {C, sanitize_reason(R)}} end,
        exit({pw_scylla_result, Result})
    end),
    Remaining = erlang:max(1, Deadline - erlang:monotonic_time(millisecond)),
    TimerRef = erlang:send_after(Remaining, self(), {worker_timeout, Ref}),
    KeyN = maps:get(Key, S0#state.by_key, 0) + 1,
    S0#state{active = S0#state.active + 1,
             by_key = maps:put(Key, KeyN, S0#state.by_key),
             workers = maps:put(Ref, {Key, From, Pid, TimerRef}, S0#state.workers)}.

release(Key, S0) ->
    N = maps:get(Key, S0#state.by_key, 1) - 1,
    ByKey1 = case N =< 0 of true -> maps:remove(Key, S0#state.by_key); false -> maps:put(Key, N, S0#state.by_key) end,
    S0#state{active = erlang:max(0, S0#state.active - 1), by_key = ByKey1}.

dispatch_queued(S0) ->
    dispatch_queued(S0, queue:len(S0#state.queued)).

dispatch_queued(S, 0) ->
    pw_storage_metrics:set_gauge(scylla_queue_depth, queue:len(S#state.queued)),
    S;
dispatch_queued(S0, Remaining) ->
    case queue:out(S0#state.queued) of
        {empty, _} -> S0;
        {{value, {Key, Fun, From, Deadline}}, Q1} ->
            KeyQ = maps:get(Key, S0#state.queued_by_key, 1) - 1,
            KQ1 = case KeyQ =< 0 of true -> maps:remove(Key, S0#state.queued_by_key); false -> maps:put(Key, KeyQ, S0#state.queued_by_key) end,
            Now = erlang:monotonic_time(millisecond),
            case Deadline =< Now of
                true ->
                    %% gen_server:call may already have timed out, but replying is
                    %% harmless. More importantly, never execute stale queued work.
                    gen_server:reply(From, {error, overloaded_timeout}),
                    pw_storage_metrics:incr(scylla_queue_expired),
                    dispatch_queued(S0#state{queued = Q1, queued_by_key = KQ1}, Remaining - 1);
                false ->
                    Max = maps:get(max_inflight, S0#state.cfg),
                    PartMax = maps:get(max_partition_inflight, S0#state.cfg),
                    ActiveKey = maps:get(Key, S0#state.by_key, 0),
                    case S0#state.active < Max andalso ActiveKey < PartMax of
                        true ->
                            S1 = start_worker(Key, Fun, From, Deadline, S0#state{queued = Q1, queued_by_key = KQ1}),
                            dispatch_queued(S1, Remaining - 1);
                        false ->
                            %% Rotate a blocked hot partition behind other queued partitions.
                            KQ2 = maps:put(Key, maps:get(Key, KQ1, 0) + 1, KQ1),
                            dispatch_queued(S0#state{queued = queue:in({Key, Fun, From, Deadline}, Q1), queued_by_key = KQ2}, Remaining - 1)
                    end
            end
    end.

normalize_key(Key) when is_binary(Key); is_integer(Key); is_atom(Key) -> Key;
normalize_key(Key) -> erlang:phash2(Key).

sanitize_reason(R) -> pw_storage_sanitize:safe_reason(R).
