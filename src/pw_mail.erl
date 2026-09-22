-module(pw_mail).
-behaviour(gen_server).
-export([start_link/0, enabled/0, public_host/0, send/1, deliver_now/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([central_host/1, smtp_configured/0, compose/1, public_url/0, rfc822/4, smtp_send/1, tls_opts/1]).
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
    enqueue(Mail, none);
send(_) -> {error, invalid_mail}.

%% Wait until the SMTP server accepts the message. Account verification uses
%% this so the API does not tell someone to check an inbox that was never sent.
deliver_now(Mail) when is_map(Mail) ->
    Ref = make_ref(),
    case enqueue(Mail, {self(), Ref}) of
        ok ->
            receive
                {mail_result, Ref, Result} -> Result
            after 35000 -> {error, mail_timeout}
            end;
        {error, Reason} -> {error, Reason}
    end;
deliver_now(_) -> {error, invalid_mail}.

enqueue(Mail, ReplyTo) ->
    case enabled() of
        false -> {error, mail_disabled};
        true ->
            case whereis(?SERVER) of
                Pid when is_pid(Pid) ->
                    gen_server:cast(Pid, mail_cast(sanitize_mail(Mail), ReplyTo)),
                    ok;
                _ -> {error, mail_unavailable}
            end
    end.

mail_cast(Mail, none) -> {send, Mail};
mail_cast(Mail, ReplyTo) -> {send, Mail, ReplyTo}.

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{inflight => 0, queue => queue:new()}}.

handle_call(_Msg, _From, State) -> {reply, {error, unknown}, State}.

handle_cast({send, Mail}, State) ->
    {noreply, enqueue_or_start(Mail, none, State)};
handle_cast({send, Mail, ReplyTo}, State) ->
    {noreply, enqueue_or_start(Mail, ReplyTo, State)};
handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'DOWN', _Ref, process, _Pid, _Reason}, State0) ->
    State = State0#{inflight => max(0, maps:get(inflight, State0, 1) - 1)},
    {noreply, pump(State)};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

enqueue_or_start(Mail, ReplyTo, State) ->
    case maps:get(inflight, State, 0) < ?MAX_INFLIGHT of
        true -> start_delivery(Mail, ReplyTo, State);
        false ->
            Q = maps:get(queue, State, queue:new()),
            Item = {Mail, ReplyTo},
            Bounded = case queue:len(Q) >= 64 of
                true ->
                    {{value, Dropped}, Q1} = queue:out(Q),
                    reply_waiter(Dropped, {error, mail_busy}),
                    queue:in(Item, Q1);
                false -> queue:in(Item, Q)
            end,
            State#{queue => Bounded}
    end.

