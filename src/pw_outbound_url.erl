-module(pw_outbound_url).
-export([allowed/1, resolve_allowed/1, resolve_app_allowed/1, public_ip/1]).

%% Resolve and validate an outbound URL in one operation. Callers that perform
%% the network request must connect to the returned address instead of resolving
%% the hostname a second time; doing otherwise re-opens a DNS-rebinding window
%% between policy validation and connect(2).
allowed(Url) ->
    case resolve_allowed(Url) of
        {ok, _} -> true;
        _ -> false
    end.

resolve_allowed(Url0) ->
    Url = pw_util:clean_text(Url0, 2048),
    try uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Parts ->
            Scheme = string:lowercase(pw_util:bin(Scheme0)),
            Host = string:lowercase(pw_util:bin(Host0)),
            case scheme_allowed(Scheme) of
                false -> {error, blocked_scheme};
                true -> resolve_parts(Scheme, Host, Parts)
            end;
        _ -> {error, invalid_url}
    catch _:_ -> {error, invalid_url} end.

%% Developer application interactions and hosted-AI connectors have a stricter
%% transport policy than legacy outbound webhooks. Remote destinations are
%% always HTTPS. Explicit loopback HTTP exists only for local development and
%% is limited to exact numeric/localhost loopback names so DNS cannot turn a
%% development exception into remote plaintext token delivery.
resolve_app_allowed(Url0) ->
    Url = pw_util:clean_text(Url0, 2048),
    try uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Parts ->
            Scheme = string:lowercase(pw_util:bin(Scheme0)),
            Host = string:lowercase(pw_util:bin(Host0)),
            case Scheme of
                <<"https">> -> resolve_parts(Scheme, Host, Parts);
                <<"http">> -> resolve_app_loopback(Host, Parts);
                _ -> {error, blocked_scheme}
            end;
        _ -> {error, invalid_url}
    catch _:_ -> {error, invalid_url} end.

resolve_app_loopback(Host, Parts) ->
    case pw_util:env_bool("PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP", false) of
        false -> {error, blocked_scheme};
        true ->
            case loopback_address(Host) of
                {ok, Address} -> target_for_address(<<"http">>, Host, Parts, Address);
                error -> {error, blocked_address}
            end
    end.

loopback_address(<<"localhost">>) -> {ok, {127,0,0,1}};
loopback_address(<<"127.0.0.1">>) -> {ok, {127,0,0,1}};
loopback_address(<<"::1">>) -> {ok, {0,0,0,0,0,0,0,1}};
loopback_address(_) -> error.

resolve_parts(_Scheme, <<>>, _Parts) -> {error, invalid_host};
resolve_parts(_Scheme, <<"localhost">>, _Parts) -> {error, blocked_host};
resolve_parts(Scheme, Host, Parts) ->
    case resolve_public(Host) of
        {ok, Address} -> target_for_address(Scheme, Host, Parts, Address);
        Error -> Error
    end.

target_for_address(Scheme, Host, Parts, Address) ->
    DefaultPort = case Scheme of <<"https">> -> 443; <<"http">> -> 80 end,
    Port = maps:get(port, Parts, DefaultPort),
    case is_integer(Port) andalso Port > 0 andalso Port =< 65535 of
        false -> {error, invalid_port};
        true ->
            RawPath = case maps:get(path, Parts, <<>>) of
                <<>> -> <<"/">>;
                P -> pw_util:bin(P)
            end,
            Path = case maps:get(query, Parts, undefined) of
                undefined -> RawPath;
                <<>> -> RawPath;
                Q -> <<RawPath/binary, "?", (pw_util:bin(Q))/binary>>
            end,
            {ok, #{scheme => Scheme, host => Host, port => Port,
                   path => Path, address => Address}}
    end.

scheme_allowed(<<"https">>) -> true;
scheme_allowed(<<"http">>) -> pw_util:env_bool("PLAINWIRE_WEBHOOK_ALLOW_HTTP", false);
scheme_allowed(_) -> false.

resolve_public(Host) ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, Ip} ->
            case public_ip(Ip) of true -> {ok, Ip}; false -> {error, blocked_address} end;
        {error, _} ->
            %% Resolve once and require every answer to be public. Connecting to
            %% one of these exact tuples later avoids DNS rebinding after policy
            %% validation. Prefer IPv4 only for compatibility; IPv6 remains a
            %% first-class fallback when no A records exist.
            Addrs4 = resolved(Host, inet),
            Addrs6 = resolved(Host, inet6),
            Addrs = Addrs4 ++ Addrs6,
            case Addrs of
                [] -> {error, unresolved_host};
                _ ->
                    case lists:all(fun public_ip/1, Addrs) of
                        false -> {error, blocked_address};
                        true -> {ok, pick_address(Addrs4, Addrs6)}
                    end
            end
    end.

pick_address([_ | _] = Addrs4, _Addrs6) -> lists:nth(rand:uniform(length(Addrs4)), Addrs4);
pick_address([], Addrs6) -> lists:nth(rand:uniform(length(Addrs6)), Addrs6).

resolved(Host, Family) ->
    case inet:getaddrs(binary_to_list(Host), Family) of
        {ok, Addrs} -> lists:usort(Addrs);
        _ -> []
    end.

public_ip({A, B, C, D}) ->
    not (
        A =:= 0 orelse A =:= 10 orelse A =:= 127 orelse
        (A =:= 100 andalso B >= 64 andalso B =< 127) orelse
        (A =:= 169 andalso B =:= 254) orelse
        (A =:= 172 andalso B >= 16 andalso B =< 31) orelse
        (A =:= 192 andalso B =:= 0 andalso C =:= 0) orelse
        (A =:= 192 andalso B =:= 0 andalso C =:= 2) orelse
        (A =:= 192 andalso B =:= 88 andalso C =:= 99) orelse
        (A =:= 192 andalso B =:= 168) orelse
        (A =:= 198 andalso (B =:= 18 orelse B =:= 19)) orelse
        (A =:= 198 andalso B =:= 51 andalso C =:= 100) orelse
        (A =:= 203 andalso B =:= 0 andalso C =:= 113) orelse
        A >= 224 orelse
        {A,B,C,D} =:= {255,255,255,255}
    );
public_ip({A, B, _C, _D, _E, _F, _G, _H}) ->
    %% Outbound webhooks/media should target ordinary globally-routable unicast
    %% addresses, not protocol/translation/documentation space. Start from the
    %% currently allocated IPv6 global-unicast block (2000::/3), then reject the
    %% IANA special-purpose ranges inside it that are not suitable destinations.
    %% This deliberately blocks some globally reachable protocol anycast ranges
    %% in 2001::/23: they are not useful webhook/media origins, and conservative
    %% egress policy is safer than trying to keep a permissive exception list.
    InGlobalUnicast = A >= 16#2000 andalso A =< 16#3fff,
    Special =
        (A =:= 16#2001 andalso B =< 16#01ff) orelse                  %% 2001::/23 IETF protocol space
        (A =:= 16#2001 andalso B =:= 16#0db8) orelse                %% 2001:db8::/32 documentation
        A =:= 16#2002 orelse                                        %% 2002::/16 6to4
        (A =:= 16#3fff andalso B =< 16#0fff),                       %% 3fff::/20 documentation
    InGlobalUnicast andalso not Special;
public_ip(_) -> false.
