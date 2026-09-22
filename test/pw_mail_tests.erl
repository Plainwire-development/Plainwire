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
