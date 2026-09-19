-module(pw_cluster_local).
-export([deliver/2]).

%% User/topic fanout intentionally bypasses pw_hub. The hub remains the
%% authoritative control plane for presence, subscriptions, room membership and
%% call lifecycle, while the concurrent realtime registry handles the hot data
%% path. If the registry is restarting, fall back to the legacy hub path so a
%% transient index failure cannot turn into lost durable notifications.
deliver({user, Uid}, Event) ->
    case whereis(pw_realtime_registry) of
        Pid when is_pid(Pid) ->
            case pw_realtime_registry:send_user(Uid, Event) of
                unavailable -> gen_server:cast(pw_hub, {notify_user, Uid, Event});
                _ -> ok
            end;
        _ -> gen_server:cast(pw_hub, {notify_user, Uid, Event})
    end;
deliver({topic, Key}, Event) ->
    case whereis(pw_realtime_registry) of
        Pid when is_pid(Pid) ->
            case pw_realtime_registry:broadcast(Key, Event) of
                unavailable -> gen_server:cast(pw_hub, {broadcast, Key, Event});
                _ -> ok
            end;
        _ -> gen_server:cast(pw_hub, {broadcast, Key, Event})
    end;
deliver({control, revoke_server_access}, #{uid := Uid, server_id := ServerId, channel_ids := ChannelIds}) ->
    gen_server:cast(pw_hub, {revoke_server_access, Uid, ServerId, ChannelIds});
deliver({control, revoke_conversation_access}, #{uid := Uid, conversation_id := ConversationId}) ->
    gen_server:cast(pw_hub, {revoke_conversation_access, Uid, ConversationId}).
