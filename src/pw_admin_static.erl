-module(pw_admin_static).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, #{file := File, type := Type} = State) ->
    case cowboy_req:method(Req0) of
        Method when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
            Path = filename:join([code:priv_dir(plainwire_relay), "admin", File]),
            case file:read_file(Path) of
                {ok, Body} ->
                    Req = cowboy_req:reply(200, static_headers(Type), Body, Req0),
                    {ok, Req, State};
                _ ->
                    Req = cowboy_req:reply(404, static_headers(<<"text/plain; charset=utf-8">>), <<"not found">>, Req0),
                    {ok, Req, State}
            end;
        _ ->
            BaseHeaders = static_headers(<<"text/plain; charset=utf-8">>),
            Headers = BaseHeaders#{<<"allow">> => <<"GET, HEAD">>},
            Req = cowboy_req:reply(405, Headers, <<"method not allowed">>, Req0),
            {ok, Req, State}
    end.

static_headers(Type) ->
    Base = pw_util:security_headers(),
    Base#{<<"content-type">> => Type,
          <<"cache-control">> => <<"no-cache">>,
          <<"content-security-policy">> => <<"default-src 'none'; frame-ancestors 'none'; base-uri 'none'">>,
          <<"permissions-policy">> => <<"camera=(), microphone=(), display-capture=(), geolocation=(), payment=(), usb=(), browsing-topics=()">>}.
