-module(plainwire_bot).
-behaviour(gen_server).

-export([start_link/1, stop/1,
         me/1, server/1, channels/1, messages/2, messages/3,
         send_message/3, send_message/4, delete_message/2, toggle_reaction/3,
         subscribe/2, unsubscribe_all/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([test_parse_base/1, test_tls_opts/1]).
-endif.

-define(DEFAULT_TIMEOUT, 10000).
-define(MAX_BACKOFF, 30000).

start_link(Opts0) when is_map(Opts0) ->
    Opts = Opts0#{owner => maps:get(owner, Opts0, self())},
    gen_server:start_link(?MODULE, Opts, []).

stop(Pid) -> gen_server:stop(Pid).
me(Pid) -> gen_server:call(Pid, {request, get, <<"/api/bot/me">>, undefined}, ?DEFAULT_TIMEOUT + 2000).
server(Pid) -> gen_server:call(Pid, {request, get, <<"/api/bot/server">>, undefined}, ?DEFAULT_TIMEOUT + 2000).
channels(Pid) -> gen_server:call(Pid, {request, get, <<"/api/bot/channels">>, undefined}, ?DEFAULT_TIMEOUT + 2000).
messages(Pid, ChannelId) -> messages(Pid, ChannelId, #{}).
messages(Pid, ChannelId, Params) ->
    Path0 = iolist_to_binary([<<"/api/bot/channels/">>, id(ChannelId), <<"/messages">>]),
    Path = with_query(Path0, Params),
    gen_server:call(Pid, {request, get, Path, undefined}, ?DEFAULT_TIMEOUT + 2000).
send_message(Pid, ChannelId, Body) -> send_message(Pid, ChannelId, Body, undefined).
send_message(Pid, ChannelId, Body, ReplyTo) ->
    Payload0 = #{body => bin(Body)},
    Payload = case ReplyTo of undefined -> Payload0; _ -> Payload0#{reply_to_id => ReplyTo} end,
    Path = iolist_to_binary([<<"/api/bot/channels/">>, id(ChannelId), <<"/messages">>]),
    gen_server:call(Pid, {request, post, Path, Payload}, ?DEFAULT_TIMEOUT + 2000).
delete_message(Pid, MessageId) ->
    Path = iolist_to_binary([<<"/api/bot/messages/">>, id(MessageId), <<"/delete">>]),
    gen_server:call(Pid, {request, post, Path, #{}}, ?DEFAULT_TIMEOUT + 2000).
toggle_reaction(Pid, MessageId, Emoji) ->
    Path = iolist_to_binary([<<"/api/bot/messages/">>, id(MessageId), <<"/reaction">>]),
    gen_server:call(Pid, {request, post, Path, #{emoji => bin(Emoji)}}, ?DEFAULT_TIMEOUT + 2000).
subscribe(Pid, Key) -> gen_server:call(Pid, {subscribe, bin(Key)}).
unsubscribe_all(Pid) -> gen_server:call(Pid, unsubscribe_all).

init(Opts) ->
    process_flag(trap_exit, true),
    Token = bin(maps:get(token, Opts, <<>>)),
    case {byte_size(Token) >= 16, parse_base(maps:get(base_url, Opts, <<"http://127.0.0.1:8080">>))} of
        {false, _} -> {stop, invalid_bot_token};
        {true, {error, Reason}} -> {stop, {invalid_base_url, Reason}};
        {true, {ok, Base}} ->
            State0 = #{base => Base, token => Token, owner => maps:get(owner, Opts),
                       http => undefined, ws => undefined, ws_ref => undefined, ws_up => false,
                       subscriptions => [], backoff => 1000, reconnect_ref => undefined},
            self() ! connect_ws,
            {ok, State0}
    end.

handle_call({request, Method, Path, Body}, _From, State0) ->
    case api_request(Method, Path, Body, State0) of
        {Reply, State} -> {reply, Reply, State}
    end;
handle_call({subscribe, Key}, _From, State=#{ws_up := true, ws := Ws, subscriptions := Subs}) ->
    ok = ws_send(Ws, maps:get(ws_ref, State), #{type => subscribe, key => Key}),
    {reply, ok, State#{subscriptions => lists:usort([Key | Subs])}};
handle_call({subscribe, Key}, _From, State=#{subscriptions := Subs}) ->
    %% Keep the intent and replay it after reconnect. The caller never needs to
    %% race Plainwire's network state just to establish an event subscription.
    {reply, ok, State#{subscriptions => lists:usort([Key | Subs])}};
handle_call(unsubscribe_all, _From, State=#{ws_up := Up, ws := Ws}) ->
    case Up of true -> ok = ws_send(Ws, maps:get(ws_ref, State), #{type => unsubscribe_all}); false -> ok end,
    {reply, ok, State#{subscriptions => []}};
handle_call(_Call, _From, State) -> {reply, {error, bad_request}, State}.

handle_cast(_Cast, State) -> {noreply, State}.

handle_info(connect_ws, State0) ->
    State1 = State0#{reconnect_ref => undefined},
    case open_connection(ws, State1) of
        {ok, Conn, State2} ->
            Base = maps:get(base, State2),
            Headers = auth_headers(State2),
            WsPath = base_path(Base, <<"/ws">>),
            Ref = gun:ws_upgrade(Conn, WsPath, Headers),
            {noreply, State2#{ws => Conn, ws_ref => Ref, ws_up => false}};
        {error, Reason, State2} ->
            notify(State2, {connection_error, websocket, Reason}),
            {noreply, schedule_reconnect(State2)}
    end;
handle_info({gun_upgrade, Conn, Ref, [<<"websocket">>], _Headers},
            State=#{ws := Conn, ws_ref := Ref}) ->
    State1 = State#{ws_ref => Ref, ws_up => true, backoff => 1000},
    lists:foreach(fun(Key) -> ok = ws_send(Conn, Ref, #{type => subscribe, key => Key}) end,
                  maps:get(subscriptions, State1)),
    notify(State1, connected),
    {noreply, State1};
handle_info({gun_response, Conn, Ref, _Fin, Status, _Headers},
            State=#{ws := Conn, ws_ref := Ref, ws_up := false}) ->
    notify(State, {connection_error, websocket, {upgrade_rejected, Status}}),
    catch gun:close(Conn),
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({gun_ws, Conn, Ref, {text, Data}}, State=#{ws := Conn, ws_ref := Ref}) ->
    case decode(Data) of
        {ok, Event} -> notify(State, {event, Event});
        {error, Reason} -> notify(State, {decode_error, Reason})
    end,
    {noreply, State};
handle_info({gun_ws, Conn, Ref, {close, Code, Reason}}, State=#{ws := Conn, ws_ref := Ref}) ->
    notify(State, {disconnected, Code, Reason}),
    catch gun:close(Conn),
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({gun_ws, Conn, Ref, {close, Reason}}, State=#{ws := Conn, ws_ref := Ref}) ->
    notify(State, {disconnected, Reason}),
    catch gun:close(Conn),
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({gun_ws, Conn, Ref, close}, State=#{ws := Conn, ws_ref := Ref}) ->
    notify(State, disconnected),
    catch gun:close(Conn),
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({gun_down, Conn, _Protocol, Reason, _Killed}, State=#{ws := Conn}) ->
    notify(State, {disconnected, Reason}),
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({gun_down, Conn, _Protocol, _Reason, _Killed}, State=#{http := Conn}) ->
    {noreply, State#{http => undefined}};
handle_info({gun_error, Conn, Ref, Reason}, State=#{ws := Conn, ws_ref := Ref}) ->
    notify(State, {connection_error, websocket, Reason}),
    catch gun:close(Conn),
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({gun_error, Conn, Reason}, State=#{ws := Conn}) ->
    notify(State, {connection_error, websocket, Reason}),
    catch gun:close(Conn),
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({'EXIT', Conn, _Reason}, State=#{ws := Conn}) ->
    {noreply, schedule_reconnect(State#{ws => undefined, ws_ref => undefined, ws_up => false})};
handle_info({'EXIT', Conn, _Reason}, State=#{http := Conn}) ->
    {noreply, State#{http => undefined}};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(maps:get(reconnect_ref, State, undefined)),
    close_conn(maps:get(ws, State, undefined)),
    close_conn(maps:get(http, State, undefined)),
    ok.
code_change(_Old, State, _Extra) -> {ok, State}.

api_request(Method, Path0, Body, State0) ->
    case ensure_http(State0) of
        {error, Reason, State} -> {{error, {connect_failed, Reason}}, State};
        {ok, Conn, State} ->
            Base = maps:get(base, State),
            Path = base_path(Base, Path0),
            {Headers, Payload} = request_body(Body, State),
            StreamRef = case Method of
                get -> gun:get(Conn, Path, Headers);
                delete -> gun:delete(Conn, Path, Headers);
                post -> gun:post(Conn, Path, Headers, Payload)
            end,
            Reply = await_response(Conn, StreamRef),
            case transport_failed(Reply) of
                true ->
                    catch gun:close(Conn),
                    {Reply, State#{http => undefined}};
                false -> {Reply, State}
            end
    end.

ensure_http(State=#{http := Conn}) when is_pid(Conn) -> {ok, Conn, State};
ensure_http(State) ->
    case open_connection(http, State) of
        {ok, Conn, State1} -> {ok, Conn, State1#{http => Conn}};
        {error, Reason, State1} -> {error, Reason, State1#{http => undefined}}
    end.

open_connection(_Kind, State) ->
    Base = maps:get(base, State),
    Host = maps:get(host, Base), Port = maps:get(port, Base), Scheme = maps:get(scheme, Base),
    Opts0 = #{protocols => [http], retry => 0, connect_timeout => ?DEFAULT_TIMEOUT},
    Opts = case Scheme of
        https -> Opts0#{transport => tls, tls_opts => tls_opts(Host)};
        http -> Opts0
    end,
    case gun:open(binary_to_list(Host), Port, Opts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?DEFAULT_TIMEOUT) of
                {ok, _Protocol} -> {ok, Conn, State};
                {error, Reason} -> catch gun:close(Conn), {error, Reason, State}
            end;
        {error, Reason} -> {error, Reason, State}
    end.

tls_opts(Host) ->
    Base = [{verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _} -> Base;
        _ -> [{server_name_indication, binary_to_list(Host)} | Base]
    end.

request_body(undefined, State) -> {auth_headers(State), <<>>};
request_body(Body, State) ->
    {[{<<"content-type">>, <<"application/json">>} | auth_headers(State)], jsx:encode(Body)}.

auth_headers(State) -> [{<<"authorization">>, <<"Bot ", (maps:get(token, State))/binary>>},
                        {<<"user-agent">>, <<"plainwire-erlang-bot/2.0">>}].

await_response(Conn, Ref) ->
    Deadline = erlang:monotonic_time(millisecond) + ?DEFAULT_TIMEOUT,
    await_final_response(Conn, Ref, Deadline).

await_final_response(Conn, Ref, Deadline) ->
    case remaining_timeout(Deadline) of
        0 -> {error, {request_failed, timeout}};
        Remaining ->
            case gun:await(Conn, Ref, Remaining) of
                {inform, _Status, _Headers} -> await_final_response(Conn, Ref, Deadline);
                {response, fin, Status, _Headers} -> decode_response(Status, <<>>);
                {response, nofin, Status, _Headers} ->
                    case remaining_timeout(Deadline) of
                        0 -> {error, {body_failed, timeout}};
                        BodyTimeout ->
                            case gun:await_body(Conn, Ref, BodyTimeout) of
                                {ok, Data} -> decode_response(Status, Data);
                                {error, Reason} -> {error, {body_failed, Reason}}
                            end
                    end;
                {error, Reason} -> {error, {request_failed, Reason}};
                Other -> {error, {request_failed, {unexpected_gun_reply, Other}}}
            end
    end.

remaining_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

transport_failed({error, {request_failed, _}}) -> true;
transport_failed({error, {body_failed, _}}) -> true;
transport_failed(_) -> false.

decode_response(Status, Data) when Status >= 200, Status < 300 ->
    case decode(Data) of
        {ok, #{<<"ok">> := true, <<"data">> := Value}} -> {ok, Value};
        {ok, #{<<"ok">> := true}} -> ok;
        {ok, Value} -> {ok, Value};
        {error, _} when Data =:= <<>> -> ok;
        {error, Reason} -> {error, {invalid_json, Reason}}
    end;
decode_response(Status, Data) ->
    Error = case decode(Data) of
        {ok, Map} -> Map;
        _ -> Data
    end,
    {error, {http, Status, Error}}.

decode(<<>>) -> {error, empty};
decode(Data) ->
    try {ok, jsx:decode(Data, [return_maps])}
    catch _:Reason -> {error, Reason}
    end.

ws_send(Conn, Ref, Map) -> gun:ws_send(Conn, Ref, {text, jsx:encode(Map)}).

schedule_reconnect(State=#{reconnect_ref := Ref}) when is_reference(Ref) -> State;
schedule_reconnect(State) ->
    Backoff = maps:get(backoff, State, 1000),
    Ref = erlang:send_after(Backoff, self(), connect_ws),
    State#{reconnect_ref => Ref, backoff => min(?MAX_BACKOFF, Backoff * 2)}.

notify(State, Event) ->
    maps:get(owner, State) ! {plainwire_bot, self(), Event},
    ok.

parse_base(Url0) ->
    try uri_string:parse(binary_to_list(bin(Url0))) of
        M when is_map(M) ->
            case normalize_scheme(maps:get(scheme, M, undefined)) of
                invalid -> {error, unsupported_scheme};
                Scheme ->
                    Host = bin(maps:get(host, M, <<>>)),
                    Port0 = maps:get(port, M, undefined),
                    Port = case Port0 of undefined when Scheme =:= https -> 443; undefined -> 80; P -> P end,
                    UserInfo = maps:get(userinfo, M, undefined),
                    Query = maps:get(query, M, undefined),
                    Fragment = maps:get(fragment, M, undefined),
                    case {byte_size(Host) > 0, is_integer(Port) andalso Port > 0 andalso Port =< 65535,
                          UserInfo, Query, Fragment} of
                        {false, _, _, _, _} -> {error, missing_host};
                        {_, false, _, _, _} -> {error, invalid_port};
                        {_, _, U, _, _} when U =/= undefined, U =/= <<>>, U =/= "" -> {error, userinfo_not_allowed};
                        {_, _, _, Q, _} when Q =/= undefined, Q =/= <<>>, Q =/= "" -> {error, query_not_allowed};
                        {_, _, _, _, F} when F =/= undefined, F =/= <<>>, F =/= "" -> {error, fragment_not_allowed};
                        _ ->
                            RawPath = bin(maps:get(path, M, <<>>)),
                            Path = case RawPath of <<"/">> -> <<>>; _ -> trim_slash(RawPath) end,
                            {ok, #{scheme => Scheme, host => Host, port => Port, path => Path}}
                    end
            end;
        _ -> {error, invalid_url}
    catch _:_ -> {error, invalid_url} end.

normalize_scheme("http") -> http;
normalize_scheme(<<"http">>) -> http;
normalize_scheme("https") -> https;
normalize_scheme(<<"https">>) -> https;
normalize_scheme(_) -> invalid.

-ifdef(TEST).
test_parse_base(Url) -> parse_base(Url).
test_tls_opts(Host) -> tls_opts(bin(Host)).
-endif.

base_path(Base, Path) -> <<(maps:get(path, Base, <<>>))/binary, Path/binary>>.
trim_slash(<<>>) -> <<>>;
trim_slash(Path) ->
    case binary:last(Path) of $/ -> binary:part(Path, 0, byte_size(Path) - 1); _ -> Path end.

with_query(Path, Params) when is_map(Params) ->
    Pairs = [{bin(K), bin(V)} || {K,V} <- maps:to_list(Params), V =/= undefined, V =/= <<>>],
    case Pairs of
        [] -> Path;
        _ -> <<Path/binary, "?", (iolist_to_binary(uri_string:compose_query(Pairs)))/binary>>
    end;
with_query(Path, _) -> Path.

id(I) when is_integer(I) -> integer_to_binary(I);
id(B) -> bin(B).
bin(B) when is_binary(B) -> B;
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref), ok.
close_conn(undefined) -> ok;
close_conn(Conn) -> catch gun:close(Conn), ok.
