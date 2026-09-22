-module(pw_cluster_wire).
-export([encode/6, decode/3, allowed/2]).

-define(MAX_BYTES, 131072).

encode(Origin, Boot, Seq, Time, Target, Event) ->
    {pw_cluster_v1, Origin, Boot, Seq, Time, Target, Event}.

decode({pw_cluster_v1, Origin, Boot, Seq, Time, Target, Event} = Envelope, Allowed, Now)
  when is_atom(Origin), is_binary(Boot), byte_size(Boot) =:= 16,
       is_integer(Seq), Seq > 0, is_integer(Time), Time >= Now - 15000, Time =< Now + 5000 ->
    case lists:member(Origin, Allowed) andalso allowed(Target, Event)
         andalso erlang:external_size(Envelope) =< ?MAX_BYTES andalso safe_term(Event, 0) of
        true -> {ok, {Origin, Boot, Seq}, Target, Event};
        false -> {error, invalid_event}
    end;
decode(_, _, _) -> {error, invalid_envelope}.

allowed(heartbeat, #{type := heartbeat}) -> true;
allowed({user, Uid}, #{type := Type}) when is_integer(Uid), Uid > 0 ->
    lists:member(Type, [friend_request, friend_accept, thread_reply, channel_message,
                       direct_message, mention, conversation_updated, server_updated, conversation_created,
                       conversation_closed, conversation_members_added, conversation_members_changed,
                       conversation_member_removed, message_request, message_request_accepted, member_joined,
                       category_created, category_updated, category_deleted, categories_reordered,
                       channel_created, channel_updated, channel_moved,
                       server_roles_updated, server_member_roles_updated, server_member_removed,
                       server_member_profile_updated, user_identity_updated,
                       call_incoming, call_ended, call_declined, call_accepted, call_cancelled,
                       call_missed, call_presence,
                       notification, account_restricted, account_restored,
                       account_disabled, account_deleted, sessions_revoked,
                       bot_command_available, bot_command_failed]);
allowed({topic, {system, global}}, #{type := Type}) ->
    lists:member(Type, [system_banners_changed, service_settings_changed, realtime_resync]);
allowed({topic, {Kind, Id}}, #{type := Type}) when is_integer(Id), Id > 0 ->
    lists:member(Kind, [channel, direct, thread, forum, server]) andalso
        lists:member(Type, [message_created, message_updated, message_deleted, thread_created,
                          thread_deleted, thread_reply, forum_deleted, server_updated,
                          channel_updated, conversation_updated, category_created, category_updated,
                          category_deleted, categories_reordered, channel_created, channel_moved, member_joined,
                          conversation_closed, conversation_members_added, conversation_members_changed,
                          user_identity_updated, thread_updated, thread_reply_updated, thread_reply_deleted,
                          message_reaction_changed, message_pin_changed]);
allowed({control, revoke_server_access}, #{uid := Uid, server_id := ServerId, channel_ids := ChannelIds}) ->
    is_integer(Uid) andalso Uid > 0 andalso is_integer(ServerId) andalso ServerId > 0 andalso
        valid_id_list(ChannelIds, 512);
allowed({control, revoke_conversation_access}, #{uid := Uid, conversation_id := ConversationId}) ->
    is_integer(Uid) andalso Uid > 0 andalso is_integer(ConversationId) andalso ConversationId > 0;
allowed(_, _) -> false.

safe_term(_, Depth) when Depth > 12 -> false;
safe_term(T, _) when is_integer(T); is_float(T); is_atom(T) -> true;
safe_term(T, _) when is_binary(T) -> byte_size(T) =< ?MAX_BYTES;
safe_term(T, D) when is_map(T), map_size(T) =< 128 ->
    lists:all(fun({K, V}) -> safe_term(K, D + 1) andalso safe_term(V, D + 1) end, maps:to_list(T));
safe_term(T, D) when is_list(T) ->
    safe_list(T, D, 0, 2048);
safe_term(_, _) -> false.

safe_list([], _D, _N, _Max) -> true;
safe_list([V | Rest], D, N, Max) when N < Max ->
    safe_term(V, D + 1) andalso safe_list(Rest, D, N + 1, Max);
safe_list(_, _, _, _) -> false.

valid_id_list(List, Max) -> valid_id_list(List, Max, 0).
valid_id_list([], _Max, _N) -> true;
valid_id_list([Id | Rest], Max, N) when is_integer(Id), Id > 0, N < Max ->
    valid_id_list(Rest, Max, N + 1);
valid_id_list(_, _, _) -> false.
