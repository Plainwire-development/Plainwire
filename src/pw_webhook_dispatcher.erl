-module(pw_webhook_dispatcher).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TICK_MS, 750).
-define(TIMEOUT_GRACE_MS, 100).
-define(PRUNE_MS, 3600000).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(?TICK_MS, self(), tick),
    erlang:send_after(60000, self(), prune),
    DeliveryTimeout = min(30000, max(2000, pw_util:env_int("PLAINWIRE_WEBHOOK_TIMEOUT_MS", 8000))),
    ConfiguredWorkerTimeout = pw_util:env_int("PLAINWIRE_WEBHOOK_WORKER_TIMEOUT_MS", DeliveryTimeout + 5000),
    %% webhook_claim_due/1 uses a 60s recovery lease. Keep the hard worker
    %% deadline strictly below that lease so a stuck worker is killed and its
    %% row is returned to the normal retry path before another node can reclaim
    %% the same delivery.
    WorkerTimeout = min(45000, max(DeliveryTimeout + 2000, ConfiguredWorkerTimeout)),
    {ok, #{workers => #{},
           max => max(1, min(32, pw_util:env_int("PLAINWIRE_WEBHOOK_CONCURRENCY", 8))),
           worker_timeout => WorkerTimeout}}.

handle_call(_Msg, _From, State) -> {reply, {error, unsupported}, State}.
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(tick, #{workers := Workers, max := Max, worker_timeout := WorkerTimeout} = State) ->
    erlang:send_after(?TICK_MS, self(), tick),
    Capacity = max(0, Max - map_size(Workers)),
    case Capacity > 0 of
        false -> {noreply, State};
        true ->
            Jobs = case pw_db:webhook_claim_due(Capacity) of {ok, J} when is_list(J) -> J; _ -> [] end,
            NewWorkers = lists:foldl(fun(Job, Acc) ->
                Parent = self(),
                {Pid, Ref} = spawn_monitor(fun() ->
                    Started = erlang:monotonic_time(millisecond),
                    Result = deliver(Job),
                    Latency = max(0, erlang:monotonic_time(millisecond) - Started),
                    Parent ! {webhook_result, self(), Result, Latency}
                end),
                Timer = erlang:send_after(WorkerTimeout, Parent, {webhook_worker_timeout, Pid, Ref}),
                Acc#{Pid => {Ref, maps:get(id, Job), Timer}}
            end, Workers, Jobs),
            {noreply, State#{workers => NewWorkers}}
    end;
handle_info({webhook_result, Pid, Result, Latency}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{Ref, DeliveryId, Timer}, Rest} ->
            _ = erlang:cancel_timer(Timer),
            erlang:demonitor(Ref, [flush]),
            _ = finish(DeliveryId, Result, Latency),
            {noreply, State#{workers => Rest}};
        error -> {noreply, State}
    end;
handle_info({webhook_worker_timeout, Pid, Ref}, #{workers := Workers} = State) ->
    case maps:find(Pid, Workers) of
        {ok, {Ref, DeliveryId, _Timer}} ->
            %% A result and this timeout are sent by different processes, so a
            %% worker that has just finished can lose the mailbox race by a few
            %% scheduler ticks. Give completion/DOWN a tiny grace period before
            %% enforcing the deadline. The total deadline still stays far below
            %% the durable 60s claim lease.
            Grace = erlang:send_after(?TIMEOUT_GRACE_MS, self(),
                                      {webhook_worker_enforce_timeout, Pid, Ref}),
            {noreply, State#{workers => Workers#{Pid => {Ref, DeliveryId, Grace}}}};
        {ok, {_OtherRef, _DeliveryId, _Timer}} ->
            %% Stale timeout from an older worker incarnation.
            {noreply, State};
        error -> {noreply, State}
    end;
handle_info({webhook_worker_enforce_timeout, Pid, Ref}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{Ref, DeliveryId, _Timer}, Rest} ->
            %% The row lease is longer than this deadline. Stop the actual
            %% request before returning it to durable retry state so duplicate
            %% concurrent deliveries cannot be created by lease recovery.
            catch exit(Pid, kill),
            erlang:demonitor(Ref, [flush]),
            _ = pw_db:webhook_finish(DeliveryId, {error, <<"worker_timeout">>, 0}),
            {noreply, State#{workers => Rest}};
        {{OtherRef, DeliveryId, Timer}, Rest} ->
            {noreply, State#{workers => Rest#{Pid => {OtherRef, DeliveryId, Timer}}}};
        error -> {noreply, State}
    end;
handle_info(prune, State) ->
    _ = pw_db:webhook_prune(),
    erlang:send_after(?PRUNE_MS, self(), prune),
    {noreply, State};
handle_info({'DOWN', _Ref, process, Pid, Reason}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{_OldRef, DeliveryId, Timer}, Rest} ->
            _ = erlang:cancel_timer(Timer),
            _ = pw_db:webhook_finish(DeliveryId, {error, pw_util:clean_text(io_lib:format("worker_exit:~p", [Reason]), 500)}),
            {noreply, State#{workers => Rest}};
        error -> {noreply, State}
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

finish(Id, {ok, Code}, Latency) -> pw_db:webhook_finish(Id, {ok, Code, Latency});
finish(Id, {error, Reason}, Latency) -> pw_db:webhook_finish(Id, {error, pw_util:clean_text(Reason, 500), Latency}).

deliver(#{url := Url, secret := Secret, payload := Payload, event := Event, id := Id}) ->
    case pw_outbound_url:resolve_allowed(Url) of
        {error, _} -> {error, <<"blocked_webhook_url">>};
        {ok, Target} ->
            Signature = <<"sha256=", (pw_util:hex_binary(crypto:mac(hmac, sha256, Secret, Payload)))/binary>>,
            Timeout = min(30000, max(2000, pw_util:env_int("PLAINWIRE_WEBHOOK_TIMEOUT_MS", 8000))),
            deliver_gun(Target, Payload, Event, Id, Signature, Timeout)
    end.

deliver_gun(#{host := Host, address := Address, port := Port, scheme := Scheme, path := Path}, Payload, Event, Id, Signature, Timeout) ->
    Transport = case Scheme of <<"https">> -> tls; _ -> tcp end,
    OpenOpts0 = #{transport => Transport, connect_timeout => min(3000, Timeout)},
    OpenOpts = case Transport of
        tls -> OpenOpts0#{tls_opts => tls_options(Host)};
        tcp -> OpenOpts0
    end,
    case gun:open(Address, Port, OpenOpts) of
        {ok, ConnPid} ->
            try
                case gun:await_up(ConnPid, min(3000, Timeout)) of
                    {ok, _Protocol} ->
                        Headers = [
                            {<<"host">>, host_header(Host, Scheme, Port)},
                            {<<"content-type">>, <<"application/json">>},
                            {<<"user-agent">>, <<"Plainwire-Webhook/2.1">>},
                            {<<"x-plainwire-event">>, Event},
                            {<<"x-plainwire-delivery">>, integer_to_binary(Id)},
                            {<<"x-plainwire-signature">>, Signature}
                        ],
                        StreamRef = gun:request(ConnPid, <<"POST">>, Path, Headers, Payload),
                        await_response(ConnPid, StreamRef, Timeout);
                    {error, Reason} -> {error, format_reason(Reason)}
                end
            after
                catch gun:close(ConnPid)
            end;
        {error, Reason} -> {error, format_reason(Reason)}
    end.

await_response(ConnPid, StreamRef, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    await_final_response(ConnPid, StreamRef, Deadline).

await_final_response(ConnPid, StreamRef, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Remaining of
        0 -> {error, <<"timeout">>};
        _ ->
            case gun:await(ConnPid, StreamRef, Remaining) of
                {inform, _Status, _Headers} -> await_final_response(ConnPid, StreamRef, Deadline);
                {response, _Fin, Code, _Headers} when Code >= 200, Code < 300 -> {ok, Code};
                {response, _Fin, Code, _Headers} -> {error, iolist_to_binary(io_lib:format("http_~B", [Code]))};
                {error, Reason} -> {error, format_reason(Reason)};
                Other -> {error, format_reason(Other)}
            end
    end.

host_header(Host, Scheme, Port) ->
    Default = case Scheme of <<"https">> -> 443; _ -> 80 end,
    AuthorityHost = case binary:match(Host, <<":">>) of
        nomatch -> Host;
        _ -> <<"[", Host/binary, "]">>
    end,
    case Port =:= Default of
        true -> AuthorityHost;
        false -> <<AuthorityHost/binary, ":", (integer_to_binary(Port))/binary>>
    end.

tls_options(Host) ->
    %% Fail closed if the host trust store is unavailable. A worker should report
    %% a TLS failure, not crash or fall back to an unverifiable connection.
    CAs = try public_key:cacerts_get() catch _:_ -> [] end,
    Base = [{verify, verify_peer}, {cacerts, CAs},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _} -> Base;
        _ -> [{server_name_indication, binary_to_list(Host)} | Base]
    end.

format_reason(Reason) ->
    pw_util:clean_text(io_lib:format("~p", [Reason]), 500).
