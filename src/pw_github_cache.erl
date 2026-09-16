-module(pw_github_cache).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, pw_github_cache).

%% Keep the public GitHub metadata ETS table owned by a supervised, long-lived
%% process. Creating it inside a Cowboy request would make the table disappear
%% when that request process exits, defeating ETags and stale-if-error caching.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set,
        {read_concurrency, true}, {write_concurrency, true}]),
    {ok, #{}}.

handle_call(_, _, State) -> {reply, ok, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
