-module(pw_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, Sup} = pw_sup:start_link(),
    Port = pw_util:env_int("PORT", 8080),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws", pw_ws, []},
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
    catch cowboy:stop_listener(plainwire_http),
    ok.
