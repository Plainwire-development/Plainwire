-module(pw_media).
-behaviour(gen_server).
-export([start_link/0, proxy_url/1, fetch/2, validate_url/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CACHE, pw_media_cache).
-define(MAX_BYTES, 524288).
-define(TTL_MS, 3600000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

proxy_url(Url) when is_binary(Url) ->
    <<"/api/media/", (pw_crypto:proxy_token(Url))/binary>>.

fetch(Uid, Token) ->
    gen_server:call(?SERVER, {fetch, Uid, Token}, 15000).

init([]) ->
    _ = ets:new(?CACHE, [named_table, public, set, {read_concurrency, true}]),
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
    case validate_url(Url) of
        ok ->
            Key = cache_key(Url),
            Now = pw_util:now_ms(),
            case ets:lookup(?CACHE, Key) of
                [{Key, Body, Type, Expires}] when Expires > Now ->
                    {ok, Body, Type};
                _ ->
                    case http_get(Url) of
                        {ok, Body, Type} ->
                            ets:insert(?CACHE, {Key, Body, Type, Now + ?TTL_MS}),
                            prune_cache(Now),
                            {ok, Body, Type};
                        Err ->
                            Err
                    end
            end;
        Err ->
            Err
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
        _ ->
            Url = pw_util:base64url_decode(Token),
            case byte_size(Url) > 0 of
                true -> Url;
                false -> erlang:error(invalid_token)
            end
    end.

cache_key(Url) -> pw_util:sha256_hex(Url).

validate_url(Url) ->
    case uri_string:parse(binary_to_list(Url)) of
        #{scheme := Scheme, host := Host} when Scheme =:= "http"; Scheme =:= "https" ->
            case blocked_host_or_addr(string:lowercase(Host)) of
                true -> {error, blocked_url};
                false -> ok
            end;
        _ ->
            {error, invalid_url}
    end.

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
blocked_addr({172,B,_,_}) when B >= 16, B =< 31 -> true;
blocked_addr({192,168,_,_}) -> true;
blocked_addr({_,_,_,_}) -> false;
blocked_addr({0,0,0,0,0,0,0,1}) -> true;
blocked_addr({S,_,_,_,_,_,_,_}) when S >= 16#fc00, S =< 16#fdff -> true;
blocked_addr({S,_,_,_,_,_,_,_}) when S >= 16#fe80, S =< 16#febf -> true;
blocked_addr({_,_,_,_,_,_,_,_}) -> false;
blocked_addr(_) -> true.

http_get(Url) ->
    Headers = [{"user-agent", "PlainwireRelay/1.1"}],
    case httpc:request(get, {binary_to_list(Url), Headers}, [{timeout, 8000}], [{body_format, binary}]) of
        {ok, {{_, Code, _}, RespHeaders, Body}} when Code >= 200, Code < 300 ->
            case content_length_ok(RespHeaders) andalso byte_size(Body) =< ?MAX_BYTES of
                true ->
                    Type = content_type(RespHeaders),
                    case allowed_type(Type) of
                        true -> {ok, Body, Type};
                        false -> {error, unsupported_type}
                    end;
                false ->
                    {error, too_large}
            end;
        {ok, {{_, Code, _}, _, _}} ->
            {error, {http, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

content_type(Headers) ->
    case header_value("content-type", Headers) of
        undefined -> <<"application/octet-stream">>;
        CT -> pw_util:bin(string:trim(hd(string:split(CT, ";"))))
    end.

content_length_ok(Headers) ->
    case header_value("content-length", Headers) of
        undefined -> true;
        Len -> case safe_list_to_integer(string:trim(Len)) of
            N when is_integer(N), N =< ?MAX_BYTES -> true;
            _ -> false
        end
    end.

header_value(Name, Headers) ->
    Lower = string:lowercase(Name),
    case [V || {K, V} <- Headers, string:lowercase(K) =:= Lower] of
        [V | _] -> V;
        [] -> undefined
    end.

safe_list_to_integer(V) ->
    try list_to_integer(V) catch _:_ -> undefined end.

allowed_type(<<"image/", _/binary>>) -> true;
allowed_type(<<"application/octet-stream">>) -> true;
allowed_type(_) -> false.

prune_cache(Now) ->
    case ets:info(?CACHE, size) of
        N when N > 500 ->
            Expired = [K || {K, _, _, Exp} <- ets:tab2list(?CACHE), Exp =< Now],
            [ets:delete(?CACHE, K) || K <- Expired],
            ok;
        _ ->
            ok
    end.
