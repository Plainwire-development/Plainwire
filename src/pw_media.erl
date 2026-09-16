-module(pw_media).
-behaviour(gen_server).
-export([start_link/0, proxy_url/1, fetch/2, fetch_page/2, validate_url/1, cache_data_url/1, stats/0]).
-ifdef(TEST).
-export([resolve_redirect/2]).
-endif.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CACHE, pw_media_cache).
-define(INFLIGHT, pw_media_inflight).
-define(RESULTS, pw_media_results).
-define(LIMITS, pw_media_limits).
-define(MAX_BYTES, 26214400).
-define(MAX_SERVE_BYTES, 15728640).
-define(TTL_MS, 3600000).
-define(MAX_CACHE_ENTRIES, 500).
-define(MAX_CACHE_MEM, 104857600).
-define(MAX_FETCH_RESULTS, 4096).
-define(FETCH_SLOT_WAIT_MS, 10000).
-define(FETCH_RESULT_TTL_MS, 5000).
-define(FETCH_BUDGET_GRACE_MS, 3000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stats() ->
    try
        Active = case ets:lookup(?LIMITS, active_fetches) of
            [{active_fetches, N}] when is_integer(N) -> N;
            _ -> 0
        end,
        #{active_fetches => Active,
          cache_entries => ets:info(?CACHE, size),
          inflight_fetches => ets:info(?INFLIGHT, size),
          coalescing_results => ets:info(?RESULTS, size)}
    catch _:_ ->
        #{active_fetches => 0, cache_entries => 0, inflight_fetches => 0, coalescing_results => 0}
    end.

proxy_url(Url) when is_binary(Url) ->
    <<"/api/media/", (pw_crypto:proxy_token(Url))/binary>>.

cache_data_url(<<"data:", Rest/binary>> = DataUrl) ->
    SynthUrl = <<"data-proxy:", (pw_util:sha256_hex(DataUrl))/binary>>,
    Key = cache_key(SynthUrl),
    Now = pw_util:now_ms(),
    case cache_lookup(Key) of
        [{Key, _Body, _ContentType, Expires}] when Expires > Now ->
            %% don't decode the same enormous avatar on every profile map.
            proxy_url(SynthUrl);
        _ ->
            case safe_data_url_parse(Rest) of
                {ok, ContentType, Body} ->
                    ets:insert(?CACHE, {Key, Body, ContentType, Now + ?TTL_MS}),
                    prune_cache(Now),
                    proxy_url(SynthUrl);
                error ->
                    <<>>
            end
    end;
cache_data_url(Url) -> Url.

safe_data_url_parse(Rest) ->
    case binary:split(Rest, <<",">>) of
        [Meta, BodyB64] ->
            ContentType0 = case binary:split(Meta, <<";">>) of
                [CT | _] -> string:lowercase(string:trim(CT));
                _ -> string:lowercase(string:trim(Meta))
            end,
            case safe_data_image_type(ContentType0) of
                false -> error;
                true ->
                    try base64:decode(BodyB64) of
                        Body when byte_size(Body) =< ?MAX_SERVE_BYTES ->
                            {ok, ContentType0, Body};
                        _ -> error
                    catch _:_ -> error
                    end
            end;
        _ -> error
    end.

safe_data_image_type(<<"image/jpeg">>) -> true;
safe_data_image_type(<<"image/png">>) -> true;
safe_data_image_type(<<"image/gif">>) -> true;
safe_data_image_type(<<"image/webp">>) -> true;
safe_data_image_type(<<"image/avif">>) -> true;
safe_data_image_type(_) -> false.

fetch(Uid, Token) ->
    %% fetch outside the gen_server. one slow avatar once held up the lot.
    try resolve_fetch(Uid, Token)
    catch C:R:S ->
        error_logger:error_msg("media fetch failed ~p:~p ~p~n", [C, R, S]),
        {error, fetch_failed}
    end.

