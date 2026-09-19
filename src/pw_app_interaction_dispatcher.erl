-module(pw_app_interaction_dispatcher).
-behaviour(gen_server).
-export([start_link/0, poke/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TICK_MS, 500).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
poke() -> gen_server:cast(?MODULE, poke).

init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, #{workers => #{}, max => min(32, max(1, pw_util:env_int("PLAINWIRE_APP_INTERACTION_CONCURRENCY", 8))),
           timeout => min(30000, max(2000, pw_util:env_int("PLAINWIRE_APP_INTERACTION_TIMEOUT_MS", 10000)))}}.

handle_call(_Msg, _From, State) -> {reply, {error, unsupported}, State}.
handle_cast(poke, State) -> self() ! tick_now, {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(tick, State) -> erlang:send_after(?TICK_MS, self(), tick), dispatch(State);
handle_info(tick_now, State) -> dispatch(State);
handle_info({result, Pid, Result}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{Ref, InvocationId, Timer}, Rest} ->
            _ = erlang:cancel_timer(Timer), erlang:demonitor(Ref, [flush]),
            _ = pw_db:app_interaction_finish(InvocationId, Result),
            {noreply, State#{workers => Rest}};
        error -> {noreply, State}
    end;
handle_info({worker_timeout, Pid, Ref}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{Ref, InvocationId, _Timer}, Rest} ->
            catch exit(Pid, kill), erlang:demonitor(Ref, [flush]),
            _ = pw_db:app_interaction_finish(InvocationId, {error, <<"interaction_timeout">>}),
            {noreply, State#{workers => Rest}};
        {{OtherRef, InvocationId, Timer}, Rest} -> {noreply, State#{workers => Rest#{Pid => {OtherRef, InvocationId, Timer}}}};
        error -> {noreply, State}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{_OldRef, InvocationId, Timer}, Rest} ->
            _ = erlang:cancel_timer(Timer),
            _ = pw_db:app_interaction_finish(InvocationId, {error, pw_util:clean_text(io_lib:format("worker_exit:~p", [Reason]), 500)}),
            {noreply, State#{workers => Rest}};
        error -> {noreply, State}
    end;
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

dispatch(#{workers := Workers, max := Max, timeout := Timeout} = State) ->
    Capacity = max(0, Max - map_size(Workers)),
    case Capacity of
        0 -> {noreply, State};
        _ ->
            Jobs = case pw_db:app_interaction_claim_due(Capacity) of {ok, List} when is_list(List) -> List; _ -> [] end,
            New = lists:foldl(fun(Job, Acc) ->
                Parent = self(),
                {Pid, Ref} = spawn_monitor(fun() -> Parent ! {result, self(), deliver(Job, Timeout)} end),
                Timer = erlang:send_after(Timeout + 1000, Parent, {worker_timeout, Pid, Ref}),
                Acc#{Pid => {Ref, maps:get(id, Job), Timer}}
            end, Workers, Jobs),
            {noreply, State#{workers => New}}
    end.

deliver(Job, Timeout) ->
    Timestamp = integer_to_binary(pw_util:now_ms()),
    Payload = pw_util:json(#{
        type => <<"command">>, version => 1,
        invocation_id => maps:get(id, Job),
        application => #{id => maps:get(app_id, Job), public_id => maps:get(app_public_id, Job), name => maps:get(app_name, Job)},
        server_id => maps:get(server_id, Job), channel_id => maps:get(channel_id, Job), user_id => maps:get(user_id, Job),
        command => maps:get(command, Job), arguments => maps:get(args, Job), request_message_id => maps:get(request_message_id, Job)
    }),
    Secret = maps:get(secret, Job),
    Mac = crypto:mac(hmac, sha256, Secret, <<Timestamp/binary, ".", Payload/binary>>),
    Signature = <<"v1=", (pw_util:hex_binary(Mac))/binary>>,
    Headers = [{<<"x-plainwire-interaction-timestamp">>, Timestamp},
               {<<"x-plainwire-interaction-signature">>, Signature},
               {<<"x-plainwire-interaction-id">>, integer_to_binary(maps:get(id, Job))}],
    case pw_app_http:post_json(maps:get(url, Job), Headers, Payload, Timeout) of
        {ok, Code, _RespHeaders, Body} when Code >= 200, Code < 300 -> parse_response(Body);
        {ok, Code, _, _} -> {error, iolist_to_binary(io_lib:format("interaction_http_~B", [Code]))};
        {error, Reason} -> {error, pw_util:clean_text(io_lib:format("~p", [Reason]), 500)}
    end.

parse_response(<<>>) -> {ok, <<>>};
parse_response(Body) ->
    try jsx:decode(Body, [return_maps]) of
        M when is_map(M) ->
            Content = maps:get(<<"body">>, M, maps:get(<<"content">>, M, <<>>)),
            {ok, pw_util:clean_text(Content, 5000)};
        _ -> {error, <<"invalid_interaction_response">>}
    catch _:_ -> {error, <<"invalid_interaction_json">>} end.
