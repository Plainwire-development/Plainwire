-module(pw_ws).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

init(Req0, _State) ->
    case origin_allowed(Req0) of
        false ->
            {ok, cowboy_req:reply(403, #{}, <<"forbidden origin">>, Req0), #{}};
        true ->
            case pw_util:cookie_value(Req0, <<"pw_session">>) of
                undefined -> {ok, cowboy_req:reply(401, #{}, <<"not authenticated">>, Req0), #{}};
                Token ->
                    case pw_db:session(Token) of
                        {ok, Session} ->
                            User = maps:get(user, Session),
                            Status = maps:get(status, User, <<"online">>),
                            WsOpts = #{idle_timeout => 60000, max_frame_size => 65536},
                            {cowboy_websocket, Req0, #{session=>Session, uid=>maps:get(id,User), subs=>[], voice=>undefined, call=>undefined, status=>Status}, WsOpts};
                        _ -> {ok, cowboy_req:reply(401, #{}, <<"not authenticated">>, Req0), #{}}
                    end
            end
    end.

websocket_init(State=#{uid:=Uid, status:=Status}) ->
    pw_hub:connect(Uid, self(), Status),
    {reply, {text, pw_util:json(#{type=>hello, session=>maps:get(session,State)})}, State}.

websocket_handle({text, Data}, State0=#{uid:=Uid}) ->
    case byte_size(Data) =< 65536 andalso pw_rate:allow({ws, Uid}, 240, 60000) of
        true ->
            case safe_json_decode(Data) of
                M when is_map(M) -> handle_msg(M, State0);
                _ -> {ok, State0}
            end;
        false ->
            reply_error(State0, rate_limited)
    end;
websocket_handle(_Frame, State) -> {ok, State}.

handle_msg(#{<<"type">> := <<"ping">>}, State) ->
    {reply, {text, pw_util:json(#{type => pong, ts => pw_util:now_ms()})}, State};
handle_msg(#{<<"type">> := <<"subscribe">>, <<"key">> := Key0}, State=#{uid:=Uid, subs := Subs}) ->
    case parse_key(Key0) of
        undefined -> {ok, State};
        Key ->
            case can_subscribe(Uid, Key) of
                true -> pw_hub:subscribe(self(), Key), {ok, State#{subs=>lists:usort([Key|Subs])}};
                false -> reply_error(State, forbidden)
            end
    end;
handle_msg(#{<<"type">> := <<"unsubscribe_all">>}, State) ->
    pw_hub:unsubscribe_all(self()),
    {ok, State#{subs=>[]}};
handle_msg(#{<<"type">> := <<"voice_join">>, <<"channel_id">> := Cid0}, State=#{uid:=Uid, session:=Session}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:member_of_channel(Uid, Cid) of
        true -> maybe_leave_voice(State), pw_hub:voice_join(Cid, Uid, self(), maps:get(user,Session)), {ok, State#{voice=>Cid}};
        false -> reply_error(State, forbidden)
    end;
handle_msg(#{<<"type">> := <<"voice_leave">>}, State) -> S1 = maybe_leave_voice(State), {ok, S1#{voice=>undefined}};
handle_msg(#{<<"type">> := <<"voice_state">>, <<"patch">> := Patch}, State=#{uid:=Uid, session:=Session, voice:=Cid}) when is_integer(Cid), is_map(Patch) ->
    Clean = #{muted=>pw_util:bool(maps:get(<<"muted">>,Patch,false)), deafened=>pw_util:bool(maps:get(<<"deafened">>,Patch,false))},
    pw_hub:voice_state(Cid, Uid, Clean, maps:get(user,Session)), {ok, State};
handle_msg(#{<<"type">> := <<"voice_signal">>, <<"to_user_id">> := To0, <<"signal">> := Sig}, State=#{uid:=Uid, voice:=Cid}) when is_integer(Cid) ->
    case {pw_util:int(To0), signal_ok(Sig)} of
        {To, true} when is_integer(To), To > 0 -> pw_hub:voice_signal(Cid, Uid, To, Sig), {ok, State};
        _ -> {ok, State}
    end;
handle_msg(#{<<"type">> := <<"call_ring">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid, session:=Session}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:conversation_peer_ids(Uid, Cid) of
        {ok, Targets0} ->
            case lists:filter(fun(T) -> T =/= Uid end, Targets0) of
                [] ->
                    reply_error(State, no_peers);
                Targets ->
                    S1 = maybe_leave_call(State),
                    pw_hub:call_ring(Cid, Uid, self(), maps:get(user, Session), Targets),
                    {ok, S1#{call => Cid}}
            end;
        false ->
            reply_error(State, forbidden);
        {error, _} ->
            reply_error(State, forbidden)
    end;
handle_msg(#{<<"type">> := <<"call_accept">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid, session:=Session}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:member_of_conversation(Uid, Cid) of
        true ->
            S1 = maybe_leave_call(State),
            pw_hub:call_accept(Cid, Uid, self(), maps:get(user, Session)),
            {ok, S1#{call => Cid}};
        false ->
            reply_error(State, forbidden)
    end;
handle_msg(#{<<"type">> := <<"call_decline">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:member_of_conversation(Uid, Cid) of
        true -> pw_hub:call_decline(Cid, Uid), {ok, State};
        false -> reply_error(State, forbidden)
    end;
handle_msg(#{<<"type">> := <<"call_cancel">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:member_of_conversation(Uid, Cid) of
        true -> pw_hub:call_cancel(Cid, Uid), {ok, State};
        false -> reply_error(State, forbidden)
    end;
handle_msg(#{<<"type">> := <<"call_join">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid, session:=Session}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:member_of_conversation(Uid, Cid) of
        true -> maybe_leave_call(State), pw_hub:call_accept(Cid, Uid, self(), maps:get(user,Session)), {ok, State#{call=>Cid}};
        false -> reply_error(State, forbidden)
    end;
handle_msg(#{<<"type">> := <<"call_leave">>}, State) -> S1 = maybe_leave_call(State), {ok, S1#{call=>undefined}};
handle_msg(#{<<"type">> := <<"call_state">>, <<"patch">> := Patch}, State=#{uid:=Uid, session:=Session, call:=Cid}) when is_integer(Cid), is_map(Patch) ->
    Clean = #{muted=>pw_util:bool(maps:get(<<"muted">>,Patch,false)), deafened=>pw_util:bool(maps:get(<<"deafened">>,Patch,false))},
    pw_hub:call_state(Cid, Uid, Clean, maps:get(user,Session)), {ok, State};
handle_msg(#{<<"type">> := <<"call_signal">>, <<"to_user_id">> := To0, <<"signal">> := Sig}, State=#{uid:=Uid, call:=Cid}) when is_integer(Cid) ->
    case {pw_util:int(To0), signal_ok(Sig)} of
        {To, true} when is_integer(To), To > 0 -> pw_hub:call_signal(Cid, Uid, To, Sig), {ok, State};
        _ -> {ok, State}
    end;
handle_msg(#{<<"type">> := <<"presence_update">>, <<"status">> := Status0}, #{uid:=Uid}=State) ->
    Status = clean_status(Status0),
    pw_hub:status_update(Uid, Status),
    {ok, State#{status => Status}};
handle_msg(_, State) -> {ok, State}.

websocket_info({hub_json, Event}, State) -> {reply, {text, pw_util:json(Event)}, State};
websocket_info(_, State) -> {ok, State}.

terminate(_, _, State) ->
    maybe_leave_voice(State), maybe_leave_call(State), pw_hub:disconnect(self()), ok.

parse_key(Bin) when is_binary(Bin) ->
    case binary:split(Bin, <<":">>, [global]) of
        [<<"channel">>, Id] -> make_key(channel, pw_util:int(Id));
        [<<"direct">>, Id] -> make_key(direct, pw_util:int(Id));
        [<<"thread">>, Id] -> make_key(thread, pw_util:int(Id));
        [<<"forum">>, Id] -> make_key(forum, pw_util:int(Id));
        [<<"server">>, Id] -> make_key(server, pw_util:int(Id));
        _ -> undefined
    end;
parse_key(_) -> undefined.

make_key(_, undefined) -> undefined;
make_key(_, Id) when not is_integer(Id); Id =< 0 -> undefined;
make_key(Type, Id) -> {Type, Id}.

can_subscribe(Uid, {channel, Id}) -> pw_db:member_of_channel(Uid, Id);
can_subscribe(Uid, {direct, Id}) -> pw_db:member_of_conversation(Uid, Id);
can_subscribe(Uid, {server, Id}) -> pw_db:member_of_server(Uid, Id);
can_subscribe(_, {thread, _}) -> true;
can_subscribe(_, {forum, _}) -> true;
can_subscribe(_, _) -> false.

signal_ok(Sig) when is_map(Sig) -> byte_size(pw_util:json(Sig)) =< 32768;
signal_ok(_) -> false.

clean_status(<<"busy">>) -> <<"busy">>;
clean_status(<<"away">>) -> <<"away">>;
clean_status(<<"invisible">>) -> <<"invisible">>;
clean_status(_) -> <<"online">>.

origin_allowed(Req) ->
    case cowboy_req:header(<<"origin">>, Req, <<>>) of
        <<>> -> true;
        Origin ->
            Allowed = pw_util:env_str("PLAINWIRE_ALLOWED_ORIGINS", <<>>),
            case Allowed of
                <<>> -> same_origin(Origin, cowboy_req:header(<<"host">>, Req, <<>>));
                _ -> lists:member(Origin, [string:trim(O) || O <- binary:split(Allowed, <<",">>, [global])])
            end
    end.

same_origin(Origin, Host) ->
    case uri_string:parse(binary_to_list(Origin)) of
        #{scheme := Scheme, host := OHost} = Parsed when Scheme =:= "http"; Scheme =:= "https" ->
            OriginPort = maps:get(port, Parsed, default_port(Scheme)),
            case parse_host_header(Host, Scheme) of
                {ok, HHost, HPort} ->
                    string:lowercase(OHost) =:= string:lowercase(HHost) andalso OriginPort =:= HPort;
                error ->
                    false
            end;
        _ -> false
    end.

parse_host_header(Host, Scheme) ->
    case uri_string:parse("//" ++ binary_to_list(Host)) of
        #{host := HHost} = Parsed -> {ok, HHost, maps:get(port, Parsed, default_port(Scheme))};
        _ -> error
    end.

default_port("https") -> 443;
default_port(_) -> 80.

safe_json_decode(Data) ->
    try jsx:decode(Data, [return_maps]) catch _:_ -> error end.

reply_error(State, E) -> {reply, {text, pw_util:json(#{type=>error,error=>E})}, State}.
maybe_leave_voice(State=#{uid:=Uid, voice:=Cid}) when is_integer(Cid) -> pw_hub:voice_leave(Cid, Uid), State;
maybe_leave_voice(State) -> State.
maybe_leave_call(State=#{uid:=Uid, call:=Cid}) when is_integer(Cid) -> pw_hub:call_leave(Cid, Uid), State;
maybe_leave_call(State) -> State.
