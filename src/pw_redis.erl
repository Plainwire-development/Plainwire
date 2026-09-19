-module(pw_redis).
-behaviour(gen_server).

-export([start_link/0, enabled/0, command/1, command/2, cast_command/1,
         rate_allow/3, presence_set/3, presence_set_many/2, presence_get/1, presence_delete/1, cache_put/3, cache_get/1,
         cache_delete/1, cache_version/1, cache_bump_version/1,
         cache_get_at_version/2, cache_put_at_version/4, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-ifdef(TEST).
-export([encode_command/1, parse_resp/1, redis_key/2]).
-endif.

-define(DEFAULT_PORT, 6379).
-define(DEFAULT_TIMEOUT, 80).
-define(MAX_RESPONSE_BYTES, 8 * 1024 * 1024).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

enabled() ->
    case whereis(?MODULE) of
        undefined -> configured();
        _ ->
            try gen_server:call(?MODULE, enabled, 100)
            catch exit:_ -> false end
    end.

command(Args) -> command(Args, timeout_ms()).
command(Args, Timeout) when is_list(Args), is_integer(Timeout), Timeout > 0 ->
    case choose_worker(Args) of
        {manager, Pid} when is_pid(Pid) ->
            try gen_server:call(Pid, {command, Args, Timeout}, Timeout + 100)
            catch exit:_ -> {error, unavailable} end;
        {worker, Pid} when is_pid(Pid) -> worker_call(Pid, Args, Timeout);
        _ -> {error, unavailable}
    end.

cast_command(Args) when is_list(Args) ->
    send_async(choose_worker(Args), {redis_cast, Args}).

cast_pipeline([]) -> ok;
cast_pipeline(Commands) when is_list(Commands) ->
    Groups = lists:foldl(fun(Command, Acc) ->
        Entry = choose_worker(Command),
        maps:update_with(Entry, fun(L) -> [Command | L] end, [Command], Acc)
    end, #{}, Commands),
    maps:foreach(fun(Entry, Reversed) -> send_pipeline(Entry, lists:reverse(Reversed)) end, Groups),
    ok.

%% Shared limiter is deliberately a second gate behind pw_rate's ETS limiter.
%% If Redis is absent or unhealthy we fail open to the already-enforced local
%% limit; Redis can improve cross-node fairness but can never take auth down.
rate_allow(Key, Limit, WindowMs) when Limit > 0, WindowMs > 0 ->
    RedisKey = redis_key(<<"rate">>, term_to_binary(Key)),
    Script = <<"local n=redis.call('INCR',KEYS[1]); if n==1 then redis.call('PEXPIRE',KEYS[1],ARGV[1]) end; if n<=tonumber(ARGV[2]) then return 1 else return 0 end">>,
    case command([<<"EVAL">>, Script, <<"1">>, RedisKey,
                  integer_to_binary(WindowMs), integer_to_binary(Limit)]) of
        {ok, 1} -> true;
        {ok, _} -> false;
        {error, _} -> unavailable
    end;
rate_allow(_, _, _) -> false.

presence_set(Uid, Status0, TtlMs) when is_integer(Uid), Uid > 0, TtlMs >= 1000 ->
    Status = safe_status(Status0),
    Owner = presence_owner(),
    Now = pw_util:now_ms(),
    cast_command(presence_set_command(Uid, Status, TtlMs, Owner, Now));
presence_set(_, _, _) -> ok.

%% Refreshing thousands of online users one TCP round-trip at a time creates a
%% burst every presence TTL interval and can bury the Redis worker mailbox.
%% Pipeline single-key Lua commands so this remains compatible with Redis
%% Cluster hash-slot rules while collapsing the network round trips.
presence_set_many(Pairs0, TtlMs) when is_list(Pairs0), TtlMs >= 1000 ->
    Pairs = [{Uid, safe_status(Status)} || {Uid, Status} <- Pairs0,
        is_integer(Uid), Uid > 0],
    Owner = presence_owner(),
    Now = pw_util:now_ms(),
    Commands = [presence_set_command(Uid, Status, TtlMs, Owner, Now) || {Uid, Status} <- Pairs],
    lists:foreach(fun(Batch) -> cast_pipeline(Batch) end, chunk_list(Commands, 256)),
    ok;
presence_set_many(_, _) -> ok.

presence_set_command(Uid, Status, TtlMs, Owner, Now) ->
    Key = redis_key(<<"presence">>, integer_to_binary(Uid)),
    %% Presence is stored per Plainwire node, not as one user-wide scalar. That
    %% prevents one websocket node from overwriting another node that still has
    %% an active session for the same account. Each field carries its own expiry
    %% deadline; readers prune stale fields atomically. Invisible means this node
    %% has no visible session and therefore removes only its own field.
    Script = <<"local owner=ARGV[1]; local now=tonumber(ARGV[2]); local ttl=tonumber(ARGV[3]); "
               "local status=ARGV[4]; if status=='invisible' then redis.call('HDEL',KEYS[1],owner); "
               "if redis.call('HLEN',KEYS[1])==0 then redis.call('DEL',KEYS[1]) end; return 1 end; "
               "redis.call('HSET',KEYS[1],owner,status..'|'..tostring(now+ttl)); redis.call('PEXPIRE',KEYS[1],ttl*2); return 1">>,
    [<<"EVAL">>, Script, <<"1">>, Key, Owner, integer_to_binary(Now), integer_to_binary(TtlMs), Status].

presence_get(Uids0) when is_list(Uids0) ->
    Uids = lists:usort([U || U <- Uids0, is_integer(U), U > 0]),
    case Uids of
        [] -> #{};
        _ ->
            %% Keep every presence read single-key. Besides avoiding one giant
            %% Lua invocation for a 2k-member watch list, this preserves Redis
            %% Cluster/proxy compatibility because no command spans hash slots.
            %% Commands are synchronously pipelined across the local Redis worker
            %% pool, so the caller pays roughly one round trip per worker/batch,
            %% not one round trip per watched account.
            Now = integer_to_binary(pw_util:now_ms()),
            Pairs = [{U, presence_get_command(U, Now)} || U <- Uids],
            Results = lists:append([
                presence_get_batch(Batch) || Batch <- chunk_list(Pairs, 256)
            ]),
            maps:from_list([{U, normalize_presence(V)} || {U, {ok, V}} <- Results, is_binary(V)])
    end.

presence_get_command(Uid, Now) ->
    Key = redis_key(<<"presence">>, integer_to_binary(Uid)),
    Script = <<"local now=tonumber(ARGV[1]); local vals=redis.call('HGETALL',KEYS[1]); "
               "local best=false; local rank=0; for i=1,#vals,2 do local v=vals[i+1]; "
               "local sep=string.find(v,'|',1,true); if sep then local st=string.sub(v,1,sep-1); "
               "local exp=tonumber(string.sub(v,sep+1)) or 0; if exp<=now then redis.call('HDEL',KEYS[1],vals[i]); "
               "else local r=(st=='busy' and 3) or (st=='online' and 2) or (st=='away' and 1) or 0; "
               "if r>rank then rank=r; best=st end end end; if redis.call('HLEN',KEYS[1])==0 then redis.call('DEL',KEYS[1]) end; return best">>,
    [<<"EVAL">>, Script, <<"1">>, Key, Now].

presence_get_batch(Pairs) ->
    Commands = [Command || {_Uid, Command} <- Pairs],
    Values = pipeline_commands(Commands, timeout_ms()),
    lists:zipwith(fun({Uid, _}, Value) -> {Uid, Value} end, Pairs, Values).

presence_delete(Uid) when is_integer(Uid), Uid > 0 ->
    %% Presence is node-scoped. Disconnecting from this gateway must never wipe
    %% a session for the same account that is still alive on another gateway.
    Owner = presence_owner(),
    Key = redis_key(<<"presence">>, integer_to_binary(Uid)),
    Script = <<"redis.call('HDEL',KEYS[1],ARGV[1]); if redis.call('HLEN',KEYS[1])==0 then redis.call('DEL',KEYS[1]) end; return 1">>,
    cast_command([<<"EVAL">>, Script, <<"1">>, Key, Owner]);
presence_delete(_) -> ok.

presence_owner() ->
    case os:getenv("PLAINWIRE_NODE_ID") of
        false -> iolist_to_binary([atom_to_binary(node(), utf8), <<"-">>, list_to_binary(os:getpid())]);
        "" -> iolist_to_binary([atom_to_binary(node(), utf8), <<"-">>, list_to_binary(os:getpid())]);
        Value -> pw_util:clean_text(Value, 120)
    end.

%% Small generic hot-cache primitive. Values are opaque binaries so callers keep
%% serialization/versioning ownership. Durable data must always be written to
%% PostgreSQL before this is populated.
cache_put(Key0, Value, TtlMs) when is_binary(Value), TtlMs >= 1000 ->
    Key = redis_key(<<"cache">>, Key0),
    cast_command([<<"SET">>, Key, Value, <<"PX">>, integer_to_binary(TtlMs)]);
cache_put(_, _, _) -> ok.

cache_get(Key0) ->
    case command([<<"GET">>, redis_key(<<"cache">>, Key0)]) of
        {ok, Value} when is_binary(Value) -> {ok, Value};
        {ok, undefined} -> miss;
        {error, _} -> unavailable;
        _ -> miss
    end.

cache_delete(Key0) -> cast_command([<<"DEL">>, redis_key(<<"cache">>, Key0)]).

%% Versioned cache namespaces make invalidation constant-time. A mutation bumps
%% the namespace generation; old payloads remain unreachable until their short
%% TTL expires. The generation itself lives much longer than payloads so an
%% expired namespace can never accidentally revive a generation-0 stale entry.
cache_version(Key0) ->
    case command([<<"GET">>, redis_key(<<"cache-version">>, Key0)]) of
        {ok, undefined} -> {ok, 0};
        {ok, Value} when is_binary(Value) ->
            case parse_integer(Value) of {ok, N} when N >= 0 -> {ok, N}; _ -> unavailable end;
        {error, _} -> unavailable;
        _ -> unavailable
    end.

cache_bump_version(Key0) ->
    Key = redis_key(<<"cache-version">>, Key0),
    %% Keep generation keys for a day while cache entries live for seconds.
    %% The Lua script also refreshes the TTL for active conversations.
    Script = <<"local n=redis.call('INCR',KEYS[1]); redis.call('PEXPIRE',KEYS[1],86400000); return n">>,
    case command([<<"EVAL">>, Script, <<"1">>, Key]) of
        {ok, N} when is_integer(N), N >= 0 -> {ok, N};
        {error, _} -> unavailable;
        _ -> unavailable
    end.

cache_get_at_version(Namespace0, Version) when is_integer(Version), Version >= 0 ->
    cache_get(versioned_cache_key(Namespace0, Version));
cache_get_at_version(_, _) -> unavailable.

cache_put_at_version(Namespace0, Version, Value, TtlMs)
  when is_integer(Version), Version >= 0, is_binary(Value), TtlMs >= 1000 ->
    cache_put(versioned_cache_key(Namespace0, Version), Value, TtlMs);
cache_put_at_version(_, _, _, _) -> ok.

versioned_cache_key(Namespace0, Version) ->
    Namespace = to_binary(Namespace0),
    <<Namespace/binary, 0, (integer_to_binary(Version))/binary>>.

stats() ->
    case whereis(?MODULE) of
        undefined -> #{enabled => false, connected => false};
        _ ->
            try gen_server:call(?MODULE, stats, 200)
            catch exit:_ -> #{enabled => configured(), connected => false} end
    end.

init([]) ->
    process_flag(trap_exit, true),
    Enabled = configured(),
    BaseState = #{enabled => Enabled, socket => undefined, transport => tcp,
              host => os:getenv("PLAINWIRE_REDIS_HOST", "127.0.0.1"),
              port => env_range("PLAINWIRE_REDIS_PORT", ?DEFAULT_PORT, 1, 65535),
              tls => env_bool("PLAINWIRE_REDIS_TLS", false),
              tls_insecure => env_bool("PLAINWIRE_REDIS_TLS_INSECURE", false),
              username => os:getenv("PLAINWIRE_REDIS_USERNAME", ""),
              password => os:getenv("PLAINWIRE_REDIS_PASSWORD", ""),
              database => env_range("PLAINWIRE_REDIS_DB", 0, 0, 15),
              timeout => timeout_ms(),
              commands => 0, failures => 0, connects => 0, last_error => undefined},
    PoolSize = case Enabled of
        true -> env_range("PLAINWIRE_REDIS_POOL_SIZE", min(8, max(2, erlang:system_info(schedulers_online))), 1, 32);
        false -> 1
    end,
    %% Keep the gen_server as a pure control plane. Redis I/O happens only in
    %% dedicated workers so a slow socket can never delay worker supervision,
    %% stats, or pool repair. Workers connect lazily and reconnect independently.
    Workers = case Enabled of
        true -> [spawn_link(fun() -> redis_worker_start(BaseState) end) || _ <- lists:seq(1, PoolSize)];
        false -> []
    end,
    Entries = [{worker, Pid} || Pid <- Workers],
    %% slot 1 = round-robin cursor; slot 2 = shed async accelerator writes.
    Counter = atomics:new(2, [{signed, false}]),
    persistent_term:put({?MODULE, pool}, {Entries, Counter}),
    {ok, BaseState#{workers => Workers, pool_size => length(Workers)}}.

handle_call(enabled, _, State) -> {reply, maps:get(enabled, State), State};
handle_call(stats, _, State) ->
    Reply = aggregate_stats(State),
    {reply, Reply, State};
handle_call({command, _Args, _Timeout}, _, State=#{enabled := false}) ->
    {reply, {error, disabled}, State};
handle_call({command, Args, Timeout}, _, State0) ->
    {Reply, State} = execute(Args, Timeout, State0, true),
    {reply, Reply, State};
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

handle_cast({command, _Args}, State=#{enabled := false}) -> {noreply, State};
handle_cast({pipeline, _Commands}, State=#{enabled := false}) -> {noreply, State};
handle_cast({command, Args}, State0) ->
    {_Reply, State} = execute(Args, maps:get(timeout, State0), State0, false),
    {noreply, State};
handle_cast({pipeline, Commands}, State0) ->
    {_Reply, State} = execute_pipeline(Commands, maps:get(timeout, State0), State0, true),
    {noreply, State};
handle_cast(_, State) -> {noreply, State}.

handle_info(warm_connect, State=#{enabled := true}) ->
    case ensure_connected(State) of
        {ok, State1} -> {noreply, State1};
        {error, _Reason, State1} -> erlang:send_after(5000, self(), warm_connect), {noreply, State1}
    end;
handle_info({tcp_closed, _}, State) -> {noreply, close_socket(State)};
handle_info({ssl_closed, _}, State) -> {noreply, close_socket(State)};
handle_info({tcp_error, _, Reason}, State) -> {noreply, failed(Reason, close_socket(State))};
handle_info({ssl_error, _, Reason}, State) -> {noreply, failed(Reason, close_socket(State))};
handle_info({'EXIT', Pid, Reason}, State=#{workers := Workers}) ->
    case lists:member(Pid, Workers) of
        false -> {noreply, State};
        true ->
            logger:warning("[plainwire:redis] pool worker restarted reason=~p", [Reason]),
            Base = worker_base_state(State),
            Replacement = spawn_link(fun() -> redis_worker_start(Base) end),
            Workers1 = [case W =:= Pid of true -> Replacement; false -> W end || W <- Workers],
            update_pool(Workers1),
            {noreply, State#{workers => Workers1}}
    end;
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    persistent_term:erase({?MODULE, pool}),
    persistent_term:erase({?MODULE, async_queue_limit}),
    persistent_term:erase({?MODULE, sync_queue_limit}),
    [Pid ! stop || Pid <- maps:get(workers, State, [])],
    _ = close_socket(State),
    ok.
code_change(_, State, _) -> {ok, State}.

choose_worker(Args) ->
    case persistent_term:get({?MODULE, pool}, undefined) of
        {Entries, Counter} when is_list(Entries), Entries =/= [] ->
            Index = case command_route_key(Args) of
                undefined ->
                    N = atomics:add_get(Counter, 1, 1),
                    1 + ((N - 1) rem length(Entries));
                Key -> 1 + erlang:phash2(Key, length(Entries))
            end,
            lists:nth(Index, Entries);
        _ -> unavailable
    end.

send_async({worker, Pid}, Message) when is_pid(Pid) ->
    case queue_len(Pid) >= redis_async_queue_limit() of
        true -> record_async_drop(), ok;
        false -> Pid ! Message, ok
    end;
send_async(_, _) -> ok.

send_pipeline({worker, Pid}, Commands) when is_pid(Pid) ->
    send_async({worker, Pid}, {redis_pipeline, Commands});
send_pipeline(_, _) -> ok.

redis_async_queue_limit() ->
    case persistent_term:get({?MODULE, async_queue_limit}, undefined) of
        Limit when is_integer(Limit) -> Limit;
        undefined ->
            Limit = env_range("PLAINWIRE_REDIS_ASYNC_QUEUE", 4096, 128, 65536),
            persistent_term:put({?MODULE, async_queue_limit}, Limit),
            Limit
    end.

record_async_drop() ->
    case persistent_term:get({?MODULE, pool}, undefined) of
        {_Entries, Counter} -> atomics:add(Counter, 2, 1);
        _ -> ok
    end.

%% Hash commands by their Redis key so asynchronous mutations for the same
%% logical record remain ordered even with multiple TCP connections.
command_route_key([Command, Key | _]) when Command =:= <<"GET">>; Command =:= <<"SET">>;
                                                Command =:= <<"DEL">>; Command =:= <<"INCR">>;
                                                Command =:= <<"HGETALL">>; Command =:= <<"HSET">>;
                                                Command =:= <<"HDEL">> -> Key;
command_route_key([<<"EVAL">>, _Script, NumKeys, Key | _]) ->
    case NumKeys of <<"1">> -> Key; 1 -> Key; _ -> undefined end;
command_route_key(_) -> undefined.

worker_call(Pid, Args, Timeout) ->
    case queue_len(Pid) >= redis_sync_queue_limit() of
        true -> {error, overloaded};
        false ->
            Ref = make_ref(),
            Mon = erlang:monitor(process, Pid),
            Pid ! {redis_command, self(), Ref, Args, Timeout},
            receive
                {redis_reply, Ref, Reply} -> erlang:demonitor(Mon, [flush]), Reply;
                {'DOWN', Mon, process, Pid, _} -> {error, unavailable}
            after Timeout + 100 ->
                erlang:demonitor(Mon, [flush]),
                {error, timeout}
            end
    end.

redis_sync_queue_limit() ->
    case persistent_term:get({?MODULE, sync_queue_limit}, undefined) of
        Limit when is_integer(Limit) -> Limit;
        undefined ->
            Limit = env_range("PLAINWIRE_REDIS_SYNC_QUEUE", 2048, 64, 32768),
            persistent_term:put({?MODULE, sync_queue_limit}, Limit),
            Limit
    end.

%% Return one {ok, Value}/{error, Reason} entry per input command while running
%% independent worker pipelines concurrently. This is used for bounded bulk
%% reads such as presence snapshots; it never turns them into a cross-slot Redis
%% command and it keeps result ordering stable for callers.
pipeline_commands([], _Timeout) -> [];
pipeline_commands(Commands, Timeout) ->
    Indexed = lists:zip(lists:seq(1, length(Commands)), Commands),
    Groups = lists:foldl(fun({Index, Command}, Acc) ->
        Entry = choose_worker(Command),
        maps:update_with(Entry, fun(L) -> [{Index, Command} | L] end,
                         [{Index, Command}], Acc)
    end, #{}, Indexed),
    {Pending, Results0} = maps:fold(fun(Entry, Reversed, {PendingAcc, ResultAcc}) ->
        Items = lists:reverse(Reversed),
        case Entry of
            {worker, Pid} when is_pid(Pid) ->
                case queue_len(Pid) >= redis_sync_queue_limit() of
                    true ->
                        {PendingAcc, add_pipeline_errors(Items, overloaded, ResultAcc)};
                    false ->
                        Ref = make_ref(),
                        Mon = erlang:monitor(process, Pid),
                        Pid ! {redis_pipeline_call, self(), Ref,
                               [Command || {_Index, Command} <- Items], Timeout},
                        {[{Ref, Mon, Pid, Items} | PendingAcc], ResultAcc}
                end;
            _ -> {PendingAcc, add_pipeline_errors(Items, unavailable, ResultAcc)}
        end
    end, {[], #{}}, Groups),
    Deadline = erlang:monotonic_time(millisecond) + Timeout + 100,
    Results = collect_pipeline_replies(Pending, Deadline, Results0),
    [maps:get(I, Results, {error, timeout}) || I <- lists:seq(1, length(Commands))].

add_pipeline_errors(Items, Reason, Acc) ->
    lists:foldl(fun({Index, _}, A) -> maps:put(Index, {error, Reason}, A) end, Acc, Items).

collect_pipeline_replies([], _Deadline, Results) -> Results;
collect_pipeline_replies(Pending, Deadline, Results0) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of
        0 ->
            lists:foreach(fun({_Ref, Mon, _Pid, _Items}) -> erlang:demonitor(Mon, [flush]) end, Pending),
            lists:foldl(fun({_Ref, _Mon, _Pid, Items}, Acc) ->
                add_pipeline_errors(Items, timeout, Acc)
            end, Results0, Pending);
        _ ->
            receive
                {redis_pipeline_reply, Ref, Reply} ->
                    case lists:keytake(Ref, 1, Pending) of
                        {value, {Ref, Mon, _Pid, Items}, Rest} ->
                            erlang:demonitor(Mon, [flush]),
                            Results1 = add_pipeline_reply(Items, Reply, Results0),
                            collect_pipeline_replies(Rest, Deadline, Results1);
                        false -> collect_pipeline_replies(Pending, Deadline, Results0)
                    end;
                {'DOWN', Mon, process, Pid, _Reason} ->
                    case take_pipeline_monitor(Mon, Pid, Pending) of
                        {ok, Items, Rest} ->
                            collect_pipeline_replies(Rest, Deadline,
                                add_pipeline_errors(Items, unavailable, Results0));
                        error -> collect_pipeline_replies(Pending, Deadline, Results0)
                    end
            after Remaining ->
                collect_pipeline_replies(Pending, Deadline, Results0)
            end
    end.

add_pipeline_reply(Items, {ok, Values}, Results) when is_list(Values), length(Values) =:= length(Items) ->
    lists:foldl(fun({{Index, _}, Value}, Acc) -> maps:put(Index, {ok, Value}, Acc) end,
                Results, lists:zip(Items, Values));
add_pipeline_reply(Items, {error, Reason}, Results) -> add_pipeline_errors(Items, Reason, Results);
add_pipeline_reply(Items, _Other, Results) -> add_pipeline_errors(Items, invalid_response, Results).

take_pipeline_monitor(_Mon, _Pid, []) -> error;
take_pipeline_monitor(Mon, Pid, [{_Ref, Mon, Pid, Items} | Rest]) -> {ok, Items, Rest};
take_pipeline_monitor(Mon, Pid, [Item | Rest]) ->
    case take_pipeline_monitor(Mon, Pid, Rest) of
        {ok, Items, Tail} -> {ok, Items, [Item | Tail]};
        error -> error
    end.

redis_worker_start(State0) ->
    process_flag(message_queue_data, off_heap),
    State = case maps:get(enabled, State0, false) of
        true ->
            case ensure_connected(State0) of
                {ok, Connected} -> Connected;
                {error, _Reason, Failed} -> Failed
            end;
        false -> State0
    end,
    redis_worker_loop(State).

redis_worker_loop(State0) ->
    receive
        {redis_command, From, Ref, Args, Timeout} when is_pid(From), is_list(Args) ->
            {Reply, State} = execute(Args, Timeout, State0, true),
            From ! {redis_reply, Ref, Reply},
            redis_worker_loop(State);
        {redis_cast, Args} when is_list(Args) ->
            {_Reply, State} = execute(Args, maps:get(timeout, State0), State0, false),
            redis_worker_loop(State);
        {redis_pipeline, Commands} when is_list(Commands) ->
            {_Reply, State} = execute_pipeline(Commands, maps:get(timeout, State0), State0, true),
            redis_worker_loop(State);
        {redis_pipeline_call, From, Ref, Commands, Timeout}
          when is_pid(From), is_list(Commands), is_integer(Timeout), Timeout > 0 ->
            {Reply, State} = execute_pipeline(Commands, Timeout, State0, true),
            From ! {redis_pipeline_reply, Ref, Reply},
            redis_worker_loop(State);
        {redis_stats, From, Ref} when is_pid(From) ->
            From ! {redis_worker_stats, Ref, local_stats(State0)},
            redis_worker_loop(State0);
        stop ->
            _ = close_socket(State0),
            ok;
        _ -> redis_worker_loop(State0)
    end.

worker_base_state(State) ->
    (maps:without([workers, pool_size], State))#{socket => undefined, transport => tcp,
        commands => 0, failures => 0, connects => 0, last_error => undefined}.

update_pool(Workers) ->
    case persistent_term:get({?MODULE, pool}, undefined) of
        {_OldEntries, Counter} ->
            persistent_term:put({?MODULE, pool},
                {[{worker, Pid} || Pid <- Workers], Counter});
        _ -> ok
    end.

aggregate_stats(State) ->
    Workers = maps:get(workers, State, []),
    Requests = [begin Ref = make_ref(), Pid ! {redis_stats, self(), Ref}, Ref end || Pid <- Workers],
    WorkerStats = collect_worker_stats(Requests, erlang:monotonic_time(millisecond) + 50, []),
    AsyncDropped = case persistent_term:get({?MODULE, pool}, undefined) of
        {_Entries, Counter} -> atomics:get(Counter, 2);
        _ -> 0
    end,
    #{enabled => maps:get(enabled, State),
      pool_size => maps:get(pool_size, State, 0),
      connected => lists:any(fun(S) -> maps:get(connected, S, false) end, WorkerStats),
      connected_workers => length([ok || S <- WorkerStats, maps:get(connected, S, false)]),
      commands => lists:sum([maps:get(commands, S, 0) || S <- WorkerStats]),
      failures => lists:sum([maps:get(failures, S, 0) || S <- WorkerStats]),
      connects => lists:sum([maps:get(connects, S, 0) || S <- WorkerStats]),
      async_dropped => AsyncDropped,
      async_queue_limit => redis_async_queue_limit(),
      sync_queue_limit => redis_sync_queue_limit(),
      worker_mailboxes => [queue_len(Pid) || Pid <- Workers]}.

collect_worker_stats([], _Deadline, Acc) -> Acc;
collect_worker_stats(Pending, Deadline, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of
        0 -> Acc;
        _ ->
            receive
                {redis_worker_stats, Ref, Stats} ->
                    case lists:member(Ref, Pending) of
                        true -> collect_worker_stats(lists:delete(Ref, Pending), Deadline, [Stats | Acc]);
                        false -> collect_worker_stats(Pending, Deadline, Acc)
                    end
            after Remaining -> Acc
            end
    end.

local_stats(State) ->
    #{connected => maps:get(socket, State, undefined) =/= undefined,
      commands => maps:get(commands, State, 0), failures => maps:get(failures, State, 0),
      connects => maps:get(connects, State, 0), last_error => maps:get(last_error, State, undefined)}.

queue_len(Pid) ->
    case process_info(Pid, message_queue_len) of {message_queue_len, N} -> N; _ -> -1 end.

execute(Args, Timeout, State0, Retry) ->
    case ensure_connected(State0) of
        {error, Reason, State1} -> {{error, Reason}, State1};
        {ok, State1} ->
            Socket = maps:get(socket, State1),
            Transport = maps:get(transport, State1),
            Packet = encode_command(Args),
            case sock_send(Transport, Socket, Packet) of
                ok ->
                    case recv_response(Transport, Socket, Timeout, <<>>) of
                        {ok, Value} -> {{ok, Value}, State1#{commands := maps:get(commands, State1) + 1, last_error => undefined}};
                        {error, Reason} -> retry_or_fail(Args, Timeout, Reason, State1, Retry)
                    end;
                {error, Reason} -> retry_or_fail(Args, Timeout, Reason, State1, Retry)
            end
    end.

retry_or_fail(Args, Timeout, Reason, State0, true) ->
    State1 = failed(Reason, close_socket(State0)),
    execute(Args, Timeout, State1, false);
retry_or_fail(_Args, _Timeout, Reason, State0, false) ->
    {{error, Reason}, failed(Reason, close_socket(State0))}.

execute_pipeline([], _Timeout, State, _Retry) -> {{ok, []}, State};
execute_pipeline(Commands, Timeout, State0, Retry) ->
    case ensure_connected(State0) of
        {error, Reason, State1} -> {{error, Reason}, State1};
        {ok, State1} ->
            Socket = maps:get(socket, State1),
            Transport = maps:get(transport, State1),
            Packet = [encode_command(Args) || Args <- Commands],
            case sock_send(Transport, Socket, Packet) of
                ok ->
                    case recv_responses(Transport, Socket, Timeout, length(Commands), <<>>, []) of
                        {ok, Values} ->
                            Count = length(Commands),
                            {{ok, Values}, State1#{commands := maps:get(commands, State1) + Count, last_error => undefined}};
                        {error, Reason} -> retry_pipeline_or_fail(Commands, Timeout, Reason, State1, Retry)
                    end;
                {error, Reason} -> retry_pipeline_or_fail(Commands, Timeout, Reason, State1, Retry)
            end
    end.

retry_pipeline_or_fail(Commands, Timeout, Reason, State0, true) ->
    State1 = failed(Reason, close_socket(State0)),
    execute_pipeline(Commands, Timeout, State1, false);
retry_pipeline_or_fail(_Commands, _Timeout, Reason, State0, false) ->
    {{error, Reason}, failed(Reason, close_socket(State0))}.

ensure_connected(State=#{socket := Socket}) when Socket =/= undefined -> {ok, State};
ensure_connected(State=#{enabled := false}) -> {error, disabled, State};
ensure_connected(State) ->
    Host = maps:get(host, State), Port = maps:get(port, State), Timeout = maps:get(timeout, State),
    case connect_socket(Host, Port, Timeout, State) of
        {ok, Transport, Socket} ->
            State1 = State#{transport => Transport, socket => Socket,
                            connects := maps:get(connects, State) + 1, last_error => undefined},
            case initialize_connection(State1) of
                {ok, Ready} -> {ok, Ready};
                {error, Reason, Failed} -> {error, Reason, failed(Reason, close_socket(Failed))}
            end;
        {error, Reason} -> {error, Reason, failed(Reason, State)}
    end.

initialize_connection(State) ->
    Username = maps:get(username, State, ""),
    Password = maps:get(password, State),
    AuthArgs = case {Username, Password} of
        {"", ""} -> none;
        {"", P} -> [<<"AUTH">>, unicode:characters_to_binary(P)];
        {U, P} when P =/= "" -> [<<"AUTH">>, unicode:characters_to_binary(U), unicode:characters_to_binary(P)];
        {_U, ""} -> invalid
    end,
    case AuthArgs of
        invalid -> {error, redis_password_required_for_username, State};
        _ ->
            case maybe_init_command(AuthArgs =/= none, AuthArgs, State) of
                {error, Reason, S1} -> {error, Reason, S1};
                {ok, S1} ->
                    Db = maps:get(database, S1),
                    maybe_init_command(Db =/= 0, [<<"SELECT">>, integer_to_binary(Db)], S1)
            end
    end.

maybe_init_command(false, _Args, State) -> {ok, State};
maybe_init_command(true, Args, State) ->
    Socket = maps:get(socket, State), Transport = maps:get(transport, State), Timeout = maps:get(timeout, State),
    case sock_send(Transport, Socket, encode_command(Args)) of
        ok ->
            case recv_response(Transport, Socket, Timeout, <<>>) of
                {ok, _} -> {ok, State};
                {error, Reason} -> {error, Reason, State}
            end;
        {error, Reason} -> {error, Reason, State}
    end.

connect_socket(Host0, Port, Timeout, State) ->
    Host = case inet:parse_address(Host0) of {ok, Ip} -> Ip; _ -> Host0 end,
    Opts = [binary, {active, false}, {packet, raw}, {nodelay, true}, {keepalive, true}],
    case maps:get(tls, State) of
        false ->
            case gen_tcp:connect(Host, Port, Opts, Timeout) of
                {ok, Socket} -> {ok, tcp, Socket};
                Error -> Error
            end;
        true ->
            SslOpts = ssl_options(Host0, State) ++ Opts,
            case ssl:connect(Host, Port, SslOpts, Timeout) of
                {ok, Socket} -> {ok, ssl, Socket};
                Error -> Error
            end
    end.

ssl_options(_Host, #{tls_insecure := true}) -> [{verify, verify_none}];
ssl_options(Host, _) ->
    Base = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}],
    case inet:parse_address(Host) of
        {ok, _} -> Base;
        _ -> [{server_name_indication, Host} | Base]
    end.

sock_send(tcp, Socket, Data) -> gen_tcp:send(Socket, Data);
sock_send(ssl, Socket, Data) -> ssl:send(Socket, Data).

sock_recv(tcp, Socket, Timeout) -> gen_tcp:recv(Socket, 0, Timeout);
sock_recv(ssl, Socket, Timeout) -> ssl:recv(Socket, 0, Timeout).

close_socket(State=#{socket := undefined}) -> State;
close_socket(State=#{transport := tcp, socket := Socket}) -> catch gen_tcp:close(Socket), State#{socket => undefined};
close_socket(State=#{transport := ssl, socket := Socket}) -> catch ssl:close(Socket), State#{socket => undefined}.

recv_response(_Transport, _Socket, _Timeout, Buffer) when byte_size(Buffer) > ?MAX_RESPONSE_BYTES ->
    {error, response_too_large};
recv_response(Transport, Socket, Timeout, Buffer) ->
    case parse_resp(Buffer) of
        {ok, Value, _Rest} -> {ok, Value};
        more ->
            case sock_recv(Transport, Socket, Timeout) of
                {ok, Chunk} -> recv_response(Transport, Socket, Timeout, <<Buffer/binary, Chunk/binary>>);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

recv_responses(_Transport, _Socket, _Timeout, 0, _Buffer, Acc) ->
    {ok, lists:reverse(Acc)};
recv_responses(_Transport, _Socket, _Timeout, _N, Buffer, _Acc)
  when byte_size(Buffer) > ?MAX_RESPONSE_BYTES ->
    {error, response_too_large};
recv_responses(Transport, Socket, Timeout, N, Buffer, Acc) ->
    case parse_resp(Buffer) of
        {ok, Value, Rest} -> recv_responses(Transport, Socket, Timeout, N - 1, Rest, [Value | Acc]);
        more ->
            case sock_recv(Transport, Socket, Timeout) of
                {ok, Chunk} -> recv_responses(Transport, Socket, Timeout, N, <<Buffer/binary, Chunk/binary>>, Acc);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

encode_command(Args) ->
    Bins = [to_binary(A) || A <- Args],
    [<<"*", (integer_to_binary(length(Bins)))/binary, "\r\n">> |
     [[<<"$", (integer_to_binary(byte_size(B)))/binary, "\r\n">>, B, <<"\r\n">>] || B <- Bins]].

parse_resp(<<>>) -> more;
parse_resp(<<$+, Rest/binary>>) -> parse_line_value(Rest, fun(V) -> V end);
parse_resp(<<$-, Rest/binary>>) ->
    case take_line(Rest) of {ok, V, Tail} -> {error, {redis, V, Tail}}; more -> more end;
parse_resp(<<$:, Rest/binary>>) ->
    case take_line(Rest) of
        {ok, V, Tail} -> case parse_integer(V) of {ok, N} -> {ok, N, Tail}; error -> {error, invalid_integer} end;
        more -> more
    end;
parse_resp(<<$$, Rest/binary>>) ->
    case take_line(Rest) of
        more -> more;
        {ok, <<"-1">>, Tail} -> {ok, undefined, Tail};
        {ok, LenBin, Tail} ->
            case parse_integer(LenBin) of
                {ok, Len} when Len >= 0, byte_size(Tail) >= Len + 2 ->
                    <<Value:Len/binary, "\r\n", Rem/binary>> = Tail,
                    {ok, Value, Rem};
                {ok, Len} when Len >= 0 -> more;
                _ -> {error, invalid_bulk_length}
            end
    end;
parse_resp(<<$*, Rest/binary>>) ->
    case take_line(Rest) of
        more -> more;
        {ok, <<"-1">>, Tail} -> {ok, undefined, Tail};
        {ok, CountBin, Tail} ->
            case parse_integer(CountBin) of
                {ok, Count} when Count >= 0 -> parse_array(Count, Tail, []);
                _ -> {error, invalid_array_length}
            end
    end;
parse_resp(_) -> {error, invalid_response}.

parse_line_value(Rest, Fun) ->
    case take_line(Rest) of {ok, V, Tail} -> {ok, Fun(V), Tail}; more -> more end.

take_line(Bin) ->
    case binary:match(Bin, <<"\r\n">>) of
        nomatch -> more;
        {Pos, 2} -> <<Line:Pos/binary, "\r\n", Tail/binary>> = Bin, {ok, Line, Tail}
    end.

parse_array(0, Tail, Acc) -> {ok, lists:reverse(Acc), Tail};
parse_array(N, Bin, Acc) ->
    case parse_resp(Bin) of
        {ok, Value, Tail} -> parse_array(N - 1, Tail, [Value | Acc]);
        more -> more;
        {error, Reason} -> {error, Reason}
    end.

parse_integer(Bin) ->
    try {ok, binary_to_integer(Bin)} catch _:_ -> error end.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V).

redis_key(Namespace, Raw0) ->
    Raw = to_binary(Raw0),
    Prefix = unicode:characters_to_binary(os:getenv("PLAINWIRE_REDIS_PREFIX", "plainwire")),
    Digest = binary:encode_hex(crypto:hash(sha256, Raw), lowercase),
    <<Prefix/binary, $:, Namespace/binary, $:, Digest/binary>>.

%% pw_hub:effective_status/3 hands these over as binaries, and "invisible" has
%% to survive the trip: presence_set/3's script treats it as "remove this node's
%% field", which is how a user who went invisible — or whose last socket closed —
%% stops being published. Without an explicit clause it fell through to the
%% catch-all and was rewritten to <<"online">>, so the script never saw
%% 'invisible', the HDEL branch was unreachable, and an invisible account was
%% broadcast to every other node as online until its field expired.
safe_status(online) -> <<"online">>;
safe_status(away) -> <<"away">>;
safe_status(busy) -> <<"busy">>;
safe_status(invisible) -> <<"invisible">>;
safe_status(<<"online">>) -> <<"online">>;
safe_status(<<"away">>) -> <<"away">>;
safe_status(<<"busy">>) -> <<"busy">>;
safe_status(<<"invisible">>) -> <<"invisible">>;
safe_status(_) -> <<"online">>.

normalize_presence(<<"away">>) -> <<"away">>;
normalize_presence(<<"busy">>) -> <<"busy">>;
normalize_presence(_) -> <<"online">>.

chunk_list([], _) -> [];
chunk_list(List, N) when N > 0 ->
    {Head, Tail} = lists:split(min(N, length(List)), List),
    [Head | chunk_list(Tail, N)].

configured() ->
    case string:lowercase(os:getenv("PLAINWIRE_REDIS_ENABLED", "false")) of
        "1" -> true; "true" -> true; "yes" -> true; "on" -> true; _ -> false
    end.

timeout_ms() -> env_range("PLAINWIRE_REDIS_TIMEOUT_MS", ?DEFAULT_TIMEOUT, 20, 2000).

env_bool(Name, Default) ->
    DefaultString = case Default of true -> "true"; false -> "false" end,
    case string:lowercase(os:getenv(Name, DefaultString)) of
        "1" -> true; "true" -> true; "yes" -> true; "on" -> true; _ -> false
    end.

env_range(Name, Default, Min, Max) ->
    Value = pw_util:env_int(Name, Default),
    erlang:min(Max, erlang:max(Min, Value)).

failed(Reason, State) ->
    logger:warning("[plainwire:redis] command/connect failed: ~p", [Reason]),
    State#{failures := maps:get(failures, State) + 1, last_error => Reason}.
