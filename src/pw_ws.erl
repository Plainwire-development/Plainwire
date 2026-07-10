-module(pw_ws).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

init(Req0, _State) ->
    case pw_util:cookie_value(Req0, <<"pw_session">>) of
        undefined -> {ok, cowboy_req:reply(401, #{}, <<"not authenticated">>, Req0), #{}};
        Token ->
            case pw_db:session(Token) of
                {ok, Session} -> {cowboy_websocket, Req0, #{session=>Session, uid=>maps:get(id,maps:get(user,Session)), subs=>[], voice=>undefined, call=>undefined, status=><<"online">>}};
                _ -> {ok, cowboy_req:reply(401, #{}, <<"not authenticated">>, Req0), #{}}
            end
    end.

websocket_init(State=#{uid:=Uid}) ->
    pw_hub:connect(Uid, self()),
    {reply, {text, pw_util:json(#{type=>hello, session=>maps:get(session,State)})}, State}.

websocket_handle({text, Data}, State0) ->
    case safe_json_decode(Data) of
        M when is_map(M) -> handle_msg(M, State0);
        _ -> {ok, State0}
    end;
websocket_handle(_Frame, State) -> {ok, State}.

handle_msg(#{<<"type">> := <<"ping">>}, State) ->
    {reply, {text, pw_util:json(#{type => pong, ts => pw_util:now_ms()})}, State};
handle_msg(#{<<"type">> := <<"subscribe">>, <<"key">> := Key0}, State=#{subs := Subs}) ->
    case parse_key(Key0) of
        undefined -> {ok, State};
        Key -> pw_hub:subscribe(self(), Key), {ok, State#{subs=>lists:usort([Key|Subs])}}
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
    case pw_util:int(To0) of
        To when is_integer(To), To > 0 -> pw_hub:voice_signal(Cid, Uid, To, Sig), {ok, State};
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
    pw_hub:call_decline(Cid, Uid),
    {ok, State};
handle_msg(#{<<"type">> := <<"call_cancel">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid}) ->
    Cid = pw_util:int(Cid0),
    pw_hub:call_cancel(Cid, Uid),
    {ok, State};
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
    case pw_util:int(To0) of
        To when is_integer(To), To > 0 -> pw_hub:call_signal(Cid, Uid, To, Sig), {ok, State};
        _ -> {ok, State}
    end;
handle_msg(#{<<"type">> := <<"presence_update">>, <<"status">> := Status}, #{uid:=Uid}=State) ->
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

safe_json_decode(Data) ->
    try jsx:decode(Data, [return_maps]) catch _:_ -> error end.

reply_error(State, E) -> {reply, {text, pw_util:json(#{type=>error,error=>E})}, State}.
maybe_leave_voice(State=#{uid:=Uid, voice:=Cid}) when is_integer(Cid) -> pw_hub:voice_leave(Cid, Uid), State;
maybe_leave_voice(State) -> State.
maybe_leave_call(State=#{uid:=Uid, call:=Cid}) when is_integer(Cid) -> pw_hub:call_leave(Cid, Uid), State;
maybe_leave_call(State) -> State.
