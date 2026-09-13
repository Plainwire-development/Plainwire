-module(pw_cluster_partisan).
-export([start/1, send/3, members/0]).

start(C) ->
    case code:ensure_loaded(partisan) of
        {module, partisan} -> configure(C);
        _ -> {error, partisan_not_installed}
    end.

configure(C) ->
    %% A named VM overrides Partisan's configured name. Never accidentally
    %% expose a second, unauthenticated native-distribution network.
    NativeSafe = node() =:= nonode@nohost orelse
        (node() =:= maps:get(name, C) andalso init:get_argument(dist_listen) =:= {ok, [["false"]]}),
    case NativeSafe andalso pw_cluster_config:validate(C) =:= ok of
        false -> {error, unsafe_cluster_runtime};
        true -> configure_validated(C)
    end.

configure_validated(C) ->
    TLS = [{certfile, maps:get(certfile, C)}, {keyfile, maps:get(keyfile, C)},
           {cacertfile, maps:get(cacertfile, C)}, {verify, verify_peer},
           {versions, ['tlsv1.3', 'tlsv1.2']}],
    Opts = [{name, maps:get(name, C)},
            {listen_addrs, [#{ip => maps:get(listen_ip, C), port => maps:get(listen_port, C)}]},
            {channels, channels()}, {connect_disterl, false}, {broadcast, false},
            {peer_service_manager, partisan_pluggable_peer_service_manager},
            {tls, true}, {tls_server_options, [{fail_if_no_peer_cert, true} | TLS]},
            {tls_client_options, TLS}, {tls_handshake_timeout, 3000},
            {max_message_size, 262144}],
    Started = lists:keymember(partisan, 1, application:which_applications()),
    Owned = persistent_term:get({?MODULE, options}, undefined) =:= Opts,
    %% A pw_cluster restart may reuse only the transport it securely started.
    case Started andalso not Owned of
        true -> {error, partisan_started_outside_plainwire};
        false ->
            [application:set_env(partisan, K, V) || {K, V} <- Opts],
            case application:ensure_all_started(partisan) of
                {ok, _} ->
                    persistent_term:put({?MODULE, options}, Opts),
                    [partisan:join(#{name => maps:get(name, P),
                                    listen_addrs => [maps:with([ip, port], P)],
                                    channels => channels()}) || P <- maps:get(peers, C)],
                    ok;
                {error, _} -> {error, partisan_start_failed}
            end
    end.

channels() -> #{realtime => #{parallelism => 1}, events => #{parallelism => 1}}.
send(Node, Channel, Envelope) ->
    try partisan:forward_message(Node, pw_cluster, Envelope,
          #{channel => Channel, channel_fallback => false, ack => false,
            retransmission => false, transitive => false})
    catch _:_ -> {error, unavailable} end.
members() ->
    try partisan:nodes() catch _:_ -> [] end.
