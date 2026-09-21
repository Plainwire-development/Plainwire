-module(pw_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    CoreChildren = [
        #{id => pw_cf_turn, start => {pw_cf_turn, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_cf_turn]},
        #{id => pw_cluster, start => {pw_cluster, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_cluster]},
        #{id => pw_media_quality, start => {pw_media_quality, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_media_quality]},
        #{id => pw_redis, start => {pw_redis, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_redis]},
        #{id => pw_storage_metrics, start => {pw_storage_metrics, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_storage_metrics]},
        #{id => pw_scylla_gate, start => {pw_scylla_gate, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_scylla_gate]},
        #{id => pw_scylla, start => {pw_scylla, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_scylla]},
        #{id => pw_rate, start => {pw_rate, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_rate]},
        #{id => pw_github_cache, start => {pw_github_cache, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_github_cache]},
        #{id => pw_async_pool, start => {pw_async_pool, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_async_pool]},
        %% Hot realtime lookup/fanout lives in concurrent ETS instead of forcing
        %% every delivery through pw_hub's single control-plane mailbox.
        #{id => pw_realtime_registry, start => {pw_realtime_registry, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_realtime_registry]},
        #{id => pw_hub, start => {pw_hub, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_hub]},
        #{id => pw_media, start => {pw_media, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_media]},
        #{id => pw_db, start => {pw_db, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_db]},
        #{id => pw_search_index, start => {pw_search_index, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_search_index]},
        #{id => pw_message_id, start => {pw_message_id, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_message_id]},
        #{id => pw_storage_outbox, start => {pw_storage_outbox, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_storage_outbox]},
        #{id => pw_storage_reconciler, start => {pw_storage_reconciler, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_storage_reconciler]},
        #{id => pw_webhook_dispatcher, start => {pw_webhook_dispatcher, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_webhook_dispatcher]},
        #{id => pw_app_interaction_dispatcher, start => {pw_app_interaction_dispatcher, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_app_interaction_dispatcher]},
        #{id => pw_ai_bot_dispatcher, start => {pw_ai_bot_dispatcher, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_ai_bot_dispatcher]},
        #{id => pw_upload_gc, start => {pw_upload_gc, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_upload_gc]},
        #{id => pw_mail, start => {pw_mail, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_mail]}
    ],
    %% Both listeners go last; DB/hub and the optional instance-local admin
    %% identity must exist before either surface accepts traffic.
    Children = CoreChildren ++ admin_children() ++ [http_listener_spec()],
    {ok, {{one_for_one, 20, 10}, Children}}.

admin_children() ->
    case pw_admin_identity:enabled() of
        false -> [];
        true -> [
            #{id => pw_admin_identity, start => {pw_admin_identity, start_link, []}, restart => permanent,
              shutdown => 5000, type => worker, modules => [pw_admin_identity]},
            admin_listener_spec()
        ]
    end.

admin_listener_spec() ->
    Port = env_range("PLAINWIRE_ADMIN_PORT", 8090, 1, 65535),
    Ip = admin_bind_ip(),
    Acceptors = env_range("PLAINWIRE_ADMIN_ACCEPTORS", 10, 1, 128),
    MaxConnections = env_range("PLAINWIRE_ADMIN_MAX_CONNECTIONS", 2000, 10, 20000),
    ConnSups = env_range("PLAINWIRE_ADMIN_CONNECTION_SUPERVISORS", 4, 1, 32),
    PerConnSup = per_connection_supervisor_limit(MaxConnections, ConnSups),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/[...]", pw_admin_api, []},
            {"/admin.js", pw_admin_static, #{file => "admin.js", type => <<"text/javascript; charset=utf-8">>}},
            {"/admin.css", pw_admin_static, #{file => "admin.css", type => <<"text/css; charset=utf-8">>}},
            {"/plainwire-mark.svg", pw_admin_static, #{file => "plainwire-mark.svg", type => <<"image/svg+xml; charset=utf-8">>}},
            {"/[...]", pw_admin_page, []}
        ]}
    ]),
    TransportOpts = #{
        num_acceptors => Acceptors,
        num_conns_sups => ConnSups,
        max_connections => PerConnSup,
        handshake_timeout => env_range("PLAINWIRE_ADMIN_HANDSHAKE_TIMEOUT_MS", 5000, 1000, 30000),
        connection_type => supervisor,
        socket_opts => [{ip, Ip}, {port, Port}, {backlog, 256}, {nodelay, true}, {keepalive, true},
                        {send_timeout, env_range("PLAINWIRE_ADMIN_SEND_TIMEOUT_MS", 10000, 1000, 60000)},
                        {send_timeout_close, true}]
    },
    ProtocolOpts = #{
        connection_type => supervisor,
        env => #{dispatch => Dispatch},
        idle_timeout => env_range("PLAINWIRE_ADMIN_IDLE_TIMEOUT_MS", 30000, 5000, 120000),
        request_timeout => env_range("PLAINWIRE_ADMIN_REQUEST_TIMEOUT_MS", 15000, 5000, 60000),
        max_keepalive => env_range("PLAINWIRE_ADMIN_MAX_KEEPALIVE", 200, 1, 2000),
        stream_handlers => [cowboy_compress_h, cowboy_stream_h]
    },
    logger:notice("[plainwire:admin] listening ip=~p port=~p acceptors=~p conn_sups=~p max_connections_total=~p",
        [Ip, Port, Acceptors, ConnSups, MaxConnections]),
    ranch:child_spec(plainwire_admin_http, ranch_tcp, TransportOpts, cowboy_clear, ProtocolOpts).

