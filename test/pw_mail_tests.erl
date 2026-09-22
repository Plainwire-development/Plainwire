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

starttls_socket_stays_passive_and_binary_test() ->
    Opts = pw_mail:tls_opts("smtp.example.com"),
    ?assertEqual(false, proplists:get_value(active, Opts)),
    ?assertEqual(binary, proplists:get_value(mode, Opts)),
    ?assertEqual(verify_peer, proplists:get_value(verify, Opts)).

smtp_headers_reject_injected_breaks_test() ->
    Msg = pw_mail:rfc822(<<"from@example.com\r\nBcc: evil@example.com">>, <<"user@example.com">>, <<"Hi\r\nBcc: evil@example.com">>, <<"ok">>),
    ?assertEqual(nomatch, binary:match(Msg, <<"\r\nBcc:">>)).

smtp_message_id_uses_from_domain_and_ascii_is_7bit_test() ->
    Msg = pw_mail:rfc822(<<"from@example.com">>, <<"user@example.com">>, <<"Hi">>, <<"ok">>),
    ?assertNotEqual(nomatch, binary:match(Msg, <<"@example.com>">>)),
    ?assertEqual(nomatch, binary:match(Msg, <<"@plainwire>">>)),
    ?assertNotEqual(nomatch, binary:match(Msg, <<"Content-Transfer-Encoding: 7bit\r\n">>)).

smtp_non_ascii_body_is_quoted_printable_test() ->
    Msg = pw_mail:rfc822(<<"from@example.com">>, <<"user@example.com">>, <<"Hi">>, <<"héllo">>),
    ?assertNotEqual(nomatch, binary:match(Msg, <<"Content-Transfer-Encoding: quoted-printable\r\n">>)),
    ?assertEqual(nomatch, binary:match(Msg, <<"8bit">>)).

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

