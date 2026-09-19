-module(pw_ai_bot_dispatcher).
-behaviour(gen_server).
-export([start_link/0, poke/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TICK_MS, 750).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
poke() -> gen_server:cast(?MODULE, poke).

init([]) ->
    process_flag(trap_exit, true),
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, #{workers => #{}, max => min(16, max(1, pw_util:env_int("PLAINWIRE_AI_COMMAND_CONCURRENCY", 4))),
           timeout => min(60000, max(5000, pw_util:env_int("PLAINWIRE_AI_COMMAND_TIMEOUT_MS", 30000)))}}.
handle_call(_Msg, _From, State) -> {reply, {error, unsupported}, State}.
handle_cast(poke, State) -> self() ! tick_now, {noreply, State};
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(tick, State) -> erlang:send_after(?TICK_MS, self(), tick), dispatch(State);
handle_info(tick_now, State) -> dispatch(State);
handle_info({result, Pid, Result}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{Ref, InvocationId, Timer}, Rest} ->
            _ = erlang:cancel_timer(Timer), erlang:demonitor(Ref, [flush]),
            _ = pw_db:ai_command_finish(InvocationId, Result),
            {noreply, State#{workers => Rest}};
        error -> {noreply, State}
    end;
handle_info({worker_timeout, Pid, Ref}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{Ref, InvocationId, _}, Rest} ->
            catch exit(Pid, kill), erlang:demonitor(Ref, [flush]),
            _ = pw_db:ai_command_finish(InvocationId, {error, <<"ai_timeout">>}),
            {noreply, State#{workers => Rest}};
        {{OtherRef, InvocationId, Timer}, Rest} -> {noreply, State#{workers => Rest#{Pid => {OtherRef, InvocationId, Timer}}}};
        error -> {noreply, State}
    end;
handle_info({'DOWN', _Ref, process, Pid, Reason}, #{workers := Workers} = State) ->
    case maps:take(Pid, Workers) of
        {{_OldRef, InvocationId, Timer}, Rest} ->
            _ = erlang:cancel_timer(Timer),
            _ = pw_db:ai_command_finish(InvocationId, {error, pw_util:clean_text(io_lib:format("worker_exit:~p", [Reason]), 500)}),
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
            Jobs = case pw_db:ai_command_claim_due(Capacity) of {ok, List} when is_list(List) -> List; _ -> [] end,
            New = lists:foldl(fun(Job, Acc) ->
                Parent = self(),
                {Pid, Ref} = spawn_monitor(fun() -> Parent ! {result, self(), deliver(Job, Timeout)} end),
                Timer = erlang:send_after(Timeout + 1000, Parent, {worker_timeout, Pid, Ref}),
                Acc#{Pid => {Ref, maps:get(id, Job), Timer}}
            end, Workers, Jobs),
            {noreply, State#{workers => New}}
    end.

deliver(Job, Timeout) ->
    AppId = maps:get(app_id, Job),
    PerMinute = min(600, max(1, pw_util:env_int("PLAINWIRE_AI_COMMANDS_PER_APP_PER_MINUTE", 60))),
    case pw_rate:allow_shared({developer_app_ai, AppId}, PerMinute, 60000) of
        false -> {error, <<"ai_app_rate_limited">>};
        true ->
            UserContent = ai_user_content(Job),
            System = pw_util:clean_text(maps:get(system_prompt, Job, <<>>), 8000),
            Messages = case System of
                <<>> -> [#{role => <<"user">>, content => UserContent}];
                _ -> [#{role => <<"system">>, content => System}, #{role => <<"user">>, content => UserContent}]
            end,
            Payload = pw_util:json(#{model => maps:get(model, Job), messages => Messages, stream => false}),
            Headers = case maps:get(api_key, Job, <<>>) of
                <<>> -> [];
                Key -> [{<<"authorization">>, <<"Bearer ", Key/binary>>}]
            end,
            case pw_app_http:post_json(maps:get(endpoint, Job), Headers, Payload, Timeout) of
                {ok, Code, _, Body} when Code >= 200, Code < 300 -> parse_ai_response(Body);
                {ok, Code, _, _} -> {error, iolist_to_binary(io_lib:format("ai_http_~B", [Code]))};
                {error, Reason} -> {error, pw_util:clean_text(io_lib:format("~p", [Reason]), 500)}
            end
    end.

ai_user_content(Job) ->
    Command = maps:get(command, Job), Args = maps:get(args, Job, #{}),
    ArgsText = case Args of
        #{<<"raw">> := Raw} -> pw_util:clean_text(Raw, 4000);
        _ -> pw_util:clean_text(pw_util:json(Args), 4000)
    end,
    <<"Plainwire command /", Command/binary, "\nArguments:\n", ArgsText/binary>>.

parse_ai_response(Body) ->
    try jsx:decode(Body, [return_maps]) of
        #{<<"choices">> := [#{<<"message">> := #{<<"content">> := Content}} | _]} -> clean_ai_content(Content);
        #{<<"output_text">> := Content} -> clean_ai_content(Content);
        #{<<"response">> := Content} -> clean_ai_content(Content);
        _ -> {error, <<"invalid_ai_response">>}
    catch _:_ -> {error, <<"invalid_ai_json">>} end.

clean_ai_content(Content) ->
    Text = pw_util:clean_text(Content, 5000),
    case Text of <<>> -> {error, <<"empty_ai_response">>}; _ -> {ok, Text} end.
