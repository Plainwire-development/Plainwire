-module(pw_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => pw_rate, start => {pw_rate, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_rate]},
        #{id => pw_hub, start => {pw_hub, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_hub]},
        #{id => pw_media, start => {pw_media, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_media]},
        #{id => pw_db, start => {pw_db, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_db]},
        #{id => pw_upload_gc, start => {pw_upload_gc, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_upload_gc]},
        #{id => pw_cf_turn, start => {pw_cf_turn, start_link, []}, restart => permanent, shutdown => 5000, type => worker, modules => [pw_cf_turn]},
        %% listener goes last; DB and hub should exist before traffic does.
        http_listener_spec()
    ],
    {ok, {{one_for_one, 20, 10}, Children}}.

http_listener_spec() ->
    Port = env_range("PORT", 8080, 1, 65535),
    Acceptors = env_range("PLAINWIRE_HTTP_ACCEPTORS", 100, 1, 1024),
    MaxConnections = env_range("PLAINWIRE_HTTP_MAX_CONNECTIONS", 100000, 100, 500000),
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
        max_connections => MaxConnections,
        %% ranch child specs skip cowboy's defaults, so spell this one out.
        connection_type => supervisor,
        %% ranch adds reuseaddr itself, then complains if we do. neat.
        socket_opts => [{port, Port}, {backlog, 4096}, {nodelay, true}, {keepalive, true}]
    },
    ProtocolOpts = #{
        connection_type => supervisor,
        env => #{dispatch => Dispatch},
        idle_timeout => env_range("PLAINWIRE_HTTP_IDLE_TIMEOUT_MS", 60000, 5000, 300000),
        request_timeout => env_range("PLAINWIRE_HTTP_REQUEST_TIMEOUT_MS", 30000, 5000, 120000),
        max_keepalive => env_range("PLAINWIRE_HTTP_MAX_KEEPALIVE", 1000, 1, 10000),
        stream_handlers => [cowboy_compress_h, cowboy_stream_h]
    },
    logger:notice("[plainwire] listening port=~p acceptors=~p max_connections=~p schedulers=~p",
        [Port, Acceptors, MaxConnections, erlang:system_info(schedulers_online)]),
    ranch:child_spec(plainwire_http, ranch_tcp, TransportOpts, cowboy_clear, ProtocolOpts).

env_range(Name, Default, Min, Max) ->
    Value = pw_util:env_int(Name, Default),
    erlang:min(Max, erlang:max(Min, Value)).