pump(State) ->
    case maps:get(inflight, State, 0) >= ?MAX_INFLIGHT of
        true -> State;
        false ->
            case queue:out(maps:get(queue, State, queue:new())) of
                {empty, Q} -> State#{queue => Q};
                {{value, {Mail, ReplyTo}}, Q} -> start_delivery(Mail, ReplyTo, State#{queue => Q})
            end
    end.

start_delivery(Mail, ReplyTo, State) ->
    {_Pid, _Ref} = spawn_monitor(fun() ->
        Result = try deliver(Mail) catch Class:Reason -> {error, {Class, Reason}} end,
        reply_waiter(ReplyTo, client_result(Result))
    end),
    State#{inflight => maps:get(inflight, State, 0) + 1}.

reply_waiter({Pid, Ref}, Result) when is_pid(Pid), is_reference(Ref) ->
    Pid ! {mail_result, Ref, Result};
reply_waiter({_Mail, ReplyTo}, Result) ->
    reply_waiter(ReplyTo, Result);
reply_waiter(_, _) -> ok.

client_result(ok) -> ok;
client_result({error, mail_disabled}) -> {error, mail_disabled};
client_result({error, mail_unavailable}) -> {error, mail_unavailable};
client_result({error, mail_busy}) -> {error, mail_busy};
client_result({error, mail_timeout}) -> {error, mail_timeout};
client_result({error, invalid_mail}) -> {error, invalid_mail};
client_result({error, tls_required}) -> {error, mail_tls};
client_result({error, {tls, _}}) -> {error, mail_tls};
client_result({error, {smtp, 535, _}}) -> {error, mail_auth};
client_result({error, {smtp_auth, _}}) -> {error, mail_auth};
client_result({error, timeout}) -> {error, mail_timeout};
client_result({error, closed}) -> {error, mail_unavailable};
client_result({error, {connect, _}}) -> {error, mail_unavailable};
client_result({error, _}) -> {error, mail_rejected}.

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

compose(#{kind := Kind, to := To0, token := Token0} = Mail) when Kind =:= password_reset; Kind =:= email_verify ->
    Token = header_safe(Token0),
    App = case header_safe(maps:get(app_name, Mail, <<>>)) of
        <<>> -> <<"Plainwire">>;
        Name -> Name
    end,
    Username = case header_safe(maps:get(username, Mail, <<>>)) of
        <<>> -> <<"there">>;
        Display -> Display
    end,
    From = header_safe(from_address()),
    To = header_safe(To0),
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
            logger:warning("[plainwire:mail] compose_failed reason=~p", [Reason]),
            {error, Reason};
        Message ->
            case smtp_send(Message) of
                ok ->
                    logger:info("[plainwire:mail] sent kind=~s", [maps:get(kind, Mail, unknown)]),
                    ok;
                {error, Reason} = Error ->
                    logger:warning("[plainwire:mail] send_failed kind=~s reason=~p",
                                   [maps:get(kind, Mail, unknown), redact_reason(Reason)]),
                    Error
            end
    end.

redact_reason({smtp_auth, _}) -> smtp_auth_failed;
redact_reason({smtp, 535, _}) -> smtp_auth_failed;
redact_reason(Reason) -> Reason.

smtp_send(Message) -> smtp_send(Message, 1).

smtp_send(Message, Attempt) ->
    case smtp_once(Message) of
        ok -> ok;
        {error, Reason} = Error ->
            case Attempt < 2 andalso transient_failure(Reason) of
                true ->
                    timer:sleep(250),
                    smtp_send(Message, Attempt + 1);
                false -> Error
            end
    end.

%% One attempt. The live socket is the post-STARTTLS SSL socket when the
%% session upgraded; closing the original TCP socket instead resets the TLS
%% session and some servers then drop a message they already accepted.
smtp_once(#{from := From, to := To, subject := Subject, text := Text}) ->
    Host = binary_to_list(string:trim(pw_util:env_str("PLAINWIRE_SMTP_HOST", <<>>))),
    Port = pw_util:env_int("PLAINWIRE_SMTP_PORT", 587),
    User = header_safe(string:trim(pw_util:env_str("PLAINWIRE_SMTP_USER", <<>>))),
    Pass = smtp_password(),
    case smtp_connect(Host, Port) of
        {ok, Io} ->
            put(pw_mail_conn, Io),
            Result = try smtp_session(Io, User, Pass, header_safe(From), header_safe(To), header_safe(Subject), Text)
                     catch Class:Reason -> {error, {Class, Reason}}
                     end,
            close_io(erase(pw_mail_conn)),
            Result;
        {error, Reason} -> {error, {connect, Reason}}
    end;
smtp_once(_) -> {error, invalid_mail}.

transient_failure({connect, _}) -> true;
transient_failure(closed) -> true;
transient_failure(timeout) -> true;
transient_failure({smtp, 421, _}) -> true;
transient_failure({smtp, Code, _}) when Code >= 450, Code =< 452 -> true;
transient_failure(_) -> false.

track(Io) -> put(pw_mail_conn, Io), Io.

live(Fallback) ->
    case get(pw_mail_conn) of
        #{} = Io -> Io;
        _ -> Fallback
    end.

smtp_connect(Host, 465) ->
    case ssl:connect(Host, 465, [binary, {active, false}, {packet, raw}, {nodelay, true} | tls_opts(Host)], ?SMTP_TIMEOUT_MS) of
        {ok, Ssl} -> {ok, #{mod => ssl, sock => Ssl, buf => <<>>}};
        {error, Reason} -> {error, Reason}
    end;
smtp_connect(Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}, {nodelay, true}], ?SMTP_TIMEOUT_MS) of
        {ok, Sock} -> {ok, #{mod => gen_tcp, sock => Sock, buf => <<>>}};
        {error, Reason} -> {error, Reason}
    end.

smtp_session(Io0, User, Pass, From, To, Subject, Text) ->
    case expect(Io0, 220) of
        {ok, Io1} ->
            case ehlo(Io1) of
                {ok, Io2, Features} ->
                    case maybe_starttls(Io2, Features) of
                        {ok, Io3, again} ->
                            case ehlo(Io3) of
                                {ok, Io4, _} -> smtp_authenticated(Io4, User, Pass, From, To, Subject, Text);
                                Error -> Error
                            end;
                        {ok, Io3, same} -> smtp_authenticated(Io3, User, Pass, From, To, Subject, Text);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

smtp_authenticated(#{mod := gen_tcp} = Io, User, Pass, From, To, Subject, Text) ->
    case smtp_tls_required() of
        true -> {error, tls_required};
        false -> smtp_mail(Io, User, Pass, From, To, Subject, Text)
    end;
smtp_authenticated(Io, User, Pass, From, To, Subject, Text) ->
    smtp_mail(Io, User, Pass, From, To, Subject, Text).

smtp_mail(Io, User, Pass, From, To, Subject, Text) ->
    case smtp_auth(Io, User, Pass) of
        {ok, Io1} -> submit(Io1, User, From, To, Subject, Text);
        Error -> Error
    end.

%% Some providers reject MAIL FROM when it is not the authenticated address.
%% Retry the envelope (and the header) with the SMTP user. No new setting.
submit(Io, User, From, To, Subject, Text) ->
    case command(Io, [<<"MAIL FROM:<">>, From, <<">">>], 250) of
        {ok, Io1} -> recipients(Io1, To, Subject, Text, From);
        {error, {smtp, Code, _}} when (Code =:= 550 orelse Code =:= 553 orelse Code =:= 551 orelse Code =:= 501),
                                       From =/= User, User =/= <<>> ->
            case command(live(Io), [<<"MAIL FROM:<">>, User, <<">">>], 250) of
                {ok, Io1} -> recipients(Io1, To, Subject, Text, User);
                Error -> Error
            end;
        Error -> Error
    end.

recipients(Io, To, Subject, Text, From) ->
    case command(Io, [<<"RCPT TO:<">>, To, <<">">>], [250, 251]) of
        {ok, Io1} ->
            case command(Io1, <<"DATA">>, 354) of
                {ok, Io2} ->
                    Payload = rfc822(From, To, Subject, Text),
                    case command(Io2, [Payload, <<"\r\n.">>], 250) of
                        {ok, Io3} ->
                            _ = command(Io3, <<"QUIT">>, [221, 250]),
                            ok;
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

smtp_auth(Io, User, Pass) ->
    Plain = base64:encode(<<0, User/binary, 0, Pass/binary>>),
    case command(Io, [<<"AUTH PLAIN ">>, Plain], 235) of
        {ok, Io1} -> {ok, Io1};
        %% 535 means the credentials were read and rejected. Retrying AUTH LOGIN
        %% with the same secret spends a second failed attempt per mail against
        %% the provider's lockout counter, so stop here.
        {error, {smtp, 535, _}} = Error -> Error;
        %% 334 means the server wants the SASL payload as the next line. Sending
        %% AUTH LOGIN here aborts the exchange and the message is never accepted.
        {error, {smtp, 334, _}} ->
            case command(live(Io), Plain, 235) of
                {ok, Io1} -> {ok, Io1};
                {error, {smtp, 535, _}} = Error -> Error;
                {error, {smtp, _, _}} -> smtp_auth_login(live(Io), User, Pass);
                {error, _} = Error -> Error
            end;
        %% Any other refusal (504, 534, ...) means PLAIN was not usable on this
        %% connection; LOGIN is worth a try.
        {error, {smtp, _, _}} -> smtp_auth_login(live(Io), User, Pass);
        %% A transport error is not an auth problem. Propagate it unchanged so
        %% the log names the real fault.
        {error, _} = Error -> Error
    end.

smtp_auth_login(Io, User, Pass) ->
    case command(Io, <<"AUTH LOGIN">>, 334) of
        {ok, Io1} ->
            case command(Io1, base64:encode(User), 334) of
                {ok, Io2} ->
                    case command(Io2, base64:encode(Pass), 235) of
                        {ok, Io3} -> {ok, Io3};
                        {error, Reason} -> {error, {smtp_auth, Reason}}
                    end;
                {error, Reason} -> {error, {smtp_auth, Reason}}
            end;
        {error, Reason} -> {error, {smtp_auth, Reason}}
    end.

maybe_starttls(#{mod := ssl} = Io, _Features) -> {ok, track(Io), again};
maybe_starttls(Io, Features) ->
    case lists:member(<<"STARTTLS">>, Features) of
        false ->
            case smtp_tls_required() of
                true -> {error, tls_required};
                false -> {ok, Io, same}
            end;
        true ->
            Host = smtp_host_list(),
            case command(Io, <<"STARTTLS">>, 220) of
                {ok, Io1} ->
                    case ssl_upgrade(Io1, Host) of
                        {ok, Io2} -> {ok, Io2, again};
                        Error -> Error
                    end;
                Error -> Error
            end
    end.

smtp_tls_required() ->
    pw_util:env_bool("PLAINWIRE_SMTP_TLS", true).

smtp_host_list() ->
    binary_to_list(string:trim(pw_util:env_str("PLAINWIRE_SMTP_HOST", <<>>))).

tls_opts(Host) ->
    [
        %% ssl:connect defaults to an active, list-mode socket. The SMTP reader
        %% uses a passive binary recv. On port 587 the socket is upgraded with
        %% these options alone, so leaving the defaults makes the first read
        %% after STARTTLS fail and the message is never submitted.
        {active, false},
        {mode, binary},
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Host},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ].

ssl_upgrade(#{mod := gen_tcp, sock := Sock}, Host) ->
    case ssl:connect(Sock, tls_opts(Host), ?SMTP_TIMEOUT_MS) of
        {ok, Ssl} -> {ok, track(#{mod => ssl, sock => Ssl, buf => <<>>})};
        {error, Reason} -> {error, {tls, Reason}}
    end;
ssl_upgrade(Io, _Host) -> {ok, track(Io)}.

ehlo_name() ->
    case public_host() of
        <<>> -> <<"plainwire">>;
        Host -> Host
    end.

ehlo(Io) ->
    case send_line(Io, [<<"EHLO ">>, ehlo_name()]) of
        ok ->
            case recv_reply(Io) of
                {ok, 250, Lines, Io1} ->
                    Features = [string:uppercase(string:trim(Text)) || {_Code, Text} <- Lines],
                    {ok, track(Io1), Features};
                {ok, Code, Lines, Io1} -> track(Io1), {error, {smtp, Code, Lines}};
                {error, Reason, Io1} -> track(Io1), {error, Reason};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

expect(Io, Code) ->
    case recv_reply(Io) of
        {ok, Code, _, Io1} -> {ok, track(Io1)};
        {ok, Other, Lines, Io1} -> track(Io1), {error, {smtp, Other, Lines}};
        {error, Reason, Io1} -> track(Io1), {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

command(Io, Line, Expected) when is_integer(Expected) ->
    command(Io, Line, [Expected]);
command(Io, Line, Expected) when is_list(Expected) ->
    case send_line(Io, Line) of
        ok ->
            case recv_reply(Io) of
                {ok, Code, Lines, Io1} ->
                    track(Io1),
                    case lists:member(Code, Expected) of
                        true -> {ok, Io1};
                        false -> {error, {smtp, Code, Lines}}
                    end;
                {error, Reason, Io1} -> track(Io1), {error, Reason};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

send_line(#{mod := Mod, sock := Sock}, Line) ->
    Mod:send(Sock, [Line, <<"\r\n">>]).

recv_reply(Io) -> recv_reply(Io, []).
recv_reply(Io, Acc) ->
    case recv_line(Io) of
        {ok, <<A, B, C, Sep, Rest/binary>>, Io1} when A >= $0, A =< $9, B >= $0, B =< $9, C >= $0, C =< $9 ->
            Code = list_to_integer([A, B, C]),
            Text = binary:replace(Rest, <<"\r">>, <<>>, [global]),
            case Sep of
                $- -> recv_reply(Io1, [{Code, Text} | Acc]);
                $\s -> {ok, Code, lists:reverse([{Code, Text} | Acc]), Io1};
                _ -> {error, {bad_smtp, <<A, B, C, Sep, Rest/binary>>}, Io1}
            end;
        {ok, Line, Io1} -> {error, {bad_smtp, Line}, Io1};
        {error, Reason, Io1} -> {error, Reason, Io1};
        {error, Reason} -> {error, Reason}
    end.

recv_line(#{buf := Buf} = Io) when byte_size(Buf) >= 8192 ->
    {error, smtp_line_too_long, Io};
recv_line(#{buf := Buf} = Io) ->
    case binary:match(Buf, <<"\n">>) of
        {Pos, _} ->
            <<Line:Pos/binary, "\n", Rest/binary>> = Buf,
            {ok, strip_cr(Line), Io#{buf => Rest}};
        nomatch ->
            case recv_chunk(Io) of
                {ok, Io1} -> recv_line(Io1);
                Error -> Error
            end
    end.

recv_chunk(#{mod := Mod, sock := Sock, buf := Buf} = Io) ->
    case Mod:recv(Sock, 0, ?SMTP_TIMEOUT_MS) of
        {ok, <<>>} -> {error, closed, Io};
        {ok, Data} -> {ok, Io#{buf => <<Buf/binary, Data/binary>>}};
        {error, Reason} -> {error, Reason, Io}
    end.

strip_cr(<<>>) -> <<>>;
strip_cr(Line) ->
    Size = byte_size(Line) - 1,
    case Line of
        <<Trimmed:Size/binary, "\r">> -> Trimmed;
        _ -> Line
    end.

close_io(undefined) -> ok;
close_io(#{mod := ssl, sock := Sock}) ->
    try ssl:close(Sock) catch _:_ -> ok end,
    ok;
close_io(#{mod := gen_tcp, sock := Sock}) ->
    try gen_tcp:close(Sock) catch _:_ -> ok end,
    ok;
close_io(_) -> ok.

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
    {Encoding, Encoded} = transfer_encode(pw_util:bin(Text)),
    iolist_to_binary([
        "From: Plainwire <", From, ">\r\n",
        "To: <", To, ">\r\n",
        "Subject: ", Subject, "\r\n",
        "Date: ", smtp_date(), "\r\n",
        "Message-ID: <", message_id(From), ">\r\n",
        "MIME-Version: 1.0\r\n",
        "Content-Type: text/plain; charset=utf-8\r\n",
        "Content-Transfer-Encoding: ", Encoding, "\r\n",
        "Auto-Submitted: auto-generated\r\n",
        "\r\n",
        smtp_dot_stuff(Encoded)
    ]).

message_id(From) ->
    Domain = case binary:split(From, <<"@">>) of
        [_, Domain0] when byte_size(Domain0) >= 3 -> Domain0;
        _ ->
            case public_host() of
                <<>> -> <<"plainwire.local">>;
                Host -> Host
            end
    end,
    <<(pw_util:random_token(16))/binary, $@, Domain/binary>>.

smtp_date() ->
    try iolist_to_binary(httpd_util:rfc1123_date())
    catch _:_ -> <<"Thu, 01 Jan 1970 00:00:00 GMT">>
    end.

%% 7bit when the body is ASCII. Quoted-printable otherwise, so a server that
%% did not advertise 8BITMIME still accepts the message.
transfer_encode(Body) ->
    case ascii_body(Body) of
        true -> {<<"7bit">>, Body};
        false -> {<<"quoted-printable">>, quoted_printable(Body)}
    end.

ascii_body(<<>>) -> true;
ascii_body(<<C, Rest/binary>>) when C =:= $\t; C =:= $\n; C =:= $\r; C >= 32, C =< 126 ->
    ascii_body(Rest);
ascii_body(_) -> false.

quoted_printable(Body) ->
    iolist_to_binary(lists:reverse(qp(binary_to_list(Body), 0, []))).

qp([], _Col, Acc) -> Acc;
qp([$\r, $\n | Rest], _Col, Acc) -> qp(Rest, 0, [$\n, $\r | Acc]);
qp([$\n | Rest], _Col, Acc) -> qp(Rest, 0, [$\n, $\r | Acc]);
qp([C | Rest], Col, Acc) when Col >= 73 -> qp([C | Rest], 0, [$\n, $\r, $= | Acc]);
qp([C | Rest], Col, Acc) when C =:= $\t; C >= 33, C =< 126, C =/= $= ->
    qp(Rest, Col + 1, [C | Acc]);
qp([$\s | Rest], Col, Acc) ->
    case Rest of
        [$\n | _] -> qp(Rest, Col + 3, ["=20" | Acc]);
        [$\r, $\n | _] -> qp(Rest, Col + 3, ["=20" | Acc]);
        [] -> qp([], Col + 3, ["=20" | Acc]);
        _ -> qp(Rest, Col + 1, [$\s | Acc])
    end;
qp([C | Rest], Col, Acc) ->
    Hex = io_lib:format("=~2.16.0B", [C]),
    qp(Rest, Col + 3, [Hex | Acc]).
