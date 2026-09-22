-module(pw_mail).
-behaviour(gen_server).
-export([start_link/0, enabled/0, public_host/0, send/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([central_host/1, smtp_configured/0, compose/1, public_url/0, rfc822/4]).
-endif.

-define(SERVER, ?MODULE).
-define(MAX_INFLIGHT, 4).
-define(SMTP_TIMEOUT_MS, 20000).

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

enabled() ->
    case explicit_mail_flag() of
        false -> false;
        true -> smtp_configured() andalso public_url() =/= <<>>;
        undefined ->
            central_host(public_host()) andalso smtp_configured() andalso public_url() =/= <<>>
    end.

public_host() ->
    host_from_url(public_url()).

send(Mail) when is_map(Mail) ->
    case enabled() of
        false -> {error, mail_disabled};
        true ->
            case whereis(?SERVER) of
                Pid when is_pid(Pid) -> gen_server:cast(?SERVER, {send, sanitize_mail(Mail)}), ok;
                _ -> {error, mail_unavailable}
            end
    end;
send(_) -> {error, invalid_mail}.

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{inflight => 0, queue => queue:new()}}.

handle_call(_Msg, _From, State) -> {reply, {error, unknown}, State}.

handle_cast({send, Mail}, State) ->
    {noreply, enqueue_or_start(Mail, State)};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'DOWN', _Ref, process, _Pid, _Reason}, State0) ->
    State = State0#{inflight => max(0, maps:get(inflight, State0, 1) - 1)},
    {noreply, pump(State)};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

enqueue_or_start(Mail, State) ->
    case maps:get(inflight, State, 0) < ?MAX_INFLIGHT of
        true -> start_delivery(Mail, State);
        false ->
            Q = maps:get(queue, State, queue:new()),
            Bounded = case queue:len(Q) >= 64 of
                true -> queue:in(Mail, queue:drop(Q));
                false -> queue:in(Mail, Q)
            end,
            State#{queue => Bounded}
    end.

