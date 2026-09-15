-module(pw_cluster_local).
-export([deliver/2]).

deliver({user, Uid}, Event) -> gen_server:cast(pw_hub, {notify_user, Uid, Event});
deliver({topic, Key}, Event) -> gen_server:cast(pw_hub, {broadcast, Key, Event});
deliver({control, revoke_server_access}, #{uid := Uid, server_id := ServerId, channel_ids := ChannelIds}) ->
    gen_server:cast(pw_hub, {revoke_server_access, Uid, ServerId, ChannelIds});
deliver({control, revoke_conversation_access}, #{uid := Uid, conversation_id := ConversationId}) ->
    gen_server:cast(pw_hub, {revoke_conversation_access, Uid, ConversationId}).
