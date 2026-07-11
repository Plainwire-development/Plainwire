-module(pw_media).
-behaviour(gen_server).
-export([start_link/0, proxy_url/1, fetch/2, validate_url/1, cache_data_url/1]).
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

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

proxy_url(Url) when is_binary(Url) ->
    <<"/api/media/", (pw_crypto:proxy_token(Url))/binary>>.

cache_data_url(<<"data:", Rest/binary>> = DataUrl) ->
    SynthUrl = <<"data-proxy:", (pw_util:sha256_hex(DataUrl))/binary>>,
    Key = cache_key(SynthUrl),
    Now = pw_util:now_ms(),
    case cache_lookup(Key) of
        [{Key, _Body, _ContentType, Expires}] when Expires > Now ->
            %% Profile maps are built often; avoid repeatedly base64-decoding
            %% the same multi-megabyte avatar while its cache entry is alive.
            proxy_url(SynthUrl);
        _ ->
            case safe_data_url_parse(Rest) of
                {ok, ContentType, Body} ->
                    ets:insert(?CACHE, {Key, Body, ContentType, Now + ?TTL_MS}),
                    proxy_url(SynthUrl);
                error ->
                    DataUrl
            end
    end;
cache_data_url(Url) -> Url.

safe_data_url_parse(Rest) ->
    case binary:split(Rest, <<",">>) of
        [Meta, BodyB64] ->
            ContentType = case binary:split(Meta, <<";">>) of
                [CT | _] -> CT;
                _ -> Meta
            end,
            try base64:decode(BodyB64) of
                Body when byte_size(Body) =< ?MAX_SERVE_BYTES ->
                    {ok, ContentType, Body};
                _ -> error
            catch _:_ -> error
            end;
        _ -> error
    end.

fetch(Uid, Token) ->
    %% Remote requests must not run inside the gen_server: one slow avatar used
    %% to block every other image request behind it.
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
        [{Key, <<"error">>, <<"error">>, Expires}] when Expires > Now ->
            {error, upstream_error};
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
                            {error, too_large}
                    end;
                Err ->
                    ets:insert(?CACHE, {Key, <<"error">>, <<"error">>, Now + 60000}),
                    Err
            end;
        Err ->
            Err
    end.

%% A popular uncached GIF can be requested by hundreds of page renders at the
%% same instant. Only one process downloads a URL; followers wait for its
%% short-lived result. A global semaphore also caps distinct upstream fetches.
coalesced_http_get(Url, Key) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?RESULTS, Key) of
        [{Key, Result, Expires}] when Expires > Now -> Result;
        _ ->
            Lock = {Key, self(), Now},
            case ets:insert_new(?INFLIGHT, Lock) of
                true ->
                    try
                        Result = bounded_http_get(Url),
                        ets:insert(?RESULTS, {Key, Result, erlang:monotonic_time(millisecond) + 5000}),
                        Result
                    after ets:delete_object(?INFLIGHT, Lock)
                    end;
                false ->
                    await_fetch(Key, Url, Now + 17000)
            end
    end.

await_fetch(Key, Url, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?RESULTS, Key) of
        [{Key, Result, Expires}] when Expires > Now -> Result;
        _ when Now >= Deadline -> {error, timeout};
        _ ->
            case ets:lookup(?INFLIGHT, Key) of
                [{Key, Owner, Started}] when is_pid(Owner) ->
                    case is_process_alive(Owner) andalso Now - Started < 20000 of
                        true -> receive after 25 -> await_fetch(Key, Url, Deadline) end;
                        false ->
                            ets:delete_object(?INFLIGHT, {Key, Owner, Started}),
                            coalesced_http_get(Url, Key)
                    end;
                _ -> coalesced_http_get(Url, Key)
            end
    end.

bounded_http_get(Url) ->
    Max = max(1, pw_util:env_int("PLAINWIRE_MEDIA_FETCH_CONCURRENCY", 24)),
    acquire_fetch_slot(Max, erlang:monotonic_time(millisecond) + 10000),
    try http_get(Url)
    after ets:update_counter(?LIMITS, active_fetches, {2, -1}, {active_fetches, 1})
    end.

acquire_fetch_slot(Max, Deadline) ->
    Active = ets:update_counter(?LIMITS, active_fetches, {2, 1}, {active_fetches, 0}),
    case Active =< Max of
        true -> ok;
        false ->
            _ = ets:update_counter(?LIMITS, active_fetches, {2, -1}),
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> erlang:error(media_overloaded);
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
            %% Compatibility for URLs issued before signed proxy tokens. The
            %% decoded URL still passes DNS/IP and production allowlist checks.
            Url = pw_util:base64url_decode(Legacy),
            case byte_size(Url) > 0 of
                true -> Url;
                false -> erlang:error(invalid_token)
            end;
        _ -> erlang:error(invalid_token)
    end.

cache_key(Url) -> pw_util:sha256_hex(Url).

validate_url(Url) ->
    case uri_string:parse(binary_to_list(Url)) of
        #{scheme := Scheme, host := Host} when Scheme =:= "http"; Scheme =:= "https" ->
            LowerHost = string:lowercase(Host),
            case blocked_host_or_addr(LowerHost) orelse not host_allowed(LowerHost) of
                true -> {error, blocked_url};
                false -> ok
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

blocked_host(H) ->
    lists:any(fun(Prefix) -> string:prefix(H, Prefix) =:= Prefix end,
        ["localhost", "127.", "0.", "10.", "192.168.", "172.16.", "172.17.",
         "172.18.", "172.19.", "172.20.", "172.21.", "172.22.", "172.23.",
         "172.24.", "172.25.", "172.26.", "172.27.", "172.28.", "172.29.",
         "172.30.", "172.31.", "[::1]", "::1"]) orelse H =:= "169.254.169.254".

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
    case pw_http_fetch:get(Url, ?MAX_BYTES) of
        {ok, Code, RespHeaders, Body} when Code >= 200, Code < 300 ->
            Type = content_type(RespHeaders),
            case allowed_type(Type) of
                true -> {ok, Body, Type};
                false -> {error, unsupported_type}
            end;
        {ok, Code, _, _} when Code >= 300, Code < 400 ->
            {error, blocked_url};
        {ok, Code, _, _} ->
            {error, {http, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

content_type(Headers) ->
    case header_value("content-type", Headers) of
        undefined -> <<"application/octet-stream">>;
        CT -> pw_util:bin(string:trim(hd(string:split(CT, ";"))))
    end.

header_value(Name, Headers) ->
    Lower = string:lowercase(Name),
    case [V || {K, V} <- Headers, string:lowercase(K) =:= Lower] of
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
