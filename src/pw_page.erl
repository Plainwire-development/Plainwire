-module(pw_page).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, State) ->
    Path = filename:join([code:priv_dir(plainwire_relay), "static", "index.html"]),
    Body = case file:read_file(Path) of
        {ok, Bin} -> Bin;
        _ -> <<"Plainwire Relay: index.html missing">>
    end,
    Req = cowboy_req:reply(200, maps:merge(pw_util:security_headers(), #{
        <<"content-type">> => <<"text/html; charset=utf-8">>
    }), Body, Req0),
    {ok, Req, State}.
