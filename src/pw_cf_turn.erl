%% Cloudflare credentials stay server-side. Only short-lived, per-user ICE
%% credentials leave this process. External HTTP never runs in a call handler.
-module(pw_cf_turn).
-behaviour(gen_server).
-export([start_link/0, configured/0, validate/0, ice_entry/1, parse_credentials/1,
         parse_usage/1, budget_state/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([start_link/1]).
start_link(Fetch) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Fetch, []).
-endif.

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, fun fetch/1, []).
env(K) -> pw_util:env_str(K, <<>>).
configured() -> env("PLAINWIRE_CF_TURN_KEY_ID") =/= <<>> andalso env("PLAINWIRE_CF_TURN_API_TOKEN") =/= <<>>.
validate() ->
    Key = env("PLAINWIRE_CF_TURN_KEY_ID"), Token = env("PLAINWIRE_CF_TURN_API_TOKEN"),
    Account = env("PLAINWIRE_CF_ACCOUNT_ID"),
    case {Key, Token} of
        {<<>>, <<>>} -> ok;
        _ ->
            case identifier(Key) andalso byte_size(Token) >= 20 andalso byte_size(Token) =< 4096
                 andalso (Account =:= <<>> orelse identifier(Account))
                 andalso binary:match(Token, [<<"\r">>, <<"\n">>]) =:= nomatch of
                true -> ok;
                false -> {error, invalid_cloudflare_turn_config}
            end
    end.
identifier(B) -> is_binary(B) andalso byte_size(B) >= 8 andalso byte_size(B) =< 128
    andalso re:run(B, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) =:= match.
ttl() -> max(600, min(86400, pw_util:env_int("PLAINWIRE_TURN_TTL_SECONDS", 3600))).
ice_entry(Uid) when is_integer(Uid), Uid > 0 ->
    case configured() of
        false -> {error, not_configured};
        true -> try gen_server:call(?MODULE, {ice, Uid}, 6000) catch exit:_ -> {error, unavailable} end
    end;
ice_entry(_) -> {error, unauthorized}.

init(Fetch) ->
    self() ! usage,
    erlang:send_after(60000, self(), sweep),
    {ok, #{fetch => Fetch, cache => #{}, jobs => #{}, budget => unknown,
           retry_at => erlang:monotonic_time(second) - 1}}.
