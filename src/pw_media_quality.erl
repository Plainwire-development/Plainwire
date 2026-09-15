-module(pw_media_quality).
-behaviour(gen_server).
-export([start_link/0, submit/4, available/0, validate/1, decode/1, policy/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([start_link/1]).
start_link(Path) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Path, []).
-endif.

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, worker_path(), []).
available() ->
    try gen_server:call(?MODULE, available, 100) catch exit:_ -> false end.
submit(Pid, Request, Peer, Rows) ->
    case validate(Rows) of
        {ok, Binary} ->
            try gen_server:call(?MODULE, {submit, Pid, Request, Peer, Binary}, 100)
            catch exit:_ -> {error, unavailable} end;
        Error -> Error
    end.

worker_path() ->
    case os:getenv("PLAINWIRE_MEDIA_QUALITY") of
        "off" -> disabled;
        _ ->
            case os:getenv("PLAINWIRE_MEDIA_QUALITY_BIN") of
                false ->
                    Priv = case code:priv_dir(plainwire_relay) of {error, _} -> "priv"; P -> P end,
                    filename:absname(filename:join([Priv, "bin", "pw-media-quality"]));
                Path -> Path
            end
    end.

validate(Rows) when is_list(Rows), length(Rows) >= 1, length(Rows) =< 24 ->
    Limits = [300, 100, 10000, 30000, 100, 30000, 100000, 100000, 100],
    try
        true = lists:all(fun(Row) ->
            is_list(Row) andalso length(Row) =:= 9 andalso
                lists:all(fun({V, Max}) -> is_number(V) andalso (V =:= -1 orelse V =:= -1.0 orelse V >= 0) andalso V =< Max end,
                          lists:zip(Row, Limits))
        end, Rows),
        Times = [hd(R) || R <- Rows],
        true = hd(Times) >= 0,
        true = increasing(Times),
        {ok, <<(length(Rows)):32, (iolist_to_binary([<< (float(V)):64/float-big >> || R <- Rows, V <- R]))/binary>>}
    catch _:_ -> {error, invalid_samples} end;
validate(_) -> {error, invalid_samples}.
increasing([A, B | Rest]) -> B - A >= 1 andalso increasing([B | Rest]);
increasing([_]) -> true.

