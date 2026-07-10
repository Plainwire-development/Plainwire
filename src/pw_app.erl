-module(pw_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    ensure_secure_config(),
    {ok, Sup} = pw_sup:start_link(),
    Port = pw_util:env_int("PORT", 8080),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws", pw_ws, []},
            {"/api/media/[...]", pw_media_hdl, []},
            {"/api/[...]", pw_api, []},
            {"/assets/[...]", cowboy_static, {priv_dir, plainwire_relay, "static"}},
            {"/[...]", pw_page, []}
        ]}
    ]),
    {ok, _} = cowboy:start_clear(plainwire_http, [{port, Port}], #{
        env => #{dispatch => Dispatch},
        stream_handlers => [cowboy_stream_h]
    }),
    io:format("Plainwire Relay listening on http://0.0.0.0:~p~n", [Port]),
    {ok, Sup}.

stop(_State) ->
    try cowboy:stop_listener(plainwire_http) catch _:_ -> ok end,
    ok.

ensure_secure_config() ->
    case production_env() of
        false ->
            ok;
        true ->
            true = pw_crypto:enabled(),
            true = secure_cookie_configured(),
            true = db_password_configured(),
            true = db_ssl_configured(),
            ok
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
