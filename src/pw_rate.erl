-module(pw_rate).
-behaviour(gen_server).
-export([start_link/0, allow/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
allow(Key, Limit, WindowMs) -> gen_server:call(?MODULE, {allow, Key, Limit, WindowMs}, 5000).

init([]) -> {ok, #{}}.
handle_call({allow, Key, Limit, WindowMs}, _From, State0) ->
    Now = erlang:monotonic_time(millisecond),
    Bucket = maps:get(Key, State0, []),
    Fresh = [T || T <- Bucket, Now - T < WindowMs],
    Allowed = length(Fresh) < Limit,
    State = case Allowed of true -> maps:put(Key, [Now|Fresh], State0); false -> maps:put(Key, Fresh, State0) end,
    {reply, Allowed, maybe_gc(State, Now)};
handle_call(_, _, State) -> {reply, false, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

maybe_gc(State, Now) when map_size(State) > 20000 ->
    maps:filter(fun(_, Times) -> lists:any(fun(T) -> Now - T < 300000 end, Times) end, State);
maybe_gc(State, _) -> State.
