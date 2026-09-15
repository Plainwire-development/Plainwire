-module(pw_ws).
-behaviour(cowboy_websocket).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-ifdef(TEST).
-export([signal_ok/1, message_allowed/2]).
-endif.

-define(MAX_SUBS, 200).

init(Req0, _State) ->
    case pw_cluster_config:websocket_owner() of
        true -> init_owner(Req0);
        false -> {ok, cowboy_req:reply(503, #{<<"retry-after">> => <<"5">>}, <<"Route WebSockets to the realtime owner">>, Req0), #{}}
    end.

init_owner(Req0) ->
    case origin_allowed(Req0) of
        false ->
            logger:warning("[plainwire:ws] connection_rejected reason=origin host=~p origin=~p", [cowboy_req:header(<<"host">>, Req0), cowboy_req:header(<<"origin">>, Req0)]),
            {ok, cowboy_req:reply(403, #{}, <<"forbidden origin">>, Req0), #{}};
        true ->
            case pw_util:cookie_value(Req0, <<"pw_session">>) of
                undefined ->
                    logger:warning("[plainwire:ws] connection_rejected reason=unauthenticated"),
                    {ok, cowboy_req:reply(401, #{}, <<"not authenticated">>, Req0), #{}};
                Token ->
                        case cached_session(Token) of
                        {ok, Session} ->
                            User = maps:get(user, Session),
                            Status = maps:get(status, User, <<"online">>),
                            CleanSession = strip_session_urls(Session),
                            WsOpts = #{idle_timeout => 300000, max_frame_size => 65536, compress => true},
                            {cowboy_websocket, Req0, #{session=>CleanSession, token=>Token,
                                last_auth_check=>erlang:monotonic_time(millisecond),
                                uid=>maps:get(id,User), subs=>[], voice=>undefined, voice_profile=>undefined, call=>undefined, status=>Status}, WsOpts};
                        _ -> {ok, cowboy_req:reply(401, #{}, <<"not authenticated">>, Req0), #{}}
                    end
            end
    end.

websocket_init(State=#{uid:=Uid, status:=Status}) ->
    process_flag(message_queue_data, off_heap),
    debug(info, "connected", #{uid => Uid, status => Status}),
    pw_hub:connect(Uid, self(), Status),
    erlang:send_after(60000, self(), revalidate_auth),
    Session = strip_session_urls(maps:get(session, State)),
    {reply, {text, pw_util:json(#{type=>hello, session=>Session})}, State}.

websocket_handle({text, Data}, State0=#{uid:=Uid}) ->
    case revalidate_session(State0) of
        {error, expired} -> {stop, State0};
        {ok, State} ->
            %% coarse flood guard first; each message class then spends its own
            %% budget so speaking indicators can't starve offers and candidates.
            case byte_size(Data) =< 65536 andalso pw_rate:allow({ws_frames, Uid}, 1500, 60000) of
                true ->
                    case safe_json_decode(Data) of
                        M when is_map(M) ->
                            case message_allowed(Uid, M) of
                                true ->
                                    debug(debug_level(M), "received", #{uid => Uid, type => event_type(M), bytes => byte_size(Data), room => room_summary(State)}),
                                    handle_msg(M, State);
                                false ->
                                    reply_error(State, rate_limited)
                            end;
                        _ ->
                            debug(warning, "invalid_json", #{uid => Uid, bytes => byte_size(Data)}),
                            {ok, State}
                    end;
                false ->
                    reply_error(State, rate_limited)
            end
    end;
websocket_handle(_Frame, State) -> {ok, State}.

%% speaking and quality samples are limited in their handlers and just dropped.
message_allowed(_Uid, #{<<"type">> := Type}) when Type =:= <<"voice_activity">>; Type =:= <<"call_quality">>; Type =:= <<"typing">> ->
    true;
message_allowed(Uid, #{<<"type">> := Type}) when Type =:= <<"voice_signal">>; Type =:= <<"call_signal">> ->
    %% every ICE restart trickles a fresh batch of candidates.
    pw_rate:allow({ws_signal, Uid}, 900, 60000);
message_allowed(Uid, _) ->
    pw_rate:allow({ws, Uid}, 240, 60000).

handle_msg(#{<<"type">> := <<"call_quality">>, <<"request_id">> := Request,
             <<"peer_id">> := Peer, <<"samples">> := Rows}, State = #{uid := Uid})
  when is_binary(Request), byte_size(Request) =< 96, is_integer(Peer), Peer > 0 ->
    InRoom = is_integer(maps:get(call, State, undefined)) orelse is_integer(maps:get(voice, State, undefined)),
    case InRoom andalso pw_rate:allow({call_quality, Uid}, 60, 60000) of
        true ->
            case pw_media_quality:submit(self(), Request, Peer, Rows) of
                ok -> {ok, State};
                {error, _} -> quality_reply(Request, Peer, #{unavailable => true}, State)
            end;
        false -> {ok, State}
    end;
handle_msg(#{<<"type">> := <<"ping">>}, State) ->
    {reply, {text, pw_util:json(#{type => pong, ts => pw_util:now_ms()})}, State};
handle_msg(#{<<"type">> := <<"subscribe">>, <<"key">> := Key0}, State=#{uid:=Uid, subs := Subs}) ->
    case parse_key(Key0) of
        undefined -> {ok, State};
        Key ->
            case length(Subs) >= ?MAX_SUBS andalso not lists:member(Key, Subs) of
                true -> reply_error(State, too_many_subscriptions);
                false ->
                    case can_subscribe(Uid, Key) of
                        true -> pw_hub:subscribe(self(), Key), {ok, State#{subs=>lists:usort([Key|Subs])}};
                        false -> reply_error(State, forbidden)
                    end
            end
    end;
handle_msg(#{<<"type">> := <<"unsubscribe_all">>}, State) ->
    pw_hub:unsubscribe_all(self()),
    {ok, State#{subs=>[]}};
handle_msg(#{<<"type">> := <<"presence_watch">>, <<"user_ids">> := Uids0}, State) when is_list(Uids0) ->
    Uids = lists:sublist(lists:usort([U || U0 <- Uids0, U <- [pw_util:int(U0)], is_integer(U), U > 0]), 2000),
    pw_hub:watch_presence(self(), Uids),
    {ok, State};
handle_msg(#{<<"type">> := <<"typing">>, <<"scope">> := Scope0, <<"scope_id">> := ScopeId0} = Msg,
           State=#{uid:=Uid, session:=Session}) ->
    ScopeId = pw_util:int(ScopeId0),
    Scope = case Scope0 of
        <<"direct">> -> direct;
        <<"channel">> -> channel;
        <<"thread">> -> thread;
        _ -> undefined
    end,
    Active = maps:get(<<"active">>, Msg, true) =:= true,
    Key = case {Scope, ScopeId} of
        {direct, Id} when is_integer(Id), Id > 0 -> {direct, Id};
        {channel, Id} when is_integer(Id), Id > 0 -> {channel, Id};
        {thread, Id} when is_integer(Id), Id > 0 -> {thread, Id};
        _ -> undefined
    end,
    case Key =/= undefined andalso pw_rate:allow({ws_typing, Uid}, 180, 60000) of
        true ->
            case typing_profile(Uid, Key, Session) of
                {ok, User} ->
                    Event = #{
                        type => typing,
                        scope => atom_to_binary(Scope, utf8),
                        scope_id => ScopeId,
                        user_id => Uid,
                        username => maps:get(username, User, <<>>),
                        display_name => maps:get(display_name, User, maps:get(username, User, <<>>)),
                        avatar_url => maps:get(avatar_url, User, <<>>),
                        active => Active,
                        ts => pw_util:now_ms()
                    },
                    pw_hub:broadcast(Key, Event),
                    {ok, State};
                error -> {ok, State}
            end;
        false ->
            %% Typing is deliberately best-effort. Invalid or over-rate events are
            %% dropped instead of turning a harmless UI hint into a chat error.
            {ok, State}
    end;
handle_msg(#{<<"type">> := <<"voice_join">>, <<"channel_id">> := Cid0}, State=#{uid:=Uid}) ->
    Cid = pw_util:int(Cid0),
    case {pw_db:voice_access(Uid, Cid), pw_db:channel_identity(Uid, Cid)} of
        {true, {ok, VoiceProfile}} ->
            S1 = maybe_leave_rtc(State),
            case pw_hub:voice_join(Cid, Uid, self(), VoiceProfile) of
                ok -> {ok, S1#{voice=>Cid, voice_profile=>VoiceProfile, call=>undefined}};
                {error, Reason} -> reply_rtc_error(S1, Reason, voice, Cid)
            end;
        _ -> reply_rtc_error(State, forbidden, voice, Cid)
    end;
handle_msg(#{<<"type">> := <<"voice_leave">>}, State) -> S1 = maybe_leave_voice(State), {ok, S1#{voice=>undefined, voice_profile=>undefined}};
handle_msg(#{<<"type">> := <<"voice_state">>, <<"patch">> := Patch}, State=#{uid:=Uid, voice:=Cid}) when is_integer(Cid), is_map(Patch) ->
    VoiceProfile = maps:get(voice_profile, State, #{}),
    pw_hub:voice_state(Cid, Uid, self(), clean_room_patch(Patch), VoiceProfile), {ok, State};
handle_msg(#{<<"type">> := <<"voice_signal">>, <<"to_user_id">> := To0, <<"signal">> := Sig}, State=#{uid:=Uid, voice:=Cid}) when is_integer(Cid) ->
    case {pw_util:int(To0), signal_ok(Sig)} of
        {To, true} when is_integer(To), To > 0 -> pw_hub:voice_signal(Cid, Uid, self(), To, Sig), {ok, State};
        _ -> {ok, State}
    end;
handle_msg(#{<<"type">> := <<"call_ring">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid, session:=Session}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:conversation_peer_ids(Uid, Cid) of
        {ok, Targets0} ->
            case lists:filter(fun(T) -> T =/= Uid end, Targets0) of
                [] ->
                    reply_rtc_error(State, no_peers, call, Cid);
                Targets ->
                    S1 = maybe_leave_rtc(State),
                    pw_hub:call_ring(Cid, Uid, self(), maps:get(user, Session), Targets),
                    {ok, S1#{voice => undefined, call => Cid}}
            end;
        false ->
            reply_rtc_error(State, forbidden, call, Cid);
        {error, _} ->
            reply_rtc_error(State, forbidden, call, Cid)
    end;
handle_msg(#{<<"type">> := <<"call_accept">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid, session:=Session}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:conversation_peer_ids(Uid, Cid) of
        {ok, Targets} ->
            S1 = maybe_leave_rtc(State),
            case pw_hub:call_accept(Cid, Uid, self(), maps:get(user, Session), Targets) of
                ok -> {ok, S1#{voice => undefined, call => Cid}};
                {error, Reason} -> reply_rtc_error(S1, Reason, call, Cid)
            end;
        _ ->
            reply_rtc_error(State, forbidden, call, Cid)
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
        true -> pw_hub:call_cancel(Cid, Uid, self()), {ok, State};
        false -> reply_error(State, forbidden)
    end;
handle_msg(#{<<"type">> := <<"call_join">>, <<"conversation_id">> := Cid0}, State=#{uid:=Uid, session:=Session}) ->
    Cid = pw_util:int(Cid0),
    case pw_db:conversation_peer_ids(Uid, Cid) of
        {ok, Targets} ->
            S1 = maybe_leave_rtc(State),
            case pw_hub:call_rejoin(Cid, Uid, self(), maps:get(user,Session), Targets) of
                ok -> {ok, S1#{voice=>undefined, call=>Cid}};
                {error, Reason} -> reply_rtc_error(S1, Reason, call, Cid)
            end;
        _ -> reply_rtc_error(State, forbidden, call, Cid)
    end;
handle_msg(#{<<"type">> := <<"call_leave">>}, State) -> S1 = maybe_leave_call(State), {ok, S1#{call=>undefined}};
handle_msg(#{<<"type">> := <<"call_state">>, <<"patch">> := Patch}, State=#{uid:=Uid, session:=Session, call:=Cid}) when is_integer(Cid), is_map(Patch) ->
    pw_hub:call_state(Cid, Uid, self(), clean_room_patch(Patch), maps:get(user,Session)), {ok, State};
handle_msg(#{<<"type">> := <<"call_signal">>, <<"to_user_id">> := To0, <<"signal">> := Sig}, State=#{uid:=Uid, call:=Cid}) when is_integer(Cid) ->
    case {pw_util:int(To0), signal_ok(Sig)} of
        {To, true} when is_integer(To), To > 0 -> pw_hub:call_signal(Cid, Uid, self(), To, Sig), {ok, State};
        _ -> {ok, State}
    end;
handle_msg(#{<<"type">> := <<"voice_activity">>, <<"active">> := Active0}=Msg, State=#{uid:=Uid}) ->
    Active = pw_util:bool(Active0),
    Level = clamp_level(pw_util:int(maps:get(<<"level_db">>, Msg, -100))),
    %% speaking rings are useful but disposable, so rate-limit them separately.
    case pw_rate:allow({ws_activity, Uid}, 120, 60000) of
        true -> relay_activity(State, Uid, Active);
        false -> ok
    end,
    debug(debug, case Active of true -> "voice_detected"; false -> "voice_stopped" end,
        #{uid => Uid, active => Active, level_db => Level, room => room_summary(State)}),
    {ok, State};
handle_msg(#{<<"type">> := <<"presence_update">>, <<"status">> := Status0}, #{uid:=Uid}=State) ->
    Status = clean_status(Status0),
    pw_hub:status_update(Uid, self(), Status),
    {ok, State#{status => Status}};
handle_msg(_, State) -> {ok, State}.

websocket_info({quality_result, Request, Peer, Result}, State) ->
    quality_reply(Request, Peer, Result, State);
websocket_info(revalidate_auth, State0) ->
    case revalidate_session(State0) of
        {ok, State} ->
            erlang:send_after(60000, self(), revalidate_auth),
            {ok, State};
        {error, expired} -> {stop, State0}
    end;
websocket_info({hub_json, Event=#{type := voice_superseded}}, State=#{uid:=Uid}) ->
    deliver_hub_payload(pw_util:json(Event), voice_superseded, Uid, State#{voice => undefined, voice_profile => undefined});
websocket_info({hub_json, Event=#{type := call_superseded}}, State=#{uid:=Uid}) ->
    deliver_hub_payload(pw_util:json(Event), call_superseded, Uid, State#{call => undefined});
websocket_info({hub_json, Event}, State=#{uid:=Uid}) ->
    deliver_hub_payload(pw_util:json(Event), event_type(Event), Uid, State);
websocket_info({hub_text, Payload, Type}, State=#{uid:=Uid}) ->
    deliver_hub_payload(Payload, Type, Uid, State);
websocket_info(_, State) -> {ok, State}.

quality_reply(Request, Peer, Result, State) ->
    {reply, {text, pw_util:json(#{type => call_quality_result, request_id => Request,
                                peer_id => Peer, result => Result})}, State}.

deliver_hub_payload(Payload, Type, Uid, State) ->
    QueueLen = case process_info(self(), message_queue_len) of {message_queue_len, N} -> N; _ -> 0 end,
    Soft = max(10, pw_util:env_int("PLAINWIRE_WS_SOFT_QUEUE", 500)),
    Hard = max(Soft + 1, pw_util:env_int("PLAINWIRE_WS_HARD_QUEUE", 2000)),
    case QueueLen >= Hard of
        true ->
            logger:warning("[plainwire:ws] slow_client_disconnected uid=~p queue=~p", [Uid, QueueLen]),
            {stop, State};
        false when QueueLen >= Soft ->
            case droppable_event(Type) of
                true -> {ok, State};
                false -> {reply, {text, Payload}, State}
            end;
        false ->
            logger:debug("[plainwire:ws] sent ~p", [#{uid => Uid, type => Type, room => room_summary(State)}]),
            {reply, {text, Payload}, State}
    end.

terminate(Reason, _, State=#{uid:=Uid}) ->
    debug(info, "disconnected", #{uid => Uid, reason => Reason, room => room_summary(State)}),
    %% refresh isn't hangup. let the replacement socket reclaim the room.
    pw_hub:disconnect(self()), ok.

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
can_subscribe(_, {thread, Id}) -> pw_db:subscribable(thread, Id);
can_subscribe(_, {forum, Id}) -> pw_db:subscribable(forum, Id).

typing_profile(Uid, {channel, Id}, _Session) ->
    case pw_db:channel_message_identity(Uid, Id) of
        {ok, User} -> {ok, User};
        _ -> error
    end;
typing_profile(Uid, Key, Session) ->
    case can_type_in(Uid, Key) of
        true -> {ok, maps:get(user, Session)};
        false -> error
    end.

can_type_in(Uid, {direct, Id}) -> pw_db:member_of_conversation(Uid, Id);
can_type_in(Uid, {thread, Id}) -> pw_db:member_of_thread_forum(Uid, Id);
can_type_in(_, _) -> false.

%% size isn't validation; check the signal shape too.
signal_ok(#{<<"kind">> := <<"offer">>, <<"sdp">> := Sdp}) -> sdp_ok(Sdp);
signal_ok(#{<<"kind">> := <<"answer">>, <<"sdp">> := Sdp}) -> sdp_ok(Sdp);
signal_ok(#{<<"kind">> := <<"candidate">>, <<"candidate">> := Candidate}) -> candidate_ok(Candidate);
%% answerer asks the one true offerer to try again. no glare circus.
signal_ok(#{<<"kind">> := <<"renegotiate">>} = Signal) -> map_size(Signal) =:= 1;
signal_ok(_) -> false.

sdp_ok(#{<<"type">> := Type, <<"sdp">> := Sdp}) when is_binary(Sdp) ->
    lists:member(Type, [<<"offer">>, <<"answer">>, <<"pranswer">>, <<"rollback">>])
        andalso byte_size(Sdp) =< 32768;
sdp_ok(_) -> false.

candidate_ok(Candidate) when is_map(Candidate) ->
    byte_size(pw_util:json(Candidate)) =< 4096;
candidate_ok(_) -> false.

clean_status(<<"busy">>) -> <<"busy">>;
clean_status(<<"away">>) -> <<"away">>;
clean_status(<<"invisible">>) -> <<"invisible">>;
clean_status(_) -> <<"online">>.

origin_allowed(Req) ->
    case cowboy_req:header(<<"origin">>, Req, <<>>) of
        <<>> -> not production_env();
        Origin ->
            Allowed = configured_origins(),
            case Allowed of
                <<>> -> same_origin(Origin, cowboy_req:header(<<"host">>, Req, <<>>));
                _ -> lists:member(Origin, [string:trim(O) || O <- binary:split(Allowed, <<",">>, [global])])
            end
    end.

production_env() ->
    lists:member(os:getenv("PLAINWIRE_ENV"), ["prod", "production"]) orelse
        lists:member(os:getenv("NODE_ENV"), ["prod", "production"]).

revalidate_session(State=#{last_auth_check := Last, token := Token, uid := Uid}) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - Last < 60000 of
        true -> {ok, State};
        false ->
            case pw_db:session_fast(Token) of
                {ok, Session} ->
                    User = maps:get(user, Session),
                    case maps:get(id, User) of
                        Uid -> {ok, revalidate_subscriptions(revalidate_rooms(State#{session=>strip_session_urls(Session), last_auth_check=>Now}))};
                        _ -> {error, expired}
                    end;
                _ ->
                    case pw_db:session(Token) of
                        {ok, Session2} ->
                            User2 = maps:get(user, Session2),
                            case maps:get(id, User2) of
                                Uid -> {ok, revalidate_subscriptions(revalidate_rooms(State#{session=>strip_session_urls(Session2), last_auth_check=>Now}))};
                                _ -> {error, expired}
                            end;
                        _ -> {error, expired}
                    end
            end
    end.

revalidate_subscriptions(State=#{uid:=Uid, subs:=Subs}) ->
    Allowed = [Key || Key <- Subs, can_subscribe(Uid, Key) =:= true],
    case Allowed =:= Subs of
        true -> State;
        false ->
            pw_hub:unsubscribe_all(self()),
            lists:foreach(fun(Key) -> pw_hub:subscribe(self(), Key) end, Allowed),
            State#{subs => Allowed}
    end.

%% kicked/removed/blocked means the media room goes too.
revalidate_rooms(State=#{uid:=Uid}) ->
    S1 = case maps:get(voice, State, undefined) of
        Cid when is_integer(Cid) ->
            case pw_db:voice_access(Uid, Cid) of
                true -> State;
                _ ->
                    pw_hub:voice_leave(Cid, Uid, self()),
                    self() ! {hub_json, #{type => voice_ejected, channel_id => Cid, reason => access_revoked}},
                    State#{voice => undefined, voice_profile => undefined}
            end;
        _ -> State
    end,
    case maps:get(call, S1, undefined) of
        Conv when is_integer(Conv) ->
            case pw_db:member_of_conversation(Uid, Conv) of
                true -> S1;
                _ ->
                    pw_hub:call_leave(Conv, Uid, self()),
                    self() ! {hub_json, #{type => call_ejected, conversation_id => Conv, reason => access_revoked}},
                    S1#{call => undefined}
            end;
        _ -> S1
    end.

configured_origins() ->
    case pw_util:env_str("PLAINWIRE_ALLOWED_ORIGINS", <<>>) of
        <<>> -> pw_util:env_str("PLAINWIRE_PUBLIC_URL", <<>>);
        Origins -> Origins
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

cached_session(Token) ->
    case pw_db:session_fast(Token) of
        {ok, Session} -> {ok, Session};
        _ -> pw_db:session(Token)
    end.

safe_json_decode(Data) ->
    try jsx:decode(Data, [return_maps]) catch _:_ -> error end.

reply_error(State, E) -> {reply, {text, pw_util:json(#{type=>error,error=>E})}, State}.
reply_rtc_error(State, E, Kind, Id) ->
    {reply, {text, pw_util:json(#{type => error, error => E, rtc_kind => Kind, rtc_id => Id})}, State}.
maybe_leave_voice(State=#{uid:=Uid, voice:=Cid}) when is_integer(Cid) -> pw_hub:voice_leave(Cid, Uid, self()), State;
maybe_leave_voice(State) -> State.
maybe_leave_call(State=#{uid:=Uid, call:=Cid}) when is_integer(Cid) -> pw_hub:call_leave(Cid, Uid, self()), State;
maybe_leave_call(State) -> State.

%% one socket gets one RTC room, even if its JavaScript disagrees.
maybe_leave_rtc(State) ->
    S1 = maybe_leave_voice(State),
    S2 = maybe_leave_call(S1),
    S2#{voice => undefined, voice_profile => undefined, call => undefined}.

event_type(Map) -> maps:get(<<"type">>, Map, maps:get(type, Map, unknown)).

debug_level(Map) ->
    case event_type(Map) of
        <<"voice_signal">> -> debug;
        <<"call_signal">> -> debug;
        voice_signal -> debug;
        call_signal -> debug;
        _ -> debug
    end.

droppable_event(presence_state) -> true;
droppable_event(presence_online) -> true;
droppable_event(presence_offline) -> true;
droppable_event(presence_status) -> true;
droppable_event(voice_state) -> true;
droppable_event(call_state) -> true;
droppable_event(voice_activity) -> true;
droppable_event(call_activity) -> true;
droppable_event(_) -> false.

relay_activity(#{voice := Cid}, Uid, Active) when is_integer(Cid) -> pw_hub:voice_activity(voice, Cid, Uid, self(), Active);
relay_activity(#{call := Cid}, Uid, Active) when is_integer(Cid) -> pw_hub:voice_activity(call, Cid, Uid, self(), Active);
relay_activity(_State, _Uid, _Active) -> ok.

clean_room_patch(Patch) ->
    %% patch means patch; changing screen should not magically unmute anyone.
    maps:from_list([
        {Key, pw_util:bool(Value)}
        || {WireKey, Key} <- [{<<"muted">>, muted}, {<<"deafened">>, deafened},
                              {<<"screen">>, screen}, {<<"screen_audio">>, screen_audio}],
           {ok, Value} <- [maps:find(WireKey, Patch)]
    ]).

room_summary(State) ->
    #{voice => maps:get(voice, State, undefined), call => maps:get(call, State, undefined)}.

clamp_level(undefined) -> -100;
clamp_level(N) when N < -100 -> -100;
clamp_level(N) when N > 0 -> 0;
clamp_level(N) -> N.

debug(debug, Event, Data) -> logger:debug("[plainwire:ws] ~s ~p", [Event, Data]);
debug(info, Event, Data) -> logger:notice("[plainwire:ws] ~s ~p", [Event, Data]);
debug(warning, Event, Data) -> logger:warning("[plainwire:ws] ~s ~p", [Event, Data]).

strip_session_urls(Session = #{user := User}) ->
    Session#{user => maps:remove(avatar_source_url, maps:remove(banner_source_url, User))};
strip_session_urls(Session) -> Session.
