-module(pw_redis).
-behaviour(gen_server).

-export([start_link/0, enabled/0, command/1, command/2, cast_command/1,
         rate_allow/3, presence_set/3, presence_get/1, presence_delete/1, cache_put/3, cache_get/1,
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
    case whereis(?MODULE) of
        undefined -> {error, unavailable};
        _ ->
            try gen_server:call(?MODULE, {command, Args, Timeout}, Timeout + 100)
            catch exit:_ -> {error, unavailable} end
    end.

cast_command(Args) when is_list(Args) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _ -> gen_server:cast(?MODULE, {command, Args}), ok
    end.

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
    Key = redis_key(<<"presence">>, integer_to_binary(Uid)),
    Owner = presence_owner(),
    Now = pw_util:now_ms(),
    %% Presence is stored per Plainwire node, not as one user-wide scalar. That
    %% prevents one websocket node from overwriting another node that still has
    %% an active session for the same account. Each field carries its own expiry
    %% deadline; readers prune stale fields atomically. Invisible means this node
    %% has no visible session and therefore removes only its own field.
    Script = <<"local owner=ARGV[1]; local status=ARGV[2]; local now=tonumber(ARGV[3]); local ttl=tonumber(ARGV[4]); "
               "if status=='invisible' then redis.call('HDEL',KEYS[1],owner); if redis.call('HLEN',KEYS[1])==0 then redis.call('DEL',KEYS[1]) end; return 1 end; "
               "redis.call('HSET',KEYS[1],owner,status..'|'..tostring(now+ttl)); redis.call('PEXPIRE',KEYS[1],ttl*2); return 1">>,
    cast_command([<<"EVAL">>, Script, <<"1">>, Key, Owner, Status, integer_to_binary(Now), integer_to_binary(TtlMs)]);
presence_set(_, _, _) -> ok.

presence_get(Uids0) when is_list(Uids0) ->
    Uids = lists:usort([U || U <- Uids0, is_integer(U), U > 0]),
    case Uids of
        [] -> #{};
        _ ->
            Keys = [redis_key(<<"presence">>, integer_to_binary(U)) || U <- Uids],
            %% One Lua call keeps a large presence-watch request to one network
            %% round trip. Stale node fields are removed while reading. Status
            %% precedence matches pw_hub: effective_status/3.
            Script = <<"local now=tonumber(ARGV[1]); local out={}; "
                       "for k=1,#KEYS do local vals=redis.call('HGETALL',KEYS[k]); local best=false; local rank=0; "
                       "for i=1,#vals,2 do local v=vals[i+1]; local sep=string.find(v,'|',1,true); "
                       "if sep then local st=string.sub(v,1,sep-1); local exp=tonumber(string.sub(v,sep+1)) or 0; "
                       "if exp<=now then redis.call('HDEL',KEYS[k],vals[i]); else local r=(st=='busy' and 3) or (st=='online' and 2) or (st=='away' and 1) or 0; if r>rank then rank=r; best=st end end end end; "
                       "if redis.call('HLEN',KEYS[k])==0 then redis.call('DEL',KEYS[k]) end; out[k]=best; end; return out">>,
            case command([<<"EVAL">>, Script, integer_to_binary(length(Keys)) | Keys] ++ [integer_to_binary(pw_util:now_ms())]) of
                {ok, Values} when is_list(Values), length(Values) =:= length(Uids) ->
                    maps:from_list([{U, normalize_presence(V)} || {U, V} <- lists:zip(Uids, Values), is_binary(V)]);
                _ -> #{}
            end
    end.

presence_delete(Uid) when is_integer(Uid), Uid > 0 ->
    cast_command([<<"DEL">>, redis_key(<<"presence">>, integer_to_binary(Uid))]);
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
    State = #{enabled => Enabled, socket => undefined, transport => tcp,
              host => os:getenv("PLAINWIRE_REDIS_HOST", "127.0.0.1"),
              port => env_range("PLAINWIRE_REDIS_PORT", ?DEFAULT_PORT, 1, 65535),
              tls => env_bool("PLAINWIRE_REDIS_TLS", false),
              tls_insecure => env_bool("PLAINWIRE_REDIS_TLS_INSECURE", false),
              username => os:getenv("PLAINWIRE_REDIS_USERNAME", ""),
              password => os:getenv("PLAINWIRE_REDIS_PASSWORD", ""),
              database => env_range("PLAINWIRE_REDIS_DB", 0, 0, 15),
              timeout => timeout_ms(),
              commands => 0, failures => 0, connects => 0, last_error => undefined},
    case Enabled of
        true -> self() ! warm_connect;
        false -> ok
    end,
    {ok, State}.

handle_call(enabled, _, State) -> {reply, maps:get(enabled, State), State};
handle_call(stats, _, State) ->
    Reply = maps:with([enabled, commands, failures, connects, last_error], State),
    {reply, Reply#{connected => maps:get(socket, State) =/= undefined}, State};
handle_call({command, _Args, _Timeout}, _, State=#{enabled := false}) ->
    {reply, {error, disabled}, State};
handle_call({command, Args, Timeout}, _, State0) ->
    {Reply, State} = execute(Args, Timeout, State0, true),
    {reply, Reply, State};
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.

handle_cast({command, _Args}, State=#{enabled := false}) -> {noreply, State};
handle_cast({command, Args}, State0) ->
    {_Reply, State} = execute(Args, maps:get(timeout, State0), State0, false),
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
handle_info(_, State) -> {noreply, State}.

terminate(_, State) -> _ = close_socket(State), ok.
code_change(_, State, _) -> {ok, State}.

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

safe_status(online) -> <<"online">>;
safe_status(away) -> <<"away">>;
safe_status(busy) -> <<"busy">>;
safe_status(<<"away">>) -> <<"away">>;
safe_status(<<"busy">>) -> <<"busy">>;
safe_status(_) -> <<"online">>.

normalize_presence(<<"away">>) -> <<"away">>;
normalize_presence(<<"busy">>) -> <<"busy">>;
normalize_presence(_) -> <<"online">>.

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