admin_bind_ip() ->
    Raw = os:getenv("PLAINWIRE_ADMIN_BIND", "127.0.0.1"),
    case inet:parse_address(Raw) of
        {ok, Ip} -> Ip;
        {error, _} -> erlang:error({invalid_admin_bind_address, Raw})
    end.

http_listener_spec() ->
    Port = env_range("PORT", 8080, 1, 65535),
    Acceptors = env_range("PLAINWIRE_HTTP_ACCEPTORS", 100, 1, 1024),
    MaxConnections = env_range("PLAINWIRE_HTTP_MAX_CONNECTIONS", 100000, 100, 500000),
    DefaultConnSups = min(16, max(2, erlang:system_info(schedulers_online))),
    ConnSups = env_range("PLAINWIRE_HTTP_CONNECTION_SUPERVISORS", DefaultConnSups, 1, 128),
    PerConnSup = per_connection_supervisor_limit(MaxConnections, ConnSups),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws", pw_ws, []},
            {"/api/client-config", pw_client_config_hdl, []},
            {"/api/uploads", pw_upload_hdl, []},
            {"/api/files/[...]", pw_file_hdl, []},
            {"/api/media/[...]", pw_media_hdl, []},
            {"/api/[...]", pw_api, []},
            {"/assets/[...]", cowboy_static, {priv_dir, plainwire_relay, "static"}},
            {"/[...]", pw_page, []}
        ]}
    ]),
    TransportOpts = #{
        num_acceptors => Acceptors,
        num_conns_sups => ConnSups,
        %% Ranch 2.x applies max_connections per connection supervisor. Split
        %% the operator-facing total across supervisors so the configured cap
        %% remains approximately listener-wide instead of multiplying silently.
        max_connections => PerConnSup,
        handshake_timeout => env_range("PLAINWIRE_HTTP_HANDSHAKE_TIMEOUT_MS", 5000, 1000, 30000),
        %% ranch child specs skip cowboy's defaults, so spell this one out.
        connection_type => supervisor,
        %% ranch adds reuseaddr itself, then complains if we do. neat.
        socket_opts => [{port, Port}, {backlog, 4096}, {nodelay, true}, {keepalive, true},
                        {send_timeout, env_range("PLAINWIRE_HTTP_SEND_TIMEOUT_MS", 15000, 1000, 120000)},
                        {send_timeout_close, true}]
    },
    ProtocolOpts = #{
        connection_type => supervisor,
        env => #{dispatch => Dispatch},
        idle_timeout => env_range("PLAINWIRE_HTTP_IDLE_TIMEOUT_MS", 60000, 5000, 300000),
        request_timeout => env_range("PLAINWIRE_HTTP_REQUEST_TIMEOUT_MS", 30000, 5000, 120000),
        max_keepalive => env_range("PLAINWIRE_HTTP_MAX_KEEPALIVE", 1000, 1, 10000),
        stream_handlers => [cowboy_compress_h, cowboy_stream_h]
    },
    logger:notice("[plainwire] listening port=~p acceptors=~p conn_sups=~p max_connections_total=~p schedulers=~p",
        [Port, Acceptors, ConnSups, MaxConnections, erlang:system_info(schedulers_online)]),
    ranch:child_spec(plainwire_http, ranch_tcp, TransportOpts, cowboy_clear, ProtocolOpts).

per_connection_supervisor_limit(Total, Supervisors) ->
    max(1, (Total + Supervisors - 1) div Supervisors).

env_range(Name, Default, Min, Max) ->
    Value = pw_util:env_int(Name, Default),
    erlang:min(Max, erlang:max(Min, Value)).