smtp_strips_quotes_and_breaks_from_credentials_test() ->
    {Server, Port} = start_fake_smtp(#{}),
    Result = with_env([{"PLAINWIRE_SMTP_HOST", "127.0.0.1"},
                       {"PLAINWIRE_SMTP_PORT", integer_to_list(Port)},
                       {"PLAINWIRE_SMTP_USER", "\"mailer\""},
                       {"PLAINWIRE_SMTP_PASS", "\"sec\rret\""},
                       {"PLAINWIRE_SMTP_TLS", "false"},
                       {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        pw_mail:smtp_send(sample_message(<<"body">>))
    end),
    ?assertEqual(ok, Result),
    ?assertEqual([<<"AUTH PLAIN ", (base64:encode(<<0, "mailer", 0, "secret">>))/binary>>],
                 auth_lines(fake_smtp_transcript(Server))).

%% The SMTP username is often a label, while the From address is the mailbox
%% the token was created for. A 535 on the label must not block that mailbox.
smtp_retries_auth_as_mailbox_from_address_test() ->
    {Server, Port} = start_fake_smtp(#{reject_first_auth => true}),
    Result = with_env([{"PLAINWIRE_SMTP_HOST", "127.0.0.1"},
                       {"PLAINWIRE_SMTP_PORT", integer_to_list(Port)},
                       {"PLAINWIRE_SMTP_USER", "mailer"},
                       {"PLAINWIRE_SMTP_PASS", "secret"},
                       {"PLAINWIRE_SMTP_FROM", "mailer@example.com"},
                       {"PLAINWIRE_SMTP_TLS", "false"},
                       {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        pw_mail:smtp_send(sample_message(<<"body">>))
    end),
    ?assertEqual(ok, Result),
    Lines = fake_smtp_transcript(Server),
    ?assertEqual(2, length(auth_lines(Lines))),
    ?assert(lists:member(<<"AUTH PLAIN ", (base64:encode(<<0, "mailer@example.com", 0, "secret">>))/binary>>, Lines)),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(lists:join(<<"\n">>, Lines)), <<"AUTH LOGIN">>)).

%% "Display Name <box@domain>" is not a login a server will accept. The
%% address inside the brackets is the username.
smtp_sends_bracketed_username_as_the_mailbox_test() ->
    {Server, Port} = start_fake_smtp(#{}),
    Result = with_env([{"PLAINWIRE_SMTP_HOST", "127.0.0.1"},
                       {"PLAINWIRE_SMTP_PORT", integer_to_list(Port)},
                       {"PLAINWIRE_SMTP_USER", "Mailer <mailer@example.com>"},
                       {"PLAINWIRE_SMTP_PASS", "secret"},
                       {"PLAINWIRE_SMTP_FROM", ""},
                       {"PLAINWIRE_SMTP_TLS", "false"},
                       {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        pw_mail:smtp_send(sample_message(<<"body">>))
    end),
    ?assertEqual(ok, Result),
    ?assertEqual([<<"AUTH PLAIN ", (base64:encode(<<0, "mailer@example.com", 0, "secret">>))/binary>>],
                 auth_lines(fake_smtp_transcript(Server))).

%% A proton.me username is refused. The From address is the mailbox the token
%% was created for, so the second login uses that address.
smtp_retries_auth_as_custom_domain_from_address_test() ->
    {Server, Port} = start_fake_smtp(#{reject_first_auth => true}),
    Result = with_env([{"PLAINWIRE_SMTP_HOST", "127.0.0.1"},
                       {"PLAINWIRE_SMTP_PORT", integer_to_list(Port)},
                       {"PLAINWIRE_SMTP_USER", "person@proton.me"},
                       {"PLAINWIRE_SMTP_PASS", "secret"},
                       {"PLAINWIRE_SMTP_FROM", "Mailer <mailer@example.com>"},
                       {"PLAINWIRE_SMTP_TLS", "false"},
                       {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        pw_mail:smtp_send(sample_message(<<"body">>))
    end),
    ?assertEqual(ok, Result),
    Lines = fake_smtp_transcript(Server),
    ?assertEqual(2, length(auth_lines(Lines))),
    ?assert(lists:member(<<"AUTH PLAIN ", (base64:encode(<<0, "mailer@example.com", 0, "secret">>))/binary>>, Lines)),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(lists:join(<<"\n">>, Lines)), <<"AUTH LOGIN">>)).

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
    ?assertMatch({error, {connect, econnrefused}}, Result),
    ?assertEqual(1, length(auth_lines(fake_smtp_transcript(Server)))).

%% A server that answers AUTH PLAIN with 334 is waiting for the SASL payload.
%% Starting AUTH LOGIN instead leaves the exchange unfinished.
smtp_auth_plain_334_continues_instead_of_login_test() ->
    {Server, Port} = start_fake_smtp(#{plain_continue => true}),
    Result = with_smtp_env(Port, fun() -> pw_mail:smtp_send(sample_message(<<"body">>)) end),
    ?assertEqual(ok, Result),
    Lines = fake_smtp_transcript(Server),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(lists:join(<<"\n">>, Lines)), <<"AUTH LOGIN">>)),
    ?assert(lists:member(<<"QUIT">>, Lines)).

%% MAIL FROM is retried with the authenticated address when the configured
%% From is rejected. Operators do not need a new environment variable.
smtp_retries_envelope_with_authenticated_user_test() ->
    {Server, Port} = start_fake_smtp(#{reject_first_mail => true}),
    Result = with_env([{"PLAINWIRE_SMTP_HOST", "127.0.0.1"},
                       {"PLAINWIRE_SMTP_PORT", integer_to_list(Port)},
                       {"PLAINWIRE_SMTP_USER", "mailer@example.com"},
                       {"PLAINWIRE_SMTP_PASS", "secret"},
                       {"PLAINWIRE_SMTP_TLS", "false"},
                       {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], fun() ->
        pw_mail:smtp_send(sample_message(<<"body">>))
    end),
    ?assertEqual(ok, Result),
    Lines = fake_smtp_transcript(Server),
    ?assert(lists:member(<<"MAIL FROM:<noreply@example.com>">>, Lines)),
    ?assert(lists:member(<<"MAIL FROM:<mailer@example.com>">>, Lines)).

smtp_retries_a_dropped_greeting_once_test() ->
    {Server, Port} = start_fake_smtp(#{accepts => 2, close_after => <<"EHLO">>, close_times => 1}),
    Result = with_smtp_env(Port, fun() -> pw_mail:smtp_send(sample_message(<<"body">>)) end),
    ?assertEqual(ok, Result),
    Lines = fake_smtp_transcript(Server),
    ?assert(lists:member(<<"QUIT">>, Lines)).

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
              {"PLAINWIRE_SMTP_FROM", ""},
              {"PLAINWIRE_SMTP_TLS", "false"},
              {"PLAINWIRE_PUBLIC_URL", "https://plainwi.re"}], Fun).

start_fake_smtp(Opts) ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false}, {packet, line},
                                     {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(LSock),
    Parent = self(),
    Accepts = maps:get(accepts, Opts, 1),
    Server = spawn(fun() ->
        Lines = accept_sessions(LSock, Opts, Accepts, []),
        catch gen_tcp:close(LSock),
        Parent ! {fake_smtp, self(), Lines}
    end),
    {Server, Port}.

accept_sessions(_LSock, _Opts, 0, Acc) -> lists:reverse(Acc);
accept_sessions(LSock, Opts, N, Acc) ->
    case gen_tcp:accept(LSock, 10000) of
        {ok, Sock} ->
            ok = gen_tcp:send(Sock, <<"220 fake.localhost ESMTP\r\n">>),
            Collected = try serve(Sock, Opts, none, []) catch _:_ -> [] end,
            catch gen_tcp:close(Sock),
            accept_sessions(LSock, Opts, N - 1, lists:reverse(Collected, Acc));
        {error, _} -> lists:reverse(Acc)
    end.

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
handle_line(Sock, Opts, plain_payload, _Line) ->
    reply(Sock, Opts, auth_plain, <<"235 2.7.0 Authentication succeeded">>),
    {continue, none};
handle_line(Sock, Opts, none, Line) ->
    Cmd = iolist_to_binary(string:uppercase(hd(binary:split(Line, <<" ">>)))),
    case maps:get(close_after, Opts, undefined) of
        Cmd ->
            Seen = case get({closed_cmd, Cmd}) of undefined -> 0; N -> N end,
            put({closed_cmd, Cmd}, Seen + 1),
            case Seen < maps:get(close_times, Opts, 1) of
                true -> stop;
                false -> dispatch(Sock, Opts, Cmd, Line)
            end;
        _ -> dispatch(Sock, Opts, Cmd, Line)
    end.

dispatch(Sock, Opts, <<"EHLO">>, _Line) ->
    Greeting = maps:get(ehlo, Opts, [<<"250-fake.localhost">>, <<"250 AUTH PLAIN LOGIN">>]),
    [gen_tcp:send(Sock, [L, <<"\r\n">>]) || L <- Greeting],
    {continue, none};
dispatch(Sock, Opts, <<"AUTH">>, <<"AUTH LOGIN", _/binary>>) ->
    reply(Sock, Opts, auth_login, <<"334 VXNlcm5hbWU6">>),
    {continue, login_user};
dispatch(Sock, Opts, <<"AUTH">>, Line) ->
    case maps:get(plain_continue, Opts, false) andalso binary:match(Line, <<"PLAIN">>) =/= nomatch of
        true ->
            reply(Sock, Opts, auth_plain_challenge, <<"334 ">>),
            {continue, plain_payload};
        false ->
            N = case get(auth_n) of undefined -> 0; C -> C end,
            put(auth_n, N + 1),
            case maps:get(reject_first_auth, Opts, false) andalso N =:= 0 of
                true ->
                    gen_tcp:send(Sock, <<"535 5.7.8 authentication failed\r\n">>),
                    {continue, none};
                false ->
                    reply(Sock, Opts, auth_plain, <<"235 2.7.0 Authentication succeeded">>),
                    {continue, none}
            end
    end;
dispatch(Sock, Opts, <<"MAIL">>, _Line) ->
    N = case get(mail_count) of undefined -> 0; C -> C end,
    put(mail_count, N + 1),
    case maps:get(reject_first_mail, Opts, false) andalso N =:= 0 of
        true ->
            gen_tcp:send(Sock, <<"550 5.1.0 sender rejected\r\n">>),
            {continue, none};
        false ->
            reply(Sock, Opts, mail, <<"250 2.1.0 Ok">>),
            {continue, none}
    end;
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