handle_call({ice, Uid}, From, S) ->
    Now = erlang:monotonic_time(second),
    case budget_state(maps:get(budget, S), Now, env("PLAINWIRE_CF_ACCOUNT_ID") =/= <<>>) of
        ok ->
            case maps:get(Uid, maps:get(cache, S), undefined) of
                {Entry, Until} when Until > Now + 60 ->
                    S1 = case Until < Now + 300 of true -> launch(Uid, [], S); false -> S end,
                    {reply, {ok, Entry, Until - Now}, S1};
                _ ->
                    case maps:get(Uid, maps:get(jobs, S), undefined) of
                        #{waiters := W} = J when length(W) < 8 ->
                            {noreply, S#{jobs => maps:put(Uid, J#{waiters => [From | W]}, maps:get(jobs, S))}};
                        undefined ->
                            S1 = launch(Uid, [From], S),
                            case maps:is_key(Uid, maps:get(jobs, S1)) of
                                true -> {noreply, S1};
                                false -> {reply, {error, unavailable}, S1}
                            end;
                        _ -> {reply, {error, busy}, S}
                    end
            end;
        Reason -> {reply, {error, Reason}, S}
    end;
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(usage, S) ->
    Interval = max(60000, min(900000, pw_util:env_int("PLAINWIRE_CF_USAGE_CHECK_INTERVAL_MS", 300000))),
    erlang:send_after(Interval, self(), usage),
    S1 = case configured() andalso env("PLAINWIRE_CF_ACCOUNT_ID") =/= <<>> of
        true -> launch(usage, [], S);
        false -> S
    end,
    {noreply, S1};
handle_info(sweep, S) ->
    Now = erlang:monotonic_time(second),
    erlang:send_after(60000, self(), sweep),
    {noreply, S#{cache => maps:filter(fun(_, {_, Until}) -> Until > Now end, maps:get(cache, S))}};
handle_info({result, Key, Pid, Result}, S) ->
    case maps:get(Key, maps:get(jobs, S), undefined) of
        #{pid := Pid} = J -> {noreply, finish(Key, J, Result, S)};
        _ -> {noreply, S}
    end;
handle_info({job_timeout, Key, Pid}, S) ->
    case maps:get(Key, maps:get(jobs, S), undefined) of
        #{pid := Pid} = J -> exit(Pid, kill), {noreply, finish(Key, J, {error, timeout}, S)};
        _ -> {noreply, S}
    end;
handle_info({'DOWN', Ref, process, _, _}, S) ->
    case [{K, J} || {K, #{ref := R} = J} <- maps:to_list(maps:get(jobs, S)), R =:= Ref] of
        [{K, J}] -> {noreply, finish(K, J, {error, worker_failed}, S)};
        _ -> {noreply, S}
    end;
handle_info(_, S) -> {noreply, S}.
terminate(_, S) -> [exit(maps:get(pid, J), kill) || J <- maps:values(maps:get(jobs, S))], ok.
code_change(_, S, _) -> {ok, S}.

launch(Key, Waiters, S) ->
    Jobs = maps:get(jobs, S), Now = erlang:monotonic_time(second),
    Limit = case Key of usage -> 5; _ -> 4 end,
    case not maps:is_key(Key, Jobs) andalso map_size(Jobs) < Limit andalso
         (Key =:= usage orelse Now >= maps:get(retry_at, S)) of
        false -> S;
        true ->
            Parent = self(), Fetch = maps:get(fetch, S),
            {Pid, Ref} = spawn_monitor(fun() ->
                Result = try Fetch(Key) catch _:_ -> {error, fetch_failed} end,
                Parent ! {result, Key, self(), Result}
            end),
            Timer = erlang:send_after(5000, self(), {job_timeout, Key, Pid}),
            S#{jobs => maps:put(Key, #{pid => Pid, ref => Ref, timer => Timer, waiters => Waiters}, Jobs)}
    end.
finish(Key, J, Result, S) ->
    erlang:demonitor(maps:get(ref, J), [flush]), erlang:cancel_timer(maps:get(timer, J)),
    S0 = S#{jobs => maps:remove(Key, maps:get(jobs, S))},
    Now = erlang:monotonic_time(second),
    case {Key, Result} of
        {usage, {ok, Bytes}} when is_integer(Bytes), Bytes >= 0 ->
            Limit = max(0, pw_util:env_int("PLAINWIRE_TURN_MONTHLY_LIMIT_BYTES", 950000000000)),
            {Month, _} = month_range(),
            S0#{budget => {Bytes >= Limit, Now, Month}};
        {usage, _} -> logger:warning("[plainwire:turn] usage lookup unavailable"), S0;
        {_, {ok, Entry}} when is_map(Entry) ->
            Lifetime = ttl() - 10,
            {Reply, Cache} = case budget_state(maps:get(budget, S0), Now, env("PLAINWIRE_CF_ACCOUNT_ID") =/= <<>>) of
                ok ->
                    C0 = maps:filter(fun(_, {_, Until}) -> Until > Now end, maps:get(cache, S0)),
                    C1 = case map_size(C0) >= 1024 of true -> maps:remove(hd(maps:keys(C0)), C0); false -> C0 end,
                    {{ok, Entry, Lifetime}, maps:put(Key, {Entry, Now + Lifetime}, C1)};
                Reason -> {{error, Reason}, maps:get(cache, S0)}
            end,
            [gen_server:reply(W, Reply) || W <- maps:get(waiters, J)],
            S0#{cache => Cache, retry_at => erlang:monotonic_time(second) - 1};
        _ ->
            [gen_server:reply(W, {error, unavailable}) || W <- maps:get(waiters, J)],
            %% Do not log response bodies or tokens, even for provider errors.
            logger:warning("[plainwire:turn] credential lookup unavailable; retry delayed"),
            S0#{retry_at => Now + 30}
    end.

budget_state(_, _, false) -> ok;
budget_state({Over, At, Month}, Now, true) when Now - At =< 900 ->
    case month_range() of
        {Month, _} -> case Over of true -> over_limit; false -> ok end;
        _ -> usage_unavailable
    end;
budget_state(_, _, true) -> usage_unavailable.

fetch(usage) ->
    {From, To} = month_range(),
    Query = <<"query($accountId: String!, $dateFrom: Date!, $dateTo: Date!) { viewer { accounts(filter: {accountTag: $accountId}) { callsTurnUsageAdaptiveGroups(limit: 1, filter: {date_geq: $dateFrom, date_leq: $dateTo}) { sum { egressBytes } } } } }">>,
    Token = case env("PLAINWIRE_CF_ANALYTICS_API_TOKEN") of <<>> -> env("PLAINWIRE_CF_TURN_API_TOKEN"); T -> T end,
    case post("https://api.cloudflare.com/client/v4/graphql", Token,
              #{query => Query, variables => #{accountId => env("PLAINWIRE_CF_ACCOUNT_ID"), dateFrom => From, dateTo => To}}) of
        {ok, 200, Body} -> parse_usage(Body);
        _ -> {error, usage_unavailable}
    end;
fetch(_) ->
    Url = "https://rtc.live.cloudflare.com/v1/turn/keys/" ++ binary_to_list(env("PLAINWIRE_CF_TURN_KEY_ID")) ++ "/credentials/generate-ice-servers",
    case post(Url, env("PLAINWIRE_CF_TURN_API_TOKEN"), #{ttl => ttl()}) of
        {ok, 201, Body} -> parse_credentials(Body);
        _ -> {error, credential_unavailable}
    end.
post(Url, Token, Body) ->
    TLS = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
           {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Token)}, {"accept", "application/json"}],
    case httpc:request(post, {Url, Headers, "application/json", jsx:encode(Body)},
                       [{ssl, TLS}, {autoredirect, false}, {timeout, 4000}, {connect_timeout, 2000}],
                       [{body_format, binary}]) of
        {ok, {{_, Code, _}, _, Resp}} when byte_size(Resp) =< 262144 -> {ok, Code, Resp};
        _ -> {error, http_failed}
    end.
parse_credentials(B) when is_binary(B), byte_size(B) =< 262144 ->
    try
        #{<<"iceServers">> := Servers} = jsx:decode(B, [return_maps]),
        true = is_list(Servers) andalso length(Servers) =< 8,
        Entries = [S || S <- Servers, is_map(S), maps:is_key(<<"username">>, S)],
        [#{<<"urls">> := Urls, <<"username">> := U, <<"credential">> := P} | _] = Entries,
        true = is_list(Urls) andalso length(Urls) > 0 andalso length(Urls) =< 16,
        true = lists:all(fun valid_turn_url/1, Urls),
        true = is_binary(U) andalso byte_size(U) > 0 andalso byte_size(U) =< 2048,
        true = is_binary(P) andalso byte_size(P) > 0 andalso byte_size(P) =< 2048,
        {ok, #{urls => Urls, username => U, credential => P, credentialType => <<"password">>}}
    catch _:_ -> {error, invalid_credentials} end;
parse_credentials(_) -> {error, invalid_credentials}.
valid_turn_url(U) when is_binary(U), byte_size(U) < 256 ->
    re:run(U, <<"^turns?:turn\\.cloudflare\\.com:(3478|5349|443|80)\\?transport=(udp|tcp)$">>, [{capture, none}]) =:= match;
valid_turn_url(_) -> false.
parse_usage(B) when is_binary(B), byte_size(B) =< 262144 ->
    try
        M = jsx:decode(B, [return_maps]),
        Errors = maps:get(<<"errors">>, M, null), true = Errors =:= null orelse Errors =:= [],
        #{<<"data">> := #{<<"viewer">> := #{<<"accounts">> := [A]}}} = M,
        #{<<"callsTurnUsageAdaptiveGroups">> := Groups} = A,
        true = is_list(Groups) andalso length(Groups) =< 1,
        Ns = [begin #{<<"sum">> := #{<<"egressBytes">> := N}} = G,
                    true = is_integer(N) andalso N >= 0, N end || G <- Groups],
        {ok, lists:sum(Ns)}
    catch _:_ -> {error, invalid_usage} end;
parse_usage(_) -> {error, invalid_usage}.
month_range() ->
    {{Y, M, D}, _} = calendar:universal_time(),
    {iolist_to_binary(io_lib:format("~4..0B-~2..0B-01", [Y, M])),
     iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D]))}.
