-module(pw_mail_tests).
-include_lib("eunit/include/eunit.hrl").

central_host_only_matches_plainwire_test() ->
    ?assert(pw_mail:central_host(<<"plainwi.re">>)),
    ?assert(pw_mail:central_host(<<"www.plainwi.re">>)),
    ?assertNot(pw_mail:central_host(<<"chat.example.com">>)),
    ?assertNot(pw_mail:central_host(<<"localhost">>)).

disabled_without_smtp_or_public_url_test() ->
    with_env([
        {"PLAINWIRE_MAIL_ENABLED", "true"},
        {"PLAINWIRE_SMTP_HOST", ""},
        {"PLAINWIRE_SMTP_USER", ""},
        {"PLAINWIRE_SMTP_PASS", ""},
        {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}
    ], fun() ->
        ?assertNot(pw_mail:enabled())
    end).

explicit_disable_overrides_central_host_test() ->
    with_env([{"PLAINWIRE_MAIL_ENABLED", "false"}, {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        ?assertNot(pw_mail:enabled())
    end).

self_hosted_stays_disabled_without_explicit_flag_test() ->
    with_env([
        {"PLAINWIRE_MAIL_ENABLED", ""},
        {"PLAINWIRE_PUBLIC_URL", "https://chat.example.com"},
        {"PLAINWIRE_SMTP_HOST", "smtp.example.com"},
        {"PLAINWIRE_SMTP_USER", "mailer"},
        {"PLAINWIRE_SMTP_PASS", "secret"}
    ], fun() ->
        ?assertNot(pw_mail:enabled())
    end).

compose_reset_mail_does_not_echo_smtp_password_test() ->
    with_env([{"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}, {"PLAINWIRE_SMTP_FROM", "noreply@example.com"}], fun() ->
        Mail = pw_mail:compose(#{kind => password_reset, to => <<"user@example.com">>,
                                 username => <<"ada">>, token => <<"reset-token-value">>, app_name => <<"Plainwire">>}),
        ?assertEqual(<<"user@example.com">>, maps:get(to, Mail)),
        Text = maps:get(text, Mail),
        ?assert(binary:match(Text, <<"https://plainwi.re/#reset/reset-token-value">>) =/= nomatch),
        ?assertEqual(nomatch, binary:match(Text, <<"PLAINWIRE_SMTP_PASS">>)),
        ?assertEqual(nomatch, binary:match(jsx:encode(Mail), <<"41844184">>))
    end).

compose_strips_header_breaks_from_app_name_test() ->
    with_env([{"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        Mail = pw_mail:compose(#{kind => password_reset, to => <<"user@example.com">>,
                                 username => <<"ada">>, token => <<"reset-token-value">>,
                                 app_name => <<"Plainwire\r\nBcc: evil@example.com">>}),
        Subject = maps:get(subject, Mail),
        ?assertEqual(nomatch, binary:match(Subject, <<"\r">>)),
        ?assertEqual(nomatch, binary:match(Subject, <<"\n">>))
    end).

smtp_body_stuffs_lf_dot_lines_test() ->
    Msg = pw_mail:rfc822(<<"from@example.com">>, <<"user@example.com">>, <<"Hi">>, <<"hello\n.\nthere">>),
    ?assertEqual(nomatch, binary:match(Msg, <<"\r\n.\r\n">>)),
    ?assertNotEqual(nomatch, binary:match(Msg, <<"\r\n..\r\nthere">>)).

smtp_headers_reject_injected_breaks_test() ->
    Msg = pw_mail:rfc822(<<"from@example.com\r\nBcc: evil@example.com">>, <<"user@example.com">>, <<"Hi\r\nBcc: evil@example.com">>, <<"ok">>),
    ?assertEqual(nomatch, binary:match(Msg, <<"\r\nBcc:">>)).

compose_verify_mail_uses_verify_fragment_test() ->
    with_env([{"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        Mail = pw_mail:compose(#{kind => email_verify, to => <<"user@example.com">>,
                                 username => <<"ada">>, token => <<"verify-token-value">>}),
        ?assert(binary:match(maps:get(text, Mail), <<"https://plainwi.re/#verify-email/verify-token-value">>) =/= nomatch)
    end).

with_env(Pairs, Fun) ->
    Old = [{Name, os:getenv(Name)} || {Name, _} <- Pairs],
    lists:foreach(fun({Name, Value}) -> os:putenv(Name, Value) end, Pairs),
    try Fun()
    after
        lists:foreach(fun
            ({Name, false}) -> os:unsetenv(Name);
            ({Name, Value}) -> os:putenv(Name, Value)
        end, Old)
    end.

%% ---------------------------------------------------------------------------
%% SMTP wire protocol
%%
%% The tests above stop at compose/1. These drive smtp_send/1 against a fake
%% SMTP server on loopback so the session state machine (EHLO, AUTH, MAIL/RCPT/
%% DATA, dot stuffing, TLS gating) is exercised as a real server would see it.
%% ---------------------------------------------------------------------------

smtp_delivers_and_dot_stuffs_on_the_wire_test() ->
    {Server, Port} = start_fake_smtp(#{}),
    Result = with_smtp_env(Port, fun() ->
        pw_mail:smtp_send(sample_message(<<"hello\n.\nthere\n">>))
    end),
    ?assertEqual(ok, Result),
    Lines = fake_smtp_transcript(Server),
    ?assertEqual([<<"AUTH PLAIN ", (base64:encode(<<0, "mailer", 0, "secret">>))/binary>>],
                 auth_lines(Lines)),
    ?assert(lists:member(<<"MAIL FROM:<noreply@example.com>">>, Lines)),
    ?assert(lists:member(<<"RCPT TO:<user@example.com>">>, Lines)),
    ?assert(lists:member(<<"DATA">>, Lines)),
    ?assert(lists:member(<<"QUIT">>, Lines)),
    %% The lone "." in the body must reach the server stuffed as "..", otherwise
    %% it would terminate DATA early and truncate the mail.
    ?assert(lists:member(<<"..">>, Lines)).

%% A 535 means the credentials were read and rejected. Retrying AUTH LOGIN with
%% the same credentials burns a second failed attempt against the provider's
%% lockout counter for every queued mail.
smtp_auth_rejection_is_not_retried_test() ->
    {Server, Port} = start_fake_smtp(#{auth_plain => <<"535 5.7.8 Username and Password not accepted">>}),
    Result = with_smtp_env(Port, fun() -> pw_mail:smtp_send(sample_message(<<"body">>)) end),
    ?assertMatch({error, _}, Result),
    ?assertEqual(1, length(auth_lines(fake_smtp_transcript(Server)))).

smtp_auth_falls_back_to_login_when_plain_unsupported_test() ->
    {Server, Port} = start_fake_smtp(#{auth_plain => <<"504 5.5.4 Unrecognized authentication type">>}),
    Result = with_smtp_env(Port, fun() -> pw_mail:smtp_send(sample_message(<<"body">>)) end),
    ?assertEqual(ok, Result),
    Lines = fake_smtp_transcript(Server),
    ?assert(lists:member(<<"AUTH LOGIN">>, Lines)),
    ?assert(lists:member(<<"QUIT">>, Lines)).

%% PLAINWIRE_SMTP_TLS defaults to true, so a server that never offers STARTTLS
%% must not receive the credentials at all.
smtp_refuses_to_authenticate_without_tls_test() ->
    {Server, Port} = start_fake_smtp(#{}),
    Result = with_env([{"PLAINWIRE_SMTP_HOST", "127.0.0.1"},
                       {"PLAINWIRE_SMTP_PORT", integer_to_list(Port)},
                       {"PLAINWIRE_SMTP_USER", "mailer"},
                       {"PLAINWIRE_SMTP_PASS", "secret"},
                       {"PLAINWIRE_SMTP_TLS", "true"},
                       {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        pw_mail:smtp_send(sample_message(<<"body">>))
    end),
    ?assertEqual({error, tls_required}, Result),
    ?assertEqual([], auth_lines(fake_smtp_transcript(Server))).

%% A dropped connection is a transport failure. Reporting it as an auth failure
%% sends operators chasing credentials instead of the network.
smtp_transport_error_is_not_reported_as_auth_failure_test() ->
    {Server, Port} = start_fake_smtp(#{close_after => <<"AUTH">>}),
    Result = with_smtp_env(Port, fun() -> pw_mail:smtp_send(sample_message(<<"body">>)) end),
    ?assertEqual({error, closed}, Result),
    ?assertEqual(1, length(auth_lines(fake_smtp_transcript(Server)))).

%% --- fake SMTP server -------------------------------------------------------

sample_message(Text) ->
    #{from => <<"noreply@example.com">>, to => <<"user@example.com">>,
      subject => <<"Hi">>, text => Text}.

auth_lines(Lines) -> [L || <<"AUTH", _/binary>> = L <- Lines].

with_smtp_env(Port, Fun) ->
    with_env([{"PLAINWIRE_SMTP_HOST", "127.0.0.1"},
              {"PLAINWIRE_SMTP_PORT", integer_to_list(Port)},
              {"PLAINWIRE_SMTP_USER", "mailer"},
              {"PLAINWIRE_SMTP_PASS", "secret"},
              {"PLAINWIRE_SMTP_TLS", "false"},
              {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], Fun).

start_fake_smtp(Opts) ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}, {packet, line},
                                     {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(LSock),
    Parent = self(),
    Server = spawn(fun() ->
        Lines = try
            {ok, Sock} = gen_tcp:accept(LSock, 10000),
            ok = gen_tcp:send(Sock, <<"220 fake.localhost ESMTP\r\n">>),
            Collected = serve(Sock, Opts, none, []),
            catch gen_tcp:close(Sock),
            Collected
        catch _:_ -> []
        end,
        catch gen_tcp:close(LSock),
        Parent ! {fake_smtp, self(), lists:reverse(Lines)}
    end),
    {Server, Port}.

fake_smtp_transcript(Server) ->
    receive {fake_smtp, Server, Lines} -> Lines
    after 10000 -> erlang:error(fake_smtp_timeout)
    end.

serve(Sock, Opts, State, Acc) ->
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, Raw} ->
            Line = iolist_to_binary(string:trim(Raw)),
            Acc1 = [Line | Acc],
            case handle_line(Sock, Opts, State, Line) of
                {continue, Next} -> serve(Sock, Opts, Next, Acc1);
                stop -> Acc1
            end;
        {error, _} -> Acc
    end.

handle_line(Sock, Opts, data, <<".">>) ->
    reply(Sock, Opts, data_end, <<"250 2.0.0 Ok: queued">>),
    {continue, none};
handle_line(_Sock, _Opts, data, _Line) ->
    {continue, data};
handle_line(Sock, Opts, login_user, _Line) ->
    reply(Sock, Opts, auth_login_pass_prompt, <<"334 UGFzc3dvcmQ6">>),
    {continue, login_pass};
handle_line(Sock, Opts, login_pass, _Line) ->
    reply(Sock, Opts, auth_login_result, <<"235 2.7.0 Authentication succeeded">>),
    {continue, none};
handle_line(Sock, Opts, none, Line) ->
    Cmd = iolist_to_binary(string:uppercase(hd(binary:split(Line, <<" ">>)))),
    case maps:get(close_after, Opts, undefined) of
        Cmd -> stop;
        _ -> dispatch(Sock, Opts, Cmd, Line)
    end.

dispatch(Sock, Opts, <<"EHLO">>, _Line) ->
    Greeting = maps:get(ehlo, Opts, [<<"250-fake.localhost">>, <<"250 AUTH PLAIN LOGIN">>]),
    [gen_tcp:send(Sock, [L, <<"\r\n">>]) || L <- Greeting],
    {continue, none};
dispatch(Sock, Opts, <<"AUTH">>, <<"AUTH LOGIN", _/binary>>) ->
    reply(Sock, Opts, auth_login, <<"334 VXNlcm5hbWU6">>),
    {continue, login_user};
dispatch(Sock, Opts, <<"AUTH">>, _Line) ->
    reply(Sock, Opts, auth_plain, <<"235 2.7.0 Authentication succeeded">>),
    {continue, none};
dispatch(Sock, Opts, <<"MAIL">>, _Line) ->
    reply(Sock, Opts, mail, <<"250 2.1.0 Ok">>),
    {continue, none};
dispatch(Sock, Opts, <<"RCPT">>, _Line) ->
    reply(Sock, Opts, rcpt, <<"250 2.1.5 Ok">>),
    {continue, none};
dispatch(Sock, Opts, <<"DATA">>, _Line) ->
    reply(Sock, Opts, data, <<"354 End data with <CR><LF>.<CR><LF>">>),
    {continue, data};
dispatch(Sock, Opts, <<"QUIT">>, _Line) ->
    reply(Sock, Opts, quit, <<"221 2.0.0 Bye">>),
    stop;
dispatch(Sock, _Opts, _Cmd, _Line) ->
    gen_tcp:send(Sock, <<"500 5.5.1 Unrecognized command\r\n">>),
    {continue, none}.

reply(Sock, Opts, Key, Default) ->
    gen_tcp:send(Sock, [maps:get(Key, Opts, Default), <<"\r\n">>]).
