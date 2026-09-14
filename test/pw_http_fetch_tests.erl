-module(pw_http_fetch_tests).

-include_lib("eunit/include/eunit.hrl").

oversized_pages_can_be_read_as_a_prefix_test() ->
    {ok, _} = application:ensure_all_started(inets),
    Body = <<"<html><head><meta property=\"og:title\" content=\"Big\"></head><body>",
             (binary:copy(<<"x">>, 400000))/binary, "</body></html>">>,
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Server = spawn(fun() -> serve(Listen, Body) end),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/page">>,
    try
        %% media fetches still refuse bodies over the limit
        ?assertEqual({error, too_large}, pw_http_fetch:get(Url, 4096)),
        %% page metadata only needs the start of a large page
        {ok, 200, _, Prefix} = pw_http_fetch:get(Url, 4096, #{truncate => true}),
        ?assertEqual(binary:part(Body, 0, 4096), Prefix)
    after
        exit(Server, kill),
        gen_tcp:close(Listen)
    end.

serve(Listen, Body) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    _ = read_request(Socket, <<>>),
    Head = ["HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: ",
            integer_to_list(byte_size(Body)), "\r\nConnection: close\r\n\r\n"],
    _ = gen_tcp:send(Socket, [Head, Body]),
    gen_tcp:close(Socket),
    serve(Listen, Body).

read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, 2000) of
                {ok, Data} -> read_request(Socket, <<Acc/binary, Data/binary>>);
                _ -> Acc
            end;
        _ ->
            Acc
    end.