init([]) ->
    _ = ets:new(?CACHE, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(?INFLIGHT, [named_table, public, set, {write_concurrency, true}]),
    _ = ets:new(?RESULTS, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(?LIMITS, [named_table, public, set, {write_concurrency, true}]),
    ets:insert(?LIMITS, {active_fetches, 0}),
    {ok, #{}}.

handle_call({fetch, Uid, Token}, _From, St) ->
    Reply = try resolve_fetch(Uid, Token)
            catch C:R:S ->
                error_logger:error_msg("media fetch failed ~p:~p ~p~n", [C, R, S]),
                {error, fetch_failed}
            end,
    {reply, Reply, St};
handle_call(_, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_, St) -> {noreply, St}.
handle_info(_, St) -> {noreply, St}.
terminate(_, _) -> ok.
code_change(_, St, _) -> {ok, St}.

resolve_fetch(_Uid, Token) ->
    Url = decode_token(Token),
    Key = cache_key(Url),
    Now = pw_util:now_ms(),
    case cache_lookup(Key) of
        %% Keep compatibility with error markers written by 1.7.5-1 prerelease
        %% builds while preserving the specific reason for all new entries.
        [{Key, <<"error">>, <<"error">>, Expires}] when Expires > Now ->
            {error, upstream_error};
        [{Key, <<"error">>, Reason, Expires}] when Expires > Now, is_atom(Reason) ->
            {error, Reason};
        [{Key, Body, Type, Expires}] when Expires > Now, byte_size(Body) =< ?MAX_SERVE_BYTES ->
            {ok, Body, Type};
        [{Key, _, _, Expires}] when Expires > Now ->
            {error, too_large};
        _ ->
            resolve_fetch_url(Url, Key, Now)
    end.

cache_lookup(Key) ->
    try ets:lookup(?CACHE, Key) catch error:badarg -> [] end.

resolve_fetch_url(<<"data-proxy:", _/binary>>, _Key, _Now) ->
    {error, not_found};
resolve_fetch_url(Url, Key, Now) ->
    case validate_url(Url) of
        ok ->
            case coalesced_http_get(Url, Key) of
                {ok, Body, Type} ->
                    case byte_size(Body) =< ?MAX_SERVE_BYTES of
                        true ->
                            ets:insert(?CACHE, {Key, Body, Type, Now + ?TTL_MS}),
                            prune_cache(Now),
                            {ok, Body, Type};
                        false ->
                            cache_negative(Key, too_large, Now, 3600000),
                            {error, too_large}
                    end;
                {error, blocked_url} = Err ->
                    Err;
                {error, unsupported_type} = Err ->
                    cache_negative(Key, unsupported_type, Now, 3600000),
                    Err;
                {error, Reason} = Err ->
                    %% Cache upstream misery long enough that avatar-heavy pages
                    %% do not stampede a dead host on every refresh. Preserve the
                    %% reason so a cached timeout/overload keeps the same HTTP
                    %% semantics as the first request.
                    cache_negative(Key, Reason, Now, 30000),
                    Err
            end;
        Err ->
            Err
    end.

cache_negative(Key, Reason0, Now, TtlMs) ->
    %% httpc can return nested tuples such as {http, 500}. Never place arbitrary
    %% terms in the content-type slot: cache reads intentionally accept only this
    %% small atom vocabulary and collapse everything else to upstream_error.
    Reason = cacheable_error_reason(Reason0),
    ets:insert(?CACHE, {Key, <<"error">>, Reason, Now + TtlMs}),
    %% Negative entries count toward the exact same memory/cardinality budget as
    %% successful media. Without this call, unique dead URLs bypassed MAX_CACHE_ENTRIES.
    prune_cache(Now).

cacheable_error_reason(timeout) -> timeout;
cacheable_error_reason(overloaded) -> overloaded;
cacheable_error_reason(too_large) -> too_large;
cacheable_error_reason(unsupported_type) -> unsupported_type;
cacheable_error_reason(_) -> upstream_error.

%% one download per URL, with a global cap. GIF stampedes are real somehow.
coalesced_http_get(Url, Key) ->
    Now = erlang:monotonic_time(millisecond),
    Budget = fetch_operation_budget_ms(),
    case fetch_result(Key, Now) of
        {hit, Result} -> Result;
        miss ->
            Lock = {Key, self(), Now},
            case ets:insert_new(?INFLIGHT, Lock) of
                true ->
                    try
                        Result = bounded_http_get(Url),
                        ets:insert(?RESULTS, {Key, Result, erlang:monotonic_time(millisecond) + ?FETCH_RESULT_TTL_MS}),
                        trim_fetch_results(),
                        Result
                    after ets:delete_object(?INFLIGHT, Lock)
                    end;
                false ->
                    await_fetch(Key, Url, Now + Budget, Budget)
            end
    end.

%% Waiters must use the same worst-case budget as the owner: the owner may spend
%% time queued behind the global concurrency cap before its own HTTP deadline even
%% starts. Keeping one shared budget prevents a slow-but-valid request from being
%% declared stale while it is still inside Plainwire's configured limits.
fetch_operation_budget_ms() ->
    ?FETCH_SLOT_WAIT_MS + media_http_timeout_ms() + ?FETCH_BUDGET_GRACE_MS.

media_http_timeout_ms() ->
    min(30000, max(2000, pw_util:env_int("PLAINWIRE_HTTP_FETCH_TIMEOUT_MS", 8000))).

await_fetch(Key, Url, Deadline, StaleAfterMs) ->
    Now = erlang:monotonic_time(millisecond),
    case fetch_result(Key, Now) of
        {hit, Result} -> Result;
        miss when Now >= Deadline -> {error, timeout};
        miss ->
            case ets:lookup(?INFLIGHT, Key) of
                [{Key, Owner, Started}] when is_pid(Owner) ->
                    case is_process_alive(Owner) andalso Now - Started < StaleAfterMs of
                        true -> receive after 25 -> await_fetch(Key, Url, Deadline, StaleAfterMs) end;
                        false ->
                            ets:delete_object(?INFLIGHT, {Key, Owner, Started}),
                            coalesced_http_get(Url, Key)
                    end;
                _ -> coalesced_http_get(Url, Key)
            end
    end.

fetch_result(Key, Now) ->
    case ets:lookup(?RESULTS, Key) of
        [{Key, Result, Expires}] when Expires > Now ->
            {hit, Result};
        [{Key, _Result, _Expires}] ->
            %% One-off URLs should not retain dead dedupe entries indefinitely.
            ets:delete(?RESULTS, Key),
            miss;
        _ ->
            miss
    end.

%% ?RESULTS is only a short coalescing handoff cache, not durable media cache.
%% Bound it independently so a busy long-lived node cannot accumulate one ETS
%% row forever for every unique avatar URL it has ever seen. Under an extreme
%% >4096-results-in-5s burst, evicting any handoff result is safe: at worst one
%% waiter performs a duplicate bounded fetch instead of leaking memory forever.
trim_fetch_results() ->
    case ets:info(?RESULTS, size) of
        Size when is_integer(Size), Size > ?MAX_FETCH_RESULTS ->
            case ets:first(?RESULTS) of
                '$end_of_table' -> ok;
                EvictKey ->
                    ets:delete(?RESULTS, EvictKey),
                    trim_fetch_results()
            end;
        _ ->
            ok
    end.

bounded_http_get(Url) ->
    Max = max(1, pw_util:env_int("PLAINWIRE_MEDIA_FETCH_CONCURRENCY", 24)),
    Deadline = erlang:monotonic_time(millisecond) + ?FETCH_SLOT_WAIT_MS,
    case acquire_fetch_slot(Max, Deadline) of
        ok ->
            try http_get(Url)
            after ets:update_counter(?LIMITS, active_fetches, {2, -1}, {active_fetches, 1})
            end;
        {error, overloaded} = Err ->
            %% Return a normal bounded failure so the coalescer can publish it to
            %% all waiters and the caller can negative-cache it. Raising here used
            %% to strand waiters behind an owner that had already crashed out.
            Err
    end.

acquire_fetch_slot(Max, Deadline) ->
    Active = ets:update_counter(?LIMITS, active_fetches, {2, 1}, {active_fetches, 0}),
    case Active =< Max of
        true -> ok;
        false ->
            _ = ets:update_counter(?LIMITS, active_fetches, {2, -1}),
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, overloaded};
                false -> receive after 20 -> acquire_fetch_slot(Max, Deadline) end
            end
    end.

decode_token(Token) ->
    case binary:split(Token, <<".">>, []) of
        [SigPart, UrlB64 | _] ->
            Url = pw_util:base64url_decode(UrlB64),
            Full = <<SigPart/binary, ".", UrlB64/binary>>,
            case pw_crypto:verify_proxy_token(Full, Url) of
                true when byte_size(Url) > 0 -> Url;
                _ -> erlang:error(invalid_token)
            end;
        [Legacy] ->
            %% old unsigned tokens are dev-only. production has standards.
            case production_env() andalso not pw_util:env_bool("PLAINWIRE_ALLOW_UNSIGNED_MEDIA_TOKENS", false) of
                true -> erlang:error(invalid_token);
                false ->
                    Url = pw_util:base64url_decode(Legacy),
                    case byte_size(Url) > 0 of
                        true -> Url;
                        false -> erlang:error(invalid_token)
                    end
            end;
        _ -> erlang:error(invalid_token)
    end.

cache_key(Url) -> pw_util:sha256_hex(Url).

validate_url(Url) ->
    case uri_string:parse(binary_to_list(Url)) of
        #{scheme := Scheme, host := Host} when Scheme =:= "http"; Scheme =:= "https" ->
            LowerHost = string:lowercase(Host),
            %% Reject a disallowed hostname before DNS. Aside from being faster in
            %% production allow-list mode, this avoids pointless resolver work for
            %% every blocked avatar on a large friends list.
            case host_allowed(LowerHost) of
                false -> {error, blocked_url};
                true ->
                    case blocked_host_or_addr(LowerHost) of
                        true -> {error, blocked_url};
                        false -> ok
                    end
            end;
        _ ->
            {error, invalid_url}
    end.

host_allowed(Host) ->
    case pw_util:env_str("PLAINWIRE_MEDIA_ALLOWED_HOSTS", <<>>) of
        <<>> ->
            not production_env() orelse pw_util:env_bool("PLAINWIRE_ALLOW_ARBITRARY_MEDIA", false);
        Csv ->
            Hosts = [string:lowercase(binary_to_list(string:trim(H))) ||
                H <- binary:split(Csv, <<",">>, [global]), H =/= <<>>],
            lists:any(fun(Allowed) ->
                Host =:= Allowed orelse lists:suffix("." ++ Allowed, Host)
            end, Hosts)
    end.

production_env() ->
    lists:member(os:getenv("PLAINWIRE_ENV"), ["prod", "production"]) orelse
        lists:member(os:getenv("NODE_ENV"), ["prod", "production"]).

%% only IP literals use the blocked-address table; 0.gravatar.com is a hostname.
blocked_host(H) ->
    case host_to_addr(H) of
        {ok, Addr} -> blocked_addr(Addr);
        error -> H =:= "localhost" orelse lists:suffix(".localhost", H)
    end.

host_to_addr([$[ | Rest]) ->
    case string:split(Rest, "]") of
        [Inner, _] -> parse_addr(Inner);
        _ -> error
    end;
host_to_addr(H) -> parse_addr(H).

parse_addr(S) ->
    case inet:parse_address(S) of
        {ok, Addr} -> {ok, Addr};
        _ -> error
    end.

blocked_host_or_addr(H) ->
    blocked_host(H) orelse addresses_blocked(H).

addresses_blocked(H) ->
    Addrs = resolve_addrs(H, inet) ++ resolve_addrs(H, inet6),
    case Addrs of
        [] -> true;
        _ -> lists:any(fun blocked_addr/1, Addrs)
    end.

resolve_addrs(H, Family) ->
    case inet:getaddrs(H, Family) of
        {ok, Addrs} -> Addrs;
        _ -> []
    end.

blocked_addr({10,_,_,_}) -> true;
blocked_addr({127,_,_,_}) -> true;
blocked_addr({0,_,_,_}) -> true;
blocked_addr({169,254,_,_}) -> true;
blocked_addr({100,B,_,_}) when B >= 64, B =< 127 -> true;
blocked_addr({172,B,_,_}) when B >= 16, B =< 31 -> true;
blocked_addr({192,0,0,_}) -> true;
blocked_addr({192,0,2,_}) -> true;
blocked_addr({192,168,_,_}) -> true;
blocked_addr({198,18,_,_}) -> true;
blocked_addr({198,19,_,_}) -> true;
blocked_addr({198,51,100,_}) -> true;
blocked_addr({203,0,113,_}) -> true;
    blocked_addr({_,_,_,_}) -> false;
blocked_addr({0,0,0,0,0,0,0,1}) -> true;
blocked_addr({0,0,0,0,0,16#ffff,A,B}) -> blocked_addr({A bsr 8, A band 255, B bsr 8, B band 255});
blocked_addr({S,_,_,_,_,_,_,_}) when S >= 16#fc00, S =< 16#fdff -> true;
blocked_addr({S,_,_,_,_,_,_,_}) when S >= 16#fe80, S =< 16#febf -> true;
blocked_addr({_,_,_,_,_,_,_,_}) -> false;
blocked_addr(_) -> true.

http_get(Url) ->
    case follow_redirects(Url, ?MAX_BYTES, #{}, 5) of
        {ok, RespHeaders, Body} ->
            Type = content_type(RespHeaders),
            case allowed_type(Type) of
                true -> {ok, Body, Type};
                false -> {error, unsupported_type}
            end;
        Err ->
            Err
    end.

%% Link previews: the same SSRF check on the URL and every redirect hop, but only
%% the start of the body is read and any content type goes back to the caller.
fetch_page(Url, MaxBytes) ->
    case validate_url(Url) of
        ok ->
            Opts = #{truncate => true, accept => "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
                     user_agent => "Mozilla/5.0 (compatible; PlainwireLinkPreview/1.0)"},
            case follow_redirects(Url, MaxBytes, Opts, 5) of
                {ok, RespHeaders, Body} -> {ok, string:lowercase(content_type(RespHeaders)), Body};
                Err -> Err
            end;
        Err ->
            Err
    end.

follow_redirects(_Url, _MaxBytes, _Opts, 0) ->
    {error, too_many_redirects};
follow_redirects(Url, MaxBytes, Opts, Depth) ->
    case pw_http_fetch:get(Url, MaxBytes, Opts) of
        {ok, Code, RespHeaders, Body} when Code >= 200, Code < 300 ->
            {ok, RespHeaders, Body};
        {ok, Code, RespHeaders, _} when Code >= 300, Code < 400 ->
            case header_value("location", RespHeaders) of
                undefined -> {error, {http, Code}};
                Location0 ->
                    Location = resolve_redirect(Url, pw_util:bin(Location0)),
                    case validate_url(Location) of
                        ok -> follow_redirects(Location, MaxBytes, Opts, Depth - 1);
                        _ -> {error, blocked_url}
                    end
            end;
        {ok, Code, _, _} ->
            {error, {http, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

%% Locations may be absolute, host-relative, protocol-relative or path-relative.
resolve_redirect(OriginalUrl, Location0) ->
    Location = pw_util:bin(Location0),
    try uri_string:resolve(Location, OriginalUrl) of
        Resolved when is_binary(Resolved) -> Resolved;
        _ -> Location
    catch _:_ -> Location
    end.

content_type(Headers) ->
    case header_value(<<"content-type">>, Headers) of
        undefined -> <<"application/octet-stream">>;
        CT0 ->
            CT = pw_util:bin(CT0),
            [MediaType | _] = binary:split(CT, <<";">>, [global]),
            string:lowercase(string:trim(MediaType))
    end.

header_value(Name0, Headers) ->
    Lower = string:lowercase(pw_util:bin(Name0)),
    case [V || {K, V} <- Headers, string:lowercase(pw_util:bin(K)) =:= Lower] of
        [V | _] -> V;
        [] -> undefined
    end.

allowed_type(<<"image/jpeg">>) -> true;
allowed_type(<<"image/png">>) -> true;
allowed_type(<<"image/gif">>) -> true;
allowed_type(<<"image/webp">>) -> true;
allowed_type(<<"image/avif">>) -> true;
allowed_type(_) -> false.

prune_cache(Now) ->
    Size = ets:info(?CACHE, size),
    MemBytes = ets:info(?CACHE, memory) * erlang:system_info(wordsize),
    NeedsPrune = Size > ?MAX_CACHE_ENTRIES orelse MemBytes > ?MAX_CACHE_MEM,
    case NeedsPrune of
        true ->
            ExpiredSpec = [{{'$1', '_', '_', '$3'}, [{'<', '$3', Now}], ['$1']}],
            Expired = ets:select(?CACHE, ExpiredSpec),
            [ets:delete(?CACHE, K) || K <- Expired],
            Sorted = lists:keysort(4, ets:tab2list(?CACHE)),
            drop_oldest_until_within(Sorted);
        false ->
            ok
    end.

drop_oldest_until_within([]) -> ok;
drop_oldest_until_within([{Key, _, _, _} | Rest]) ->
    Size = ets:info(?CACHE, size),
    MemBytes = ets:info(?CACHE, memory) * erlang:system_info(wordsize),
    case Size > ?MAX_CACHE_ENTRIES orelse MemBytes > ?MAX_CACHE_MEM of
        true -> ets:delete(?CACHE, Key), drop_oldest_until_within(Rest);
        false -> ok
    end.
