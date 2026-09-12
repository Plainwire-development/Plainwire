-module(pw_client_config_hdl).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> ->
            Body = jsx:encode(pw_client_config:public()),
            Req = cowboy_req:reply(200, maps:merge(pw_util:security_headers(), #{
                <<"content-type">> => <<"application/json; charset=utf-8">>,
                <<"cache-control">> => <<"no-cache, no-store, must-revalidate">>
            }), Body, Req0),
            {ok, Req, State};
        <<"HEAD">> ->
            Req = cowboy_req:reply(200, maps:merge(pw_util:security_headers(), #{
                <<"content-type">> => <<"application/json; charset=utf-8">>,
                <<"cache-control">> => <<"no-cache, no-store, must-revalidate">>
            }), <<>>, Req0),
            {ok, Req, State};
        _ ->
            pw_util:err_json(Req0, 405, <<"method_not_allowed">>)
    end.
