-module(pw_cluster_config).
-export([get/0, validate/1, private_ip/1, websocket_owner/0]).

get() -> application:get_env(plainwire_relay, cluster, #{backend => local}).
websocket_owner() ->
    case ?MODULE:get() of
        #{backend := partisan, name := Name, realtime_node := Name} -> true;
        #{backend := partisan} -> false;
        _ -> true
    end.

validate(#{backend := local}) -> ok;
validate(C = #{backend := partisan}) ->
    try
        Name = maps:get(name, C),
        Owner = maps:get(realtime_node, C),
        true = valid_name(Name),
        true = valid_name(Owner),
        true = private_ip(maps:get(listen_ip, C)),
        true = valid_port(maps:get(listen_port, C)),
        Peers = maps:get(peers, C),
        true = is_list(Peers) andalso length(Peers) > 0 andalso length(Peers) =< 15,
        true = lists:all(fun valid_peer/1, Peers),
        Names = [maps:get(name, P) || P <- Peers],
        true = length(lists:usort([Name | Names])) =:= length(Names) + 1,
        true = lists:member(Owner, [Name | Names]),
        true = lists:all(fun(Key) -> readable_file(maps:get(Key, C)) end,
                         [certfile, keyfile, cacertfile]),
        ok
    catch _:_ -> {error, invalid_cluster_config} end;
validate(_) -> {error, invalid_cluster_backend}.

valid_peer(#{name := Name, ip := IP, port := Port}) ->
    valid_name(Name) andalso private_ip(IP) andalso valid_port(Port);
valid_peer(_) -> false.
valid_name(N) when is_atom(N), N =/= nonode@nohost ->
    length(atom_to_list(N)) =< 128;
valid_name(_) -> false.
valid_port(P) -> is_integer(P) andalso P > 0 andalso P =< 65535.
readable_file(Path) when is_list(Path) ->
    filename:pathtype(Path) =:= absolute andalso
        case file:open(Path, [read, raw]) of
            {ok, F} -> file:close(F), true;
            _ -> false
        end;
readable_file(_) -> false.

%% Cluster listeners must bind to an explicit loopback/private address. TLS is
%% still mandatory: a private network is not an authentication mechanism.
private_ip({127, B, C, D}) -> octets([B, C, D]);
private_ip({10, B, C, D}) -> octets([B, C, D]);
private_ip({172, B, C, D}) when B >= 16, B =< 31 -> octets([C, D]);
private_ip({192, 168, C, D}) -> octets([C, D]);
private_ip({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
private_ip({A, B, C, D, E, F, G, H}) when A >= 16#fc00, A =< 16#fdff ->
    lists:all(fun(N) -> is_integer(N) andalso N >= 0 andalso N =< 65535 end,
              [B, C, D, E, F, G, H]);
private_ip(_) -> false.
octets(Ns) -> lists:all(fun(N) -> is_integer(N) andalso N >= 0 andalso N =< 255 end, Ns).
