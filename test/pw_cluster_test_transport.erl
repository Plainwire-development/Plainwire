%% Deterministic transport contract fixture; the real Partisan smoke test is separate.
-module(pw_cluster_test_transport).
-export([start/1, send/3, members/0]).
start(_) -> application:get_env(plainwire_relay, test_transport_start, ok).
send(Node, Channel, Envelope) ->
    case application:get_env(plainwire_relay, test_transport_sink) of
        {ok, Pid} -> Pid ! {transport_sent, Node, Channel, Envelope};
        _ -> ok
    end,
    application:get_env(plainwire_relay, test_transport_result, ok).
members() -> application:get_env(plainwire_relay, test_transport_members, []).
