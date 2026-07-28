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
        %% Listed last so the database pool and hub are ready before the socket
        %% starts accepting. Supervising the listener instead of starting it from
        %% the application callback means a crashed listener is restarted rather
        %% than leaving the node up with no HTTP.
        http_listener_spec()
    ],
    {ok, {{one_for_one, 20, 10}, Children}}.

http_listener_spec() ->
    Port = pw_util:env_int("PORT", 8080),
    Acceptors = pw_util:env_int("PLAINWIRE_HTTP_ACCEPTORS", 100),
    MaxConnections = pw_util:env_int("PLAINWIRE_HTTP_MAX_CONNECTIONS", 100000),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws", pw_ws, []},
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
        %% cowboy:start_clear/3 defaults the connection type to supervisor and
        %% mirrors it into the protocol options; both are set explicitly here
        %% because ranch:child_spec/5 does not apply cowboy's defaults.
        connection_type => supervisor,
        socket_opts => [{port, Port}, {backlog, 4096}, {nodelay, true}, {keepalive, true}, {reuseaddr, true}]
    },
    ProtocolOpts = #{
        connection_type => supervisor,
        env => #{dispatch => Dispatch},
        idle_timeout => pw_util:env_int("PLAINWIRE_HTTP_IDLE_TIMEOUT_MS", 60000),
        request_timeout => pw_util:env_int("PLAINWIRE_HTTP_REQUEST_TIMEOUT_MS", 30000),
        max_keepalive => pw_util:env_int("PLAINWIRE_HTTP_MAX_KEEPALIVE", 1000),
        stream_handlers => [cowboy_stream_h]
    },
    logger:notice("[plainwire] listening port=~p acceptors=~p max_connections=~p schedulers=~p",
        [Port, Acceptors, MaxConnections, erlang:system_info(schedulers_online)]),
    ranch:child_spec(plainwire_http, ranch_tcp, TransportOpts, cowboy_clear, ProtocolOpts).
