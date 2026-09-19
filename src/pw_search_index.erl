-module(pw_search_index).
-behaviour(gen_server).
-export([start_link/0, status/0, reconcile_now/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_INTERVAL_MS, 1500).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
status() -> pw_db:search_index_status().
reconcile_now() -> gen_server:cast(?MODULE, reconcile).

init([]) ->
    self() ! reconcile,
    {ok, #{timer => undefined}}.

handle_call(_Request, _From, State) -> {reply, {error, unsupported}, State}.
handle_cast(reconcile, State) ->
    self() ! reconcile,
    {noreply, State};
handle_cast(_, State) -> {noreply, State}.

handle_info(reconcile, State) ->
    Batch = clamp(pw_util:env_int("PLAINWIRE_SEARCH_BACKFILL_BATCH", 100), 10, 250),
    Delay = clamp(pw_util:env_int("PLAINWIRE_SEARCH_BACKFILL_INTERVAL_MS", ?DEFAULT_INTERVAL_MS), 250, 60000),
    NextDelay = case pw_db:search_index_reconcile(Batch) of
        {ok, #{complete := true}} -> max(Delay, 30000);
        {ok, _} -> Delay;
        {error, database_busy} -> min(60000, Delay * 4);
        {error, database_unavailable} -> min(60000, Delay * 4);
        _ -> min(60000, Delay * 2)
    end,
    Ref = erlang:send_after(NextDelay, self(), reconcile),
    {noreply, State#{timer => Ref}};
handle_info(_, State) -> {noreply, State}.

terminate(_Reason, State) ->
    case maps:get(timer, State, undefined) of
        undefined -> ok;
        Ref -> _ = erlang:cancel_timer(Ref), ok
    end.
code_change(_Old, State, _Extra) -> {ok, State}.

clamp(Value, Min, Max) -> min(Max, max(Min, Value)).