pump(State) ->
    case queue:out(maps:get(queue, State, queue:new())) of
        {empty, Q} -> State#{queue => Q};
        {{value, Mail}, Q} -> start_delivery(Mail, State#{queue => Q})
    end.

start_delivery(Mail, State) ->
    {_Pid, _Ref} = spawn_monitor(fun() -> deliver(Mail) end),
    State#{inflight => maps:get(inflight, State, 0) + 1}.

sanitize_mail(Mail) ->
    maps:with([kind, to, username, token, app_name], Mail).

explicit_mail_flag() ->
    case os:getenv("PLAINWIRE_MAIL_ENABLED") of
        false -> undefined;
        Value ->
            case string:lowercase(string:trim(Value)) of
                "1" -> true;
                "true" -> true;
                "yes" -> true;
                "on" -> true;
                "0" -> false;
                "false" -> false;
                "no" -> false;
                "off" -> false;
                _ -> undefined
            end
    end.

smtp_configured() ->
    Host = string:trim(pw_util:env_str("PLAINWIRE_SMTP_HOST", <<>>)),
    User = string:trim(pw_util:env_str("PLAINWIRE_SMTP_USER", <<>>)),
    Pass = smtp_password(),
    Host =/= <<>> andalso User =/= <<>> andalso Pass =/= <<>>.

smtp_password() ->
    case os:getenv("PLAINWIRE_SMTP_PASS") of
        false -> <<>>;
        Value -> iolist_to_binary(string:trim(Value))
    end.

public_url() ->
    trim_slash(string:trim(pw_util:env_str("PLAINWIRE_PUBLIC_URL", <<>>))).

trim_slash(<<>>) -> <<>>;
trim_slash(Url) ->
    case binary:last(Url) of
        $/ -> trim_slash(binary:part(Url, 0, byte_size(Url) - 1));
        _ -> Url
    end.

host_from_url(<<>>) -> <<>>;
host_from_url(Url) ->
    case uri_string:parse(Url) of
        #{host := Host} when is_binary(Host) -> string:lowercase(Host);
        #{host := Host} when is_list(Host) -> string:lowercase(unicode:characters_to_binary(Host));
        _ -> <<>>
    end.

central_host(Host) ->
    Host =:= <<"plainwi.re">> orelse Host =:= <<"www.plainwi.re">>.

compose(#{kind := Kind, to := To, token := Token} = Mail) when Kind =:= password_reset; Kind =:= email_verify ->
    App = case header_safe(maps:get(app_name, Mail, <<>>)) of
        <<>> -> <<"Plainwire">>;
        Name -> Name
    end,
    Username = maps:get(username, Mail, <<"there">>),
    From = from_address(),
    {Subject, Path, Intro, Action} = case Kind of
        password_reset ->
            {<<"Reset your ", App/binary, " password">>,
             <<"/#reset/", Token/binary>>,
             <<"We received a request to reset the password for @">>,
             <<"this password reset link">>};
        email_verify ->
            {<<"Verify your ", App/binary, " email">>,
             <<"/#verify-email/", Token/binary>>,
             <<"Confirm the email address for @">>,
             <<"this verification link">>}
    end,
    Url = <<(public_url())/binary, Path/binary>>,
    Expiry = case Kind of password_reset -> <<"1 hour">>; email_verify -> <<"24 hours">> end,
    Text = iolist_to_binary([
        "Hi ", Username, ",", $\n, $\n,
        Intro, Username, " on ", App, ".", $\n,
        "Open ", Action, " within ", Expiry, ":", $\n, $\n,
        Url, $\n, $\n,
        "If you did not request this, you can ignore this email.", $\n
    ]),
    #{from => From, to => To, subject => Subject, text => Text};
compose(_) -> {error, invalid_mail}.

from_address() ->
    case string:trim(pw_util:env_str("PLAINWIRE_SMTP_FROM", <<>>)) of
        <<>> -> string:trim(pw_util:env_str("PLAINWIRE_SMTP_USER", <<>>));
        From -> From
    end.

deliver(Mail) ->
    case compose(Mail) of
        {error, Reason} ->
            logger:warning("[plainwire:mail] compose_failed reason=~p", [Reason]);
        Message ->
            case smtp_send(Message) of
                ok ->
                    logger:info("[plainwire:mail] sent kind=~s", [maps:get(kind, Mail, unknown)]);
                {error, Reason} ->
                    logger:warning("[plainwire:mail] send_failed kind=~s reason=~p",
                                   [maps:get(kind, Mail, unknown), redact_reason(Reason)])
            end
    end.

redact_reason({smtp_auth, _}) -> smtp_auth_failed;
redact_reason(Reason) -> Reason.

smtp_send(#{from := From, to := To, subject := Subject, text := Text}) ->
    Host = binary_to_list(string:trim(pw_util:env_str("PLAINWIRE_SMTP_HOST", <<>>))),
    Port = pw_util:env_int("PLAINWIRE_SMTP_PORT", 587),
    User = string:trim(pw_util:env_str("PLAINWIRE_SMTP_USER", <<>>)),
    Pass = smtp_password(),
    case smtp_connect(Host, Port) of
        {ok, Sock0} ->
            try smtp_session(Sock0, User, Pass, From, To, Subject, Text)
            after close_sock(Sock0)
            end;
        {error, Reason} -> {error, {connect, Reason}}
    end.

smtp_connect(Host, 465) ->
    case ssl:connect(Host, 465, [binary, {active, false}, {packet, raw}, {nodelay, true} | tls_opts(Host)], ?SMTP_TIMEOUT_MS) of
        {ok, Ssl} -> {ok, {ssl, Ssl}};
        {error, Reason} -> {error, Reason}
    end;
smtp_connect(Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}, {nodelay, true}], ?SMTP_TIMEOUT_MS) of
        {ok, Sock} -> {ok, {tcp, Sock}};
        {error, Reason} -> {error, Reason}
    end.

smtp_session(Sock0, User, Pass, From, To, Subject, Text) ->
    case expect(Sock0, 220) of
        {ok, Sock1} ->
            case ehlo(Sock1) of
                {ok, Sock2, Features} ->
                    case maybe_starttls(Sock2, Features) of
                        {ok, Sock3} ->
                            case ehlo(Sock3) of
                                {ok, Sock4, _} ->
                                    smtp_authenticated(Sock4, User, Pass, From, To, Subject, Text);
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

smtp_authenticated({tcp, _} = Sock, User, Pass, From, To, Subject, Text) ->
    case smtp_tls_required() of
        true -> {error, tls_required};
        false -> smtp_mail(Sock, User, Pass, From, To, Subject, Text)
    end;
smtp_authenticated(Sock, User, Pass, From, To, Subject, Text) ->
    smtp_mail(Sock, User, Pass, From, To, Subject, Text).

smtp_mail(Sock, User, Pass, From, To, Subject, Text) ->
    case smtp_auth(Sock, User, Pass) of
        {ok, Sock1} ->
            case command(Sock1, [<<"MAIL FROM:<">>, From, <<">">>], 250) of
                {ok, Sock2} ->
                    case command(Sock2, [<<"RCPT TO:<">>, To, <<">">>], [250, 251]) of
                        {ok, Sock3} ->
                            case command(Sock3, <<"DATA">>, 354) of
                                {ok, Sock4} ->
                                    Payload = rfc822(From, To, Subject, Text),
                                    case command(Sock4, [Payload, <<"\r\n.">>], 250) of
                                        {ok, Sock5} ->
                                            _ = command(Sock5, <<"QUIT">>, [221, 250]),
                                            ok;
                                        Error -> Error
                                    end;
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

smtp_auth(Sock, User, Pass) ->
    Plain = base64:encode(<<0, User/binary, 0, Pass/binary>>),
    case command(Sock, [<<"AUTH PLAIN ">>, Plain], 235) of
        {ok, Sock1} -> {ok, Sock1};
        {error, {smtp, 504, _}} -> smtp_auth_login(Sock, User, Pass);
        {error, {smtp, 534, _}} -> smtp_auth_login(Sock, User, Pass);
        {error, {smtp, 535, _}} = Error -> Error;
        _ -> smtp_auth_login(Sock, User, Pass)
    end.

smtp_auth_login(Sock, User, Pass) ->
    case command(Sock, <<"AUTH LOGIN">>, 334) of
        {ok, Sock1} ->
            case command(Sock1, base64:encode(User), 334) of
                {ok, Sock2} ->
                    case command(Sock2, base64:encode(Pass), 235) of
                        {ok, Sock3} -> {ok, Sock3};
                        {error, Reason} -> {error, {smtp_auth, Reason}}
                    end;
                {error, Reason} -> {error, {smtp_auth, Reason}}
            end;
        {error, Reason} -> {error, {smtp_auth, Reason}}
    end.

maybe_starttls({ssl, _} = Sock, _Features) -> {ok, Sock};
maybe_starttls(Sock, Features) ->
    case lists:member(<<"STARTTLS">>, Features) of
        false ->
            case smtp_tls_required() of
                true -> {error, tls_required};
                false -> {ok, Sock}
            end;
        true ->
            Host = smtp_host_list(),
            case command(Sock, <<"STARTTLS">>, 220) of
                {ok, Sock1} -> ssl_upgrade(Sock1, Host);
                Error -> Error
            end
    end.

smtp_tls_required() ->
    pw_util:env_bool("PLAINWIRE_SMTP_TLS", true).

smtp_host_list() ->
    binary_to_list(string:trim(pw_util:env_str("PLAINWIRE_SMTP_HOST", <<>>))).

tls_opts(Host) ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Host},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ].

