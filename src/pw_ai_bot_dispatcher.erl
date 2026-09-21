-module(pw_ai_bot_dispatcher).
-behaviour(gen_server).
-export([start_link/0, poke/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([parse_ai_response/2, google_endpoint/2, ai_user_content/1]).
-endif.

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
            Provider = maps:get(provider, Job, <<"openai_compatible">>),
            {Url, Headers, Payload} = ai_request(Provider, Job),
            case pw_app_http:post_json(Url, Headers, pw_util:json(Payload), Timeout) of
                {ok, Code, _, Body} when Code >= 200, Code < 300 -> parse_ai_response(Provider, Body);
                {ok, Code, _, _} when Code =:= 400; Code =:= 401; Code =:= 403; Code =:= 404 ->
                    {terminal_error, iolist_to_binary(io_lib:format("ai_http_~B", [Code]))};
                {ok, Code, _, _} -> {error, iolist_to_binary(io_lib:format("ai_http_~B", [Code]))};
                {error, Reason} -> {error, pw_util:clean_text(io_lib:format("~p", [Reason]), 500)}
            end
    end.

ai_request(Provider, Job) ->
    Endpoint = maps:get(endpoint, Job),
    Model = maps:get(model, Job),
    Key = maps:get(api_key, Job, <<>>),
    System = pw_util:clean_text(maps:get(system_prompt, Job, <<>>), 8000),
    Temperature = maps:get(temperature, Job, 0.7),
    MaxTokens = maps:get(max_output_tokens, Job, 1000),
    Messages0 = normalize_context(maps:get(context, Job, [])) ++
        [#{role => <<"user">>, content => ai_user_content(Job)}],
    case Provider of
        <<"anthropic">> ->
            Headers = [{<<"x-api-key">>, Key}, {<<"anthropic-version">>, <<"2023-06-01">>}],
            Payload0 = #{model => Model, messages => Messages0, max_tokens => MaxTokens, temperature => Temperature},
            {Endpoint, Headers, maybe_put(system, System, Payload0)};
        <<"google">> ->
            Contents = [google_message(Message) || Message <- Messages0],
            Generation = #{temperature => Temperature, maxOutputTokens => MaxTokens},
            Payload0 = #{contents => Contents, generationConfig => Generation},
            Payload = case System of
                <<>> -> Payload0;
                _ -> Payload0#{systemInstruction => #{parts => [#{text => System}]}}
            end,
            {google_endpoint(Endpoint, Model), [{<<"x-goog-api-key">>, Key}], Payload};
        <<"openai_responses">> ->
            Payload0 = #{model => Model, input => Messages0, temperature => Temperature,
                         max_output_tokens => MaxTokens, stream => false},
            {Endpoint, bearer_headers(Key), maybe_put(instructions, System, Payload0)};
        _ ->
            Messages = case System of
                <<>> -> Messages0;
                _ -> [#{role => <<"system">>, content => System} | Messages0]
            end,
            Payload = #{model => Model, messages => Messages, stream => false,
                        temperature => Temperature, max_tokens => MaxTokens},
            {Endpoint, bearer_headers(Key), Payload}
    end.

maybe_put(_Key, <<>>, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

bearer_headers(<<>>) -> [];
bearer_headers(Key) -> [{<<"authorization">>, <<"Bearer ", Key/binary>>}].

normalize_context(Context) when is_list(Context) ->
    lists:filtermap(fun(Message) when is_map(Message) ->
        Role0 = maps:get(role, Message, maps:get(<<"role">>, Message, <<"user">>)),
        Content = pw_util:clean_text(maps:get(content, Message, maps:get(<<"content">>, Message, <<>>)), 1200),
        Role = case Role0 of <<"assistant">> -> <<"assistant">>; _ -> <<"user">> end,
        case Content of <<>> -> false; _ -> {true, #{role => Role, content => Content}} end;
        (_) -> false
    end, Context);
normalize_context(_) -> [].

google_message(#{role := Role, content := Content}) ->
    #{role => case Role of <<"assistant">> -> <<"model">>; _ -> <<"user">> end,
      parts => [#{text => Content}]}.

google_endpoint(Endpoint0, Model0) ->
    Endpoint = string:trim(pw_util:bin(Endpoint0), trailing, "/"),
    case binary:match(Endpoint, <<":generateContent">>) of
        nomatch ->
            Model = re:replace(pw_util:bin(Model0), <<"[^A-Za-z0-9._-]">>, <<>>, [global, {return, binary}]),
            <<Endpoint/binary, "/", Model/binary, ":generateContent">>;
        _ -> Endpoint
    end.

ai_user_content(Job) ->
    Command = pw_util:bin(maps:get(command, Job, <<"command">>)),
    Args = case maps:get(args, Job, #{}) of M when is_map(M) -> M; _ -> #{} end,
    Source = pw_util:bin(maps:get(<<"source">>, Args, maps:get(source, Args, <<"command">>))),
    Member = nonempty(maps:get(member_name, Job, <<"a member">>), <<"a member">>),
    Channel = nonempty(maps:get(channel_name, Job, <<"channel">>), <<"channel">>),
    Body = argument_text(Args),
    case Source of
        <<"chat">> ->
            <<"A Plainwire member mentioned you or replied to you in #", Channel/binary,
              ".\nMember: ", Member/binary, "\nMessage:\n", Body/binary>>;
        _ ->
            OptionLines = option_lines(Args),
            <<"Plainwire slash command /", Command/binary, " invoked by ", Member/binary,
              " in #", Channel/binary, ".\n", OptionLines/binary, "Arguments:\n", Body/binary>>
    end.

argument_text(#{<<"raw">> := Raw}) -> pw_util:clean_text(Raw, 4000);
argument_text(Args) -> pw_util:clean_text(pw_util:json(maps:without([<<"source">>, source], Args)), 4000).

option_lines(Args) when is_map(Args) ->
    Options = maps:without([<<"raw">>, <<"source">>, raw, source], Args),
    case maps:size(Options) of
        0 -> <<>>;
        _ ->
            Lines = [[pw_util:bin(Name), <<": ">>, option_value_text(Value), <<"\n">>]
                     || {Name, Value} <- lists:sort(maps:to_list(Options))],
            iolist_to_binary([<<"Options:\n">>, Lines])
    end;
option_lines(_) -> <<>>.

option_value_text(Value) when is_binary(Value) -> pw_util:clean_text(Value, 400);
option_value_text(Value) -> pw_util:clean_text(pw_util:json(Value), 400).

nonempty(<<>>, Default) -> Default;
nonempty(Value, _Default) -> pw_util:clean_text(Value, 80).

parse_ai_response(Provider, Body) ->
    try jsx:decode(Body, [return_maps]) of
        Json when Provider =:= <<"anthropic">> ->
            clean_ai_content(text_parts(maps:get(<<"content">>, Json, [])));
        Json when Provider =:= <<"google">> ->
            Candidates = maps:get(<<"candidates">>, Json, []),
            clean_ai_content(text_parts(Candidates));
        #{<<"choices">> := [#{<<"message">> := #{<<"content">> := Content}} | _]} -> clean_ai_content(text_parts(Content));
        #{<<"output_text">> := Content} -> clean_ai_content(Content);
        #{<<"output">> := Output} -> clean_ai_content(text_parts(Output));
        #{<<"response">> := Content} -> clean_ai_content(Content);
        _ -> {error, <<"invalid_ai_response">>}
    catch _:_ -> {error, <<"invalid_ai_json">>} end.

text_parts(Value) when is_binary(Value) -> Value;
text_parts(Value) when is_list(Value) ->
    iolist_to_binary(lists:join(<<"\n">>, [Part || Item <- Value, Part <- [text_parts(Item)], Part =/= <<>>]));
text_parts(#{<<"text">> := Text}) -> text_parts(Text);
text_parts(#{<<"content">> := Content}) -> text_parts(Content);
text_parts(#{<<"parts">> := Parts}) -> text_parts(Parts);
text_parts(_) -> <<>>.

clean_ai_content(Content) ->
    Text = pw_util:clean_text(Content, 5000),
    case Text of <<>> -> {error, <<"empty_ai_response">>}; _ -> {ok, Text} end.
