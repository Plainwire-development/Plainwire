-module(pw_admin_page).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        Method when Method =:= <<"GET">>; Method =:= <<"HEAD">> ->
            Path = filename:join([code:priv_dir(plainwire_relay), "admin", "index.html"]),
            case file:read_file(Path) of
                {ok, Body} ->
                    Req = cowboy_req:reply(200, page_headers(<<"text/html; charset=utf-8">>), Body, Req0),
                    {ok, Req, State};
                _ ->
                    Req = cowboy_req:reply(503, page_headers(<<"text/plain; charset=utf-8">>), <<"Plainwire control UI unavailable">>, Req0),
                    {ok, Req, State}
            end;
        _ ->
            BaseHeaders = page_headers(<<"text/plain; charset=utf-8">>),
            Headers = BaseHeaders#{<<"allow">> => <<"GET, HEAD">>},
            Req = cowboy_req:reply(405, Headers, <<"method not allowed">>, Req0),
            {ok, Req, State}
    end.

page_headers(ContentType) ->
    Base = pw_util:security_headers(),
    Base#{<<"content-type">> => ContentType,
          <<"cache-control">> => <<"no-cache, no-store, must-revalidate">>,
          <<"content-security-policy">> => <<"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'">>,
          <<"permissions-policy">> => <<"camera=(), microphone=(), display-capture=(), geolocation=(), payment=(), usb=(), browsing-topics=()">>}.
