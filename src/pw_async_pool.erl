-module(pw_async_pool).
-behaviour(gen_server).

-export([start_link/0, submit/1, submit/3, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

submit(Fun) when is_function(Fun, 0) -> submit(undefined, Fun, undefined).
submit(Tag, Fun, ReplyPid) when is_function(Fun, 0) ->
    try gen_server:call(?MODULE, {submit, Tag, Fun, ReplyPid}, 100)
    catch exit:_ -> {error, unavailable} end.

stats() ->
    try gen_server:call(?MODULE, stats, 200)
    catch exit:_ -> #{available => false} end.

init([]) ->
    process_flag(message_queue_data, off_heap),
    Schedulers = erlang:system_info(schedulers_online),
    DefaultWorkers = min(32, max(4, Schedulers * 2)),
    Limit = env_range("PLAINWIRE_ASYNC_WORKERS", DefaultWorkers, 2, 128),
    MaxQueue = env_range("PLAINWIRE_ASYNC_MAX_QUEUE", 4096, 64, 65536),
    {ok, #{limit => Limit, max_queue => MaxQueue, running => #{}, queue => queue:new(),
           queued => 0, submitted => 0, completed => 0, failed => 0, dropped => 0}}.

handle_call(stats, _From, State) ->
    {reply, #{available => true,
              workers => maps:get(limit, State),
              running => map_size(maps:get(running, State)),
              queued => maps:get(queued, State),
              max_queue => maps:get(max_queue, State),
              submitted => maps:get(submitted, State),
              completed => maps:get(completed, State),
              failed => maps:get(failed, State),
              dropped => maps:get(dropped, State)}, State};
handle_call({submit, Tag, Fun, ReplyPid}, _From, State0) ->
    State1 = State0#{submitted := maps:get(submitted, State0) + 1},
    case map_size(maps:get(running, State1)) < maps:get(limit, State1) of
        true -> {reply, ok, start_job(Tag, Fun, ReplyPid, State1)};
        false ->
            case maps:get(queued, State1) < maps:get(max_queue, State1) of
                true ->
                    Q1 = queue:in({Tag, Fun, ReplyPid}, maps:get(queue, State1)),
                    {reply, ok, State1#{queue => Q1, queued := maps:get(queued, State1) + 1}};
                false ->
                    {reply, {error, overloaded}, State1#{dropped := maps:get(dropped, State1) + 1}}
            end
    end;
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info({async_done, Pid, Result}, State0) when is_pid(Pid) ->
    Running0 = maps:get(running, State0),
    case maps:take(Pid, Running0) of
        error -> {noreply, State0};
        {{Ref, Tag, ReplyPid}, Running} ->
            erlang:demonitor(Ref, [flush]),
            maybe_reply(ReplyPid, Tag, Result),
            FailedInc = case Result of {error, {worker_failed, _, _}} -> 1; _ -> 0 end,
            State1 = State0#{running => Running,
                             completed := maps:get(completed, State0) + 1,
                             failed := maps:get(failed, State0) + FailedInc},
            {noreply, start_queued(State1)}
    end;
handle_info({'DOWN', Ref, process, Pid, Reason}, State0) ->
    Running0 = maps:get(running, State0),
    case maps:get(Pid, Running0, undefined) of
        {Ref, Tag, ReplyPid} ->
            maybe_reply(ReplyPid, Tag, {error, {worker_down, Reason}}),
            State1 = State0#{running => maps:remove(Pid, Running0),
                             completed := maps:get(completed, State0) + 1,
                             failed := maps:get(failed, State0) + 1},
            {noreply, start_queued(State1)};
        _ -> {noreply, State0}
    end;
handle_info(_, State) -> {noreply, State}.

terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.

start_job(Tag, Fun, ReplyPid, State) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = try Fun()
        catch Class:Reason -> {error, {worker_failed, Class, Reason}} end,
        Parent ! {async_done, self(), Result}
    end),
    Running = maps:put(Pid, {Ref, Tag, ReplyPid}, maps:get(running, State)),
    State#{running => Running}.

start_queued(State=#{queued := 0}) -> State;
start_queued(State0) ->
    case map_size(maps:get(running, State0)) < maps:get(limit, State0) of
        false -> State0;
        true ->
            case queue:out(maps:get(queue, State0)) of
                {{value, {Tag, Fun, ReplyPid}}, Q1} ->
                    State1 = State0#{queue => Q1, queued := maps:get(queued, State0) - 1},
                    start_queued(start_job(Tag, Fun, ReplyPid, State1));
                {empty, _} -> State0#{queued => 0}
            end
    end.

maybe_reply(Pid, Tag, Result) when is_pid(Pid) -> Pid ! {pw_async_result, Tag, Result}, ok;
maybe_reply(_, _, _) -> ok.

env_range(Name, Default, Min, Max) ->
    min(Max, max(Min, pw_util:env_int(Name, Default))).
