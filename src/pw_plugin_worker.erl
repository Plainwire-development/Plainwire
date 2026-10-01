-module(pw_plugin_worker).
-behaviour(cowboy_handler).
-export([init/2]).

%% A network policy must come from the worker response, rather than writable
%% JavaScript globals. Blob workers inherit the page's authenticated egress.
init(Req0, State) ->
    Headers = (pw_util:security_headers())#{
        <<"content-type">> => <<"text/javascript; charset=utf-8">>,
        <<"content-security-policy">> =>
            <<"default-src 'none'; script-src 'unsafe-eval'; connect-src 'none'; worker-src 'none'; frame-ancestors 'none'; base-uri 'none'">>
    },
    case cowboy_req:method(Req0) of
        Method when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
            Path = filename:join([code:priv_dir(plainwire_relay), "static", "plugin-worker.js"]),
            case file:read_file(Path) of
                {ok, Body} -> {ok, cowboy_req:reply(200, Headers, Body, Req0), State};
                _ -> {ok, cowboy_req:reply(404, Headers, <<>>, Req0), State}
            end;
        _ -> {ok, cowboy_req:reply(405, Headers#{<<"allow">> => <<"GET, HEAD">>}, <<>>, Req0), State}
    end.
