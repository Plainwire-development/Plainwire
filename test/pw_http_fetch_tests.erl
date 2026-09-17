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

extra_headers_are_forwarded_test() ->
    {ok, _} = application:ensure_all_started(inets),
    Parent = self(),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Server = spawn(fun() -> serve_once(Listen, Parent) end),
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/headers">>,
    try
        {ok, 200, _, <<"{}">>} = pw_http_fetch:get(Url, 4096, #{
            headers => [{<<"x-github-api-version">>, <<"2026-03-10">>},
                        {<<"if-none-match">>, <<"etag-test">>},
                        {<<"bad\r\nheader">>, <<"skip-me">>},
                        {<<"x-bad-value">>, <<"safe\r\ninjected: nope">>}]
        }),
        receive
            {captured_request, Request} ->
                Lower = string:lowercase(Request),
                ?assertNotEqual(nomatch, binary:match(Lower, <<"x-github-api-version: 2026-03-10">>)),
                ?assertNotEqual(nomatch, binary:match(Lower, <<"if-none-match: etag-test">>)),
                ?assertEqual(nomatch, binary:match(Lower, <<"skip-me">>)),
                ?assertEqual(nomatch, binary:match(Lower, <<"injected: nope">>))
        after 1000 ->
            ?assert(false)
        end
    after
        exit(Server, kill),
        gen_tcp:close(Listen)
    end.

serve_once(Listen, Parent) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Request = read_request(Socket, <<>>),
    Parent ! {captured_request, Request},
    _ = gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}">>),
    gen_tcp:close(Socket).

reserved_transport_headers_are_not_forwarded_test() ->
    Headers = pw_http_fetch:test_normalize_extra_headers([
        {<<"host">>, <<"evil.example">>},
        {<<"content-length">>, <<"999999">>},
        {<<"transfer-encoding">>, <<"chunked">>},
        {<<"connection">>, <<"upgrade">>},
        {<<"authorization">>, <<"Bearer allowed">>},
        {<<"x-plainwire-test">>, <<"ok">>}
    ]),
    LowerNames = [string:lowercase(pw_util:bin(K)) || {K, _} <- Headers],
    ?assertNot(lists:member(<<"host">>, LowerNames)),
    ?assertNot(lists:member(<<"content-length">>, LowerNames)),
    ?assertNot(lists:member(<<"transfer-encoding">>, LowerNames)),
    ?assertNot(lists:member(<<"connection">>, LowerNames)),
    ?assert(lists:member(<<"authorization">>, LowerNames)),
    ?assert(lists:member(<<"x-plainwire-test">>, LowerNames)).
