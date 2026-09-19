-module(pw_rate).
-behaviour(gen_server).
-export([start_link/0, allow/3, allow_shared/3, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, pw_rate_counters).
-define(GC_MS, 60000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% hot path stays in atomic ETS, not one sad global mailbox.
allow(Key, Limit, WindowMs) when Limit > 0, WindowMs > 0 ->
    Now = erlang:monotonic_time(millisecond),
    Bucket = Now div WindowMs,
    CounterKey = {Key, WindowMs, Bucket},
    Expires = (Bucket + 1) * WindowMs + WindowMs,
    %% High-cardinality attacker input must not turn the rate limiter itself
    %% into an unbounded memory sink. Existing counters continue to update;
    %% novel keys fail closed once the soft global table budget is reached.
    case counter_admitted(CounterKey) of
        false -> false;
        true ->
            try ets:update_counter(?TABLE, CounterKey, {2, 1}, {CounterKey, 0, Expires}) of
                Count -> Count =< Limit
            catch
                error:badarg -> false
            end
    end;
allow(_, _, _) -> false.

%% Add Redis as a distributed second gate only where callers explicitly need it.
%% The local ETS gate remains first and authoritative during Redis outages.
allow_shared(Key, Limit, WindowMs) ->
    case allow(Key, Limit, WindowMs) of
        false -> false;
        true ->
            case pw_redis:rate_allow(Key, Limit, WindowMs) of
                false -> false;
                true -> true;
                unavailable -> true
            end
    end.

stats() ->
    try #{entries => ets:info(?TABLE, size), memory_words => ets:info(?TABLE, memory)}
    catch _:_ -> #{entries => 0, memory_words => 0}
    end.

counter_admitted(CounterKey) ->
    try
        ets:member(?TABLE, CounterKey) orelse
            ets:info(?TABLE, size) < rate_max_entries()
    catch error:badarg -> false
    end.

rate_max_entries() ->
    min(5000000, max(10000, pw_util:env_int_cached("PLAINWIRE_RATE_MAX_ENTRIES", 500000))).

init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set,
        {read_concurrency, true}, {write_concurrency, true},
        {decentralized_counters, true}]),
    erlang:send_after(?GC_MS, self(), gc),
    {ok, #{}}.

handle_call(_, _, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(gc, State) ->
    Now = erlang:monotonic_time(millisecond),
    _ = ets:select_delete(?TABLE, [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}]),
    erlang:send_after(?GC_MS, self(), gc),
    {noreply, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
