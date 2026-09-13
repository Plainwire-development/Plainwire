%% Cloudflare Realtime TURN integration.
%%
%% Two independent Cloudflare API calls live here:
%%   1. Minting short-lived TURN credentials (rtc.live.cloudflare.com) —
%%      one credential is shared across all users for its TTL window rather
%%      than minted per-request, since it's just as valid for anyone during
%%      that window and Cloudflare bills on relayed bytes, not credential count.
%%   2. Polling this month's actual relayed-egress usage (the GraphQL
%%      Analytics API) so the app can stop offering TURN once a configured
%%      byte budget is reached, instead of quietly running past whatever
%%      free/paid cap the account has.
%%
%% Both calls are best-effort: on any failure this falls back to omitting
%% the TURN server (STUN-only), never to crashing a live request.
-module(pw_cf_turn).
-behaviour(gen_server).
-export([start_link/0, ice_entry/0, configured/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CREDENTIALS_URL_PREFIX, "https://rtc.live.cloudflare.com/v1/turn/keys/").
-define(CREDENTIALS_URL_SUFFIX, "/credentials/generate-ice-servers").
-define(GRAPHQL_URL, "https://api.cloudflare.com/client/v4/graphql").
%% mint a fresh credential a bit before it actually expires, not at the wire.
-define(CRED_EXPIRY_BUFFER_SECONDS, 300).
-define(DEFAULT_MONTHLY_LIMIT_BYTES, 950000000000). %% ~950 decimal GB: a safety
                                                     %% margin under Cloudflare's
                                                     %% published 1000 GB free tier.
-define(DEFAULT_CHECK_INTERVAL_MS, 300000). %% 5 minutes; usage isn't billed
                                             %% in real time, so there is no
                                             %% point polling much faster.

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% true once a TURN key id + its API token are both set. Cloudflare mode
%% takes priority over the legacy coturn-secret/static-credential modes in
%% pw_rtc_config when this is true.
configured() ->
    key_id() =/= <<>> andalso turn_token() =/= <<>>.

%% {ok, IceServerMap} | {error, over_limit} | {error, not_configured} | {error, term()}
ice_entry() ->
    case configured() of
        false -> {error, not_configured};
        true -> gen_server:call(?MODULE, ice_entry, 20000)
    end.

init([]) ->
    case configured() andalso account_id() =:= <<>> of
        true -> logger:warning("[plainwire:cf_turn] PLAINWIRE_CF_TURN_KEY_ID is set but "
                                "PLAINWIRE_CF_ACCOUNT_ID is not — usage limit checking is disabled "
                                "and TURN will run unmetered against your Cloudflare account.");
        false -> ok
    end,
    self() ! check_usage,
    {ok, #{cred => undefined, cred_expires_at => 0, over_limit => false}}.

handle_call(ice_entry, _From, #{over_limit := true} = State) ->
    {reply, {error, over_limit}, State};
handle_call(ice_entry, _From, State) ->
    Now = erlang:system_time(second),
    case State of
        #{cred := Entry, cred_expires_at := ExpiresAt} when Entry =/= undefined, ExpiresAt > Now ->
            {reply, {ok, Entry}, State};
        _ ->
            case fetch_credential() of
                {ok, Entry, ExpiresAt} ->
                    {reply, {ok, Entry}, State#{cred => Entry, cred_expires_at => ExpiresAt}};
                {error, Reason} ->
                    logger:warning("[plainwire:cf_turn] credential_fetch_failed reason=~p", [Reason]),
                    {reply, {error, Reason}, State}
            end
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(check_usage, State) ->
    NewState = case account_id() of
        <<>> -> State#{over_limit => false};
        _ ->
            case fetch_usage_bytes() of
                {ok, Bytes} ->
                    Limit = limit_bytes(),
                    OverLimit = Bytes >= Limit,
                    WasOverLimit = maps:get(over_limit, State, false),
                    case OverLimit of
                        WasOverLimit -> ok;
                        _ -> logger:notice("[plainwire:cf_turn] turn_limit_state_changed over_limit=~p "
                                           "usage_bytes=~p limit_bytes=~p", [OverLimit, Bytes, Limit])
                    end,
                    State#{over_limit => OverLimit};
                {error, Reason} ->
                    logger:warning("[plainwire:cf_turn] usage_check_failed reason=~p", [Reason]),
                    State
            end
    end,
    erlang:send_after(check_interval_ms(), self(), check_usage),
    {noreply, NewState};
handle_info(_Msg, State) -> {noreply, State}.

%% --- config ---

key_id() -> pw_util:env_str("PLAINWIRE_CF_TURN_KEY_ID", <<>>).
turn_token() -> pw_util:env_str("PLAINWIRE_CF_TURN_API_TOKEN", <<>>).
account_id() -> pw_util:env_str("PLAINWIRE_CF_ACCOUNT_ID", <<>>).

%% the analytics query can reuse the TURN token if it also carries the
%% "Account Analytics" permission, or use a separate token if you'd rather
%% keep the two scoped apart.
analytics_token() ->
    case pw_util:env_str("PLAINWIRE_CF_ANALYTICS_API_TOKEN", <<>>) of
        <<>> -> turn_token();
        T -> T
    end.

limit_bytes() -> pw_util:env_int("PLAINWIRE_TURN_MONTHLY_LIMIT_BYTES", ?DEFAULT_MONTHLY_LIMIT_BYTES).

check_interval_ms() -> erlang:max(60000, pw_util:env_int("PLAINWIRE_CF_USAGE_CHECK_INTERVAL_MS", ?DEFAULT_CHECK_INTERVAL_MS)).

cred_ttl_seconds() ->
    N = pw_util:env_int("PLAINWIRE_TURN_TTL_SECONDS", 3600),
    erlang:min(86400, erlang:max(300, N)).

%% --- Cloudflare: mint TURN credentials ---

fetch_credential() ->
    Url = iolist_to_binary([?CREDENTIALS_URL_PREFIX, key_id(), ?CREDENTIALS_URL_SUFFIX]),
    Body = jsx:encode(#{ttl => cred_ttl_seconds()}),
    case http_post_json(Url, turn_token(), Body) of
        {ok, 201, RespBody} -> parse_credential_response(RespBody);
        {ok, Code, RespBody} -> {error, {http_error, Code, safe_snippet(RespBody)}};
        {error, Reason} -> {error, Reason}
    end.

parse_credential_response(RespBody) ->
    try jsx:decode(RespBody, [return_maps]) of
        #{<<"iceServers">> := Servers} when is_list(Servers) ->
            %% the STUN entry in that list has no username; the TURN entry does.
            case lists:filter(fun(S) -> is_map(S) andalso maps:is_key(<<"username">>, S) end, Servers) of
                [Entry | _] ->
                    Urls = maps:get(<<"urls">>, Entry, []),
                    Username = maps:get(<<"username">>, Entry, <<>>),
                    Credential = maps:get(<<"credential">>, Entry, <<>>),
                    ExpiresAt = erlang:system_time(second) + cred_ttl_seconds() - ?CRED_EXPIRY_BUFFER_SECONDS,
                    {ok, #{urls => Urls, username => Username, credential => Credential,
                           credentialType => <<"password">>}, ExpiresAt};
                [] -> {error, no_turn_entry_in_response}
            end;
        _ -> {error, unexpected_response}
    catch _:_ -> {error, invalid_json}
    end.

%% --- Cloudflare: this month's relayed-egress usage ---

fetch_usage_bytes() ->
    {DateFrom, DateTo} = current_month_range(),
    Query = <<"query GetTurnUsage($accountId: String!, $dateFrom: DateTime!, $dateTo: DateTime!) { "
              "viewer { accounts(filter: { accountTag: $accountId }) { "
              "callsTurnUsageAdaptiveGroups(limit: 10000, filter: { date_geq: $dateFrom, date_leq: $dateTo }) { "
              "sum { egressBytes } } } } }">>,
    Body = jsx:encode(#{
        query => Query,
        variables => #{accountId => account_id(), dateFrom => DateFrom, dateTo => DateTo}
    }),
    case http_post_json(<<?GRAPHQL_URL>>, analytics_token(), Body) of
        {ok, 200, RespBody} -> parse_usage_response(RespBody);
        {ok, Code, RespBody} -> {error, {http_error, Code, safe_snippet(RespBody)}};
        {error, Reason} -> {error, Reason}
    end.

parse_usage_response(RespBody) ->
    try jsx:decode(RespBody, [return_maps]) of
        #{<<"errors">> := Errors} when is_list(Errors), Errors =/= [] ->
            {error, {graphql_errors, Errors}};
        #{<<"data">> := #{<<"viewer">> := #{<<"accounts">> := Accounts}}} ->
            Groups = lists:flatmap(fun(A) -> maps:get(<<"callsTurnUsageAdaptiveGroups">>, A, []) end, Accounts),
            Total = lists:foldl(fun(G, Acc) ->
                Sum = maps:get(<<"sum">>, G, #{}),
                Acc + to_int(maps:get(<<"egressBytes">>, Sum, 0))
            end, 0, Groups),
            {ok, Total};
        _ -> {error, unexpected_response}
    catch _:_ -> {error, invalid_json}
    end.

to_int(N) when is_integer(N) -> N;
to_int(N) when is_float(N) -> round(N);
to_int(_) -> 0.

current_month_range() ->
    {{Y, M, _}, _} = calendar:universal_time(),
    {{Y2, M2, D2}, {H2, Mi2, S2}} = calendar:universal_time(),
    From = iolist_to_binary(io_lib:format("~4..0B-~2..0B-01T00:00:00Z", [Y, M])),
    To = iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y2, M2, D2, H2, Mi2, S2])),
    {From, To}.

%% --- shared HTTP helper (inets/httpc, same client pw_http_fetch uses) ---

http_post_json(UrlBin, TokenBin, Body) ->
    Url = binary_to_list(iolist_to_binary(UrlBin)),
    Headers = [{"authorization", "Bearer " ++ binary_to_list(TokenBin)}],
    HttpOptions = [{timeout, 15000}, {connect_timeout, 5000}],
    Request = {Url, Headers, "application/json", Body},
    case httpc:request(post, Request, HttpOptions, [{body_format, binary}]) of
        {ok, {{_, Code, _}, _RespHeaders, RespBody}} -> {ok, Code, RespBody};
        {error, Reason} -> {error, Reason}
    end.

safe_snippet(Bin) when is_binary(Bin) -> binary:part(Bin, 0, erlang:min(200, byte_size(Bin)));
safe_snippet(Other) -> Other.
