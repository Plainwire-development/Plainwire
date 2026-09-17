-module(pw_storage_metrics).
-behaviour(gen_server).
-export([start_link/0, observe/3, incr/1, add/2, set_gauge/2, snapshot/0, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TAB, pw_storage_metrics_tab).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

observe(Operation, Outcome, DurationUs) when is_integer(DurationUs), DurationUs >= 0 ->
    ensure_table(),
    incr({request, Operation, Outcome}),
    add({latency_sum_us, Operation}, DurationUs),
    maybe_max(Operation, DurationUs),
    incr({latency_bucket, Operation, bucket(DurationUs)}),
    ok.

incr(Key) ->
    add(Key, 1).

add(Key, Value) ->
    ensure_table(),
    _ = ets:update_counter(?TAB, Key, {2, Value}, {Key, 0}),
    ok.

set_gauge(Key, Value) when is_integer(Value); is_float(Value) ->
    ensure_table(), ets:insert(?TAB, {{gauge, Key}, Value}), ok.

snapshot() ->
    ensure_table(),
    maps:from_list(ets:tab2list(?TAB)).

reset() ->
    ensure_table(), ets:delete_all_objects(?TAB), ok.

init([]) -> ensure_table(), {ok, #{}}.
handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            try ets:new(?TAB, [named_table, public, set, {write_concurrency, true}, {read_concurrency, true}]) of _ -> ok
            catch error:badarg -> ok end;
        _ -> ok
    end.

maybe_max(Operation, Value) ->
    Key = {latency_max_us, Operation},
    case ets:lookup(?TAB, Key) of
        [{_, Old}] when Old >= Value -> ok;
        _ -> ets:insert(?TAB, {Key, Value})
    end.

bucket(Us) when Us =< 1000 -> le_1ms;
bucket(Us) when Us =< 5000 -> le_5ms;
bucket(Us) when Us =< 10000 -> le_10ms;
bucket(Us) when Us =< 25000 -> le_25ms;
bucket(Us) when Us =< 50000 -> le_50ms;
bucket(Us) when Us =< 100000 -> le_100ms;
bucket(Us) when Us =< 250000 -> le_250ms;
bucket(Us) when Us =< 1000000 -> le_1s;
bucket(_) -> gt_1s.
