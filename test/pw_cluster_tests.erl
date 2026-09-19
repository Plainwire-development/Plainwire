-module(pw_cluster_tests).
-include_lib("eunit/include/eunit.hrl").

local_without_manager_test() ->
    {ok, Hub} = start_test_hub(),
    Parent = self(),
    Socket = spawn(fun() -> cluster_socket_loop(Parent) end),
    try
        pw_hub:connect(17017, Socket, <<"online">>),
        gen_server:call(pw_hub, sync),
        pw_hub:subscribe(Socket, {direct, 17}),
        gen_server:call(pw_hub, sync),
        ok = pw_cluster:broadcast({direct, 17}, event()),
        receive
            {cluster_message_created, Socket, _Payload} -> ok
        after 500 ->
            ?assert(false)
        end
    after
        Socket ! stop,
        stop_test_hub(Hub)
    end.

wire_validation_test() ->
    Now = erlang:system_time(millisecond),
    Boot = <<0:128>>,
    E = pw_cluster_wire:encode(api, Boot, 1, Now, {topic, {direct, 17}}, event()),
    ?assertMatch({ok, _, _, _}, pw_cluster_wire:decode(E, [api], Now)),
    ?assertMatch({error, _}, pw_cluster_wire:decode(E, [other], Now)),
    ?assertMatch({error, _}, pw_cluster_wire:decode(E, [api], Now + 16000)),
    ?assertMatch({error, _}, pw_cluster_wire:decode(E, [api], Now - 6000)),
    ?assertMatch({error, _}, pw_cluster_wire:decode({arbitrary, self()}, [api], Now)),
    Bad = pw_cluster_wire:encode(api, Boot, 2, Now, {topic, {direct, 17}}, (event())#{pid => self()}),
    ?assertMatch({error, _}, pw_cluster_wire:decode(Bad, [api], Now)),
    ?assertEqual(false, pw_cluster_wire:allowed({user, 1}, #{type => call_signal})),
    ?assertEqual(true, pw_cluster_wire:allowed({user, 1}, #{type => mention, scope => direct})),
    ?assertEqual(true, pw_cluster_wire:allowed({topic, {system, global}}, #{type => system_banners_changed})),
    ?assertEqual(true, pw_cluster_wire:allowed({topic, {system, global}}, #{type => service_settings_changed})),
    ?assertEqual(true, pw_cluster_wire:allowed({topic, {system, global}}, #{type => realtime_resync})),
    ?assertEqual(false, pw_cluster_wire:allowed({topic, {system, global}}, #{type => arbitrary_admin_event})),
    ?assertEqual(true, pw_cluster_wire:allowed({control, revoke_server_access},
        #{uid => 1, server_id => 2, channel_ids => lists:seq(1, 512)})),
    ?assertEqual(false, pw_cluster_wire:allowed({control, revoke_server_access},
        #{uid => 1, server_id => 2, channel_ids => lists:seq(1, 513)})),
    ?assertEqual(false, pw_cluster_wire:allowed({control, revoke_server_access},
        #{uid => 1, server_id => 2, channel_ids => [3 | malformed_tail]})),
    Huge = pw_cluster_wire:encode(api, Boot, 3, Now, {user, 1}, #{type => direct_message, data => binary:copy(<<0>>, 140000)}),
    ?assertMatch({error, _}, pw_cluster_wire:decode(Huge, [api], Now)).

secure_configuration_test() ->
    ?assertEqual(ok, pw_cluster_config:validate(#{backend => local})),
    ?assertMatch({error, _}, pw_cluster_config:validate(#{backend => partisan})),
    ?assert(pw_cluster_config:private_ip({127, 0, 0, 1})),
    ?assert(pw_cluster_config:private_ip({10, 4, 2, 1})),
    ?assertNot(pw_cluster_config:private_ip({0, 0, 0, 0})),
    ?assertNot(pw_cluster_config:private_ip({8, 8, 8, 8})),
    ?assertNot(pw_cluster_config:private_ip({10, 1000, 0, 1})),
    C = owner_config(),
    ?assertMatch({error, _}, pw_cluster_config:validate(C#{listen_ip => {0,0,0,0}})),
    ?assertMatch({error, _}, pw_cluster_config:validate(C#{cacertfile => "/no/such/ca"})).

duplicate_expiry_and_rejoin_test() ->
    C = owner_config(),
    application:set_env(plainwire_relay, cluster, C),
    {ok, Hub} = start_test_hub(),
    Parent = self(),
    Socket = spawn(fun() -> cluster_socket_loop(Parent) end),
    {ok, Cluster} = pw_cluster:start_link(C, pw_cluster_test_transport),
    try
        pw_hub:connect(17017, Socket, <<"online">>),
        gen_server:call(pw_hub, sync),
        pw_hub:subscribe(Socket, {direct, 17}),
        gen_server:call(pw_hub, sync),
        Now = erlang:system_time(millisecond),
        E = pw_cluster_wire:encode(api, <<1:128>>, 1, Now, {topic, {direct, 17}}, event()),
        Cluster ! E, Cluster ! E,
        receive
            {cluster_message_created, Socket, _} -> ok
        after 500 ->
            ?assert(false)
        end,
        receive
            {cluster_message_created, Socket, _DuplicatePayload} -> ?assert(false)
        after 30 ->
            ok
        end,
        %% A restarted peer may begin its sequence at 1 with a new boot ID.
        Cluster ! pw_cluster_wire:encode(api, <<2:128>>, 1, Now, {topic, {direct, 17}}, event()),
        receive
            {cluster_message_created, Socket, _} -> ok
        after 500 ->
            ?assert(false)
        end,
        ?assertEqual(2, maps:get(received, pw_cluster:status())),
        ?assertEqual(1, maps:get(dropped, pw_cluster:status())),
        %% Node leases expire, without changing hub presence or local call state.
        sys:replace_state(Cluster, fun(S) -> S#{peers => #{api => {<<1:128>>, Now - 20000}}} end),
        Cluster ! tick,
        _ = pw_cluster:status(),
        ?assertEqual(#{}, maps:get(peers, sys:get_state(Cluster)))
    after
        Socket ! stop,
        gen_server:stop(Cluster),
        stop_test_hub(Hub),
        application:unset_env(plainwire_relay, cluster)
    end.

outbound_and_failure_test() ->
    C = (owner_config())#{name => api, realtime_node => owner, peers => [#{name => owner, ip => {127,0,0,1}, port => 9911}]},
    application:set_env(plainwire_relay, cluster, C),
    application:set_env(plainwire_relay, test_transport_sink, self()),
    os:putenv("PLAINWIRE_CLUSTER_OUTBOX_LIMIT", "256"),
    {ok, Hub} = start_test_hub(),
    {ok, Cluster} = pw_cluster:start_link(C, pw_cluster_test_transport),
    try
        _ = pw_cluster:status(),
        ?assertEqual(false, pw_cluster_config:websocket_owner()),
        ok = pw_cluster:broadcast({direct, 17}, event()),
        receive {transport_sent, owner, events, {pw_cluster_v1, api, _, _, _, _, _}} -> ok after 500 -> ?assert(false) end,

        %% A transport rejection retains the bounded head event and retries the
        %% exact same signed/deduplicated envelope instead of silently losing a
        %% security-control or durable-state notification.
        application:set_env(plainwire_relay, test_transport_result, {error, disconnected}),
        ok = pw_cluster:broadcast({direct, 17}, event()),
        FailedEnvelope = receive
            {transport_sent, owner, events, E1} -> E1
        after 500 -> ?assert(false)
        end,
        timer:sleep(50),
        ?assertEqual(1, maps:get(queue, pw_cluster:status())),
        ?assert(maps:get(send_failures, pw_cluster:status()) >= 1),
        ?assertEqual(0, maps:get(dropped, pw_cluster:status())),
        application:set_env(plainwire_relay, test_transport_result, ok),
        RetriedEnvelope = receive
            {transport_sent, owner, events, E2} -> E2
        after 1500 -> ?assert(false)
        end,
        ?assertEqual(FailedEnvelope, RetriedEnvelope),
        timer:sleep(20),
        ?assertEqual(0, maps:get(queue, pw_cluster:status())),

        %% Bound queued work even if the transport process stops consuming it.
        sys:suspend(Cluster),
        [pw_cluster:broadcast({direct, 17}, event()) || _ <- lists:seq(1, 256)],
        ?assertEqual({error, overloaded}, pw_cluster:broadcast({direct, 17}, event())),
        ?assertEqual(256, ets:lookup_element(pw_cluster_outbox, count, 2)),
        sys:resume(Cluster)
    after
        try sys:resume(Cluster) catch _:_ -> ok end,
        try gen_server:stop(Cluster) catch _:_ -> ok end,
        try stop_test_hub(Hub) catch _:_ -> ok end,
        os:unsetenv("PLAINWIRE_CLUSTER_OUTBOX_LIMIT"),
        [application:unset_env(plainwire_relay, K) || K <- [cluster, test_transport_sink, test_transport_result]]
    end.

owner_config() -> #{backend => partisan, name => owner, realtime_node => owner,
    peers => [#{name => api, ip => {127,0,0,1}, port => 9912}] }.
event() -> #{type => message_created, scope => direct, scope_id => 17, message => #{id => 3, body => <<"hello">>}}.

cluster_socket_loop(Parent) ->
    receive
        {hub_text, Payload, message_created} ->
            Parent ! {cluster_message_created, self(), Payload},
            cluster_socket_loop(Parent);
        stop ->
            ok;
        _Other ->
            cluster_socket_loop(Parent)
    end.

start_test_hub() ->
    stop_named(pw_hub),
    stop_named(pw_realtime_registry),
    {ok, _Registry} = pw_realtime_registry:start_link(),
    pw_hub:start_link().

stop_test_hub(Hub) ->
    case is_process_alive(Hub) of
        true -> gen_server:stop(Hub);
        false -> ok
    end,
    stop_named(pw_realtime_registry).

stop_named(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid when is_pid(Pid) ->
            try gen_server:stop(Pid, normal, 1000)
            catch exit:_ -> exit(Pid, kill), ok end
    end.