ssl_upgrade({tcp, Sock}, Host) ->
    case ssl:connect(Sock, tls_opts(Host), ?SMTP_TIMEOUT_MS) of
        {ok, Ssl} -> {ok, {ssl, Ssl}};
        {error, Reason} -> {error, {tls, Reason}}
    end;
ssl_upgrade(Sock, _Host) -> {ok, Sock}.

ehlo_name() ->
    case public_host() of
        <<>> -> <<"plainwire">>;
        Host -> Host
    end.

ehlo(Sock) ->
    case send_line(Sock, [<<"EHLO ">>, ehlo_name()]) of
        ok ->
            case recv_reply(Sock) of
                {ok, 250, Lines} ->
                    Features = [string:uppercase(string:trim(Text)) || {_Code, Text} <- Lines],
                    {ok, Sock, Features};
                {ok, Code, Lines} -> {error, {smtp, Code, Lines}};
                Error -> Error
            end;
        Error -> Error
    end.

expect(Sock, Code) ->
    case recv_reply(Sock) of
        {ok, Code, _} -> {ok, Sock};
        {ok, Other, Lines} -> {error, {smtp, Other, Lines}};
        Error -> Error
    end.

command(Sock, Line, Expected) when is_integer(Expected) ->
    command(Sock, Line, [Expected]);