%% Accept the previous 13-field worker during staged upgrades. Its new
%% measurements remain null, so they cannot trigger new adaptive behavior.
decode(Bin) when is_binary(Bin), byte_size(Bin) =:= 104; is_binary(Bin), byte_size(Bin) =:= 152 ->
    try
        Raw = [V || <<V:64/float-big>> <= Bin],
        true = length(Raw) * 8 =:= byte_size(Bin),
        Values = case length(Raw) of 13 -> Raw ++ lists:duplicate(6, -1.0); 19 -> Raw end,
        Keys = [score, stability, loss_pct, jitter_p95_ms, rtt_ms, concealment_pct,
                buffer_ms, bitrate_variation_pct, jitter_trend, loss_trend,
                upstream_loss_pct, coverage_pct, sample_count, recent_score, upstream_score,
                loss_burst_pct, loss_burst_seconds, rtt_p95_ms, confidence_pct],
        Limits = [100, 100, 100, 10000, 30000, 100, 30000, 10000, 100000, 1000, 100, 100, 24,
                  100, 100, 100, 300, 30000, 100],
        true = lists:all(fun({K, V, Max}) ->
            case nullable(K, V) of
                null -> K =/= sample_count andalso K =/= coverage_pct;
                N when K =:= jitter_trend; K =:= loss_trend -> abs(N) =< Max;
                N when K =:= sample_count -> N >= 1 andalso N =< Max andalso N =:= float(trunc(N));
                N -> N >= 0 andalso N =< Max
            end
        end, lists:zip3(Keys, Values, Limits)),
        Result = maps:from_list([{K, nullable(K, V)} || {K, V} <- lists:zip(Keys, Values)]),
        Score = maps:get(score, Result),
        true = Score =:= null orelse (Score >= 0 andalso Score =< 100),
        {ok, Result#{recommendation => policy(Result)}}
    catch _:_ -> {error, invalid_native_output} end;
decode(_) -> {error, invalid_native_output}.
nullable(K, -1000000000.0) when K =:= jitter_trend; K =:= loss_trend -> null;
nullable(K, V) when K =:= jitter_trend; K =:= loss_trend -> V;
nullable(_, -1.0) -> null;
nullable(_, V) -> V.

%% Interpretation belongs to the numerical worker; actions remain Plainwire's.
%% These are advisory. Only optional, bounded screen bitrate changes use them.
policy(#{upstream_score := Score, upstream_loss_pct := Loss})
  when is_number(Score), Score =< 75, is_number(Loss), Loss >= 5 -> reduce_screen_bitrate;
policy(#{score := Score}) when Score =:= null -> insufficient_data;
policy(#{score := Score, upstream_loss_pct := Loss}) when is_number(Loss), Loss >= 5, Score < 60 -> reduce_screen_bitrate;
policy(#{concealment_pct := Conceal}) when is_number(Conceal), Conceal >= 5 -> audio_gaps;
policy(#{score := Score, recent_score := Recent, confidence_pct := Evidence,
         jitter_trend := Jitter, loss_trend := Loss})
  when is_number(Score), is_number(Recent), is_number(Evidence), Evidence >= 40,
       Recent < Score - 15, ((is_number(Jitter) andalso Jitter >= 5) orelse (is_number(Loss) andalso Loss >= 1)) -> deteriorating_connection;
policy(#{loss_burst_seconds := Seconds, loss_burst_pct := Percent})
  when is_number(Seconds), Seconds >= 10, is_number(Percent), Percent >= 20 -> burst_packet_loss;
policy(#{loss_pct := Loss}) when is_number(Loss), Loss >= 3 -> receiving_packet_loss;
policy(#{rtt_ms := RTT}) when is_number(RTT), RTT >= 400 -> high_latency;
policy(#{jitter_p95_ms := Jitter}) when is_number(Jitter), Jitter >= 50 -> unstable_arrival;
policy(_) -> healthy.

init(Path) ->
    process_flag(trap_exit, true),
    self() ! open_worker,
    {ok, #{path => Path, port => undefined, active => undefined, queue => queue:new(),
           retry_ms => 1000}}.
handle_call(available, _, S) -> {reply, is_port(maps:get(port, S)), S};
handle_call({submit, _, _, _, _}, _, S = #{port := undefined}) -> {reply, {error, unavailable}, S};
handle_call({submit, Pid, Request, Peer, Binary}, _, S) ->
    Q = maps:get(queue, S),
    case queue:len(Q) >= 31 of
        true -> {reply, {error, busy}, S};
        false ->
            Job = #{pid => Pid, request => Request, peer => Peer, binary => Binary,
                    deadline => erlang:monotonic_time(millisecond) + 1000},
            {reply, ok, next(S#{queue => queue:in(Job, Q)})}
    end;
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(open_worker, S = #{path := disabled}) -> {noreply, S};
handle_info(open_worker, S = #{path := Path}) ->
    try
        true = filename:pathtype(Path) =:= absolute,
        true = filelib:is_regular(Path),
        Port = open_port({spawn_executable, Path}, [binary, {packet, 4}, exit_status, use_stdio]),
        {noreply, S#{port => Port}}
    catch _:_ ->
        logger:notice("[plainwire:quality] native analysis unavailable; calls continue normally"),
        erlang:send_after(30000, self(), open_worker),
        {noreply, S}
    end;
handle_info({Port, {data, Data}}, S = #{port := Port, active := Job}) when is_map(Job) ->
    erlang:cancel_timer(maps:get(timer, Job)),
    case decode(Data) of
        {ok, Result} ->
            reply(Job, Result),
            {noreply, next(S#{active => undefined, retry_ms => 1000})};
        {error, _} -> {noreply, failed(S)}
    end;
handle_info({native_timeout, Token}, S = #{active := #{token := Token}}) -> {noreply, failed(S)};
handle_info({Port, {exit_status, _}}, S = #{port := Port}) -> {noreply, failed(S)};
handle_info({'EXIT', Port, _}, S = #{port := Port}) -> {noreply, failed(S)};
handle_info(_, S) -> {noreply, S}.
terminate(_, S) -> close_port(maps:get(port, S)), ok.
code_change(_, S, _) -> {ok, S}.

next(S = #{active := undefined, port := Port, queue := Q}) when is_port(Port) ->
    case queue:out(Q) of
        {empty, _} -> S;
        {{value, Job}, Rest} ->
            Now = erlang:monotonic_time(millisecond),
            case maps:get(deadline, Job) > Now andalso is_process_alive(maps:get(pid, Job)) of
                false -> reply(Job, #{unavailable => true}), next(S#{queue => Rest});
                true ->
                    Token = make_ref(),
                    Timer = erlang:send_after(250, self(), {native_timeout, Token}),
                    S1 = S#{active => Job#{token => Token, timer => Timer}, queue => Rest},
                    try erlang:port_command(Port, maps:get(binary, Job), [nosuspend]) of
                        true -> S1;
                        false -> failed(S1)
                    catch _:_ -> failed(S1) end
            end
    end;
next(S) -> S.

failed(S) ->
    close_port(maps:get(port, S)),
    case maps:get(active, S) of
        undefined -> ok;
        Job -> erlang:cancel_timer(maps:get(timer, Job)), reply(Job, #{unavailable => true})
    end,
    [reply(J, #{unavailable => true}) || J <- queue:to_list(maps:get(queue, S))],
    Delay = maps:get(retry_ms, S),
    erlang:send_after(Delay, self(), open_worker),
    logger:warning("[plainwire:quality] worker failed; restarting in ~p ms", [Delay]),
    S#{port => undefined, active => undefined, queue => queue:new(), retry_ms => min(30000, Delay * 2)}.
reply(Job, Result) ->
    maps:get(pid, Job) ! {quality_result, maps:get(request, Job), maps:get(peer, Job), Result}.
close_port(Port) when is_port(Port) ->
    try erlang:port_close(Port) of _ -> ok catch error:badarg -> ok end;
close_port(_) -> ok.
