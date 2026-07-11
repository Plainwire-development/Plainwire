-module(pw_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    ensure_secure_config(),
    {ok, Sup} = pw_sup:start_link(),
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
        socket_opts => [{port, Port}, {backlog, 4096}, {nodelay, true}, {keepalive, true}, {reuseaddr, true}]
    },
    {ok, _} = cowboy:start_clear(plainwire_http, TransportOpts, #{
        env => #{dispatch => Dispatch},
        idle_timeout => pw_util:env_int("PLAINWIRE_HTTP_IDLE_TIMEOUT_MS", 60000),
        request_timeout => pw_util:env_int("PLAINWIRE_HTTP_REQUEST_TIMEOUT_MS", 30000),
        max_keepalive => pw_util:env_int("PLAINWIRE_HTTP_MAX_KEEPALIVE", 1000),
        stream_handlers => [cowboy_stream_h]
    }),
    logger:notice("[plainwire] listening port=~p acceptors=~p max_connections=~p schedulers=~p", [Port, Acceptors, MaxConnections, erlang:system_info(schedulers_online)]),
    {ok, Sup}.

stop(_State) ->
    try cowboy:stop_listener(plainwire_http) catch _:_ -> ok end,
    ok.

ensure_secure_config() ->
    Production = production_env(),
    ensure_upload_config(Production),
    case Production of
        false ->
            ensure_rtc_config(Production);
        true ->
            true = pw_crypto:enabled(),
            true = secure_cookie_configured(),
            true = db_password_configured(),
            true = db_ssl_configured(),
            true = public_url_configured(),
            true = password_cost_configured(),
            ensure_rtc_config(Production)
    end.

ensure_rtc_config(Production) ->
    case pw_rtc_config:validate(Production) of
        ok -> ok;
        {error, Reason} -> erlang:error({insecure_production_config, Reason})
    end.

production_env() ->
    lists:member(os:getenv("PLAINWIRE_ENV"), ["prod", "production"]) orelse
        lists:member(os:getenv("NODE_ENV"), ["prod", "production"]).

secure_cookie_configured() ->
    case os:getenv("COOKIE_SECURE") of
        "1" -> true;
        "true" -> true;
        "TRUE" -> true;
        "yes" -> true;
        _ ->
            case os:getenv("PLAINWIRE_PUBLIC_URL") of
                "https://" ++ _ -> true;
                _ -> erlang:error({insecure_production_config, cookie_secure})
            end
    end.

db_password_configured() ->
    case os:getenv("PLAINWIRE_DB_PASS") of
        false -> erlang:error({insecure_production_config, db_password});
        "plainwire" -> erlang:error({insecure_production_config, db_password});
        "" -> erlang:error({insecure_production_config, db_password});
        _ -> true
    end.

db_ssl_configured() ->
    case {os:getenv("PLAINWIRE_DB_SSL"), os:getenv("PLAINWIRE_ALLOW_INSECURE_DB")} of
        {"1", _} -> true;
        {"true", _} -> true;
        {"TRUE", _} -> true;
        {"yes", _} -> true;
        {_, "1"} -> true;
        {_, "true"} -> true;
        {_, "TRUE"} -> true;
        {_, "yes"} -> true;
        _ -> erlang:error({insecure_production_config, db_ssl})
    end.

public_url_configured() ->
    case os:getenv("PLAINWIRE_PUBLIC_URL") of
        "https://" ++ Host when Host =/= [] -> true;
        _ -> erlang:error({insecure_production_config, public_https_url})
    end.

password_cost_configured() ->
    case pw_util:env_int("PLAINWIRE_PBKDF2_ITERS", 160000) of
        N when N >= 100000 -> true;
        _ -> erlang:error({insecure_production_config, password_hash_cost})
    end.

ensure_upload_config(Production) ->
    DirBin = pw_util:env_str("PLAINWIRE_UPLOAD_DIR", <<"data/uploads/">>),
    Dir = binary_to_list(DirBin),
    case Production andalso not (filename:pathtype(Dir) =:= absolute) of
        true -> erlang:error({insecure_production_config, upload_dir_must_be_absolute});
        false -> ok
    end,
    Probe = filename:join(Dir, ".plainwire-write-test"),
    ok = filelib:ensure_dir(Probe),
    case file:write_file(Probe, <<>>, [write, raw]) of
        ok -> file:delete(Probe), ok;
        {error, Reason} -> erlang:error({upload_storage_unavailable, Reason})
    end.
