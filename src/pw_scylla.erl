-module(pw_scylla).
-behaviour(gen_server).

-export([start_link/0, enabled/0, ready/0, health/0, execute/3, reconnect/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {cfg = #{}, status = disabled, last_error = undefined,
             connected_at = 0, retry_ms = 1000, reconnect_ref = undefined}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
enabled() -> pw_scylla_config:enabled().

ready() ->
    %% Hot-path readiness must stay cheap. The full health snapshot includes
    %% driver metrics and gate diagnostics and is intentionally reserved for
    %% admin/diagnostic calls.
    try gen_server:call(?MODULE, ready, 1000)
    catch _:_ -> false end.

health() ->
    try gen_server:call(?MODULE, health, 2500)
    catch _:_ -> #{status => unavailable, enabled => enabled()} end.

reconnect() -> gen_server:cast(?MODULE, reconnect).

execute(Key, Statement, Params) when is_atom(Statement), is_list(Params) ->
    Cfg = pw_scylla_config:config(),
    Timeout = maps:get(operation_timeout_ms, Cfg, 8000),
    pw_scylla_gate:run(Key, fun() -> timed(Statement, fun() -> do_execute(Statement, Params) end) end, Timeout).


init([]) ->
    process_flag(trap_exit, true),
    Cfg = pw_scylla_config:config(),
    case maps:get(enabled, Cfg, false) of
        false -> {ok, #st{cfg = Cfg, status = disabled}};
        true ->
            self() ! connect,
            {ok, #st{cfg = Cfg, status = connecting}}
    end.

handle_call(ready, _From, S) ->
    {reply, S#st.status =:= healthy, S};
handle_call(health, _From, S) ->
    Gate = pw_scylla_gate:stats(),
    {reply, #{enabled => maps:get(enabled, S#st.cfg, false),
              backend => maps:get(backend, S#st.cfg, postgres),
              status => S#st.status,
              last_error => S#st.last_error,
              connected_at => S#st.connected_at,
              gate => Gate,
              metrics => json_metrics(pw_storage_metrics:snapshot()),
              driver_metrics => driver_metrics(S#st.status)}, S};
handle_call(_Req, _From, S) -> {reply, {error, bad_request}, S}.

handle_cast(reconnect, S0) ->
    cancel_retry(S0#st.reconnect_ref),
    self() ! connect,
    {noreply, S0#st{status = connecting, reconnect_ref = undefined}};
handle_cast({operation_error, Reason}, S0) ->
    Safe = sanitize_reason(Reason),
    case S0#st.status of
        healthy ->
            Ref = erlang:send_after(1000, self(), connect),
            {noreply, S0#st{status = degraded, last_error = Safe, reconnect_ref = Ref}};
        _ -> {noreply, S0#st{last_error = Safe}}
    end;
handle_cast(_Msg, S) -> {noreply, S}.

handle_info(connect, S0 = #st{cfg = Cfg}) ->
    case connect_driver(Cfg) of
        ok ->
            logger:notice("[plainwire:scylla] connected contact_points=~p keyspace=~p", [length(maps:get(contact_points, Cfg)), maps:get(keyspace, Cfg)]),
            pw_storage_metrics:set_gauge(scylla_connected, 1),
            {noreply, S0#st{status = healthy, last_error = undefined, connected_at = pw_util:now_ms(), retry_ms = 1000, reconnect_ref = undefined}};
        {error, Reason} ->
            Safe = sanitize_reason(Reason),
            logger:warning("[plainwire:scylla] unavailable reason=~p; PostgreSQL compatibility path remains available", [Safe]),
            pw_storage_metrics:set_gauge(scylla_connected, 0),
            Ref = erlang:send_after(jitter(S0#st.retry_ms), self(), connect),
            Next = erlang:min(60000, S0#st.retry_ms * 2),
            {noreply, S0#st{status = unavailable, last_error = Safe, retry_ms = Next, reconnect_ref = Ref}}
    end;
handle_info(_Info, S) -> {noreply, S}.

terminate(_Reason, _S) ->
    case application:stop(erlcass) of _ -> ok end,
    ok.
code_change(_Old, State, _Extra) -> {ok, State}.

connect_driver(Cfg) ->
    case pw_scylla_config:validate() of
        ok ->
            try
                application:set_env(erlcass, log_level, 3),
                application:set_env(erlcass, keyspace, maps:get(keyspace, Cfg)),
                application:set_env(erlcass, cluster_options, cluster_options(Cfg)),
                case application:ensure_all_started(erlcass) of
                    {ok, _} -> health_query_and_prepare();
                    {error, {already_started, erlcass}} -> health_query_and_prepare();
                    {error, Reason} -> {error, Reason}
                end
            catch C:R -> {error, {C, R}} end;
        Error -> Error
    end.

health_query_and_prepare() ->
    case erlcass:query(<<"SELECT release_version FROM system.local">>) of
        {ok, _Cols, _Rows} -> prepare_statements();
        Other -> {error, {health_query_failed, Other}}
    end.

prepare_statements() ->
    Statements = pw_scylla_statements:all(),
    lists:foldl(fun({Name, Cql}, ok) ->
                        case erlcass:add_prepare_statement(Name, Cql) of
                            ok -> ok;
                            {error, already_exists} -> ok;
                            Other -> {error, {prepare_failed, Name, Other}}
                        end;
                   (_, Error) -> Error
                end, ok, Statements).

do_execute(Statement, Params) ->
    case ready() of
        false -> {error, scylla_unavailable};
        true ->
            try erlcass:execute(Statement, Params) of
                ok -> ok;
                {ok, _Cols, _Rows} = Ok -> Ok;
                {error, _} = Error -> Error;
                Other -> {error, {unexpected_result, Other}}
            catch C:R -> {error, {C, sanitize_reason(R)}} end
    end.


timed(Operation, Fun) ->
    Started = erlang:monotonic_time(microsecond),
    Result = Fun(),
    Outcome = case Result of ok -> ok; {ok, _, _} -> ok; {error, _} -> error; _ -> error end,
    pw_storage_metrics:observe(Operation, Outcome, erlang:monotonic_time(microsecond) - Started),
    case Result of {error, Reason} -> gen_server:cast(?MODULE, {operation_error, Reason}); _ -> ok end,
    Result.

driver_metrics(healthy) ->
    try sanitize_driver_metrics(erlcass:get_metrics(), 0)
    catch _:_ -> #{} end;
driver_metrics(_) -> #{}.

sanitize_driver_metrics(_Value, Depth) when Depth > 4 -> undefined;
sanitize_driver_metrics(Value, _Depth) when is_integer(Value); is_float(Value); is_boolean(Value) -> Value;
sanitize_driver_metrics(Value, _Depth) when is_atom(Value) -> atom_to_binary(Value, utf8);
sanitize_driver_metrics(Value, _Depth) when is_binary(Value) ->
    binary:part(Value, 0, erlang:min(byte_size(Value), 128));
sanitize_driver_metrics(Map, Depth) when is_map(Map) ->
    Pairs = lists:sublist(maps:to_list(Map), 128),
    maps:from_list([{safe_metric_key(K), sanitize_driver_metrics(V, Depth + 1)} || {K,V} <- Pairs]);
sanitize_driver_metrics(List, Depth) when is_list(List) ->
    [sanitize_driver_metrics(V, Depth + 1) || V <- lists:sublist(List, 128)];
sanitize_driver_metrics(Tuple, Depth) when is_tuple(Tuple) ->
    sanitize_driver_metrics(tuple_to_list(Tuple), Depth + 1);
sanitize_driver_metrics(_, _) -> undefined.

safe_metric_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
safe_metric_key(K) when is_binary(K) -> binary:part(K, 0, erlang:min(byte_size(K), 128));
safe_metric_key(K) when is_integer(K) -> integer_to_binary(K);
safe_metric_key(_) -> <<"metric">>.

cluster_options(Cfg) ->
    Contacts = iolist_to_binary(lists:join($,, maps:get(contact_points, Cfg))),
    Base0 = [{contact_points, Contacts},
             {port, maps:get(port, Cfg)},
             {protocol_version, 4},
             {token_aware_routing, true},
             {token_aware_routing_shuffle_replicas, true},
             {latency_aware_routing, true},
             {number_threads_io, maps:get(io_threads, Cfg)},
             {queue_size_io, maps:get(queue_size, Cfg)},
             {core_connections_host, maps:get(pool_size, Cfg)},
             {tcp_nodelay, true},
             {tcp_keepalive, {true, 60}},
             {heartbeat_interval, 30},
             {idle_timeout, 60},
             {connect_timeout, maps:get(connect_timeout_ms, Cfg)},
             {request_timeout, maps:get(request_timeout_ms, Cfg)},
             {exponential_reconnect, {1000, 60000}},
             {retry_policy, {default, false}},
             {default_consistency_level, consistency_value(maps:get(consistency, Cfg))}],
    Base1 = case maps:get(local_dc, Cfg, <<>>) of
        <<>> -> Base0;
        Dc -> [{load_balance_dc_aware, {Dc, 0, false}} | Base0]
    end,
    Base2 = case {maps:get(username, Cfg, <<>>), maps:get(password, Cfg, <<>>)} of
        {<<>>, <<>>} -> Base1;
        {User, Pass} when User =/= <<>>, Pass =/= <<>> -> [{credentials, {User, Pass}} | Base1];
        _ -> erlang:error(incomplete_scylla_credentials)
    end,
    case maps:get(tls, Cfg, false) of
        false -> Base2;
        true -> [{ssl, ssl_options(Cfg)} | Base2]
    end.

ssl_options(Cfg) ->
    Ca = read_required_file(maps:get(ca_file, Cfg), ca_file),
    Base = [{trusted_certs, [Ca]}, {verify_flags, 3}],
    case {maps:get(cert_file, Cfg, <<>>), maps:get(key_file, Cfg, <<>>)} of
        {<<>>, <<>>} -> Base;
        {CertPath, KeyPath} when CertPath =/= <<>>, KeyPath =/= <<>> ->
            Cert = read_required_file(CertPath, cert_file),
            Key = read_required_file(KeyPath, key_file),
            [{cert, Cert}, {private_key, {Key, <<>>}} | Base];
        _ -> erlang:error(incomplete_scylla_client_certificate)
    end.

read_required_file(Path, Kind) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Bin} -> Bin;
        {error, Reason} -> erlang:error({Kind, Reason})
    end.

%% DataStax consistency enum values used by erlcass.
consistency_value(one) -> 1;
consistency_value(quorum) -> 4;
consistency_value(local_quorum) -> 6;
consistency_value(local_one) -> 10.

jitter(Base) -> Base + rand:uniform(erlang:max(1, Base div 5)) - erlang:max(1, Base div 10).
cancel_retry(undefined) -> ok;
cancel_retry(Ref) -> erlang:cancel_timer(Ref), ok.
sanitize_reason(R) -> pw_storage_sanitize:safe_reason(R).

json_metrics(Metrics) when is_map(Metrics) ->
    [#{metric => pw_util:clean_text(io_lib:format("~0p", [Key]), 160), value => Value}
     || {Key, Value} <- maps:to_list(Metrics), is_integer(Value) orelse is_float(Value)].