command(Sock, Line, Expected) when is_list(Expected) ->
    case send_line(Sock, Line) of
        ok ->
            case recv_reply(Sock) of
                {ok, Code, _} ->
                    case lists:member(Code, Expected) of
                        true -> {ok, Sock};
                        false -> {error, {smtp, Code}}
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

send_line({tcp, Sock}, Line) -> gen_tcp:send(Sock, [Line, <<"\r\n">>]);
send_line({ssl, Sock}, Line) -> ssl:send(Sock, [Line, <<"\r\n">>]).

recv_reply(Sock) -> recv_reply(Sock, []).
recv_reply(Sock, Acc) ->
    case recv_line(Sock) of
        {ok, <<A, B, C, Sep, Rest/binary>>} when A >= $0, A =< $9, B >= $0, B =< $9, C >= $0, C =< $9 ->
            Code = list_to_integer([A, B, C]),
            Text = binary:replace(Rest, <<"\r">>, <<>>, [global]),
            case Sep of
                $- -> recv_reply(Sock, [{Code, Text} | Acc]);
                $\s -> {ok, Code, lists:reverse([{Code, Text} | Acc])};
                _ -> {error, {bad_smtp, <<A, B, C, Sep, Rest/binary>>}}
            end;
        {ok, Line} -> {error, {bad_smtp, Line}};
        Error -> Error
    end.

recv_line(Sock) -> recv_line(Sock, <<>>).
recv_line(Sock, Acc) when byte_size(Acc) < 8192 ->
    case recv_bytes(Sock, 1) of
        {ok, <<"\n">>} -> {ok, Acc};
        {ok, <<"\r">>} -> recv_line(Sock, Acc);
        {ok, Byte} -> recv_line(Sock, <<Acc/binary, Byte/binary>>);
        Error -> Error
    end;
recv_line(_Sock, _Acc) -> {error, smtp_line_too_long}.

recv_bytes({tcp, Sock}, N) -> gen_tcp:recv(Sock, N, ?SMTP_TIMEOUT_MS);
recv_bytes({ssl, Sock}, N) -> ssl:recv(Sock, N, ?SMTP_TIMEOUT_MS).

close_sock({tcp, Sock}) ->
    try gen_tcp:close(Sock) catch _:_ -> ok end;
close_sock({ssl, Sock}) ->
    try ssl:close(Sock) catch _:_ -> ok end;
close_sock(_) -> ok.

header_safe(Value) ->
    Bin = pw_util:bin(Value),
    binary:replace(binary:replace(Bin, <<"\r">>, <<>>, [global]), <<"\n">>, <<>>, [global]).

%% Body lines are built with LF. Stuff any line that starts with a dot, then
%% emit CRLF so a lone "." cannot be read as the end of DATA.
smtp_dot_stuff(Text0) ->
    Text1 = binary:replace(pw_util:bin(Text0), <<"\r\n">>, <<"\n">>, [global]),
    Text = binary:replace(Text1, <<"\r">>, <<"\n">>, [global]),
    Lines = binary:split(Text, <<"\n">>, [global]),
    Stuffed = [case Line of
        <<".", _/binary>> -> <<".", Line/binary>>;
        Line -> Line
    end || Line <- Lines],
    iolist_to_binary(lists:join(<<"\r\n">>, Stuffed)).

rfc822(From0, To0, Subject0, Text) ->
    From = header_safe(From0),
    To = header_safe(To0),
    Subject = header_safe(Subject0),
    Date = iolist_to_binary(httpd_util:rfc1123_date()),
    Id = iolist_to_binary([pw_util:random_token(12), "@plainwire"]),
    SafeText = smtp_dot_stuff(Text),
    iolist_to_binary([
        "From: Plainwire <", From, ">\r\n",
        "To: <", To, ">\r\n",
        "Subject: ", Subject, "\r\n",
        "Date: ", Date, "\r\n",
        "Message-ID: <", Id, ">\r\n",
        "MIME-Version: 1.0\r\n",
        "Content-Type: text/plain; charset=utf-8\r\n",
        "Content-Transfer-Encoding: 8bit\r\n",
        "Auto-Submitted: auto-generated\r\n",
        "\r\n",
        SafeText
    ]).
