-module(pw_db).
-behaviour(gen_server).
-export([
    start_link/0,
    health/0, message_id_claim_node/3, message_id_renew_node/3, message_id_release_node/2,
    register/3, login/2, session/1, session_fast/1, logout/1, sessions/2, logout_other_sessions/2, change_password/4, change_username/4, disable_account/2, delete_account/2, me/1, update_profile/3, update_theme/2,
    onboarding/1, start_onboarding/1, update_onboarding/2, complete_onboarding/1, dismiss_onboarding/1, replay_onboarding/1,
    sync/2, users/1, profile/2, profile_by_username/2,
    friend_request/2, friend_accept/2, friend_remove/2, friend_block/2, friend_unblock/2, friends/1,
    forums/1, create_forum/4, delete_forum/2, join_forum/2, leave_forum/2, threads/3, thread/2, create_thread/4, edit_thread/4, moderate_thread/4, delete_thread/2, reply_thread/3, edit_reply/4, delete_reply/3, vote_thread/3,
    servers/1, create_server/3, update_server/3, delete_server/3, server/2, update_channel_settings/3, server_member_profile/3, create_channel/4, create_channel/5,
    server_roles/2, create_server_role/4, update_server_role/4, delete_server_role/3, set_server_member_roles/4,
    kick_server_member/3, ban_server_member/4, unban_server_member/3, server_bans/2, update_server_member_profile/4, server_permissions/2, update_server_default_permissions/3,
    server_webhooks/2, create_server_webhook/5, update_server_webhook/5, delete_server_webhook/3, rotate_server_webhook/3, test_server_webhook/3,
    incoming_webhooks/2, create_incoming_webhook/4, rotate_incoming_webhook/3, delete_incoming_webhook/3, execute_incoming_webhook/4,
    server_webhook_deliveries/4, retry_server_webhook_delivery/4,
    webhook_claim_due/1, webhook_finish/2, webhook_prune/0,
    storage_outbox_claim/1, storage_outbox_finish/2, storage_outbox_prune/0, storage_status/0, storage_migration_page/2, storage_migration_checkpoint/0, storage_migration_set_checkpoint/2, storage_reconcile_page/1,
    storage_pg_message_get/1, storage_pg_message_recent/3, storage_pg_message_before/4, storage_pg_message_after/4, storage_pg_message_bulk/1, storage_pg_message_edit/3, storage_pg_message_delete/2,
    server_bots/2, create_server_bot/3, rotate_server_bot/3, delete_server_bot/3, authenticate_bot/1, bot_server/2, bot_members/4, bot_post_channel_message/4,
    developer_apps/1, developer_app/2, create_developer_app/2, update_developer_app/3, delete_developer_app/2,
    developer_app_installations/2, install_developer_app/3, install_public_developer_app/3, rotate_developer_app_installation/3, uninstall_developer_app/3, public_developer_app/1, public_developer_apps/2, server_apps/2,
    server_app_commands/3, set_server_command_permissions/5, uninstall_server_app/3,
    developer_app_commands/2, upsert_developer_app_command/6, delete_developer_app_command/3,
    update_developer_app_interactions/3, rotate_developer_app_interaction_secret/2, update_developer_app_ai/3,
    app_interaction_claim_due/1, app_interaction_finish/2, ai_command_claim_due/1, ai_command_finish/2,
    bot_commands/1, bot_register_command/4, bot_sync_commands/2, bot_delete_command/2, bot_claim_commands/2, bot_defer_command/4, bot_respond_command/4, bot_fail_command/4,
    commands_for_channel/2, invoke_bot_command/4,
    search_messages/4, search_index_reconcile/1, search_index_status/0,
    create_invite/4, create_invite/5, list_invites/2, revoke_invite/3, invite_options/2, invite_preview/1, join_invite/2,
    messages/5, message_context/2, channel_pins/2, set_message_pin/3,
    post_channel_message/4, delete_message/2, edit_message/3, forward_message/4, toggle_message_reaction/3, record_missed_call/2, record_completed_call/3,
    conversations/1, create_conversation/3, create_conversation_usernames/3, update_conversation/4,
    set_conversation_member_role/4, kick_conversation_member/3,
    add_conversation_members/3, add_conversation_members_usernames/3, conversation/2, post_direct_message/4,
    close_conversation/2, leave_conversation/2, accept_message_request/2, deny_message_request/2,
    mark_conversation_read/2, notifications/1, mark_notifications_seen/1, clear_notifications/1, mark_url_seen/2,
    member_of_channel/2, channel_identity/2, channel_message_identity/2, voice_access/2, stream_access/2, member_of_conversation/2, member_of_server/2, member_of_thread_forum/2, conversation_peer_ids/2,
    subscribable/2,
    begin_upload/6, finish_upload/3, abort_upload/2, get_upload/2, stale_uploads/2, delete_upload/1,
    upload_delete_claim/1, upload_delete_finish/2, queue_stale_upload_deletes/2,
    upload_ref_backfill/1,
    categories/2, create_category/3, update_category/4, reorder_categories/3, delete_category/3, move_channel/4,
    admin_operator_count/0, admin_bootstrap_owner/3, admin_recover_owner/3, admin_login/8, admin_session/1, admin_logout/1,
    admin_create_enrollment/6, admin_redeem_enrollment/9, admin_rotate_key/5,
    admin_operators/1, admin_set_operator_role/3, admin_remove_operator/2,
    admin_overview/0, admin_users/3, admin_user/1, admin_servers/3, admin_server/1,
    admin_user_moderation/2, admin_user_moderation_history/2, admin_apply_user_moderation/4,
    admin_audit/2, admin_record_audit/6,
    global_banners/0, invalidate_global_banners_cache/0, admin_banners/0, admin_create_banner/2, admin_update_banner/3, admin_delete_banner/3,
    instance_registration_mode/0, admin_set_registration_mode/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([profile_file_signature/2, extract_file_ids/1,
         normalize_banner_patch/2, safe_banner_link/1, normalize_registration_mode/1]).
-endif.

-record(st, {}).
-record(pool, {conns, size, counter}).
-define(SERVER, ?MODULE).
-define(POOL_KEY, pw_db_pool).
-define(POOL_CONNS, pw_db_connections).
-define(POOL_LOAD, pw_db_connection_load).
-define(MAX_BODY, 12000).
-define(MAX_MSG, 5000).
-define(SESSION_GC_MS, 3600000).

-define(SESSION_CACHE, pw_session_cache).
-define(BANNER_CACHE, pw_global_banner_cache).
-define(BANNER_CACHE_TTL_MS, 1000).
-define(MESSAGE_CACHE_TTL_MS, 20000).
-define(MAX_MESSAGE_CACHE_BYTES, 2097152).
-define(MAX_MESSAGE_CACHE_DECODED_BYTES, 8388608).
%% message.hard_delete may perform locator lookup + four bounded bucket deletes
%% + locator cleanup. Storage-outbox row leases must outlive that whole bounded
%% operation or another node can reclaim a live privacy job.
-define(MAX_STORAGE_OUTBOX_CQL_OPS, 6).

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

message_id_claim_node(NodeId, Owner, LeaseUntil) -> call({message_id_claim_node, NodeId, Owner, LeaseUntil}).
message_id_renew_node(NodeId, Owner, LeaseUntil) -> call({message_id_renew_node, NodeId, Owner, LeaseUntil}).
message_id_release_node(NodeId, Owner) -> call({message_id_release_node, NodeId, Owner}).

health() ->
    %% Health probes must use the same reservation + per-connection serialization
    %% path as every other query. Querying an epgsql connection directly here can
    %% otherwise interleave with a transaction that currently owns that lane.
    case call(health_probe) of
        {ok, database_ok} ->
            try
                #pool{conns = Conns, size = Size} = persistent_term:get(?POOL_KEY),
                Queues = [connection_load(I, pool_conn(I, Conns)) || I <- lists:seq(1, Size)],
                {ok, #{database => ok, pool_size => Size,
                       inflight => lists:sum([max(0, case ets:lookup(?POOL_LOAD, I) of [{I, N}] -> N; [] -> 0 end) || I <- lists:seq(1, Size)]),
                       max_connection_queue => lists:max(Queues),
                       queue_limit_per_connection => max(8, pw_util:env_int("PLAINWIRE_DB_MAX_QUEUE", 128))}}
            catch
                _:_ -> {error, database_unavailable}
            end;
        _ -> {error, database_unavailable}
    end.

session_fast(Token) ->
    case pw_cluster_config:get() of
        #{backend := partisan} -> {error, no_session};
        _ -> session_cached(Token)
    end.

session_cached(Token) ->
    case Token of
        undefined -> {error, no_session};
        <<>> -> {error, no_session};
        _ ->
            H = pw_util:sha256_hex(Token),
            Now = pw_util:now_ms(),
            try ets:lookup(?SESSION_CACHE, H) of
                [{H, Session, Expires}] when Expires > Now -> {ok, Session};
                _ -> {error, no_session}
            catch error:badarg -> {error, database_unavailable}
            end
    end.

call(Msg) ->
    try persistent_term:get(?POOL_KEY) of
        Pool = #pool{} -> call_with_pool(Msg, Pool)
    catch
        error:badarg -> {error, database_unavailable};
        error:{badmatch, _} -> {error, database_unavailable}
    end.

call_with_pool(Msg, #pool{conns = Conns, size = Size, counter = Counter}) ->
    %% Reserve capacity atomically before queuing work on a lane. Each lane is a
    %% dedicated lightweight process that owns exactly one epgsql connection, so
    %% whole routes/transactions are serialized without a global lock-manager hop.
    case reserve_connection(Conns, Size, Counter) of
        overloaded ->
            logger:warning("[plainwire:db] pool_overloaded operation=~p", [operation_name(Msg)]),
            {error, database_busy};
        {_Idx, Lane, QueueLen} ->
            Started = erlang:monotonic_time(millisecond),
            %% The lane, not the caller, releases the reservation after the DB
            %% operation actually finishes. If an HTTP/client caller times out,
            %% the query may still be executing and must continue counting
            %% against bounded admission until PostgreSQL returns.
            run_connection_lane(Msg, Lane, Started, QueueLen)
    end.

operation_name(Msg) when is_tuple(Msg), tuple_size(Msg) > 0 -> element(1, Msg);
operation_name(Msg) -> Msg.

run_connection_lane(Msg, Lane, Started, QueueLen) when is_pid(Lane) ->
    %% OTP process aliases make late replies disappear after timeout instead of
    %% accumulating unmatched {db_reply,...} messages in long-lived callers.
    ReplyTo = erlang:alias([reply]),
    Mon = erlang:monitor(process, Lane),
    Lane ! {db_call, ReplyTo, Msg},
    Timeout = min(120000, max(1000, pw_util:env_int_cached("PLAINWIRE_DB_CALL_TIMEOUT_MS", 60000))),
    receive
        {db_reply, ReplyTo, Reply} ->
            erlang:demonitor(Mon, [flush]),
            log_db_latency(Msg, Started, QueueLen),
            Reply;
        {'DOWN', Mon, process, Lane, Reason} ->
            _ = erlang:unalias(ReplyTo),
            error_logger:error_msg("DB lane exited ~p for ~p~n", [Reason, safe_log_msg(Msg)]),
            {error, database_unavailable}
    after Timeout ->
        _ = erlang:unalias(ReplyTo),
        erlang:demonitor(Mon, [flush]),
        %% A reply can win the race immediately before unalias/1. Flush that one
        %% message exactly once; later sends to the inactive alias are dropped.
        receive
            {db_reply, ReplyTo, Reply} ->
                log_db_latency(Msg, Started, QueueLen),
                Reply
        after 0 ->
            logger:warning("[plainwire:db] call_timeout operation=~p duration_ms=~p", [operation_name(Msg), Timeout]),
            {error, timeout}
        end
    end;
run_connection_lane(_, _, _, _) -> {error, database_unavailable}.

%% Power-of-two choices keeps normal selection O(1). Reservations are atomic;
%% if both sampled lanes race to full, do one bounded pool scan rather than
%% returning database_busy while another lane still has room.
reserve_connection(Conns, Size, Counter) ->
    A = atomics:add_get(Counter, 1, 1) rem Size + 1,
    B = case Size of 1 -> A; _ -> atomics:add_get(Counter, 1, 1) rem Size + 1 end,
    Candidates0 = case A =:= B of true -> [A]; false -> [A, B] end,
    Candidates = lists:sort(fun(I, J) ->
        connection_load(I, pool_conn(I, Conns)) =< connection_load(J, pool_conn(J, Conns))
    end, Candidates0),
    MaxQueue = max(8, pw_util:env_int_cached("PLAINWIRE_DB_MAX_QUEUE", 128)),
    case reserve_candidates(Candidates, Conns, MaxQueue) of
        overloaded -> reserve_least_loaded(Conns, Size, MaxQueue, Candidates0);
        Reserved -> Reserved
    end.

reserve_candidates([], _Conns, _MaxQueue) -> overloaded;
reserve_candidates([Idx | Rest], Conns, MaxQueue) ->
    Conn = pool_conn(Idx, Conns),
    case is_pid(Conn) of
        false -> reserve_candidates(Rest, Conns, MaxQueue);
        true ->
            NewLoad = ets:update_counter(?POOL_LOAD, Idx, {2, 1}, {Idx, 0}),
            case NewLoad =< MaxQueue of
                true -> {Idx, Conn, NewLoad - 1};
                false ->
                    ets:update_counter(?POOL_LOAD, Idx, {2, -1}, {Idx, 1}),
                    reserve_candidates(Rest, Conns, MaxQueue)
            end
    end.

reserve_least_loaded(Conns, Size, MaxQueue, Skip) ->
    Remaining = [I || I <- lists:seq(1, Size), not lists:member(I, Skip)],
    case Remaining of
        [] -> overloaded;
        _ ->
            Sorted = lists:sort(fun(I, J) ->
                connection_load(I, pool_conn(I, Conns)) =< connection_load(J, pool_conn(J, Conns))
            end, Remaining),
            reserve_candidates(Sorted, Conns, MaxQueue)
    end.

connection_load(Idx, _Lane) ->
    %% ?POOL_LOAD is an exact atomic admission counter for queued + executing
    %% work, so probing another process mailbox on every pool choice adds cost
    %% without improving the admission decision.
    case ets:lookup(?POOL_LOAD, Idx) of [{Idx, N}] -> max(0, N); [] -> 0 end.

log_db_latency(Msg, Started, QueueLen) ->
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    SlowMs = pw_util:env_int_cached("PLAINWIRE_DB_SLOW_MS", 250),
    case Elapsed >= SlowMs of
        true -> logger:warning("[plainwire:db] slow operation=~p duration_ms=~p initial_queue=~p", [operation_name(Msg), Elapsed, QueueLen]);
        false -> ok
    end.

pool_conn(Idx, FallbackConns) ->
    case ets:lookup(?POOL_CONNS, Idx) of
        [{Idx, Conn}] -> Conn;
        [] -> element(Idx, FallbackConns)
    end.

register(U, D, P) -> call({register, U, D, P}).
login(U, P) -> call({login, U, P}).
session(T) -> call({session, T}).
logout(T) -> call({logout, T}).
sessions(Uid, Token) -> call({sessions, Uid, Token}).
logout_other_sessions(Uid, Token) -> call({logout_other_sessions, Uid, Token}).
change_password(Uid, Token, Current, New) -> call({change_password, Uid, Token, Current, New}).
change_username(Uid, CurrentPassword, NewUsername, ExpectedUsername) -> call({change_username, Uid, CurrentPassword, NewUsername, ExpectedUsername}).
disable_account(Uid, Password) -> call({disable_account, Uid, Password}).
delete_account(Uid, Password) -> call({delete_account, Uid, Password}).
me(Uid) -> call({me, Uid}).
update_profile(Uid, Display, Patch) -> call({update_profile, Uid, Display, Patch}).
update_theme(Uid, Theme) -> call({update_theme, Uid, Theme}).
onboarding(Uid) -> call({onboarding, Uid}).
start_onboarding(Uid) -> call({start_onboarding, Uid}).
update_onboarding(Uid, Step) -> call({update_onboarding, Uid, Step}).
complete_onboarding(Uid) -> call({complete_onboarding, Uid}).
dismiss_onboarding(Uid) -> call({dismiss_onboarding, Uid}).
replay_onboarding(Uid) -> call({replay_onboarding, Uid}).
sync(Uid, Since) -> call({sync, Uid, Since}).
users(Q) -> call({users, Q}).
profile(Viewer, UserId) -> call({profile, Viewer, UserId}).
profile_by_username(Viewer, Username) -> call({profile_by_username, Viewer, Username}).
friend_request(Uid, Target) -> call({friend_request, Uid, Target}).
friend_accept(Uid, Target) -> call({friend_accept, Uid, Target}).
friend_remove(Uid, Target) -> call({friend_remove, Uid, Target}).
friend_block(Uid, Target) -> call({friend_block, Uid, Target}).
friend_unblock(Uid, Target) -> call({friend_unblock, Uid, Target}).
friends(Uid) -> call({friends, Uid}).
forums(Uid) -> call({forums, Uid}).
create_forum(Uid, Name, Slug, Description) -> call({create_forum, Uid, Name, Slug, Description}).
delete_forum(Uid, ForumId) -> call({delete_forum, Uid, ForumId}).
join_forum(Uid, ForumId) -> call({join_forum, Uid, ForumId}).
leave_forum(Uid, ForumId) -> call({leave_forum, Uid, ForumId}).
threads(Uid, ForumId, Search) -> call({threads, Uid, ForumId, Search}).
thread(Uid, ThreadId) -> call({thread, Uid, ThreadId}).
create_thread(Uid, ForumId, Title, Body) -> call({create_thread, Uid, ForumId, Title, Body}).
delete_thread(Uid, ThreadId) -> call({delete_thread, Uid, ThreadId}).
reply_thread(Uid, ThreadId, Body) -> call({reply_thread, Uid, ThreadId, Body}).
vote_thread(Uid, ThreadId, Value) -> call({vote_thread, Uid, ThreadId, Value}).
edit_thread(Uid, ThreadId, Title, Body) -> call({edit_thread, Uid, ThreadId, Title, Body}).
moderate_thread(Uid, ThreadId, Action, Value) -> call({moderate_thread, Uid, ThreadId, Action, Value}).
edit_reply(Uid, ThreadId, ReplyId, Body) -> call({edit_reply, Uid, ThreadId, ReplyId, Body}).
delete_reply(Uid, ThreadId, ReplyId) -> call({delete_reply, Uid, ThreadId, ReplyId}).
servers(Uid) -> call({servers, Uid}).
create_server(Uid, Name, Desc) -> call({create_server, Uid, Name, Desc}).
update_server(Uid, Sid, Patch) -> call({update_server, Uid, Sid, Patch}).
delete_server(Uid, Sid, ConfirmName) -> call({delete_server, Uid, Sid, ConfirmName}).
server(Uid, ServerId) -> call({server, Uid, ServerId}).
update_channel_settings(Uid, ChannelId, Patch) -> call({update_channel_settings, Uid, ChannelId, Patch}).
server_member_profile(Uid, ServerId, TargetUid) -> call({server_member_profile, Uid, ServerId, TargetUid}).
create_channel(Uid, ServerId, Name, Kind) -> create_channel(Uid, ServerId, Name, Kind, undefined).
create_channel(Uid, ServerId, Name, Kind, CategoryId) -> call({create_channel, Uid, ServerId, Name, Kind, CategoryId}).
server_roles(Uid, ServerId) -> call({server_roles, Uid, ServerId}).
create_server_role(Uid, ServerId, Name, Patch) -> call({create_server_role, Uid, ServerId, Name, Patch}).
update_server_role(Uid, ServerId, RoleId, Patch) -> call({update_server_role, Uid, ServerId, RoleId, Patch}).
delete_server_role(Uid, ServerId, RoleId) -> call({delete_server_role, Uid, ServerId, RoleId}).
set_server_member_roles(Uid, ServerId, TargetUid, RoleIds) -> call({set_server_member_roles, Uid, ServerId, TargetUid, RoleIds}).
kick_server_member(Uid, ServerId, TargetUid) -> call({kick_server_member, Uid, ServerId, TargetUid}).
ban_server_member(Uid, ServerId, TargetUid, Reason) -> call({ban_server_member, Uid, ServerId, TargetUid, Reason}).
unban_server_member(Uid, ServerId, TargetUid) -> call({unban_server_member, Uid, ServerId, TargetUid}).
server_bans(Uid, ServerId) -> call({server_bans, Uid, ServerId}).
update_server_member_profile(Uid, ServerId, TargetUid, Patch) -> call({update_server_member_profile, Uid, ServerId, TargetUid, Patch}).
server_permissions(Uid, ServerId) -> call({server_permissions, Uid, ServerId}).
update_server_default_permissions(Uid, ServerId, Permissions) -> call({update_server_default_permissions, Uid, ServerId, Permissions}).
server_webhooks(Uid, ServerId) -> call({server_webhooks, Uid, ServerId}).
create_server_webhook(Uid, ServerId, Name, Url, Events) -> call({create_server_webhook, Uid, ServerId, Name, Url, Events}).
update_server_webhook(Uid, ServerId, WebhookId, Patch, ExpectedUpdatedAt) -> call({update_server_webhook, Uid, ServerId, WebhookId, Patch, ExpectedUpdatedAt}).
delete_server_webhook(Uid, ServerId, WebhookId) -> call({delete_server_webhook, Uid, ServerId, WebhookId}).
rotate_server_webhook(Uid, ServerId, WebhookId) -> call({rotate_server_webhook, Uid, ServerId, WebhookId}).
test_server_webhook(Uid, ServerId, WebhookId) -> call({test_server_webhook, Uid, ServerId, WebhookId}).
incoming_webhooks(Uid, ServerId) -> call({incoming_webhooks, Uid, ServerId}).
create_incoming_webhook(Uid, ServerId, ChannelId, Name) -> call({create_incoming_webhook, Uid, ServerId, ChannelId, Name}).
rotate_incoming_webhook(Uid, ServerId, WebhookId) -> call({rotate_incoming_webhook, Uid, ServerId, WebhookId}).
delete_incoming_webhook(Uid, ServerId, WebhookId) -> call({delete_incoming_webhook, Uid, ServerId, WebhookId}).
execute_incoming_webhook(WebhookId, Token, Body, ReplyTo) -> call({execute_incoming_webhook, WebhookId, Token, Body, ReplyTo}).
server_webhook_deliveries(Uid, ServerId, WebhookId, Limit) -> call({server_webhook_deliveries, Uid, ServerId, WebhookId, Limit}).
retry_server_webhook_delivery(Uid, ServerId, WebhookId, DeliveryId) -> call({retry_server_webhook_delivery, Uid, ServerId, WebhookId, DeliveryId}).
webhook_claim_due(Limit) -> call({webhook_claim_due, Limit}).
webhook_finish(Id, Result) -> call({webhook_finish, Id, Result}).
webhook_prune() -> call(webhook_prune).
storage_outbox_claim(Limit) -> call({storage_outbox_claim, Limit}).
storage_outbox_finish(Id, Result) -> call({storage_outbox_finish, Id, Result}).
storage_outbox_prune() -> call(storage_outbox_prune).
storage_status() -> call(storage_status).
storage_migration_page(AfterId, Limit) -> call({storage_migration_page, AfterId, Limit}).
storage_migration_checkpoint() -> call(storage_migration_checkpoint).
storage_migration_set_checkpoint(LastId, RowsDone) -> call({storage_migration_set_checkpoint, LastId, RowsDone}).
storage_pg_message_get(Id) -> call({storage_pg_message_get, Id}).
storage_pg_message_recent(Scope, ScopeId, Limit) -> call({storage_pg_message_recent, Scope, ScopeId, Limit}).
storage_pg_message_before(Scope, ScopeId, Before, Limit) -> call({storage_pg_message_before, Scope, ScopeId, Before, Limit}).
storage_pg_message_after(Scope, ScopeId, After, Limit) -> call({storage_pg_message_after, Scope, ScopeId, After, Limit}).
storage_pg_message_bulk(Ids) -> call({storage_pg_message_bulk, Ids}).
storage_pg_message_edit(Id, Body, EditedAt) -> call({storage_pg_message_edit, Id, Body, EditedAt}).
storage_pg_message_delete(Id, ActorId) -> call({storage_pg_message_delete, Id, ActorId}).
storage_reconcile_page(Limit) -> call({storage_reconcile_page, Limit}).
server_bots(Uid, ServerId) -> call({server_bots, Uid, ServerId}).
create_server_bot(Uid, ServerId, Name) -> call({create_server_bot, Uid, ServerId, Name}).
rotate_server_bot(Uid, ServerId, BotId) -> call({rotate_server_bot, Uid, ServerId, BotId}).
delete_server_bot(Uid, ServerId, BotId) -> call({delete_server_bot, Uid, ServerId, BotId}).
authenticate_bot(Token) -> call({authenticate_bot, Token}).
bot_server(BotUid, ServerId) -> call({bot_server, BotUid, ServerId}).
bot_members(BotUid, ServerId, After, Limit) -> call({bot_members, BotUid, ServerId, After, Limit}).
bot_post_channel_message(BotUid, ChannelId, Body, ReplyTo) -> call({post_channel_message, BotUid, ChannelId, Body, ReplyTo}).
developer_apps(Uid) -> call({developer_apps, Uid}).
developer_app(Uid, AppId) -> call({developer_app, Uid, AppId}).
create_developer_app(Uid, Name) -> call({create_developer_app, Uid, Name}).
update_developer_app(Uid, AppId, Patch) -> call({update_developer_app, Uid, AppId, Patch}).
delete_developer_app(Uid, AppId) -> call({delete_developer_app, Uid, AppId}).
developer_app_installations(Uid, AppId) -> call({developer_app_installations, Uid, AppId}).
install_developer_app(Uid, AppId, ServerId) -> call({install_developer_app, Uid, AppId, ServerId}).
install_public_developer_app(Uid, PublicId, ServerId) -> call({install_public_developer_app, Uid, PublicId, ServerId}).
server_apps(Uid, ServerId) -> call({server_apps, Uid, ServerId}).
rotate_developer_app_installation(Uid, AppId, InstallationId) -> call({rotate_developer_app_installation, Uid, AppId, InstallationId}).
uninstall_developer_app(Uid, AppId, InstallationId) -> call({uninstall_developer_app, Uid, AppId, InstallationId}).
public_developer_app(PublicId) -> call({public_developer_app, PublicId}).
public_developer_apps(Query, Limit) -> call({public_developer_apps, Query, Limit}).
server_app_commands(Uid, ServerId, InstallationId) -> call({server_app_commands, Uid, ServerId, InstallationId}).
set_server_command_permissions(Uid, ServerId, InstallationId, CommandId, Rules) -> call({set_server_command_permissions, Uid, ServerId, InstallationId, CommandId, Rules}).
uninstall_server_app(Uid, ServerId, InstallationId) -> call({uninstall_server_app, Uid, ServerId, InstallationId}).
developer_app_commands(Uid, AppId) -> call({developer_app_commands, Uid, AppId}).
upsert_developer_app_command(Uid, AppId, Name, Description, Options, Handler) -> call({upsert_developer_app_command, Uid, AppId, Name, Description, Options, Handler}).
delete_developer_app_command(Uid, AppId, CommandId) -> call({delete_developer_app_command, Uid, AppId, CommandId}).
update_developer_app_interactions(Uid, AppId, Patch) -> call({update_developer_app_interactions, Uid, AppId, Patch}).
rotate_developer_app_interaction_secret(Uid, AppId) -> call({rotate_developer_app_interaction_secret, Uid, AppId}).
update_developer_app_ai(Uid, AppId, Patch) -> call({update_developer_app_ai, Uid, AppId, Patch}).
app_interaction_claim_due(Limit) -> call({app_interaction_claim_due, Limit}).
app_interaction_finish(Id, Result) -> call({app_interaction_finish, Id, Result}).
ai_command_claim_due(Limit) -> call({ai_command_claim_due, Limit}).
ai_command_finish(Id, Result) -> call({ai_command_finish, Id, Result}).
bot_commands(BotId) -> call({bot_commands, BotId}).
bot_register_command(BotId, Name, Description, Options) -> call({bot_register_command, BotId, Name, Description, Options}).
bot_sync_commands(BotId, Commands) -> call({bot_sync_commands, BotId, Commands}).
bot_delete_command(BotId, CommandId) -> call({bot_delete_command, BotId, CommandId}).
bot_claim_commands(BotId, Limit) -> call({bot_claim_commands, BotId, Limit}).
bot_defer_command(BotId, InvocationId, ClaimToken, LeaseMs) -> call({bot_defer_command, BotId, InvocationId, ClaimToken, LeaseMs}).
bot_respond_command(BotId, InvocationId, ClaimToken, Body) -> call({bot_respond_command, BotId, InvocationId, ClaimToken, Body}).
bot_fail_command(BotId, InvocationId, ClaimToken, Reason) -> call({bot_fail_command, BotId, InvocationId, ClaimToken, Reason}).
commands_for_channel(Uid, ChannelId) -> call({commands_for_channel, Uid, ChannelId}).
invoke_bot_command(Uid, ChannelId, Name, Args) -> call({invoke_bot_command, Uid, ChannelId, Name, Args}).
search_messages(Uid, Query, Before, Limit) -> call({search_messages, Uid, Query, Before, Limit}).
search_index_reconcile(Limit) -> call({search_index_reconcile, Limit}).
search_index_status() -> call(search_index_status).
message_context(Uid, MessageId) -> call({message_context, Uid, MessageId}).
channel_pins(Uid, ChannelId) -> call({channel_pins, Uid, ChannelId}).
set_message_pin(Uid, MessageId, Pinned) -> call({set_message_pin, Uid, MessageId, Pinned}).
categories(Uid, ServerId) -> call({categories, Uid, ServerId}).
create_category(Uid, ServerId, Name) -> call({create_category, Uid, ServerId, Name}).
update_category(Uid, ServerId, CatId, Patch) -> call({update_category, Uid, ServerId, CatId, Patch}).
reorder_categories(Uid, ServerId, Order) -> call({reorder_categories, Uid, ServerId, Order}).
delete_category(Uid, ServerId, CatId) -> call({delete_category, Uid, ServerId, CatId}).
move_channel(Uid, ChannelId, CatId, Position) -> call({move_channel, Uid, ChannelId, CatId, Position}).
create_invite(Uid, ServerId, ChannelId, MaxUses) -> create_invite(Uid, ServerId, ChannelId, MaxUses, 86400).
create_invite(Uid, ServerId, ChannelId, MaxUses, ExpiresIn) -> call({create_invite, Uid, ServerId, ChannelId, MaxUses, ExpiresIn}).
list_invites(Uid, Sid) -> call({list_invites, Uid, Sid}).
revoke_invite(Uid, Sid, Code) -> call({revoke_invite, Uid, Sid, Code}).
invite_preview(Code) -> call({invite_preview, Code}).
join_invite(Uid, Code) -> call({join_invite, Uid, Code}).
messages(Uid, Scope, ScopeId, Before, After) -> call({messages, Uid, Scope, ScopeId, Before, After}).
post_channel_message(Uid, ChannelId, Body, ReplyTo) -> call({post_channel_message, Uid, ChannelId, Body, ReplyTo}).
delete_message(Uid, Mid) -> call({delete_message, Uid, Mid}).
edit_message(Uid, Mid, Body) -> call({edit_message, Uid, Mid, Body}).
forward_message(Uid, Mid, TargetScope, TargetId) -> call({forward_message, Uid, Mid, TargetScope, TargetId}).
toggle_message_reaction(Uid, Mid, Emoji) -> call({toggle_message_reaction, Uid, Mid, Emoji}).
conversations(Uid) -> call({conversations, Uid}).
create_conversation(Uid, Name, UserIds) -> call({create_conversation, Uid, Name, UserIds}).
create_conversation_usernames(Uid, Name, Usernames) -> call({create_conversation_usernames, Uid, Name, Usernames}).
update_conversation(Uid, Cid, Name, Patch) -> call({update_conversation, Uid, Cid, Name, Patch}).
set_conversation_member_role(Uid, Cid, TargetUid, Role) -> call({set_conversation_member_role, Uid, Cid, TargetUid, Role}).
kick_conversation_member(Uid, Cid, TargetUid) -> call({kick_conversation_member, Uid, Cid, TargetUid}).
add_conversation_members(Uid, Cid, UserIds) -> call({add_conversation_members, Uid, Cid, UserIds}).
add_conversation_members_usernames(Uid, Cid, Usernames) -> call({add_conversation_members_usernames, Uid, Cid, Usernames}).
conversation(Uid, Cid) -> call({conversation, Uid, Cid}).
close_conversation(Uid, Cid) -> call({close_conversation, Uid, Cid}).
leave_conversation(Uid, Cid) -> call({leave_conversation, Uid, Cid}).
accept_message_request(Uid, Cid) -> call({accept_message_request, Uid, Cid}).
deny_message_request(Uid, Cid) -> call({deny_message_request, Uid, Cid}).
mark_conversation_read(Uid, Cid) -> call({mark_conversation_read, Uid, Cid}).
post_direct_message(Uid, Cid, Body, ReplyTo) -> call({post_direct_message, Uid, Cid, Body, ReplyTo}).
record_missed_call(Uid, Cid) -> call({record_missed_call, Uid, Cid}).
record_completed_call(Uid, Cid, Seconds) when is_integer(Seconds), Seconds >= 0 ->
    Duration = iolist_to_binary(io_lib:format("~B:~2..0B", [Seconds div 60, Seconds rem 60])),
    call({record_call_event, Uid, Cid, <<"call_ended">>, <<"Call ended · "/utf8, Duration/binary>>}).
notifications(Uid) -> call({notifications, Uid}).
mark_notifications_seen(Uid) -> call({mark_notifications_seen, Uid}).
clear_notifications(Uid) -> call({clear_notifications, Uid}).
mark_url_seen(Uid, Url) -> call({mark_url_seen, Uid, Url}).
member_of_channel(Uid, ChannelId) -> call({member_of_channel, Uid, ChannelId}).
channel_identity(Uid, ChannelId) -> call({channel_identity, Uid, ChannelId}).
channel_message_identity(Uid, ChannelId) -> call({channel_message_identity, Uid, ChannelId}).
voice_access(Uid, ChannelId) -> call({voice_access, Uid, ChannelId}).
stream_access(Uid, ChannelId) -> call({stream_access, Uid, ChannelId}).
member_of_conversation(Uid, Cid) -> call({member_of_conversation, Uid, Cid}).
member_of_server(Uid, Sid) -> call({member_of_server, Uid, Sid}).
member_of_thread_forum(Uid, ThreadId) -> call({member_of_thread_forum, Uid, ThreadId}).
conversation_peer_ids(Uid, Cid) -> call({conversation_peer_ids, Uid, Cid}).
subscribable(Kind, Id) -> call({subscribable, Kind, Id}).
begin_upload(Uid, Id, Name, Type, Size, Path) -> call({begin_upload, Uid, Id, Name, Type, Size, Path}).
finish_upload(Uid, Id, Hash) -> call({finish_upload, Uid, Id, Hash}).
abort_upload(Uid, Id) -> call({abort_upload, Uid, Id}).
get_upload(Uid, Id) -> call({get_upload, Uid, Id}).
stale_uploads(PendingBefore, ReadyBefore) -> call({stale_uploads, PendingBefore, ReadyBefore}).
delete_upload(Id) -> call({delete_upload, Id}).
upload_delete_claim(Limit) -> call({upload_delete_claim, Limit}).
upload_delete_finish(Path, Result) -> call({upload_delete_finish, Path, Result}).
queue_stale_upload_deletes(PendingBefore, ReadyBefore) -> call({queue_stale_upload_deletes, PendingBefore, ReadyBefore}).
upload_ref_backfill(Batch) -> call({upload_ref_backfill, Batch}).
admin_operator_count() -> call(admin_operator_count).
admin_bootstrap_owner(Username, Password, VerificationHash) -> call({admin_bootstrap_owner, Username, Password, VerificationHash}).
admin_recover_owner(Username, Password, VerificationHash) -> call({admin_recover_owner, Username, Password, VerificationHash}).
admin_login(Username, Password, VerificationHash, SessionHash, Csrf, ExpiresAt, IpHash, UaHash) ->
    call({admin_login, Username, Password, VerificationHash, SessionHash, Csrf, ExpiresAt, IpHash, UaHash}).
admin_session(SessionHash) -> call({admin_session, SessionHash}).
admin_logout(SessionHash) -> call({admin_logout, SessionHash}).
admin_create_enrollment(ActorUid, TargetUsername, Role, TokenHash, ExpiresAt, Note) ->
    call({admin_create_enrollment, ActorUid, TargetUsername, Role, TokenHash, ExpiresAt, Note}).
admin_redeem_enrollment(Username, Password, TokenHash, VerificationHash, SessionHash, Csrf, ExpiresAt, IpHash, UaHash) ->
    call({admin_redeem_enrollment, Username, Password, TokenHash, VerificationHash, SessionHash, Csrf, ExpiresAt, IpHash, UaHash}).
admin_rotate_key(Uid, Password, CurrentHash, NewHash, ActorIpHash) ->
    call({admin_rotate_key, Uid, Password, CurrentHash, NewHash, ActorIpHash}).
admin_operators(ActorUid) -> call({admin_operators, ActorUid}).
admin_set_operator_role(ActorUid, TargetUid, Role) -> call({admin_set_operator_role, ActorUid, TargetUid, Role}).
admin_remove_operator(ActorUid, TargetUid) -> call({admin_remove_operator, ActorUid, TargetUid}).
admin_overview() -> call(admin_overview).
admin_users(Query, Limit, Offset) -> call({admin_users, Query, Limit, Offset}).
admin_user(Uid) -> call({admin_user, Uid}).
admin_user_moderation(ActorUid, TargetUid) -> call({admin_user_moderation, ActorUid, TargetUid}).
admin_user_moderation_history(ActorUid, TargetUid) -> call({admin_user_moderation_history, ActorUid, TargetUid}).
admin_apply_user_moderation(ActorUid, TargetUid, Action, Patch) -> call({admin_apply_user_moderation, ActorUid, TargetUid, Action, Patch}).
admin_servers(Query, Limit, Offset) -> call({admin_servers, Query, Limit, Offset}).
admin_server(Sid) -> call({admin_server, Sid}).
admin_audit(Limit, BeforeId) -> call({admin_audit, Limit, BeforeId}).
admin_record_audit(ActorUid, Action, TargetType, TargetId, Detail, IpHash) ->
    call({admin_record_audit, ActorUid, Action, TargetType, TargetId, Detail, IpHash}).
global_banners() -> global_banners_cached().
invalidate_global_banners_cache() ->
    try ets:delete(?BANNER_CACHE, active), ok
    catch error:badarg -> ok end.

global_banners_cached() ->
    case cached_global_banners() of
        {ok, Banners} -> {ok, Banners};
        miss ->
            %% A banner mutation wakes many clients at once. Serialize only the
            %% short cache refill on this node so that realtime invalidation does
            %% not turn into one identical PostgreSQL query per connected tab.
            LockId = {{?MODULE, global_banners_cache}, self()},
            try global:trans(LockId, fun() ->
                case cached_global_banners() of
                    {ok, Banners1} -> {ok, Banners1};
                    miss -> cache_global_banners(call(global_banners))
                end
            end, [node()], infinity) of
                aborted -> call(global_banners);
                Reply -> Reply
            catch
                _:_ -> call(global_banners)
            end
    end.

cached_global_banners() ->
    Now = erlang:monotonic_time(millisecond),
    try ets:lookup(?BANNER_CACHE, active) of
        [{active, ExpiresAt, Banners}] when ExpiresAt > Now -> {ok, Banners};
        _ -> miss
    catch error:badarg -> miss end.

cache_global_banners({ok, Banners} = Result) ->
    ExpiresAt = erlang:monotonic_time(millisecond) + ?BANNER_CACHE_TTL_MS,
    try ets:insert(?BANNER_CACHE, {active, ExpiresAt, Banners})
    catch error:badarg -> ok end,
    Result;
cache_global_banners(Error) -> Error.
admin_banners() -> call(admin_banners).
admin_create_banner(ActorUid, Patch) -> call({admin_create_banner, ActorUid, Patch}).
admin_update_banner(ActorUid, BannerId, Patch) -> call({admin_update_banner, ActorUid, BannerId, Patch}).
admin_delete_banner(ActorUid, BannerId, ExpectedUpdatedAt) -> call({admin_delete_banner, ActorUid, BannerId, ExpectedUpdatedAt}).
instance_registration_mode() -> call(instance_registration_mode).
admin_set_registration_mode(ActorUid, Mode) -> call({admin_set_registration_mode, ActorUid, Mode}).

init([]) ->
    %% Database lanes are linked so shutdown remains simple, but isolate an
    %% unexpected lane crash from the pool owner and replace only that lane.
    process_flag(trap_exit, true),
    application:ensure_all_started(inets),
    _ = ets:new(?SESSION_CACHE, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    _ = ets:new(?BANNER_CACHE, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}]),
    _ = ets:new(?POOL_CONNS, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}]),
    _ = ets:new(?POOL_LOAD, [named_table, public, set, {read_concurrency, true}, {write_concurrency, auto}, {decentralized_counters, true}]),
    {ok, MigConn} = connect_with_retry(10, 500),
    ok = migrate(MigConn),
    try epgsql:close(MigConn) catch _:_ -> ok end,
    %% Keep the zero-config pool proportional to the host without assuming an
    %% enormous PostgreSQL max_connections setting. Explicit configuration wins.
    Schedulers = erlang:system_info(schedulers_online),
    DefaultPool = min(32, max(8, Schedulers * 2)),
    PoolSize = min(128, max(1, pw_util:env_int("PLAINWIRE_DB_POOL_SIZE", DefaultPool))),
    Lanes = list_to_tuple([
        begin
            {ok, C} = connect_with_retry(5, 500),
            spawn_link(fun() -> db_lane_loop(I, C) end)
        end || I <- lists:seq(1, PoolSize)
    ]),
    Counter = atomics:new(1, [{signed, false}]),
    [begin ets:insert(?POOL_CONNS, {I, element(I, Lanes)}), ets:insert(?POOL_LOAD, {I, 0}) end || I <- lists:seq(1, PoolSize)],
    persistent_term:put(?POOL_KEY, #pool{conns = Lanes, size = PoolSize, counter = Counter}),
    erlang:send_after(?SESSION_GC_MS, self(), session_gc),
    {ok, #st{}}.

handle_call(_, _From, St) -> {reply, {error, unknown}, St}.

handle_cast(_, St) -> {noreply, St}.
handle_info(session_gc, St) ->
    Now = pw_util:now_ms(),
    _ = ets:select_delete(?SESSION_CACHE,
        [{{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}]),
    %% small batches; cleanup doesn't deserve a giant lock.
    _ = call({prune_sessions, Now}),
    erlang:send_after(?SESSION_GC_MS, self(), session_gc),
    {noreply, St};
handle_info({'EXIT', Lane, Reason}, St) when is_pid(Lane) ->
    case lane_index(Lane) of
        undefined -> {noreply, St};
        Idx ->
            %% Queued callers monitor the failed lane and return immediately.
            %% Reset its exact admission count and publish an unavailable sentinel
            %% before reconnecting so new calls choose healthy lanes instead.
            ets:insert(?POOL_CONNS, {Idx, unavailable}),
            ets:insert(?POOL_LOAD, {Idx, 0}),
            logger:warning("[plainwire:db] lane_crashed lane=~p reason=~p", [Idx, Reason]),
            self() ! {restart_lane, Idx},
            {noreply, St}
    end;
handle_info({restart_lane, Idx}, St) when is_integer(Idx), Idx > 0 ->
    case ets:lookup(?POOL_CONNS, Idx) of
        [{Idx, unavailable}] ->
            case connect_with_retry(3, 250) of
                {ok, Conn} ->
                    NewLane = spawn_link(fun() -> db_lane_loop(Idx, Conn) end),
                    ets:insert(?POOL_CONNS, {Idx, NewLane}),
                    logger:notice("[plainwire:db] lane_recovered lane=~p", [Idx]),
                    {noreply, St};
                {error, Reason} ->
                    logger:warning("[plainwire:db] lane_reconnect_failed lane=~p reason=~p", [Idx, Reason]),
                    erlang:send_after(2000, self(), {restart_lane, Idx}),
                    {noreply, St}
            end;
        _ -> {noreply, St}
    end;
handle_info(_, St) -> {noreply, St}.
terminate(_, _) ->
    try
        #pool{conns = Lanes, size = Size} = persistent_term:get(?POOL_KEY),
        
[begin Lane = pool_conn(I, Lanes), try Lane ! stop catch _:_ -> ok end end || I <- lists:seq(1, Size)],
        persistent_term:erase(?POOL_KEY)
    catch _:_ -> ok end,
    ok.
code_change(_, St, _) -> {ok, St}.

lane_index(Lane) ->
    case [Idx || {Idx, Pid} <- ets:tab2list(?POOL_CONNS), Pid =:= Lane] of
        [Idx | _] -> Idx;
        [] -> undefined
    end.

db_lane_loop(Idx, Conn) ->
    process_flag(message_queue_data, off_heap),
    receive
        {db_call, ReplyTo, Msg} when is_reference(ReplyTo) ->
            %% A reservation represents queued + executing work. Release it only
            %% after the lane has actually completed, even when the original
            %% caller has timed out and its reply alias has been deactivated.
            {Reply, Conn1} = route_with_reconnect(Msg, Conn),
            ReplyTo ! {db_reply, ReplyTo, Reply},
            ets:update_counter(?POOL_LOAD, Idx, {2, -1, 0, 0}),
            db_lane_loop(Idx, Conn1);
        stop ->
            try epgsql:close(Conn) catch _:_ -> ok end,
            ok;
        _ -> db_lane_loop(Idx, Conn)
    end.

route_with_reconnect(Msg, Conn) ->
    try route(Msg, Conn) of
        Reply -> {Reply, Conn}
    catch
        throw:{plainwire_error, Reason} ->
            {{error, Reason}, Conn};
        C:R:S ->
            error_logger:error_msg("DB route failed ~p:~p ~p for ~p~n", [C, R, S, safe_log_msg(Msg)]),
            case db_error(R) of
                true ->
                    case reconnect(Conn) of
                        {ok, Conn1} -> maybe_retry_read(Msg, Conn1, R);
                        {error, Reason} ->
                            error_logger:error_msg("DB reconnect failed: ~p~n", [Reason]),
                            {{error, database_unavailable}, Conn}
                    end;
                false ->
                    {{error, internal_error}, Conn}
            end
    end.

maybe_retry_read(Msg, Conn, FirstReason) ->
    case read_msg(Msg) of
        true ->
            try route(Msg, Conn) of
                Reply -> {Reply, Conn}
            catch
                C:R:S ->
                    error_logger:error_msg("DB retry failed after ~p: ~p:~p ~p for ~p~n", [FirstReason, C, R, S, safe_log_msg(Msg)]),
                    {{error, database_unavailable}, Conn}
            end;
        false ->
            {{error, database_unavailable}, Conn}
    end.

db_error({sql_error, Reason, _}) -> transient_db_reason(Reason);
db_error({sql_error, Reason}) -> transient_db_reason(Reason);
db_error({badmatch, {error, Reason}}) -> transient_db_reason(Reason);
db_error({connection_down, _}) -> true;
db_error(closed) -> true;
db_error(disconnected) -> true;
db_error(_) -> false.

transient_db_reason(closed) -> true;
transient_db_reason(disconnected) -> true;
transient_db_reason(timeout) -> true;
transient_db_reason(econnrefused) -> true;
transient_db_reason({tcp, closed}) -> true;
transient_db_reason({tcp_error, _}) -> true;
transient_db_reason({connection_down, _}) -> true;
transient_db_reason(Reason) when is_atom(Reason) ->
    lists:member(Reason, [closed, timeout, econnrefused, nxdomain, enetunreach, ehostunreach]);
transient_db_reason(_) -> false.

read_msg({register, _, _, _}) -> false;
read_msg({login, _, _}) -> false;
read_msg({logout, _}) -> false;
read_msg({logout_other_sessions, _, _}) -> false;
read_msg({change_password, _, _, _, _}) -> false;
read_msg({update_profile, _, _, _}) -> false;
read_msg({update_theme, _, _}) -> false;
read_msg({start_onboarding, _}) -> false;
read_msg({update_onboarding, _, _}) -> false;
read_msg({complete_onboarding, _}) -> false;
read_msg({dismiss_onboarding, _}) -> false;
read_msg({replay_onboarding, _}) -> false;
read_msg({friend_request, _, _}) -> false;
read_msg({friend_accept, _, _}) -> false;
read_msg({friend_remove, _, _}) -> false;
read_msg({friend_block, _, _}) -> false;
read_msg({friend_unblock, _, _}) -> false;
read_msg({create_forum, _, _, _, _}) -> false;
read_msg({join_forum, _, _}) -> false;
read_msg({leave_forum, _, _}) -> false;
read_msg({create_thread, _, _, _, _}) -> false;
read_msg({edit_thread, _, _, _, _}) -> false;
read_msg({moderate_thread, _, _, _, _}) -> false;
read_msg({edit_reply, _, _, _, _}) -> false;
read_msg({delete_reply, _, _, _}) -> false;
read_msg({delete_thread, _, _}) -> false;
read_msg({delete_forum, _, _}) -> false;
read_msg({reply_thread, _, _, _}) -> false;
read_msg({vote_thread, _, _, _}) -> false;
read_msg({create_server, _, _, _}) -> false;
read_msg({update_server, _, _, _}) -> false;
read_msg({delete_server, _, _, _}) -> false;
read_msg({create_channel, _, _, _, _, _}) -> false;
read_msg({update_channel_settings, _, _, _}) -> false;
read_msg({create_server_role, _, _, _, _}) -> false;
read_msg({update_server_role, _, _, _, _}) -> false;
read_msg({delete_server_role, _, _, _}) -> false;
read_msg({set_server_member_roles, _, _, _, _}) -> false;
read_msg({kick_server_member, _, _, _}) -> false;
read_msg({ban_server_member, _, _, _, _}) -> false;
read_msg({unban_server_member, _, _, _}) -> false;
read_msg({update_server_member_profile, _, _, _, _}) -> false;
read_msg({update_server_default_permissions, _, _, _}) -> false;
read_msg({create_server_webhook, _, _, _, _, _}) -> false;
read_msg({update_server_webhook, _, _, _, _, _}) -> false;
read_msg({delete_server_webhook, _, _, _}) -> false;
read_msg({rotate_server_webhook, _, _, _}) -> false;
read_msg({test_server_webhook, _, _, _}) -> false;
read_msg({create_incoming_webhook, _, _, _, _}) -> false;
read_msg({rotate_incoming_webhook, _, _, _}) -> false;
read_msg({delete_incoming_webhook, _, _, _}) -> false;
read_msg({execute_incoming_webhook, _, _, _, _}) -> false;
read_msg({retry_server_webhook_delivery, _, _, _, _}) -> false;
read_msg({webhook_claim_due, _}) -> false;
read_msg({webhook_finish, _, _}) -> false;
read_msg(webhook_prune) -> false;
read_msg({storage_outbox_claim, _}) -> false;
read_msg({storage_outbox_finish, _, _}) -> false;
read_msg(storage_outbox_prune) -> false;
read_msg({storage_migration_set_checkpoint, _, _}) -> false;
read_msg({storage_pg_message_edit, _, _, _}) -> false;
read_msg({storage_pg_message_delete, _, _}) -> false;
read_msg({create_server_bot, _, _, _}) -> false;
read_msg({rotate_server_bot, _, _, _}) -> false;
read_msg({delete_server_bot, _, _, _}) -> false;
read_msg({bot_register_command, _, _, _, _}) -> false;
read_msg({bot_sync_commands, _, _}) -> false;
read_msg({create_developer_app, _, _}) -> false;
read_msg({update_developer_app, _, _, _}) -> false;
read_msg({delete_developer_app, _, _}) -> false;
read_msg({install_developer_app, _, _, _}) -> false;
read_msg({install_public_developer_app, _, _, _}) -> false;
read_msg({rotate_developer_app_installation, _, _, _}) -> false;
read_msg({uninstall_developer_app, _, _, _}) -> false;
read_msg({upsert_developer_app_command, _, _, _, _, _, _}) -> false;
read_msg({delete_developer_app_command, _, _, _}) -> false;
read_msg({update_developer_app_interactions, _, _, _}) -> false;
read_msg({rotate_developer_app_interaction_secret, _, _}) -> false;
read_msg({update_developer_app_ai, _, _, _}) -> false;
read_msg({set_server_command_permissions, _, _, _, _, _}) -> false;
read_msg({uninstall_server_app, _, _, _}) -> false;
read_msg({app_interaction_claim_due, _}) -> false;
read_msg({app_interaction_finish, _, _}) -> false;
read_msg({ai_command_claim_due, _}) -> false;
read_msg({ai_command_finish, _, _}) -> false;
read_msg({bot_delete_command, _, _}) -> false;
read_msg({bot_claim_commands, _, _}) -> false;
read_msg({bot_defer_command, _, _, _, _}) -> false;
read_msg({bot_respond_command, _, _, _, _}) -> false;
read_msg({bot_fail_command, _, _, _, _}) -> false;
read_msg({invoke_bot_command, _, _, _, _}) -> false;
read_msg({search_index_reconcile, _}) -> false;
read_msg({set_message_pin, _, _, _}) -> false;
read_msg({create_category, _, _, _}) -> false;
read_msg({update_category, _, _, _, _}) -> false;
read_msg({reorder_categories, _, _, _}) -> false;
read_msg({delete_category, _, _, _}) -> false;
read_msg({move_channel, _, _, _, _}) -> false;
read_msg({create_invite, _, _, _, _, _}) -> false;
read_msg({revoke_invite, _, _, _}) -> false;
read_msg({join_invite, _, _}) -> false;
read_msg({post_channel_message, _, _, _, _}) -> false;
read_msg({delete_message, _, _}) -> false;
read_msg({edit_message, _, _, _}) -> false;
read_msg({forward_message, _, _, _, _}) -> false;
read_msg({toggle_message_reaction, _, _, _}) -> false;
read_msg({record_missed_call, _, _}) -> false;
read_msg({record_call_event, _, _, _, _}) -> false;
read_msg({create_conversation, _, _, _}) -> false;
read_msg({create_conversation_usernames, _, _, _}) -> false;
read_msg({update_conversation, _, _, _, _}) -> false;
read_msg({set_conversation_member_role, _, _, _, _}) -> false;
read_msg({kick_conversation_member, _, _, _}) -> false;
read_msg({add_conversation_members, _, _, _}) -> false;
read_msg({add_conversation_members_locked, _, _, _}) -> false;
read_msg({add_conversation_members_usernames, _, _, _}) -> false;
read_msg({close_conversation, _, _}) -> false;
read_msg({leave_conversation, _, _}) -> false;
read_msg({accept_message_request, _, _}) -> false;
read_msg({deny_message_request, _, _}) -> false;
read_msg({mark_conversation_read, _, _}) -> false;
read_msg({post_direct_message, _, _, _, _}) -> false;
read_msg({mark_notifications_seen, _}) -> false;
read_msg({clear_notifications, _}) -> false;
read_msg({mark_url_seen, _, _}) -> false;
read_msg({begin_upload, _, _, _, _, _, _}) -> false;
read_msg({finish_upload, _, _, _}) -> false;
read_msg({abort_upload, _, _}) -> false;
read_msg({delete_upload, _}) -> false;
read_msg({upload_delete_claim, _}) -> false;
read_msg({upload_delete_finish, _, _}) -> false;
read_msg({queue_stale_upload_deletes, _, _}) -> false;
read_msg({upload_ref_backfill, _}) -> false;
read_msg({prune_sessions, _}) -> false;
read_msg({change_username, _, _, _, _}) -> false;
read_msg({disable_account, _, _}) -> false;
read_msg({delete_account, _, _}) -> false;
read_msg({admin_bootstrap_owner, _, _, _}) -> false;
read_msg({admin_recover_owner, _, _, _}) -> false;
read_msg({admin_login, _, _, _, _, _, _, _, _}) -> false;
read_msg({admin_session, _}) -> false; %% updates last_seen opportunistically
read_msg({admin_logout, _}) -> false;
read_msg({admin_create_enrollment, _, _, _, _, _, _}) -> false;
read_msg({admin_redeem_enrollment, _, _, _, _, _, _, _, _, _}) -> false;
read_msg({admin_rotate_key, _, _, _, _, _}) -> false;
read_msg({admin_set_operator_role, _, _, _}) -> false;
read_msg({admin_remove_operator, _, _}) -> false;
read_msg({admin_record_audit, _, _, _, _, _, _}) -> false;
read_msg({message_id_claim_node, _, _, _}) -> false;
read_msg({message_id_renew_node, _, _, _}) -> false;
read_msg({message_id_release_node, _, _}) -> false;
read_msg({admin_create_banner, _, _}) -> false;
read_msg({admin_update_banner, _, _, _}) -> false;
read_msg({admin_delete_banner, _, _, _}) -> false;
read_msg({admin_set_registration_mode, _, _}) -> false;
read_msg({admin_user_moderation, _, _}) -> true;
read_msg({admin_user_moderation_history, _, _}) -> true;
read_msg({admin_apply_user_moderation, _, _, _, _}) -> false;
read_msg(_) -> true.

safe_log_msg({register, _, _, _}) -> {register, redacted};
safe_log_msg({login, _, _}) -> {login, redacted};
safe_log_msg({admin_bootstrap_owner, _, _, _}) -> {admin_bootstrap_owner, redacted};
safe_log_msg({admin_recover_owner, _, _, _}) -> {admin_recover_owner, redacted};
safe_log_msg({admin_login, _, _, _, _, _, _, _, _}) -> {admin_login, redacted};
safe_log_msg({admin_session, _}) -> {admin_session, redacted};
safe_log_msg({admin_logout, _}) -> {admin_logout, redacted};
safe_log_msg({admin_create_enrollment, Actor, Target, Role, _, Expires, _}) -> {admin_create_enrollment, Actor, Target, Role, redacted, Expires};
safe_log_msg({admin_redeem_enrollment, _, _, _, _, _, _, _, _, _}) -> {admin_redeem_enrollment, redacted};
safe_log_msg({admin_rotate_key, Uid, _, _, _, _}) -> {admin_rotate_key, Uid, redacted};
safe_log_msg({admin_create_banner, ActorUid, _}) -> {admin_create_banner, ActorUid, redacted};
safe_log_msg({admin_update_banner, ActorUid, BannerId, _}) -> {admin_update_banner, ActorUid, BannerId, redacted};
safe_log_msg({admin_delete_banner, ActorUid, BannerId, _}) -> {admin_delete_banner, ActorUid, BannerId, redacted_revision};
safe_log_msg({session, _}) -> {session, redacted};
safe_log_msg({logout, _}) -> {logout, redacted};
safe_log_msg({logout_other_sessions, Uid, _}) -> {logout_other_sessions, Uid, redacted};
safe_log_msg({change_username, Uid, _, NewUsername, _}) -> {change_username, Uid, redacted, pw_util:normalize_username(NewUsername), redacted_expected};
safe_log_msg({change_password, Uid, _, _, _}) -> {change_password, Uid, redacted};
safe_log_msg({update_profile, Uid, _, _}) -> {update_profile, Uid, redacted};
safe_log_msg({update_server, Uid, ServerId, _}) -> {update_server, Uid, ServerId, redacted};
safe_log_msg({post_channel_message, Uid, ChannelId, _, ReplyTo}) ->
    {post_channel_message, Uid, ChannelId, redacted, ReplyTo};
safe_log_msg({post_direct_message, Uid, Cid, _, ReplyTo}) ->
    {post_direct_message, Uid, Cid, redacted, ReplyTo};
safe_log_msg({edit_message, Uid, Mid, _}) -> {edit_message, Uid, Mid, redacted};
safe_log_msg({create_thread, Uid, ForumId, _, _}) -> {create_thread, Uid, ForumId, redacted};
safe_log_msg({reply_thread, Uid, ThreadId, _}) -> {reply_thread, Uid, ThreadId, redacted};
safe_log_msg(Msg) when is_tuple(Msg), tuple_size(Msg) > 0 ->
    %% Fail closed. New DB operations routinely grow arguments that may contain
    %% credentials, message bodies, webhook URLs or other private data. Logging
    %% an unknown tuple verbatim turns every future route into a potential secret
    %% leak. Narrow clauses above deliberately retain reviewed identifiers only.
    {element(1, Msg), redacted};
safe_log_msg(_) -> redacted.

reconnect(Conn) ->
    try epgsql:close(Conn) catch _:_ -> ok end,
    connect().

connect() ->
    Opts = #{
        host => binary_to_list(pw_util:env_str("PLAINWIRE_DB_HOST", <<"localhost">>)),
        port => pw_util:env_int("PLAINWIRE_DB_PORT", 5432),
        username => binary_to_list(pw_util:env_str("PLAINWIRE_DB_USER", <<"plainwire">>)),
        password => binary_to_list(pw_util:env_str("PLAINWIRE_DB_PASS", <<"plainwire">>)),
        database => binary_to_list(pw_util:env_str("PLAINWIRE_DB_NAME", <<"plainwire">>)),
        ssl => pw_util:env_bool("PLAINWIRE_DB_SSL", false)
    },
    case epgsql:connect(Opts) of
        {ok, Conn} ->
            configure_connection(Conn),
            %% epgsql connections may be linked to the process that opened
            %% them. Lane workers deliberately own failure/reconnect handling;
            %% an asynchronous socket exit must not cascade into pw_db itself.
            
try unlink(Conn) catch _:_ -> ok end,
            {ok, Conn};
        Err ->
            Err
    end.

configure_connection(Conn) ->
    StatementMs = clamp_timeout(pw_util:env_int("PLAINWIRE_DB_STATEMENT_TIMEOUT_MS", 15000)),
    TxMs = clamp_timeout(pw_util:env_int("PLAINWIRE_DB_IDLE_TX_TIMEOUT_MS", 15000)),
    LockMs = clamp_lock_timeout(pw_util:env_int("PLAINWIRE_DB_LOCK_TIMEOUT_MS", 5000)),
    _ = epgsql:squery(Conn, "SET statement_timeout = " ++ integer_to_list(StatementMs)),
    _ = epgsql:squery(Conn, "SET idle_in_transaction_session_timeout = " ++ integer_to_list(TxMs)),
    _ = epgsql:squery(Conn, "SET lock_timeout = " ++ integer_to_list(LockMs)),
    ok.

clamp_timeout(N) when is_integer(N), N >= 1000, N =< 120000 -> N;
clamp_timeout(N) when is_integer(N), N < 1000 -> 1000;
clamp_timeout(_) -> 15000.

clamp_lock_timeout(N) when is_integer(N), N >= 250, N =< 30000 -> N;
clamp_lock_timeout(N) when is_integer(N), N < 250 -> 250;
clamp_lock_timeout(_) -> 5000.

connect_with_retry(Attempts, DelayMs) ->
    case connect() of
        {ok, Conn} -> {ok, Conn};
        {error, Reason} when Attempts > 1 ->
            error_logger:error_msg("DB connect failed: ~p; retrying~n", [Reason]),
            timer:sleep(DelayMs),
            connect_with_retry(Attempts - 1, DelayMs);
        Error -> Error
    end.

route(health_probe, Conn) ->
    case rows(Conn, "SELECT 1", []) of
        {ok, _} -> {ok, database_ok};
        _ -> {error, database_unavailable}
    end;
route(admin_operator_count, Conn) ->
    %% No parameters, so rows/3 takes the simple-query path (epgsql:squery),
    %% which returns every column as text: count(*) arrives as <<"0">>, and
    %% pw_admin_identity's {ok, 0} first-run check would never match.
    case one(Conn, "SELECT count(*) FROM admin_operators", []) of
        {ok, [Count]} when is_binary(Count) -> {ok, binary_to_integer(Count)};
        {ok, [Count]} -> {ok, Count};
        {error, Reason} -> erlang:error({sql_error, Reason})
    end;
route({admin_bootstrap_owner, U0, P0, VerificationHash0}, Conn) ->
    U = pw_util:normalize_username(U0),
    P = pw_util:clean_text(P0, 256),
    VerificationHash = pw_util:clean_text(VerificationHash0, 128),
    with_tx(Conn, fun() ->
        ok = exec(Conn, "LOCK TABLE admin_operators IN SHARE ROW EXCLUSIVE MODE", []),
        case one(Conn, "SELECT count(*) FROM admin_operators", []) of
            %% simple-query text result; see route(admin_operator_count, _)
            {ok, [Zero]} when Zero =:= 0; Zero =:= <<"0">> ->
                case verify_admin_user(Conn, U, P) of
                    {ok, Uid, Username, DisplayName} ->
                        Now = pw_util:now_ms(),
                        ok = exec(Conn,
                            "INSERT INTO admin_operators(user_id,role,verification_hash,created_by,created_at,updated_at) "
                            "VALUES($1,'owner',$2,$1,$3,$3)", [Uid, VerificationHash, Now]),
                        admin_audit_insert(Conn, Uid, <<"operator.bootstrap">>, <<"operator">>, integer_to_binary(Uid), <<"first service owner">>, <<>>, Now),
                        {ok, #{user_id => Uid, username => Username, display_name => DisplayName, role => <<"owner">>}};
                    Error -> Error
                end;
            {ok, [_]} -> {error, bootstrap_unavailable};
            {error, Reason} -> erlang:error({sql_error, Reason})
        end
    end);
route({admin_recover_owner, U0, P0, VerificationHash0}, Conn) ->
    U = pw_util:normalize_username(U0),
    P = pw_util:clean_text(P0, 256),
    VerificationHash = pw_util:clean_text(VerificationHash0, 128),
    with_tx(Conn, fun() ->
        ok = exec(Conn, "LOCK TABLE admin_operators IN SHARE ROW EXCLUSIVE MODE", []),
        case verify_admin_user(Conn, U, P) of
            {ok, Uid, Username, DisplayName} ->
                Now = pw_util:now_ms(),
                ok = exec(Conn,
                    "INSERT INTO admin_operators(user_id,role,verification_hash,created_by,created_at,updated_at) "
                    "VALUES($1,'owner',$2,$1,$3,$3) ON CONFLICT(user_id) DO UPDATE SET role='owner',verification_hash=EXCLUDED.verification_hash,updated_at=EXCLUDED.updated_at",
                    [Uid, VerificationHash, Now]),
                ok = exec(Conn, "DELETE FROM admin_sessions", []),
                ok = exec(Conn, "DELETE FROM admin_enrollments WHERE used_at IS NULL", []),
                admin_audit_insert(Conn, Uid, <<"operator.local_recovery">>, <<"operator">>, integer_to_binary(Uid),
                                   <<"host-local emergency owner recovery; all admin sessions revoked">>, <<>>, Now),
                {ok, #{user_id => Uid, username => Username, display_name => DisplayName, role => <<"owner">>, sessions_revoked => true}};
            Error -> Error
        end
    end);
route({admin_login, U0, P0, VerificationHash0, SessionHash0, Csrf0, ExpiresAt, IpHash0, UaHash0}, Conn) ->
    U = pw_util:normalize_username(U0),
    P = pw_util:clean_text(P0, 256),
    VerificationHash = pw_util:clean_text(VerificationHash0, 128),
    SessionHash = pw_util:clean_text(SessionHash0, 128),
    Csrf = pw_util:clean_text(Csrf0, 128),
    IpHash = pw_util:clean_text(IpHash0, 128),
    UaHash = pw_util:clean_text(UaHash0, 128),
    %% Serialize credential verification against key rotation/removal. Without
    %% the row lock, an old key could validate immediately before a rotation,
    %% then insert a new admin session after the rotation deleted old sessions.
    with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT u.id,u.username,u.display_name,u.password_hash,u.password_salt,a.role,a.verification_hash "
            "FROM users u JOIN admin_operators a ON a.user_id=u.id WHERE u.username=$1 AND u.account_state='active' FOR UPDATE OF u,a", [U]) of
            {ok, [Uid, Username, DisplayName, PasswordHash, Salt, Role, StoredVerification]} ->
                PasswordOk = pw_util:verify_password(P, Salt, PasswordHash),
                KeyOk = pw_util:constant_time(VerificationHash, StoredVerification),
                case PasswordOk andalso KeyOk of
                    true ->
                        maybe_upgrade_password_hash(Conn, Uid, P, PasswordHash),
                        Now = pw_util:now_ms(),
                        ok = exec(Conn,
                            "INSERT INTO admin_sessions(token_hash,user_id,csrf,created_at,last_seen,expires_at,ip_hash,user_agent_hash) "
                            "VALUES($1,$2,$3,$4,$4,$5,$6,$7)",
                            [SessionHash, Uid, Csrf, Now, ExpiresAt, IpHash, UaHash]),
                        admin_audit_insert(Conn, Uid, <<"auth.login">>, <<"operator">>, integer_to_binary(Uid), <<>>, IpHash, Now),
                        {ok, #{user_id => Uid, username => Username, display_name => DisplayName, role => Role, csrf => Csrf, expires_at => ExpiresAt}};
                    false -> {error, bad_login}
                end;
            {ok, undefined} ->
                _ = pw_util:pbkdf2(P, <<"plainwire-admin-login-timing-pad">>),
                {error, bad_login};
            {error, Reason} -> erlang:error({sql_error, Reason})
        end
    end);
route({admin_session, SessionHash0}, Conn) ->
    SessionHash = pw_util:clean_text(SessionHash0, 128),
    Now = pw_util:now_ms(),
    case one(Conn,
        "SELECT s.user_id,s.csrf,s.created_at,s.last_seen,s.expires_at,u.username,u.display_name,a.role "
        "FROM admin_sessions s JOIN users u ON u.id=s.user_id JOIN admin_operators a ON a.user_id=s.user_id "
        "WHERE s.token_hash=$1 AND s.expires_at>$2 AND u.account_state='active'", [SessionHash, Now]) of
        {ok, [Uid, Csrf, Created, LastSeen, Expires, Username, DisplayName, Role]} ->
            Cutoff = Now - 60000,
            _ = exec(Conn, "UPDATE admin_sessions SET last_seen=$1 WHERE token_hash=$2 AND last_seen<$3", [Now, SessionHash, Cutoff]),
            {ok, #{user_id => Uid, csrf => Csrf, created_at => Created, last_seen => LastSeen, expires_at => Expires,
                   username => Username, display_name => DisplayName, role => Role}};
        {ok, undefined} -> {error, no_session};
        {error, Reason} -> erlang:error({sql_error, Reason})
    end;
route({admin_logout, SessionHash0}, Conn) ->
    SessionHash = pw_util:clean_text(SessionHash0, 128),
    ok = exec(Conn, "DELETE FROM admin_sessions WHERE token_hash=$1", [SessionHash]),
    {ok, #{logged_out => true}};
route({admin_create_enrollment, ActorUid, TargetUsername0, RequestedRole0, TokenHash0, ExpiresAt, Note0}, Conn) ->
    TargetUsername = pw_util:normalize_username(TargetUsername0),
    TokenHash = pw_util:clean_text(TokenHash0, 128),
    Note = pw_util:clean_text(Note0, 160),
    case normalize_admin_role(RequestedRole0) of
        undefined -> {error, invalid_role};
        RequestedRole -> with_tx(Conn, fun() ->
        ok = exec(Conn, "LOCK TABLE admin_operators IN SHARE ROW EXCLUSIVE MODE", []),
        case admin_actor_role(Conn, ActorUid) of
            <<"owner">> ->
                case one(Conn, "SELECT id,username,display_name FROM users WHERE username=$1 AND account_state='active' FOR UPDATE", [TargetUsername]) of
                    {ok, [TargetUid, Username, DisplayName]} ->
                        ExistingRole = case one(Conn, "SELECT role FROM admin_operators WHERE user_id=$1", [TargetUid]) of
                            {ok, [ExistingRoleValue]} -> ExistingRoleValue;
                            _ -> undefined
                        end,
                        EffectiveRole = case ExistingRole of undefined -> RequestedRole; _ -> ExistingRole end,
                        Now = pw_util:now_ms(),
                        ok = exec(Conn, "DELETE FROM admin_enrollments WHERE user_id=$1 AND used_at IS NULL", [TargetUid]),
                        ok = exec(Conn,
                            "INSERT INTO admin_enrollments(token_hash,user_id,role,created_by,note,created_at,expires_at,used_at) "
                            "VALUES($1,$2,$3,$4,$5,$6,$7,NULL)",
                            [TokenHash, TargetUid, EffectiveRole, ActorUid, Note, Now, ExpiresAt]),
                        admin_audit_insert(Conn, ActorUid, <<"operator.enrollment_created">>, <<"operator">>, integer_to_binary(TargetUid), Note, <<>>, Now),
                        {ok, #{user_id => TargetUid, username => Username, display_name => DisplayName, role => EffectiveRole, expires_at => ExpiresAt}};
                    _ -> {error, user_not_found}
                end;
            _ -> {error, forbidden}
        end
    end)
    end;
route({admin_redeem_enrollment, U0, P0, TokenHash0, VerificationHash0, SessionHash0, Csrf0, ExpiresAt, IpHash0, UaHash0}, Conn) ->
    U = pw_util:normalize_username(U0),
    P = pw_util:clean_text(P0, 256),
    TokenHash = pw_util:clean_text(TokenHash0, 128),
    VerificationHash = pw_util:clean_text(VerificationHash0, 128),
    SessionHash = pw_util:clean_text(SessionHash0, 128),
    Csrf = pw_util:clean_text(Csrf0, 128),
    IpHash = pw_util:clean_text(IpHash0, 128),
    UaHash = pw_util:clean_text(UaHash0, 128),
    with_tx(Conn, fun() ->
        Now = pw_util:now_ms(),
        case one(Conn,
            "SELECT e.user_id,e.role,u.username,u.display_name,u.password_hash,u.password_salt,e.expires_at,e.used_at,u.account_state "
            "FROM admin_enrollments e JOIN users u ON u.id=e.user_id WHERE e.token_hash=$1 FOR UPDATE", [TokenHash]) of
            {ok, [Uid, _EnrollmentRole, Username, DisplayName, PasswordHash, Salt, EnrollExpires, null, <<"active">>]} when EnrollExpires > Now, Username =:= U ->
                case pw_util:verify_password(P, Salt, PasswordHash) of
                    false -> {error, bad_login};
                    true ->
                        maybe_upgrade_password_hash(Conn, Uid, P, PasswordHash),
                        ok = exec(Conn,
                            "INSERT INTO admin_operators(user_id,role,verification_hash,created_by,created_at,updated_at) "
                            "SELECT user_id,role,$2,created_by,$3,$3 FROM admin_enrollments WHERE token_hash=$1 "
                            "ON CONFLICT(user_id) DO UPDATE SET verification_hash=EXCLUDED.verification_hash,updated_at=EXCLUDED.updated_at",
                            [TokenHash, VerificationHash, Now]),
                        ok = exec(Conn, "UPDATE admin_enrollments SET used_at=$2 WHERE token_hash=$1 AND used_at IS NULL", [TokenHash, Now]),
                        ok = exec(Conn, "DELETE FROM admin_sessions WHERE user_id=$1", [Uid]),
                        ok = exec(Conn,
                            "INSERT INTO admin_sessions(token_hash,user_id,csrf,created_at,last_seen,expires_at,ip_hash,user_agent_hash) "
                            "VALUES($1,$2,$3,$4,$4,$5,$6,$7)", [SessionHash, Uid, Csrf, Now, ExpiresAt, IpHash, UaHash]),
                        %% Existing operators keep their current role. An older recovery
                        %% code must never resurrect a role that was changed after the
                        %% code was issued, so return the authoritative role as well.
                        {ok, [EffectiveRole]} = one(Conn, "SELECT role FROM admin_operators WHERE user_id=$1", [Uid]),
                        admin_audit_insert(Conn, Uid, <<"operator.enrollment_redeemed">>, <<"operator">>, integer_to_binary(Uid), <<>>, IpHash, Now),
                        {ok, #{user_id => Uid, username => Username, display_name => DisplayName, role => EffectiveRole, csrf => Csrf, expires_at => ExpiresAt}}
                end;
            {ok, [_Uid, _Role, _Username, _DisplayName, _PasswordHash, _Salt, _EnrollExpires, _UsedAt, _AccountState]} -> {error, invalid_enrollment};
            _ ->
                _ = pw_util:pbkdf2(P, <<"plainwire-admin-enrollment-timing-pad">>),
                {error, invalid_enrollment}
        end
    end);
route({admin_rotate_key, Uid, P0, CurrentHash0, NewHash0, ActorIpHash0}, Conn) ->
    P = pw_util:clean_text(P0, 256),
    CurrentHash = pw_util:clean_text(CurrentHash0, 128),
    NewHash = pw_util:clean_text(NewHash0, 128),
    ActorIpHash = pw_util:clean_text(ActorIpHash0, 128),
    with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT u.password_hash,u.password_salt,a.verification_hash FROM users u JOIN admin_operators a ON a.user_id=u.id WHERE u.id=$1 FOR UPDATE OF u,a",
            [Uid]) of
            {ok, [PasswordHash, Salt, StoredVerification]} ->
                case pw_util:verify_password(P, Salt, PasswordHash) andalso pw_util:constant_time(CurrentHash, StoredVerification) of
                    false -> {error, bad_login};
                    true ->
                        Now = pw_util:now_ms(),
                        ok = exec(Conn, "UPDATE admin_operators SET verification_hash=$2,updated_at=$3 WHERE user_id=$1", [Uid, NewHash, Now]),
                        ok = exec(Conn, "DELETE FROM admin_sessions WHERE user_id=$1", [Uid]),
                        %% Key rotation is a credential-reset boundary. Revoke unused
                        %% recovery/enrollment capabilities for this account, and any
                        %% outstanding codes it issued while acting as an owner.
                        ok = exec(Conn, "DELETE FROM admin_enrollments WHERE used_at IS NULL AND (user_id=$1 OR created_by=$1)", [Uid]),
                        admin_audit_insert(Conn, Uid, <<"operator.key_rotated">>, <<"operator">>, integer_to_binary(Uid), <<>>, ActorIpHash, Now),
                        {ok, #{rotated => true}}
                end;
            _ -> {error, not_found}
        end
    end);
route({admin_operators, _ActorUid}, Conn) ->
    {ok, Rows} = rows(Conn,
        "SELECT a.user_id,u.username,u.display_name,a.role,a.created_at,a.updated_at,"
        "(SELECT max(last_seen) FROM admin_sessions s WHERE s.user_id=a.user_id AND s.expires_at>$1) "
        "FROM admin_operators a JOIN users u ON u.id=a.user_id ORDER BY CASE a.role WHEN 'owner' THEN 0 WHEN 'operator' THEN 1 ELSE 2 END,u.username",
        [pw_util:now_ms()]),
    {ok, [#{user_id => Uid, username => Username, display_name => DisplayName, role => Role,
            created_at => Created, updated_at => Updated, last_admin_seen => LastSeen}
          || [Uid, Username, DisplayName, Role, Created, Updated, LastSeen] <- Rows]};
route({admin_set_operator_role, ActorUid, TargetUid, Role0}, Conn) ->
    case normalize_admin_role(Role0) of
        undefined -> {error, invalid_role};
        Role -> with_tx(Conn, fun() ->
        ok = exec(Conn, "LOCK TABLE admin_operators IN SHARE ROW EXCLUSIVE MODE", []),
        case admin_actor_role(Conn, ActorUid) of
            <<"owner">> ->
                case one(Conn, "SELECT role FROM admin_operators WHERE user_id=$1 FOR UPDATE", [TargetUid]) of
                    {ok, [CurrentRole]} ->
                        case can_change_owner(Conn, CurrentRole, Role) of
                            false -> {error, last_owner};
                            true ->
                                Now = pw_util:now_ms(),
                                ok = exec(Conn, "UPDATE admin_operators SET role=$2,updated_at=$3 WHERE user_id=$1", [TargetUid, Role, Now]),
                                ok = exec(Conn, "DELETE FROM admin_sessions WHERE user_id=$1", [TargetUid]),
                                ok = exec(Conn, "DELETE FROM admin_enrollments WHERE used_at IS NULL AND (user_id=$1 OR created_by=$1)", [TargetUid]),
                                admin_audit_insert(Conn, ActorUid, <<"operator.role_changed">>, <<"operator">>, integer_to_binary(TargetUid), Role, <<>>, Now),
                                {ok, #{user_id => TargetUid, role => Role, sessions_revoked => true}}
                        end;
                    _ -> {error, not_found}
                end;
            _ -> {error, forbidden}
        end
    end)
    end;
route({admin_remove_operator, ActorUid, TargetUid}, Conn) ->
    with_tx(Conn, fun() ->
        ok = exec(Conn, "LOCK TABLE admin_operators IN SHARE ROW EXCLUSIVE MODE", []),
        case admin_actor_role(Conn, ActorUid) of
            <<"owner">> ->
                case one(Conn, "SELECT role FROM admin_operators WHERE user_id=$1 FOR UPDATE", [TargetUid]) of
                    {ok, [Role]} ->
                        case can_remove_owner(Conn, Role) of
                            false -> {error, last_owner};
                            true ->
                                Now = pw_util:now_ms(),
                                %% A pending recovery code targets users, not operator
                                %% rows, so invalidate it explicitly before removing the
                                %% operator. Codes issued by the operator cascade via
                                %% admin_enrollments.created_by.
                                ok = exec(Conn, "DELETE FROM admin_enrollments WHERE user_id=$1 AND used_at IS NULL", [TargetUid]),
                                ok = exec(Conn, "DELETE FROM admin_operators WHERE user_id=$1", [TargetUid]),
                                admin_audit_insert(Conn, ActorUid, <<"operator.removed">>, <<"operator">>, integer_to_binary(TargetUid), <<>>, <<>>, Now),
                                {ok, #{removed => true, user_id => TargetUid}}
                        end;
                    _ -> {error, not_found}
                end;
            _ -> {error, forbidden}
        end
    end);
route({message_id_claim_node, NodeId, Owner0, LeaseMs0}, Conn) ->
    Owner = pw_util:clean_text(Owner0, 128),
    LeaseMs = min(120000, max(5000, int_or(pw_util:int(LeaseMs0), 30000))),
    %% PostgreSQL is the clock authority for distributed node fencing. Using an
    %% app node's wall clock here allows clock skew/rollback on two hosts to make
    %% both believe the same Snowflake node id is leased.
    case one(Conn,
        "WITH clock AS (SELECT (extract(epoch from clock_timestamp())*1000)::bigint AS now_ms) "
        "INSERT INTO message_id_node_leases(node_id,node_name,lease_until,updated_at) "
        "SELECT $1,$2,clock.now_ms+$3,clock.now_ms FROM clock "
        "ON CONFLICT(node_id) DO UPDATE SET node_name=EXCLUDED.node_name,lease_until=EXCLUDED.lease_until,updated_at=EXCLUDED.updated_at "
        "WHERE message_id_node_leases.lease_until < EXCLUDED.updated_at OR message_id_node_leases.node_name = EXCLUDED.node_name "
        "RETURNING node_id,lease_until,(SELECT now_ms FROM clock)",
        [NodeId, Owner, LeaseMs]) of
        {ok, [NodeId, LeaseUntil, DbNowMs]} -> {ok, claimed, LeaseUntil, DbNowMs};
        _ -> {error, node_id_in_use}
    end;
route({message_id_renew_node, NodeId, Owner0, LeaseMs0}, Conn) ->
    Owner = pw_util:clean_text(Owner0, 128),
    LeaseMs = min(120000, max(5000, int_or(pw_util:int(LeaseMs0), 30000))),
    case one(Conn,
        "WITH clock AS (SELECT (extract(epoch from clock_timestamp())*1000)::bigint AS now_ms) "
        "UPDATE message_id_node_leases SET lease_until=clock.now_ms+$1,updated_at=clock.now_ms FROM clock "
        "WHERE node_id=$2 AND node_name=$3 AND message_id_node_leases.lease_until >= clock.now_ms "
        "RETURNING node_id,lease_until,(SELECT now_ms FROM clock)",
        [LeaseMs, NodeId, Owner]) of
        {ok, [NodeId, LeaseUntil, DbNowMs]} -> {ok, renewed, LeaseUntil, DbNowMs};
        _ -> {error, lease_lost}
    end;
route({message_id_release_node, NodeId, Owner0}, Conn) ->
    Owner = pw_util:clean_text(Owner0, 128),
    case exec(Conn, "DELETE FROM message_id_node_leases WHERE node_id=$1 AND node_name=$2", [NodeId, Owner]) of
        ok -> ok;
        {ok, _} -> ok;
        Error -> Error
    end;
route(admin_overview, Conn) ->
    Now = pw_util:now_ms(),
    DayAgo = Now - 86400000,
    HourAgo = Now - 3600000,
    {ok, [Users, Servers, Channels, DirectThreads, Messages, Uploads, Reactions]} = one(Conn,
        "SELECT "
        "COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables WHERE relname='users'),0),"
        "COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables WHERE relname='servers'),0),"
        "COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables WHERE relname='channels'),0),"
        "COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables WHERE relname='direct_threads'),0),"
        "COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables WHERE relname='messages'),0),"
        "COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables WHERE relname='uploads'),0),"
        "COALESCE((SELECT n_live_tup::bigint FROM pg_stat_user_tables WHERE relname='message_reactions'),0)", []),
    {ok, [ActiveHour, ActiveDay, ActiveSessions, MessagesDay, UploadBytes, ReadyUploads, AdminSessions]} = one(Conn,
        "SELECT "
        "(SELECT count(*) FROM users WHERE last_seen >= $1),"
        "(SELECT count(*) FROM users WHERE last_seen >= $2),"
        "(SELECT count(*) FROM sessions WHERE expires_at > $3),"
        "(SELECT count(*) FROM messages WHERE created_at >= $2),"
        "COALESCE((SELECT sum(size) FROM uploads WHERE status='ready'),0),"
        "(SELECT count(*) FROM uploads WHERE status='ready'),"
        "(SELECT count(*) FROM admin_sessions WHERE expires_at > $3)", [HourAgo, DayAgo, Now]),
    {ok, [OutboxPending, OutboxFailed, PrivacyDeletePending]} = one(Conn,
        "SELECT count(*) FILTER (WHERE status IN ('pending','running'))," 
        "count(*) FILTER (WHERE status='failed')," 
        "count(*) FILTER (WHERE kind='message.hard_delete' AND status IN ('pending','running')) FROM storage_outbox", []),
    {ok, #{totals_approximate => true, users => Users, servers => Servers, channels => Channels, direct_threads => DirectThreads,
           messages => Messages, uploads => Uploads, reactions => Reactions, active_users_1h => ActiveHour,
           active_users_24h => ActiveDay, active_sessions => ActiveSessions, messages_24h => MessagesDay,
           upload_bytes => UploadBytes, ready_uploads => ReadyUploads, admin_sessions => AdminSessions,
           storage => storage_health_summary(), storage_outbox_pending => OutboxPending,
           storage_outbox_failed => OutboxFailed, storage_privacy_delete_pending => PrivacyDeletePending}};
route({admin_users, Q0, Limit0, Offset0}, Conn) ->
    Q = pw_util:clean_text(Q0, 80),
    Limit = clamp_page_limit(Limit0),
    Offset = clamp_offset(Offset0),
    Like = <<"%", Q/binary, "%">>,
    {ok, Rows} = rows(Conn,
        "SELECT u.id,u.username,u.display_name,u.created_at,u.last_seen,"
        "(SELECT count(*) FROM server_members sm WHERE sm.user_id=u.id),"
        "(SELECT count(*) FROM direct_members dm WHERE dm.user_id=u.id),"
        "(SELECT count(*) FROM sessions s WHERE s.user_id=u.id AND s.expires_at>$4),"
        "COALESCE((SELECT sum(size) FROM uploads up WHERE up.user_id=u.id AND up.status='ready'),0),"
        "u.account_state,u.is_bot,u.moderation_expires_at "
        "FROM users u WHERE ($1='' OR u.username ILIKE $2 OR u.display_name ILIKE $2) "
        "ORDER BY u.last_seen DESC,u.id DESC LIMIT $3 OFFSET $5",
        [Q, Like, Limit, pw_util:now_ms(), Offset]),
    {ok, [admin_user_summary(R) || R <- Rows]};
route({admin_user, Uid}, Conn) ->
    case one(Conn,
        "SELECT u.id,u.username,u.display_name,u.created_at,u.updated_at,u.last_seen,"
        "(SELECT count(*) FROM server_members sm WHERE sm.user_id=u.id),"
        "(SELECT count(*) FROM servers s WHERE s.owner_id=u.id),"
        "(SELECT count(*) FROM direct_members dm WHERE dm.user_id=u.id),"
        "(SELECT count(*) FROM messages m WHERE m.user_id=u.id),"
        "(SELECT count(*) FROM uploads up WHERE up.user_id=u.id AND up.status='ready'),"
        "COALESCE((SELECT sum(size) FROM uploads up WHERE up.user_id=u.id AND up.status='ready'),0),"
        "(SELECT count(*) FROM sessions s WHERE s.user_id=u.id AND s.expires_at>$2),"
        "u.account_state,u.is_bot,u.moderation_title,u.moderation_reason,u.moderation_severity,u.moderation_expires_at,u.moderated_by,u.moderated_at "
        "FROM users u WHERE u.id=$1", [Uid, pw_util:now_ms()]) of
        {ok, Row} when is_list(Row) -> {ok, admin_user_detail(Row)};
        _ -> {error, not_found}
    end;

route({admin_user_moderation, ActorUid, TargetUid0}, Conn) ->
    TargetUid = pw_util:int(TargetUid0),
    case admin_can_inspect_user(Conn, ActorUid, TargetUid) of
        false -> {error, forbidden};
        true ->
            case one(Conn,
                "SELECT id,username,display_name,account_state,is_bot,moderation_title,moderation_reason,moderation_severity,moderation_expires_at,moderated_by,moderated_at "
                "FROM users WHERE id=$1", [TargetUid]) of
                {ok, [Uid, Username, Display, State, IsBot, Title, Reason, Severity, ExpiresAt, ModeratedBy, ModeratedAt]} ->
                    {ok, #{id => Uid, username => Username, display_name => Display, account_state => State, is_bot => IsBot,
                        moderation => moderation_public_map(State, Title, Reason, Severity, ExpiresAt, ModeratedBy, ModeratedAt)}};
                _ -> {error, not_found}
            end
    end;
route({admin_user_moderation_history, ActorUid, TargetUid0}, Conn) ->
    TargetUid = pw_util:int(TargetUid0),
    case admin_can_inspect_user(Conn, ActorUid, TargetUid) of
        false -> {error, forbidden};
        true ->
            {ok, Rows} = rows(Conn,
                "SELECT a.id,a.action,a.title,a.reason,a.severity,a.expires_at,a.created_at,a.actor_user_id,u.username "
                "FROM instance_account_actions a LEFT JOIN users u ON u.id=a.actor_user_id WHERE a.user_id=$1 ORDER BY a.id DESC LIMIT 100",
                [TargetUid]),
            {ok, [#{id => Id, action => Action, title => Title, reason => Reason, severity => Severity,
                    expires_at => ExpiresAt, created_at => CreatedAt, actor_user_id => Actor,
                    actor_username => ActorUsername}
                  || [Id, Action, Title, Reason, Severity, ExpiresAt, CreatedAt, Actor, ActorUsername] <- Rows]}
    end;
route({admin_apply_user_moderation, ActorUid, TargetUid0, Action0, Patch0}, Conn) ->
    TargetUid = pw_util:int(TargetUid0), Action = normalize_instance_moderation_action(Action0),
    Patch = normalize_instance_moderation_patch(Patch0, Action),
    case {Action, Patch, TargetUid} of
        {invalid, _, _} -> {error, invalid_action};
        {_, {error, Reason}, _} -> {error, Reason};
        {_, _, Uid} when not is_integer(Uid); Uid =< 0 -> {error, not_found};
        {_, {ok, Moderation}, Uid} ->
            Result = with_tx(Conn, fun() ->
                %% Serialize operator-role checks with the action so demotion and
                %% moderation cannot race each other across admin nodes.
                ok = exec(Conn, "LOCK TABLE admin_operators IN SHARE MODE", []),
                case moderation_actor_allowed(Conn, ActorUid, Uid) of
                    {error, Reason} -> {error, Reason};
                    ok ->
                        case one(Conn, "SELECT id,account_state FROM users WHERE id=$1 FOR UPDATE", [Uid]) of
                            {ok, [_Id, _OldState]} ->
                                Now = pw_util:now_ms(),
                                NewState = moderation_action_state(Action),
                                Title = maps:get(title, Moderation), ReasonText = maps:get(reason, Moderation),
                                Severity = maps:get(severity, Moderation), ExpiresAt = maps:get(expires_at, Moderation),
                                case Action of
                                    restore ->
                                        ok = exec(Conn,
                                            "UPDATE users SET account_state='active',moderation_title='',moderation_reason='',moderation_severity='warning',moderation_expires_at=0,moderated_by=$2,moderated_at=$3,updated_at=$3 WHERE id=$1",
                                            [Uid, ActorUid, Now]);
                                    _ ->
                                        ok = exec(Conn,
                                            "UPDATE users SET account_state=$2,moderation_title=$3,moderation_reason=$4,moderation_severity=$5,moderation_expires_at=$6,moderated_by=$7,moderated_at=$8,updated_at=$8 WHERE id=$1",
                                            [Uid, NewState, Title, ReasonText, Severity, ExpiresAt, ActorUid, Now])
                                end,
                                {ok, SessionRows} = rows(Conn, "DELETE FROM sessions WHERE user_id=$1 RETURNING token_hash", [Uid]),
                                ok = exec(Conn, "DELETE FROM admin_sessions WHERE user_id=$1", [Uid]),
                                ok = exec(Conn,
                                    "INSERT INTO instance_account_actions(user_id,actor_user_id,action,title,reason,severity,expires_at,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
                                    [Uid, ActorUid, atom_to_binary(Action, utf8), Title, ReasonText, Severity, ExpiresAt, Now]),
                                Detail = moderation_audit_detail(Action, Title, ReasonText, Severity, ExpiresAt),
                                admin_audit_insert(Conn, ActorUid, <<"account.", (atom_to_binary(Action, utf8))/binary>>, <<"user">>, integer_to_binary(Uid), Detail, <<>>, Now),
                                {ok, #{user_id => Uid, account_state => NewState,
                                    moderation => moderation_public_map(NewState, Title, ReasonText, Severity, ExpiresAt, ActorUid, Now),
                                    session_hashes => [only_id(R) || R <- SessionRows]}};
                            _ -> {error, not_found}
                        end
                end
            end),
            case Result of
                {ok, #{session_hashes := Hashes, user_id := UserId} = Data} ->
                    [ets:delete(?SESSION_CACHE, H) || H <- Hashes],
                    invalidate_session_cache(UserId),
                    pw_redis:presence_delete(UserId),
                    pw_upload_gc:invalidate_user(UserId),
                    Public = maps:remove(session_hashes, Data),
                    EventType = case Action of restore -> account_restored; _ -> account_restricted end,
                    pw_hub:notify_user(UserId, #{type => EventType, account_state => maps:get(account_state, Public), moderation => maps:get(moderation, Public)}),
                    {ok, Public};
                Other -> Other
            end
    end;
route({admin_servers, Q0, Limit0, Offset0}, Conn) ->
    Q = pw_util:clean_text(Q0, 100),
    Limit = clamp_page_limit(Limit0),
    Offset = clamp_offset(Offset0),
    Like = <<"%", Q/binary, "%">>,
    {ok, Rows} = rows(Conn,
        "SELECT s.id,s.name,s.created_at,s.updated_at,u.id,u.username,u.display_name,"
        "(SELECT count(*) FROM server_members sm WHERE sm.server_id=s.id),"
        "(SELECT count(*) FROM channels c WHERE c.server_id=s.id) "
        "FROM servers s JOIN users u ON u.id=s.owner_id "
        "WHERE ($1='' OR s.name ILIKE $2 OR u.username ILIKE $2) ORDER BY s.updated_at DESC,s.id DESC LIMIT $3 OFFSET $4",
        [Q, Like, Limit, Offset]),
    {ok, [admin_server_summary(R) || R <- Rows]};
route({admin_server, Sid}, Conn) ->
    case one(Conn,
        "SELECT s.id,s.name,s.created_at,s.updated_at,u.id,u.username,u.display_name,"
        "(SELECT count(*) FROM server_members sm WHERE sm.server_id=s.id),"
        "(SELECT count(*) FROM channels c WHERE c.server_id=s.id),"
        "(SELECT count(*) FROM server_roles r WHERE r.server_id=s.id),"
        "(SELECT count(*) FROM server_invites i WHERE i.server_id=s.id AND i.revoked=false AND (i.expires_at=0 OR i.expires_at>$2)),"
        "(SELECT count(*) FROM messages m JOIN channels c ON c.id=m.scope_id WHERE m.scope='channel' AND c.server_id=s.id),"
        "(SELECT max(m.created_at) FROM messages m JOIN channels c ON c.id=m.scope_id WHERE m.scope='channel' AND c.server_id=s.id) "
        "FROM servers s JOIN users u ON u.id=s.owner_id WHERE s.id=$1", [Sid, pw_util:now_ms()]) of
        {ok, Row} when is_list(Row) -> {ok, admin_server_detail(Row)};
        _ -> {error, not_found}
    end;
route({admin_audit, Limit0, BeforeId0}, Conn) ->
    Limit = min(200, max(1, case pw_util:int(Limit0) of undefined -> 80; LimitI -> LimitI end)),
    BeforeId = case pw_util:int(BeforeId0) of undefined -> 9223372036854775807; BeforeI -> max(1, BeforeI) end,
    {ok, Rows} = rows(Conn,
        "SELECT a.id,a.actor_user_id,u.username,a.action,a.target_type,a.target_id,a.detail,a.created_at "
        "FROM admin_audit a LEFT JOIN users u ON u.id=a.actor_user_id WHERE a.id<$1 ORDER BY a.id DESC LIMIT $2",
        [BeforeId, Limit]),
    {ok, [#{id => Id, actor_user_id => Actor, actor_username => Username, action => Action,
            target_type => TargetType, target_id => TargetId, detail => Detail, created_at => Created}
          || [Id, Actor, Username, Action, TargetType, TargetId, Detail, Created] <- Rows]};
route({admin_record_audit, ActorUid, Action0, TargetType0, TargetId0, Detail0, IpHash0}, Conn) ->
    Action = pw_util:clean_text(Action0, 80),
    TargetType = pw_util:clean_text(TargetType0, 40),
    TargetId = pw_util:clean_text(TargetId0, 80),
    Detail = pw_util:clean_text(Detail0, 240),
    IpHash = pw_util:clean_text(IpHash0, 128),
    AuditNow = pw_util:now_ms(),
    admin_audit_insert(Conn, ActorUid, Action, TargetType, TargetId, Detail, IpHash, AuditNow),
    ok = maybe_queue_admin_server_audit(Conn, ActorUid, Action, TargetType, TargetId, Detail, AuditNow),
    {ok, #{recorded => true}};
route(global_banners, Conn) ->
    Now = pw_util:now_ms(),
    {ok, Rows} = rows(Conn,
        "SELECT id,title,body,severity,starts_at,ends_at,dismissible,link_label,link_url,updated_at "
        "FROM global_banners WHERE enabled=true AND starts_at<=$1 AND (ends_at=0 OR ends_at>$1) "
        "ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 WHEN 'success' THEN 2 ELSE 3 END, "
        "starts_at DESC,id DESC LIMIT 32", [Now]),
    {ok, [banner_map(Row) || Row <- Rows]};
route(admin_banners, Conn) ->
    {ok, Rows} = rows(Conn,
        "SELECT b.id,b.title,b.body,b.severity,b.starts_at,b.ends_at,b.dismissible,b.link_label,b.link_url,b.enabled,"
        "b.created_by,u.username,b.created_at,b.updated_at FROM global_banners b "
        "LEFT JOIN users u ON u.id=b.created_by ORDER BY b.updated_at DESC,b.id DESC LIMIT 200", []),
    {ok, [admin_banner_map(Row) || Row <- Rows]};
route({admin_create_banner, ActorUid, Patch0}, Conn) ->
    with_tx(Conn, fun() ->
        case admin_can_operate(Conn, ActorUid) of
            false -> {error, forbidden};
            true ->
                case normalize_banner_patch(Patch0, pw_util:now_ms()) of
                    {error, Reason} -> {error, Reason};
                    {ok, Banner} ->
                        Now = pw_util:now_ms(),
                        {ok, [BannerId]} = one(Conn,
                            "INSERT INTO global_banners(title,body,severity,starts_at,ends_at,dismissible,link_label,link_url,enabled,created_by,created_at,updated_at) "
                            "VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$11) RETURNING id",
                            [maps:get(title, Banner), maps:get(body, Banner), maps:get(severity, Banner),
                             maps:get(starts_at, Banner), maps:get(ends_at, Banner), maps:get(dismissible, Banner),
                             maps:get(link_label, Banner), maps:get(link_url, Banner), maps:get(enabled, Banner), ActorUid, Now]),
                        admin_audit_insert(Conn, ActorUid, <<"banner.created">>, <<"global_banner">>, integer_to_binary(BannerId),
                                           banner_audit_detail(Banner), <<>>, Now),
                        {ok, Banner#{id => BannerId, created_by => ActorUid, created_at => Now, updated_at => Now}}
                end
        end
    end);
route({admin_update_banner, ActorUid, BannerId0, Patch0}, Conn) ->
    case pw_util:int(BannerId0) of
        BannerId when is_integer(BannerId), BannerId > 0 ->
            with_tx(Conn, fun() ->
                case admin_can_operate(Conn, ActorUid) of
                    false -> {error, forbidden};
                    true ->
                        case one(Conn,
                            "SELECT title,body,severity,starts_at,ends_at,dismissible,link_label,link_url,enabled,updated_at "
                            "FROM global_banners WHERE id=$1 FOR UPDATE",
                            [BannerId]) of
                            {ok, ExistingRow} when is_list(ExistingRow), length(ExistingRow) =:= 10 ->
                                ExistingUpdatedAt = lists:nth(10, ExistingRow),
                                Patch = normalize_patch_keys(Patch0),
                                ExpectedUpdatedAt = pw_util:int(maps:get(<<"expected_updated_at">>, Patch, undefined)),
                                case ExpectedUpdatedAt =:= ExistingUpdatedAt of
                                    false -> {error, banner_conflict};
                                    true ->
                                        Existing = banner_patch_from_row(lists:sublist(ExistingRow, 9)),
                                        case normalize_banner_patch(maps:merge(Existing, Patch), pw_util:now_ms()) of
                                            {error, Reason} -> {error, Reason};
                                            {ok, Banner} ->
                                                %% updated_at doubles as the public banner revision used for
                                                %% dismissal invalidation. Keep it strictly monotonic even if
                                                %% two updates land inside the same millisecond.
                                                Now = max(pw_util:now_ms(), ExistingUpdatedAt + 1),
                                                ok = exec(Conn,
                                                    "UPDATE global_banners SET title=$2,body=$3,severity=$4,starts_at=$5,ends_at=$6,dismissible=$7,"
                                                    "link_label=$8,link_url=$9,enabled=$10,updated_at=$11 WHERE id=$1",
                                                    [BannerId, maps:get(title, Banner), maps:get(body, Banner), maps:get(severity, Banner),
                                                     maps:get(starts_at, Banner), maps:get(ends_at, Banner), maps:get(dismissible, Banner),
                                                     maps:get(link_label, Banner), maps:get(link_url, Banner), maps:get(enabled, Banner), Now]),
                                                admin_audit_insert(Conn, ActorUid, <<"banner.updated">>, <<"global_banner">>, integer_to_binary(BannerId),
                                                                   banner_audit_detail(Banner), <<>>, Now),
                                                {ok, Banner#{id => BannerId, updated_at => Now}}
                                        end
                                end;
                            _ -> {error, not_found}
                        end
                end
            end);
        _ -> {error, not_found}
    end;
route({admin_delete_banner, ActorUid, BannerId0, ExpectedUpdatedAt0}, Conn) ->
    BannerId = pw_util:int(BannerId0),
    ExpectedUpdatedAt = pw_util:int(ExpectedUpdatedAt0),
    case {BannerId, ExpectedUpdatedAt} of
        {Id, Revision} when is_integer(Id), Id > 0, is_integer(Revision), Revision > 0 ->
            with_tx(Conn, fun() ->
                case admin_can_operate(Conn, ActorUid) of
                    false -> {error, forbidden};
                    true ->
                        case one(Conn, "SELECT title,updated_at FROM global_banners WHERE id=$1 FOR UPDATE", [Id]) of
                            {ok, [_Title, CurrentUpdatedAt]} when CurrentUpdatedAt =/= Revision ->
                                {error, banner_conflict};
                            {ok, [Title, Revision]} ->
                                case one(Conn, "DELETE FROM global_banners WHERE id=$1 AND updated_at=$2 RETURNING id", [Id, Revision]) of
                                    {ok, [Id]} ->
                                        Now = pw_util:now_ms(),
                                        admin_audit_insert(Conn, ActorUid, <<"banner.deleted">>, <<"global_banner">>, integer_to_binary(Id),
                                                           pw_util:clean_text(Title, 80), <<>>, Now),
                                        {ok, #{deleted => true, id => Id}};
                                    _ -> {error, banner_conflict}
                                end;
                            _ -> {error, not_found}
                        end
                end
            end);
        _ -> {error, banner_conflict}
    end;
route(instance_registration_mode, Conn) ->
    case one(Conn, "SELECT value FROM instance_settings WHERE key='registration_mode'", []) of
        {ok, [RawMode]} ->
            case normalize_registration_mode(RawMode) of
                invalid -> {ok, <<"inherit">>};
                Mode -> {ok, Mode}
            end;
        _ -> {ok, <<"inherit">>}
    end;
route({admin_set_registration_mode, ActorUid, Mode0}, Conn) ->
    case normalize_registration_mode(Mode0) of
        invalid -> {error, invalid_registration_mode};
        Mode -> with_tx(Conn, fun() ->
            case admin_can_operate(Conn, ActorUid) of
                false -> {error, forbidden};
                true ->
                    Now = pw_util:now_ms(),
                    ok = exec(Conn,
                        "INSERT INTO instance_settings(key,value,updated_by,updated_at) VALUES('registration_mode',$1,$2,$3) "
                        "ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value,updated_by=EXCLUDED.updated_by,updated_at=EXCLUDED.updated_at",
                        [Mode, ActorUid, Now]),
                    admin_audit_insert(Conn, ActorUid, <<"service.registration_mode">>, <<"instance_setting">>, <<"registration_mode">>, Mode, <<>>, Now),
                    {ok, #{registration_mode => Mode}}
            end
        end)
    end;
route({register, U0, D0, P0}, Conn) ->
    U = pw_util:normalize_username(U0),
    D0b = pw_util:clean_text(D0, 48),
    P = pw_util:clean_text(P0, 256),
    D = case D0b of <<>> -> U; _ -> D0b end,
    case {byte_size(U) >= 3, byte_size(U) =< 24, byte_size(P) >= 10} of
        {true, true, true} ->
            Salt = pw_util:random_token(18),
            Hash = pw_util:pbkdf2(P, Salt),
            Now = pw_util:now_ms(),
            %% Let PostgreSQL arbitrate the unique username. A SELECT followed by
            %% INSERT races under simultaneous registrations for the same name.
            case rows(Conn,
                "INSERT INTO users(username,display_name,password_hash,password_salt,bio,avatar_url,banner_url,status,theme,created_at,updated_at,last_seen,onboarding_state,onboarding_step,onboarding_updated_at) "
                "VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) ON CONFLICT (username) DO NOTHING RETURNING id",
                [U, D, Hash, Salt, <<>>, <<>>, <<>>, <<>>, <<"system">>, Now, Now, Now, <<"pending">>, 0, Now]) of
                {ok, [[Id]]} -> {ok, make_session(Conn, Id)};
                {ok, []} -> {error, username_taken};
                {error, Reason} -> erlang:error({sql_error, Reason})
            end;
        _ ->
            {error, invalid_registration}
    end;
route({login, U0, P0}, Conn) ->
    U = pw_util:normalize_username(U0),
    P = pw_util:clean_text(P0, 256),
    case one(Conn,
        "SELECT id,password_hash,password_salt,account_state,moderation_title,moderation_reason,moderation_severity,moderation_expires_at,moderated_at "
        "FROM users WHERE username=$1", [U]) of
        {ok, [Id, Hash, Salt, AccountState0, Title, Reason, Severity, ExpiresAt, ModeratedAt]} ->
            case pw_util:verify_password(P, Salt, Hash) of
                true ->
                    maybe_upgrade_password_hash(Conn, Id, P, Hash),
                    Now = pw_util:now_ms(),
                    {AccountState, AutoRestored} = maybe_expire_account_restriction(Conn, Id, AccountState0, ExpiresAt, Now),
                    case AccountState of
                        <<"suspended">> ->
                            {error, {account_restricted, moderation_public_map(AccountState, Title, Reason, Severity, ExpiresAt, null, ModeratedAt)}};
                        <<"banned">> ->
                            {error, {account_restricted, moderation_public_map(AccountState, Title, Reason, Severity, ExpiresAt, null, ModeratedAt)}};
                        _ ->
                            Reactivated = AccountState =:= <<"disabled">>,
                            case Reactivated of
                                true -> ok = exec(Conn,
                                    "UPDATE users SET account_state='active',disabled_at=0,updated_at=$2 WHERE id=$1", [Id, Now]);
                                false -> ok
                            end,
                            Session = make_session(Conn, Id),
                            Extra = case {Reactivated, AutoRestored} of
                                {true, _} -> #{reactivated => true};
                                {false, true} -> #{restriction_expired => true};
                                _ -> #{}
                            end,
                            {ok, maps:merge(Session, Extra)}
                    end;
                false -> {error, bad_login}
            end;
        _ ->
            _ = pw_util:pbkdf2(P, <<"plainwire-login-timing-pad">>),
            {error, bad_login}
    end;
route({prune_sessions, Now}, Conn) ->
    ok = exec(Conn,
        "DELETE FROM sessions WHERE token_hash IN "
        "(SELECT token_hash FROM sessions WHERE expires_at <= $1 LIMIT 10000)",
        [Now]),
    ok = exec(Conn,
        "DELETE FROM admin_sessions WHERE token_hash IN "
        "(SELECT token_hash FROM admin_sessions WHERE expires_at <= $1 LIMIT 10000)",
        [Now]),
    ok = exec(Conn,
        "DELETE FROM admin_enrollments WHERE token_hash IN "
        "(SELECT token_hash FROM admin_enrollments WHERE expires_at <= $1 OR used_at IS NOT NULL LIMIT 10000)",
        [Now]),
    {ok, pruned};
route({session, Token}, Conn) ->
    case Token of
        undefined -> {error, no_session};
        <<>> -> {error, no_session};
        _ ->
            H = pw_util:sha256_hex(Token),
            Now = pw_util:now_ms(),
            Sql = "SELECT s.user_id, s.csrf, u.username, u.display_name, u.bio, u.avatar_url, "
                  "u.banner_url, u.status, u.theme, u.created_at, u.last_seen, s.expires_at "
                  "FROM sessions s JOIN users u ON u.id = s.user_id "
                  "WHERE s.token_hash = $1 AND s.expires_at > $2 AND u.account_state = 'active'",
            case one(Conn, Sql, [H, Now]) of
                {ok, [Uid, Csrf, Un, Dn, Bio, Av, Ban, St, Th, Cr, Ls, ExpiresAt]} ->
                    Cutoff = Now - 60000,
                    _ = exec(Conn, "UPDATE sessions SET last_seen = $1 WHERE token_hash = $2 AND last_seen < $3", [Now, H, Cutoff]),
                    _ = exec(Conn, "UPDATE users SET last_seen = $1 WHERE id = $2 AND last_seen < $3", [Now, Uid, Cutoff]),
                    Session = #{user => user_map_full([Uid, Un, Dn, Bio, Av, Ban, St, Th, Cr, Ls]),
                           csrf => Csrf, server_time => Now},
                    ets:insert(?SESSION_CACHE, {H, Session, session_cache_expiry(Now, ExpiresAt)}),
                    {ok, Session};
                {ok, undefined} ->
                    {error, no_session};
                {error, Reason} ->
                    erlang:error({sql_error, Reason})
            end
    end;
route({logout, Token}, Conn) ->
    H = pw_util:sha256_hex(Token),
    _ = exec(Conn, "DELETE FROM sessions WHERE token_hash = $1", [H]),
    ets:delete(?SESSION_CACHE, H),
    ok;
route({sessions, Uid, Token}, Conn) ->
    CurrentHash = pw_util:sha256_hex(Token),
    {ok, Rows} = rows(Conn,
        "SELECT id, token_hash, created_at, last_seen, expires_at FROM sessions WHERE user_id = $1 AND expires_at > $2 ORDER BY last_seen DESC",
        [Uid, pw_util:now_ms()]),
    {ok, [#{id => Id, current => Hash =:= CurrentHash, created_at => Created, last_seen => Seen, expires_at => Expires}
          || [Id, Hash, Created, Seen, Expires] <- Rows]};
route({logout_other_sessions, Uid, Token}, Conn) ->
    CurrentHash = pw_util:sha256_hex(Token),
    {ok, Existing} = rows(Conn, "DELETE FROM sessions WHERE user_id = $1 AND token_hash <> $2 RETURNING token_hash", [Uid, CurrentHash]),
    [ets:delete(?SESSION_CACHE, Hash) || [Hash] <- Existing],
    {ok, #{revoked => length(Existing)}};
route({change_password, Uid, Token, Current0, New0}, Conn) ->
    Current = pw_util:clean_text(Current0, 256),
    New = pw_util:clean_text(New0, 256),
    case byte_size(New) >= 10 andalso byte_size(New) =< 256 of
        false -> {error, weak_password};
        true ->
            CurrentHash = pw_util:sha256_hex(Token),
            case with_tx(Conn, fun() ->
                case one(Conn, "SELECT password_hash, password_salt FROM users WHERE id = $1 FOR UPDATE", [Uid]) of
                    {ok, [Hash, Salt]} ->
                        case pw_util:verify_password(Current, Salt, Hash) of
                            false -> {error, bad_password};
                            true ->
                                NewSalt = pw_util:random_token(18),
                                NewHash = pw_util:pbkdf2(New, NewSalt),
                                Now = pw_util:now_ms(),
                                ok = exec(Conn, "UPDATE users SET password_hash = $1, password_salt = $2, updated_at = $3 WHERE id = $4", [NewHash, NewSalt, Now, Uid]),
                                {ok, Existing} = rows(Conn, "DELETE FROM sessions WHERE user_id = $1 AND token_hash <> $2 RETURNING token_hash", [Uid, CurrentHash]),
                                {ok, Existing}
                        end;
                    _ -> {error, not_found}
                end
            end) of
                {ok, Existing} ->
                    [ets:delete(?SESSION_CACHE, SessionHash) || [SessionHash] <- Existing],
                    {ok, #{changed => true, revoked_sessions => length(Existing)}};
                Error -> Error
            end
    end;
route({change_username, Uid, Current0, NewUsername0, ExpectedUsername0}, Conn) ->
    Current = pw_util:clean_text(Current0, 256),
    NewUsername = pw_util:normalize_username(NewUsername0),
    ExpectedUsername = pw_util:normalize_username(ExpectedUsername0),
    case byte_size(NewUsername) >= 3 andalso byte_size(NewUsername) =< 24 andalso
         byte_size(ExpectedUsername) >= 3 andalso byte_size(ExpectedUsername) =< 24 of
        false -> {error, invalid_username};
        true ->
            Result = with_tx(Conn, fun() ->
                case one(Conn,
                    "SELECT username,password_hash,password_salt FROM users WHERE id=$1 FOR UPDATE", [Uid]) of
                    {ok, [CurrentUsername, PasswordHash, Salt]} ->
                        case pw_util:verify_password(Current, Salt, PasswordHash) of
                            false -> {error, bad_password};
                            true when CurrentUsername =/= ExpectedUsername ->
                                %% A second tab or device renamed this account after this
                                %% dialog opened. Do not silently overwrite the newer identity.
                                {error, username_changed_elsewhere};
                            true when CurrentUsername =:= NewUsername ->
                                {ok, #{changed => false, username => CurrentUsername}};
                            true ->
                                %% Serialize competing claims for the same normalized username.
                                %% The unique users(username) index remains the final DB invariant.
                                ok = exec(Conn, "SELECT pg_advisory_xact_lock(hashtextextended($1, 1347175753))", [NewUsername]),
                                case one(Conn, "SELECT id FROM users WHERE username=$1 AND id<>$2 LIMIT 1", [NewUsername, Uid]) of
                                    {ok, [_]} -> {error, username_taken};
                                    _ ->
                                        Now = pw_util:now_ms(),
                                        case rows(Conn,
                                            "UPDATE users SET username=$1,updated_at=$2 WHERE id=$3 AND username=$4 RETURNING username",
                                            [NewUsername, Now, Uid, ExpectedUsername]) of
                                            {ok, [[SavedUsername]]} ->
                                                {ok, #{changed => true, username => SavedUsername, previous_username => CurrentUsername}};
                                            {ok, []} -> {error, username_changed_elsewhere};
                                            {error, Reason} ->
                                                case is_unique_violation(Reason) of
                                                    true -> {error, username_taken};
                                                    false -> erlang:error({sql_error, Reason})
                                                end
                                        end
                                end
                        end;
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{changed := true, username := SavedUsername} = Data} ->
                    invalidate_session_cache(Uid),
                    best_effort_identity_changed(Conn, Uid, SavedUsername),
                    {ok, Data};
                Other -> Other
            end
    end;
route({onboarding, Uid}, Conn) ->
    case one(Conn,
        "SELECT onboarding_state, onboarding_step, onboarding_updated_at FROM users WHERE id = $1",
        [Uid]) of
        {ok, [State, Step, UpdatedAt]} ->
            {ok, #{state => State, step => Step, updated_at => UpdatedAt}};
        _ -> {error, not_found}
    end;
route({start_onboarding, Uid}, Conn) ->
    Now = pw_util:now_ms(),
    case one(Conn,
        "UPDATE users SET onboarding_state = 'active', onboarding_updated_at = $2 "
        "WHERE id = $1 AND onboarding_state IN ('pending','active') "
        "RETURNING onboarding_state, onboarding_step, onboarding_updated_at",
        [Uid, Now]) of
        {ok, [State, Step, UpdatedAt]} -> {ok, #{state => State, step => Step, updated_at => UpdatedAt}};
        _ -> route({onboarding, Uid}, Conn)
    end;
route({update_onboarding, Uid, Step0}, Conn) ->
    Step = pw_util:int(Step0),
    case is_integer(Step) andalso Step >= 0 andalso Step =< 64 of
        false -> {error, invalid_step};
        true ->
            Now = pw_util:now_ms(),
            case one(Conn,
                "UPDATE users SET onboarding_state = 'active', onboarding_step = $2, onboarding_updated_at = $3 "
                "WHERE id = $1 AND onboarding_state IN ('pending','active') "
                "RETURNING onboarding_state, onboarding_step, onboarding_updated_at",
                [Uid, Step, Now]) of
                {ok, [State, SavedStep, UpdatedAt]} ->
                    {ok, #{state => State, step => SavedStep, updated_at => UpdatedAt}};
                _ -> {error, onboarding_not_active}
            end
    end;
route({complete_onboarding, Uid}, Conn) ->
    Now = pw_util:now_ms(),
    case one(Conn,
        "UPDATE users SET onboarding_state = 'complete', onboarding_updated_at = $2 WHERE id = $1 "
        "RETURNING onboarding_state, onboarding_step, onboarding_updated_at",
        [Uid, Now]) of
        {ok, [State, Step, UpdatedAt]} -> {ok, #{state => State, step => Step, updated_at => UpdatedAt}};
        _ -> {error, not_found}
    end;
route({dismiss_onboarding, Uid}, Conn) ->
    Now = pw_util:now_ms(),
    case one(Conn,
        "UPDATE users SET onboarding_state = 'dismissed', onboarding_updated_at = $2 WHERE id = $1 "
        "RETURNING onboarding_state, onboarding_step, onboarding_updated_at",
        [Uid, Now]) of
        {ok, [State, Step, UpdatedAt]} -> {ok, #{state => State, step => Step, updated_at => UpdatedAt}};
        _ -> {error, not_found}
    end;
route({replay_onboarding, Uid}, Conn) ->
    Now = pw_util:now_ms(),
    case one(Conn,
        "UPDATE users SET onboarding_state = 'active', onboarding_step = 0, onboarding_updated_at = $2 WHERE id = $1 "
        "RETURNING onboarding_state, onboarding_step, onboarding_updated_at",
        [Uid, Now]) of
        {ok, [State, Step, UpdatedAt]} -> {ok, #{state => State, step => Step, updated_at => UpdatedAt}};
        _ -> {error, not_found}
    end;
route({disable_account, Uid, Password0}, Conn) ->
    Password = pw_util:clean_text(Password0, 256),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT password_hash,password_salt,account_state FROM users WHERE id=$1 FOR UPDATE", [Uid]) of
            {ok, [Hash, Salt, <<"active">>]} ->
                case pw_util:verify_password(Password, Salt, Hash) of
                    false -> {error, bad_password};
                    true ->
                        Now = pw_util:now_ms(),
                        ok = exec(Conn, "UPDATE users SET account_state='disabled',disabled_at=$2,updated_at=$2 WHERE id=$1", [Uid, Now]),
                        {ok, SessionRows} = rows(Conn, "DELETE FROM sessions WHERE user_id=$1 RETURNING token_hash", [Uid]),
                        {ok, #{disabled => true, session_hashes => [only_id(R) || R <- SessionRows]}}
                end;
            {ok, [_Hash, _Salt, <<"disabled">>]} -> {ok, #{disabled => true, session_hashes => []}};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{session_hashes := Hashes} = Data} ->
            [ets:delete(?SESSION_CACHE, H) || H <- Hashes],
            pw_redis:presence_delete(Uid),
            pw_hub:notify_user(Uid, #{type => account_disabled}),
            {ok, maps:remove(session_hashes, Data)};
        Other -> Other
    end;
route({delete_account, Uid, Password0}, Conn) ->
    Password = pw_util:clean_text(Password0, 256),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT password_hash,password_salt FROM users WHERE id=$1 FOR UPDATE", [Uid]) of
            {ok, [Hash, Salt]} ->
                case pw_util:verify_password(Password, Salt, Hash) of
                    false -> {error, bad_password};
                    true ->
                        {ok, SessionRows} = rows(Conn, "SELECT token_hash FROM sessions WHERE user_id=$1", [Uid]),
                        ok = enqueue_upload_deletes_for_user(Conn, Uid),
                        ok = enqueue_scylla_hard_deletes_for_user(Conn, Uid),
                        %% Webhook delivery payloads can contain authored message text or
                        %% moderation actor/subject IDs. Remove any delivery that belongs
                        %% to the erased account before the user row disappears. Terminal
                        %% deliveries normally have their payload bytes wiped immediately,
                        %% but deleting the row also removes the remaining metadata link.
                        ok = exec(Conn, "DELETE FROM webhook_deliveries WHERE subject_user_id=$1 OR actor_user_id=$1", [Uid]),
                        ok = prepare_owned_servers_for_account_delete(Conn, Uid),
                        ok = prepare_owned_conversations_for_account_delete(Conn, Uid),
                        ok = prepare_owned_forums_for_account_delete(Conn, Uid),
                        %% Remove authored content that has restrictive user FKs. This is
                        %% a true erase: no tombstone user row or ghost profile remains.
                        ok = exec(Conn, "DELETE FROM server_invites WHERE creator_id=$1", [Uid]),
                        %% requester_id/addressee_id are intentionally restrictive FKs even though
                        %% the canonical friendship pair cascades. Delete explicitly so erasure is
                        %% independent of PostgreSQL FK execution order.
                        ok = exec(Conn, "DELETE FROM friendships WHERE user_low=$1 OR user_high=$1 OR requester_id=$1 OR addressee_id=$1", [Uid]),
                        ok = exec(Conn, "DELETE FROM replies WHERE user_id=$1", [Uid]),
                        ok = exec(Conn, "DELETE FROM threads WHERE user_id=$1", [Uid]),
                        ok = exec(Conn, "UPDATE messages SET reply_to_id=NULL WHERE reply_to_id IN (SELECT id FROM messages WHERE user_id=$1)", [Uid]),
                        ok = exec(Conn, "DELETE FROM messages WHERE user_id=$1", [Uid]),
                        ok = exec(Conn, "DELETE FROM users WHERE id=$1", [Uid]),
                        {ok, #{deleted => true,
                               session_hashes => [only_id(R) || R <- SessionRows]}}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{session_hashes := Hashes} = Data} ->
            [ets:delete(?SESSION_CACHE, H) || H <- Hashes],
            pw_redis:presence_delete(Uid),
            pw_upload_gc:invalidate_user(Uid),
            pw_upload_gc:wake(),
            pw_hub:notify_user(Uid, #{type => account_deleted}),
            {ok, maps:remove(session_hashes, Data)};
        Other -> Other
    end;
route({me, Uid}, Conn) ->
    case one(Conn,
        "SELECT id, username, display_name, bio, avatar_url, banner_url, status, theme, created_at, last_seen, is_bot "
        "FROM users WHERE id = $1", [Uid]) of
        {ok, [Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, LastSeen, IsBot]} ->
            {ok, (user_map_full([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, LastSeen]))#{is_bot => IsBot =:= true}};
        _ -> {error, not_found}
    end;
route({update_profile, Uid, Display0, Patch}, Conn) ->
    Result = with_tx(Conn, fun() ->
        Display = pw_util:clean_text(Display0, 48),
        Bio = pw_util:clean_text(maps:get(<<"bio">>, Patch, <<>>), 600),
        {CurrentAvatar, CurrentBanner} = current_profile_images(Conn, Uid),
        Avatar = store_profile_image(maps:get(<<"avatar_url">>, Patch, <<>>), CurrentAvatar, Conn, Uid),
        Banner = store_profile_image(maps:get(<<"banner_url">>, Patch, <<>>), CurrentBanner, Conn, Uid),
        Status = pw_util:clean_text(maps:get(<<"status">>, Patch, <<>>), 100),
        Theme = normalize_theme(maps:get(<<"theme">>, Patch, <<"system">>)),
        Now = pw_util:now_ms(),
        ok = exec(Conn,
            "UPDATE users SET display_name = $1, bio = $2, avatar_url = $3, banner_url = $4, "
            "status = $5, theme = $6, updated_at = $7 WHERE id = $8",
            [Display, Bio, Avatar, Banner, Status, Theme, Now, Uid]),
        sync_profile_upload_refs(Conn, Uid, Avatar, Banner, Now),
        {ok, #{updated => true}}
    end),
    case Result of
        {ok, _} -> invalidate_session_cache(Uid);
        _ -> ok
    end,
    Result;
route({update_theme, Uid, Theme0}, Conn) ->
    Theme = normalize_theme(Theme0),
    ok = exec(Conn, "UPDATE users SET theme = $1, updated_at = $2 WHERE id = $3",
        [Theme, pw_util:now_ms(), Uid]),
    invalidate_session_cache(Uid),
    {ok, #{theme => Theme}};
route({sync, Uid, Since0}, Conn) ->
    Since = case pw_util:int(Since0) of undefined -> 0; I -> I end,
    %% Bootstrap must not be all-or-nothing. A malformed legacy row or a
    %% permanent query/schema bug in one panel used to turn /api/sync into a
    %% blank-app 500 and then make the reconnecting WebSocket look logged out.
    %% Keep transient database failures fatal so the outer reconnect/retry path
    %% still does the right thing; isolate only permanent component failures.
    {Notifs, W1} = sync_component(notifications, [], fun() ->
        case Since > 0 of
            true ->
                case rows(Conn, "SELECT id, kind, body, url, seen, created_at FROM notifications WHERE user_id = $1 AND created_at > $2 ORDER BY id DESC LIMIT 120", [Uid, Since]) of
                    {ok, Rows} -> {ok, [notification_map(R) || R <- Rows]};
                    {error, Reason} -> erlang:error({sql_error, Reason})
                end;
            false -> route({notifications, Uid}, Conn)
        end
    end),
    {Convs, W2} = sync_component(conversations, [], fun() -> route({conversations, Uid}, Conn) end),
    {Servers, W3} = sync_component(servers, [], fun() -> route({servers, Uid}, Conn) end),
    {Friends, W4} = sync_component(friends, [], fun() -> route({friends, Uid}, Conn) end),
    Warnings = W1 ++ W2 ++ W3 ++ W4,
    {ok, #{now => pw_util:now_ms(), since => Since,
          notifications => Notifs, conversations => Convs,
          servers => Servers, friends => Friends,
          sync_degraded => (Warnings =/= []), sync_warnings => Warnings}};
route({users, Q0}, Conn) ->
    Q = pw_util:clean_text(Q0, 80),
    case byte_size(Q) >= 2 of
        false ->
            {ok, []};
        true ->
            Like = <<"%", Q/binary, "%">>,
            {ok, Rows} = rows(Conn,
                "SELECT id, username, display_name, bio, avatar_url, banner_url, status, theme, created_at, last_seen, is_bot "
                "FROM users WHERE is_bot=false AND (username ILIKE $1 OR display_name ILIKE $2) "
                "ORDER BY last_seen DESC LIMIT 40", [Like, Like]),
            {ok, map_rows_resilient(users, Rows, fun user_map/1)}
    end;
route({profile, Viewer, UserId0}, Conn) ->
    UserId = pw_util:int(UserId0),
    case route({me, UserId}, Conn) of
        {ok, U} ->
            Rel = friendship_status(Conn, Viewer, UserId),
            %% source URLs are private edit state, and data URLs can be huge.
            Public = maps:without([avatar_source_url, banner_source_url], U),
            {ok, #{user => Public, relationship => Rel}};
        E ->
            E
    end;
route({profile_by_username, Viewer, Username0}, Conn) ->
    Username = string:lowercase(pw_util:clean_text(Username0, 32)),
    case one(Conn, "SELECT id FROM users WHERE lower(username) = $1 LIMIT 1", [Username]) of
        {ok, [UserId]} -> route({profile, Viewer, UserId}, Conn);
        _ -> {error, not_found}
    end;
route({friend_request, Uid, Target0}, Conn) ->
    Target = pw_util:int(Target0),
    case Target of
        Uid -> {error, cannot_friend_self};
        undefined -> {error, invalid_user};
        _ ->
            {A, B} = pair(Uid, Target),
            Now = pw_util:now_ms(),
            case one(Conn, "SELECT id FROM users WHERE id = $1", [Target]) of
                {ok, [_]} ->
                    case one(Conn, "SELECT status FROM friendships WHERE user_low = $1 AND user_high = $2", [A, B]) of
                        {ok, [<<"accepted">>]} ->
                            {ok, #{status => accepted}};
                        {ok, [<<"blocked">>]} ->
                            {error, forbidden};
                        _ ->
                            Sql = "INSERT INTO friendships(user_low, user_high, requester_id, addressee_id, status, created_at, updated_at) "
                                  "VALUES($1,$2,$3,$4,$5,$6,$7) "
                                  "ON CONFLICT (user_low, user_high) DO UPDATE SET "
                                  "requester_id = EXCLUDED.requester_id, addressee_id = EXCLUDED.addressee_id, "
                                  "status = 'pending', updated_at = EXCLUDED.updated_at",
                            ok = exec(Conn, Sql, [A, B, Uid, Target, <<"pending">>, Now, Now]),
                            best_effort_user_notification(Conn, Target, <<"friend_request">>, <<"New friend request">>, <<"#/friends">>, Now,
                                #{type => friend_request, from_user_id => Uid}),
                            {ok, #{status => pending}}
                    end;
                _ ->
                    {error, invalid_user}
            end
    end;
route({friend_accept, Uid, Target0}, Conn) ->
    Target = pw_util:int(Target0),
    case Target of
        undefined -> {error, invalid_user};
        _ ->
            {A, B} = pair(Uid, Target),
            Now = pw_util:now_ms(),
            case one(Conn, "SELECT status, requester_id, addressee_id FROM friendships WHERE user_low = $1 AND user_high = $2", [A, B]) of
                {ok, [<<"pending">>, Target, Uid]} ->
                    ok = exec(Conn, "UPDATE friendships SET status = 'accepted', updated_at = $1 WHERE user_low = $2 AND user_high = $3", [Now, A, B]),
                    ok = exec(Conn,
                        "UPDATE direct_members SET request_state = 'accepted' WHERE user_id = $1 AND request_state = 'pending' "
                        "AND thread_id IN (SELECT dm1.thread_id FROM direct_members dm1 JOIN direct_members dm2 ON dm2.thread_id = dm1.thread_id "
                        "WHERE dm1.user_id = $1 AND dm2.user_id = $2 AND (SELECT count(*) FROM direct_members dmc WHERE dmc.thread_id = dm1.thread_id) = 2)",
                        [Uid, Target]),
                    best_effort_user_notification(Conn, Target, <<"friend_accept">>, <<"Friend request accepted">>, <<"#/friends">>, Now,
                        #{type => friend_accept, user_id => Uid}),
                    {ok, #{status => accepted}};
                {ok, [<<"accepted">>, _, _]} ->
                    {ok, #{status => accepted}};
                _ ->
                    {error, no_pending_request}
            end
    end;
route({friend_remove, Uid, Target0}, Conn) ->
    Target = pw_util:int(Target0),
    case Target of
        undefined -> {error, invalid_user};
        Uid -> {error, invalid_user};
        _ ->
            {A, B} = pair(Uid, Target),
            %% Generic remove/decline/cancel must never undo a block. Unblocking
            %% is ownership checked separately so another user cannot erase it.
            case one(Conn, "SELECT status FROM friendships WHERE user_low = $1 AND user_high = $2", [A, B]) of
                {ok, [<<"blocked">>]} -> {error, forbidden};
                {ok, [_]} ->
                    ok = exec(Conn, "DELETE FROM friendships WHERE user_low = $1 AND user_high = $2 AND status <> 'blocked'", [A, B]),
                    {ok, #{removed => true}};
                _ -> {ok, #{removed => false}}
            end
    end;
route({friend_block, Uid, Target0}, Conn) ->
    Target = pw_util:int(Target0),
    case Target of
        undefined -> {error, invalid_user};
        Uid -> {error, cannot_block_self};
        _ ->
            {A, B} = pair(Uid, Target),
            Now = pw_util:now_ms(),
            Sql = "INSERT INTO friendships(user_low, user_high, requester_id, addressee_id, status, created_at, updated_at) "
                  "VALUES($1,$2,$3,$4,$5,$6,$7) "
                  "ON CONFLICT (user_low, user_high) DO UPDATE SET "
                  "requester_id = EXCLUDED.requester_id, addressee_id = EXCLUDED.addressee_id, "
                  "status = 'blocked', updated_at = EXCLUDED.updated_at",
            ok = exec(Conn, Sql, [A, B, Uid, Target, <<"blocked">>, Now, Now]),
            pw_upload_gc:invalidate_user(Uid),
            pw_upload_gc:invalidate_user(Target),
            {ok, #{status => blocked}}
    end;
route({friend_unblock, Uid, Target0}, Conn) ->
    Target = pw_util:int(Target0),
    case Target of
        undefined -> {error, invalid_user};
        Uid -> {error, cannot_unblock_self};
        _ ->
            {A, B} = pair(Uid, Target),
            %% only the blocker gets to undo the block. seems fair.
            case one(Conn,
                "SELECT requester_id FROM friendships WHERE user_low = $1 AND user_high = $2 AND status = 'blocked'",
                [A, B]) of
                {ok, [Uid]} ->
                    ok = exec(Conn, "DELETE FROM friendships WHERE user_low = $1 AND user_high = $2", [A, B]),
                    %% Blocking removes direct-scope attachment access. Drop both
                    %% parties' cached decisions when that access is restored too.
                    pw_upload_gc:invalidate_user(Uid),
                    pw_upload_gc:invalidate_user(Target),
                    {ok, #{status => none}};
                _ -> {error, forbidden}
            end
    end;
route({friends, Uid}, Conn) ->
    Sql = "SELECT fr.status, fr.requester_id, fr.addressee_id, u.id, u.username, u.display_name, "
          "u.bio, u.avatar_url, u.banner_url, u.status, u.theme, u.created_at, u.last_seen "
          "FROM friendships fr JOIN users u ON u.id = CASE WHEN fr.user_low = $1 THEN fr.user_high ELSE fr.user_low END "
          "WHERE (fr.user_low = $1 OR fr.user_high = $1) "
          "AND (fr.status <> 'blocked' OR fr.requester_id = $1) ORDER BY fr.updated_at DESC",
    {ok, Rows} = rows(Conn, Sql, [Uid]),
    {ok, map_rows_resilient(friends, Rows, fun(R) -> friend_map(R, Uid) end)};
route({forums, Uid}, Conn) ->
    Sql = "SELECT f.id, f.slug, f.name, f.description, f.position, f.owner_id, "
           "(SELECT count(*) FROM threads t WHERE t.forum_id = f.id), "
           "(SELECT count(*) FROM replies r JOIN threads t2 ON t2.id = r.thread_id WHERE t2.forum_id = f.id), "
          "(SELECT max(updated_at) FROM threads t3 WHERE t3.forum_id = f.id), "
          "(SELECT count(*) FROM forum_members fm WHERE fm.forum_id = f.id), "
          "EXISTS(SELECT 1 FROM forum_members fm2 WHERE fm2.forum_id = f.id AND fm2.user_id = $1) "
          "FROM forums f ORDER BY f.position ASC, lower(f.name) ASC",
    {ok, Rows} = rows(Conn, Sql, [Uid]),
    {ok, [forum_map(R) || R <- Rows]};
route({create_forum, Uid, Name0, Slug0, Desc0}, Conn) ->
    Name = pw_util:clean_text(Name0, 80),
    Slug = clean_slug(Slug0, Name),
    Desc = pw_util:clean_text(Desc0, 280),
    case byte_size(Name) >= 2 andalso byte_size(Slug) >= 2 of
        false -> {error, invalid_forum};
        true ->
            with_tx(Conn, fun() ->
                case one(Conn, "SELECT id FROM forums WHERE lower(slug) = lower($1) LIMIT 1", [Slug]) of
                    {ok, [_]} -> {error, forum_exists};
                    _ ->
                        Pos = forum_position(Conn),
                        Now = pw_util:now_ms(),
                        {ok, Fid} = insert_returning(Conn,
                            "INSERT INTO forums(slug, name, description, position, owner_id) VALUES($1,$2,$3,$4,$5) RETURNING id",
                            [Slug, Name, Desc, Pos, Uid]),
                        ok = exec(Conn, "INSERT INTO forum_members(forum_id, user_id, joined_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [Fid, Uid, Now]),
                        {ok, #{id => Fid}}
                end
            end)
    end;
route({delete_forum, Uid, ForumId0}, Conn) ->
    ForumId = pw_util:int(ForumId0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT owner_id FROM forums WHERE id = $1 FOR UPDATE", [ForumId]) of
            {ok, [Uid]} ->
                {ok, ThreadRows} = rows(Conn, "SELECT id FROM threads WHERE forum_id = $1", [ForumId]),
                ok = exec(Conn,
                    "DELETE FROM notifications WHERE url IN "
                    "(SELECT '#/thread/' || id::text FROM threads WHERE forum_id = $1) "
                    "OR url IN (SELECT '#/t/' || id::text FROM threads WHERE forum_id = $1)", [ForumId]),
                [remove_scope_upload_refs(Conn, <<"thread">>, only_id(Row)) || Row <- ThreadRows],
                ok = exec(Conn, "DELETE FROM forums WHERE id = $1", [ForumId]),
                {ok, #{deleted => true, id => ForumId,
                    deleted_thread_ids => [only_id(Row) || Row <- ThreadRows]}};
            {ok, [_]} -> {error, forbidden};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{deleted_thread_ids := ThreadIds} = Data} ->
            DeletedEvent = #{type => forum_deleted, forum_id => ForumId},
            pw_hub:broadcast({forum, ForumId}, DeletedEvent),
            [pw_hub:broadcast({thread, ThreadId}, DeletedEvent) || ThreadId <- ThreadIds],
            {ok, maps:remove(deleted_thread_ids, Data)};
        Other -> Other
    end;
route({join_forum, Uid, ForumId0}, Conn) ->
    ForumId = pw_util:int(ForumId0),
    case one(Conn, "SELECT id FROM forums WHERE id = $1", [ForumId]) of
        {ok, [_]} ->
            ok = exec(Conn, "INSERT INTO forum_members(forum_id, user_id, joined_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [ForumId, Uid, pw_util:now_ms()]),
            {ok, #{id => ForumId}};
        _ -> {error, not_found}
    end;
route({leave_forum, Uid, ForumId0}, Conn) ->
    ForumId = pw_util:int(ForumId0),
    case one(Conn, "SELECT owner_id FROM forums WHERE id = $1", [ForumId]) of
        {ok, [Uid]} ->
            %% A forum cannot be left ownerless. Owners can delete the forum;
            %% ownership transfer can be added as a separate explicit action.
            {error, forum_owner_cannot_leave};
        {ok, [_]} ->
            case is_forum_member(Conn, Uid, ForumId) of
                true ->
                    ok = exec(Conn, "DELETE FROM forum_members WHERE forum_id = $1 AND user_id = $2", [ForumId, Uid]),
                    {ok, #{id => ForumId, left => true}};
                false ->
                    {ok, #{id => ForumId, left => false}}
            end;
        _ -> {error, not_found}
    end;
route({threads, Uid, ForumId0, Search0}, Conn) ->
    ForumId = pw_util:int(ForumId0),
    Search = pw_util:clean_text(Search0, 80),
    {Sql, Params0} = thread_sql(ForumId, Search),
    Params = [Uid | Params0],
    {ok, Rows} = rows(Conn, Sql, Params),
    {ok, [thread_row_map(R) || R <- Rows]};
route({thread, Uid, ThreadId0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    _ = record_thread_view(Conn, ThreadId, Uid),
    Sql1 = "SELECT t.id, t.forum_id, f.name, t.user_id, u.username, u.display_name, u.avatar_url, "
           "t.title, t.body, COALESCE(NULLIF(t.raw_body,''),t.body), t.created_at, t.updated_at, t.reply_count, t.locked, t.pinned, t.views, "
           "COALESCE(t.score,0), COALESCE(tv.value,0) "
           "FROM threads t JOIN forums f ON f.id = t.forum_id JOIN users u ON u.id = t.user_id "
           "LEFT JOIN thread_votes tv ON tv.thread_id = t.id AND tv.user_id = $2 WHERE t.id = $1",
    case one(Conn, Sql1, [ThreadId, Uid]) of
        {ok, T} when is_list(T) ->
            {ok, Rs} = rows(Conn,
                "SELECT r.id, r.thread_id, r.user_id, u.username, u.display_name, u.avatar_url, "
                "r.body, COALESCE(NULLIF(r.raw_body,''),r.body), r.created_at, r.updated_at FROM replies r JOIN users u ON u.id = r.user_id "
                "WHERE r.thread_id = $1 ORDER BY r.created_at ASC LIMIT 800", [ThreadId]),
            _ = mark_url_seen0(Conn, Uid, <<"#/t/", (integer_to_binary(ThreadId))/binary>>),
            Thread0 = thread_full_map(T),
            ForumId = maps:get(forum_id, Thread0),
            AuthorId = maps:get(user_id, Thread0),
            ForumOwnerId = case one(Conn, "SELECT owner_id FROM forums WHERE id = $1", [ForumId]) of
                {ok, [OwnerId]} -> OwnerId;
                _ -> undefined
            end,
            CanModerate = is_integer(ForumOwnerId) andalso Uid =:= ForumOwnerId,
            Joined = is_forum_member(Conn, Uid, ForumId),
            Thread = Thread0#{
                can_edit => Uid =:= AuthorId andalso Joined,
                can_delete => (Uid =:= AuthorId andalso Joined) orelse CanModerate,
                can_moderate => CanModerate,
                viewer_joined => Joined
            },
            Replies = [begin
                Reply0 = reply_map(R),
                ReplyAuthor = maps:get(user_id, Reply0),
                Reply0#{can_edit => Uid =:= ReplyAuthor andalso Joined,
                        can_delete => (Uid =:= ReplyAuthor andalso Joined) orelse CanModerate}
            end || R <- Rs],
            {ok, #{thread => Thread, replies => Replies}};
        _ ->
            {error, not_found}
    end;
route({create_thread, Uid, ForumId0, Title0, Body0}, Conn) ->
    ForumId = pw_util:int(ForumId0),
    Title = pw_util:clean_text(Title0, 160),
    Body = pw_util:clean_text(Body0, ?MAX_BODY),
    Result = with_tx(Conn, fun() ->
        case validate_thread(Conn, Uid, ForumId, Title, Body) of
            ok ->
                %% Serialize against forum deletion and membership changes.
                case one(Conn, "SELECT id FROM forums WHERE id = $1 FOR UPDATE", [ForumId]) of
                    {ok, [_]} ->
                        case is_forum_member(Conn, Uid, ForumId) of
                            false -> {error, forum_membership_required};
                            true ->
                                Now = pw_util:now_ms(),
                                {ok, Tid} = insert_returning(Conn,
                                    "INSERT INTO threads(forum_id, user_id, title, body, raw_body, created_at, updated_at, reply_count, locked, pinned, views) "
                                    "VALUES($1,$2,$3,$4,$4,$5,$6,0,false,false,0) RETURNING id",
                                    [ForumId, Uid, Title, Body, Now, Now]),
                                insert_upload_refs(Conn, Body, <<"thread">>, Tid, Now),
                                {ok, #{id => Tid}}
                        end;
                    _ -> {error, not_found}
                end;
            Err -> Err
        end
    end),
    case Result of
        {ok, #{id := Tid}} ->
            pw_hub:broadcast({forum, ForumId}, #{type => thread_created, thread_id => Tid, forum_id => ForumId}),
            Result;
        _ -> Result
    end;
route({edit_thread, Uid, ThreadId0, Title0, Body0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    Title = pw_util:clean_text(Title0, 160),
    Body = pw_util:clean_text(Body0, ?MAX_BODY),
    case byte_size(Title) >= 3 andalso byte_size(Body) > 0 of
        false -> {error, invalid_thread};
        true ->
            Result = with_tx(Conn, fun() ->
                case one(Conn, "SELECT user_id,forum_id,COALESCE(NULLIF(raw_body,''),body) FROM threads WHERE id = $1 FOR UPDATE", [ThreadId]) of
                    {ok, [Uid, ForumId, OldBody]} ->
                        case is_forum_member(Conn, Uid, ForumId) of
                            false -> {error, forum_membership_required};
                            true ->
                                Now = pw_util:now_ms(),
                                ok = exec(Conn, "UPDATE threads SET title=$1,body=$2,raw_body=$2,updated_at=$3 WHERE id=$4", [Title, Body, Now, ThreadId]),
                                case removed_upload_refs(OldBody, Body) of
                                    [] -> insert_upload_refs(Conn, Body, <<"thread">>, ThreadId, Now);
                                    _ -> sync_thread_upload_refs(Conn, ThreadId, Now)
                                end,
                                {ok, #{updated => true, id => ThreadId, forum_id => ForumId}}
                        end;
                    {ok, [_Author, _Forum, _Old]} -> {error, forbidden};
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{forum_id := ForumId} = Data} ->
                    Event = #{type => thread_updated, thread_id => ThreadId, forum_id => ForumId},
                    pw_hub:broadcast({thread, ThreadId}, Event),
                    pw_hub:broadcast({forum, ForumId}, Event),
                    {ok, maps:remove(forum_id, Data)};
                Other -> Other
            end
    end;
route({moderate_thread, Uid, ThreadId0, Action0, Value0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0), Action = pw_util:clean_text(Action0, 16), Value = pw_util:bool(Value0),
    Result = with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT t.forum_id,f.owner_id FROM threads t JOIN forums f ON f.id=t.forum_id WHERE t.id=$1 FOR UPDATE", [ThreadId]) of
            {ok, [ForumId, Uid]} ->
                Column = case Action of
                    <<"lock">> -> locked;
                    <<"locked">> -> locked;
                    <<"pin">> -> pinned;
                    <<"pinned">> -> pinned;
                    _ -> invalid
                end,
                case Column of
                    invalid -> {error, invalid_action};
                    locked -> ok = exec(Conn, "UPDATE threads SET locked=$1,updated_at=$2 WHERE id=$3", [Value,pw_util:now_ms(),ThreadId]), {ok, #{updated=>true,locked=>Value,forum_id=>ForumId}};
                    pinned -> ok = exec(Conn, "UPDATE threads SET pinned=$1,updated_at=$2 WHERE id=$3", [Value,pw_util:now_ms(),ThreadId]), {ok, #{updated=>true,pinned=>Value,forum_id=>ForumId}}
                end;
            {ok, _} -> {error, forbidden};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{forum_id := ForumId} = Data} ->
            Event = #{type => thread_updated, thread_id => ThreadId, forum_id => ForumId},
            pw_hub:broadcast({thread, ThreadId}, Event), pw_hub:broadcast({forum, ForumId}, Event),
            {ok, maps:remove(forum_id, Data)};
        Other -> Other
    end;
route({delete_thread, Uid, ThreadId0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    Result = with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT t.user_id,f.owner_id,t.forum_id FROM threads t "
            "JOIN forums f ON f.id = t.forum_id WHERE t.id = $1 FOR UPDATE", [ThreadId]) of
            {ok, [AuthorId, ForumOwnerId, ForumId]} ->
                Joined = is_forum_member(Conn, Uid, ForumId),
                case Uid =:= ForumOwnerId orelse (Uid =:= AuthorId andalso Joined) of
                    true ->
                        OldUrl = <<"#/thread/", (integer_to_binary(ThreadId))/binary>>,
                        NewUrl = <<"#/t/", (integer_to_binary(ThreadId))/binary>>,
                        ok = exec(Conn, "DELETE FROM notifications WHERE url = $1 OR url = $2", [OldUrl, NewUrl]),
                        remove_scope_upload_refs(Conn, <<"thread">>, ThreadId),
                        ok = exec(Conn, "DELETE FROM threads WHERE id = $1", [ThreadId]),
                        {ok, #{deleted => true, id => ThreadId, forum_id => ForumId}};
                    false when Uid =:= AuthorId -> {error, forum_membership_required};
                    false -> {error, forbidden}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{forum_id := ForumId} = Data} ->
            DeletedEvent = #{type => thread_deleted, forum_id => ForumId, thread_id => ThreadId},
            pw_hub:broadcast({forum, ForumId}, DeletedEvent),
            %% readers follow the thread key too. tell both after commit.
            pw_hub:broadcast({thread, ThreadId}, DeletedEvent),
            {ok, Data};
        Other -> Other
    end;
route({reply_thread, Uid, ThreadId0, Body0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    Body = pw_util:clean_text(Body0, ?MAX_BODY),
    case byte_size(Body) > 0 of
        false -> {error, invalid_reply};
        true ->
            Result = with_tx(Conn, fun() ->
                case one(Conn,
                    "SELECT t.locked,t.forum_id,EXISTS(SELECT 1 FROM forum_members fm WHERE fm.forum_id=t.forum_id AND fm.user_id=$2) "
                    "FROM threads t WHERE t.id=$1 FOR UPDATE", [ThreadId, Uid]) of
                    {ok, [true, _ForumId, _Joined]} -> {error, thread_locked};
                    {ok, [false, _ForumId, false]} -> {error, forum_membership_required};
                    {ok, [false, _ForumId, true]} ->
                        Now = pw_util:now_ms(),
                        {ok, Rid} = insert_returning(Conn,
                            "INSERT INTO replies(thread_id, user_id, body, raw_body, created_at, updated_at) VALUES($1,$2,$3,$3,$4,$5) RETURNING id",
                            [ThreadId, Uid, Body, Now, Now]),
                        insert_upload_refs(Conn, Body, <<"thread">>, ThreadId, Now),
                        ok = exec(Conn, "UPDATE threads SET updated_at=$1,reply_count=(SELECT count(*) FROM replies WHERE thread_id=$2) WHERE id=$2", [Now, ThreadId]),
                        {ok, Row} = one(Conn,
                            "SELECT r.id,r.thread_id,r.user_id,u.username,u.display_name,u.avatar_url,r.body,COALESCE(NULLIF(r.raw_body,''),r.body),r.created_at,r.updated_at "
                            "FROM replies r JOIN users u ON u.id=r.user_id WHERE r.id=$1", [Rid]),
                        {ok, #{reply => reply_map(Row), notify_at => Now}};
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{reply := Reply, notify_at := Now}} ->
                    best_effort_thread_notifications(Conn, ThreadId, Uid, Body, Now),
                    pw_hub:broadcast({thread, ThreadId}, #{type => thread_reply, thread_id => ThreadId, reply => Reply}),
                    {ok, Reply};
                Other -> Other
            end
    end;
route({edit_reply, Uid, ThreadId0, ReplyId0, Body0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0), ReplyId = pw_util:int(ReplyId0), Body = pw_util:clean_text(Body0, ?MAX_BODY),
    case byte_size(Body) > 0 of
        false -> {error, invalid_reply};
        true ->
            Result = with_tx(Conn, fun() ->
                case one(Conn,
                    "SELECT r.user_id,t.forum_id,COALESCE(NULLIF(r.raw_body,''),r.body) FROM replies r "
                    "JOIN threads t ON t.id=r.thread_id WHERE r.id=$1 AND r.thread_id=$2 FOR UPDATE", [ReplyId, ThreadId]) of
                    {ok, [Uid, ForumId, OldBody]} ->
                        case is_forum_member(Conn, Uid, ForumId) of
                            false -> {error, forum_membership_required};
                            true ->
                                Now = pw_util:now_ms(),
                                ok = exec(Conn, "UPDATE replies SET body=$1,raw_body=$1,updated_at=$2 WHERE id=$3 AND thread_id=$4", [Body,Now,ReplyId,ThreadId]),
                                case removed_upload_refs(OldBody, Body) of
                                    [] -> insert_upload_refs(Conn, Body, <<"thread">>, ThreadId, Now);
                                    _ -> sync_thread_upload_refs(Conn, ThreadId, Now)
                                end,
                                {ok, #{updated=>true,id=>ReplyId}}
                        end;
                    {ok, [_Author, _ForumId, _OldBody]} -> {error, forbidden};
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, _} ->
                    pw_hub:broadcast({thread, ThreadId}, #{type => thread_reply_updated, thread_id => ThreadId, reply_id => ReplyId}),
                    Result;
                _ -> Result
            end
    end;
route({delete_reply, Uid, ThreadId0, ReplyId0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0), ReplyId = pw_util:int(ReplyId0),
    Result = with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT r.user_id,f.owner_id,t.forum_id,COALESCE(NULLIF(r.raw_body,''),r.body) FROM replies r JOIN threads t ON t.id=r.thread_id JOIN forums f ON f.id=t.forum_id "
            "WHERE r.id=$1 AND r.thread_id=$2 FOR UPDATE", [ReplyId,ThreadId]) of
            {ok, [Author, ForumOwner, ForumId, OldBody]} ->
                Joined = is_forum_member(Conn, Uid, ForumId),
                case Uid =:= ForumOwner orelse (Uid =:= Author andalso Joined) of
                    true ->
                        Now = pw_util:now_ms(),
                        ok = exec(Conn, "DELETE FROM replies WHERE id=$1 AND thread_id=$2", [ReplyId,ThreadId]),
                        ok = exec(Conn, "UPDATE threads SET reply_count=(SELECT count(*) FROM replies WHERE thread_id=$1),updated_at=$2 WHERE id=$1", [ThreadId,Now]),
                        case extract_file_ids(pw_util:bin(OldBody)) of
                            [] -> ok;
                            _ -> sync_thread_upload_refs(Conn, ThreadId, Now)
                        end,
                        {ok, #{deleted=>true,id=>ReplyId}};
                    false when Uid =:= Author -> {error, forum_membership_required};
                    false -> {error, forbidden}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, _} -> pw_hub:broadcast({thread, ThreadId}, #{type=>thread_reply_deleted,thread_id=>ThreadId,reply_id=>ReplyId}), Result;
        _ -> Result
    end;
route({vote_thread, Uid, ThreadId0, Value0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    Value = case pw_util:int(Value0) of 1 -> 1; -1 -> -1; _ -> 0 end,
    case one(Conn,
        "SELECT EXISTS(SELECT 1 FROM forum_members fm WHERE fm.forum_id = t.forum_id AND fm.user_id = $2) "
        "FROM threads t WHERE t.id = $1", [ThreadId, Uid]) of
        {ok, [true]} ->
            Now = pw_util:now_ms(),
            ok = exec(Conn, "DELETE FROM thread_votes WHERE thread_id = $1 AND user_id = $2", [ThreadId, Uid]),
            case Value of
                0 -> ok;
                _ -> ok = exec(Conn, "INSERT INTO thread_votes(thread_id, user_id, value, created_at) VALUES($1,$2,$3,$4)", [ThreadId, Uid, Value, Now])
            end,
            ok = exec(Conn,
                "UPDATE threads SET score = COALESCE((SELECT sum(value) FROM thread_votes WHERE thread_id = $1), 0), "
                "upvotes = (SELECT count(*) FROM thread_votes WHERE thread_id = $1 AND value = 1), "
                "downvotes = (SELECT count(*) FROM thread_votes WHERE thread_id = $1 AND value = -1) WHERE id = $1",
                [ThreadId]),
            {ok, Row} = one(Conn, "SELECT score, COALESCE((SELECT value FROM thread_votes WHERE thread_id = $1 AND user_id = $2),0) FROM threads WHERE id = $1", [ThreadId, Uid]),
            {ok, #{thread_id => ThreadId, score => lists:nth(1, Row), user_vote => lists:nth(2, Row)}};
        {ok, [false]} -> {error, forum_membership_required};
        _ -> {error, not_found}
    end;
route({servers, Uid}, Conn) ->
    Sql = "SELECT s.id, s.owner_id, s.name, s.description, s.icon_url, s.banner_url, s.accent_color, s.welcome_message, s.created_at, s.updated_at, sm.role, "
          "(SELECT count(*) FROM server_members WHERE server_id = s.id), "
          "((CASE sm.role WHEN 'owner' THEN $2 WHEN 'admin' THEN $2 ELSE s.default_permissions END) | "
          "COALESCE((SELECT bit_or(r.permissions) FROM server_member_roles mr JOIN server_roles r ON r.id = mr.role_id "
          "WHERE mr.server_id = s.id AND mr.user_id = $1), 0)) "
          "FROM servers s JOIN server_members sm ON sm.server_id = s.id AND sm.user_id = $1 "
          "ORDER BY sm.joined_at ASC",
    {ok, Rows} = rows(Conn, Sql, [Uid, pw_permissions:all()]),
    {ok, map_rows_resilient(servers, Rows, fun server_row_map/1)};
route({create_server, Uid, Name0, Desc0}, Conn) ->
    Name = pw_util:clean_text(Name0, 80),
    Desc = pw_util:clean_text(Desc0, 280),
    case byte_size(Name) >= 2 of
        false ->
            {error, invalid_server_name};
        true ->
            %% Lock the owner row so two API nodes cannot simultaneously pass the
            %% duplicate-name check for the same account.
            with_tx(Conn, fun() ->
                _ = one(Conn, "SELECT id FROM users WHERE id = $1 FOR UPDATE", [Uid]),
                case one(Conn, "SELECT id FROM servers WHERE owner_id = $1 AND lower(name) = lower($2) LIMIT 1", [Uid, Name]) of
                    {ok, [_]} ->
                        {error, server_exists};
                    _ ->
                        Now = pw_util:now_ms(),
                        {ok, Sid} = insert_returning(Conn,
                            "INSERT INTO servers(owner_id, name, description, icon_url, created_at, updated_at) "
                            "VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                            [Uid, Name, Desc, <<>>, Now, Now]),
                        ok = exec(Conn, "INSERT INTO server_members(server_id, user_id, role, muted, joined_at) VALUES($1,$2,$3,$4,$5)",
                            [Sid, Uid, <<"owner">>, false, Now]),
                        ok = exec(Conn, "INSERT INTO channels(server_id, name, kind, position, topic, created_at) VALUES($1,$2,$3,$4,$5,$6)",
                            [Sid, <<"general">>, <<"text">>, 1, <<>>, Now]),
                        ok = exec(Conn, "INSERT INTO channels(server_id, name, kind, position, topic, created_at) VALUES($1,$2,$3,$4,$5,$6)",
                            [Sid, <<"Lounge">>, <<"voice">>, 2, <<>>, Now]),
                        {ok, #{id => Sid}}
                end
            end)
    end;
route({update_server, Uid, Sid0, Patch}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(maps:get(<<"name">>, Patch, <<>>), 80),
    Desc = pw_util:clean_text(maps:get(<<"description">>, Patch, <<>>), 280),
    RawIcon = maps:get(<<"icon_url">>, Patch, <<>>),
    RawBanner = maps:get(<<"banner_url">>, Patch, <<>>),
    Icon = store_image_url(RawIcon),
    Banner = store_image_url(RawBanner),
    Accent = clean_accent(maps:get(<<"accent_color">>, Patch, <<>>)),
    Welcome = pw_util:clean_text(maps:get(<<"welcome_message">>, Patch, <<>>), 2000),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT owner_id FROM servers WHERE id = $1 FOR UPDATE", [Sid]) of
            {ok, [OwnerId]} ->
                case can_manage_server(Conn, Uid, Sid) of
                    false -> {error, forbidden};
                    true ->
                        Now = pw_util:now_ms(),
                        HasWelcome = maps:is_key(<<"welcome_message">>, Patch),
                        HasDesc = maps:is_key(<<"description">>, Patch),
                        %% /api/media is derived output. don't save it over the real source.
                        HasIcon = maps:is_key(<<"icon_url">>, Patch) andalso not derived_media_url(RawIcon)
                            andalso server_image_input_allowed(Conn, Uid, RawIcon),
                        HasBanner = maps:is_key(<<"banner_url">>, Patch) andalso not derived_media_url(RawBanner)
                            andalso server_image_input_allowed(Conn, Uid, RawBanner),
                        HasAccent = maps:is_key(<<"accent_color">>, Patch) andalso Accent =/= undefined,
                        case duplicate_server_name(Conn, OwnerId, Sid, Name) of
                            true -> {error, server_exists};
                            false ->
                                ok = exec(Conn,
                                    "UPDATE servers SET name = COALESCE(NULLIF($1,''), name), "
                                    "description = CASE WHEN $3 THEN $2 ELSE description END, "
                                    "icon_url = CASE WHEN $4 THEN $5 ELSE icon_url END, "
                                    "banner_url = CASE WHEN $6 THEN $7 ELSE banner_url END, "
                                    "accent_color = CASE WHEN $8 THEN $9 ELSE accent_color END, welcome_message = CASE WHEN $12 THEN $13 ELSE welcome_message END, updated_at = $10 WHERE id = $11",
                                    [Name, Desc, HasDesc, HasIcon, Icon, HasBanner, Banner, HasAccent, Accent, Now, Sid, HasWelcome, Welcome]),
                                case one(Conn, "SELECT icon_url,banner_url FROM servers WHERE id = $1", [Sid]) of
                                    {ok, [CurrentIcon, CurrentServerBanner]} ->
                                        sync_server_upload_refs(Conn, Sid, pw_util:bin(CurrentIcon), pw_util:bin(CurrentServerBanner), Now);
                                    _ -> ok
                                end,
                                {ok, #{updated => true}}
                        end
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, _} ->
            publish_server_event(Conn, Sid, #{type => server_updated, server_id => Sid, actor_id => Uid}),
            route({server, Uid, Sid}, Conn);
        _ -> Result
    end;
route({delete_server, Uid, Sid0, ConfirmName0}, Conn) ->
    Sid = pw_util:int(Sid0),
    ConfirmName = pw_util:clean_text(ConfirmName0, 80),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT owner_id,name FROM servers WHERE id = $1 FOR UPDATE", [Sid]) of
            {ok, [Uid, ServerName]} when ConfirmName =:= ServerName ->
                {ok, MemberRows} = rows(Conn, "SELECT user_id FROM server_members WHERE server_id = $1", [Sid]),
                {ok, ChannelRows} = rows(Conn, "SELECT id FROM channels WHERE server_id = $1 ORDER BY id ASC FOR UPDATE", [Sid]),
                MemberIds = [only_id(R) || R <- MemberRows],
                ChannelIds = [only_id(R) || R <- ChannelRows],
                {ok, BotRows} = rows(Conn, "SELECT bot_user_id FROM server_bots WHERE server_id=$1 UNION SELECT bot_user_id FROM incoming_webhooks WHERE server_id=$1", [Sid]),
                AutomationUserIds = lists:usort([only_id(R) || R <- BotRows]),
                %% Messages are polymorphic and intentionally have no channel FK.
                %% Purge their dependent rows before the server/channel cascade so
                %% a deleted server cannot leave invisible message/upload zombies.
                ok = exec(Conn,
                    "DELETE FROM notifications n WHERE EXISTS (SELECT 1 FROM channels c WHERE c.server_id=$1 AND n.url = '#/channel/' || c.id::text)",
                    [Sid]),
                ok = exec(Conn,
                    "DELETE FROM upload_refs ur WHERE (ur.scope='server' AND ur.scope_id=$1) "
                    "OR (ur.scope='server_member' AND ur.scope_id=$1) "
                    "OR (ur.scope='channel' AND EXISTS (SELECT 1 FROM channels c WHERE c.server_id=$1 AND c.id=ur.scope_id))",
                    [Sid]),
                ok = enqueue_scylla_hard_deletes_for_server(Conn, Sid),
                ok = exec(Conn,
                    "DELETE FROM messages m WHERE m.scope='channel' AND EXISTS (SELECT 1 FROM channels c WHERE c.server_id=$1 AND c.id=m.scope_id)",
                    [Sid]),
                %% Bot/webhook identities are owned by this server. Remove their
                %% integration rows before their user rows so deleting a server
                %% cannot accumulate globally orphaned automation accounts.
                ok = exec(Conn, "DELETE FROM incoming_webhooks WHERE server_id=$1", [Sid]),
                ok = exec(Conn, "DELETE FROM server_bots WHERE server_id=$1", [Sid]),
                lists:foreach(fun(BotUid) -> ok = exec(Conn, "DELETE FROM users WHERE id=$1", [BotUid]) end, AutomationUserIds),
                ok = exec(Conn, "DELETE FROM servers WHERE id = $1", [Sid]),
                {ok, #{deleted => true, id => Sid, member_ids => MemberIds, channel_ids => ChannelIds}};
            {ok, [Uid, _]} -> {error, confirmation_mismatch};
            {ok, [_Other, _]} -> {error, forbidden};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{member_ids := MemberIds, channel_ids := ChannelIds} = Data} ->
            invalidate_upload_authz_users(MemberIds),
            [pw_cluster:revoke_server_access(MemberId, Sid, ChannelIds) || MemberId <- MemberIds],
            {ok, maps:without([member_ids, channel_ids], Data)};
        Other -> Other
    end;
route({server_member_profile, Uid, Sid0, Target0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Target = pw_util:int(Target0),
    case server_permissions0(Conn, Uid, Sid) of
        {ok, ViewerPermissions} ->
            CanManageRoles = pw_permissions:has(ViewerPermissions, pw_permissions:mask(<<"manage_roles">>))
                andalso (can_moderate_server_member(Conn, Uid, Sid, Target) orelse
                         (Uid =:= Target andalso server_member_is_owner(Conn, Sid, Uid))),
            CanBanMembers = pw_permissions:has(ViewerPermissions, pw_permissions:mask(<<"ban_members">>))
                andalso can_moderate_server_member(Conn, Uid, Sid, Target),
            case one(Conn,
                "SELECT u.id,u.username,u.display_name,u.bio,u.avatar_url,u.banner_url,u.status,u.theme,u.created_at,u.last_seen,"
                "sm.role,sm.muted,sm.joined_at,sm.nickname,sm.avatar_url,sm.bio,"
                "COALESCE((SELECT r.color FROM server_member_roles mr JOIN server_roles r ON r.id=mr.role_id "
                "WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id ORDER BY "
                "(r.permissions & 1073741824) DESC,(r.permissions & 16) DESC,(r.permissions & 32) DESC,"
                "(r.permissions & 8) DESC,(r.permissions & 4) DESC,(r.permissions & 64) DESC,"
                "(r.permissions & 128) DESC,(r.permissions & 2048) DESC,(r.permissions & 4096) DESC,"
                "(r.permissions & 256) DESC,(r.permissions & 512) DESC,(r.permissions & 2) DESC,"
                "(r.permissions & 1) DESC,r.position DESC,r.id ASC LIMIT 1),''),"
                "COALESCE((SELECT string_agg(r.name, ', ' ORDER BY r.position DESC,r.id ASC) FROM server_member_roles mr "
                "JOIN server_roles r ON r.id=mr.role_id WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id),''), "
                "u.is_bot "
                "FROM server_members sm JOIN users u ON u.id=sm.user_id WHERE sm.server_id=$1 AND sm.user_id=$2",
                [Sid, Target]) of
                {ok, MemberRow} when is_list(MemberRow) ->
                    case one(Conn, "SELECT name FROM servers WHERE id=$1", [Sid]) of
                        {ok, [ServerName]} ->
                            case rows(Conn,
                                "SELECT r.id,r.name,r.color,r.permissions,r.position,r.hoist,r.mentionable,r.created_at,r.updated_at "
                                "FROM server_member_roles mr JOIN server_roles r ON r.id=mr.role_id "
                                "WHERE mr.server_id=$1 AND mr.user_id=$2 ORDER BY r.position DESC,r.id ASC", [Sid, Target]) of
                                {ok, RoleRows} ->
                                    {ok, #{server_id => Sid, server_name => ServerName, member => member_map(MemberRow),
                                           roles => [server_role_map(R) || R <- RoleRows], can_manage_roles => CanManageRoles,
                                           can_ban_members => CanBanMembers}};
                                Error -> Error
                            end;
                        _ ->
                            {error, not_found}
                    end;
                _ -> {error, not_found}
            end;
        Error -> Error
    end;
route({server, Uid, ServerId0}, Conn) ->
    Sid = pw_util:int(ServerId0),
    case one(Conn, "SELECT role FROM server_members WHERE server_id = $1 AND user_id = $2", [Sid, Uid]) of
        {ok, [Role]} ->
            {ok, S} = one(Conn, "SELECT id, owner_id, name, description, icon_url, banner_url, accent_color, welcome_message, created_at, updated_at, default_permissions FROM servers WHERE id = $1", [Sid]),
            {ok, Permissions} = server_permissions0(Conn, Uid, Sid),
            CanViewChannels = pw_permissions:has(Permissions, pw_permissions:mask(<<"view_channels">>)),
            {ok, Ch} = case CanViewChannels of
                true -> rows(Conn, "SELECT id, server_id, name, kind, position, topic, created_at, category_id, slowmode_seconds FROM channels WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]);
                false -> {ok, []}
            end,
            {ok, Cats} = case CanViewChannels of
                true -> rows(Conn, "SELECT id, server_id, name, position, created_at FROM channel_categories WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]);
                false -> {ok, []}
            end,
            {ok, Ms} = rows(Conn,
                "SELECT u.id, u.username, u.display_name, u.bio, u.avatar_url, u.banner_url, u.status, u.theme, "
                "u.created_at, u.last_seen, sm.role, sm.muted, sm.joined_at, sm.nickname, sm.avatar_url, sm.bio, "
                "COALESCE((SELECT r.color FROM server_member_roles mr JOIN server_roles r ON r.id=mr.role_id "
                "WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id ORDER BY (r.permissions & 1073741824) DESC,(r.permissions & 16) DESC,(r.permissions & 32) DESC,(r.permissions & 8) DESC,(r.permissions & 4) DESC,(r.permissions & 64) DESC,(r.permissions & 128) DESC,(r.permissions & 2048) DESC,(r.permissions & 4096) DESC,(r.permissions & 256) DESC,(r.permissions & 512) DESC,(r.permissions & 2) DESC,(r.permissions & 1) DESC,r.position DESC,r.id ASC LIMIT 1),''), "
                "COALESCE((SELECT string_agg(r.name, ', ' ORDER BY r.position DESC,r.id ASC) FROM server_member_roles mr "
                "JOIN server_roles r ON r.id=mr.role_id WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id),''), "
                "u.is_bot "
                "FROM server_members sm JOIN users u ON u.id = sm.user_id WHERE sm.server_id = $1 "
                "ORDER BY CASE sm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, u.display_name ASC",
                [Sid]),
            Server = (server_full_map(S, Role))#{permissions => Permissions},
            {ok, #{server => Server, channels => [channel_map(R) || R <- Ch], members => [member_map(R) || R <- Ms], categories => [category_map(R) || R <- Cats]}};
        _ ->
            {error, forbidden}
    end;
route({server_permissions, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case server_permissions0(Conn, Uid, Sid) of
        {ok, Permissions} -> {ok, #{server_id => Sid, permissions => Permissions, catalog => pw_permissions:catalog()}};
        Error -> Error
    end;
route({update_server_default_permissions, Uid, Sid0, Permissions0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Requested = pw_permissions:sanitize(Permissions0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT owner_id FROM servers WHERE id = $1 FOR UPDATE", [Sid]) of
            {ok, [Uid]} ->
                %% The server owner controls the baseline that every ordinary member
                %% receives. Administrator is deliberately excluded from the baseline;
                %% it must remain an explicit high-trust role grant.
                Admin = pw_permissions:mask(<<"administrator">>),
                Default = Requested band (pw_permissions:all() bxor Admin),
                ok = exec(Conn, "UPDATE servers SET default_permissions = $1, updated_at = $2 WHERE id = $3", [Default, pw_util:now_ms(), Sid]),
                {ok, #{server_id => Sid, default_permissions => Default}};
            {ok, [_]} -> {error, forbidden};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, _} ->
            invalidate_server_upload_authz(Conn, Sid),
            publish_server_event(Conn, Sid, #{type => server_roles_updated, server_id => Sid}),
            Result;
        _ -> Result
    end;
route({server_roles, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case server_permissions0(Conn, Uid, Sid) of
        {ok, Permissions} ->
            {ok, RoleRows} = rows(Conn,
                "SELECT id,name,color,permissions,position,hoist,mentionable,created_at,updated_at "
                "FROM server_roles WHERE server_id = $1 ORDER BY position DESC,id ASC", [Sid]),
            {ok, MemberRows} = rows(Conn,
                "SELECT u.id,u.username,u.display_name,u.bio,u.avatar_url,u.banner_url,u.status,u.theme,u.created_at,u.last_seen,"
                "sm.role,sm.nickname,sm.avatar_url,sm.bio,sm.joined_at,u.is_bot "
                "FROM server_members sm JOIN users u ON u.id = sm.user_id WHERE sm.server_id = $1 "
                "ORDER BY CASE sm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END,u.display_name ASC", [Sid]),
            {ok, AssignmentRows} = rows(Conn,
                "SELECT user_id,role_id FROM server_member_roles WHERE server_id = $1 ORDER BY role_id ASC", [Sid]),
            Assignments = role_assignment_map(AssignmentRows),
            {ok, [DefaultPermissions]} = one(Conn, "SELECT default_permissions FROM servers WHERE id = $1", [Sid]),
            {ok, #{server_id => Sid, permissions => Permissions, default_permissions => pw_permissions:sanitize(DefaultPermissions), catalog => pw_permissions:catalog(),
                roles => [server_role_map(R) || R <- RoleRows],
                members => [server_admin_member_map(R, maps:get(lists:nth(1, R), Assignments, [])) || R <- MemberRows]}};
        Error -> Error
    end;
route({create_server_role, Uid, Sid0, Name0, Patch}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 40),
    Color = role_color(maps:get(<<"color">>, Patch, <<"#99aab5">>)),
    RequestedPermissions = pw_permissions:sanitize(maps:get(<<"permissions">>, Patch, 0)),
    Position0 = pw_util:int(maps:get(<<"position">>, Patch, 1)),
    Hoist = pw_util:bool(maps:get(<<"hoist">>, Patch, false)),
    Mentionable = pw_util:bool(maps:get(<<"mentionable">>, Patch, false)),
    case byte_size(Name) >= 2 andalso byte_size(Name) =< 40 of
        false -> {error, invalid_role_name};
        true ->
            Result = with_tx(Conn, fun() ->
            _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
            case has_server_permission(Conn, Uid, Sid, <<"manage_roles">>) of
                false -> {error, forbidden};
                true ->
                    case one(Conn, "SELECT id FROM server_roles WHERE server_id = $1 AND lower(name) = lower($2)", [Sid, Name]) of
                        {ok, [_]} -> {error, role_exists};
                        _ ->
                            ActorRank = server_member_rank0(Conn, Sid, Uid),
                            Owner = server_member_is_owner(Conn, Sid, Uid),
                            %% Non-owners may only create roles strictly below their own
                            %% highest role. Position 1 is the lowest assignable role, so
                            %% rank 0/1 actors have no legal position even if a custom
                            %% permission mask grants manage_roles.
                            case Owner orelse ActorRank > 1 of
                                false -> {error, role_hierarchy};
                                true ->
                                    MaxPosition = case Owner of true -> 9999; false -> ActorRank - 1 end,
                                    Position = min(MaxPosition, max(1, int_or(Position0, 1))),
                                    Permissions = grantable_role_permissions(Conn, Uid, Sid, RequestedPermissions),
                                    Now = pw_util:now_ms(),
                                    {ok, RoleId} = insert_returning(Conn,
                                        "INSERT INTO server_roles(server_id,name,color,permissions,position,hoist,mentionable,created_at,updated_at) "
                                        "VALUES($1,$2,$3,$4,$5,$6,$7,$8,$8) RETURNING id",
                                        [Sid, Name, Color, Permissions, Position, Hoist, Mentionable, Now]),
                                    {ok, #{id => RoleId}}
                            end
                    end
            end
        end),
            case Result of
                {ok, _} ->
                    publish_server_event(Conn, Sid, #{type => server_roles_updated, server_id => Sid}),
                    Result;
                _ -> Result
            end
    end;
route({update_server_role, Uid, Sid0, RoleId0, Patch}, Conn) ->
    Sid = pw_util:int(Sid0), RoleId = pw_util:int(RoleId0),
    Result = with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
        case {has_server_permission(Conn, Uid, Sid, <<"manage_roles">>),
              one(Conn, "SELECT name,color,permissions,position,hoist,mentionable FROM server_roles WHERE id = $1 AND server_id = $2 FOR UPDATE", [RoleId, Sid])} of
            {false, _} -> {error, forbidden};
            {true, {ok, [OldName, OldColor, OldPermissions, OldPosition, OldHoist, OldMentionable]}} ->
                ActorRank = server_member_rank0(Conn, Sid, Uid),
                Owner = server_member_is_owner(Conn, Sid, Uid),
                case Owner orelse ActorRank > OldPosition of
                    false -> {error, role_hierarchy};
                    true ->
                        Name = case maps:is_key(<<"name">>, Patch) of true -> pw_util:clean_text(maps:get(<<"name">>, Patch), 40); false -> OldName end,
                        Color = case maps:is_key(<<"color">>, Patch) of true -> role_color(maps:get(<<"color">>, Patch)); false -> OldColor end,
                        Permissions = case maps:is_key(<<"permissions">>, Patch) of
                            true -> grantable_role_permissions(Conn, Uid, Sid, maps:get(<<"permissions">>, Patch));
                            false -> OldPermissions
                        end,
                        MaxPosition = case Owner of true -> 9999; false -> max(1, ActorRank - 1) end,
                        Position = case maps:is_key(<<"position">>, Patch) of
                            true -> min(MaxPosition, max(1, int_or(pw_util:int(maps:get(<<"position">>, Patch)), OldPosition)));
                            false -> OldPosition
                        end,
                        Hoist = case maps:is_key(<<"hoist">>, Patch) of true -> pw_util:bool(maps:get(<<"hoist">>, Patch)); false -> OldHoist end,
                        Mentionable = case maps:is_key(<<"mentionable">>, Patch) of true -> pw_util:bool(maps:get(<<"mentionable">>, Patch)); false -> OldMentionable end,
                        case byte_size(Name) >= 2 of
                            false -> {error, invalid_role_name};
                            true ->
                                case one(Conn, "SELECT id FROM server_roles WHERE server_id = $1 AND lower(name) = lower($2) AND id <> $3", [Sid, Name, RoleId]) of
                                    {ok, [_]} -> {error, role_exists};
                                    _ ->
                                        ok = exec(Conn, "UPDATE server_roles SET name=$1,color=$2,permissions=$3,position=$4,hoist=$5,mentionable=$6,updated_at=$7 WHERE id=$8 AND server_id=$9",
                                            [Name, Color, Permissions, Position, Hoist, Mentionable, pw_util:now_ms(), RoleId, Sid]),
                                        {ok, #{updated => true, id => RoleId}}
                                end
                        end
                end;
            {true, _} -> {error, not_found}
        end
    end),
    case Result of
        {ok, _} ->
            invalidate_role_upload_authz(Conn, Sid, RoleId),
            publish_server_event(Conn, Sid, #{type => server_roles_updated, server_id => Sid}),
            Result;
        _ -> Result
    end;
route({delete_server_role, Uid, Sid0, RoleId0}, Conn) ->
    Sid = pw_util:int(Sid0), RoleId = pw_util:int(RoleId0),
    Result = with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
        case {has_server_permission(Conn, Uid, Sid, <<"manage_roles">>),
              one(Conn, "SELECT position FROM server_roles WHERE id = $1 AND server_id = $2 FOR UPDATE", [RoleId, Sid])} of
            {false, _} -> {error, forbidden};
            {true, {ok, [Position]}} ->
                case server_member_is_owner(Conn, Sid, Uid) orelse server_member_rank0(Conn, Sid, Uid) > Position of
                    false -> {error, role_hierarchy};
                    true ->
                        {ok, AffectedRows} = rows(Conn,
                            "SELECT user_id FROM server_member_roles WHERE server_id = $1 AND role_id = $2 FOR UPDATE", [Sid, RoleId]),
                        Affected = [MemberId || [MemberId] <- AffectedRows],
                        ok = exec(Conn, "DELETE FROM server_roles WHERE id = $1 AND server_id = $2", [RoleId, Sid]),
                        {ok, #{deleted => true, id => RoleId, invalidate_upload_users => Affected}}
                end;
            {true, _} -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{invalidate_upload_users := Affected} = Data} ->
            invalidate_upload_authz_users(Affected),
            publish_server_event(Conn, Sid, #{type => server_roles_updated, server_id => Sid}),
            {ok, maps:remove(invalidate_upload_users, Data)};
        _ -> Result
    end;
route({set_server_member_roles, Uid, Sid0, Target0, RoleIds0}, Conn) ->
    Sid = pw_util:int(Sid0), Target = pw_util:int(Target0),
    RoleIds = normalize_role_ids(RoleIds0),
    case length(RoleIds) =< 50 of
        false -> {error, too_many_roles};
        true ->
            Result = with_tx(Conn, fun() ->
            _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
            case one(Conn, "SELECT user_id FROM server_members WHERE server_id = $1 AND user_id = $2 FOR UPDATE", [Sid, Target]) of
                {ok, [_]} ->
                    case has_server_permission(Conn, Uid, Sid, <<"manage_roles">>) andalso
                         (can_moderate_server_member(Conn, Uid, Sid, Target) orelse
                          (Uid =:= Target andalso server_member_is_owner(Conn, Sid, Uid))) of
                        false -> {error, forbidden};
                        true ->
                            {ok, AvailableRows} = rows(Conn, "SELECT id,position FROM server_roles WHERE server_id = $1", [Sid]),
                            Available = maps:from_list([{Id, Pos} || [Id, Pos] <- AvailableRows]),
                            Missing = [Id || Id <- RoleIds, not maps:is_key(Id, Available)],
                            ActorRank = server_member_rank0(Conn, Sid, Uid),
                            TooHigh = not server_member_is_owner(Conn, Sid, Uid) andalso lists:any(fun(Id) -> maps:get(Id, Available, ActorRank) >= ActorRank end, RoleIds),
                            case {Missing, TooHigh} of
                                {[], false} ->
                                    ok = exec(Conn, "DELETE FROM server_member_roles WHERE server_id = $1 AND user_id = $2", [Sid, Target]),
                                    Now = pw_util:now_ms(),
                                    [ok = exec(Conn, "INSERT INTO server_member_roles(server_id,user_id,role_id,assigned_by,assigned_at) VALUES($1,$2,$3,$4,$5)", [Sid, Target, RoleId, Uid, Now]) || RoleId <- RoleIds],
                                    {ok, #{updated => true, user_id => Target, role_ids => RoleIds}};
                                {[_|_], _} -> {error, invalid_role};
                                {_, true} -> {error, role_hierarchy}
                            end
                    end;
                _ -> {error, not_found}
            end
        end),
            case Result of
                {ok, _} ->
                    pw_upload_gc:invalidate_user(Target),
                    publish_server_event(Conn, Sid, #{type => server_member_roles_updated, server_id => Sid, user_id => Target}),
                    Result;
                _ -> Result
            end
    end;
route({kick_server_member, Uid, Sid0, Target0}, Conn) ->
    Sid = pw_util:int(Sid0), Target = pw_util:int(Target0),
    Result = with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
        case one(Conn, "SELECT user_id FROM server_members WHERE server_id = $1 AND user_id = $2 FOR UPDATE", [Sid, Target]) of
            {ok, [_]} ->
                case has_server_permission(Conn, Uid, Sid, <<"kick_members">>) andalso can_moderate_server_member(Conn, Uid, Sid, Target) of
                    false -> {error, forbidden};
                    true ->
                        {ok, ChannelRows} = rows(Conn, "SELECT id FROM channels WHERE server_id = $1", [Sid]),
                        ChannelIds = [Id || [Id] <- ChannelRows],
                        ok = exec(Conn, "DELETE FROM server_member_roles WHERE server_id = $1 AND user_id = $2", [Sid, Target]),
                        ok = exec(Conn, "DELETE FROM server_members WHERE server_id = $1 AND user_id = $2", [Sid, Target]),
                        sync_server_member_upload_refs(Conn, Sid, pw_util:now_ms()),
                        {ok, #{kicked => true, user_id => Target, server_id => Sid, revoke_channels => ChannelIds}}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{revoke_channels := ChannelIds} = Data} ->
            %% Revoke cached attachment authorization before the removed member can
            %% reuse a previously cached allow decision after the membership commit.
            pw_upload_gc:invalidate_user(Target),
            pw_cluster:revoke_server_access(Target, Sid, ChannelIds),
            publish_server_event(Conn, Sid, #{type => server_member_removed, server_id => Sid, user_id => Target, actor_id => Uid}),
            {ok, maps:remove(revoke_channels, Data)};
        Other -> Other
    end;
route({ban_server_member, Uid, Sid0, Target0, Reason0}, Conn) ->
    Sid = pw_util:int(Sid0), Target = pw_util:int(Target0), Reason = pw_util:clean_text(Reason0, 512),
    Result = with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT id FROM servers WHERE id=$1 FOR UPDATE", [Sid]),
        case one(Conn, "SELECT user_id FROM server_members WHERE server_id=$1 AND user_id=$2 FOR UPDATE", [Sid, Target]) of
            {ok, [_]} ->
                case has_server_permission(Conn, Uid, Sid, <<"ban_members">>) andalso can_moderate_server_member(Conn, Uid, Sid, Target) of
                    false -> {error, forbidden};
                    true ->
                        {ok, ChannelRows} = rows(Conn, "SELECT id FROM channels WHERE server_id=$1", [Sid]),
                        ChannelIds = [Id || [Id] <- ChannelRows], Now = pw_util:now_ms(),
                        ok = exec(Conn, "INSERT INTO server_bans(server_id,user_id,banned_by,reason,created_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(server_id,user_id) DO UPDATE SET banned_by=EXCLUDED.banned_by,reason=EXCLUDED.reason,created_at=EXCLUDED.created_at", [Sid, Target, Uid, Reason, Now]),
                        ok = exec(Conn, "DELETE FROM server_member_roles WHERE server_id=$1 AND user_id=$2", [Sid, Target]),
                        ok = exec(Conn, "DELETE FROM server_members WHERE server_id=$1 AND user_id=$2", [Sid, Target]),
                        sync_server_member_upload_refs(Conn, Sid, Now),
                        queue_server_storage_event(Conn, <<"member.banned">>, Sid, Target, Uid, #{reason => Reason}, Now),
                        enqueue_server_webhooks(Conn, Sid, <<"member.banned">>, #{user_id => Target, actor_id => Uid, reason => Reason}),
                        {ok, #{banned => true, user_id => Target, server_id => Sid, revoke_channels => ChannelIds}}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{revoke_channels := ChannelIds} = Data} ->
            pw_upload_gc:invalidate_user(Target),
            pw_cluster:revoke_server_access(Target, Sid, ChannelIds),
            publish_server_event(Conn, Sid, #{type => server_member_banned, server_id => Sid, user_id => Target}),
            {ok, maps:remove(revoke_channels, Data)};
        _ -> Result
    end;
route({unban_server_member, Uid, Sid0, Target0}, Conn) ->
    Sid = pw_util:int(Sid0), Target = pw_util:int(Target0),
    with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT id FROM servers WHERE id=$1 FOR UPDATE", [Sid]),
        case has_server_permission(Conn, Uid, Sid, <<"ban_members">>) of
            false -> {error, forbidden};
            true ->
                case one(Conn, "DELETE FROM server_bans WHERE server_id=$1 AND user_id=$2 RETURNING user_id", [Sid, Target]) of
                    {ok, [Target]} ->
                        Now = pw_util:now_ms(),
                        queue_server_storage_event(Conn, <<"member.unbanned">>, Sid, Target, Uid, #{}, Now),
                        enqueue_server_webhooks(Conn, Sid, <<"member.unbanned">>, #{user_id => Target, actor_id => Uid}),
                        {ok, #{unbanned => true, user_id => Target, server_id => Sid}};
                    _ -> {error, not_found}
                end
        end
    end);
route({server_bans, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case has_server_permission(Conn, Uid, Sid, <<"ban_members">>) of
        false -> {error, forbidden};
        true ->
            {ok, Rows} = rows(Conn, "SELECT b.user_id,u.username,u.display_name,u.avatar_url,b.banned_by,COALESCE(a.username,''),b.reason,b.created_at FROM server_bans b JOIN users u ON u.id=b.user_id LEFT JOIN users a ON a.id=b.banned_by WHERE b.server_id=$1 ORDER BY b.created_at DESC,b.user_id ASC LIMIT 500", [Sid]),
            {ok, [#{user_id => UserId, username => Username, display_name => DisplayName, avatar_url => Avatar, banned_by => BannedBy, banned_by_username => ActorName, reason => Reason, created_at => CreatedAt} || [UserId, Username, DisplayName, Avatar, BannedBy, ActorName, Reason, CreatedAt] <- Rows]}
    end;
route({update_server_member_profile, Uid, Sid0, Target0, Patch}, Conn) ->
    Sid = pw_util:int(Sid0), Target = pw_util:int(Target0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT user_id FROM server_members WHERE server_id = $1 AND user_id = $2 FOR UPDATE", [Sid, Target]) of
            {ok, [_]} ->
                Own = Uid =:= Target,
                Allowed = Own orelse (has_server_permission(Conn, Uid, Sid, <<"manage_profiles">>) andalso can_moderate_server_member(Conn, Uid, Sid, Target)),
                case Allowed of
                    false -> {error, forbidden};
                    true ->
                        Nick = pw_util:clean_text(maps:get(<<"nickname">>, Patch, <<>>), 80),
                        Bio = pw_util:clean_text(maps:get(<<"bio">>, Patch, <<>>), 280),
                        RawAvatar = maps:get(<<"avatar_url">>, Patch, <<>>),
                        Avatar = store_image_url(RawAvatar),
                        HasNick = maps:is_key(<<"nickname">>, Patch),
                        HasBio = maps:is_key(<<"bio">>, Patch),
                        HasAvatar0 = maps:is_key(<<"avatar_url">>, Patch),
                        HasAvatar = HasAvatar0 andalso not derived_media_url(RawAvatar)
                            andalso server_image_input_allowed(Conn, Uid, RawAvatar),
                        ok = exec(Conn,
                            "UPDATE server_members SET nickname = CASE WHEN $1 THEN $2 ELSE nickname END, "
                            "bio = CASE WHEN $3 THEN $4 ELSE bio END, avatar_url = CASE WHEN $5 THEN $6 ELSE avatar_url END "
                            "WHERE server_id = $7 AND user_id = $8",
                            [HasNick, Nick, HasBio, Bio, HasAvatar, Avatar, Sid, Target]),
                        case HasAvatar of
                            true -> sync_server_member_upload_refs(Conn, Sid, pw_util:now_ms());
                            false -> ok
                        end,
                        {ok, #{updated => true, user_id => Target}}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, _} ->
            publish_server_event(Conn, Sid, #{type => server_member_profile_updated, server_id => Sid, user_id => Target}),
            Result;
        _ -> Result
    end;

route({create_channel, Uid, Sid0, Name0, Kind0, CategoryId0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 40),
    Kind = case pw_util:clean_text(Kind0, 10) of <<"voice">> -> <<"voice">>; _ -> <<"text">> end,
    CategoryId = optional_id(CategoryId0),
    case byte_size(Name) >= 1 of
        false -> {error, invalid_channel_name};
        true ->
            Result = with_tx(Conn, fun() ->
                %% Serialize channel naming/position assignment across API nodes.
                _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
                case {has_server_permission(Conn, Uid, Sid, <<"manage_channels">>),
                      valid_channel_category(Conn, Sid, CategoryId)} of
                    {false, _} -> {error, forbidden};
                    {_, false} -> {error, invalid_category};
                    {true, true} ->
                        case one(Conn, "SELECT id FROM channels WHERE server_id = $1 AND lower(name) = lower($2) LIMIT 1", [Sid, Name]) of
                            {ok, [_]} -> {error, channel_exists};
                            _ ->
                                Now = pw_util:now_ms(),
                                {ok, [Pos]} = one(Conn, "SELECT COALESCE(max(position), 0) + 1 FROM channels WHERE server_id = $1", [Sid]),
                                {ok, Cid} = insert_returning(Conn,
                                    "INSERT INTO channels(server_id, name, kind, position, topic, created_at, category_id) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id",
                                    [Sid, Name, Kind, Pos, <<>>, Now, sql_optional_id(CategoryId)]),
                                {ok, #{id => Cid}}
                        end
                end
            end),
            case Result of
                {ok, #{id := Cid}} ->
                    publish_server_event(Conn, Sid, #{type => channel_created, server_id => Sid, channel_id => Cid}),
                    enqueue_server_webhooks(Conn, Sid, <<"channel.created">>, #{channel_id => Cid, actor_id => Uid}),
                    Result;
                _ -> Result
            end
    end;
route({update_channel_settings, Uid, ChannelId0, Patch0}, Conn) ->
    ChannelId = pw_util:int(ChannelId0),
    Patch = case is_map(Patch0) of true -> Patch0; false -> #{} end,
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT server_id,name,topic,slowmode_seconds,kind FROM channels WHERE id=$1 FOR UPDATE", [ChannelId]) of
            {ok, [Sid, OldName, OldTopic, OldSlowmode, Kind]} ->
                case has_server_permission(Conn, Uid, Sid, <<"manage_channels">>) of
                    false -> {error, forbidden};
                    true ->
                        Name = case maps:is_key(<<"name">>, Patch) of true -> pw_util:clean_text(maps:get(<<"name">>, Patch), 40); false -> OldName end,
                        Topic = case maps:is_key(<<"topic">>, Patch) of true -> pw_util:clean_text(maps:get(<<"topic">>, Patch), 1024); false -> OldTopic end,
                        Slow0 = case maps:is_key(<<"slowmode_seconds">>, Patch) of true -> pw_util:int(maps:get(<<"slowmode_seconds">>, Patch)); false -> OldSlowmode end,
                        Slow = case Slow0 of I when is_integer(I), I >= 0, I =< 21600 -> I; _ -> invalid end,
                        case {byte_size(Name) >= 1, Slow, one(Conn, "SELECT id FROM channels WHERE server_id=$1 AND id<>$2 AND lower(name)=lower($3) LIMIT 1", [Sid,ChannelId,Name])} of
                            {false, _, _} -> {error, invalid_channel_name};
                            {_, invalid, _} -> {error, invalid_slowmode};
                            {_, _, {ok, [_]}} -> {error, channel_exists};
                            {true, S, _} ->
                                ok = exec(Conn, "UPDATE channels SET name=$1,topic=$2,slowmode_seconds=$3 WHERE id=$4", [Name,Topic,S,ChannelId]),
                                {ok, #{id => ChannelId, server_id => Sid, name => Name, topic => Topic, slowmode_seconds => S, kind => Kind}}
                        end
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{server_id := Sid} = Data} ->
            publish_server_event(Conn, Sid, #{type => channel_updated, server_id => Sid, channel_id => ChannelId}),
            enqueue_server_webhooks(Conn, Sid, <<"channel.updated">>, #{channel_id => ChannelId, actor_id => Uid}),
            {ok, Data};
        Other -> Other
    end;
route({categories, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case has_server_permission(Conn, Uid, Sid, <<"view_channels">>) of
        true ->
            {ok, Rows} = rows(Conn, "SELECT id, server_id, name, position, created_at FROM channel_categories WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]),
            {ok, [category_map(R) || R <- Rows]};
        false ->
            {error, forbidden}
    end;
route({create_category, Uid, Sid0, Name0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 80),
    case byte_size(Name) >= 1 of
        false -> {error, invalid_category_name};
        true ->
            Result = with_tx(Conn, fun() ->
                %% Position allocation must be serialized just like channels.
                _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
                case has_server_permission(Conn, Uid, Sid, <<"manage_channels">>) of
                    false -> {error, forbidden};
                    true ->
                        Now = pw_util:now_ms(),
                        {ok, [Pos]} = one(Conn, "SELECT COALESCE(max(position), 0) + 1 FROM channel_categories WHERE server_id = $1", [Sid]),
                        {ok, Cid} = insert_returning(Conn,
                            "INSERT INTO channel_categories(server_id, name, position, created_at) VALUES($1,$2,$3,$4) RETURNING id",
                            [Sid, Name, Pos, Now]),
                        {ok, #{id => Cid}}
                end
            end),
            case Result of
                {ok, #{id := Cid}} ->
                    publish_server_event(Conn, Sid, #{type => category_created, server_id => Sid, category_id => Cid}),
                    Result;
                _ -> Result
            end
    end;
route({update_category, Uid, Sid0, CatId0, Patch}, Conn) ->
    Sid = pw_util:int(Sid0),
    CatId = pw_util:int(CatId0),
    Name = pw_util:clean_text(maps:get(<<"name">>, Patch, <<>>), 80),
    case byte_size(Name) >= 1 of
        false -> {error, invalid_category_name};
        true ->
            Result = with_tx(Conn, fun() ->
                _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
                case has_server_permission(Conn, Uid, Sid, <<"manage_channels">>) of
                    false -> {error, forbidden};
                    true ->
                        case one(Conn, "UPDATE channel_categories SET name = $1 WHERE id = $2 AND server_id = $3 RETURNING id", [Name, CatId, Sid]) of
                            {ok, [_]} -> {ok, #{updated => true}};
                            _ -> {error, not_found}
                        end
                end
            end),
            case Result of
                {ok, _} ->
                    publish_server_event(Conn, Sid, #{type => category_updated, server_id => Sid, category_id => CatId}),
                    Result;
                _ -> Result
            end
    end;
route({reorder_categories, Uid, Sid0, Order0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case normalize_category_order(Order0) of
        {error, _} = Error -> Error;
        {ok, Order} ->
            Result = with_tx(Conn, fun() ->
            _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
            case has_server_permission(Conn, Uid, Sid, <<"manage_channels">>) of
                false -> {error, forbidden};
                true ->
                    {ok, ExistingRows} = rows(Conn, "SELECT id FROM channel_categories WHERE server_id = $1 FOR UPDATE", [Sid]),
                    Existing = maps:from_list([{Id, true} || [Id] <- ExistingRows]),
                    Missing = [CatId || {CatId, _} <- Order, not maps:is_key(CatId, Existing)],
                    case Missing of
                        [_ | _] -> {error, invalid_category};
                        [] ->
                            [ok = exec(Conn, "UPDATE channel_categories SET position = $1 WHERE id = $2 AND server_id = $3", [Pos, CatId, Sid]) || {CatId, Pos} <- Order],
                            {ok, #{updated => true, count => length(Order)}}
                    end
            end
        end),
            case Result of
                {ok, _} ->
                    publish_server_event(Conn, Sid, #{type => categories_reordered, server_id => Sid}),
                    Result;
                _ -> Result
            end
    end;
route({delete_category, Uid, Sid0, CatId0}, Conn) ->
    Sid = pw_util:int(Sid0),
    CatId = pw_util:int(CatId0),
    Result = with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
        case has_server_permission(Conn, Uid, Sid, <<"manage_channels">>) of
            false -> {error, forbidden};
            true ->
                case one(Conn, "SELECT id FROM channel_categories WHERE id = $1 AND server_id = $2 FOR UPDATE", [CatId, Sid]) of
                    {ok, [_]} ->
                        ok = exec(Conn, "UPDATE channels SET category_id = NULL WHERE category_id = $1 AND server_id = $2", [CatId, Sid]),
                        ok = exec(Conn, "DELETE FROM channel_categories WHERE id = $1 AND server_id = $2", [CatId, Sid]),
                        {ok, #{deleted => true}};
                    _ -> {error, not_found}
                end
        end
    end),
    case Result of
        {ok, _} ->
            publish_server_event(Conn, Sid, #{type => category_deleted, server_id => Sid, category_id => CatId}),
            Result;
        _ -> Result
    end;
route({move_channel, Uid, ChannelId0, CatId0, Position0}, Conn) ->
    ChannelId = pw_util:int(ChannelId0),
    CatId = optional_id(CatId0),
    Position = pw_util:int(Position0),
    Result = with_tx(Conn, fun() ->
        %% Lock parent before child everywhere. Server deletion follows the same
        %% order, avoiding channel-move/server-delete lock inversion.
        case one(Conn, "SELECT server_id FROM channels WHERE id = $1", [ChannelId]) of
            {ok, [Sid]} ->
                case one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]) of
                    {ok, [_]} ->
                        case one(Conn, "SELECT id FROM channels WHERE id=$1 AND server_id=$2 FOR UPDATE", [ChannelId, Sid]) of
                            {ok, [_]} ->
                                case {has_server_permission(Conn, Uid, Sid, <<"manage_channels">>),
                                      valid_channel_category(Conn, Sid, CatId)} of
                                    {false, _} -> {error, forbidden};
                                    {_, false} -> {error, invalid_category};
                                    {true, true} ->
                                        CatIdSafe = sql_optional_id(CatId),
                                        PosSafe = case Position of undefined -> 0; P when is_integer(P) -> min(10000, max(0, P)) end,
                                        ok = exec(Conn, "UPDATE channels SET category_id = $1, position = $2 WHERE id = $3", [CatIdSafe, PosSafe, ChannelId]),
                                        {ok, #{updated => true, server_id => Sid}}
                                end;
                            _ -> {error, not_found}
                        end;
                    _ -> {error, not_found}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{server_id := Sid} = Data} ->
            publish_server_event(Conn, Sid, #{type => channel_moved, server_id => Sid, channel_id => ChannelId}),
            {ok, maps:remove(server_id, Data)};
        _ -> Result
    end;
route({server_webhooks, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>) of
        false -> {error, forbidden};
        true ->
            {ok, Rows} = rows(Conn,
                "SELECT id,name,url,events,enabled,created_by,created_at,updated_at,last_success_at,last_failure_at,failure_count "
                "FROM server_webhooks WHERE server_id=$1 ORDER BY id ASC", [Sid]),
            {ok, [webhook_public_map(R) || R <- Rows]}
    end;
route({create_server_webhook, Uid, Sid0, Name0, Url0, Events0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 80),
    Url = pw_util:clean_text(Url0, 2048),
    case {byte_size(Name) >= 2, pw_outbound_url:allowed(Url), normalize_webhook_events(Events0)} of
        {false, _, _} -> {error, invalid_webhook_name};
        {_, false, _} -> {error, blocked_webhook_url};
        {_, _, error} -> {error, invalid_webhook_events};
        {true, true, {ok, Events}} ->
            with_tx(Conn, fun() ->
                _ = one(Conn, "SELECT id FROM servers WHERE id=$1 FOR UPDATE", [Sid]),
                case has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>) of
                    false -> {error, forbidden};
                    true ->
                        {ok, [Count]} = one(Conn, "SELECT count(*) FROM server_webhooks WHERE server_id=$1", [Sid]),
                        case Count >= 50 of
                            true -> {error, webhook_limit};
                            false ->
                                Secret = pw_util:random_token(32),
                                Now = pw_util:now_ms(),
                                StoredEvents = webhook_events_storage(Events),
                                {ok, Id} = insert_returning(Conn,
                                    "INSERT INTO server_webhooks(server_id,name,url,secret,events,enabled,created_by,created_at,updated_at) "
                                    "VALUES($1,$2,$3,$4,$5,true,$6,$7,$7) RETURNING id",
                                    [Sid, Name, Url, store_message(Secret), StoredEvents, Uid, Now]),
                                {ok, #{id => Id, server_id => Sid, name => Name, url => Url,
                                       events => Events, enabled => true, secret => Secret,
                                       created_at => Now, updated_at => Now}}
                        end
                end
            end)
    end;
route({update_server_webhook, Uid, Sid0, WebhookId0, Patch, ExpectedUpdatedAt0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0), ExpectedUpdatedAt = pw_util:int(ExpectedUpdatedAt0),
    Result = with_tx(Conn, fun() ->
        case {has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>),
              one(Conn, "SELECT name,url,events,enabled,updated_at FROM server_webhooks WHERE id=$1 AND server_id=$2 FOR UPDATE", [WebhookId, Sid])} of
            {false, _} -> {error, forbidden};
            {true, {ok, [OldName, OldUrl, OldEvents, OldEnabled, OldUpdatedAt]}} ->
                case is_integer(ExpectedUpdatedAt) andalso ExpectedUpdatedAt > 0 andalso ExpectedUpdatedAt =/= OldUpdatedAt of
                    true -> {error, webhook_changed_elsewhere};
                    false ->
                        Name = case maps:is_key(<<"name">>, Patch) of true -> pw_util:clean_text(maps:get(<<"name">>, Patch), 80); false -> OldName end,
                        Url = case maps:is_key(<<"url">>, Patch) of true -> pw_util:clean_text(maps:get(<<"url">>, Patch), 2048); false -> OldUrl end,
                        Enabled = case maps:is_key(<<"enabled">>, Patch) of true -> pw_util:bool(maps:get(<<"enabled">>, Patch)); false -> OldEnabled end,
                        EventsResult = case maps:is_key(<<"events">>, Patch) of
                            true -> normalize_webhook_events(maps:get(<<"events">>, Patch));
                            false -> {ok, webhook_events_from_storage(OldEvents)}
                        end,
                        case {byte_size(Name) >= 2, pw_outbound_url:allowed(Url), EventsResult} of
                            {false, _, _} -> {error, invalid_webhook_name};
                            {_, false, _} -> {error, blocked_webhook_url};
                            {_, _, error} -> {error, invalid_webhook_events};
                            {true, true, {ok, Events}} ->
                                Now = pw_util:now_ms(),
                                ok = exec(Conn,
                                    "UPDATE server_webhooks SET name=$1,url=$2,events=$3,enabled=$4,updated_at=$5 WHERE id=$6 AND server_id=$7",
                                    [Name, Url, webhook_events_storage(Events), Enabled, Now, WebhookId, Sid]),
                                {ok, #{id => WebhookId, server_id => Sid, name => Name, url => Url,
                                       events => Events, enabled => Enabled, updated_at => Now}}
                        end
                end;
            {true, _} -> {error, not_found}
        end
    end),
    Result;
route({delete_server_webhook, Uid, Sid0, WebhookId0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>) of
        false -> {error, forbidden};
        true ->
            case one(Conn, "DELETE FROM server_webhooks WHERE id=$1 AND server_id=$2 RETURNING id", [WebhookId, Sid]) of
                {ok, [_]} -> {ok, #{deleted => true, id => WebhookId}};
                _ -> {error, not_found}
            end
    end;
route({rotate_server_webhook, Uid, Sid0, WebhookId0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>) of
        false -> {error, forbidden};
        true ->
            Secret = pw_util:random_token(32), Now = pw_util:now_ms(),
            case one(Conn,
                "UPDATE server_webhooks SET secret=$1,updated_at=$2 WHERE id=$3 AND server_id=$4 RETURNING id",
                [store_message(Secret), Now, WebhookId, Sid]) of
                {ok, [_]} -> {ok, #{id => WebhookId, secret => Secret, updated_at => Now}};
                _ -> {error, not_found}
            end
    end;
route({test_server_webhook, Uid, Sid0, WebhookId0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>) of
        false -> {error, forbidden};
        true ->
            case one(Conn, "SELECT id FROM server_webhooks WHERE id=$1 AND server_id=$2 AND enabled=true", [WebhookId, Sid]) of
                {ok, [_]} ->
                    Event = <<"webhook.test">>,
                    Payload = webhook_payload(Event, Sid, #{webhook_id => WebhookId, actor_id => Uid, message => <<"Plainwire webhook test">>}),
                    Now = pw_util:now_ms(),
                    {ok, DeliveryId} = insert_returning(Conn,
                        "INSERT INTO webhook_deliveries(webhook_id,event,payload,subject_user_id,actor_user_id,status,attempts,next_attempt_at,created_at,updated_at) "
                        "VALUES($1,$2,$3,NULL,$4,'pending',0,$5,$5,$5) RETURNING id",
                        [WebhookId, Event, store_message(Payload), Uid, Now]),
                    {ok, #{queued => true, delivery_id => DeliveryId}};
                _ -> {error, not_found}
            end
    end;
route({server_webhook_deliveries, Uid, Sid0, WebhookId0, Limit0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0),
    Limit = min(100, max(1, int_or(pw_util:int(Limit0), 25))),
    case {has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>),
          one(Conn, "SELECT id FROM server_webhooks WHERE id=$1 AND server_id=$2", [WebhookId,Sid])} of
        {false, _} -> {error, forbidden};
        {true, {ok, [_]}} ->
            {ok, Rows} = rows(Conn,
                "SELECT id,event,status,attempts,next_attempt_at,response_code,last_error,created_at,updated_at FROM webhook_deliveries WHERE webhook_id=$1 ORDER BY id DESC LIMIT $2",
                [WebhookId,Limit]),
            {ok, [#{id => Id,event => Event,status => Status,attempts => Attempts,next_attempt_at => Next,
                    response_code => Code,last_error => Err,created_at => Created,updated_at => Updated}
                  || [Id,Event,Status,Attempts,Next,Code,Err,Created,Updated] <- Rows]};
        {true, _} -> {error, not_found}
    end;
route({retry_server_webhook_delivery, Uid, Sid0, WebhookId0, DeliveryId0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0), DeliveryId = pw_util:int(DeliveryId0), Now = pw_util:now_ms(),
    with_tx(Conn, fun() ->
        case {has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>),
              one(Conn, "SELECT d.status,octet_length(d.payload) FROM webhook_deliveries d JOIN server_webhooks w ON w.id=d.webhook_id WHERE d.id=$1 AND d.webhook_id=$2 AND w.server_id=$3 FOR UPDATE", [DeliveryId,WebhookId,Sid])} of
            {false, _} -> {error, forbidden};
            {true, {ok, [<<"failed">>, Size]}} when is_integer(Size), Size > 0 ->
                ok = exec(Conn, "UPDATE webhook_deliveries SET status='pending',attempts=0,next_attempt_at=$1,locked_at=0,response_code=0,last_error='',updated_at=$1 WHERE id=$2", [Now,DeliveryId]),
                {ok, #{queued => true, delivery_id => DeliveryId}};
            {true, {ok, [<<"failed">>, _]}} -> {error, retry_payload_unavailable};
            {true, {ok, [_Status, _]}} -> {error, delivery_not_failed};
            {true, _} -> {error, not_found}
        end
    end);
route({incoming_webhooks, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>) of
        false -> {error, forbidden};
        true ->
            {ok, Rows} = rows(Conn,
                "SELECT w.id,w.channel_id,w.bot_user_id,w.name,w.enabled,w.created_by,w.created_at,w.updated_at,w.last_used_at,c.name FROM incoming_webhooks w JOIN channels c ON c.id=w.channel_id WHERE w.server_id=$1 ORDER BY w.id ASC", [Sid]),
            {ok, [#{id => Id,channel_id => Cid,bot_user_id => BotUid,name => Name,enabled => Enabled,
                    created_by => CreatedBy,created_at => Created,updated_at => Updated,last_used_at => LastUsed,channel_name => ChannelName}
                  || [Id,Cid,BotUid,Name,Enabled,CreatedBy,Created,Updated,LastUsed,ChannelName] <- Rows]}
    end;
route({create_incoming_webhook, Uid, Sid0, ChannelId0, Name0}, Conn) ->
    Sid = pw_util:int(Sid0), ChannelId = pw_util:int(ChannelId0), Name = pw_util:clean_text(Name0, 80),
    case byte_size(Name) >= 2 of
        false -> {error, invalid_webhook_name};
        true -> with_tx(Conn, fun() ->
            _ = one(Conn, "SELECT id FROM servers WHERE id=$1 FOR UPDATE", [Sid]),
            case {has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>),
                  one(Conn, "SELECT id FROM channels WHERE id=$1 AND server_id=$2 AND kind='text'", [ChannelId,Sid])} of
                {false, _} -> {error, forbidden};
                {true, {ok, [_]}} ->
                    {ok,[Count]} = one(Conn, "SELECT count(*) FROM incoming_webhooks WHERE server_id=$1", [Sid]),
                    case Count >= 50 of
                        true -> {error, webhook_limit};
                        false ->
                            Token = <<"pwi_", (pw_util:random_token(40))/binary>>, Hash = pw_util:sha256_hex(Token),
                            Salt = pw_util:random_token(18), PasswordHash = pw_util:pbkdf2(pw_util:random_token(32), Salt), Now = pw_util:now_ms(),
                            Username = unique_bot_username(Conn, Sid, <<Name/binary, "-hook">>),
                            {ok,BotUid} = insert_returning(Conn,
                                "INSERT INTO users(username,display_name,password_hash,password_salt,bio,avatar_url,banner_url,status,theme,created_at,updated_at,last_seen,account_state,disabled_at,is_bot) VALUES($1,$2,$3,$4,'','','','','system',$5,$5,$5,'active',0,true) RETURNING id",
                                [Username,Name,PasswordHash,Salt,Now]),
                            ok = exec(Conn, "INSERT INTO server_members(server_id,user_id,role,joined_at) VALUES($1,$2,'member',$3)", [Sid,BotUid,Now]),
                            {ok,Id} = insert_returning(Conn,
                                "INSERT INTO incoming_webhooks(server_id,channel_id,bot_user_id,name,token_hash,enabled,created_by,created_at,updated_at,last_used_at) VALUES($1,$2,$3,$4,$5,true,$6,$7,$7,0) RETURNING id",
                                [Sid,ChannelId,BotUid,Name,Hash,Uid,Now]),
                            {ok, #{id => Id,server_id => Sid,channel_id => ChannelId,bot_user_id => BotUid,name => Name,token => Token,
                                   path => <<"/api/webhooks/",(integer_to_binary(Id))/binary,"/",Token/binary>>,created_at => Now}}
                    end;
                {true, _} -> {error, invalid_channel}
            end
        end)
    end;
route({rotate_incoming_webhook, Uid, Sid0, WebhookId0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>) of
        false -> {error, forbidden};
        true ->
            Token = <<"pwi_", (pw_util:random_token(40))/binary>>, Hash = pw_util:sha256_hex(Token), Now = pw_util:now_ms(),
            case one(Conn, "UPDATE incoming_webhooks SET token_hash=$1,updated_at=$2 WHERE id=$3 AND server_id=$4 RETURNING id", [Hash,Now,WebhookId,Sid]) of
                {ok,[_]} -> {ok, #{id => WebhookId,token => Token,path => <<"/api/webhooks/",(integer_to_binary(WebhookId))/binary,"/",Token/binary>>,updated_at => Now}};
                _ -> {error, not_found}
            end
    end;
route({delete_incoming_webhook, Uid, Sid0, WebhookId0}, Conn) ->
    Sid = pw_util:int(Sid0), WebhookId = pw_util:int(WebhookId0), Now = pw_util:now_ms(),
    with_tx(Conn, fun() ->
        case {has_server_permission(Conn, Uid, Sid, <<"manage_webhooks">>),
              one(Conn, "SELECT bot_user_id FROM incoming_webhooks WHERE id=$1 AND server_id=$2 FOR UPDATE", [WebhookId,Sid])} of
            {false,_} -> {error, forbidden};
            {true,{ok,[BotUid]}} ->
                ok = exec(Conn, "DELETE FROM incoming_webhooks WHERE id=$1", [WebhookId]),
                ok = exec(Conn, "DELETE FROM server_members WHERE server_id=$1 AND user_id=$2", [Sid,BotUid]),
                ok = exec(Conn, "UPDATE users SET account_state='disabled',disabled_at=$1,updated_at=$1 WHERE id=$2", [Now,BotUid]),
                {ok, #{deleted => true,id => WebhookId}};
            {true,_} -> {error, not_found}
        end
    end);
route({execute_incoming_webhook, WebhookId0, Token0, Body0, ReplyTo0}, Conn) ->
    WebhookId = pw_util:int(WebhookId0), Token = pw_util:clean_text(Token0, 256), Plain = pw_util:clean_text(Body0, ?MAX_MSG), ReplyTo = pw_util:int(ReplyTo0),
    case message_body_valid(Plain) andalso extract_file_ids(Plain) =:= [] of
        false -> {error, invalid_message};
        true ->
            Result = with_tx(Conn, fun() ->
                case one(Conn,
                    "SELECT w.server_id,w.channel_id,w.bot_user_id,w.token_hash FROM incoming_webhooks w JOIN users u ON u.id=w.bot_user_id JOIN channels c ON c.id=w.channel_id WHERE w.id=$1 AND w.enabled=true AND u.account_state='active' AND c.kind='text' FOR UPDATE",
                    [WebhookId]) of
                    {ok,[Sid,Cid,BotUid,ExpectedHash]} ->
                        case secure_token_hash_match(Token, ExpectedHash) andalso valid_reply_to(Conn, <<"channel">>, Cid, ReplyTo) of
                            false -> {error, invalid_webhook_token};
                            true ->
                                Now = pw_util:now_ms(), Mid = new_message_id(), Stored = store_message(Plain),
                                ok = exec(Conn, "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,'channel',$2,$3,$4,$5,$6)", [Mid,Cid,BotUid,Stored,ReplyTo,Now]),
                                ok = exec(Conn, "UPDATE incoming_webhooks SET last_used_at=$1 WHERE id=$2", [Now,WebhookId]),
                                ok = storage_after_message_change(Conn, Mid, <<"message.created">>, BotUid),
                                {ok,Row} = one(Conn, message_select() ++ " WHERE m.id=$1", [Mid]), Msg = message_map(Conn,Row),
                                ok = maybe_enqueue_message_webhook(Conn, <<"channel">>, Cid, <<"message.created">>, #{message => Msg,actor_id => BotUid,source => <<"incoming_webhook">>,incoming_webhook_id => WebhookId}),
                                {ok, #{message => Msg,server_id => Sid,channel_id => Cid,notify_at => Now}}
                        end;
                    _ -> {error, invalid_webhook_token}
                end
            end),
            case Result of
                {ok,#{message := Msg,server_id := Sid,channel_id := Cid,notify_at := Now}} ->
                    invalidate_message_cache(<<"channel">>,Cid),
                    pw_hub:broadcast({channel,Cid},#{type => message_created,scope => channel,scope_id => Cid,message => Msg}),
                    best_effort_channel_notifications(Conn,Sid,maps:get(user_id,Msg),Cid,Msg,Now,false),
                    %% Incoming webhooks are write-only credentials. Do not echo
                    %% the serialized message because reply metadata can contain
                    %% another user's message body.
                    {ok,#{message_id => maps:get(id,Msg), channel_id => Cid, created_at => maps:get(created_at,Msg)}};
                Other -> Other
            end
    end;

route({storage_outbox_claim, Limit0}, Conn) ->
    Limit = min(100, max(1, case pw_util:int(Limit0) of undefined -> 25; I -> I end)),
    Now = pw_util:now_ms(),
    %% Never reclaim an item while a legitimately slow but bounded Scylla
    %% operation can still be running. Duplicate delivery is idempotent, but
    %% avoiding needless concurrent retries protects hot partitions.
    ScyllaTimeout = maps:get(operation_timeout_ms, pw_scylla_config:config(), 8000),
    LeaseMs = max(60000, ?MAX_STORAGE_OUTBOX_CQL_OPS * ScyllaTimeout + 30000),
    LeaseCutoff = Now - LeaseMs,
    with_tx(Conn, fun() ->
        ok = exec(Conn,
            "UPDATE storage_outbox SET status='pending',locked_at=0,updated_at=$1 WHERE status='running' AND locked_at>0 AND locked_at<$2",
            [Now, LeaseCutoff]),
        {ok, Rows} = rows(Conn,
            "WITH picked AS (SELECT o.id FROM storage_outbox o WHERE o.status='pending' AND o.next_attempt_at<=$1 "
            "AND (o.kind NOT IN ('message.upsert','message.hard_delete') OR NOT EXISTS ("
            "SELECT 1 FROM storage_outbox older WHERE older.entity_id=o.entity_id AND older.id<o.id "
            "AND older.kind IN ('message.upsert','message.hard_delete') AND older.status IN ('pending','running'))) "
            "ORDER BY o.id ASC FOR UPDATE OF o SKIP LOCKED LIMIT $2) "
            "UPDATE storage_outbox o SET status='running',attempts=o.attempts+1,locked_at=$1,updated_at=$1 FROM picked p "
            "WHERE o.id=p.id RETURNING o.id,o.kind,o.entity_id,o.payload,o.attempts,o.entity_scope,o.entity_scope_id,o.entity_created_at", [Now, Limit]),
        {ok, [#{id => Id, kind => Kind, entity_id => EntityId, payload => Payload, attempts => Attempts,
                entity_scope => EntityScope, entity_scope_id => EntityScopeId, entity_created_at => EntityCreatedAt}
              || [Id,Kind,EntityId,Payload,Attempts,EntityScope,EntityScopeId,EntityCreatedAt] <- Rows]}
    end);
route({storage_outbox_finish, Id0, Result}, Conn) ->
    Id = pw_util:int(Id0), Now = pw_util:now_ms(),
    with_tx(Conn, fun() ->
        case one(Conn, "SELECT kind,attempts FROM storage_outbox WHERE id=$1 FOR UPDATE", [Id]) of
            {ok, [Kind, Attempts]} ->
                case Result of
                    ok ->
                        ok = exec(Conn, "UPDATE storage_outbox SET status='delivered',locked_at=0,last_error='',updated_at=$1 WHERE id=$2", [Now, Id]),
                        {ok, #{delivered => true}};
                    {error, Reason0} ->
                        SafeReason = pw_storage_sanitize:safe_reason(Reason0),
                        Reason = pw_util:clean_text(io_lib:format("~0p", [SafeReason]), 400),
                        %% Privacy hard-deletes are never abandoned. Account/server
                        %% deletion has already removed the PostgreSQL source row, so
                        %% a terminal outbox failure here would violate deletion
                        %% semantics. Retry forever with bounded backoff and expose the
                        %% persistent backlog through storage health/metrics.
                        DurableKind = pw_util:bin(Kind),
                        NeverAbandon = lists:member(DurableKind, [<<"message.hard_delete">>, <<"message.upsert">>]),
                        PrivacyDelete = (DurableKind =:= <<"message.hard_delete">>),
                        case Attempts >= 20 andalso not NeverAbandon of
                            true ->
                                ok = exec(Conn, "UPDATE storage_outbox SET status='failed',locked_at=0,last_error=$1,updated_at=$2 WHERE id=$3", [Reason,Now,Id]),
                                {ok, #{failed => true, retrying => false}};
                            false ->
                                Delay = storage_retry_delay_ms(Attempts),
                                ok = exec(Conn, "UPDATE storage_outbox SET status='pending',locked_at=0,last_error=$1,next_attempt_at=$2,updated_at=$3 WHERE id=$4", [Reason,Now+Delay,Now,Id]),
                                case PrivacyDelete of true -> pw_storage_metrics:incr(storage_privacy_delete_retry); false -> ok end,
                                {ok, #{failed => true, retrying => true, privacy_delete => PrivacyDelete, retry_in_ms => Delay}}
                        end;
                    _ -> {error, invalid_result}
                end;
            _ -> {error, not_found}
        end
    end);
route({storage_pg_message_get, Id0}, Conn) ->
    case pw_util:int(Id0) of
        Id when is_integer(Id), Id > 0 -> message_core(Conn, Id);
        _ -> {error, not_found}
    end;
route({storage_pg_message_recent, Scope0, ScopeId0, Limit0}, Conn) ->
    storage_pg_timeline(Conn, Scope0, ScopeId0, recent, undefined, Limit0);
route({storage_pg_message_before, Scope0, ScopeId0, Before0, Limit0}, Conn) ->
    storage_pg_timeline(Conn, Scope0, ScopeId0, before, Before0, Limit0);
route({storage_pg_message_after, Scope0, ScopeId0, After0, Limit0}, Conn) ->
    storage_pg_timeline(Conn, Scope0, ScopeId0, 'after', After0, Limit0);
route({storage_pg_message_bulk, Ids0}, Conn) ->
    Ids = lists:sublist(lists:usort([I || X <- normalize_list(Ids0), I <- [pw_util:int(X)], is_integer(I), I > 0]), 250),
    case Ids of
        [] -> {ok, #{}};
        _ ->
            N = length(Ids),
            Placeholders = string:join(["$" ++ integer_to_list(I) || I <- lists:seq(1, N)], ","),
            Sql = "SELECT id,scope,scope_id,user_id,body,COALESCE(reply_to_id,0),created_at,COALESCE(edited_at,0),COALESCE(deleted_at,0),kind,COALESCE(forwarded_from_id,0) FROM messages WHERE id IN (" ++ Placeholders ++ ")",
            case rows(Conn, Sql, Ids) of
                {ok, Rs} -> {ok, maps:from_list([{maps:get(id, M), M} || R <- Rs, M <- [message_core_map(R)]])};
                Error -> Error
            end
    end;
route({storage_pg_message_edit, Id0, Body0, EditedAt0}, Conn) ->
    Id = pw_util:int(Id0), EditedAt = pw_util:int(EditedAt0),
    Body = case Body0 of Bin when is_binary(Bin) -> Bin; _ -> invalid end,
    case {Id, Body, EditedAt} of
        {I, B, T} when is_integer(I), I > 0, is_binary(B), is_integer(T), T > 0 ->
            case one(Conn, "UPDATE messages SET body=$1,edited_at=$2 WHERE id=$3 AND deleted_at IS NULL RETURNING id", [B,T,I]) of
                {ok, [_]} -> ok;
                _ -> {error, not_found}
            end;
        _ -> {error, bad_request}
    end;
route({storage_pg_message_delete, Id0, _ActorId}, Conn) ->
    Id = pw_util:int(Id0), Now = pw_util:now_ms(),
    case Id of
        I when is_integer(I), I > 0 ->
            case one(Conn, "UPDATE messages SET body='',deleted_at=$1 WHERE id=$2 AND deleted_at IS NULL RETURNING id", [Now,I]) of
                {ok, [_]} -> ok;
                _ -> {error, not_found}
            end;
        _ -> {error, bad_request}
    end;
route(storage_status, Conn) ->
    Now = pw_util:now_ms(),
    {ok, Counts} = rows(Conn,
        "SELECT status,count(*),COALESCE(min(created_at),0),COALESCE(max(updated_at),0) FROM storage_outbox GROUP BY status ORDER BY status", []),
    Outbox = maps:from_list([{pw_util:bin(Status), #{count => Count, oldest_created_at => Oldest, newest_updated_at => Newest}}
                             || [Status,Count,Oldest,Newest] <- Counts]),
    {ok, CriticalRows} = rows(Conn,
        "SELECT kind,count(*),COALESCE(min(created_at),0),COALESCE(max(attempts),0) FROM storage_outbox "
        "WHERE status IN ('pending','running') AND kind IN ('message.upsert','message.hard_delete') "
        "GROUP BY kind ORDER BY kind", []),
    Critical = maps:from_list([{pw_util:bin(Kind), #{count => Count, oldest_created_at => Oldest, max_attempts => MaxAttempts}}
                              || [Kind,Count,Oldest,MaxAttempts] <- CriticalRows]),
    Checkpoint = case one(Conn, "SELECT last_id,rows_done,updated_at FROM storage_migration_checkpoints WHERE name='messages'", []) of
        {ok, [Last,Done,Updated]} -> #{last_id => Last, rows_done => Done, updated_at => Updated};
        _ -> #{last_id => 0, rows_done => 0, updated_at => 0}
    end,
    {ok, #{timestamp => Now, backend => pw_scylla_config:backend(), storage => storage_health_summary(),
           outbox => Outbox, critical_outbox => Critical, migration => Checkpoint, gate => pw_scylla_gate:stats()}};
route(storage_outbox_prune, Conn) ->
    Now = pw_util:now_ms(),
    DeliveredDays = min(365, max(1, pw_util:env_int("PLAINWIRE_STORAGE_OUTBOX_RETENTION_DAYS", 7))),
    FailedDays = min(3650, max(DeliveredDays, pw_util:env_int("PLAINWIRE_STORAGE_OUTBOX_FAILED_RETENTION_DAYS", 30))),
    DeliveredCutoff = Now - DeliveredDays * 86400000,
    FailedCutoff = Now - FailedDays * 86400000,
    {ok, DeliveredRows} = rows(Conn, "DELETE FROM storage_outbox WHERE status='delivered' AND updated_at < $1 RETURNING id", [DeliveredCutoff]),
    {ok, FailedRows} = rows(Conn, "DELETE FROM storage_outbox WHERE status='failed' AND updated_at < $1 RETURNING id", [FailedCutoff]),
    {ok, #{delivered_deleted => length(DeliveredRows), failed_deleted => length(FailedRows),
           delivered_retention_days => DeliveredDays, failed_retention_days => FailedDays}};
route({storage_migration_page, After0, Limit0}, Conn) ->
    After = case pw_util:int(After0) of undefined -> 0; A -> max(0,A) end,
    Limit = min(1000, max(1, case pw_util:int(Limit0) of undefined -> 250; L -> L end)),
    {ok, Rows} = rows(Conn,
        "SELECT id,scope,scope_id,user_id,body,COALESCE(reply_to_id,0),created_at,COALESCE(edited_at,0),COALESCE(deleted_at,0),kind,COALESCE(forwarded_from_id,0) "
        "FROM messages WHERE id>$1 ORDER BY id ASC LIMIT $2", [After,Limit]),
    {ok, [message_core_map(R) || R <- Rows]};
route({storage_reconcile_page, Limit0}, Conn) ->
    Limit = min(5000, max(1, case pw_util:int(Limit0) of undefined -> 500; L -> L end)),
    {ok, Rows} = rows(Conn,
        "SELECT id,scope,scope_id,user_id,body,COALESCE(reply_to_id,0),created_at,COALESCE(edited_at,0),COALESCE(deleted_at,0),kind,COALESCE(forwarded_from_id,0) "
        "FROM messages ORDER BY id DESC LIMIT $1", [Limit]),
    {ok, [message_core_map(R) || R <- lists:reverse(Rows)]};
route(storage_migration_checkpoint, Conn) ->
    case one(Conn, "SELECT last_id,rows_done,updated_at FROM storage_migration_checkpoints WHERE name='messages'", []) of
        {ok, [Last,Done,Updated]} -> {ok, #{last_id => Last, rows_done => Done, updated_at => Updated}};
        _ -> {ok, #{last_id => 0, rows_done => 0, updated_at => 0}}
    end;
route({storage_migration_set_checkpoint, Last0, Done0}, Conn) ->
    Last = max(0, case pw_util:int(Last0) of undefined -> 0; L -> L end),
    Done = max(0, case pw_util:int(Done0) of undefined -> 0; D -> D end),
    Now = pw_util:now_ms(),
    ok = exec(Conn, "INSERT INTO storage_migration_checkpoints(name,last_id,rows_done,updated_at) VALUES('messages',$1,$2,$3) "
                    "ON CONFLICT(name) DO UPDATE SET last_id=EXCLUDED.last_id,rows_done=EXCLUDED.rows_done,updated_at=EXCLUDED.updated_at", [Last,Done,Now]),
    case Done > 0 of true -> ok = mark_scylla_seen(Conn, Now); false -> ok end,
    {ok, #{last_id => Last, rows_done => Done, updated_at => Now}};
route({webhook_claim_due, Limit0}, Conn) ->
    Limit = min(64, max(1, int_or(pw_util:int(Limit0), 1))),
    Now = pw_util:now_ms(),
    LeaseCutoff = Now - 60000,
    with_tx(Conn, fun() ->
        %% A worker can die after claiming a row. Requeue only leases old enough
        %% that the previous HTTP request has certainly timed out.
        ok = exec(Conn,
            "UPDATE webhook_deliveries SET status='pending',locked_at=0,updated_at=$1 "
            "WHERE status='running' AND locked_at > 0 AND locked_at < $2",
            [Now, LeaseCutoff]),
        {ok, Rows} = rows(Conn,
            "WITH picked AS ("
            " SELECT d.id FROM webhook_deliveries d JOIN server_webhooks w ON w.id=d.webhook_id"
            " WHERE d.status='pending' AND d.next_attempt_at <= $1 AND w.enabled=true"
            " ORDER BY d.next_attempt_at ASC,d.id ASC FOR UPDATE OF d SKIP LOCKED LIMIT $2"
            ") UPDATE webhook_deliveries d SET status='running',attempts=d.attempts+1,locked_at=$1,updated_at=$1"
            " FROM picked p,server_webhooks w WHERE d.id=p.id AND w.id=d.webhook_id"
            " RETURNING d.id,w.url,w.secret,d.payload,d.event,d.attempts",
            [Now, Limit]),
        {ok, [#{id => Id, url => Url, secret => load_message(Secret), payload => load_message(Payload), event => Event, attempts => Attempts}
              || [Id, Url, Secret, Payload, Event, Attempts] <- Rows]}
    end);
route({webhook_finish, DeliveryId0, Result0}, Conn) ->
    DeliveryId = pw_util:int(DeliveryId0), Now = pw_util:now_ms(),
    {Result, LatencyMs} = normalize_webhook_finish_result(Result0),
    with_tx(Conn, fun() ->
        case Result of
            {ok, Code} when is_integer(Code) ->
                case one(Conn,
                    "UPDATE webhook_deliveries d SET status='delivered',payload=decode('','hex'),response_code=$1,last_error='',locked_at=0,updated_at=$2 "
                    "WHERE d.id=$3 RETURNING webhook_id,attempts", [Code, Now, DeliveryId]) of
                    {ok, [WebhookId, Attempts]} ->
                        _ = exec(Conn, "UPDATE server_webhooks SET last_success_at=$1,failure_count=0 WHERE id=$2", [Now, WebhookId]),
                        ok = maybe_queue_webhook_delivery_event(Conn, WebhookId, DeliveryId, Attempts, delivered, Code, LatencyMs, <<>>, Now),
                        {ok, #{delivered => true}};
                    _ -> {error, not_found}
                end;
            {error, Reason0} ->
                Reason = pw_util:clean_text(Reason0, 500),
                case one(Conn, "SELECT webhook_id,attempts FROM webhook_deliveries WHERE id=$1 FOR UPDATE", [DeliveryId]) of
                    {ok, [WebhookId, Attempts]} ->
                        _ = exec(Conn, "UPDATE server_webhooks SET last_failure_at=$1,failure_count=failure_count+1 WHERE id=$2", [Now, WebhookId]),
                        case Attempts >= 6 of
                            true ->
                                ok = exec(Conn,
                                    "UPDATE webhook_deliveries SET status='failed',last_error=$1,locked_at=0,updated_at=$2 WHERE id=$3",
                                    [Reason, Now, DeliveryId]),
                                ok = maybe_queue_webhook_delivery_event(Conn, WebhookId, DeliveryId, Attempts, failed, 0, LatencyMs, Reason, Now),
                                {ok, #{failed => true, retrying => false}};
                            false ->
                                Delay = webhook_retry_delay_ms(Attempts),
                                ok = exec(Conn,
                                    "UPDATE webhook_deliveries SET status='pending',last_error=$1,next_attempt_at=$2,locked_at=0,updated_at=$3 WHERE id=$4",
                                    [Reason, Now + Delay, Now, DeliveryId]),
                                ok = maybe_queue_webhook_delivery_event(Conn, WebhookId, DeliveryId, Attempts, retrying, 0, LatencyMs, Reason, Now),
                                {ok, #{failed => true, retrying => true, retry_in_ms => Delay}}
                        end;
                    _ -> {error, not_found}
                end;
            _ -> {error, invalid_result}
        end
    end);
route(webhook_prune, Conn) ->
    Now = pw_util:now_ms(),
    DeliveredDays = min(365, max(1, pw_util:env_int("PLAINWIRE_WEBHOOK_DELIVERED_RETENTION_DAYS", 7))),
    FailedDays = min(3650, max(DeliveredDays, pw_util:env_int("PLAINWIRE_WEBHOOK_FAILED_RETENTION_DAYS", 30))),
    DeliveredCutoff = Now - DeliveredDays * 86400000,
    FailedCutoff = Now - FailedDays * 86400000,
    {ok, DeliveredRows} = rows(Conn,
        "DELETE FROM webhook_deliveries WHERE status='delivered' AND updated_at < $1 RETURNING id", [DeliveredCutoff]),
    {ok, FailedRows} = rows(Conn,
        "DELETE FROM webhook_deliveries WHERE status='failed' AND updated_at < $1 RETURNING id", [FailedCutoff]),
    {ok, #{delivered_deleted => length(DeliveredRows), failed_deleted => length(FailedRows),
           delivered_retention_days => DeliveredDays, failed_retention_days => FailedDays}};

route({developer_apps, Uid}, Conn) ->
    {ok, Rows} = rows(Conn, developer_app_select() ++ " WHERE a.owner_user_id=$1 ORDER BY a.updated_at DESC,a.id DESC", [Uid]),
    {ok, [developer_app_map(Row) || Row <- Rows]};
route({developer_app, Uid, AppId0}, Conn) ->
    AppId = pw_util:int(AppId0),
    case developer_app_owned_row(Conn, Uid, AppId, false) of
        {ok, Row} -> {ok, developer_app_map(Row)};
        _ -> {error, not_found}
    end;
route({public_developer_apps, Query0, Limit0}, Conn) ->
    Query = pw_util:clean_text(Query0, 80), Limit = clamp_int(Limit0, 1, 50, 20),
    Pattern = <<"%", Query/binary, "%">>,
    {ok, Rows} = rows(Conn,
        "SELECT a.public_id,a.name,a.description,a.avatar_url,a.default_permissions,a.created_at,a.updated_at,count(di.id) "
        "FROM developer_applications a LEFT JOIN developer_app_installations di ON di.app_id=a.id "
        "WHERE a.public=true AND ($1='' OR a.name ILIKE $2 OR a.description ILIKE $2) "
        "GROUP BY a.id ORDER BY count(di.id) DESC,a.name ASC,a.id ASC LIMIT $3",
        [Query, Pattern, Limit]),
    {ok, [#{public_id => PublicId, name => Name, description => Description,
            avatar_url => pw_util:proxied_image(Avatar), default_permissions => pw_permissions:sanitize(Permissions),
            created_at => CreatedAt, updated_at => UpdatedAt, installation_count => Count}
          || [PublicId, Name, Description, Avatar, Permissions, CreatedAt, UpdatedAt, Count] <- Rows]};
route({public_developer_app, PublicId0}, Conn) ->
    PublicId = pw_util:clean_text(PublicId0, 96),
    case one(Conn, developer_app_select() ++ " WHERE a.public_id=$1 AND a.public=true", [PublicId]) of
        {ok, Row} ->
            App = developer_app_map(Row),
            {ok, Commands} = rows(Conn,
                "SELECT name,description,options_json,handler FROM developer_app_commands WHERE app_id=$1 ORDER BY name ASC",
                [maps:get(id, App)]),
            {ok, 
(maps:without([interaction, ai, avatar_source, owner_user_id], App))#{commands => [developer_public_command_map(C) || C <- Commands]}};
        _ -> {error, not_found}
    end;
route({create_developer_app, Uid, Name0}, Conn) ->
    Name = pw_util:clean_text(Name0, 48),
    case byte_size(Name) >= 2 of
        false -> {error, invalid_app_name};
        true -> with_tx(Conn, fun() ->
            Limit = min(100, max(1, pw_util:env_int("PLAINWIRE_DEVELOPER_APP_LIMIT", 25))),
            {ok, [Count]} = one(Conn, "SELECT count(*) FROM developer_applications WHERE owner_user_id=$1", [Uid]),
            case Count >= Limit of
                true -> {error, app_limit};
                false ->
                    PublicId = unique_developer_public_id(Conn),
                    Now = pw_util:now_ms(),
                    {ok, AppId} = insert_returning(Conn,
                        "INSERT INTO developer_applications(owner_user_id,public_id,name,created_at,updated_at) VALUES($1,$2,$3,$4,$4) RETURNING id",
                        [Uid, PublicId, Name, Now]),
                    {ok, Row} = developer_app_owned_row(Conn, Uid, AppId, false),
                    {ok, developer_app_map(Row)}
            end
        end)
    end;
route({update_developer_app, Uid, AppId0, Patch}, Conn) ->
    AppId = pw_util:int(AppId0),
    with_tx(Conn, fun() ->
        case developer_app_owned_row(Conn, Uid, AppId, true) of
            {ok, Row0} ->
                Current = developer_app_map(Row0),
                Name = case maps:is_key(<<"name">>, Patch) of true -> pw_util:clean_text(maps:get(<<"name">>, Patch), 48); false -> maps:get(name, Current) end,
                Description = case maps:is_key(<<"description">>, Patch) of true -> pw_util:clean_text(maps:get(<<"description">>, Patch), 500); false -> maps:get(description, Current) end,
                Avatar = case maps:is_key(<<"avatar_url">>, Patch) of
                    true -> developer_app_avatar(Conn, Uid, maps:get(<<"avatar_url">>, Patch, <<>>));
                    false -> maps:get(avatar_source, Current, <<>>)
                end,
                Public = case maps:get(<<"public">>, Patch, maps:get(public, Current)) of true -> true; _ -> false end,
                Permissions = case maps:is_key(<<"default_permissions">>, Patch) of
                    true -> pw_permissions:sanitize(maps:get(<<"default_permissions">>, Patch, 0));
                    false -> maps:get(default_permissions, Current, 0)
                end,
                case byte_size(Name) >= 2 of
                    false -> {error, invalid_app_name};
                    true ->
                        Now = pw_util:now_ms(),
                        ok = exec(Conn, "UPDATE developer_applications SET name=$1,description=$2,avatar_url=$3,public=$4,default_permissions=$5,updated_at=$6 WHERE id=$7 AND owner_user_id=$8",
                                  [Name, Description, Avatar, Public, Permissions, Now, AppId, Uid]),
                        %% Keep installed bot identity consistent with the app without
                        %% changing server-scoped usernames or roles unexpectedly.
                        ok = exec(Conn,
                            "UPDATE users SET display_name=$1,bio=$2,avatar_url=$3,updated_at=$4 WHERE id IN (SELECT b.bot_user_id FROM developer_app_installations di JOIN server_bots b ON b.id=di.server_bot_id WHERE di.app_id=$5)",
                            [Name, Description, Avatar, Now, AppId]),
                        {ok, BotRows} = rows(Conn,
                            "SELECT b.bot_user_id FROM developer_app_installations di JOIN server_bots b ON b.id=di.server_bot_id WHERE di.app_id=$1", [AppId]),
                        [sync_profile_upload_refs(Conn, BotUid, Avatar, <<>>, Now) || [BotUid] <- BotRows],
                        {ok, Row} = developer_app_owned_row(Conn, Uid, AppId, false),
                        {ok, developer_app_map(Row)}
                end;
            _ -> {error, not_found}
        end
    end);
route({delete_developer_app, Uid, AppId0}, Conn) ->
    AppId = pw_util:int(AppId0),
    with_tx(Conn, fun() ->
        case developer_app_owned_row(Conn, Uid, AppId, true) of
            {ok, _} ->
                {ok, Installs} = rows(Conn,
                    "SELECT id,server_id,server_bot_id,COALESCE(role_id,0) FROM developer_app_installations WHERE app_id=$1 ORDER BY id ASC FOR UPDATE", [AppId]),
                lists:foreach(fun([InstallId, Sid, BotId, RoleId]) ->
                    ok = uninstall_developer_app_internal(Conn, AppId, InstallId, Sid, BotId, RoleId, Uid)
                end, Installs),
                ok = exec(Conn, "DELETE FROM developer_applications WHERE id=$1 AND owner_user_id=$2", [AppId, Uid]),
                {ok, #{deleted => true, id => AppId}};
            _ -> {error, not_found}
        end
    end);
route({developer_app_installations, Uid, AppId0}, Conn) ->
    AppId = pw_util:int(AppId0),
    case developer_app_owned_row(Conn, Uid, AppId, false) of
        {ok, _} ->
            {ok, Rows} = rows(Conn,
                "SELECT di.id,di.server_id,s.name,di.server_bot_id,b.bot_user_id,u.username,u.display_name,u.avatar_url,COALESCE(di.role_id,0),di.installed_by,di.created_at "
                "FROM developer_app_installations di JOIN servers s ON s.id=di.server_id JOIN server_bots b ON b.id=di.server_bot_id JOIN users u ON u.id=b.bot_user_id "
                "WHERE di.app_id=$1 ORDER BY s.name ASC,di.id ASC", [AppId]),
            {ok, [developer_installation_map(R) || R <- Rows]};
        _ -> {error, not_found}
    end;
route({server_apps, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
        false -> {error, forbidden};
        true ->
            {ok, Rows} = rows(Conn,
                "SELECT di.id,a.id,a.public_id,a.name,a.description,a.avatar_url,di.server_bot_id,b.bot_user_id,u.username,u.display_name,COALESCE(di.role_id,0),di.installed_by,di.created_at "
                "FROM developer_app_installations di JOIN developer_applications a ON a.id=di.app_id JOIN server_bots b ON b.id=di.server_bot_id JOIN users u ON u.id=b.bot_user_id "
                "WHERE di.server_id=$1 ORDER BY a.name ASC,di.id ASC", [Sid]),
            {ok, [server_app_map(R) || R <- Rows]}
    end;
route({server_app_commands, Uid, Sid0, InstallId0}, Conn) ->
    Sid = pw_util:int(Sid0), InstallId = pw_util:int(InstallId0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
        false -> {error, forbidden};
        true ->
            case one(Conn, "SELECT server_bot_id FROM developer_app_installations WHERE id=$1 AND server_id=$2", [InstallId, Sid]) of
                {ok, [BotId]} ->
                    {ok, CommandRows} = rows(Conn,
                        "SELECT id,name,description,options_json,enabled,created_at,updated_at,handler FROM bot_commands WHERE bot_id=$1 AND server_id=$2 ORDER BY name ASC",
                        [BotId, Sid]),
                    {ok, [server_app_command_map(Row, bot_command_permission_rules(Conn, lists:nth(1, Row))) || Row <- CommandRows]};
                _ -> {error, not_found}
            end
    end;
route({set_server_command_permissions, Uid, Sid0, InstallId0, CommandId0, Rules0}, Conn) ->
    Sid = pw_util:int(Sid0), InstallId = pw_util:int(InstallId0), CommandId = pw_util:int(CommandId0),
    case normalize_command_permission_rules(Rules0) of
        error -> {error, invalid_command_permissions};
        {ok, Rules} -> with_tx(Conn, fun() ->
            case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
                false -> {error, forbidden};
                true ->
                    case one(Conn,
                        "SELECT c.id FROM developer_app_installations di JOIN bot_commands c ON c.bot_id=di.server_bot_id "
                        "WHERE di.id=$1 AND di.server_id=$2 AND c.id=$3 FOR UPDATE OF c", [InstallId, Sid, CommandId]) of
                        {ok, [_]} ->
                            case validate_command_permission_subjects(Conn, Sid, Rules) of
                                false -> {error, invalid_command_permission_subject};
                                true ->
                                    Now = pw_util:now_ms(),
                                    ok = exec(Conn, "DELETE FROM bot_command_permissions WHERE command_id=$1", [CommandId]),
                                    lists:foreach(fun(#{type := Type, id := SubjectId, allow := Allow}) ->
                                        ok = exec(Conn,
                                            "INSERT INTO bot_command_permissions(command_id,subject_type,subject_id,allow,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$5)",
                                            [CommandId, Type, SubjectId, Allow, Now])
                                    end, Rules),
                                    {ok, #{command_id => CommandId, permissions => bot_command_permission_rules(Conn, CommandId), updated_at => Now}}
                            end;
                        _ -> {error, not_found}
                    end
            end
        end)
    end;
route({uninstall_server_app, Uid, Sid0, InstallId0}, Conn) ->
    Sid = pw_util:int(Sid0), InstallId = pw_util:int(InstallId0),
    with_tx(Conn, fun() ->
        case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
            false -> {error, forbidden};
            true ->
                _ = one(Conn, "SELECT id FROM servers WHERE id=$1 FOR UPDATE", [Sid]),
                case one(Conn,
                    "SELECT app_id,server_bot_id,COALESCE(role_id,0) FROM developer_app_installations WHERE id=$1 AND server_id=$2 FOR UPDATE",
                    [InstallId, Sid]) of
                    {ok, [AppId, BotId, RoleId]} ->
                        ok = uninstall_developer_app_internal(Conn, AppId, InstallId, Sid, BotId, RoleId, Uid),
                        {ok, #{deleted => true, installation_id => InstallId, server_id => Sid}};
                    _ -> {error, not_found}
                end
        end
    end);
route({install_developer_app, Uid, AppId0, Sid0}, Conn) ->
    AppId = pw_util:int(AppId0), Sid = pw_util:int(Sid0),
    with_tx(Conn, fun() ->
        case developer_app_owned_row(Conn, Uid, AppId, true) of
            {ok, Row} -> install_developer_app_internal(Conn, Uid, developer_app_map(Row), Sid);
            _ -> {error, not_found}
        end
    end);
route({install_public_developer_app, Uid, PublicId0, Sid0}, Conn) ->
    PublicId = pw_util:clean_text(PublicId0, 96), Sid = pw_util:int(Sid0),
    with_tx(Conn, fun() ->
        case one(Conn, developer_app_select() ++ " WHERE a.public_id=$1 AND a.public=true FOR UPDATE OF a", [PublicId]) of
            {ok, Row} ->
                App = developer_app_map(Row),
                case install_developer_app_internal(Conn, Uid, App, Sid) of
                    {ok, Data} ->
                        case maps:get(owner_user_id, App) =:= Uid of
                            true -> {ok, Data};
                            false -> {ok, maps:remove(token, Data)}
                        end;
                    Other -> Other
                end;
            _ -> {error, not_found}
        end
    end);
route({rotate_developer_app_installation, Uid, AppId0, InstallId0}, Conn) ->
    AppId = pw_util:int(AppId0), InstallId = pw_util:int(InstallId0),
    case developer_app_owned_row(Conn, Uid, AppId, false) of
        {ok, _} ->
            Token = <<"pwb_", (pw_util:random_token(36))/binary>>, Hash = pw_util:sha256_hex(Token), Now = pw_util:now_ms(),
            case one(Conn,
                "UPDATE server_bots b SET token_hash=$1,updated_at=$2 FROM developer_app_installations di WHERE di.id=$3 AND di.app_id=$4 AND b.id=di.server_bot_id RETURNING b.id,b.bot_user_id,di.server_id",
                [Hash, Now, InstallId, AppId]) of
                {ok, [BotId, BotUid, Sid]} -> {ok, #{installation_id => InstallId, bot_id => BotId, user_id => BotUid, server_id => Sid, token => Token, updated_at => Now}};
                _ -> {error, not_found}
            end;
        _ -> {error, not_found}
    end;
route({uninstall_developer_app, Uid, AppId0, InstallId0}, Conn) ->
    AppId = pw_util:int(AppId0), InstallId = pw_util:int(InstallId0),
    with_tx(Conn, fun() ->
        case developer_app_owned_row(Conn, Uid, AppId, true) of
            {ok, _} ->
                case one(Conn,
                    "SELECT server_id,server_bot_id,COALESCE(role_id,0) FROM developer_app_installations WHERE id=$1 AND app_id=$2 FOR UPDATE",
                    [InstallId, AppId]) of
                    {ok, [Sid, BotId, RoleId]} ->
                        ok = uninstall_developer_app_internal(Conn, AppId, InstallId, Sid, BotId, RoleId, Uid),
                        {ok, #{deleted => true, installation_id => InstallId, server_id => Sid}};
                    _ -> {error, not_found}
                end;
            _ -> {error, not_found}
        end
    end);
route({developer_app_commands, Uid, AppId0}, Conn) ->
    AppId = pw_util:int(AppId0),
    case developer_app_owned_row(Conn, Uid, AppId, false) of
        {ok, _} ->
            {ok, Rows} = rows(Conn,
                "SELECT id,name,description,options_json,handler,created_at,updated_at FROM developer_app_commands WHERE app_id=$1 ORDER BY name ASC", [AppId]),
            {ok, [developer_command_map(R) || R <- Rows]};
        _ -> {error, not_found}
    end;
route({upsert_developer_app_command, Uid, AppId0, Name0, Description0, Options0, Handler0}, Conn) ->
    AppId = pw_util:int(AppId0), Name = normalize_command_name(Name0), Description = pw_util:clean_text(Description0, 160),
    Handler = normalize_developer_handler(Handler0),
    case {Name, normalize_command_options(Options0), Handler} of
        {invalid, _, _} -> {error, invalid_command_name};
        {_, error, _} -> {error, invalid_command_options};
        {_, _, invalid} -> {error, invalid_command_handler};
        {CommandName, {ok, Options}, HandlerName} -> with_tx(Conn, fun() ->
            case developer_app_owned_row(Conn, Uid, AppId, true) of
                {ok, AppRow} ->
                    App = developer_app_map(AppRow),
                    case developer_handler_available(App, HandlerName) of
                        false -> {error, handler_not_configured};
                        true ->
                            case one(Conn,
                                "SELECT di.server_id FROM developer_app_installations di JOIN bot_commands c ON c.server_id=di.server_id AND c.name=$2 WHERE di.app_id=$1 AND c.bot_id<>di.server_bot_id LIMIT 1",
                                [AppId, CommandName]) of
                                {ok, [ConflictSid]} -> {error, {command_name_conflict, ConflictSid}};
                                _ ->
                                    Now = pw_util:now_ms(), OptionsJson = pw_util:json(Options),
                                    {ok, CmdRow} = one(Conn,
                                        "INSERT INTO developer_app_commands(app_id,name,description,options_json,handler,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$6) "
                                        "ON CONFLICT(app_id,name) DO UPDATE SET description=EXCLUDED.description,options_json=EXCLUDED.options_json,handler=EXCLUDED.handler,updated_at=EXCLUDED.updated_at "
                                        "RETURNING id,name,description,options_json,handler,created_at,updated_at",
                                        [AppId, CommandName, Description, OptionsJson, HandlerName, Now]),
                                    [DevCmdId, _, _, _, _, _, _] = CmdRow,
                                    {ok, Installs} = rows(Conn, "SELECT server_bot_id,server_id FROM developer_app_installations WHERE app_id=$1 ORDER BY id ASC", [AppId]),
                                    lists:foreach(fun([BotId, Sid]) ->
                                        case one(Conn,
                                            "INSERT INTO bot_commands(bot_id,server_id,name,description,options_json,enabled,developer_command_id,handler,created_at,updated_at) "
                                            "VALUES($1,$2,$3,$4,$5,true,$6,$7,$8,$8) ON CONFLICT(server_id,name) DO UPDATE SET description=EXCLUDED.description,options_json=EXCLUDED.options_json,enabled=true,developer_command_id=EXCLUDED.developer_command_id,handler=EXCLUDED.handler,updated_at=EXCLUDED.updated_at WHERE bot_commands.bot_id=EXCLUDED.bot_id RETURNING id",
                                            [BotId, Sid, CommandName, Description, OptionsJson, DevCmdId, HandlerName, Now]) of
                                            {ok, [_]} -> ok;
                                            _ -> throw({plainwire_error, command_name_taken})
                                        end
                                    end, Installs),
                                    {ok, developer_command_map(CmdRow)}
                            end
                    end;
                _ -> {error, not_found}
            end
        end)
    end;
route({delete_developer_app_command, Uid, AppId0, CommandId0}, Conn) ->
    AppId = pw_util:int(AppId0), CommandId = pw_util:int(CommandId0),
    case developer_app_owned_row(Conn, Uid, AppId, false) of
        {ok, _} ->
            case one(Conn, "DELETE FROM developer_app_commands WHERE id=$1 AND app_id=$2 RETURNING id", [CommandId, AppId]) of
                {ok, [_]} -> {ok, #{deleted => true, id => CommandId}};
                _ -> {error, not_found}
            end;
        _ -> {error, not_found}
    end;
route({update_developer_app_interactions, Uid, AppId0, Patch}, Conn) ->
    AppId = pw_util:int(AppId0),
    with_tx(Conn, fun() ->
        case developer_app_owned_row(Conn, Uid, AppId, true) of
            {ok, Row0} ->
                App0 = developer_app_map(Row0),
                Url = pw_util:clean_text(maps:get(<<"url">>, Patch, maps:get(url, maps:get(interaction, App0), <<>>)), 2048),
                case developer_endpoint_valid(Url) of
                    false -> {error, invalid_interaction_url};
                    true ->
                        {ok, [StoredSecret]} = one(Conn, "SELECT interaction_secret FROM developer_applications WHERE id=$1", [AppId]),
                        {SecretPlain, SecretStored, Reveal} = case {Url =/= <<>>, pw_util:bin(StoredSecret)} of
                            {true, <<>>} ->
                                Generated = <<"pwi_", (pw_util:random_token(36))/binary>>,
                                {Generated, pw_crypto:encrypt(Generated), true};
                            _ -> {<<>>, StoredSecret, false}
                        end,
                        Now = pw_util:now_ms(),
                        ok = exec(Conn, "UPDATE developer_applications SET interaction_url=$1,interaction_secret=$2,updated_at=$3 WHERE id=$4 AND owner_user_id=$5", [Url, SecretStored, Now, AppId, Uid]),
                        Base = #{url => Url, configured => Url =/= <<>> andalso pw_util:bin(SecretStored) =/= <<>>, updated_at => Now},
                        case Reveal of true -> {ok, Base#{secret => SecretPlain}}; false -> {ok, Base} end
                end;
            _ -> {error, not_found}
        end
    end);
route({rotate_developer_app_interaction_secret, Uid, AppId0}, Conn) ->
    AppId = pw_util:int(AppId0),
    case developer_app_owned_row(Conn, Uid, AppId, false) of
        {ok, Row} ->
            App = developer_app_map(Row),
            case maps:get(url, maps:get(interaction, App), <<>>) of
                <<>> -> {error, interaction_not_configured};
                _ ->
                    Secret = <<"pwi_", (pw_util:random_token(36))/binary>>, Now = pw_util:now_ms(),
                    ok = exec(Conn, "UPDATE developer_applications SET interaction_secret=$1,updated_at=$2 WHERE id=$3 AND owner_user_id=$4", [pw_crypto:encrypt(Secret), Now, AppId, Uid]),
                    {ok, #{secret => Secret, updated_at => Now}}
            end;
        _ -> {error, not_found}
    end;
route({update_developer_app_ai, Uid, AppId0, Patch}, Conn) ->
    AppId = pw_util:int(AppId0),
    with_tx(Conn, fun() ->
        case developer_app_owned_row(Conn, Uid, AppId, true) of
            {ok, Row0} ->
                App0 = developer_app_map(Row0), Ai0 = maps:get(ai, App0),
                Enabled = maps:get(<<"enabled">>, Patch, maps:get(enabled, Ai0, false)) =:= true,
                Endpoint = pw_util:clean_text(maps:get(<<"endpoint">>, Patch, maps:get(endpoint, Ai0, <<>>)), 2048),
                Model = pw_util:clean_text(maps:get(<<"model">>, Patch, maps:get(model, Ai0, <<>>)), 160),
                SystemPrompt = pw_util:clean_text(maps:get(<<"system_prompt">>, Patch, maps:get(system_prompt, Ai0, <<>>)), 8000),
                {ok, [StoredKey0]} = one(Conn, "SELECT ai_api_key FROM developer_applications WHERE id=$1", [AppId]),
                NewKey0 = pw_util:clean_text(maps:get(<<"api_key">>, Patch, <<>>), 1024),
                StoredKey = case NewKey0 of <<>> -> StoredKey0; _ -> pw_crypto:encrypt(NewKey0) end,
                ConfigOk = (not Enabled) orelse (developer_endpoint_valid(Endpoint) andalso Model =/= <<>> andalso pw_util:bin(StoredKey) =/= <<>>),
                case ConfigOk of
                    false -> {error, invalid_ai_configuration};
                    true ->
                        Now = pw_util:now_ms(),
                        ok = exec(Conn,
                            "UPDATE developer_applications SET ai_enabled=$1,ai_endpoint=$2,ai_model=$3,ai_api_key=$4,ai_system_prompt=$5,updated_at=$6 WHERE id=$7 AND owner_user_id=$8",
                            [Enabled, Endpoint, Model, StoredKey, pw_crypto:encrypt(SystemPrompt), Now, AppId, Uid]),
                        {ok, Row} = developer_app_owned_row(Conn, Uid, AppId, false),
                        {ok, maps:get(ai, developer_app_map(Row))}
                end;
            _ -> {error, not_found}
        end
    end);

route({app_interaction_claim_due, Limit0}, Conn) ->
    internal_app_claim_route(Conn, <<"webhook">>, Limit0);
route({ai_command_claim_due, Limit0}, Conn) ->
    internal_app_claim_route(Conn, <<"ai">>, Limit0);
route({app_interaction_finish, InvocationId0, Result0}, Conn) ->
    internal_app_finish_route(Conn, <<"webhook">>, InvocationId0, Result0);
route({ai_command_finish, InvocationId0, Result0}, Conn) ->
    internal_app_finish_route(Conn, <<"ai">>, InvocationId0, Result0);

route({server_bots, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
        false -> {error, forbidden};
        true ->
            {ok, Rows} = rows(Conn,
                "SELECT b.id,b.bot_user_id,b.name,u.username,u.display_name,u.avatar_url,b.created_by,b.created_at,b.updated_at,"
                "COALESCE(di.app_id,0),COALESCE(a.public_id,''),COALESCE(a.name,'') "
                "FROM server_bots b JOIN users u ON u.id=b.bot_user_id "
                "LEFT JOIN developer_app_installations di ON di.server_bot_id=b.id LEFT JOIN developer_applications a ON a.id=di.app_id "
                "WHERE b.server_id=$1 ORDER BY b.id ASC", [Sid]),
            {ok, [#{id => Id, user_id => BotUid, name => Name, username => Username, display_name => Display, avatar_url => pw_util:proxied_image(Avatar),
                    created_by => CreatedBy, created_at => CreatedAt, updated_at => UpdatedAt,
                    application_id => AppId, application_public_id => AppPublicId, application_name => AppName}
                  || [Id, BotUid, Name, Username, Display, Avatar, CreatedBy, CreatedAt, UpdatedAt, AppId, AppPublicId, AppName] <- Rows]}
    end;
route({create_server_bot, Uid, Sid0, Name0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 48),
    case byte_size(Name) >= 2 of
        false -> {error, invalid_bot_name};
        true -> with_tx(Conn, fun() ->
            _ = one(Conn, "SELECT id FROM servers WHERE id=$1 FOR UPDATE", [Sid]),
            case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
                false -> {error, forbidden};
                true ->
                    {ok, [Count]} = one(Conn, "SELECT count(*) FROM server_bots WHERE server_id=$1", [Sid]),
                    case Count >= 50 of
                        true -> {error, bot_limit};
                        false ->
                            Token = <<"pwb_", (pw_util:random_token(36))/binary>>,
                            TokenHash = pw_util:sha256_hex(Token),
                            Salt = pw_util:random_token(18),
                            PasswordHash = pw_util:pbkdf2(pw_util:random_token(32), Salt),
                            Now = pw_util:now_ms(),
                            Username = unique_bot_username(Conn, Sid, Name),
                            {ok, BotUid} = insert_returning(Conn,
                                "INSERT INTO users(username,display_name,password_hash,password_salt,bio,avatar_url,banner_url,status,theme,created_at,updated_at,last_seen,account_state,disabled_at,is_bot) "
                                "VALUES($1,$2,$3,$4,'','','','', 'system',$5,$5,$5,'active',0,true) RETURNING id",
                                [Username, Name, PasswordHash, Salt, Now]),
                            ok = exec(Conn, "INSERT INTO server_members(server_id,user_id,role,joined_at) VALUES($1,$2,'member',$3)", [Sid, BotUid, Now]),
                            {ok, BotId} = insert_returning(Conn,
                                "INSERT INTO server_bots(server_id,bot_user_id,name,token_hash,created_by,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$6) RETURNING id",
                                [Sid, BotUid, Name, TokenHash, Uid, Now]),
                            publish_server_event(Conn, Sid, #{type => bot_added, server_id => Sid, bot_user_id => BotUid}),
                            enqueue_server_webhooks(Conn, Sid, <<"bot.added">>, #{bot_user_id => BotUid, bot_id => BotId, actor_id => Uid}),
                            {ok, #{id => BotId, user_id => BotUid, name => Name, username => Username, token => Token, created_at => Now}}
                    end
            end
        end)
    end;
route({rotate_server_bot, Uid, Sid0, BotId0}, Conn) ->
    Sid = pw_util:int(Sid0), BotId = pw_util:int(BotId0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
        false -> {error, forbidden};
        true ->
            Token = <<"pwb_", (pw_util:random_token(36))/binary>>,
            Hash = pw_util:sha256_hex(Token), Now = pw_util:now_ms(),
            case one(Conn, "UPDATE server_bots SET token_hash=$1,updated_at=$2 WHERE id=$3 AND server_id=$4 RETURNING bot_user_id", [Hash, Now, BotId, Sid]) of
                {ok, [BotUid]} -> {ok, #{id => BotId, user_id => BotUid, token => Token, updated_at => Now}};
                _ -> {error, not_found}
            end
    end;
route({delete_server_bot, Uid, Sid0, BotId0}, Conn) ->
    Sid = pw_util:int(Sid0), BotId = pw_util:int(BotId0),
    with_tx(Conn, fun() ->
        case {has_server_permission(Conn, Uid, Sid, <<"manage_bots">>),
              one(Conn, "SELECT bot_user_id FROM server_bots WHERE id=$1 AND server_id=$2 FOR UPDATE", [BotId, Sid])} of
            {false, _} -> {error, forbidden};
            {true, {ok, [BotUid]}} ->
                case one(Conn, "SELECT id,app_id,COALESCE(role_id,0) FROM developer_app_installations WHERE server_bot_id=$1 FOR UPDATE", [BotId]) of
                    {ok, [InstallId, AppId, RoleId]} ->
                        %% User-owned applications preserve historical bot messages when
                        %% removed from a server, matching normal chat expectations.
                        ok = uninstall_developer_app_internal(Conn, AppId, InstallId, Sid, BotId, RoleId, Uid),
                        {ok, #{deleted => true, id => BotId, user_id => BotUid, application_id => AppId}};
                    _ ->
                        %% Legacy server-scoped bot deletion keeps the established 2.0
                        %% behavior for compatibility with existing self-hosted servers.
                        ok = enqueue_scylla_hard_deletes_for_user(Conn, BotUid),
                        ok = exec(Conn, "UPDATE messages SET reply_to_id=NULL WHERE reply_to_id IN (SELECT id FROM messages WHERE user_id=$1)", [BotUid]),
                        ok = exec(Conn, "DELETE FROM messages WHERE user_id=$1", [BotUid]),
                        ok = exec(Conn, "DELETE FROM users WHERE id=$1", [BotUid]),
                        publish_server_event(Conn, Sid, #{type => bot_removed, server_id => Sid, bot_user_id => BotUid}),
                        enqueue_server_webhooks(Conn, Sid, <<"bot.removed">>, #{bot_user_id => BotUid, bot_id => BotId, actor_id => Uid}),
                        {ok, #{deleted => true, id => BotId, user_id => BotUid}}
                end;
            {true, _} -> {error, not_found}
        end
    end);
route({authenticate_bot, Token0}, Conn) ->
    Token = pw_util:clean_text(Token0, 256),
    case Token of
        <<"pwb_", _/binary>> ->
            Hash = pw_util:sha256_hex(Token),
            case one(Conn,
                "SELECT b.id,b.server_id,b.bot_user_id,b.name,u.username,u.display_name FROM server_bots b "
                "JOIN users u ON u.id=b.bot_user_id WHERE b.token_hash=$1 AND u.account_state='active'", [Hash]) of
                {ok, [BotId, Sid, BotUid, Name, Username, Display]} ->
                    {ok, #{id => BotId, server_id => Sid, user_id => BotUid, name => Name, username => Username, display_name => Display}};
                _ -> {error, invalid_bot_token}
            end;
        _ -> {error, invalid_bot_token}
    end;

route({bot_server, BotUid0, Sid0}, Conn) ->
    BotUid = pw_util:int(BotUid0), Sid = pw_util:int(Sid0),
    case one(Conn, "SELECT role FROM server_members WHERE server_id=$1 AND user_id=$2", [Sid, BotUid]) of
        {ok, [Role]} ->
            {ok, S} = one(Conn,
                "SELECT id,owner_id,name,description,icon_url,banner_url,accent_color,welcome_message,created_at,updated_at,default_permissions "
                "FROM servers WHERE id=$1", [Sid]),
            {ok, Permissions} = server_permissions0(Conn, BotUid, Sid),
            CanViewChannels = pw_permissions:has(Permissions, pw_permissions:mask(<<"view_channels">>)),
            {ok, Ch} = case CanViewChannels of
                true -> rows(Conn,
                    "SELECT id,server_id,name,kind,position,topic,created_at,category_id,slowmode_seconds "
                    "FROM channels WHERE server_id=$1 ORDER BY position ASC,id ASC", [Sid]);
                false -> {ok, []}
            end,
            {ok, Cats} = case CanViewChannels of
                true -> rows(Conn,
                    "SELECT id,server_id,name,position,created_at FROM channel_categories "
                    "WHERE server_id=$1 ORDER BY position ASC,id ASC", [Sid]);
                false -> {ok, []}
            end,
            Server = (server_full_map(S, Role))#{permissions => Permissions},
            {ok, #{server => Server, channels => [channel_map(R) || R <- Ch],
                   categories => [category_map(R) || R <- Cats]}};
        _ -> {error, forbidden}
    end;
route({bot_members, BotUid0, Sid0, After0, Limit0}, Conn) ->
    BotUid = pw_util:int(BotUid0), Sid = pw_util:int(Sid0),
    After = max(0, pw_util:int(After0)), Limit = clamp_int(Limit0, 1, 200, 50),
    case one(Conn, "SELECT 1 FROM server_members WHERE server_id=$1 AND user_id=$2", [Sid, BotUid]) of
        {ok, [_]} ->
            {ok, Rows0} = rows(Conn,
                "SELECT u.id,u.username,u.display_name,u.bio,u.avatar_url,u.banner_url,u.status,u.theme,"
                "u.created_at,u.last_seen,sm.role,sm.muted,sm.joined_at,sm.nickname,sm.avatar_url,sm.bio,"
                "COALESCE((SELECT r.color FROM server_member_roles mr JOIN server_roles r ON r.id=mr.role_id "
                "WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id ORDER BY "
                "(r.permissions & 1073741824) DESC,(r.permissions & 16) DESC,(r.permissions & 32) DESC,"
                "(r.permissions & 8) DESC,(r.permissions & 4) DESC,(r.permissions & 64) DESC,"
                "(r.permissions & 128) DESC,(r.permissions & 2048) DESC,(r.permissions & 4096) DESC,"
                "(r.permissions & 256) DESC,(r.permissions & 512) DESC,(r.permissions & 2) DESC,"
                "(r.permissions & 1) DESC,r.position DESC,r.id ASC LIMIT 1),''),"
                "COALESCE((SELECT string_agg(r.name, ', ' ORDER BY r.position DESC,r.id ASC) "
                "FROM server_member_roles mr JOIN server_roles r ON r.id=mr.role_id "
                "WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id),''),u.is_bot "
                "FROM server_members sm JOIN users u ON u.id=sm.user_id "
                "WHERE sm.server_id=$1 AND sm.user_id>$2 ORDER BY sm.user_id ASC LIMIT $3",
                [Sid, After, Limit + 1]),
            HasMore = length(Rows0) > Limit,
            Page = lists:sublist(Rows0, Limit),
            NextAfter = case lists:reverse(Page) of [[LastId | _] | _] -> LastId; [] -> null end,
            {ok, #{items => [member_map(R) || R <- Page], next_after => NextAfter, has_more => HasMore}};
        _ -> {error, forbidden}
    end;


route({bot_commands, BotId0}, Conn) ->
    BotId = pw_util:int(BotId0),
    case bot_identity(Conn, BotId) of
        {ok, _BotUid, _Sid} ->
            {ok, Rows} = rows(Conn,
                "SELECT id,name,description,options_json,enabled,created_at,updated_at FROM bot_commands WHERE bot_id=$1 ORDER BY name ASC", [BotId]),
            {ok, [bot_command_map(Row) || Row <- Rows]};
        _ -> {error, forbidden}
    end;
route({bot_register_command, BotId0, Name0, Description0, Options0}, Conn) ->
    BotId = pw_util:int(BotId0),
    Name = normalize_command_name(Name0),
    Description = pw_util:clean_text(Description0, 160),
    case {Name, normalize_command_options(Options0), bot_identity(Conn, BotId)} of
        {invalid, _, _} -> {error, invalid_command_name};
        {_, error, _} -> {error, invalid_command_options};
        {_, _, {error, _}} -> {error, forbidden};
        {CommandName, {ok, Options}, {ok, _BotUid, Sid}} ->
            Now = pw_util:now_ms(),
            OptionsJson = pw_util:json(Options),
            case one(Conn,
                "INSERT INTO bot_commands(bot_id,server_id,name,description,options_json,enabled,created_at,updated_at) "
                "VALUES($1,$2,$3,$4,$5,true,$6,$6) "
                "ON CONFLICT(server_id,name) DO UPDATE SET description=EXCLUDED.description,options_json=EXCLUDED.options_json,enabled=true,updated_at=EXCLUDED.updated_at "
                "WHERE bot_commands.bot_id=EXCLUDED.bot_id RETURNING id,name,description,options_json,enabled,created_at,updated_at",
                [BotId, Sid, CommandName, Description, OptionsJson, Now]) of
                {ok, Row} -> {ok, bot_command_map(Row)};
                _ -> {error, command_name_taken}
            end
    end;
route({bot_sync_commands, BotId0, Commands0}, Conn) ->
    BotId = pw_util:int(BotId0),
    case {normalize_bot_command_set(Commands0), bot_identity(Conn, BotId)} of
        {{error, _}, _} -> {error, invalid_commands};
        {_, {error, _}} -> {error, forbidden};
        {{ok, Definitions}, {ok, _BotUid, Sid}} ->
            with_tx(Conn, fun() ->
                %% Serialize declarative syncs for one bot. All definitions are
                %% validated before this transaction, and any name conflict rolls
                %% the complete replacement back instead of leaving a partial set.
                case one(Conn, "SELECT id FROM server_bots WHERE id=$1 FOR UPDATE", [BotId]) of
                    {ok, [_]} ->
                        {ok, ExistingRows} = rows(Conn,
                            "SELECT id,name FROM bot_commands WHERE bot_id=$1 ORDER BY name ASC", [BotId]),
                        ExistingNames = maps:from_list([{Name, Id} || [Id, Name] <- ExistingRows]),
                        Now = pw_util:now_ms(),
                        case sync_bot_command_definitions(Conn, BotId, Sid, Definitions, Now, []) of
                            {error, _} = Error -> Error;
                            {ok, SyncedRows} ->
                                DesiredNames = maps:from_list([{Name, true} || {Name, _, _} <- Definitions]),
                                Stale = [[Id, Name] || [Id, Name] <- ExistingRows, not maps:is_key(Name, DesiredNames)],
                                [ok = exec(Conn, "DELETE FROM bot_commands WHERE id=$1 AND bot_id=$2", [Id, BotId])
                                 || [Id, _] <- Stale],
                                Created = length([Name || {Name, _, _} <- Definitions, not maps:is_key(Name, ExistingNames)]),
                                Updated = length(Definitions) - Created,
                                Commands = [bot_command_map(Row) || Row <- lists:sort(fun(A, B) -> lists:nth(2, A) =< lists:nth(2, B) end, SyncedRows)],
                                {ok, #{commands => Commands, created => Created, updated => Updated,
                                       deleted => length(Stale)}}
                        end;
                    _ -> {error, forbidden}
                end
            end)
    end;
route({bot_delete_command, BotId0, CommandId0}, Conn) ->
    BotId = pw_util:int(BotId0), CommandId = pw_util:int(CommandId0),
    case one(Conn, "DELETE FROM bot_commands WHERE id=$1 AND bot_id=$2 RETURNING id", [CommandId, BotId]) of
        {ok, [_]} -> {ok, #{deleted => true, id => CommandId}};
        _ -> {error, not_found}
    end;
route({commands_for_channel, Uid, ChannelId0}, Conn) ->
    ChannelId = pw_util:int(ChannelId0),
    case channel_message_access(Conn, Uid, ChannelId) of
        {ok, Sid} ->
            {ok, Rows} = rows(Conn,
                "SELECT c.id,c.name,c.description,c.options_json,c.enabled,c.created_at,c.updated_at,b.id,b.name,u.id,u.username,u.display_name,u.avatar_url,c.handler "
                "FROM bot_commands c JOIN server_bots b ON b.id=c.bot_id JOIN users u ON u.id=b.bot_user_id "
                "WHERE c.server_id=$1 AND c.enabled=true AND u.account_state='active' ORDER BY c.name ASC", [Sid]),
            %% Do not advertise commands whose bot cannot actually read/send in
            %% this channel. Handler configuration is checked dynamically as well,
            %% so disabling an app interaction/AI connector immediately removes
            %% commands that can no longer be serviced.
            Visible = [R || R <- Rows,
                            bot_command_channel_access(Conn, ChannelId, R),
                            bot_command_handler_available(Conn, lists:nth(8, R), lists:nth(14, R)),
                            bot_command_permission_allowed(Conn, Uid, Sid, ChannelId, lists:nth(1, R))],
            {ok, [bot_public_command_map(R) || R <- Visible]};
        _ -> {error, forbidden}
    end;
route({invoke_bot_command, Uid, ChannelId0, Name0, Args0}, Conn) ->
    ChannelId = pw_util:int(ChannelId0),
    Name = normalize_command_name(Name0),
    case Name of
        invalid -> {error, invalid_command_name};
        _ ->
            Result = with_tx(Conn, fun() ->
                case channel_message_access(Conn, Uid, ChannelId) of
                    {ok, Sid} ->
                        case one(Conn,
                            "SELECT c.id,c.bot_id,b.bot_user_id,c.options_json,c.handler FROM bot_commands c "
                            "JOIN server_bots b ON b.id=c.bot_id JOIN users u ON u.id=b.bot_user_id "
                            "WHERE c.server_id=$1 AND c.name=$2 AND c.enabled=true AND u.account_state='active' FOR UPDATE OF c",
                            [Sid, Name]) of
                            {ok, [CommandId, BotId, BotUid, OptionsJson, Handler]} ->
                                %% Discovery is only a convenience. Re-check both
                                %% channel authorization and handler availability in
                                %% the same transaction so stale/hand-crafted clients
                                %% cannot enqueue arguments for a revoked bot or a
                                %% disabled interaction/AI connector.
                                case channel_message_access(Conn, BotUid, ChannelId) of
                                    {ok, Sid} ->
                                        case {bot_command_handler_available(Conn, BotId, Handler),
                                              bot_command_permission_allowed(Conn, Uid, Sid, ChannelId, CommandId)} of
                                            {false, _} -> {error, command_unavailable};
                                            {_, false} -> {error, command_forbidden};
                                            {true, true} -> case normalize_command_arguments(Args0, decode_json_value(OptionsJson, [])) of
                                            {error, _} = Error -> Error;
                                            {ok, Args} ->
                                                Now = pw_util:now_ms(),
                                                Display = command_display(Name, Args),
                                                Mid = new_message_id(),
                                                ok = exec(Conn,
                                                    "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,'channel',$2,$3,$4,NULL,$5)",
                                                    [Mid, ChannelId, Uid, store_message(Display), Now]),
                                                ok = storage_after_message_change(Conn, Mid, <<"message.created">>, Uid),
                                                Cipher = encode_command_args(Args),
                                                {ok, InvocationId} = insert_returning(Conn,
                                                    "INSERT INTO bot_command_invocations(command_id,bot_id,server_id,channel_id,user_id,request_message_id,args_cipher,status,created_at,updated_at) "
                                                    "VALUES($1,$2,$3,$4,$5,$6,$7,'pending',$8,$8) RETURNING id",
                                                    [CommandId, BotId, Sid, ChannelId, Uid, Mid, Cipher, Now]),
                                                {ok, Row} = one(Conn, message_select() ++ " WHERE m.id=$1", [Mid]),
                                                Msg = message_map(Conn, Row),
                                                {ok, #{invocation_id => InvocationId, bot_id => BotId, bot_user_id => BotUid,
                                                       command => Name, handler => Handler, message => Msg, server_id => Sid, channel_id => ChannelId}}
                                        end
                                        end;
                                    _ -> {error, command_unavailable}
                                end;
                            _ -> {error, command_not_found}
                        end;
                    _ -> {error, forbidden}
                end
            end),
            case Result of
                {ok, #{message := Msg, server_id := Sid, bot_user_id := BotUid, invocation_id := InvocationId, command := CommandName, handler := Handler} = Data} ->
                    invalidate_message_cache(<<"channel">>, ChannelId),
                    pw_hub:broadcast({channel, ChannelId}, #{type => message_created, scope => channel, scope_id => ChannelId, message => Msg}),
                    case Handler of
                        <<"queue">> -> pw_hub:notify_user(BotUid, #{type => bot_command_available, invocation_id => InvocationId, command => CommandName, server_id => Sid, channel_id => ChannelId});
                        
<<"webhook">> -> try pw_app_interaction_dispatcher:poke() catch _:_ -> ok end;
                        
<<"ai">> -> try pw_ai_bot_dispatcher:poke() catch _:_ -> ok end;
                        _ -> ok
                    end,
                    {ok, maps:without([server_id, bot_user_id], Data)};
                Other -> Other
            end
    end;
route({bot_claim_commands, BotId0, Limit0}, Conn) ->
    BotId = pw_util:int(BotId0), Limit = clamp_int(Limit0, 1, 50, 10), Now = pw_util:now_ms(),
    LeaseMs = clamp_int(pw_util:env_int("PLAINWIRE_BOT_COMMAND_LEASE_MS", 30000), 5000, 120000, 30000),
    MaxAttempts = clamp_int(pw_util:env_int("PLAINWIRE_BOT_COMMAND_MAX_ATTEMPTS", 8), 1, 25, 8),
    case bot_identity(Conn, BotId) of
        {ok, BotUid, _Sid} ->
            Result = with_tx(Conn, fun() ->
                %% A worker that repeatedly disappears must not poison the queue forever.
                _ = exec(Conn,
                    "UPDATE bot_command_invocations SET status='failed',fail_reason='delivery attempts exhausted',claim_token_hash='',lease_until=0,completed_at=$1,updated_at=$1 "
                    "WHERE bot_id=$2 AND status='claimed' AND lease_until<$1 AND attempts >= $3",
                    [Now, BotId, MaxAttempts]),
                %% Reclaim only expired work. SKIP LOCKED allows several workers for
                %% one bot without duplicate live claims. Channel authorization is
                %% rechecked at claim time so queued arguments are never disclosed
                %% after a bot's role/channel access has been revoked.
                {ok, Rows0} = rows(Conn,
                    "SELECT i.id,i.command_id,c.name,i.server_id,i.channel_id,i.user_id,i.request_message_id,i.args_cipher,i.attempts,i.created_at "
                    "FROM bot_command_invocations i JOIN bot_commands c ON c.id=i.command_id "
                    "WHERE i.bot_id=$1 AND c.handler='queue' AND (i.status='pending' OR (i.status='claimed' AND i.lease_until<$2)) "
                    "ORDER BY i.id ASC LIMIT $3 FOR UPDATE OF i SKIP LOCKED", [BotId, Now, Limit]),
                {Claims, Failed} = claim_authorized_bot_invocations(Conn, BotId, BotUid, Rows0, Now, LeaseMs, [], []),
                {ok, #{claims => lists:reverse(Claims), failed => lists:reverse(Failed)}}
            end),
            case Result of
                {ok, #{claims := Claims, failed := Failed}} ->
                    [pw_hub:notify_user(UserId, #{type => bot_command_failed, invocation_id => InvocationId,
                        channel_id => ChannelId, reason => <<"Bot no longer has access to this channel">>})
                     || #{user_id := UserId, id := InvocationId, channel_id := ChannelId} <- Failed, is_integer(UserId)],
                    {ok, Claims};
                Other -> Other
            end;
        _ -> {error, forbidden}
    end;
route({bot_defer_command, BotId0, InvocationId0, ClaimToken0, LeaseMs0}, Conn) ->
    BotId = pw_util:int(BotId0), InvocationId = pw_util:int(InvocationId0),
    ClaimToken = pw_util:clean_text(ClaimToken0, 256),
    DefaultLease = clamp_int(pw_util:env_int("PLAINWIRE_BOT_COMMAND_LEASE_MS", 30000), 5000, 120000, 30000),
    LeaseMs = clamp_int(LeaseMs0, 5000, 120000, DefaultLease), Now = pw_util:now_ms(),
    with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT status,claim_token_hash,lease_until FROM bot_command_invocations "
            "WHERE id=$1 AND bot_id=$2 FOR UPDATE", [InvocationId, BotId]) of
            {ok, [<<"claimed">>, Hash, LeaseUntil]} when LeaseUntil >= Now ->
                case secure_token_hash_match(ClaimToken, Hash) of
                    true ->
                        NewLease = Now + LeaseMs,
                        ok = exec(Conn,
                            "UPDATE bot_command_invocations SET lease_until=$1,updated_at=$2 WHERE id=$3 AND bot_id=$4",
                            [NewLease, Now, InvocationId, BotId]),
                        {ok, #{deferred => true, id => InvocationId, lease_until => NewLease}};
                    false -> {error, invalid_claim}
                end;
            {ok, [<<"claimed">>, _Hash, _LeaseUntil]} -> {error, claim_expired};
            {ok, [<<"completed">>, _Hash, _LeaseUntil]} -> {error, invocation_completed};
            {ok, [<<"failed">>, _Hash, _LeaseUntil]} -> {error, invocation_failed};
            _ -> {error, invalid_claim}
        end
    end);
route({bot_respond_command, BotId0, InvocationId0, ClaimToken0, Body0}, Conn) ->
    BotId = pw_util:int(BotId0), InvocationId = pw_util:int(InvocationId0),
    ClaimToken = pw_util:clean_text(ClaimToken0, 256), Plain = pw_util:clean_text(Body0, ?MAX_MSG),
    case message_body_valid(Plain) of
        false -> {error, invalid_message};
        true ->
            Result = with_tx(Conn, fun() ->
                Now = pw_util:now_ms(),
                case one(Conn,
                    "SELECT i.channel_id,i.request_message_id,b.bot_user_id,i.status,i.claim_token_hash,i.lease_until,i.response_message_id "
                    "FROM bot_command_invocations i JOIN server_bots b ON b.id=i.bot_id WHERE i.id=$1 AND i.bot_id=$2 FOR UPDATE OF i",
                    [InvocationId, BotId]) of
                    {ok, [_Cid, _RequestMid, _BotUid, <<"completed">>, _Hash, _Lease, ExistingMid]} ->
                        {ok, #{completed => true, message_id => db_null(ExistingMid), duplicate => true}};
                    {ok, [Cid, RequestMid, BotUid, <<"claimed">>, Hash, LeaseUntil, _]} when LeaseUntil >= Now ->
                        case secure_token_hash_match(ClaimToken, Hash) of
                            false -> {error, invalid_claim};
                            true ->
                                case channel_message_access(Conn, BotUid, Cid) of
                                    {ok, Sid} ->
                                        Mid = new_message_id(),
                                        ok = exec(Conn,
                                            "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,'channel',$2,$3,$4,$5,$6)",
                                            [Mid, Cid, BotUid, store_message(Plain), RequestMid, Now]),
                                        ok = storage_after_message_change(Conn, Mid, <<"message.created">>, BotUid),
                                        ok = exec(Conn,
                                            "UPDATE bot_command_invocations SET status='completed',response_message_id=$1,claim_token_hash='',lease_until=0,completed_at=$2,updated_at=$2 WHERE id=$3",
                                            [Mid, Now, InvocationId]),
                                        {ok, Row} = one(Conn, message_select() ++ " WHERE m.id=$1", [Mid]),
                                        Msg = message_map(Conn, Row),
                                        {ok, #{completed => true, message_id => Mid, message => Msg, channel_id => Cid, server_id => Sid}};
                                    _ -> {error, forbidden}
                                end
                        end;
                    {ok, [_Cid, _RequestMid, _BotUid, <<"claimed">>, _Hash, _Lease, _]} -> {error, claim_expired};
                    {ok, [_Cid, _RequestMid, _BotUid, <<"failed">>, _, _, _]} -> {error, invocation_failed};
                    _ -> {error, invalid_claim}
                end
            end),
            case Result of
                {ok, #{message := Msg, channel_id := Cid, server_id := Sid} = Data} ->
                    invalidate_message_cache(<<"channel">>, Cid),
                    pw_hub:broadcast({channel, Cid}, #{type => message_created, scope => channel, scope_id => Cid, message => Msg}),
                    best_effort_channel_notifications(Conn, Sid, maps:get(user_id, Msg), Cid, Msg, pw_util:now_ms(), false),
                    {ok, maps:without([message, channel_id, server_id], Data)};
                Other -> Other
            end
    end;
route({bot_fail_command, BotId0, InvocationId0, ClaimToken0, Reason0}, Conn) ->
    BotId = pw_util:int(BotId0), InvocationId = pw_util:int(InvocationId0),
    ClaimToken = pw_util:clean_text(ClaimToken0, 256), Reason = pw_util:clean_text(Reason0, 240), Now = pw_util:now_ms(),
    Result = with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT status,claim_token_hash,lease_until,user_id,channel_id FROM bot_command_invocations "
            "WHERE id=$1 AND bot_id=$2 FOR UPDATE",
            [InvocationId, BotId]) of
            {ok, [<<"claimed">>, Hash, LeaseUntil, UserId, ChannelId]} when LeaseUntil >= Now ->
                case secure_token_hash_match(ClaimToken, Hash) of
                    true ->
                        ok = exec(Conn,
                            "UPDATE bot_command_invocations SET status='failed',fail_reason=$1,claim_token_hash='',lease_until=0,completed_at=$2,updated_at=$2 WHERE id=$3",
                            [Reason, Now, InvocationId]),
                        {ok, #{failed => true, id => InvocationId, user_id => UserId, channel_id => ChannelId}};
                    false -> {error, invalid_claim}
                end;
            {ok, [<<"claimed">>, _Hash, _LeaseUntil, _UserId, _ChannelId]} -> {error, claim_expired};
            {ok, [<<"failed">>, _Hash, _LeaseUntil, _UserId, _ChannelId]} -> {ok, #{failed => true, id => InvocationId, duplicate => true}};
            _ -> {error, invalid_claim}
        end
    end),
    case Result of
        {ok, #{duplicate := true} = Data} -> {ok, Data};
        {ok, #{user_id := UserId, channel_id := ChannelId} = Data} ->
            case UserId of
                I when is_integer(I) -> pw_hub:notify_user(I, #{type => bot_command_failed, invocation_id => InvocationId, channel_id => ChannelId, reason => Reason});
                _ -> ok
            end,
            {ok, maps:without([user_id, channel_id], Data)};
        Other -> Other
    end;

route({create_invite, Uid, Sid0, ChannelId0, MaxUses0, ExpiresIn0}, Conn) ->
    Sid = pw_util:int(Sid0), ChannelId = pw_util:int(ChannelId0),
    case invite_options(MaxUses0, ExpiresIn0) of
        {error, _} = Error -> Error;
        {ok, MaxUses, ExpiresIn} -> with_tx(Conn, fun() ->
            %% Serialize the per-server cap and code reuse across API nodes.
            _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
            case {has_server_permission(Conn, Uid, Sid, <<"create_wires">>), valid_invite_channel(Conn, Sid, ChannelId)} of
                {true, true} ->
                    Existing = case ExpiresIn of 0 -> existing_invite(Conn, Sid, ChannelId, MaxUses); _ -> not_found end,
                    Now = pw_util:now_ms(),
                    case Existing of
                        {ok, Code} -> {ok, #{code => Code, url => <<"#wire/", Code/binary>>, existing => true, expires_at => 0}};
                        not_found ->
                            {ok, [Count]} = one(Conn, "SELECT count(*) FROM server_invites WHERE server_id = $1 AND revoked = false AND (expires_at = 0 OR expires_at > $2) AND (max_uses = 0 OR uses < max_uses)", [Sid, Now]),
                            case Count >= 100 of
                                true -> {error, invite_limit};
                                false ->
                                    Code = pw_util:random_token(24),
                                    Expires = case ExpiresIn of 0 -> 0; _ -> Now + ExpiresIn * 1000 end,
                                    ok = exec(Conn, "INSERT INTO server_invites(code, server_id, channel_id, creator_id, max_uses, uses, created_at, expires_at, revoked) VALUES($1,$2,$3,$4,$5,0,$6,$7,false)",
                                              [Code, Sid, ChannelId, Uid, MaxUses, Now, Expires]),
                                    {ok, #{code => Code, url => <<"#wire/", Code/binary>>, expires_at => Expires, max_uses => MaxUses}}
                            end
                    end;
                {false, _} -> {error, forbidden};
                _ -> {error, invalid_channel}
            end
        end)
    end;
route({list_invites, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case has_server_permission(Conn, Uid, Sid, <<"manage_wires">>) of
        false -> {error, forbidden};
        true ->
            {ok, Rs} = rows(Conn, "SELECT code, channel_id, max_uses, uses, created_at, expires_at, revoked FROM server_invites WHERE server_id = $1 ORDER BY created_at DESC LIMIT 100", [Sid]),
            {ok, [#{code => Code, channel_id => C, max_uses => Max, uses => Uses, created_at => At, expires_at => Exp, revoked => Rev} || [Code, C, Max, Uses, At, Exp, Rev] <- Rs]}
    end;
route({revoke_invite, Uid, Sid0, Code0}, Conn) ->
    Sid = pw_util:int(Sid0), Code = pw_util:clean_text(Code0, 80),
    case has_server_permission(Conn, Uid, Sid, <<"manage_wires">>) of
        false -> {error, forbidden};
        true ->
            case one(Conn, "UPDATE server_invites SET revoked = true WHERE server_id = $1 AND code = $2 AND revoked = false RETURNING code", [Sid, Code]) of
                {ok, [_]} -> {ok, #{revoked => true, code => Code}};
                _ -> {error, not_found}
            end
    end;
route({invite_preview, Code0}, Conn) ->
    Code = pw_util:clean_text(Code0, 80),
    Now = pw_util:now_ms(),
    Sql = "SELECT i.code, i.server_id, i.channel_id, i.max_uses, i.uses, i.expires_at, i.revoked, "
          "s.name, s.description, s.icon_url, s.banner_url, s.accent_color, s.welcome_message, "
          "COALESCE(c.name,''), u.username, u.display_name, "
          "(SELECT count(*) FROM server_members WHERE server_id = s.id) "
          "FROM server_invites i JOIN servers s ON s.id = i.server_id "
          "JOIN users u ON u.id=i.creator_id LEFT JOIN channels c ON c.id=i.channel_id WHERE i.code = $1",
    case one(Conn, Sql, [Code]) of
        {ok, [Code, Sid, Cid, Max, Uses, Expires, Revoked, Name, Desc, Icon, Banner, Accent, Welcome, ChannelName, CreatorUsername, CreatorDisplay, Count]} ->
            Valid = (Revoked =:= false) andalso (Max =:= 0 orelse Uses < Max) andalso (Expires =:= 0 orelse Expires > Now),
            Remaining = case Max of 0 -> 0; _ -> max(0, Max - Uses) end,
            {ok, #{code => Code, server_id => Sid, channel_id => Cid, valid => Valid, max_uses => Max, uses => Uses,
                   remaining_uses => Remaining, expires_at => Expires, channel_name => ChannelName,
                   creator => #{username => CreatorUsername, display_name => CreatorDisplay},
                   server => #{name => Name, description => Desc, icon_url => Icon, banner_url => Banner,
                               accent_color => Accent, welcome_message => Welcome, member_count => Count}}};
        _ ->
            {error, invalid_invite}
    end;
route({join_invite, Uid, Code0}, Conn) ->
    Code = pw_util:clean_text(Code0, 80),
    Now = pw_util:now_ms(),
    Result = with_tx(Conn, fun() -> join_invite_tx(Conn, Uid, Code, Now) end),
    case Result of
        {ok, #{server_id := Sid, membership_created := true} = Data} ->
            %% A prior denied file lookup must not survive the permission grant.
            pw_upload_gc:invalidate_user(Uid),
            publish_server_event(Conn, Sid, #{type => member_joined, server_id => Sid, user_id => Uid, actor_id => Uid}),
            {ok, maps:remove(membership_created, Data)};
        {ok, Data} -> {ok, maps:remove(membership_created, Data)};
        Other -> Other
    end;
route({messages, Uid, Scope0, ScopeId0, Before0, After0}, Conn) ->
    Scope = pw_util:clean_text(Scope0, 16),
    ScopeId = pw_util:int(ScopeId0),
    Before = pw_util:int(Before0),
    After = pw_util:int(After0),
    case can_read_messages(Conn, Uid, Scope, ScopeId) of
        true ->
            case message_cache_lookup(Uid, Scope, ScopeId, Before, After) of
                {hit, Cached} -> {ok, Cached};
                {miss, VersionBefore} ->
                    {ok, Rows} = load_message_rows(Conn, Scope, ScopeId, Before, After),
                    ReplyIds = [R || [_,_,_,_,_,_,_,_,R|_] <- Rows, R =/= null, is_integer(R)],
                    ReplyMap = batch_replied_messages(Conn, ReplyIds, Scope, ScopeId),
                    ReactionMap = batch_message_reactions(Conn, Rows, Uid, Scope, ScopeId),
                    Messages = [message_map_with_replies_and_reactions(R, ReplyMap, ReactionMap) || R <- Rows],
                    maybe_store_message_cache(Uid, Scope, ScopeId, Before, After, VersionBefore, Messages),
                    {ok, Messages}
            end;
        false ->
            {error, forbidden}
    end;
route({message_context, Uid, Mid0}, Conn) ->
    Mid = pw_util:int(Mid0),
    case Mid of
        I when is_integer(I), I > 0 ->
            case one(Conn, "SELECT scope,scope_id FROM messages WHERE id=$1 AND deleted_at IS NULL", [I]) of
                {ok, [Scope, ScopeId]} ->
                    case can_read_messages(Conn, Uid, Scope, ScopeId) of
                        false -> {error, forbidden};
                        true ->
                            %% Reply jumps must stay bounded even when the target is
                            %% years old. Load a small window around the target and let
                            %% the client return to the live tail with its normal route.
                            {ok, BeforeDesc} = rows(Conn,
                                message_select() ++
                                " WHERE m.scope=$1 AND m.scope_id=$2 AND m.deleted_at IS NULL AND m.id<$3"
                                " ORDER BY m.id DESC LIMIT 24", [Scope, ScopeId, I]),
                            {ok, AfterRows} = rows(Conn,
                                message_select() ++
                                " WHERE m.scope=$1 AND m.scope_id=$2 AND m.deleted_at IS NULL AND m.id>=$3"
                                " ORDER BY m.id ASC LIMIT 37", [Scope, ScopeId, I]),
                            ContextRows = lists:reverse(BeforeDesc) ++ AfterRows,
                            ReplyIds = [R || [_,_,_,_,_,_,_,_,R|_] <- ContextRows, R =/= null, is_integer(R)],
                            ReplyMap = batch_replied_messages(Conn, ReplyIds, Scope, ScopeId),
                            ReactionMap = batch_message_reactions(Conn, ContextRows, Uid, Scope, ScopeId),
                            Messages = [message_map_with_replies_and_reactions(R, ReplyMap, ReactionMap) || R <- ContextRows],
                            case lists:any(fun(M) -> maps:get(id, M, 0) =:= I end, Messages) of
                                true -> {ok, #{target_id => I, scope => Scope, scope_id => ScopeId, messages => Messages}};
                                false -> {error, not_found}
                            end
                    end;
                _ -> {error, not_found}
            end;
        _ -> {error, not_found}
    end;
route({channel_pins, Uid, ChannelId0}, Conn) ->
    ChannelId = pw_util:int(ChannelId0),
    case can_read_messages(Conn, Uid, <<"channel">>, ChannelId) of
        false -> {error, forbidden};
        true ->
            {ok, Rows} = rows(Conn,
                message_select() ++
                " WHERE m.scope='channel' AND m.scope_id=$1 AND m.deleted_at IS NULL"
                " AND EXISTS (SELECT 1 FROM message_pins pin WHERE pin.channel_id=$1 AND pin.message_id=m.id)"
                " ORDER BY (SELECT pin.pinned_at FROM message_pins pin WHERE pin.channel_id=$1 AND pin.message_id=m.id) DESC"
                " LIMIT 50", [ChannelId]),
            ReplyIds = [R || [_,_,_,_,_,_,_,_,R|_] <- Rows, R =/= null, is_integer(R)],
            ReplyMap = batch_replied_messages(Conn, ReplyIds, <<"channel">>, ChannelId),
            ReactionMap = batch_message_reactions(Conn, Rows, Uid, <<"channel">>, ChannelId),
            {ok, [message_map_with_replies_and_reactions(R, ReplyMap, ReactionMap) || R <- Rows]}
    end;
route({set_message_pin, Uid, Mid0, Pinned0}, Conn) ->
    Mid = pw_util:int(Mid0),
    Pinned = case Pinned0 of true -> true; false -> false; _ -> invalid end,
    case {Mid, Pinned} of
        {I, P} when is_integer(I), I > 0, is_boolean(P) ->
            Result = with_tx(Conn, fun() ->
                case one(Conn,
                    "SELECT m.scope,m.scope_id,c.server_id FROM messages m"
                    " LEFT JOIN channels c ON m.scope='channel' AND c.id=m.scope_id"
                    " WHERE m.id=$1 AND m.deleted_at IS NULL AND m.kind='text' FOR UPDATE OF m", [I]) of
                    {ok, [<<"channel">>, ChannelId, Sid]} when is_integer(Sid) ->
                        case has_server_permission(Conn, Uid, Sid, <<"manage_messages">>) of
                            false -> {error, forbidden};
                            true ->
                                case P of
                                    true ->
                                        case one(Conn, "SELECT pinned_at FROM message_pins WHERE message_id=$1 AND channel_id=$2", [I, ChannelId]) of
                                            {ok, [PinnedAt]} -> {ok, #{message_id => I, channel_id => ChannelId, server_id => Sid, pinned => true, pinned_at => PinnedAt}};
                                            _ ->
                                                {ok, [Count]} = one(Conn, "SELECT count(*) FROM message_pins WHERE channel_id=$1", [ChannelId]),
                                                case Count >= 50 of
                                                    true -> {error, pin_limit};
                                                    false ->
                                                        Now = pw_util:now_ms(),
                                                        ok = exec(Conn,
                                                            "INSERT INTO message_pins(channel_id,message_id,pinned_by,pinned_at) VALUES($1,$2,$3,$4) ON CONFLICT(message_id) DO NOTHING",
                                                            [ChannelId, I, Uid, Now]),
                                                        {ok, #{message_id => I, channel_id => ChannelId, server_id => Sid, pinned => true, pinned_at => Now}}
                                                end
                                        end;
                                    false ->
                                        _ = exec(Conn, "DELETE FROM message_pins WHERE message_id=$1 AND channel_id=$2", [I, ChannelId]),
                                        {ok, #{message_id => I, channel_id => ChannelId, server_id => Sid, pinned => false, pinned_at => 0}}
                                end
                        end;
                    {ok, _} -> {error, pins_channel_only};
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{channel_id := ChannelId, server_id := Sid, pinned := IsPinned} = Data0} ->
                    invalidate_message_cache(<<"channel">>, ChannelId),
                    Event = #{type => message_pin_changed, message_id => I, channel_id => ChannelId,
                              pinned => IsPinned, actor_id => Uid},
                    pw_hub:broadcast({channel, ChannelId}, Event),
                    WebhookEvent = case IsPinned of true -> <<"message.pinned">>; false -> <<"message.unpinned">> end,
                    enqueue_server_webhooks(Conn, Sid, WebhookEvent, #{message_id => I, channel_id => ChannelId, actor_id => Uid}),
                    {ok, maps:without([server_id], Data0)};
                Other -> Other
            end;
        _ -> {error, invalid_pin_state}
    end;
route({delete_message, Uid, Mid0}, Conn) ->
    Mid = pw_util:int(Mid0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT user_id,scope,scope_id,body FROM messages WHERE id=$1 AND kind='text' AND deleted_at IS NULL FOR UPDATE", [Mid]) of
            {ok, [AuthorId, Scope, ScopeId, OldStoredBody]} ->
                case can_delete_message(Conn, Uid, AuthorId, Scope, ScopeId) of
                    false -> {error, forbidden};
                    true ->
                        Now = pw_util:now_ms(),
                        ok = exec(Conn, "DELETE FROM message_reactions WHERE message_id=$1", [Mid]),
                        ok = exec(Conn, "UPDATE messages SET deleted_at=$1,body='' WHERE id=$2", [Now, Mid]),
                        ok = storage_after_message_change(Conn, Mid, <<"message.deleted">>, Uid),
                        ok = maybe_enqueue_message_webhook(Conn, Scope, ScopeId, <<"message.deleted">>,
                            #{message_id => Mid, author_id => AuthorId, actor_id => Uid}),
                        case extract_file_ids(load_message(OldStoredBody)) of
                            [] -> ok;
                            _ -> sync_message_scope_upload_refs(Conn, Scope, ScopeId, Now)
                        end,
                        {ok, #{deleted => true, scope => Scope, scope_id => ScopeId}}
                end;
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{scope := Scope, scope_id := ScopeId} = Data} ->
            invalidate_message_cache(Scope, ScopeId),
            BroadcastKey = message_broadcast_key(Scope, ScopeId),
            pw_hub:broadcast(BroadcastKey, #{type => message_deleted, scope => Scope, scope_id => ScopeId, message_id => Mid}),
            {ok, maps:without([scope, scope_id], Data)};
        Other -> Other
    end;
route({edit_message, Uid, Mid0, Body0}, Conn) ->
    Mid = pw_util:int(Mid0),
    Plain = pw_util:clean_text(Body0, ?MAX_MSG),
    Body = store_message(Plain),
    case message_body_valid(Plain) of
        false -> {error, invalid_message};
        true ->
            Result = with_tx(Conn, fun() ->
                case one(Conn,
                    "SELECT user_id,scope,scope_id,body FROM messages WHERE id=$1 AND kind='text' AND deleted_at IS NULL AND forwarded_from_id IS NULL FOR UPDATE", [Mid]) of
                    {ok, [Uid, Scope, ScopeId, OldStoredBody]} ->
                        case can_modify_message_scope(Conn, Uid, Scope, ScopeId) of
                            false -> {error, forbidden};
                            true ->
                                Now = pw_util:now_ms(),
                                ok = exec(Conn, "UPDATE messages SET body=$1,edited_at=$2 WHERE id=$3", [Body, Now, Mid]),
                                ok = storage_after_message_change(Conn, Mid, <<"message.edited">>, Uid),
                                case removed_upload_refs(load_message(OldStoredBody), Plain) of
                                    [] -> insert_upload_refs(Conn, Plain, Scope, ScopeId, Now);
                                    _ -> sync_message_scope_upload_refs(Conn, Scope, ScopeId, Now)
                                end,
                                {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                                Msg = message_map(Conn, Row),
                                ok = maybe_enqueue_message_webhook(Conn, Scope, ScopeId, <<"message.updated">>,
                                    #{message => Msg, actor_id => Uid}),
                                {ok, #{message => Msg, scope => Scope, scope_id => ScopeId}}
                        end;
                    {ok, [_Author, _Scope, _ScopeId, _Body]} -> {error, forbidden};
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{message := Msg, scope := Scope, scope_id := ScopeId}} ->
                    invalidate_message_cache(Scope, ScopeId),
                    pw_hub:broadcast(message_broadcast_key(Scope, ScopeId),
                        #{type => message_updated, scope => Scope, scope_id => ScopeId, message => Msg}),
                    {ok, Msg};
                Other -> Other
            end
    end;
route({forward_message, Uid, Mid0, TargetScope0, TargetId0}, Conn) ->
    Mid = pw_util:int(Mid0),
    TargetId = pw_util:int(TargetId0),
    TargetScope = case TargetScope0 of
        <<"direct">> -> <<"direct">>;
        <<"channel">> -> <<"channel">>;
        direct -> <<"direct">>;
        channel -> <<"channel">>;
        _ -> invalid
    end,
    case TargetScope of
        invalid -> {error, invalid_target};
        _ ->
            Result = with_tx(Conn, fun() ->
                case one(Conn, "SELECT scope,scope_id,body,COALESCE(forwarded_from_id,id) FROM messages WHERE id=$1 AND kind='text' AND deleted_at IS NULL", [Mid]) of
                    {ok, [SourceScope, SourceId, StoredBody, OriginalId]} ->
                        CanReadSource = can_read_messages(Conn, Uid, SourceScope, SourceId),
                        TargetAccess = case TargetScope of
                            <<"direct">> -> case conversation_can_send(Conn, Uid, TargetId) of true -> {ok, undefined}; false -> error end;
                            <<"channel">> -> channel_message_access(Conn, Uid, TargetId)
                        end,
                        case {CanReadSource, TargetAccess} of
                            {true, {ok, Sid}} ->
                                LockOk = case TargetScope of
                                    <<"channel">> ->
                                        case one(Conn, "SELECT id FROM servers WHERE id=$1 FOR KEY SHARE", [Sid]) of
                                            {ok, [_]} -> true;
                                            _ -> false
                                        end;
                                    _ -> true
                                end,
                                case LockOk of
                                    false -> {error, forbidden};
                                    true ->
                                Now = pw_util:now_ms(),
                                NewId = new_message_id(),
                                ok = exec(Conn,
                                    "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at,forwarded_from_id) VALUES($1,$2,$3,$4,$5,NULL,$6,$7)",
                                    [NewId, TargetScope, TargetId, Uid, StoredBody, Now, OriginalId]),
                                insert_upload_refs(Conn, load_message(StoredBody), TargetScope, TargetId, Now),
                                case TargetScope of
                                    <<"direct">> ->
                                        ok = exec(Conn, "UPDATE direct_threads SET updated_at=$1 WHERE id=$2", [Now, TargetId]),
                                        ok = exec(Conn, "UPDATE direct_members SET last_read_message_id=$1 WHERE thread_id=$2 AND user_id=$3", [NewId, TargetId, Uid]),
                                        ok = exec(Conn, "UPDATE direct_members SET hidden=false WHERE thread_id=$1 AND user_id<>$2", [TargetId, Uid]);
                                    <<"channel">> -> ok
                                end,
                                ok = storage_after_message_change(Conn, NewId, <<"message.created">>, Uid),
                                {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [NewId]),
                                Msg = message_map(Conn, Row),
                                ok = maybe_enqueue_message_webhook(Conn, TargetScope, TargetId, <<"message.created">>,
                                    #{message => Msg, actor_id => Uid}),
                                {ok, #{message => Msg, scope => TargetScope, scope_id => TargetId, server_id => Sid, notify_at => Now}}
                                end;
                            _ -> {error, forbidden}
                        end;
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{message := Msg, scope := <<"direct">>, scope_id := Cid, notify_at := Now}} ->
                    invalidate_message_cache(<<"direct">>, Cid),
                    pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
                    best_effort_direct_notifications(Conn, Cid, Uid, #{type => direct_message, conversation_id => Cid, message => Msg}, Now, true),
                    {ok, Msg};
                {ok, #{message := Msg, scope := <<"channel">>, scope_id := Cid, server_id := Sid, notify_at := Now}} ->
                    invalidate_message_cache(<<"channel">>, Cid),
                    pw_hub:broadcast({channel, Cid}, #{type => message_created, scope => channel, scope_id => Cid, message => Msg}),
                    best_effort_channel_notifications(Conn, Sid, Uid, Cid, Msg, Now, true),
                    {ok, Msg};
                Other -> Other
            end
    end;
route({post_channel_message, Uid, ChannelId0, Body0, ReplyTo0}, Conn) ->
    Cid = pw_util:int(ChannelId0),
    Plain = pw_util:clean_text(Body0, ?MAX_MSG),
    Body = store_message(Plain),
    ReplyTo = pw_util:int(ReplyTo0),
    case message_body_valid(Plain) of
        false -> {error, invalid_message};
        true ->
            Result = with_tx(Conn, fun() ->
                case channel_message_access(Conn, Uid, Cid) of
                    {ok, Sid} ->
                        case enforce_channel_slowmode(Conn, Uid, Cid, Sid) of
                            {error, SlowReason} -> throw({plainwire_error, SlowReason});
                            ok -> ok
                        end,
                        VoiceNoteAllowed = case is_voice_note_body(Plain) of
                            true -> has_server_permission(Conn, Uid, Sid, <<"send_voice_notes">>);
                            false -> true
                        end,
                        AttachmentAllowed = case extract_file_ids(Plain) of
                            [] -> true;
                            _ -> has_server_permission(Conn, Uid, Sid, <<"attach_files">>)
                        end,
                        case {VoiceNoteAllowed, AttachmentAllowed,
                              one(Conn, "SELECT id FROM servers WHERE id=$1 FOR KEY SHARE", [Sid]),
                              valid_reply_to(Conn, <<"channel">>, Cid, ReplyTo)} of
                            {true, true, {ok, [_]}, true} ->
                        Now = pw_util:now_ms(),
                        Mid = new_message_id(),
                        ok = exec(Conn,
                            "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
                            [Mid, <<"channel">>, Cid, Uid, Body, ReplyTo, Now]),
                        insert_upload_refs(Conn, Plain, <<"channel">>, Cid, Now),
                        ok = storage_after_message_change(Conn, Mid, <<"message.created">>, Uid),
                        {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                        Msg = message_map(Conn, Row),
                        ok = maybe_enqueue_message_webhook(Conn, <<"channel">>, Cid, <<"message.created">>,
                            #{message => Msg, actor_id => Uid}),
                        {ok, #{message => Msg, server_id => Sid, notify_at => Now}};
                            {true, true, {ok, [_]}, false} -> {error, invalid_message};
                            {false, _, _, _} -> {error, voice_notes_forbidden};
                            {true, false, _, _} -> {error, attachments_forbidden};
                            _ -> {error, forbidden}
                        end;
                    _ -> {error, forbidden}
                end
            end),
            case Result of
                {ok, #{message := Msg, server_id := Sid, notify_at := Now}} ->
                    invalidate_message_cache(<<"channel">>, Cid),
                    pw_hub:broadcast({channel, Cid}, #{type => message_created, scope => channel, scope_id => Cid, message => Msg}),
                    best_effort_channel_notifications(Conn, Sid, Uid, Cid, Msg, Now, false),
                    {ok, Msg};
                Other -> Other
            end
    end;
route({toggle_message_reaction, Uid, Mid0, Emoji0}, Conn) ->
    Mid = pw_util:int(Mid0),
    Emoji = pw_util:clean_text(Emoji0, 32),
    case reaction_allowed(Emoji) of
        false -> {error, invalid_reaction};
        true ->
            Result = with_tx(Conn, fun() ->
                case one(Conn, "SELECT scope,scope_id,user_id FROM messages WHERE id=$1 AND kind='text' AND deleted_at IS NULL FOR UPDATE", [Mid]) of
                    {ok, [Scope, ScopeId, AuthorUid]} ->
                        Allowed = case Scope of
                            <<"channel">> ->
                                case channel_message_access(Conn, Uid, ScopeId) of
                                    {ok, Sid} -> has_server_permission(Conn, Uid, Sid, <<"add_reactions">>);
                                    _ -> false
                                end;
                            <<"direct">> -> conversation_can_send(Conn, Uid, ScopeId);
                            _ -> false
                        end,
                        case Allowed of
                            false -> {error, forbidden};
                            true ->
                                Existing = one(Conn, "SELECT 1 FROM message_reactions WHERE message_id=$1 AND user_id=$2 AND emoji=$3", [Mid, Uid, Emoji]),
                                Added = case Existing of
                                    {ok, [_]} ->
                                        ok = exec(Conn, "DELETE FROM message_reactions WHERE message_id=$1 AND user_id=$2 AND emoji=$3", [Mid, Uid, Emoji]),
                                        false;
                                    _ ->
                                        ok = exec(Conn,
                                            "INSERT INTO message_reactions(message_id,user_id,emoji,created_at) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING",
                                            [Mid, Uid, Emoji, pw_util:now_ms()]),
                                        true
                                end,
                                {ok, [Count]} = one(Conn, "SELECT count(*) FROM message_reactions WHERE message_id=$1 AND emoji=$2", [Mid, Emoji]),
                                ReactorName = case one(Conn, "SELECT display_name FROM users WHERE id=$1", [Uid]) of
                                    {ok, [Name]} -> pw_util:clean_text(Name, 80);
                                    _ -> <<"Someone">>
                                end,
                                ok = maybe_queue_reaction_event(Conn, Scope, ScopeId, Mid, Uid, Emoji, Added),
                                ok = maybe_enqueue_message_webhook(Conn, Scope, ScopeId, <<"message.reaction">>,
                                    #{message_id => Mid, emoji => Emoji, count => Count, added => Added,
                                      user_id => Uid, author_id => AuthorUid, actor_id => Uid}),
                                {ok, #{message_id => Mid, emoji => Emoji, count => Count, added => Added,
                                       user_id => Uid, author_id => AuthorUid, reactor_name => ReactorName,
                                       scope => Scope, scope_id => ScopeId}}
                        end;
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{scope := Scope, scope_id := ScopeId, author_id := AuthorUid,
                       reactor_name := ReactorName, added := Added} = Data} ->
                    PublicData = maps:without([scope, scope_id, author_id, reactor_name], Data),
                    invalidate_message_cache(Scope, ScopeId),
                    Event = maps:merge(#{type => message_reaction_changed}, PublicData),
                    pw_hub:broadcast(message_broadcast_key(Scope, ScopeId), Event),
                    best_effort_reaction_notification(Conn, AuthorUid, Uid, ReactorName, Mid, Emoji,
                                                      Scope, ScopeId, Added),
                    {ok, PublicData};
                Other -> Other
            end
    end;
route({conversations, Uid}, Conn) ->
    Sql = "SELECT dt.id, dt.name, dt.avatar_url, dt.owner_id, dt.created_at, dt.updated_at, "
          "dm.last_read_message_id, dm.muted, dm.request_state, dm.group_role, "
          "(SELECT count(*) FROM direct_members WHERE thread_id = dt.id), "
          "lm.body, lm.id, COALESCE(lm.user_id, 0), COALESCE(lm.display_name, ''), COALESCE(lm.username, ''), "
          "(SELECT count(*) FROM messages WHERE scope = 'direct' AND scope_id = dt.id AND deleted_at IS NULL "
          "AND id > dm.last_read_message_id AND user_id <> $1), "
          "COALESCE((SELECT u.id FROM direct_members dm2 JOIN users u ON u.id = dm2.user_id "
          "WHERE dm2.thread_id = dt.id AND dm2.user_id <> $1 ORDER BY u.display_name ASC LIMIT 1), 0), "
          "COALESCE((SELECT u.display_name FROM direct_members dm2 JOIN users u ON u.id = dm2.user_id "
          "WHERE dm2.thread_id = dt.id AND dm2.user_id <> $1 ORDER BY u.display_name ASC LIMIT 1), ''), "
          "COALESCE((SELECT u.avatar_url FROM direct_members dm2 JOIN users u ON u.id = dm2.user_id "
          "WHERE dm2.thread_id = dt.id AND dm2.user_id <> $1 ORDER BY u.display_name ASC LIMIT 1), ''), "
          "COALESCE((SELECT u.username FROM direct_members dm2 JOIN users u ON u.id = dm2.user_id "
          "WHERE dm2.thread_id = dt.id AND dm2.user_id <> $1 ORDER BY u.display_name ASC LIMIT 1), '') "
          "FROM direct_threads dt JOIN direct_members dm ON dm.thread_id = dt.id AND dm.user_id = $1 "
          "LEFT JOIN LATERAL (SELECT m.id, m.body, m.user_id, u.display_name, u.username "
          "FROM messages m JOIN users u ON u.id = m.user_id WHERE m.scope = 'direct' AND m.scope_id = dt.id "
          "AND m.deleted_at IS NULL ORDER BY m.id DESC LIMIT 1) lm ON true "
          "WHERE dm.hidden = false "
          "ORDER BY dt.updated_at DESC",
    {ok, Rows} = rows(Conn, Sql, [Uid]),
    {ok, map_rows_resilient(conversations, Rows, fun conversation_row_map/1)};
route({create_conversation, Uid, Name0, UserIds0}, Conn) ->
    UserIds1 = [pw_util:int(X) || X <- ensure_list(UserIds0)],
    UserIds = lists:usort([X || X <- UserIds1, is_integer(X), X =/= Uid]),
    Name = pw_util:clean_text(Name0, 80),
    case {UserIds, length(UserIds) =< 49, users_exist(Conn, UserIds), users_not_blocked(Conn, Uid, UserIds)} of
        {[], _, _, _} ->
            {error, invalid_members};
        {_, false, _, _} ->
            {error, too_many_members};
        {_, _, false, _} ->
            {error, invalid_members};
        {_, _, _, false} ->
            {error, forbidden};
        {[Peer], _, true, true} when Name =:= <<>> ->
            create_one_to_one0(Conn, Uid, Peer);
        {_, _, true, true} ->
            create_conversation0(Conn, Uid, Name, UserIds)
    end;
route({create_conversation_usernames, Uid, Name0, Usernames0}, Conn) ->
    Usernames = lists:usort([Normalized
        || Name <- ensure_list(Usernames0),
           Normalized <- [pw_util:normalize_username(strip_username_prefix(pw_util:bin(Name)))],
           Normalized =/= <<>>]),
    case {Usernames, length(Usernames) =< 49} of
        {[], _} -> {error, invalid_members};
        {_, false} -> {error, too_many_members};
        _ ->
            case user_ids_for_usernames(Conn, Usernames) of
                {ok, UserIds} -> route({create_conversation, Uid, Name0, UserIds}, Conn);
                error -> {error, user_not_found}
            end
    end;
route({update_conversation, Uid, Cid0, Name0, Patch}, Conn) ->
    Cid = pw_util:int(Cid0),
    Name = pw_util:clean_text(Name0, 80),
    RawAvatar = maps:get(<<"avatar_url">>, Patch, <<>>),
    Avatar = store_image_url(RawAvatar),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT owner_id FROM direct_threads WHERE id = $1 FOR UPDATE", [Cid]) of
            {ok, [Uid]} ->
                HasAvatar = maps:is_key(<<"avatar_url">>, Patch)
                    andalso not derived_media_url(RawAvatar)
                    andalso server_image_input_allowed(Conn, Uid, RawAvatar),
                Now = pw_util:now_ms(),
                ok = exec(Conn,
                    "UPDATE direct_threads SET name = $1, avatar_url = CASE WHEN $2 THEN $3 ELSE avatar_url END, updated_at = $4 WHERE id = $5",
                    [Name, HasAvatar, Avatar, Now, Cid]),
                case HasAvatar of
                    true -> sync_message_scope_upload_refs(Conn, <<"direct">>, Cid, Now);
                    false -> ok
                end,
                {ok, #{updated => true}};
            {ok, [_]} -> {error, forbidden};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, _} ->
            publish_conversation_event(Conn, Cid, #{type => conversation_updated, conversation_id => Cid}),
            Result;
        _ -> Result
    end;
route({set_conversation_member_role, Uid, Cid0, Target0, Role0}, Conn) ->
    Cid = pw_util:int(Cid0), Target = pw_util:int(Target0),
    Role = case pw_util:clean_text(Role0, 16) of <<"moderator">> -> <<"moderator">>; <<"member">> -> <<"member">>; _ -> invalid end,
    Result = with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT owner_id FROM direct_threads WHERE id = $1 FOR UPDATE", [Cid]),
        case {conversation_member_count(Conn, Cid) > 2, is_conversation_owner(Conn, Uid, Cid), Role,
              one(Conn, "SELECT group_role FROM direct_members WHERE thread_id = $1 AND user_id = $2 FOR UPDATE", [Cid, Target])} of
            {false, _, _, _} -> {error, not_group};
            {_, false, _, _} -> {error, forbidden};
            {_, _, invalid, _} -> {error, invalid_role};
            {_, true, _, {ok, [<<"owner">>]}} -> {error, owner_role_locked};
            {_, true, ValidRole, {ok, [_]}} ->
                ok = exec(Conn, "UPDATE direct_members SET group_role = $1 WHERE thread_id = $2 AND user_id = $3", [ValidRole, Cid, Target]),
                {ok, #{updated => true, user_id => Target, role => ValidRole}};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, _} -> publish_conversation_event(Conn, Cid, #{type => conversation_members_changed, conversation_id => Cid}), Result;
        _ -> Result
    end;
route({kick_conversation_member, Uid, Cid0, Target0}, Conn) ->
    Cid = pw_util:int(Cid0), Target = pw_util:int(Target0),
    Result = with_tx(Conn, fun() ->
        _ = one(Conn, "SELECT owner_id FROM direct_threads WHERE id = $1 FOR UPDATE", [Cid]),
        case {conversation_member_count(Conn, Cid) > 2, conversation_role0(Conn, Uid, Cid), conversation_role0(Conn, Target, Cid)} of
            {false, _, _} -> {error, not_group};
            {_, _, none} -> {error, not_found};
            {_, _, owner} -> {error, forbidden};
            {_, owner, _} when Target =/= Uid ->
                ok = exec(Conn, "DELETE FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Target]),
                {ok, #{kicked => true, user_id => Target}};
            {_, moderator, member} when Target =/= Uid ->
                ok = exec(Conn, "DELETE FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Target]),
                {ok, #{kicked => true, user_id => Target}};
            _ -> {error, forbidden}
        end
    end),
    case Result of
        {ok, _} ->
            pw_upload_gc:invalidate_user(Target),
            pw_cluster:revoke_conversation_access(Target, Cid),
            publish_conversation_event(Conn, Cid, #{type => conversation_member_removed, conversation_id => Cid, user_id => Target}),
            Result;
        _ -> Result
    end;

route({add_conversation_members, Uid, Cid0, UserIds0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case Cid of
        I when is_integer(I), I > 0 ->
            Result = with_tx(Conn, fun() ->
                _ = rows(Conn, "SELECT pg_advisory_xact_lock($1)", [Cid]),
                route({add_conversation_members_locked, Uid, Cid, UserIds0}, Conn)
            end),
            case Result of
                {ok, #{added := Added}} when Added > 0 ->
                    GrantedUsers = lists:usort([X || X <- [pw_util:int(Y) || Y <- ensure_list(UserIds0)], is_integer(X), X =/= Uid]),
                    invalidate_upload_authz_users(GrantedUsers),
                    publish_conversation_event(Conn, Cid, #{type => conversation_members_added, conversation_id => Cid}),
                    Result;
                _ -> Result
            end;
        _ -> {error, invalid_conversation}
    end;
route({add_conversation_members_locked, Uid, Cid0, UserIds0}, Conn) ->
    Cid = pw_util:int(Cid0),
    RequestedIds = lists:usort([X || X <- [pw_util:int(Y) || Y <- ensure_list(UserIds0)], is_integer(X), X =/= Uid]),
    UserIds = new_conversation_member_ids(Conn, Cid, RequestedIds),
    ExistingCount = conversation_member_count(Conn, Cid),
    case {conversation_can_manage_members(Conn, Uid, Cid), RequestedIds, UserIds, users_exist(Conn, RequestedIds), users_not_blocked(Conn, Uid, RequestedIds), ExistingCount + length(UserIds) =< 50} of
        {true, [], _, _, _, _} ->
            {error, invalid_members};
        {true, _, _, false, _, _} ->
            {error, invalid_members};
        {true, _, _, _, false, _} ->
            {error, forbidden};
        {true, _, _, _, _, false} ->
            {error, too_many_members};
        {true, _, [], true, true, true} ->
            {ok, #{added => 0}};
        {true, _, _, true, true, true} ->
            Now = pw_util:now_ms(),
            [exec(Conn,
                "INSERT INTO direct_members(thread_id, user_id, last_read_message_id, muted, nickname, joined_at) "
                "VALUES($1,$2,0,false,$3,$4) ON CONFLICT (thread_id, user_id) DO NOTHING",
                [Cid, U, <<>>, Now]) || U <- UserIds],
            {ok, #{added => length(UserIds)}};
        {false, _, _, _, _, _} ->
            {error, forbidden}
    end;
route({add_conversation_members_usernames, Uid, Cid, Usernames0}, Conn) ->
    Usernames = lists:usort([Normalized
        || Name <- ensure_list(Usernames0),
           Normalized <- [pw_util:normalize_username(strip_username_prefix(pw_util:bin(Name)))],
           Normalized =/= <<>>]),
    case {Usernames, length(Usernames) =< 49, user_ids_for_usernames(Conn, Usernames)} of
        {[], _, _} -> {error, invalid_members};
        {_, false, _} -> {error, too_many_members};
        {_, _, {ok, UserIds}} -> route({add_conversation_members, Uid, Cid, UserIds}, Conn);
        _ -> {error, user_not_found}
    end;
route({close_conversation, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case is_conversation_member(Conn, Uid, Cid) of
        true ->
            ok = exec(Conn, "UPDATE direct_members SET hidden = true WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]),
            {ok, #{closed => true}};
        false ->
            {error, not_found}
    end;
route({leave_conversation, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT owner_id FROM direct_threads WHERE id = $1 FOR UPDATE", [Cid]) of
            {ok, [OwnerId]} ->
                case is_conversation_member(Conn, Uid, Cid) of
                    true ->
                        case conversation_member_count(Conn, Cid) =< 2 of
                            true ->
                                %% 1:1 chats close; they don't implode.
                                ok = exec(Conn, "UPDATE direct_members SET hidden = true WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]),
                                {ok, #{left => false, closed => true}};
                            false ->
                                ok = exec(Conn, "DELETE FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]),
                                case OwnerId =:= Uid of
                                    true ->
                                        %% Pass ownership and the group-role badge atomically.
                                        case one(Conn, "SELECT user_id FROM direct_members WHERE thread_id = $1 ORDER BY CASE group_role WHEN 'moderator' THEN 0 ELSE 1 END, joined_at ASC LIMIT 1", [Cid]) of
                                            {ok, [NewOwner]} ->
                                                ok = exec(Conn, "UPDATE direct_threads SET owner_id = $1 WHERE id = $2", [NewOwner, Cid]),
                                                ok = exec(Conn, "UPDATE direct_members SET group_role = CASE WHEN user_id = $1 THEN 'owner' ELSE CASE WHEN group_role = 'owner' THEN 'member' ELSE group_role END END WHERE thread_id = $2", [NewOwner, Cid]);
                                            _ -> ok
                                        end;
                                    false -> ok
                                end,
                                {ok, #{left => true}}
                        end;
                    false ->
                        {error, not_found}
                end;
            _ ->
                {error, not_found}
        end
    end),
    case Result of
        {ok, #{left := true}} ->
            %% Leaving is an access revocation just like a kick.  Invalidate only
            %% after COMMIT so a rolled-back membership change cannot perturb the
            %% live/cache view of the conversation.
            pw_upload_gc:invalidate_user(Uid),
            pw_cluster:revoke_conversation_access(Uid, Cid),
            publish_conversation_event(Conn, Cid, #{type => conversation_members_changed, conversation_id => Cid}),
            Result;
        _ -> Result
    end;
route({accept_message_request, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT request_state FROM direct_members WHERE thread_id = $1 AND user_id = $2 FOR UPDATE", [Cid, Uid]) of
            {ok, [<<"pending">>]} ->
                ok = exec(Conn, "UPDATE direct_members SET request_state = 'accepted' WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]),
                {ok, #{accepted => true, conversation_id => Cid, changed => true}};
            {ok, [<<"accepted">>]} ->
                {ok, #{accepted => true, conversation_id => Cid, changed => false}};
            _ ->
                {error, no_message_request}
        end
    end),
    case Result of
        {ok, #{changed := true} = Data} ->
            Now = pw_util:now_ms(),
            best_effort_direct_notifications(Conn, Cid, Uid,
                #{type => message_request_accepted, conversation_id => Cid}, Now, false),
            {ok, maps:remove(changed, Data)};
        {ok, Data} -> {ok, maps:remove(changed, Data)};
        Other -> Other
    end;
route({deny_message_request, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT request_state FROM direct_members WHERE thread_id = $1 AND user_id = $2 FOR UPDATE", [Cid, Uid]) of
            {ok, [<<"pending">>]} ->
                {ok, MemberRows} = rows(Conn, "SELECT user_id, muted FROM direct_members WHERE thread_id = $1", [Cid]),
                MemberIds = [MemberId || [MemberId, _Muted] <- MemberRows],
                NotifyIds = [MemberId || [MemberId, false] <- MemberRows, MemberId =/= Uid],
                %% Reconcile through the ACL helper rather than deleting rows
                %% directly so cached positive grants are revoked immediately.
                ok = remove_scope_upload_refs(Conn, <<"direct">>, Cid),
                ok = enqueue_scylla_hard_deletes_for_scope(Conn, <<"direct">>, Cid),
                ok = exec(Conn, "DELETE FROM messages WHERE scope = 'direct' AND scope_id = $1", [Cid]),
                ok = exec(Conn, "DELETE FROM direct_threads WHERE id = $1", [Cid]),
                {ok, #{denied => true, conversation_id => Cid,
                       member_ids => MemberIds, notify_ids => NotifyIds}};
            _ ->
                {error, no_message_request}
        end
    end),
    case Result of
        {ok, #{member_ids := MemberIds, notify_ids := NotifyIds} = Data} ->
            Event = #{type => conversation_closed, conversation_id => Cid, reason => request_denied},
            [begin
                 pw_upload_gc:invalidate_user(MemberId),
                 pw_cluster:revoke_conversation_access(MemberId, Cid)
             end || MemberId <- MemberIds],
            [best_effort_user_notification(Conn, MemberId, <<"conversation_closed">>,
                <<"Message request declined">>, <<"#/dms">>, pw_util:now_ms(), Event)
                || MemberId <- NotifyIds],
            {ok, maps:without([member_ids, notify_ids], Data)};
        Other -> Other
    end;
route({mark_conversation_read, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case is_conversation_member(Conn, Uid, Cid) of
        true ->
            {ok, [LastId]} = one(Conn, "SELECT COALESCE(max(id), 0) FROM messages WHERE scope = 'direct' AND scope_id = $1", [Cid]),
            ok = exec(Conn, "UPDATE direct_members SET last_read_message_id = $1 WHERE thread_id = $2 AND user_id = $3", [LastId, Cid, Uid]),
            {ok, #{read => true, last_read_message_id => LastId}};
        false ->
            {error, forbidden}
    end;
route({conversation, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case is_conversation_member(Conn, Uid, Cid) of
        true ->
            {ok, Info} = one(Conn, "SELECT id, name, avatar_url, owner_id, created_at, updated_at FROM direct_threads WHERE id = $1", [Cid]),
            {ok, Members} = rows(Conn,
                "SELECT u.id, u.username, u.display_name, u.bio, u.avatar_url, u.banner_url, u.status, u.theme, "
                "u.created_at, u.last_seen, dm.last_read_message_id, dm.muted, dm.nickname, dm.joined_at, dm.group_role "
                "FROM direct_members dm JOIN users u ON u.id = dm.user_id WHERE dm.thread_id = $1 ORDER BY u.display_name ASC",
                [Cid]),
            {ok, #{conversation => conversation_full_map(Info), members => [conversation_member_map(M) || M <- Members]}};
        false ->
            {error, forbidden}
    end;
route({post_direct_message, Uid, Cid0, Body0, ReplyTo0}, Conn) ->
    Cid = pw_util:int(Cid0),
    Plain = pw_util:clean_text(Body0, ?MAX_MSG),
    Body = store_message(Plain),
    ReplyTo = pw_util:int(ReplyTo0),
    case message_body_valid(Plain) of
        false -> {error, invalid_message};
        true ->
            Result = with_tx(Conn, fun() ->
                case {conversation_can_send(Conn, Uid, Cid), valid_reply_to(Conn, <<"direct">>, Cid, ReplyTo)} of
                    {true, true} ->
                        Now = pw_util:now_ms(),
                        Mid = new_message_id(),
                        ok = exec(Conn,
                            "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
                            [Mid, <<"direct">>, Cid, Uid, Body, ReplyTo, Now]),
                        insert_upload_refs(Conn, Plain, <<"direct">>, Cid, Now),
                        ok = exec(Conn, "UPDATE direct_threads SET updated_at=$1 WHERE id=$2", [Now, Cid]),
                        ok = exec(Conn, "UPDATE direct_members SET last_read_message_id=$1 WHERE thread_id=$2 AND user_id=$3", [Mid, Cid, Uid]),
                        ok = exec(Conn, "UPDATE direct_members SET hidden=false WHERE thread_id=$1 AND user_id<>$2", [Cid, Uid]),
                        ok = storage_after_message_change(Conn, Mid, <<"message.created">>, Uid),
                        {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                        {ok, #{message => message_map(Conn, Row), notify_at => Now}};
                    {false, _} -> {error, forbidden};
                    _ -> {error, invalid_message}
                end
            end),
            case Result of
                {ok, #{message := Msg, notify_at := Now}} ->
                    invalidate_message_cache(<<"direct">>, Cid),
                    pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
                    best_effort_direct_notifications(Conn, Cid, Uid, #{type => direct_message, conversation_id => Cid, message => Msg}, Now, false),
                    {ok, Msg};
                Other -> Other
            end
    end;
route({record_missed_call, Uid, Cid0}, Conn) ->
    route({record_call_event, Uid, Cid0, <<"missed_call">>, <<"Missed call">>}, Conn);
route({record_call_event, Uid, Cid0, Kind, Text}, Conn) ->
    Cid = pw_util:int(Cid0),
    Result = with_tx(Conn, fun() ->
        case conversation_can_send(Conn, Uid, Cid) of
            false -> {error, forbidden};
            true ->
                Now = pw_util:now_ms(),
                Body = store_message(Text),
                Mid = new_message_id(),
                ok = exec(Conn,
                    "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at,kind) VALUES($1,'direct',$2,$3,$4,NULL,$5,$6)",
                    [Mid, Cid, Uid, Body, Now, Kind]),
                ok = exec(Conn, "UPDATE direct_threads SET updated_at=$1 WHERE id=$2", [Now, Cid]),
                ok = exec(Conn, "UPDATE direct_members SET last_read_message_id=$1 WHERE thread_id=$2 AND user_id=$3", [Mid, Cid, Uid]),
                ok = exec(Conn, "UPDATE direct_members SET hidden=false WHERE thread_id=$1", [Cid]),
                ok = storage_after_message_change(Conn, Mid, <<"message.created">>, Uid),
                {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                {ok, #{message => message_map(Conn, Row), notify_at => Now}}
        end
    end),
    case Result of
        {ok, #{message := Msg, notify_at := Now}} ->
            invalidate_message_cache(<<"direct">>, Cid),
            pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
            case Kind of
                <<"missed_call">> -> best_effort_missed_call_notifications(Conn, Cid, Uid, Msg, Now);
                _ -> ok
            end,
            {ok, Msg};
        Other -> Other
    end;
route({notifications, Uid}, Conn) ->
    {ok, Rows} = rows(Conn, "SELECT id, kind, body, url, seen, created_at FROM notifications WHERE user_id = $1 ORDER BY id DESC LIMIT 120", [Uid]),
    {ok, [notification_map(R) || R <- Rows]};
route({mark_notifications_seen, Uid}, Conn) ->
    ok = exec(Conn, "UPDATE notifications SET seen = true WHERE user_id = $1", [Uid]),
    {ok, #{seen => true}};
route({clear_notifications, Uid}, Conn) ->
    ok = exec(Conn, "DELETE FROM notifications WHERE user_id = $1", [Uid]),
    {ok, #{cleared => true}};
route({mark_url_seen, Uid, Url}, Conn) ->
    mark_url_seen0(Conn, Uid, pw_util:clean_text(Url, 240)),
    {ok, #{seen => true}};
route({begin_upload, Uid, Id, Name, Type, Size, Path}, Conn) ->
    Now = pw_util:now_ms(),
    WindowStart = Now - 10800000,
    Quota = min(1073741824, max(262144000, pw_util:env_int("PLAINWIRE_UPLOAD_QUOTA_BYTES", 1073741824))),
    with_tx(Conn, fun() ->
        _ = rows(Conn, "SELECT pg_advisory_xact_lock($1)", [Uid]),
        {ok, [UsedRaw]} = one(Conn,
            "SELECT COALESCE(sum(size), 0) FROM uploads WHERE user_id = $1 AND created_at >= $2 AND status IN ('pending','ready')",
            [Uid, WindowStart]),
        Used = pw_util:int(UsedRaw),
        case Used + Size =< Quota of
            true ->
                ok = exec(Conn,
                    "INSERT INTO uploads(id,user_id,name,content_type,size,path,status,created_at) VALUES($1,$2,$3,$4,$5,$6,'pending',$7)",
                    [Id, Uid, Name, Type, Size, Path, Now]),
                {ok, reserved};
            false -> {error, quota_exceeded}
        end
    end);
route({finish_upload, Uid, Id, Hash}, Conn) ->
    case one(Conn,
        "UPDATE uploads SET status = 'ready', sha256 = $1 WHERE id = $2 AND user_id = $3 AND status = 'pending' RETURNING id",
        [Hash, Id, Uid]) of
        {ok, [_]} -> ok;
        {ok, undefined} -> {error, not_found};
        {error, Reason} -> erlang:error({sql_error, Reason, finish_upload})
    end;
route({abort_upload, Uid, Id}, Conn) ->
    exec(Conn, "DELETE FROM uploads WHERE id = $1 AND user_id = $2 AND status = 'pending'", [Id, Uid]);
route({get_upload, Uid, Id}, Conn) ->
    case one(Conn, "SELECT name,content_type,size,path,sha256,user_id FROM uploads WHERE id = $1 AND status = 'ready'", [Id]) of
        {ok, [Name, Type, Size, Path, Hash, OwnerId]} ->
            case upload_readable(Conn, Uid, Id, pw_util:int(OwnerId)) of
                true -> {ok, #{name => Name, content_type => Type, size => Size, path => Path, sha256 => Hash}};
                false -> {error, forbidden}
            end;
        _ -> {error, not_found}
    end;
route({upload_ref_backfill, Batch0}, Conn) ->
    Batch = min(2000, max(1, pw_util:int(Batch0))),
    %% No parameters, so rows/3 takes the simple-query path (epgsql:squery) and
    %% `done` arrives as text: <<"t">>, never the atom true. Without accepting
    %% both, a finished backfill re-walks messages forever and dies writing a
    %% 64-bit message id into the int4 cursor column, killing a pool connection
    %% every 30 seconds.
    case one(Conn, "SELECT cursor, done FROM upload_ref_backfill WHERE id = 1", []) of
        {ok, [_, Done]} when Done =:= true; Done =:= <<"t">> -> {ok, done};
        {ok, [Cursor0, _]} ->
            Cursor = pw_util:int(Cursor0),
            {ok, Rows} = rows(Conn,
                "SELECT id, scope, scope_id, body, created_at FROM messages "
                "WHERE id > $1 AND deleted_at IS NULL ORDER BY id ASC LIMIT $2", [Cursor, Batch]),
            case Rows of
                [] ->
                    ok = exec(Conn, "UPDATE upload_ref_backfill SET done = true WHERE id = 1", []),
                    {ok, done};
                _ ->
                    lists:foreach(fun([_, Scope, ScopeId, Body, CreatedAt]) ->
                        insert_upload_refs(Conn, load_message(Body), Scope, pw_util:int(ScopeId), pw_util:int(CreatedAt))
                    end, Rows),
                    Last = lists:max([pw_util:int(Mid) || [Mid, _, _, _, _] <- Rows]),
                    ok = exec(Conn, "UPDATE upload_ref_backfill SET cursor = $1 WHERE id = 1", [Last]),
                    {ok, continue}
            end;
        _ -> {error, not_found}
    end;
route({stale_uploads, PendingBefore, ReadyBefore}, Conn) ->
    {ok, Rows} = rows(Conn,
        "SELECT up.id,up.path FROM uploads up "
        "WHERE ((up.status = 'pending' AND up.created_at < $1) OR "
        "(up.status = 'ready' AND up.created_at < $2)) "
        "AND NOT EXISTS (SELECT 1 FROM users u WHERE "
        "u.avatar_url = '/api/files/' || up.id OR u.banner_url = '/api/files/' || up.id) "
        "AND NOT EXISTS (SELECT 1 FROM upload_refs r WHERE r.upload_id = up.id) "
        "LIMIT 500", [PendingBefore, ReadyBefore]),
    {ok, [#{id => Id, path => Path} || [Id, Path] <- Rows]};
route({delete_upload, Id}, Conn) ->
    %% Legacy metadata deletion API. Queue the physical path before removing the
    %% row so a process crash cannot orphan bytes on disk.
    with_tx(Conn, fun() ->
        case one(Conn, "SELECT path FROM uploads WHERE id=$1 FOR UPDATE", [Id]) of
            {ok, [Path]} ->
                ok = enqueue_upload_delete_path(Conn, Path),
                ok = exec(Conn, "DELETE FROM uploads WHERE id=$1", [Id]),
                ok;
            _ -> ok
        end
    end);
route({queue_stale_upload_deletes, PendingBefore0, ReadyBefore0}, Conn) ->
    PendingBefore = max(0, int_or(pw_util:int(PendingBefore0), 0)),
    ReadyBefore = max(0, int_or(pw_util:int(ReadyBefore0), 0)),
    with_tx(Conn, fun() ->
        {ok, Candidates} = rows(Conn,
            "SELECT up.id,up.path FROM uploads up "
            "WHERE ((up.status='pending' AND up.created_at<$1) OR (up.status='ready' AND up.created_at<$2)) "
            "AND NOT EXISTS (SELECT 1 FROM users u WHERE u.avatar_url='/api/files/' || up.id OR u.banner_url='/api/files/' || up.id) "
            "AND NOT EXISTS (SELECT 1 FROM upload_refs r WHERE r.upload_id=up.id) "
            "ORDER BY up.created_at ASC,up.id ASC FOR UPDATE OF up SKIP LOCKED LIMIT 500",
            [PendingBefore, ReadyBefore]),
        lists:foreach(fun([_Id, Path]) -> ok = enqueue_upload_delete_path(Conn, Path) end, Candidates),
        Ids = [pw_util:bin(Id) || [Id, _] <- Candidates],
        lists:foreach(fun(Id) -> ok = exec(Conn, "DELETE FROM uploads WHERE id=$1", [Id]) end, Ids),
        {ok, #{queued => length(Candidates), ids => Ids}}
    end);
route({upload_delete_claim, Limit0}, Conn) ->
    Limit = min(64, max(1, int_or(pw_util:int(Limit0), 16))),
    Now = pw_util:now_ms(),
    LeaseCutoff = Now - 60000,
    with_tx(Conn, fun() ->
        ok = exec(Conn,
            "UPDATE upload_delete_queue SET status='pending',locked_at=0,updated_at=$1 "
            "WHERE status='running' AND locked_at>0 AND locked_at<$2", [Now, LeaseCutoff]),
        {ok, Claimed} = rows(Conn,
            "WITH picked AS (SELECT path FROM upload_delete_queue "
            "WHERE status='pending' AND next_attempt_at<=$1 ORDER BY next_attempt_at ASC,created_at ASC,path ASC "
            "FOR UPDATE SKIP LOCKED LIMIT $2) "
            "UPDATE upload_delete_queue q SET status='running',attempts=q.attempts+1,locked_at=$1,updated_at=$1 "
            "FROM picked p WHERE q.path=p.path RETURNING q.path,q.attempts", [Now, Limit]),
        {ok, [#{path => pw_util:bin(Path), attempts => Attempts} || [Path, Attempts] <- Claimed]}
    end);
route({upload_delete_finish, Path0, Result}, Conn) ->
    Path = pw_util:clean_text(Path0, 4096),
    Now = pw_util:now_ms(),
    case byte_size(Path) > 0 of
        false -> {error, bad_request};
        true ->
            case Result of
                ok ->
                    ok = exec(Conn, "DELETE FROM upload_delete_queue WHERE path=$1", [Path]),
                    ok;
                {error, Reason0} ->
                    Reason = pw_util:clean_text(io_lib:format("~0p", [Reason0]), 500),
                    case one(Conn, "SELECT attempts FROM upload_delete_queue WHERE path=$1", [Path]) of
                        {ok, [Attempts0]} ->
                            Attempts = max(1, int_or(pw_util:int(Attempts0), 1)),
                            Delay = min(3600000, 1000 * (1 bsl min(12, Attempts - 1))),
                            ok = exec(Conn,
                                "UPDATE upload_delete_queue SET status='pending',locked_at=0,last_error=$2,next_attempt_at=$3,updated_at=$4 WHERE path=$1",
                                [Path, Reason, Now + Delay, Now]),
                            {ok, #{retrying => true, retry_in_ms => Delay}};
                        _ -> {error, not_found}
                    end;
                _ -> {error, bad_request}
            end
    end;
%% public-to-members, yes. imaginary ids, no; they bloat hub subscriptions.
route(search_index_status, Conn) ->
    case one(Conn, "SELECT key_fingerprint,last_message_id,complete,updated_at FROM message_search_state WHERE id=1", []) of
        {ok, [Fingerprint, LastId, Complete, UpdatedAt]} ->
            {ok, #{key_fingerprint => Fingerprint, last_message_id => LastId, complete => Complete, updated_at => UpdatedAt}};
        _ -> {ok, #{key_fingerprint => <<>>, last_message_id => 0, complete => false, updated_at => 0}}
    end;
route({search_index_reconcile, Limit0}, Conn) ->
    Limit = min(250, max(10, case pw_util:int(Limit0) of undefined -> 100; L -> L end)),
    case pw_crypto:search_enabled() of
        false -> {ok, #{enabled => false, indexed => 0, complete => false}};
        true ->
            Fingerprint = pw_crypto:search_key_fingerprint(),
            with_tx(Conn, fun() ->
                {ok, State} = one(Conn,
                    "SELECT key_fingerprint,last_message_id,complete FROM message_search_state WHERE id=1 FOR UPDATE", []),
                {OldFingerprint, Last0, Complete0} = case State of
                    [F, L0, C0] -> {F, L0, C0};
                    _ -> {<<>>, 0, false}
                end,
                Last = case OldFingerprint =:= Fingerprint of
                    true -> Last0;
                    false ->
                        ok = exec(Conn, "DELETE FROM message_search_tokens", []),
                        ok = exec(Conn,
                            "UPDATE message_search_state SET key_fingerprint=$1,last_message_id=0,complete=false,updated_at=$2 WHERE id=1",
                            [Fingerprint, pw_util:now_ms()]),
                        0
                end,
                case Complete0 andalso OldFingerprint =:= Fingerprint of
                    true -> {ok, #{enabled => true, indexed => 0, complete => true, last_message_id => Last}};
                    false ->
                        {ok, Rows0} = rows(Conn,
                            "SELECT id,body,COALESCE(deleted_at,0),kind FROM messages WHERE id>$1 ORDER BY id ASC LIMIT $2",
                            [Last, Limit]),
                        [sync_search_row(Conn, Row) || Row <- Rows0],
                        NewLast = case lists:reverse(Rows0) of [[Id|_] | _] -> Id; [] -> Last end,
                        Complete = length(Rows0) < Limit,
                        Now = pw_util:now_ms(),
                        ok = exec(Conn,
                            "UPDATE message_search_state SET key_fingerprint=$1,last_message_id=$2,complete=$3,updated_at=$4 WHERE id=1",
                            [Fingerprint, NewLast, Complete, Now]),
                        {ok, #{enabled => true, indexed => length(Rows0), complete => Complete, last_message_id => NewLast}}
                end
            end)
    end;
route({search_messages, Uid, Query0, Before0, Limit0}, Conn) ->
    Query = pw_util:clean_text(Query0, 500),
    Hashes = pw_crypto:search_hashes(Query),
    Limit = min(50, max(1, case pw_util:int(Limit0) of undefined -> 30; L -> L end)),
    Before = case pw_util:int(Before0) of B when is_integer(B), B > 0 -> B; _ -> 9223372036854775807 end,
    case Hashes of
        [] -> {error, invalid_search};
        _ ->
            %% Search tokens are intentionally global blind indexes.  Scan in
            %% bounded pages and re-check the caller's ACL for every candidate
            %% so unrelated private matches cannot crowd older authorized
            %% results out of the first page.  The scan ceiling also bounds DB
            %% work for very common terms without leaking global match counts.
            CandidateBatch = min(250, max(100, Limit * 6)),
            ScanBudget = min(2000, max(500, Limit * 30)),
            Messages = search_authorized_batches(Conn, Uid, Hashes, Before, Limit, CandidateBatch, ScanBudget, []),
            %% Client search needs to know only whether backfill is complete. Do
            %% not disclose instance-wide indexing cursors, key fingerprints, or
            %% timestamps to ordinary users.
            PublicIndex = case route(search_index_status, Conn) of
                {ok, S0} -> #{complete => maps:get(complete, S0, false)};
                _ -> #{complete => false}
            end,
            {ok, #{messages => Messages, query => Query, index => PublicIndex}}
    end;

route({subscribable, thread, Id}, Conn) ->
    case one(Conn, "SELECT id FROM threads WHERE id = $1", [Id]) of
        {ok, [_]} -> true;
        _ -> false
    end;
route({subscribable, forum, Id}, Conn) ->
    case one(Conn, "SELECT id FROM forums WHERE id = $1", [Id]) of
        {ok, [_]} -> true;
        _ -> false
    end;
route({subscribable, _, _}, _Conn) -> false;
route({member_of_channel, Uid, Cid0}, Conn) ->
    case channel_server_member(Conn, Uid, pw_util:int(Cid0)) of
        {ok, Sid} -> has_server_permission(Conn, Uid, Sid, <<"view_channels">>);
        _ -> false
    end;
route({channel_identity, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case channel_server_member(Conn, Uid, Cid) of
        {ok, Sid} ->
            case has_server_permission(Conn, Uid, Sid, <<"view_channels">>) of
                true -> server_member_identity(Conn, Uid, Sid);
                false -> {error, forbidden}
            end;
        _ -> {error, forbidden}
    end;
route({channel_message_identity, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case channel_message_access(Conn, Uid, Cid) of
        {ok, Sid} -> server_member_identity(Conn, Uid, Sid);
        _ -> {error, forbidden}
    end;
route({voice_access, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case one(Conn,
        "SELECT c.server_id,c.kind FROM channels c JOIN server_members sm ON sm.server_id=c.server_id AND sm.user_id=$1 WHERE c.id=$2",
        [Uid,Cid]) of
        {ok, [Sid, <<"voice">>]} ->
            has_server_permission(Conn, Uid, Sid, <<"view_channels">>) andalso
            has_server_permission(Conn, Uid, Sid, <<"voice_connect">>);
        _ -> false
    end;
route({stream_access, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case one(Conn,
        "SELECT c.server_id,c.kind FROM channels c JOIN server_members sm ON sm.server_id=c.server_id AND sm.user_id=$1 WHERE c.id=$2",
        [Uid,Cid]) of
        {ok, [Sid, <<"voice">>]} ->
            has_server_permission(Conn, Uid, Sid, <<"view_channels">>) andalso
            has_server_permission(Conn, Uid, Sid, <<"voice_connect">>) andalso
            has_server_permission(Conn, Uid, Sid, <<"stream">>);
        _ -> false
    end;
route({member_of_conversation, Uid, Cid0}, Conn) ->
    conversation_can_send(Conn, Uid, pw_util:int(Cid0));
route({member_of_server, Uid, Sid0}, Conn) ->
    is_member(Conn, Uid, pw_util:int(Sid0));
route({member_of_thread_forum, Uid, ThreadId0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    case one(Conn,
        "SELECT 1 FROM threads t JOIN forum_members fm ON fm.forum_id=t.forum_id "
        "WHERE t.id=$1 AND fm.user_id=$2", [ThreadId, Uid]) of
        {ok, [_]} -> true;
        _ -> false
    end;
route({conversation_peer_ids, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case conversation_can_send(Conn, Uid, Cid) of
        true ->
            {ok, Rows} = rows(Conn, "SELECT user_id FROM direct_members WHERE thread_id = $1 AND user_id <> $2 AND request_state = 'accepted'", [Cid, Uid]),
            {ok, [only_id(R) || R <- Rows]};
        false ->
            {error, forbidden}
    end.

sync_message_search_index(Conn, Msg) ->
    Mid = maps:get(id, Msg),
    Deleted = maps:get(deleted_at, Msg, undefined),
    Kind = maps:get(kind, Msg, <<"text">>),
    Body = maps:get(body, Msg, <<>>),
    case Deleted =:= undefined andalso Kind =:= <<"text">> of
        true -> replace_message_search_tokens(Conn, Mid, load_message(Body));
        false -> exec(Conn, "DELETE FROM message_search_tokens WHERE message_id=$1", [Mid])
    end.

sync_search_row(Conn, [Mid, Body, DeletedAt, Kind]) ->
    case DeletedAt =:= 0 andalso Kind =:= <<"text">> of
        true -> replace_message_search_tokens(Conn, Mid, load_message(Body));
        false -> exec(Conn, "DELETE FROM message_search_tokens WHERE message_id=$1", [Mid])
    end;
sync_search_row(_Conn, _) -> ok.

replace_message_search_tokens(Conn, Mid, Plain) ->
    Hashes = pw_crypto:search_hashes(Plain),
    ok = exec(Conn, "DELETE FROM message_search_tokens WHERE message_id=$1", [Mid]),
    [ok = exec(Conn,
        "INSERT INTO message_search_tokens(message_id,token) VALUES($1,$2) ON CONFLICT DO NOTHING",
        [Mid, Hash]) || Hash <- Hashes],
    ok.

search_candidate_rows(Conn, Hashes, Before, Limit) ->
    N = length(Hashes),
    TokenPlaceholders = string:join(["$" ++ integer_to_list(I) || I <- lists:seq(2, N + 1)], ","),
    CountParam = N + 2,
    LimitParam = N + 3,
    %% Carry scope metadata in the blind-index query so unauthorized candidates
    %% can be rejected without an extra point SELECT per result. The query still
    %% returns no message plaintext; bodies are loaded only after the normal ACL.
    Sql = "SELECT m.id,m.scope,m.scope_id FROM messages m JOIN message_search_tokens st ON st.message_id=m.id "
          "WHERE m.id<$1 AND m.deleted_at IS NULL AND m.kind='text' AND st.token IN (" ++ TokenPlaceholders ++ ") "
          "GROUP BY m.id,m.scope,m.scope_id HAVING count(DISTINCT st.token)=$" ++ integer_to_list(CountParam) ++
          " ORDER BY m.id DESC LIMIT $" ++ integer_to_list(LimitParam),
    Params = [Before] ++ Hashes ++ [N, Limit],
    case rows(Conn, Sql, Params) of
        {ok, Rs} -> Rs;
        _ -> []
    end.

search_authorized_batches(_Conn, _Uid, _Hashes, _Before, Limit, _Batch, _Budget, Acc) when length(Acc) >= Limit ->
    lists:reverse(Acc);
search_authorized_batches(_Conn, _Uid, _Hashes, _Before, _Limit, _Batch, Budget, Acc) when Budget =< 0 ->
    lists:reverse(Acc);
search_authorized_batches(Conn, Uid, Hashes, Before, Limit, Batch, Budget, Acc) ->
    Fetch = min(Batch, Budget),
    Candidates = search_candidate_rows(Conn, Hashes, Before, Fetch),
    {Acc1, Used} = collect_authorized_search_batch(Conn, Uid, Candidates, Limit, Acc, 0),
    case {length(Acc1) >= Limit, Candidates, length(Candidates) < Fetch} of
        {true, _, _} -> lists:reverse(Acc1);
        {false, [], _} -> lists:reverse(Acc1);
        {false, _, true} -> lists:reverse(Acc1);
        {false, _, false} ->
            [NextBefore | _] = lists:last(Candidates),
            search_authorized_batches(Conn, Uid, Hashes, NextBefore, Limit, Batch, Budget - Used, Acc1)
    end.

collect_authorized_search_batch(_Conn, _Uid, _Candidates, Limit, Acc, Used) when length(Acc) >= Limit -> {Acc, Used};
collect_authorized_search_batch(_Conn, _Uid, [], _Limit, Acc, Used) -> {Acc, Used};
collect_authorized_search_batch(Conn, Uid, [[Mid, Scope, ScopeId] | Rest], Limit, Acc, Used0) ->
    Used = Used0 + 1,
    case can_read_messages(Conn, Uid, Scope, ScopeId) of
        true ->
            case one(Conn, message_select() ++ " WHERE m.id=$1 AND m.deleted_at IS NULL", [Mid]) of
                {ok, Row} -> collect_authorized_search_batch(Conn, Uid, Rest, Limit, [message_map(Conn, Row) | Acc], Used);
                _ -> collect_authorized_search_batch(Conn, Uid, Rest, Limit, Acc, Used)
            end;
        false -> collect_authorized_search_batch(Conn, Uid, Rest, Limit, Acc, Used)
    end.

map_rows_resilient(Name, Rows, Fun) ->
    {Items, _} = lists:foldl(fun(Row, {Acc, Index}) ->
        try Fun(Row) of
            Item -> {[Item | Acc], Index + 1}
        catch
            Class:Reason ->
                %% Do not log the row itself: profile/message data can be private.
                logger:warning("[plainwire:db] row_present_failed component=~p index=~p class=~p reason=~p",
                    [Name, Index, Class, Reason]),
                {Acc, Index + 1}
        end
    end, {[], 0}, Rows),
    lists:reverse(Items).

sync_component(Name, Default, Fun) ->
    try Fun() of
        {ok, Data} -> {Data, []};
        {error, Reason} ->
            logger:error("[plainwire:db] sync_component_failed component=~p reason=~p", [Name, Reason]),
            {Default, [atom_to_binary(Name, utf8)]};
        Other ->
            logger:error("[plainwire:db] sync_component_failed component=~p unexpected=~p", [Name, Other]),
            {Default, [atom_to_binary(Name, utf8)]}
    catch
        Class:Reason:Stack ->
            case db_error(Reason) of
                true -> erlang:raise(Class, Reason, Stack);
                false ->
                    logger:error("[plainwire:db] sync_component_failed component=~p class=~p reason=~p stack=~p", [Name, Class, Reason, Stack]),
                    {Default, [atom_to_binary(Name, utf8)]}
            end
    end.

invalidate_upload_authz_users(Uids) ->
    [pw_upload_gc:invalidate_user(MemberId) || MemberId <- lists:usort(Uids), is_integer(MemberId)],
    ok.

invalidate_server_upload_authz(Conn, Sid) ->
    case rows(Conn, "SELECT user_id FROM server_members WHERE server_id = $1", [Sid]) of
        {ok, MemberRows} -> invalidate_upload_authz_users([MemberId || [MemberId] <- MemberRows]);
        _ -> ok
    end.

invalidate_role_upload_authz(Conn, Sid, RoleId) ->
    case rows(Conn, "SELECT user_id FROM server_member_roles WHERE server_id = $1 AND role_id = $2", [Sid, RoleId]) of
        {ok, MemberRows} -> invalidate_upload_authz_users([MemberId || [MemberId] <- MemberRows]);
        _ -> ok
    end.

invalidate_session_cache(Uid) ->
    ets:foldl(fun({H, Session, _}, _) ->
        case maps:get(user, Session, undefined) of
            #{id := Uid} -> ets:delete(?SESSION_CACHE, H);
            _ -> ok
        end
    end, ok, ?SESSION_CACHE),
    ok.

%% cache expiry cannot outlive the real session.
session_cache_expiry(Now, ExpiresAt) ->
    case pw_util:int(ExpiresAt) of
        Expires when is_integer(Expires) -> min(Now + 300000, Expires);
        _ -> Now + 300000
    end.

make_session(Conn, Uid) ->
    Token = pw_util:random_token(32),
    Csrf = pw_util:random_token(24),
    H = pw_util:sha256_hex(Token),
    Now = pw_util:now_ms(),
    SessionDays = clamp_session_days(pw_util:env_int("PLAINWIRE_SESSION_DAYS", 30)),
    Expires = Now + SessionDays * 24 * 60 * 60 * 1000,
    %% Opportunistically prune this account before adding another session. This
    %% keeps compromised credentials or automated logins from growing the table
    %% forever while still allowing normal multi-device use.
    _ = exec(Conn, "DELETE FROM sessions WHERE user_id = $1 AND expires_at <= $2", [Uid, Now]),
    ok = exec(Conn, "INSERT INTO sessions(token_hash, user_id, csrf, created_at, expires_at, last_seen) VALUES($1,$2,$3,$4,$5,$6)",
        [H, Uid, Csrf, Now, Expires, Now]),
    MaxSessions = clamp_max_sessions(pw_util:env_int("PLAINWIRE_MAX_SESSIONS_PER_USER", 32)),
    {ok, Evicted} = rows(Conn,
        "DELETE FROM sessions WHERE token_hash IN ("
        "SELECT token_hash FROM sessions WHERE user_id = $1 AND token_hash <> $2 "
        "ORDER BY last_seen DESC, created_at DESC OFFSET $3) RETURNING token_hash",
        [Uid, H, MaxSessions - 1]),
    [ets:delete(?SESSION_CACHE, OldHash) || [OldHash] <- Evicted],
    {ok, User} = route({me, Uid}, Conn),
    Session = #{token => Token, csrf => Csrf, user => User, server_time => Now},
    ets:insert(?SESSION_CACHE, {H, maps:remove(token, Session), session_cache_expiry(Now, Expires)}),
    Session.

clamp_session_days(N) when is_integer(N), N >= 1, N =< 365 -> N;
clamp_session_days(N) when is_integer(N), N < 1 -> 1;
clamp_session_days(_) -> 30.

clamp_max_sessions(N) when is_integer(N), N >= 4, N =< 128 -> N;
clamp_max_sessions(N) when is_integer(N), N < 4 -> 4;
clamp_max_sessions(_) -> 32.

migrate(Conn) ->
    ensure_schema_table(Conn),
    %% All API nodes may start at once. PostgreSQL DDL is transactional, but two
    %% nodes racing DROP/ADD CONSTRAINT is still unsafe, so serialize the whole
    %% ordered migration sequence on one session-level advisory lock.
    MigrationLock = 578421975,
    {ok, _} = rows(Conn, "SELECT pg_advisory_lock($1)", [MigrationLock]),
    try
        lists:foreach(fun({V, Sqls}) -> migrate_to(Conn, V, Sqls) end, migrations()),
        seed_forums(Conn),
        ok
    after
        _ = rows(Conn, "SELECT pg_advisory_unlock($1)", [MigrationLock])
    end.

ensure_schema_table(Conn) ->
    _ = exec(Conn, "CREATE TABLE IF NOT EXISTS schema_migrations(version integer PRIMARY KEY, applied_at bigint NOT NULL)", []),
    ok.

migrate_to(Conn, Version, Sqls) ->
    case with_tx(Conn, fun() ->
        case one(Conn, "SELECT version FROM schema_migrations WHERE version = $1 FOR UPDATE", [Version]) of
            {ok, undefined} ->
                [safe_exec(Conn, Sql) || Sql <- Sqls],
                ok = exec(Conn, "INSERT INTO schema_migrations(version, applied_at) VALUES($1,$2)", [Version, pw_util:now_ms()]),
                {ok, migrated};
            _ ->
                {ok, already_applied}
        end
    end) of
        {ok, _} -> ok;
        Other -> erlang:error({migration_failed, Version, Other})
    end.

migrations() -> [
    {1, [
        "CREATE TABLE IF NOT EXISTS users(id serial PRIMARY KEY, username text UNIQUE NOT NULL, display_name text NOT NULL, "
        "password_hash text NOT NULL, password_salt text NOT NULL, bio text NOT NULL DEFAULT '', avatar_url text NOT NULL DEFAULT '', "
        "banner_url text NOT NULL DEFAULT '', status text NOT NULL DEFAULT '', theme text NOT NULL DEFAULT 'system', "
        "created_at bigint NOT NULL, updated_at bigint NOT NULL, last_seen bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS sessions(token_hash text PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "csrf text NOT NULL, created_at bigint NOT NULL, expires_at bigint NOT NULL, last_seen bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS forums(id serial PRIMARY KEY, slug text UNIQUE NOT NULL, name text NOT NULL, description text NOT NULL, position integer NOT NULL)",
        "CREATE TABLE IF NOT EXISTS forum_members(forum_id integer NOT NULL REFERENCES forums(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, joined_at bigint NOT NULL, PRIMARY KEY(forum_id, user_id))",
        "CREATE TABLE IF NOT EXISTS threads(id serial PRIMARY KEY, forum_id integer NOT NULL REFERENCES forums(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id), title text NOT NULL, body text NOT NULL, created_at bigint NOT NULL, "
        "updated_at bigint NOT NULL, reply_count integer NOT NULL DEFAULT 0, locked boolean NOT NULL DEFAULT false, "
        "pinned boolean NOT NULL DEFAULT false, views integer NOT NULL DEFAULT 0, score integer NOT NULL DEFAULT 0, "
        "upvotes integer NOT NULL DEFAULT 0, downvotes integer NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS replies(id serial PRIMARY KEY, thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id), body text NOT NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS friendships(user_low integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "user_high integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, requester_id integer NOT NULL REFERENCES users(id), "
        "addressee_id integer NOT NULL REFERENCES users(id), status text NOT NULL CHECK(status IN ('pending','accepted','blocked')), "
        "created_at bigint NOT NULL, updated_at bigint NOT NULL, PRIMARY KEY(user_low, user_high))",
        "CREATE TABLE IF NOT EXISTS servers(id serial PRIMARY KEY, owner_id integer NOT NULL REFERENCES users(id), name text NOT NULL, "
        "description text NOT NULL, icon_url text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS server_members(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, role text NOT NULL DEFAULT 'member', "
        "muted boolean NOT NULL DEFAULT false, joined_at bigint NOT NULL, PRIMARY KEY(server_id, user_id))",
        "CREATE TABLE IF NOT EXISTS channels(id serial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "name text NOT NULL, kind text NOT NULL CHECK(kind IN ('text','voice')), position integer NOT NULL, topic text NOT NULL DEFAULT '', "
        "created_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS direct_threads(id serial PRIMARY KEY, name text NOT NULL DEFAULT '', avatar_url text NOT NULL DEFAULT '', "
        "owner_id integer NOT NULL REFERENCES users(id), created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS direct_members(thread_id integer NOT NULL REFERENCES direct_threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, last_read_message_id integer NOT NULL DEFAULT 0, "
        "muted boolean NOT NULL DEFAULT false, nickname text NOT NULL DEFAULT '', joined_at bigint NOT NULL, "
        "PRIMARY KEY(thread_id, user_id))",
        "CREATE TABLE IF NOT EXISTS messages(id serial PRIMARY KEY, scope text NOT NULL CHECK(scope IN ('channel','direct')), "
        "scope_id integer NOT NULL, user_id integer NOT NULL REFERENCES users(id), body text NOT NULL, reply_to_id integer, "
        "created_at bigint NOT NULL, edited_at bigint, deleted_at bigint)",
        "CREATE TABLE IF NOT EXISTS notifications(id serial PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "kind text NOT NULL, body text NOT NULL, url text NOT NULL, seen boolean NOT NULL DEFAULT false, created_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS server_invites(code text PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "channel_id integer, creator_id integer NOT NULL REFERENCES users(id), max_uses integer NOT NULL DEFAULT 0, uses integer NOT NULL DEFAULT 0, "
        "created_at bigint NOT NULL, expires_at bigint NOT NULL DEFAULT 0, revoked boolean NOT NULL DEFAULT false)",
        "CREATE INDEX IF NOT EXISTS idx_threads_forum ON threads(forum_id, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_forum_members_user ON forum_members(user_id, forum_id)",
        "CREATE INDEX IF NOT EXISTS idx_replies_thread ON replies(thread_id, created_at)",
        "CREATE INDEX IF NOT EXISTS idx_messages_scope ON messages(scope, scope_id, id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, seen, id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_user ON direct_members(user_id, thread_id)",
        "CREATE INDEX IF NOT EXISTS idx_server_members_user ON server_members(user_id, server_id)",
        "CREATE INDEX IF NOT EXISTS idx_invites_server ON server_invites(server_id, revoked)",
        "CREATE TABLE IF NOT EXISTS thread_votes(thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, value integer NOT NULL CHECK(value IN (-1, 1)), "
        "created_at bigint NOT NULL, PRIMARY KEY(thread_id, user_id))",
        "CREATE INDEX IF NOT EXISTS idx_thread_votes_user ON thread_votes(user_id, thread_id)"
    ]},
    {2, [
        "CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(scope, scope_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_users_last_seen ON users(last_seen DESC)"
    ]},
    {3, [
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS score integer NOT NULL DEFAULT 0",
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS upvotes integer NOT NULL DEFAULT 0",
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS downvotes integer NOT NULL DEFAULT 0",
        "CREATE TABLE IF NOT EXISTS thread_votes(thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, value integer NOT NULL CHECK(value IN (-1, 1)), "
        "created_at bigint NOT NULL, PRIMARY KEY(thread_id, user_id))",
        "CREATE INDEX IF NOT EXISTS idx_thread_votes_user ON thread_votes(user_id, thread_id)"
    ]},
    {4, [
        "CREATE TABLE IF NOT EXISTS forum_members(forum_id integer NOT NULL REFERENCES forums(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, joined_at bigint NOT NULL, PRIMARY KEY(forum_id, user_id))",
        "CREATE INDEX IF NOT EXISTS idx_forum_members_user ON forum_members(user_id, forum_id)"
    ]},
    {5, [
        "ALTER TABLE direct_members ADD COLUMN IF NOT EXISTS request_state text NOT NULL DEFAULT 'accepted'",
        "ALTER TABLE direct_members DROP CONSTRAINT IF EXISTS direct_members_request_state_check",
        "ALTER TABLE direct_members ADD CONSTRAINT direct_members_request_state_check CHECK(request_state IN ('pending','accepted'))",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_requests ON direct_members(user_id, request_state, joined_at DESC)"
    ]},
    {6, [
        "CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications(user_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON messages(reply_to_id) WHERE reply_to_id IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_channels_server ON channels(server_id, position ASC, id ASC)"
    ]},
    {7, [
        "CREATE TABLE IF NOT EXISTS uploads(id text PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "name text NOT NULL, content_type text NOT NULL, size bigint NOT NULL CHECK(size > 0 AND size <= 262144000), "
        "path text NOT NULL, status text NOT NULL CHECK(status IN ('pending','ready')), sha256 text NOT NULL DEFAULT '', created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_uploads_user_created ON uploads(user_id, created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_uploads_pending ON uploads(created_at) WHERE status = 'pending'"
    ]},
    {8, [
        "ALTER TABLE direct_members ADD COLUMN IF NOT EXISTS hidden boolean NOT NULL DEFAULT false"
    ]},
    {9, [
        "ALTER TABLE forums ADD COLUMN IF NOT EXISTS owner_id integer REFERENCES users(id) ON DELETE SET NULL",
        "UPDATE forums f SET owner_id = (SELECT fm.user_id FROM forum_members fm WHERE fm.forum_id = f.id ORDER BY fm.joined_at ASC LIMIT 1) "
        "WHERE f.owner_id IS NULL AND f.slug NOT IN ('general','support','development','security')",
        "CREATE TABLE IF NOT EXISTS thread_views(thread_id integer NOT NULL REFERENCES threads(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, first_viewed_at bigint NOT NULL, "
        "PRIMARY KEY(thread_id,user_id))",
        "CREATE INDEX IF NOT EXISTS idx_thread_views_user ON thread_views(user_id,thread_id)",
        "UPDATE threads SET views = 0"
    ]},
    %% old uploads had no ACL. refs add one without trying to query ciphertext.
    {10, [
        "CREATE TABLE IF NOT EXISTS upload_refs(upload_id text NOT NULL REFERENCES uploads(id) ON DELETE CASCADE, "
        "scope text NOT NULL CHECK(scope IN ('channel','direct','profile')), scope_id integer NOT NULL, "
        "created_at bigint NOT NULL, PRIMARY KEY(upload_id, scope, scope_id))",
        "CREATE INDEX IF NOT EXISTS idx_upload_refs_upload ON upload_refs(upload_id)",
        "CREATE TABLE IF NOT EXISTS upload_ref_backfill(id integer PRIMARY KEY, cursor integer NOT NULL DEFAULT 0, "
        "done boolean NOT NULL DEFAULT false)",
        "INSERT INTO upload_ref_backfill(id, cursor, done) VALUES(1, 0, false) ON CONFLICT (id) DO NOTHING",
        %% profile pictures are public refs.
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'profile', u.id, 0 FROM users u JOIN uploads up ON up.id = substring(u.avatar_url from 12) "
        "WHERE u.avatar_url LIKE '/api/files/%' ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'profile', u.id, 0 FROM users u JOIN uploads up ON up.id = substring(u.banner_url from 12) "
        "WHERE u.banner_url LIKE '/api/files/%' ON CONFLICT DO NOTHING"
    ]},
    {11, [
        "CREATE TABLE IF NOT EXISTS channel_categories(id serial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "name text NOT NULL, position integer NOT NULL, created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_channel_categories_server ON channel_categories(server_id, position ASC, id ASC)",
        "ALTER TABLE channels ADD COLUMN IF NOT EXISTS category_id integer REFERENCES channel_categories(id) ON DELETE SET NULL"
    ]},
    {12, [
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS banner_url text NOT NULL DEFAULT ''",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS accent_color text NOT NULL DEFAULT '#5865f2'"
    ]},
    {13, [
        "ALTER TABLE upload_refs DROP CONSTRAINT IF EXISTS upload_refs_scope_check",
        "ALTER TABLE upload_refs ADD CONSTRAINT upload_refs_scope_check CHECK(scope IN ('channel','direct','profile','server'))",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server', s.id, 0 FROM servers s JOIN uploads up ON up.id = substring(s.icon_url from 12) "
        "WHERE s.icon_url LIKE '/api/files/%' ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server', s.id, 0 FROM servers s JOIN uploads up ON up.id = substring(s.banner_url from 12) "
        "WHERE s.banner_url LIKE '/api/files/%' ON CONFLICT DO NOTHING"
    ]},
    {14, [
        "ALTER TABLE sessions ADD COLUMN IF NOT EXISTS id bigserial",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_id ON sessions(id)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_user_last_seen ON sessions(user_id, last_seen DESC)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON sessions(expires_at)"
    ]},
    {15, [
        "ALTER TABLE users ALTER COLUMN theme SET DEFAULT 'system'"
    ]},
    {16, [
        "CREATE INDEX IF NOT EXISTS idx_friendships_low_updated ON friendships(user_low, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_friendships_high_updated ON friendships(user_high, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_upload_refs_scope_lookup ON upload_refs(scope, scope_id, upload_id)",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_thread_request ON direct_members(thread_id, request_state, user_id)",
        "CREATE INDEX IF NOT EXISTS idx_server_members_server_role ON server_members(server_id, role, user_id)"
    ]},
    {17, [
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS welcome_message text NOT NULL DEFAULT ''"
    ]},
    {18, [
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'text'",
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check",
        "ALTER TABLE messages ADD CONSTRAINT messages_kind_check CHECK(kind IN ('text','missed_call'))"
    ]},
    {19, [
        "ALTER TABLE messages ADD COLUMN IF NOT EXISTS forwarded_from_id integer REFERENCES messages(id) ON DELETE SET NULL",
        "CREATE INDEX IF NOT EXISTS idx_messages_forwarded_from ON messages(forwarded_from_id) WHERE forwarded_from_id IS NOT NULL"
    ]},
    {20, [
        "CREATE TABLE IF NOT EXISTS server_roles(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "name text NOT NULL, color text NOT NULL DEFAULT '#99aab5', permissions bigint NOT NULL DEFAULT 0, position integer NOT NULL DEFAULT 1, "
        "hoist boolean NOT NULL DEFAULT false, mentionable boolean NOT NULL DEFAULT false, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_server_roles_name_unique ON server_roles(server_id, lower(name))",
        "CREATE INDEX IF NOT EXISTS idx_server_roles_order ON server_roles(server_id, position DESC, id ASC)",
        "CREATE TABLE IF NOT EXISTS server_member_roles(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_id bigint NOT NULL REFERENCES server_roles(id) ON DELETE CASCADE, "
        "assigned_by integer REFERENCES users(id) ON DELETE SET NULL, assigned_at bigint NOT NULL, PRIMARY KEY(server_id,user_id,role_id))",
        "CREATE INDEX IF NOT EXISTS idx_server_member_roles_user ON server_member_roles(server_id,user_id,role_id)",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS nickname text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS avatar_url text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS bio text NOT NULL DEFAULT ''",
        "ALTER TABLE direct_members ADD COLUMN IF NOT EXISTS group_role text NOT NULL DEFAULT 'member'",
        "ALTER TABLE direct_members DROP CONSTRAINT IF EXISTS direct_members_group_role_check",
        "ALTER TABLE direct_members ADD CONSTRAINT direct_members_group_role_check CHECK(group_role IN ('owner','moderator','member'))",
        "UPDATE direct_members dm SET group_role = 'owner' FROM direct_threads dt WHERE dm.thread_id = dt.id AND dm.user_id = dt.owner_id",
        "CREATE INDEX IF NOT EXISTS idx_direct_members_group_role ON direct_members(thread_id,group_role,user_id)"
    ]},
    {21, [
        "ALTER TABLE threads ADD COLUMN IF NOT EXISTS raw_body text NOT NULL DEFAULT ''",
        "UPDATE threads SET raw_body = body WHERE raw_body = ''",
        "ALTER TABLE replies ADD COLUMN IF NOT EXISTS raw_body text NOT NULL DEFAULT ''",
        "UPDATE replies SET raw_body = body WHERE raw_body = ''"
    ]},
    {22, [
        %% Existing accounts have already learned the interface. Only accounts created
        %% after this migration enter the automatic welcome tour (registration sets pending).
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_state text NOT NULL DEFAULT 'complete'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_step integer NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS onboarding_updated_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_onboarding_state_check",
        "ALTER TABLE users ADD CONSTRAINT users_onboarding_state_check CHECK(onboarding_state IN ('pending','active','complete','dismissed'))",
        "CREATE INDEX IF NOT EXISTS idx_users_onboarding_state ON users(onboarding_state)"
    ]},
    {23, [
        %% 771 is the historical ordinary-member baseline: view channels, send
        %% messages, create Wires, and connect to voice. Storing it per server lets
        %% owners tighten that baseline without breaking existing installations.
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS default_permissions bigint NOT NULL DEFAULT 771"
    ]},
    {24, [
        %% Thread composers support the same /api/files attachments as chat. Keep
        %% their ACL references explicit so non-author readers can fetch them.
        "ALTER TABLE upload_refs DROP CONSTRAINT IF EXISTS upload_refs_scope_check",
        "ALTER TABLE upload_refs ADD CONSTRAINT upload_refs_scope_check CHECK(scope IN ('channel','direct','profile','server','thread'))",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', t.id, 0 FROM threads t "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(t.raw_body,''),t.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', r.thread_id, 0 FROM replies r "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(r.raw_body,''),r.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING"
    ]},
    {25, [
        %% Rebuild every derived ACL relation once so stale references from profile/
        %% server image replacement or edited/deleted content cannot survive an
        %% upgrade. Message bodies may be encrypted, so channel/direct refs are
        %% rebuilt by the resumable application backfill after this migration.
        "DELETE FROM upload_refs WHERE scope IN ('channel','direct','profile','server','thread')",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'profile', u.id, 0 FROM users u JOIN uploads up ON "
        "(u.avatar_url = '/api/files/' || up.id OR u.banner_url = '/api/files/' || up.id) "
        "ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server', s.id, 0 FROM servers s JOIN uploads up ON "
        "(s.icon_url = '/api/files/' || up.id OR s.banner_url = '/api/files/' || up.id) "
        "ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', t.id, 0 FROM threads t "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(t.raw_body,''),t.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'thread', r.thread_id, 0 FROM replies r "
        "CROSS JOIN LATERAL regexp_matches(COALESCE(NULLIF(r.raw_body,''),r.body), '/api/files/([A-Za-z0-9_-]{24,64})', 'g') AS rx(parts) "
        "JOIN uploads up ON up.id = rx.parts[1] ON CONFLICT DO NOTHING",
        "INSERT INTO upload_ref_backfill(id, cursor, done) VALUES(1, 0, false) ON CONFLICT (id) DO NOTHING",
        "UPDATE upload_ref_backfill SET cursor = 0, done = false WHERE id = 1"
    ]},
    {26, [
        %% Server-scoped member avatars are private to server members. Group-DM
        %% avatars reuse the direct scope so all current conversation members can
        %% fetch them. Backfill both so upgrading does not leave broken images.
        "ALTER TABLE upload_refs DROP CONSTRAINT IF EXISTS upload_refs_scope_check",
        "ALTER TABLE upload_refs ADD CONSTRAINT upload_refs_scope_check CHECK(scope IN ('channel','direct','profile','server','thread','server_member'))",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'server_member', sm.server_id, 0 FROM server_members sm JOIN uploads up ON "
        "sm.avatar_url = '/api/files/' || up.id ON CONFLICT DO NOTHING",
        "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
        "SELECT up.id, 'direct', dt.id, 0 FROM direct_threads dt JOIN uploads up ON "
        "dt.avatar_url = '/api/files/' || up.id ON CONFLICT DO NOTHING"
    ]},
    {27, [
        %% Compatibility repair for installations that were upgraded by older
        %% non-transactional migration code. Every statement is idempotent; the
        %% normal ordered migrations remain authoritative for healthy installs.
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS bio text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS banner_url text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS theme text NOT NULL DEFAULT 'system'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS last_seen bigint NOT NULL DEFAULT 0",
        "ALTER TABLE friendships ADD COLUMN IF NOT EXISTS created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE friendships ADD COLUMN IF NOT EXISTS updated_at bigint NOT NULL DEFAULT 0",
        "CREATE INDEX IF NOT EXISTS idx_friendships_low_updated ON friendships(user_low, updated_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_friendships_high_updated ON friendships(user_high, updated_at DESC)",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS banner_url text NOT NULL DEFAULT ''",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS accent_color text NOT NULL DEFAULT '#5865f2'",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS welcome_message text NOT NULL DEFAULT ''",
        "ALTER TABLE servers ADD COLUMN IF NOT EXISTS default_permissions bigint NOT NULL DEFAULT 771",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS nickname text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS avatar_url text NOT NULL DEFAULT ''",
        "ALTER TABLE server_members ADD COLUMN IF NOT EXISTS bio text NOT NULL DEFAULT ''",
        "CREATE TABLE IF NOT EXISTS channel_categories(id serial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, name text NOT NULL, position integer NOT NULL, created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_channel_categories_server ON channel_categories(server_id, position ASC, id ASC)",
        "ALTER TABLE channels ADD COLUMN IF NOT EXISTS category_id integer REFERENCES channel_categories(id) ON DELETE SET NULL",
        "CREATE TABLE IF NOT EXISTS server_roles(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, name text NOT NULL, color text NOT NULL DEFAULT '#99aab5', permissions bigint NOT NULL DEFAULT 0, position integer NOT NULL DEFAULT 1, hoist boolean NOT NULL DEFAULT false, mentionable boolean NOT NULL DEFAULT false, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS color text NOT NULL DEFAULT '#99aab5'",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS permissions bigint NOT NULL DEFAULT 0",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS position integer NOT NULL DEFAULT 1",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS hoist boolean NOT NULL DEFAULT false",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS mentionable boolean NOT NULL DEFAULT false",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE server_roles ADD COLUMN IF NOT EXISTS updated_at bigint NOT NULL DEFAULT 0",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_server_roles_name_unique ON server_roles(server_id, lower(name))",
        "CREATE INDEX IF NOT EXISTS idx_server_roles_order ON server_roles(server_id, position DESC, id ASC)",
        "CREATE TABLE IF NOT EXISTS server_member_roles(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, role_id bigint NOT NULL REFERENCES server_roles(id) ON DELETE CASCADE, assigned_by integer REFERENCES users(id) ON DELETE SET NULL, assigned_at bigint NOT NULL DEFAULT 0, PRIMARY KEY(server_id,user_id,role_id))",
        "ALTER TABLE server_member_roles ADD COLUMN IF NOT EXISTS assigned_by integer REFERENCES users(id) ON DELETE SET NULL",
        "ALTER TABLE server_member_roles ADD COLUMN IF NOT EXISTS assigned_at bigint NOT NULL DEFAULT 0",
        "CREATE INDEX IF NOT EXISTS idx_server_member_roles_user ON server_member_roles(server_id,user_id,role_id)"
    ]},
    {28, [
        "CREATE TABLE IF NOT EXISTS message_reactions(message_id integer NOT NULL REFERENCES messages(id) ON DELETE CASCADE, "
        "user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, emoji text NOT NULL, created_at bigint NOT NULL, "
        "PRIMARY KEY(message_id,user_id,emoji), CHECK(char_length(emoji) BETWEEN 1 AND 16))",
        "CREATE INDEX IF NOT EXISTS idx_message_reactions_message ON message_reactions(message_id,created_at ASC)",
        "CREATE INDEX IF NOT EXISTS idx_message_reactions_user ON message_reactions(user_id,message_id)"
    ]},
    {29, [
        "CREATE TABLE IF NOT EXISTS admin_operators(user_id integer PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, "
        "role text NOT NULL CHECK(role IN ('owner','operator','viewer')), verification_hash text NOT NULL, "
        "created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE TABLE IF NOT EXISTS admin_sessions(token_hash text PRIMARY KEY, user_id integer NOT NULL REFERENCES admin_operators(user_id) ON DELETE CASCADE, "
        "csrf text NOT NULL, created_at bigint NOT NULL, last_seen bigint NOT NULL, expires_at bigint NOT NULL, "
        "ip_hash text NOT NULL DEFAULT '', user_agent_hash text NOT NULL DEFAULT '')",
        "CREATE INDEX IF NOT EXISTS idx_admin_sessions_user ON admin_sessions(user_id,expires_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_admin_sessions_expiry ON admin_sessions(expires_at)",
        "CREATE TABLE IF NOT EXISTS admin_enrollments(token_hash text PRIMARY KEY, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "role text NOT NULL CHECK(role IN ('owner','operator','viewer')), created_by integer REFERENCES admin_operators(user_id) ON DELETE CASCADE, "
        "note text NOT NULL DEFAULT '', created_at bigint NOT NULL, expires_at bigint NOT NULL, used_at bigint)",
        "CREATE INDEX IF NOT EXISTS idx_admin_enrollments_user ON admin_enrollments(user_id,expires_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_admin_enrollments_creator_unused ON admin_enrollments(created_by) WHERE used_at IS NULL",
        "CREATE TABLE IF NOT EXISTS admin_audit(id bigserial PRIMARY KEY, actor_user_id integer REFERENCES users(id) ON DELETE SET NULL, "
        "action text NOT NULL, target_type text NOT NULL DEFAULT '', target_id text NOT NULL DEFAULT '', detail text NOT NULL DEFAULT '', "
        "ip_hash text NOT NULL DEFAULT '', created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON admin_audit(created_at DESC,id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_messages_created_global ON messages(created_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_messages_user ON messages(user_id,id DESC)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON sessions(expires_at)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_user_expiry ON sessions(user_id,expires_at DESC)",
        "CREATE INDEX IF NOT EXISTS idx_uploads_user_status ON uploads(user_id,status)"
    ]},
    {30, [
        "CREATE TABLE IF NOT EXISTS global_banners(id bigserial PRIMARY KEY, title text NOT NULL DEFAULT '', body text NOT NULL, "
        "severity text NOT NULL CHECK(severity IN ('info','success','warning','critical')), starts_at bigint NOT NULL CHECK(starts_at>=0), "
        "ends_at bigint NOT NULL DEFAULT 0 CHECK(ends_at=0 OR ends_at>starts_at), "
        "dismissible boolean NOT NULL DEFAULT true, link_label text NOT NULL DEFAULT '', link_url text NOT NULL DEFAULT '', enabled boolean NOT NULL DEFAULT true, "
        "created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_global_banners_window ON global_banners(enabled,starts_at,ends_at,id)",
        "CREATE INDEX IF NOT EXISTS idx_global_banners_updated ON global_banners(updated_at DESC,id DESC)",
        "CREATE TABLE IF NOT EXISTS instance_settings(key text PRIMARY KEY, value text NOT NULL, updated_by integer REFERENCES users(id) ON DELETE SET NULL, updated_at bigint NOT NULL)",
        "INSERT INTO instance_settings(key,value,updated_by,updated_at) VALUES('registration_mode','inherit',NULL,0) ON CONFLICT(key) DO NOTHING"
    ]}
    ,{31, [
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS account_state text NOT NULL DEFAULT 'active'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS disabled_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_account_state_check",
        "ALTER TABLE users ADD CONSTRAINT users_account_state_check CHECK(account_state IN ('active','disabled'))",
        "CREATE INDEX IF NOT EXISTS idx_users_account_state ON users(account_state,id)"
    ]}
    ,{32, [
        "CREATE TABLE IF NOT EXISTS server_webhooks(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, name text NOT NULL, url text NOT NULL, secret text NOT NULL, events text NOT NULL, enabled boolean NOT NULL DEFAULT true, created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL, last_success_at bigint NOT NULL DEFAULT 0, last_failure_at bigint NOT NULL DEFAULT 0, failure_count integer NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_server_webhooks_server ON server_webhooks(server_id,id)",
        "CREATE TABLE IF NOT EXISTS webhook_deliveries(id bigserial PRIMARY KEY, webhook_id bigint NOT NULL REFERENCES server_webhooks(id) ON DELETE CASCADE, event text NOT NULL, payload bytea NOT NULL, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','delivered','failed')), attempts integer NOT NULL DEFAULT 0, next_attempt_at bigint NOT NULL, locked_at bigint NOT NULL DEFAULT 0, response_code integer NOT NULL DEFAULT 0, last_error text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_due ON webhook_deliveries(status,next_attempt_at,id)",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_webhook ON webhook_deliveries(webhook_id,id DESC)"
    ]}

    ,{33, [
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS is_bot boolean NOT NULL DEFAULT false",
        "CREATE INDEX IF NOT EXISTS idx_users_is_bot ON users(is_bot,id) WHERE is_bot=true",
        "CREATE TABLE IF NOT EXISTS server_bots(id bigserial PRIMARY KEY, server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, bot_user_id integer NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE, name text NOT NULL, token_hash text NOT NULL UNIQUE, created_by integer REFERENCES users(id) ON DELETE SET NULL, created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_server_bots_server ON server_bots(server_id,id)"
    ]}
    ,{34, [
        %% 1.x default members could already attach files, react, and stream. 2.0
        %% gives those existing behaviors explicit permission bits and enables the
        %% new voice-note bit for untouched default servers. Customized permission
        %% masks are deliberately left alone.
        "ALTER TABLE servers ALTER COLUMN default_permissions SET DEFAULT 59139",
        "UPDATE servers SET default_permissions=59139 WHERE default_permissions=771"
    ]}
    ,{35, [
        %% Message IDs move off PostgreSQL sequences. Widen every reference first,
        %% then the primary key, and recreate the two explicit message FKs.
        "ALTER TABLE message_reactions DROP CONSTRAINT IF EXISTS message_reactions_message_id_fkey",
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_reply_to_id_fkey",
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_forwarded_from_id_fkey",
        "ALTER TABLE message_reactions ALTER COLUMN message_id TYPE bigint USING message_id::bigint",
        "ALTER TABLE direct_members ALTER COLUMN last_read_message_id TYPE bigint USING last_read_message_id::bigint",
        "ALTER TABLE messages ALTER COLUMN reply_to_id TYPE bigint USING reply_to_id::bigint",
        "ALTER TABLE messages ALTER COLUMN forwarded_from_id TYPE bigint USING forwarded_from_id::bigint",
        "ALTER TABLE messages ALTER COLUMN id TYPE bigint USING id::bigint",
        "ALTER TABLE messages ALTER COLUMN id DROP DEFAULT",
        "ALTER TABLE message_reactions ADD CONSTRAINT message_reactions_message_id_fkey FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE",
        "ALTER TABLE messages ADD CONSTRAINT messages_reply_to_id_fkey FOREIGN KEY(reply_to_id) REFERENCES messages(id) ON DELETE SET NULL",
        "ALTER TABLE messages ADD CONSTRAINT messages_forwarded_from_id_fkey FOREIGN KEY(forwarded_from_id) REFERENCES messages(id) ON DELETE SET NULL",
        "CREATE TABLE IF NOT EXISTS message_id_node_leases(node_id smallint PRIMARY KEY CHECK(node_id BETWEEN 0 AND 63), node_name text NOT NULL, lease_until bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_message_id_node_leases_expiry ON message_id_node_leases(lease_until)",
        "CREATE TABLE IF NOT EXISTS storage_outbox(id bigserial PRIMARY KEY, kind text NOT NULL, entity_id bigint NOT NULL DEFAULT 0, payload bytea NOT NULL, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running','delivered','failed')), attempts integer NOT NULL DEFAULT 0, next_attempt_at bigint NOT NULL DEFAULT 0, locked_at bigint NOT NULL DEFAULT 0, last_error text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_storage_outbox_due ON storage_outbox(status,next_attempt_at,id)",
        "CREATE INDEX IF NOT EXISTS idx_storage_outbox_entity ON storage_outbox(kind,entity_id,id DESC)",
        "CREATE TABLE IF NOT EXISTS storage_migration_checkpoints(name text PRIMARY KEY, last_id bigint NOT NULL DEFAULT 0, rows_done bigint NOT NULL DEFAULT 0, updated_at bigint NOT NULL)",
        "INSERT INTO storage_migration_checkpoints(name,last_id,rows_done,updated_at) VALUES('messages',0,0,0) ON CONFLICT(name) DO NOTHING"
    ]}
    ,{36, [
        "CREATE TABLE IF NOT EXISTS server_bans(server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE, user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE, banned_by integer REFERENCES users(id) ON DELETE SET NULL, reason text NOT NULL DEFAULT '', created_at bigint NOT NULL, PRIMARY KEY(server_id,user_id))",
        "CREATE INDEX IF NOT EXISTS idx_server_bans_user ON server_bans(user_id,server_id)",
        "CREATE INDEX IF NOT EXISTS idx_server_bans_server_created ON server_bans(server_id,created_at DESC,user_id)"
    ]}
    ,{37, [
        "CREATE TABLE IF NOT EXISTS upload_delete_queue(path text PRIMARY KEY, status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','running')), attempts integer NOT NULL DEFAULT 0, next_attempt_at bigint NOT NULL DEFAULT 0, locked_at bigint NOT NULL DEFAULT 0, last_error text NOT NULL DEFAULT '', created_at bigint NOT NULL, updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_upload_delete_queue_due ON upload_delete_queue(status,next_attempt_at,created_at,path)"
    ]}
    ,{38, [
        %% Keep user associations outside the JSON blob so privacy erasure can
        %% delete queued webhook payloads without parsing arbitrary payload text.
        "ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS subject_user_id integer",
        "ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS actor_user_id integer",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_subject_user ON webhook_deliveries(subject_user_id,id) WHERE subject_user_id IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_actor_user ON webhook_deliveries(actor_user_id,id) WHERE actor_user_id IS NOT NULL"
    ]}
    ,{39, [
        %% A privacy hard-delete must still identify the physical Scylla
        %% partitions if a prior ambiguous write left a row without a locator.
        %% Store only routing metadata; never duplicate message bodies here.
        "ALTER TABLE storage_outbox ADD COLUMN IF NOT EXISTS entity_scope text NOT NULL DEFAULT ''",
        "ALTER TABLE storage_outbox ADD COLUMN IF NOT EXISTS entity_scope_id bigint NOT NULL DEFAULT 0",
        "ALTER TABLE storage_outbox ADD COLUMN IF NOT EXISTS entity_created_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE storage_outbox DROP CONSTRAINT IF EXISTS storage_outbox_entity_scope_check",
        "ALTER TABLE storage_outbox ADD CONSTRAINT storage_outbox_entity_scope_check CHECK(entity_scope IN ('','channel','direct'))",
        "ALTER TABLE storage_outbox DROP CONSTRAINT IF EXISTS storage_outbox_entity_scope_id_check",
        "ALTER TABLE storage_outbox ADD CONSTRAINT storage_outbox_entity_scope_id_check CHECK(entity_scope_id >= 0)",
        "ALTER TABLE storage_outbox DROP CONSTRAINT IF EXISTS storage_outbox_entity_created_at_check",
        "ALTER TABLE storage_outbox ADD CONSTRAINT storage_outbox_entity_created_at_check CHECK(entity_created_at >= 0)"
    ]}

    ,{40, [
        %% Search never stores plaintext message terms. Tokens are keyed HMACs
        %% derived in Erlang and are useless without the instance search key.
        "CREATE TABLE IF NOT EXISTS message_search_tokens(message_id bigint NOT NULL REFERENCES messages(id) ON DELETE CASCADE, token text NOT NULL, PRIMARY KEY(message_id,token))",
        "CREATE INDEX IF NOT EXISTS idx_message_search_token ON message_search_tokens(token,message_id DESC)",
        "CREATE TABLE IF NOT EXISTS message_search_state(id smallint PRIMARY KEY CHECK(id=1), key_fingerprint text NOT NULL DEFAULT '', last_message_id bigint NOT NULL DEFAULT 0, complete boolean NOT NULL DEFAULT false, updated_at bigint NOT NULL DEFAULT 0)",
        "INSERT INTO message_search_state(id,key_fingerprint,last_message_id,complete,updated_at) VALUES(1,'',0,false,0) ON CONFLICT(id) DO NOTHING"
    ]}
    ,{41, [
        %% Bot commands are a durable, language-neutral queue. Command arguments
        %% are encrypted before storage; claim tokens are stored only as hashes.
        "CREATE TABLE IF NOT EXISTS bot_commands(id bigserial PRIMARY KEY,bot_id bigint NOT NULL REFERENCES server_bots(id) ON DELETE CASCADE,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,name text NOT NULL,description text NOT NULL DEFAULT '',options_json text NOT NULL DEFAULT '[]',enabled boolean NOT NULL DEFAULT true,created_at bigint NOT NULL,updated_at bigint NOT NULL,UNIQUE(server_id,name))",
        "CREATE INDEX IF NOT EXISTS idx_bot_commands_bot ON bot_commands(bot_id,id)",
        "CREATE TABLE IF NOT EXISTS bot_command_invocations(id bigserial PRIMARY KEY,command_id bigint NOT NULL REFERENCES bot_commands(id) ON DELETE CASCADE,bot_id bigint NOT NULL REFERENCES server_bots(id) ON DELETE CASCADE,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,channel_id integer NOT NULL REFERENCES channels(id) ON DELETE CASCADE,user_id integer REFERENCES users(id) ON DELETE SET NULL,request_message_id bigint REFERENCES messages(id) ON DELETE SET NULL,args_cipher text NOT NULL,status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','claimed','completed','failed')),claim_token_hash text NOT NULL DEFAULT '',lease_until bigint NOT NULL DEFAULT 0,attempts integer NOT NULL DEFAULT 0,response_message_id bigint,fail_reason text NOT NULL DEFAULT '',created_at bigint NOT NULL,updated_at bigint NOT NULL,completed_at bigint NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_bot_command_invocations_claim ON bot_command_invocations(bot_id,status,lease_until,id)",
        "CREATE INDEX IF NOT EXISTS idx_bot_command_invocations_user ON bot_command_invocations(user_id,id DESC) WHERE user_id IS NOT NULL"
    ]}
    ,{42, [
        %% Host moderation changes account access only. It never grants the
        %% control plane access to messages or private attachment contents.
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_title text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_reason text NOT NULL DEFAULT ''",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_severity text NOT NULL DEFAULT 'warning'",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderation_expires_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderated_by integer REFERENCES users(id) ON DELETE SET NULL",
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS moderated_at bigint NOT NULL DEFAULT 0",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_account_state_check",
        "ALTER TABLE users ADD CONSTRAINT users_account_state_check CHECK(account_state IN ('active','disabled','suspended','banned'))",
        "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_moderation_severity_check",
        "ALTER TABLE users ADD CONSTRAINT users_moderation_severity_check CHECK(moderation_severity IN ('info','warning','critical'))",
        "CREATE TABLE IF NOT EXISTS instance_account_actions(id bigserial PRIMARY KEY,user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,actor_user_id integer REFERENCES users(id) ON DELETE SET NULL,action text NOT NULL CHECK(action IN ('suspend','ban','restore')),title text NOT NULL DEFAULT '',reason text NOT NULL DEFAULT '',severity text NOT NULL DEFAULT 'warning',expires_at bigint NOT NULL DEFAULT 0,created_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_instance_account_actions_user ON instance_account_actions(user_id,id DESC)"
    ]}
    ,{43, [
        %% Channel pins are deliberately separate from message rows so pin
        %% history can be changed without rewriting encrypted message bodies.
        "CREATE TABLE IF NOT EXISTS message_pins(channel_id integer NOT NULL REFERENCES channels(id) ON DELETE CASCADE,message_id bigint PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,pinned_by integer REFERENCES users(id) ON DELETE SET NULL,pinned_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_message_pins_channel ON message_pins(channel_id,pinned_at DESC,message_id DESC)"
    ]}
    ,{44, [
        %% Slowmode is channel configuration. Enforcement is serialized per
        %% user/channel at send time so concurrent API nodes cannot bypass it.
        "ALTER TABLE channels ADD COLUMN IF NOT EXISTS slowmode_seconds integer NOT NULL DEFAULT 0",
        "ALTER TABLE channels DROP CONSTRAINT IF EXISTS channels_slowmode_seconds_check",
        "ALTER TABLE channels ADD CONSTRAINT channels_slowmode_seconds_check CHECK(slowmode_seconds BETWEEN 0 AND 21600)"
    ]}
    ,{45, [
        %% Incoming channel webhooks have dedicated bot identities. Tokens are
        %% stored only as hashes; deleting a webhook disables its identity while
        %% preserving authorship of historical messages.
        "CREATE TABLE IF NOT EXISTS incoming_webhooks(id bigserial PRIMARY KEY,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,channel_id integer NOT NULL REFERENCES channels(id) ON DELETE CASCADE,bot_user_id integer NOT NULL UNIQUE REFERENCES users(id),name text NOT NULL,token_hash text NOT NULL UNIQUE,enabled boolean NOT NULL DEFAULT true,created_by integer REFERENCES users(id) ON DELETE SET NULL,created_at bigint NOT NULL,updated_at bigint NOT NULL,last_used_at bigint NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_incoming_webhooks_server ON incoming_webhooks(server_id,id)",
        "CREATE INDEX IF NOT EXISTS idx_incoming_webhooks_channel ON incoming_webhooks(channel_id,id)"
    ]}
    ,{46, [
        %% User-owned developer applications are templates above server-scoped
        %% bot installations. Existing server_bots remain fully compatible.
        "CREATE TABLE IF NOT EXISTS developer_applications(id bigserial PRIMARY KEY,owner_user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,public_id text NOT NULL UNIQUE,name text NOT NULL,description text NOT NULL DEFAULT '',avatar_url text NOT NULL DEFAULT '',public boolean NOT NULL DEFAULT false,default_permissions bigint NOT NULL DEFAULT 0,interaction_url text NOT NULL DEFAULT '',interaction_secret text NOT NULL DEFAULT '',ai_enabled boolean NOT NULL DEFAULT false,ai_endpoint text NOT NULL DEFAULT '',ai_model text NOT NULL DEFAULT '',ai_api_key text NOT NULL DEFAULT '',ai_system_prompt text NOT NULL DEFAULT '',created_at bigint NOT NULL,updated_at bigint NOT NULL)",
        "CREATE INDEX IF NOT EXISTS idx_developer_applications_owner ON developer_applications(owner_user_id,id DESC)",
        "CREATE TABLE IF NOT EXISTS developer_app_installations(id bigserial PRIMARY KEY,app_id bigint NOT NULL REFERENCES developer_applications(id) ON DELETE CASCADE,server_id integer NOT NULL REFERENCES servers(id) ON DELETE CASCADE,server_bot_id bigint NOT NULL UNIQUE REFERENCES server_bots(id) ON DELETE CASCADE,role_id bigint REFERENCES server_roles(id) ON DELETE SET NULL,installed_by integer REFERENCES users(id) ON DELETE SET NULL,created_at bigint NOT NULL,UNIQUE(app_id,server_id))",
        "CREATE INDEX IF NOT EXISTS idx_developer_app_installations_app ON developer_app_installations(app_id,id)",
        "CREATE INDEX IF NOT EXISTS idx_developer_app_installations_server ON developer_app_installations(server_id,id)",
        "CREATE TABLE IF NOT EXISTS developer_app_commands(id bigserial PRIMARY KEY,app_id bigint NOT NULL REFERENCES developer_applications(id) ON DELETE CASCADE,name text NOT NULL,description text NOT NULL DEFAULT '',options_json text NOT NULL DEFAULT '[]',handler text NOT NULL DEFAULT 'queue' CHECK(handler IN ('queue','webhook','ai')),created_at bigint NOT NULL,updated_at bigint NOT NULL,UNIQUE(app_id,name))",
        "CREATE INDEX IF NOT EXISTS idx_developer_app_commands_app ON developer_app_commands(app_id,id)",
        "ALTER TABLE bot_commands ADD COLUMN IF NOT EXISTS developer_command_id bigint REFERENCES developer_app_commands(id) ON DELETE CASCADE",
        "ALTER TABLE bot_commands ADD COLUMN IF NOT EXISTS handler text NOT NULL DEFAULT 'queue'",
        "ALTER TABLE bot_commands DROP CONSTRAINT IF EXISTS bot_commands_handler_check",
        "ALTER TABLE bot_commands ADD CONSTRAINT bot_commands_handler_check CHECK(handler IN ('queue','webhook','ai'))",
        "CREATE INDEX IF NOT EXISTS idx_bot_commands_handler ON bot_commands(handler,bot_id,id)",
        "CREATE INDEX IF NOT EXISTS idx_bot_commands_developer_command ON bot_commands(developer_command_id) WHERE developer_command_id IS NOT NULL"
    ]}
    ,{47, [
        %% Server managers can narrow app-command usage by channel, role or
        %% member. Rules are evaluated at discovery and invocation time.
        "CREATE TABLE IF NOT EXISTS bot_command_permissions(command_id bigint NOT NULL REFERENCES bot_commands(id) ON DELETE CASCADE,subject_type text NOT NULL CHECK(subject_type IN ('channel','role','user')),subject_id bigint NOT NULL,allow boolean NOT NULL,created_at bigint NOT NULL,updated_at bigint NOT NULL,PRIMARY KEY(command_id,subject_type,subject_id))",
        "CREATE INDEX IF NOT EXISTS idx_bot_command_permissions_command ON bot_command_permissions(command_id,subject_type,subject_id)"
    ]}
    ,{48, [
        %% Internal webhook/AI workers claim across all installed bots. Keep the
        %% hot queue tiny even when completed invocation history becomes large;
        %% completed/failed rows deliberately do not occupy this partial index.
        "CREATE INDEX IF NOT EXISTS idx_bot_command_invocations_active ON bot_command_invocations(id,lease_until) WHERE status IN ('pending','claimed')"
    ]}
    ,{49, [
        %% Slowmode is evaluated on every channel message send. This partial
        %% index serves the exact channel+author live-message lookup without
        %% adding write amplification to deleted/direct/profile message rows.
        "CREATE INDEX IF NOT EXISTS idx_messages_channel_author_recent ON messages(scope_id,user_id,created_at DESC) WHERE scope='channel' AND deleted_at IS NULL"
    ]}
    ,{50, [
        "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check",
        "ALTER TABLE messages ADD CONSTRAINT messages_kind_check CHECK(kind IN ('text','missed_call','call_ended'))"
    ]}
].



developer_app_select() ->
    "SELECT a.id,a.owner_user_id,a.public_id,a.name,a.description,a.avatar_url,a.public,a.default_permissions,"
    "a.interaction_url,a.interaction_secret,a.ai_enabled,a.ai_endpoint,a.ai_model,a.ai_api_key,a.ai_system_prompt,a.created_at,a.updated_at FROM developer_applications a".

developer_app_owned_row(Conn, Uid, AppId, Lock) when is_integer(AppId), AppId > 0 ->
    Suffix = case Lock of true -> " FOR UPDATE OF a"; false -> "" end,
    one(Conn, developer_app_select() ++ " WHERE a.id=$1 AND a.owner_user_id=$2" ++ Suffix, [AppId, Uid]);
developer_app_owned_row(_Conn, _Uid, _AppId, _Lock) -> {error, not_found}.

developer_app_map([Id, Owner, PublicId, Name, Description, Avatar, Public, DefaultPermissions,
                   InteractionUrl, InteractionSecret, AiEnabled, AiEndpoint, AiModel, AiApiKey, AiSystemPrompt,
                   CreatedAt, UpdatedAt]) ->
    #{id => Id, owner_user_id => Owner, public_id => PublicId, name => Name, description => Description,
      avatar_source => pw_util:bin(Avatar), avatar_url => pw_util:proxied_image(Avatar), public => Public =:= true,
      default_permissions => pw_permissions:sanitize(DefaultPermissions),
      interaction => #{url => pw_util:bin(InteractionUrl), configured => pw_util:bin(InteractionUrl) =/= <<>> andalso pw_util:bin(InteractionSecret) =/= <<>>},
      ai => #{enabled => AiEnabled =:= true, endpoint => pw_util:bin(AiEndpoint), model => pw_util:bin(AiModel),
              has_api_key => pw_util:bin(AiApiKey) =/= <<>>, system_prompt => load_message(AiSystemPrompt),
              configured => AiEnabled =:= true andalso pw_util:bin(AiEndpoint) =/= <<>> andalso pw_util:bin(AiModel) =/= <<>> andalso pw_util:bin(AiApiKey) =/= <<>>},
      created_at => CreatedAt, updated_at => UpdatedAt}.

developer_installation_map([Id, Sid, ServerName, BotId, BotUid, Username, Display, Avatar, RoleId, InstalledBy, CreatedAt]) ->
    #{id => Id, server_id => Sid, server_name => ServerName, bot_id => BotId, bot_user_id => BotUid,
      username => Username, display_name => Display, avatar_url => pw_util:proxied_image(Avatar), role_id => int_or(pw_util:int(RoleId), 0),
      installed_by => db_null(InstalledBy), created_at => CreatedAt}.

server_app_map([InstallId, AppId, PublicId, Name, Description, Avatar, BotId, BotUid, Username, Display, RoleId, InstalledBy, CreatedAt]) ->
    #{installation_id => InstallId, app_id => AppId, public_id => PublicId, name => Name, description => Description,
      avatar_url => pw_util:proxied_image(Avatar), bot_id => BotId, bot_user_id => BotUid, username => Username,
      display_name => Display, role_id => int_or(pw_util:int(RoleId), 0), installed_by => db_null(InstalledBy), created_at => CreatedAt}.

developer_command_map([Id, Name, Description, OptionsJson, Handler, CreatedAt, UpdatedAt]) ->
    #{id => Id, name => Name, description => Description, options => decode_json_value(OptionsJson, []), handler => Handler,
      created_at => CreatedAt, updated_at => UpdatedAt}.

developer_public_command_map([Name, Description, OptionsJson, Handler]) ->
    #{name => Name, description => Description, options => decode_json_value(OptionsJson, []), handler => Handler}.

normalize_developer_handler(Value0) ->
    case string:lowercase(pw_util:bin(Value0)) of
        <<"queue">> -> <<"queue">>;
        <<"webhook">> -> <<"webhook">>;
        <<"ai">> -> <<"ai">>;
        _ -> invalid
    end.

developer_handler_available(_App, <<"queue">>) -> true;
developer_handler_available(App, <<"webhook">>) -> maps:get(configured, maps:get(interaction, App), false);
developer_handler_available(App, <<"ai">>) -> maps:get(configured, maps:get(ai, App), false);
developer_handler_available(_, _) -> false.

developer_endpoint_valid(<<>>) -> true;
developer_endpoint_valid(Url) when is_binary(Url) ->
    case pw_outbound_url:resolve_allowed(Url) of {ok, _} -> true; _ -> false end;
developer_endpoint_valid(_) -> false.

unique_developer_public_id(Conn) ->
    Candidate = <<"app_", (pw_util:random_token(18))/binary>>,
    case one(Conn, "SELECT id FROM developer_applications WHERE public_id=$1", [Candidate]) of
        {ok, [_]} -> unique_developer_public_id(Conn);
        _ -> Candidate
    end.

developer_app_avatar(Conn, Uid, Value0) ->
    Value = pw_util:clean_text(Value0, 17825792),
    case Value of
        <<>> -> <<>>;
        <<"/api/files/", Id/binary>> ->
            case profile_upload_allowed(Conn, Uid, Id) of true -> Value; false -> <<>> end;
        _ -> store_image_url(Value)
    end.

install_developer_app_internal(Conn, Uid, App, Sid) when is_integer(Sid), Sid > 0 ->
    
AppId = maps:get(id, App),
    case has_server_permission(Conn, Uid, Sid, <<"manage_bots">>) of
        false -> {error, forbidden};
        true ->
            _ = one(Conn, "SELECT id FROM servers WHERE id=$1 FOR UPDATE", [Sid]),
            case one(Conn, "SELECT id FROM developer_app_installations WHERE app_id=$1 AND server_id=$2", [AppId, Sid]) of
                {ok, [_]} -> {error, already_installed};
                _ ->
                    {ok, [Count]} = one(Conn, "SELECT count(*) FROM server_bots WHERE server_id=$1", [Sid]),
                    case Count >= 50 of
                        true -> {error, bot_limit};
                        false ->
                            case one(Conn,
                                "SELECT c.name FROM developer_app_commands dc JOIN bot_commands c ON c.server_id=$2 AND c.name=dc.name WHERE dc.app_id=$1 LIMIT 1",
                                [AppId, Sid]) of
                                {ok, [Conflict]} -> {error, {command_name_conflict, Conflict}};
                                _ -> create_developer_installation_rows(Conn, Uid, App, Sid)
                            end
                    end
            end
    end;
install_developer_app_internal(_Conn, _Uid, _App, _Sid) -> {error, invalid_server}.

create_developer_installation_rows(Conn, Uid, App, Sid) ->
    

AppId = maps:get(id, App), Name = maps:get(name, App), Description = maps:get(description, App, <<>>),
    Avatar = maps:get(avatar_source, App, <<>>), Now = pw_util:now_ms(),
    Token = <<"pwb_", (pw_util:random_token(36))/binary>>, TokenHash = pw_util:sha256_hex(Token),
    Salt = pw_util:random_token(18), PasswordHash = pw_util:pbkdf2(pw_util:random_token(32), Salt),
    Username = unique_bot_username(Conn, Sid, Name),
    {ok, BotUid} = insert_returning(Conn,
        "INSERT INTO users(username,display_name,password_hash,password_salt,bio,avatar_url,banner_url,status,theme,created_at,updated_at,last_seen,account_state,disabled_at,is_bot) "
        "VALUES($1,$2,$3,$4,$5,$6,'','','system',$7,$7,$7,'active',0,true) RETURNING id",
        [Username, Name, PasswordHash, Salt, Description, Avatar, Now]),
    ok = exec(Conn, "INSERT INTO server_members(server_id,user_id,role,joined_at) VALUES($1,$2,'member',$3)", [Sid, BotUid, Now]),
    Requested = pw_permissions:sanitize(maps:get(default_permissions, App, 0)),
    Permissions = grantable_role_permissions(Conn, Uid, Sid, Requested),
    RoleId = case Permissions of
        0 -> 0;
        _ ->
            {ok, Rid} = insert_returning(Conn,
                "INSERT INTO server_roles(server_id,name,color,permissions,position,hoist,mentionable,created_at,updated_at) VALUES($1,$2,'',$3,0,false,false,$4,$4) RETURNING id",
                [Sid, Name, Permissions, Now]),
            ok = exec(Conn, "INSERT INTO server_member_roles(server_id,user_id,role_id) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [Sid, BotUid, Rid]),
            Rid
    end,
    {ok, BotId} = insert_returning(Conn,
        "INSERT INTO server_bots(server_id,bot_user_id,name,token_hash,created_by,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$6) RETURNING id",
        [Sid, BotUid, Name, TokenHash, Uid, Now]),
    RoleDb = case RoleId of 0 -> null; _ -> RoleId end,
    {ok, InstallId} = insert_returning(Conn,
        "INSERT INTO developer_app_installations(app_id,server_id,server_bot_id,role_id,installed_by,created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
        [AppId, Sid, BotId, RoleDb, Uid, Now]),
    ok = sync_developer_commands_to_installation(Conn, AppId, BotId, Sid, Now),
    ok = sync_profile_upload_refs(Conn, BotUid, Avatar, <<>>, Now),
    publish_server_event(Conn, Sid, #{type => bot_added, server_id => Sid, bot_user_id => BotUid, application_id => AppId}),
    enqueue_server_webhooks(Conn, Sid, <<"bot.added">>, #{bot_user_id => BotUid, bot_id => BotId, application_id => AppId, actor_id => Uid}),
    {ok, #{installation_id => InstallId, app_id => AppId, server_id => Sid, bot_id => BotId, bot_user_id => BotUid,
           username => Username, token => Token, permissions => Permissions, role_id => RoleId, created_at => Now}}.

sync_developer_commands_to_installation(Conn, AppId, BotId, Sid, Now) ->
    {ok, Commands} = rows(Conn,
        "SELECT id,name,description,options_json,handler FROM developer_app_commands WHERE app_id=$1 ORDER BY id ASC", [AppId]),
    lists:foreach(fun([DevCmdId, Name, Description, OptionsJson, Handler]) ->
        case one(Conn,
            "INSERT INTO bot_commands(bot_id,server_id,name,description,options_json,enabled,developer_command_id,handler,created_at,updated_at) "
            "VALUES($1,$2,$3,$4,$5,true,$6,$7,$8,$8) ON CONFLICT(server_id,name) DO UPDATE SET description=EXCLUDED.description,options_json=EXCLUDED.options_json,enabled=true,developer_command_id=EXCLUDED.developer_command_id,handler=EXCLUDED.handler,updated_at=EXCLUDED.updated_at WHERE bot_commands.bot_id=EXCLUDED.bot_id RETURNING id",
            [BotId, Sid, Name, Description, OptionsJson, DevCmdId, Handler, Now]) of
            {ok, [_]} -> ok;
            _ -> throw({plainwire_error, command_name_taken})
        end
    end, Commands),
    ok.

uninstall_developer_app_internal(Conn, AppId, InstallId, Sid, BotId, RoleId, ActorUid) ->
    case one(Conn,
        "SELECT b.bot_user_id FROM developer_app_installations di JOIN server_bots b ON b.id=di.server_bot_id WHERE di.id=$1 AND di.app_id=$2 AND di.server_id=$3 AND di.server_bot_id=$4 FOR UPDATE OF di,b",
        [InstallId, AppId, Sid, BotId]) of
        {ok, [BotUid]} ->
            Now = pw_util:now_ms(),
            ok = exec(Conn, "DELETE FROM server_member_roles WHERE server_id=$1 AND user_id=$2", [Sid, BotUid]),
            ok = exec(Conn, "DELETE FROM server_members WHERE server_id=$1 AND user_id=$2", [Sid, BotUid]),
            ok = exec(Conn, "DELETE FROM server_bots WHERE id=$1 AND server_id=$2", [BotId, Sid]),
            case pw_util:int(RoleId) of
                Rid when is_integer(Rid), Rid > 0 -> ok = exec(Conn, "DELETE FROM server_roles WHERE id=$1 AND server_id=$2", [Rid, Sid]);
                _ -> ok
            end,
            %% Preserve historical authorship while making the detached bot identity
            %% permanently non-authenticating and undiscoverable as an active account.
            ok = exec(Conn, "UPDATE users SET account_state='disabled',disabled_at=$1,updated_at=$1 WHERE id=$2 AND is_bot=true", [Now, BotUid]),
            publish_server_event(Conn, Sid, #{type => bot_removed, server_id => Sid, bot_user_id => BotUid, application_id => AppId}),
            enqueue_server_webhooks(Conn, Sid, <<"bot.removed">>, #{bot_user_id => BotUid, bot_id => BotId, application_id => AppId, actor_id => ActorUid}),
            ok;
        _ -> throw({plainwire_error, not_found})
    end.


internal_app_claim_route(Conn, Handler, Limit0) ->
    Limit = clamp_int(Limit0, 1, 32, 8),
    Now = pw_util:now_ms(),
    LeaseMs = clamp_int(pw_util:env_int("PLAINWIRE_APP_COMMAND_LEASE_MS", 45000), 10000, 120000, 45000),
    MaxAttempts = clamp_int(pw_util:env_int("PLAINWIRE_APP_COMMAND_MAX_ATTEMPTS", 6), 1, 20, 6),
    Result = with_tx(Conn, fun() ->
        %% Internal workers use lease_until as both the in-flight lease and the
        %% retry clock. Exhausted jobs are terminal so a bad endpoint cannot
        %% permanently occupy the head of the queue.
        ok = exec(Conn,
            "UPDATE bot_command_invocations i SET status='failed',fail_reason='delivery attempts exhausted',claim_token_hash='',lease_until=0,completed_at=$1,updated_at=$1 "
            "FROM bot_commands c WHERE c.id=i.command_id AND c.handler=$2 AND i.status='claimed' AND i.lease_until<$1 AND i.attempts >= $3",
            [Now, Handler, MaxAttempts]),
        {ok, Rows0} = rows(Conn,
            "SELECT i.id,c.name,c.id,i.server_id,i.channel_id,i.user_id,i.request_message_id,i.args_cipher,i.attempts,i.created_at,"
            "b.bot_user_id,a.id,a.public_id,a.name,a.interaction_url,a.interaction_secret,a.ai_enabled,a.ai_endpoint,a.ai_model,a.ai_api_key,a.ai_system_prompt "
            "FROM bot_command_invocations i JOIN bot_commands c ON c.id=i.command_id "
            "JOIN server_bots b ON b.id=i.bot_id JOIN users bu ON bu.id=b.bot_user_id "
            "JOIN developer_app_installations di ON di.server_bot_id=b.id "
            "JOIN developer_applications a ON a.id=di.app_id "
            "WHERE c.handler=$1 AND bu.account_state='active' AND (i.status='pending' OR (i.status='claimed' AND i.lease_until<$2)) "
            "ORDER BY i.id ASC LIMIT $3 FOR UPDATE OF i SKIP LOCKED",
            [Handler, Now, Limit]),
        {Jobs, Failed} = claim_internal_app_rows(Conn, Handler, Rows0, Now, LeaseMs, [], []),
        {ok, #{jobs => lists:reverse(Jobs), failed => lists:reverse(Failed)}}
    end),
    case Result of
        {ok, #{jobs := Jobs, failed := Failed}} ->
            [pw_hub:notify_user(UserId, #{type => bot_command_failed, invocation_id => InvocationId,
                channel_id => ChannelId, reason => Reason})
             || #{user_id := UserId, id := InvocationId, channel_id := ChannelId, reason := Reason} <- Failed,
                is_integer(UserId)],
            {ok, Jobs};
        Other -> Other
    end.

claim_internal_app_rows(_Conn, _Handler, [], _Now, _LeaseMs, Jobs, Failed) -> {Jobs, Failed};
claim_internal_app_rows(Conn, Handler,
        [[Id, Command, CommandId, Sid, Cid, UserId, RequestMid, ArgsCipher, Attempts0, CreatedAt,
          BotUid, AppId, PublicId, AppName, InteractionUrl, InteractionSecret,
          AiEnabled, AiEndpoint, AiModel, AiApiKey, AiSystemPrompt] | Rest],
        Now, LeaseMs, Jobs, Failed) ->
    Available = case Handler of
        <<"webhook">> -> pw_util:bin(InteractionUrl) =/= <<>> andalso pw_util:bin(InteractionSecret) =/= <<>>;
        <<"ai">> -> AiEnabled =:= true andalso pw_util:bin(AiEndpoint) =/= <<>> andalso
                    pw_util:bin(AiModel) =/= <<>> andalso pw_util:bin(AiApiKey) =/= <<>>;
        _ -> false
    end,
    Authorization = case Available of
        true -> command_claim_authorization(Conn, UserId, Sid, Cid, CommandId, BotUid);
        false -> {error, <<"Command handler is no longer configured">>}
    end,
    case Authorization of
        ok ->
            Attempts = int_or(pw_util:int(Attempts0), 0) + 1,
            ok = exec(Conn,
                "UPDATE bot_command_invocations SET status='claimed',claim_token_hash='',lease_until=$1,attempts=$2,updated_at=$3 WHERE id=$4",
                [Now + LeaseMs, Attempts, Now, Id]),
            Base = #{id => Id, command => Command, server_id => Sid, channel_id => Cid,
                     user_id => db_null(UserId), request_message_id => db_null(RequestMid),
                     args => decode_command_args(ArgsCipher), attempts => Attempts, created_at => CreatedAt,
                     bot_user_id => BotUid, app_id => AppId, app_public_id => PublicId, app_name => AppName},
            Job = case Handler of
                <<"webhook">> -> Base#{url => pw_util:bin(InteractionUrl), secret => pw_crypto:decrypt(pw_util:bin(InteractionSecret))};
                <<"ai">> -> Base#{endpoint => pw_util:bin(AiEndpoint), model => pw_util:bin(AiModel),
                    api_key => pw_crypto:decrypt(pw_util:bin(AiApiKey)), system_prompt => pw_crypto:decrypt(pw_util:bin(AiSystemPrompt))}
            end,
            claim_internal_app_rows(Conn, Handler, Rest, Now, LeaseMs, [Job | Jobs], Failed);
        {error, Reason} ->
            ok = exec(Conn,
                "UPDATE bot_command_invocations SET status='failed',fail_reason=$1,claim_token_hash='',lease_until=0,completed_at=$2,updated_at=$2 WHERE id=$3",
                [Reason, Now, Id]),
            Failure = #{id => Id, user_id => db_null(UserId), channel_id => Cid, reason => Reason},
            claim_internal_app_rows(Conn, Handler, Rest, Now, LeaseMs, Jobs, [Failure | Failed])
    end.

internal_app_finish_route(Conn, Handler, InvocationId0, Result0) ->
    InvocationId = pw_util:int(InvocationId0),
    Now = pw_util:now_ms(),
    MaxAttempts = clamp_int(pw_util:env_int("PLAINWIRE_APP_COMMAND_MAX_ATTEMPTS", 6), 1, 20, 6),
    Result = with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT i.channel_id,i.request_message_id,b.bot_user_id,i.status,i.lease_until,i.attempts,i.user_id,i.response_message_id "
            "FROM bot_command_invocations i JOIN bot_commands c ON c.id=i.command_id JOIN server_bots b ON b.id=i.bot_id "
            "WHERE i.id=$1 AND c.handler=$2 FOR UPDATE OF i", [InvocationId, Handler]) of
            {ok, [_Cid, _RequestMid, _BotUid, <<"completed">>, _Lease, _Attempts, _UserId, ExistingMid]} ->
                {ok, #{completed => true, message_id => db_null(ExistingMid), duplicate => true}};
            {ok, [Cid, RequestMid, BotUid, <<"claimed">>, LeaseUntil, Attempts0, UserId, _]} when LeaseUntil >= Now ->
                Attempts = int_or(pw_util:int(Attempts0), 0),
                finish_internal_app_claim(Conn, InvocationId, Cid, RequestMid, BotUid, UserId, Attempts, MaxAttempts, Result0, Now);
            {ok, [_Cid, _RequestMid, _BotUid, <<"claimed">>, _Lease, _Attempts, _UserId, _]} -> {error, claim_expired};
            {ok, [_Cid, _RequestMid, _BotUid, <<"failed">>, _Lease, _Attempts, _UserId, _]} -> {ok, #{failed => true, duplicate => true}};
            _ -> {error, not_found}
        end
    end),
    case Result of
        {ok, #{message := Msg, channel_id := Cid, server_id := Sid} = Data} ->
            invalidate_message_cache(<<"channel">>, Cid),
            pw_hub:broadcast({channel, Cid}, #{type => message_created, scope => channel, scope_id => Cid, message => Msg}),
            best_effort_channel_notifications(Conn, Sid, maps:get(user_id, Msg), Cid, Msg, pw_util:now_ms(), false),
            {ok, maps:without([message, channel_id, server_id, user_id], Data)};
        {ok, #{terminal_failed := true, user_id := UserId, channel_id := Cid} = Data} ->
            case is_integer(UserId) of true -> pw_hub:notify_user(UserId, #{type => bot_command_failed, invocation_id => InvocationId, channel_id => Cid, reason => maps:get(reason, Data, <<"Command failed">>)}); false -> ok end,
            {ok, maps:without([terminal_failed, user_id, channel_id], Data)};
        Other -> Other
    end.

finish_internal_app_claim(Conn, InvocationId, Cid, RequestMid, BotUid, UserId, _Attempts, _MaxAttempts, {ok, Body0}, Now) ->
    Body = pw_util:clean_text(Body0, ?MAX_MSG),
    case Body of
        <<>> ->
            ok = exec(Conn, "UPDATE bot_command_invocations SET status='completed',claim_token_hash='',lease_until=0,completed_at=$1,updated_at=$1 WHERE id=$2", [Now, InvocationId]),
            {ok, #{completed => true, message_id => null}};
        _ ->
            case {message_body_valid(Body), channel_message_access(Conn, BotUid, Cid)} of
                {true, {ok, Sid}} ->
                    Mid = new_message_id(),
                    ok = exec(Conn,
                        "INSERT INTO messages(id,scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,'channel',$2,$3,$4,$5,$6)",
                        [Mid, Cid, BotUid, store_message(Body), RequestMid, Now]),
                    ok = storage_after_message_change(Conn, Mid, <<"message.created">>, BotUid),
                    ok = exec(Conn,
                        "UPDATE bot_command_invocations SET status='completed',response_message_id=$1,claim_token_hash='',lease_until=0,completed_at=$2,updated_at=$2 WHERE id=$3",
                        [Mid, Now, InvocationId]),
                    {ok, Row} = one(Conn, message_select() ++ " WHERE m.id=$1", [Mid]),
                    {ok, #{completed => true, message_id => Mid, message => message_map(Conn, Row), channel_id => Cid, server_id => Sid}};
                _ ->
                    Reason = <<"Bot no longer has access to this channel">>,
                    ok = exec(Conn, "UPDATE bot_command_invocations SET status='failed',fail_reason=$1,claim_token_hash='',lease_until=0,completed_at=$2,updated_at=$2 WHERE id=$3", [Reason, Now, InvocationId]),
                    {ok, #{failed => true, terminal_failed => true, reason => Reason, user_id => db_null(UserId), channel_id => Cid}}
            end
    end;
finish_internal_app_claim(Conn, InvocationId, Cid, _RequestMid, _BotUid, UserId, Attempts, MaxAttempts, {error, Reason0}, Now) ->
    Reason = pw_util:clean_text(Reason0, 500),
    case Attempts >= MaxAttempts of
        true ->
            ok = exec(Conn, "UPDATE bot_command_invocations SET status='failed',fail_reason=$1,claim_token_hash='',lease_until=0,completed_at=$2,updated_at=$2 WHERE id=$3", [Reason, Now, InvocationId]),
            {ok, #{failed => true, terminal_failed => true, reason => Reason, user_id => db_null(UserId), channel_id => Cid}};
        false ->
            Delay = internal_app_retry_delay_ms(Attempts),
            ok = exec(Conn, "UPDATE bot_command_invocations SET status='claimed',fail_reason=$1,claim_token_hash='',lease_until=$2,updated_at=$3 WHERE id=$4", [Reason, Now + Delay, Now, InvocationId]),
            {ok, #{retrying => true, retry_in_ms => Delay, attempts => Attempts}}
    end;
finish_internal_app_claim(Conn, InvocationId, Cid, RequestMid, BotUid, UserId, Attempts, MaxAttempts, Other, Now) ->
    finish_internal_app_claim(Conn, InvocationId, Cid, RequestMid, BotUid, UserId, Attempts, MaxAttempts,
        {error, pw_util:clean_text(io_lib:format("invalid dispatcher result: ~p", [Other]), 500)}, Now).

internal_app_retry_delay_ms(Attempts0) ->
    Attempts = max(1, min(10, int_or(pw_util:int(Attempts0), 1))),
    min(60000, 1000 bsl min(6, Attempts - 1)).

bot_command_handler_available(_Conn, _BotId, <<"queue">>) -> true;
bot_command_handler_available(Conn, BotId, <<"webhook">>) ->
    case one(Conn,
        "SELECT a.interaction_url,a.interaction_secret FROM developer_app_installations di "
        "JOIN developer_applications a ON a.id=di.app_id WHERE di.server_bot_id=$1", [BotId]) of
        {ok, [Url, Secret]} -> pw_util:bin(Url) =/= <<>> andalso pw_util:bin(Secret) =/= <<>>;
        _ -> false
    end;
bot_command_handler_available(Conn, BotId, <<"ai">>) ->
    case one(Conn,
        "SELECT a.ai_enabled,a.ai_endpoint,a.ai_model,a.ai_api_key FROM developer_app_installations di "
        "JOIN developer_applications a ON a.id=di.app_id WHERE di.server_bot_id=$1", [BotId]) of
        {ok, [true, Endpoint, Model, ApiKey]} -> pw_util:bin(Endpoint) =/= <<>> andalso pw_util:bin(Model) =/= <<>> andalso pw_util:bin(ApiKey) =/= <<>>;
        _ -> false
    end;
bot_command_handler_available(_Conn, _BotId, _) -> false.

server_app_command_map([Id, Name, Description, OptionsJson, Enabled, CreatedAt, UpdatedAt, Handler], Rules) ->
    #{id => Id, name => Name, description => Description,
      options => decode_json_value(OptionsJson, []), enabled => Enabled, handler => Handler,
      permissions => Rules, created_at => CreatedAt, updated_at => UpdatedAt}.

bot_command_permission_rules(Conn, CommandId) ->
    case rows(Conn,
        "SELECT subject_type,subject_id,allow FROM bot_command_permissions WHERE command_id=$1 ORDER BY subject_type ASC,subject_id ASC",
        [CommandId]) of
        {ok, RuleRows} -> [#{type => Type, id => SubjectId, allow => Allow} || [Type, SubjectId, Allow] <- RuleRows];
        _ -> []
    end.

normalize_command_permission_rules(Rules) when is_list(Rules), length(Rules) =< 100 ->
    try
        {NormalizedRev, Keys} = lists:foldl(fun(Rule0, {Acc, Seen}) when is_map(Rule0) ->
            Type0 = maps:get(<<"type">>, Rule0, maps:get(type, Rule0, undefined)),
            Id0 = maps:get(<<"id">>, Rule0, maps:get(id, Rule0, undefined)),
            Allow0 = maps:get(<<"allow">>, Rule0, maps:get(allow, Rule0, undefined)),
            Type = case pw_util:bin(Type0) of
                <<"channel">> -> <<"channel">>;
                <<"role">> -> <<"role">>;
                <<"user">> -> <<"user">>;
                _ -> throw(invalid_command_permissions)
            end,
            SubjectId = pw_util:int(Id0),
            Allow = case Allow0 of true -> true; false -> false; _ -> throw(invalid_command_permissions) end,
            case is_integer(SubjectId) andalso SubjectId > 0 of
                false -> throw(invalid_command_permissions);
                true -> ok
            end,
            Key = {Type, SubjectId},
            case maps:is_key(Key, Seen) of
                true -> throw(invalid_command_permissions);
                false -> {[#{type => Type, id => SubjectId, allow => Allow} | Acc], Seen#{Key => true}}
            end;
        (_, _) -> throw(invalid_command_permissions)
        end, {[], #{}}, Rules),
        _ = Keys,
        {ok, lists:reverse(NormalizedRev)}
    catch
        throw:invalid_command_permissions -> error
    end;
normalize_command_permission_rules(_) -> error.

validate_command_permission_subjects(Conn, Sid, Rules) ->
    lists:all(fun
        (#{type := <<"channel">>, id := SubjectId}) ->
            case one(Conn, "SELECT id FROM channels WHERE id=$1 AND server_id=$2", [SubjectId, Sid]) of {ok, [_]} -> true; _ -> false end;
        (#{type := <<"role">>, id := SubjectId}) ->
            case one(Conn, "SELECT id FROM server_roles WHERE id=$1 AND server_id=$2", [SubjectId, Sid]) of {ok, [_]} -> true; _ -> false end;
        (#{type := <<"user">>, id := SubjectId}) ->
            case one(Conn, "SELECT user_id FROM server_members WHERE server_id=$1 AND user_id=$2", [Sid, SubjectId]) of {ok, [_]} -> true; _ -> false end;
        (_) -> false
    end, Rules).

bot_command_permission_allowed(Conn, Uid, Sid, ChannelId, CommandId) ->
    %% Discord-style precedence for Plainwire: an explicit member rule wins,
    %% then the current channel rule, then role rules. Any matching role deny
    %% wins over role allows. With no matching overwrite the command remains
    %% available, preserving legacy command behavior.
    case one(Conn,
        "SELECT allow FROM bot_command_permissions WHERE command_id=$1 AND subject_type='user' AND subject_id=$2",
        [CommandId, Uid]) of
        {ok, [Allow]} when Allow =:= true; Allow =:= false -> Allow;
        _ ->
            case one(Conn,
                "SELECT allow FROM bot_command_permissions WHERE command_id=$1 AND subject_type='channel' AND subject_id=$2",
                [CommandId, ChannelId]) of
                {ok, [Allow]} when Allow =:= true; Allow =:= false -> Allow;
                _ ->
                    case rows(Conn,
                        "SELECT p.allow FROM bot_command_permissions p JOIN server_member_roles mr ON mr.role_id=p.subject_id "
                        "WHERE p.command_id=$1 AND p.subject_type='role' AND mr.server_id=$2 AND mr.user_id=$3",
                        [CommandId, Sid, Uid]) of
                        {ok, RoleRows} ->
                            Values = [V || [V] <- RoleRows, V =:= true orelse V =:= false],
                            case {lists:member(false, Values), lists:member(true, Values)} of
                                {true, _} -> false;
                                {false, true} -> true;
                                _ -> true
                            end;
                        _ -> true
                    end
            end
    end.

bot_identity(Conn, BotId) when is_integer(BotId), BotId > 0 ->
    case one(Conn,
        "SELECT b.bot_user_id,b.server_id FROM server_bots b JOIN users u ON u.id=b.bot_user_id "
        "WHERE b.id=$1 AND u.account_state='active'", [BotId]) of
        {ok, [BotUid, Sid]} -> {ok, BotUid, Sid};
        _ -> {error, forbidden}
    end;
bot_identity(_Conn, _BotId) -> {error, forbidden}.

normalize_command_name(Value0) ->
    Value = pw_util:clean_text(Value0, 40),
    Lower = try unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Value))) catch _:_ -> <<>> end,
    case byte_size(Lower) >= 1 andalso byte_size(Lower) =< 32 andalso
         re:run(Lower, <<"^[a-z][a-z0-9_-]{0,31}$">>, [{capture, none}]) =:= match of
        true -> Lower;
        false -> invalid
    end.

normalize_bot_command_set(Commands) when is_list(Commands), length(Commands) =< 100 ->
    normalize_bot_command_set(Commands, [], []);
normalize_bot_command_set(_) -> {error, invalid_commands}.

normalize_bot_command_set([], Acc, _Names) -> {ok, lists:reverse(Acc)};
normalize_bot_command_set([Definition | Rest], Acc, Names) when is_map(Definition) ->
    Name = normalize_command_name(maps:get(<<"name">>, Definition, maps:get(name, Definition, <<>>))),
    Description = pw_util:clean_text(
        maps:get(<<"description">>, Definition, maps:get(description, Definition, <<>>)), 160),
    Options0 = maps:get(<<"options">>, Definition, maps:get(options, Definition, [])),
    case {Name, normalize_command_options(Options0)} of
        {invalid, _} -> {error, invalid_command_name};
        {_, error} -> {error, invalid_command_options};
        {CommandName, {ok, Options}} ->
            case lists:member(CommandName, Names) of
                true -> {error, duplicate_command_name};
                false -> normalize_bot_command_set(Rest,
                    [{CommandName, Description, Options} | Acc], [CommandName | Names])
            end
    end;
normalize_bot_command_set(_, _, _) -> {error, invalid_commands}.

sync_bot_command_definitions(_Conn, _BotId, _Sid, [], _Now, Acc) -> {ok, lists:reverse(Acc)};
sync_bot_command_definitions(Conn, BotId, Sid, [{Name, Description, Options} | Rest], Now, Acc) ->
    OptionsJson = pw_util:json(Options),
    case one(Conn,
        "INSERT INTO bot_commands(bot_id,server_id,name,description,options_json,enabled,created_at,updated_at) "
        "VALUES($1,$2,$3,$4,$5,true,$6,$6) "
        "ON CONFLICT(server_id,name) DO UPDATE SET description=EXCLUDED.description,"
        "options_json=EXCLUDED.options_json,enabled=true,updated_at=EXCLUDED.updated_at "
        "WHERE bot_commands.bot_id=EXCLUDED.bot_id "
        "RETURNING id,name,description,options_json,enabled,created_at,updated_at",
        [BotId, Sid, Name, Description, OptionsJson, Now]) of
        {ok, Row} -> sync_bot_command_definitions(Conn, BotId, Sid, Rest, Now, [Row | Acc]);
        _ -> {error, command_name_taken}
    end.

normalize_command_options(Options) when is_list(Options), length(Options) =< 25 ->
    normalize_command_options(Options, [], []);
normalize_command_options(_) -> error.

normalize_command_options([], Acc, _Names) -> {ok, lists:reverse(Acc)};
normalize_command_options([Opt | Rest], Acc, Names) when is_map(Opt) ->
    Name = normalize_command_name(maps:get(<<"name">>, Opt, maps:get(name, Opt, <<>>))),
    Type0 = pw_util:clean_text(maps:get(<<"type">>, Opt, maps:get(type, Opt, <<"string">>)), 24),
    Type = case Type0 of
        <<"string">> -> <<"string">>; <<"integer">> -> <<"integer">>; <<"number">> -> <<"number">>;
        <<"boolean">> -> <<"boolean">>; <<"user">> -> <<"user">>; <<"channel">> -> <<"channel">>;
        _ -> invalid
    end,
    Required = maps:get(<<"required">>, Opt, maps:get(required, Opt, false)) =:= true,
    Desc = pw_util:clean_text(maps:get(<<"description">>, Opt, maps:get(description, Opt, <<>>)), 120),
    case Name =/= invalid andalso Type =/= invalid andalso not lists:member(Name, Names) of
        true -> normalize_command_options(Rest,
            [#{name => Name, type => Type, required => Required, description => Desc} | Acc], [Name | Names]);
        false -> error
    end;
normalize_command_options(_, _, _) -> error.

normalize_command_arguments(Args0, _Options) when is_binary(Args0); is_list(Args0) ->
    Raw = pw_util:clean_text(Args0, 2000),
    {ok, #{<<"raw">> => Raw}};
normalize_command_arguments(Args0, Options) when is_map(Args0), map_size(Args0) =< 32 ->
    try
        Pairs = maps:to_list(Args0),
        Clean = lists:foldl(fun({K0, V0}, Acc) ->
            K = normalize_command_name(K0),
            case {K, clean_command_arg(V0)} of
                {invalid, _} -> throw(invalid_command_arguments);
                {_, invalid} -> throw(invalid_command_arguments);
                {_, V} -> Acc#{K => V}
            end
        end, #{}, Pairs),
        case validate_command_argument_schema(Clean, Options) of
            ok ->
                Encoded = pw_util:json(Clean),
                case byte_size(Encoded) =< 4096 of true -> {ok, Clean}; false -> {error, command_arguments_too_large} end;
            error -> {error, invalid_command_arguments}
        end
    catch
        throw:invalid_command_arguments -> {error, invalid_command_arguments}
    end;
normalize_command_arguments(_, _) -> {error, invalid_command_arguments}.

clean_command_arg(V) when is_binary(V); is_list(V) -> pw_util:clean_text(V, 1000);
clean_command_arg(V) when is_integer(V) -> V;
clean_command_arg(V) when is_float(V) -> V;
clean_command_arg(true) -> true;
clean_command_arg(false) -> false;
clean_command_arg(null) -> null;
clean_command_arg(_) -> invalid.

validate_command_argument_schema(Args, Options) when is_map(Args), is_list(Options) ->
    Declared = lists:foldl(fun(Opt, Acc) when is_map(Opt) ->
        Name = maps:get(<<"name">>, Opt, maps:get(name, Opt, invalid)),
        Type = maps:get(<<"type">>, Opt, maps:get(type, Opt, invalid)),
        Required = maps:get(<<"required">>, Opt, maps:get(required, Opt, false)) =:= true,
        case Name of
            N when is_binary(N) -> Acc#{N => {Type, Required}};
            _ -> Acc
        end;
        (_, Acc) -> Acc
    end, #{}, Options),
    ArgNames = maps:keys(Args),
    NoUnknown = lists:all(fun(Name) -> maps:is_key(Name, Declared) end, ArgNames),
    RequiredPresent = maps:fold(fun(Name, {_Type, Required}, Ok) ->
        Ok andalso (not Required orelse maps:is_key(Name, Args))
    end, true, Declared),
    TypesValid = maps:fold(fun(Name, Value, Ok) ->
        case maps:get(Name, Declared, undefined) of
            {Type, _} -> Ok andalso command_argument_type_valid(Type, Value);
            _ -> false
        end
    end, true, Args),
    case NoUnknown andalso RequiredPresent andalso TypesValid of true -> ok; false -> error end;
validate_command_argument_schema(_, _) -> error.

command_argument_type_valid(<<"string">>, V) -> is_binary(V);
command_argument_type_valid(<<"integer">>, V) -> is_integer(V);
command_argument_type_valid(<<"number">>, V) -> is_integer(V) orelse is_float(V);
command_argument_type_valid(<<"boolean">>, V) -> V =:= true orelse V =:= false;
command_argument_type_valid(<<"user">>, V) -> is_integer(V) andalso V > 0;
command_argument_type_valid(<<"channel">>, V) -> is_integer(V) andalso V > 0;
command_argument_type_valid(_, _) -> false.

command_display(Name, Args) ->
    Raw = case maps:get(<<"raw">>, Args, <<>>) of
        B when is_binary(B) -> B;
        _ -> <<>>
    end,
    case Raw of
        <<>> -> <<"/", Name/binary>>;
        _ -> <<"/", Name/binary, " ", Raw/binary>>
    end.

encode_command_args(Args) -> pw_crypto:encrypt(pw_util:json(Args)).

decode_command_args(Value) ->
    Plain = pw_crypto:decrypt(pw_util:bin(Value)),
    decode_json_value(Plain, #{}).

decode_json_value(Value, Default) when is_binary(Value) ->
    try jsx:decode(Value, [return_maps]) catch _:_ -> Default end;
decode_json_value(_, Default) -> Default.

bot_command_map([Id, Name, Description, OptionsJson, Enabled, CreatedAt, UpdatedAt]) ->
    #{id => Id, name => Name, description => Description, options => decode_json_value(OptionsJson, []),
      enabled => Enabled, created_at => CreatedAt, updated_at => UpdatedAt}.

bot_command_channel_access(Conn, ChannelId,
        [_Id, _Name, _Description, _OptionsJson, _Enabled, _CreatedAt, _UpdatedAt,
         _BotId, _BotName, BotUid, _Username, _Display, _Avatar | _Rest]) ->
    channel_message_access(Conn, BotUid, ChannelId) =/= {error, forbidden};
bot_command_channel_access(_Conn, _ChannelId, _) -> false.

bot_public_command_map([Id, Name, Description, OptionsJson, Enabled, CreatedAt, UpdatedAt,
                        BotId, BotName, BotUid, Username, Display, Avatar | Rest]) ->
    Handler = case Rest of [H | _] -> H; _ -> <<"queue">> end,
    #{id => Id, name => Name, description => Description, options => decode_json_value(OptionsJson, []),
      enabled => Enabled, handler => Handler, created_at => CreatedAt, updated_at => UpdatedAt,
      bot => #{id => BotId, user_id => BotUid, name => BotName, username => Username,
               display_name => Display, avatar_url => pw_util:proxied_image(Avatar), is_bot => true}}.

claim_authorized_bot_invocations(_Conn, _BotId, _BotUid, [], _Now, _LeaseMs, Claims, Failed) ->
    {Claims, Failed};
claim_authorized_bot_invocations(Conn, BotId, BotUid,
        [Row=[Id, CommandId, _Name, Sid, Cid, UserId, _RequestMid, _ArgsCipher, _Attempts0, _CreatedAt] | Rest],
        Now, LeaseMs, Claims, Failed) ->
    case command_claim_authorization(Conn, UserId, Sid, Cid, CommandId, BotUid) of
        ok ->
            Claim = claim_bot_invocation(Conn, BotId, Row, Now, LeaseMs),
            claim_authorized_bot_invocations(Conn, BotId, BotUid, Rest, Now, LeaseMs, [Claim | Claims], Failed);
        {error, Reason} ->
            ok = exec(Conn,
                "UPDATE bot_command_invocations SET status='failed',fail_reason=$1,claim_token_hash='',lease_until=0,completed_at=$2,updated_at=$2 WHERE id=$3 AND bot_id=$4",
                [Reason, Now, Id, BotId]),
            Failure = #{id => Id, user_id => UserId, channel_id => Cid},
            claim_authorized_bot_invocations(Conn, BotId, BotUid, Rest, Now, LeaseMs, Claims, [Failure | Failed])
    end.

command_claim_authorization(Conn, UserId, Sid, Cid, CommandId, BotUid) ->
    case channel_message_access(Conn, BotUid, Cid) of
        {ok, Sid} ->
            case channel_message_access(Conn, UserId, Cid) of
                {ok, Sid} ->
                    case bot_command_permission_allowed(Conn, UserId, Sid, Cid, CommandId) of
                        true -> ok;
                        false -> {error, <<"Command permission revoked before delivery">>}
                    end;
                _ -> {error, <<"Invoking user no longer has access to this channel">>}
            end;
        _ -> {error, <<"Bot no longer has access to this channel">>}
    end.

claim_bot_invocation(Conn, BotId,
    [Id, CommandId, Name, Sid, Cid, UserId, RequestMid, ArgsCipher, Attempts0, CreatedAt], Now, LeaseMs) ->
    Token = <<"pwc_", (pw_util:random_token(32))/binary>>,
    Hash = pw_util:sha256_hex(Token), LeaseUntil = Now + LeaseMs, Attempts = Attempts0 + 1,
    ok = exec(Conn,
        "UPDATE bot_command_invocations SET status='claimed',claim_token_hash=$1,lease_until=$2,attempts=$3,updated_at=$4 WHERE id=$5 AND bot_id=$6",
        [Hash, LeaseUntil, Attempts, Now, Id, BotId]),
    #{id => Id, command_id => CommandId, command => Name, server_id => Sid, channel_id => Cid,
      user_id => db_null(UserId), request_message_id => db_null(RequestMid), args => decode_command_args(ArgsCipher),
      claim_token => Token, lease_until => LeaseUntil, attempt => Attempts, created_at => CreatedAt}.

secure_token_hash_match(Token, ExpectedHash) ->
    pw_util:constant_time(pw_util:sha256_hex(Token), ExpectedHash).

clamp_int(Value0, Min, Max, Default) ->
    Value = pw_util:int(Value0),
    case Value of I when is_integer(I) -> min(Max, max(Min, I)); _ -> Default end.

unique_bot_username(Conn, Sid, Name0) ->
    Base0 = pw_util:normalize_username(Name0),
    Base = case Base0 of <<>> -> <<"bot">>; _ -> binary:part(Base0, 0, erlang:min(16, byte_size(Base0))) end,
    Suffix = integer_to_binary(Sid),
    Candidate0 = <<Base/binary, "-bot-", Suffix/binary>>,
    unique_bot_username_try(Conn, Candidate0, 0).

unique_bot_username_try(Conn, Candidate0, Attempt) when Attempt < 100 ->
    Tail = case Attempt of 0 -> <<>>; _ -> <<"-", (integer_to_binary(Attempt))/binary>> end,
    MaxBase = erlang:max(1, 24 - byte_size(Tail)),
    Candidate = <<(binary:part(Candidate0, 0, erlang:min(MaxBase, byte_size(Candidate0))))/binary, Tail/binary>>,
    case one(Conn, "SELECT id FROM users WHERE username=$1", [Candidate]) of
        {ok, undefined} -> Candidate;
        _ -> unique_bot_username_try(Conn, Candidate0, Attempt + 1)
    end;
unique_bot_username_try(_Conn, _Candidate0, _Attempt) ->
    <<"bot-", (pw_util:random_token(9))/binary>>.

webhook_public_map([Id, Name, Url, Events, Enabled, CreatedBy, CreatedAt, UpdatedAt, LastSuccessAt, LastFailureAt, FailureCount]) ->
    #{id => Id, name => Name, url => Url, events => webhook_events_from_storage(Events), enabled => Enabled,
      created_by => CreatedBy, created_at => CreatedAt, updated_at => UpdatedAt,
      last_success_at => LastSuccessAt, last_failure_at => LastFailureAt, failure_count => FailureCount}.

webhook_event_catalog() ->
    [<<"message.created">>, <<"message.updated">>, <<"message.deleted">>, <<"message.reaction">>,
     <<"message.pinned">>, <<"message.unpinned">>,
     <<"member.joined">>, <<"member.removed">>, <<"member.banned">>, <<"member.unbanned">>,
     <<"channel.created">>, <<"channel.updated">>, <<"bot.added">>, <<"bot.removed">>, <<"server.updated">>].

normalize_webhook_events(Events0) when is_list(Events0) ->
    Events = lists:usort([pw_util:clean_text(E, 64) || E <- Events0]),
    Catalog = webhook_event_catalog(),
    case Events =/= [] andalso length(Events) =< length(Catalog) andalso lists:all(fun(E) -> lists:member(E, Catalog) end, Events) of
        true -> {ok, Events};
        false -> error
    end;
normalize_webhook_events(_) -> error.

webhook_events_storage(Events) ->
    iolist_to_binary([<<",">>, lists:join(<<",">>, Events), <<",">>]).

webhook_events_from_storage(Storage0) ->
    Storage = pw_util:bin(Storage0),
    [E || E <- binary:split(Storage, <<",">>, [global]), E =/= <<>>].

webhook_payload(Event, Sid, Data) ->
    pw_util:json(#{version => <<"2.0">>, event => Event, server_id => Sid,
                   created_at => pw_util:now_ms(), data => Data}).

enqueue_server_webhooks(Conn, Sid, Event, Data) when is_integer(Sid), Sid > 0 ->
    case lists:member(Event, webhook_event_catalog()) of
        false -> ok;
        true ->
            Needle = <<",", Event/binary, ",">>,
            case rows(Conn,
                "SELECT id FROM server_webhooks WHERE server_id=$1 AND enabled=true AND position($2 in events) > 0",
                [Sid, Needle]) of
                {ok, WebhookRows} ->
                    Payload = webhook_payload(Event, Sid, Data),
                    {SubjectUid, ActorUid} = webhook_user_ids(Event, Data),
                    Now = pw_util:now_ms(),
                    lists:foreach(fun([WebhookId]) ->
                        _ = exec(Conn,
                            "INSERT INTO webhook_deliveries(webhook_id,event,payload,subject_user_id,actor_user_id,status,attempts,next_attempt_at,created_at,updated_at) "
                            "VALUES($1,$2,$3,$4,$5,'pending',0,$6,$6,$6)",
                            [WebhookId, Event, store_message(Payload), SubjectUid, ActorUid, Now])
                    end, WebhookRows),
                    ok;
                _ -> ok
            end
    end;
enqueue_server_webhooks(_, _, _, _) -> ok.

webhook_user_ids(Event, Data) when is_map(Data) ->
    Actor = webhook_uid(maps:get(actor_id, Data, maps:get(<<"actor_id">>, Data, undefined))),
    Subject0 = case Event of
        <<"message.created">> -> webhook_message_author(Data);
        <<"message.updated">> -> webhook_message_author(Data);
        <<"message.deleted">> -> webhook_uid(maps:get(author_id, Data, undefined));
        <<"message.reaction">> -> webhook_uid(maps:get(author_id, Data, undefined));
        <<"member.joined">> -> webhook_uid(maps:get(user_id, Data, undefined));
        <<"member.removed">> -> webhook_uid(maps:get(user_id, Data, undefined));
        <<"member.banned">> -> webhook_uid(maps:get(user_id, Data, undefined));
        <<"member.unbanned">> -> webhook_uid(maps:get(user_id, Data, undefined));
        _ -> undefined
    end,
    {sql_optional_id(Subject0), sql_optional_id(Actor)};
webhook_user_ids(_, _) -> {null, null}.

webhook_message_author(Data) ->
    case maps:get(message, Data, maps:get(<<"message">>, Data, undefined)) of
        Msg when is_map(Msg) -> webhook_uid(maps:get(user_id, Msg, maps:get(<<"user_id">>, Msg, undefined)));
        _ -> undefined
    end.

webhook_uid(Value) -> optional_id(Value).

webhook_retry_delay_ms(Attempts) ->
    Base = min(60000, 1000 * (1 bsl max(0, min(5, Attempts - 1)))),
    Base + rand:uniform(500).

channel_server_id(Conn, ChannelId) ->
    case one(Conn, "SELECT server_id FROM channels WHERE id=$1", [ChannelId]) of
        {ok, [Sid]} -> Sid;
        _ -> undefined
    end.

maybe_enqueue_message_webhook(Conn, <<"channel">>, ChannelId, Event, Data) ->
    case channel_server_id(Conn, ChannelId) of
        Sid when is_integer(Sid) -> enqueue_server_webhooks(Conn, Sid, Event, Data);
        _ -> ok
    end;
maybe_enqueue_message_webhook(_, _, _, _, _) -> ok.

is_unique_violation(Reason) ->
    Text = string:lowercase(binary_to_list(pw_util:bin(io_lib:format("~p", [Reason])))),
    string:find(Text, "23505") =/= nomatch orelse string:find(Text, "unique") =/= nomatch.

best_effort_identity_changed(Conn, Uid, Username) ->
    Event = #{type => user_identity_updated, user_id => Uid, username => Username},
    %% The renaming user's own socket should update immediately. Discover the
    %% remaining targets while this DB worker is available, then release it
    %% before potentially large cross-node fanout work.
    pw_hub:notify_user(Uid, Event),
    ServerIds = case rows(Conn, "SELECT server_id FROM server_members WHERE user_id=$1", [Uid]) of
        {ok, ServerRows} -> lists:usort([Sid || [Sid] <- ServerRows]);
        _ -> []
    end,
    DirectIds = case rows(Conn, "SELECT thread_id FROM direct_members WHERE user_id=$1", [Uid]) of
        {ok, DirectRows} -> lists:usort([Cid || [Cid] <- DirectRows]);
        _ -> []
    end,
    ForumIds = case rows(Conn,
        "SELECT forum_id FROM forum_members WHERE user_id=$1 "
        "UNION SELECT forum_id FROM threads WHERE user_id=$1 "
        "UNION SELECT t.forum_id FROM replies r JOIN threads t ON t.id=r.thread_id WHERE r.user_id=$1",
        [Uid]) of
        {ok, ForumRows} -> lists:usort([ForumId || [ForumId] <- ForumRows]);
        _ -> []
    end,
    FriendIds = case rows(Conn,
        "SELECT CASE WHEN user_low=$1 THEN user_high ELSE user_low END FROM friendships "
        "WHERE (user_low=$1 OR user_high=$1) AND status IN ('accepted','pending')", [Uid]) of
        {ok, FriendRows} -> lists:usort([PeerUid || [PeerUid] <- FriendRows, PeerUid =/= Uid]);
        _ -> []
    end,
    Fanout = fun() ->
        try
            [pw_hub:broadcast({server, Sid}, Event) || Sid <- ServerIds],
            [pw_hub:broadcast({direct, Cid}, Event) || Cid <- DirectIds],
            [pw_hub:broadcast({forum, ForumId}, Event) || ForumId <- ForumIds],
            [pw_hub:notify_user(PeerUid, Event) || PeerUid <- FriendIds],
            ok
        catch C:R ->
            logger:warning("[plainwire:identity] realtime fanout failed uid=~p class=~p reason=~p", [Uid, C, R]),
            ok
        end
    end,
    case pw_async_pool:submit(Fanout) of
        {error, overloaded} -> logger:warning("[plainwire:identity] realtime fanout shed uid=~p", [Uid]);
        _ -> ok
    end,
    ok.

safe_exec(Conn, Sql) ->
    case try_exec(Conn, Sql) of
        ok -> ok;
        error -> erlang:error({migration_failed, Sql})
    end.

try_exec(Conn, Sql) ->
    try exec(Conn, Sql, []) catch _:_ -> error end.

exec(Conn, Sql, Params) ->
    R = if Params =:= [] -> epgsql:squery(Conn, Sql);
           true -> epgsql:equery(Conn, Sql, Params)
        end,
    case R of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        {ok, _, _, _} -> ok;
        {error, Reason} -> erlang:error({sql_error, Reason, Sql})
    end.

with_tx(Conn, Fun) ->
    ok = exec(Conn, "BEGIN", []),
    PreviousCompensations = erlang:get(pw_tx_compensations),
    PreviousAfterCommit = erlang:get(pw_tx_after_commit),
    erlang:put(pw_tx_compensations, []),
    erlang:put(pw_tx_after_commit, []),
    %% Keep application work and COMMIT as separate failure domains. Once COMMIT
    %% has been sent, a connection failure can make the PostgreSQL outcome
    %% unknowable to this process. Compensating Scylla in that state can undo a
    %% write whose PostgreSQL transaction actually committed. Leave the durable
    %% Scylla write intent intact instead; reconciliation will prove PostgreSQL
    %% state and either re-apply or remove the Scylla row.
    Outcome = try Fun() of
        Value -> {returned, Value}
    catch
        C0:R0:S0 -> {raised, C0, R0, S0}
    end,
    case Outcome of
        {returned, {ok, _} = Ok} ->
            case commit_tx(Conn) of
                ok ->
                    run_tx_after_commit(),
                    restore_tx_context(pw_tx_compensations, PreviousCompensations),
                    restore_tx_context(pw_tx_after_commit, PreviousAfterCommit),
                    Ok;
                {error, C, R, S} ->
                    pw_storage_metrics:incr(storage_commit_uncertain),
                    logger:error("[plainwire:storage] PostgreSQL commit outcome uncertain; preserving Scylla write intents class=~p reason=~p", [C, R]),
                    %% Do not ROLLBACK or run compensations here: the server may
                    %% already have committed. Restoring the process dictionary
                    %% discards local hooks while durable intents remain in Scylla.
                    restore_tx_context(pw_tx_compensations, PreviousCompensations),
                    restore_tx_context(pw_tx_after_commit, PreviousAfterCommit),
                    erlang:raise(C, R, S)
            end;
        {returned, Other} ->
            try exec(Conn, "ROLLBACK", []) catch _:_ -> ok end,
            run_tx_compensations(),
            discard_tx_after_commit(),
            restore_tx_context(pw_tx_compensations, PreviousCompensations),
            restore_tx_context(pw_tx_after_commit, PreviousAfterCommit),
            Other;
        {raised, C, R, S} ->
            try exec(Conn, "ROLLBACK", []) catch _:_ -> ok end,
            run_tx_compensations(),
            discard_tx_after_commit(),
            restore_tx_context(pw_tx_compensations, PreviousCompensations),
            restore_tx_context(pw_tx_after_commit, PreviousAfterCommit),
            erlang:raise(C, R, S)
    end.

commit_tx(Conn) ->
    try exec(Conn, "COMMIT", []) of
        ok -> ok
    catch
        C:R:S -> {error, C, R, S}
    end.

register_tx_compensation(Fun) when is_function(Fun, 0) ->
    case erlang:get(pw_tx_compensations) of
        L when is_list(L) -> erlang:put(pw_tx_compensations, [Fun | L]), ok;
        _ -> ok
    end.

register_tx_after_commit(Fun) when is_function(Fun, 0) ->
    case erlang:get(pw_tx_after_commit) of
        L when is_list(L) -> erlang:put(pw_tx_after_commit, [Fun | L]), ok;
        _ -> ok
    end.

run_tx_compensations() ->
    Compensations = case erlang:get(pw_tx_compensations) of L when is_list(L) -> L; _ -> [] end,
    erlang:put(pw_tx_compensations, []),
    lists:foreach(fun(Fun) ->
        try Fun() of
            ok -> ok;
            {ok, _} -> ok;
            Other ->
                pw_storage_metrics:incr(storage_compensation_failed),
                logger:error("[plainwire:storage] transaction compensation failed result=~p", [Other])
        catch C:R ->
            pw_storage_metrics:incr(storage_compensation_failed),
            logger:error("[plainwire:storage] transaction compensation crashed class=~p reason=~p", [C, R])
        end
    end, Compensations),
    ok.

run_tx_after_commit() ->
    Hooks = case erlang:get(pw_tx_after_commit) of L when is_list(L) -> lists:reverse(L); _ -> [] end,
    erlang:put(pw_tx_after_commit, []),
    lists:foreach(fun(Fun) ->
        try Fun() of
            ok -> ok;
            {ok, _} -> ok;
            Other ->
                pw_storage_metrics:incr(storage_after_commit_failed),
                logger:error("[plainwire:storage] after-commit hook failed result=~p", [Other])
        catch C:R ->
            pw_storage_metrics:incr(storage_after_commit_failed),
            logger:error("[plainwire:storage] after-commit hook crashed class=~p reason=~p", [C, R])
        end
    end, Hooks),
    ok.

discard_tx_after_commit() -> erlang:put(pw_tx_after_commit, []), ok.

restore_tx_context(Key, undefined) -> erlang:erase(Key), ok;
restore_tx_context(Key, Value) -> erlang:put(Key, Value), ok.

join_invite_tx(Conn, Uid, Code, Now) ->
    case one(Conn, "SELECT code, server_id, channel_id, max_uses, uses, expires_at, revoked FROM server_invites WHERE code = $1 FOR UPDATE", [Code]) of
        {ok, [Code, Sid, ChannelId, Max, Uses, Expires, false]} when (Max =:= 0 orelse Uses < Max), (Expires =:= 0 orelse Expires > Now) ->
            case one(Conn, "SELECT user_id FROM server_bans WHERE server_id=$1 AND user_id=$2", [Sid, Uid]) of
                {ok, [_]} -> {error, banned};
                _ ->
            AlreadyMember = is_member(Conn, Uid, Sid),
            ok = exec(Conn,
                "INSERT INTO server_members(server_id, user_id, role, muted, joined_at) VALUES($1,$2,$3,$4,$5) "
                "ON CONFLICT (server_id, user_id) DO NOTHING",
                [Sid, Uid, <<"member">>, false, Now]),
            case AlreadyMember of
                true -> ok;
                false ->
                    ok = exec(Conn, "UPDATE server_invites SET uses = uses + 1 WHERE code = $1", [Code]),
                    ok
            end,
            {ok, #{server_id => Sid, channel_id => ChannelId, membership_created => not AlreadyMember}}
            end;
        _ ->
            {error, invalid_invite}
    end.

rows(Conn, Sql, Params) ->
    R = if Params =:= [] -> epgsql:squery(Conn, Sql);
           true -> epgsql:equery(Conn, Sql, Params)
        end,
    case R of
        {ok, _, Rows} -> {ok, lists:map(fun to_list/1, Rows)};
        {ok, _, _, Rows} -> {ok, lists:map(fun to_list/1, Rows)};
        {error, Reason} -> {error, Reason}
    end.

to_list(L) when is_list(L) -> L;
to_list(T) when is_tuple(T) -> tuple_to_list(T).

one(Conn, Sql, Params) ->
    case rows(Conn, Sql, Params) of
        {ok, []} -> {ok, undefined};
        {ok, [R | _]} -> {ok, R};
        E -> E
    end.

insert_returning(Conn, Sql, Params) ->
    R = epgsql:equery(Conn, Sql, Params),
    case R of
        {ok, _, _, Rows} when is_list(Rows), Rows =/= [] -> {ok, hd(to_list(hd(Rows)))};
        {ok, _, _} -> {ok, 1};
        {ok, _} -> {ok, 1};
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

%% Validate the plaintext, never the encrypted representation. AES-GCM produces
%% a non-empty envelope even for <<>>, so checking ciphertext length would let
%% empty messages through whenever encryption-at-rest is enabled.
message_body_valid(Body) when is_binary(Body) ->
    byte_size(Body) > 0 andalso re:run(Body, <<"\\S">>, [{capture, none}, unicode]) =:= match;
message_body_valid(_) -> false.

store_message(Body) -> pw_crypto:encrypt(Body).
load_message(undefined) -> <<>>;
load_message(null) -> <<>>;
load_message(Body) -> pw_crypto:decrypt(Body).

%% Navigation summaries are intentionally bounded. The full message remains in
%% the message table and is fetched only for the open conversation; sync/sidebar
%% payloads should never carry an entire large markdown/attachment body.
conversation_preview_body(StoredBody) ->
    pw_util:clean_text(load_message(StoredBody), 512).

store_image_url(Url0) ->
    Url = pw_util:clean_text(Url0, 17825792),
    case Url of
        <<>> -> <<>>;
        <<"data:", _/binary>> ->
            case pw_util:safe_image_data_url(Url) of
                %% keep the source. ETS URLs vanish on restart (ask how we know).
                true -> Url;
                false -> <<>>
            end;
        <<"/api/files/", Id/binary>> ->
            case valid_file_id(Id) of true -> Url; false -> <<>> end;
        %% proxy URLs are output, not durable source data.
        <<"/api/media/", _/binary>> -> <<>>;
        <<"http://", _/binary>> -> Url;
        <<"https://", _/binary>> -> Url;
        _ -> <<>>
    end.

valid_file_id(Id) when byte_size(Id) >= 24, byte_size(Id) =< 64 ->
    lists:all(fun(C) -> file_id_char(C) end, binary_to_list(Id));
valid_file_id(_) -> false.

file_id_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
    (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_.

%% Owner access is intrinsic. Every other read must be justified by a live
%% reference. Backfills fail closed: a not-yet-rebuilt reference can temporarily
%% hide an old attachment, but it can never make unrelated private uploads public.
upload_readable(_Conn, Uid, _Id, Uid) when is_integer(Uid) -> true;
upload_readable(Conn, Uid, Id, _OwnerId) ->
    case rows(Conn, "SELECT scope, scope_id FROM upload_refs WHERE upload_id = $1 LIMIT 200", [Id]) of
        {ok, Refs} -> lists:any(fun(Ref) -> upload_ref_grants(Conn, Uid, Id, Ref) end, Refs);
        _ -> false
    end.

upload_ref_grants(Conn, _Uid, Id, [<<"profile">>, ProfileId]) ->
    current_public_upload_ref(Conn, <<"profile">>, pw_util:int(ProfileId), Id);
upload_ref_grants(Conn, _Uid, Id, [<<"server">>, ServerId]) ->
    current_public_upload_ref(Conn, <<"server">>, pw_util:int(ServerId), Id);
upload_ref_grants(Conn, Uid, _Id, [<<"server_member">>, ServerId]) ->
    is_member(Conn, Uid, pw_util:int(ServerId));
upload_ref_grants(Conn, _Uid, _Id, [<<"thread">>, ThreadId]) ->
    %% Forums are readable to authenticated users even before joining; joining is
    %% required only to post/vote. Thread attachment ACLs mirror that read model.
    case one(Conn, "SELECT id FROM threads WHERE id = $1", [pw_util:int(ThreadId)]) of
        {ok, [_]} -> true;
        _ -> false
    end;
upload_ref_grants(Conn, Uid, _Id, [Scope, ScopeId]) when Scope =:= <<"channel">>; Scope =:= <<"direct">> ->
    can_read_messages(Conn, Uid, Scope, pw_util:int(ScopeId));
upload_ref_grants(_Conn, _Uid, _Id, _Ref) -> false.

current_public_upload_ref(Conn, <<"profile">>, ProfileId, Id)
        when is_integer(ProfileId), ProfileId > 0, is_binary(Id) ->
    Url = <<"/api/files/", Id/binary>>,
    case one(Conn, "SELECT 1 FROM users WHERE id = $1 AND (avatar_url = $2 OR banner_url = $2)", [ProfileId, Url]) of
        {ok, [_]} -> true;
        _ -> false
    end;
current_public_upload_ref(Conn, <<"server">>, ServerId, Id)
        when is_integer(ServerId), ServerId > 0, is_binary(Id) ->
    Url = <<"/api/files/", Id/binary>>,
    case one(Conn, "SELECT 1 FROM servers WHERE id = $1 AND (icon_url = $2 OR banner_url = $2)", [ServerId, Url]) of
        {ok, [_]} -> true;
        _ -> false
    end;
current_public_upload_ref(_Conn, _Scope, _Id, _UploadId) -> false.

insert_upload_refs(Conn, Body, Scope, ScopeId, Now)
        when is_binary(Body), is_integer(ScopeId), ScopeId > 0,
             Scope =:= <<"channel">> orelse Scope =:= <<"direct">> orelse Scope =:= <<"thread">> ->
    lists:foreach(fun(Id) ->
        %% Unknown/deleted ids are a harmless INSERT..SELECT no-op. Real SQL
        %% failures must propagate so the surrounding content transaction rolls back.
        ok = exec(Conn,
            "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
            "SELECT up.id, $2, $3, $4 FROM uploads up WHERE up.id = $1 "
            "ON CONFLICT DO NOTHING", [Id, Scope, ScopeId, Now])
    end, extract_file_ids(Body)),
    ok;
insert_upload_refs(_Conn, _Body, _Scope, _ScopeId, _Now) -> ok.

sync_profile_upload_refs(Conn, Uid, Avatar, Banner, Now) ->
    replace_upload_refs(Conn, <<"profile">>, Uid,
        lists:usort(extract_file_ids(Avatar) ++ extract_file_ids(Banner)), Now).

sync_server_upload_refs(Conn, Sid, Icon, Banner, Now) ->
    replace_upload_refs(Conn, <<"server">>, Sid,
        lists:usort(extract_file_ids(Icon) ++ extract_file_ids(Banner)), Now).

sync_server_member_upload_refs(Conn, Sid, Now) ->
    Ids = case rows(Conn, "SELECT avatar_url FROM server_members WHERE server_id = $1", [Sid]) of
        {ok, MemberRows} -> lists:usort(lists:append(
            [extract_file_ids(pw_util:bin(Avatar)) || [Avatar] <- MemberRows]));
        _ -> []
    end,
    replace_upload_refs(Conn, <<"server_member">>, Sid, Ids, Now).

sync_thread_upload_refs(Conn, ThreadId, Now) ->
    Bodies0 = case one(Conn,
        "SELECT COALESCE(NULLIF(raw_body,''),body) FROM threads WHERE id = $1", [ThreadId]) of
        {ok, [Body]} -> [pw_util:bin(Body)];
        _ -> []
    end,
    Bodies = case rows(Conn,
        "SELECT COALESCE(NULLIF(raw_body,''),body) FROM replies WHERE thread_id = $1", [ThreadId]) of
        {ok, ReplyRows} -> Bodies0 ++ [pw_util:bin(Body) || [Body] <- ReplyRows];
        _ -> Bodies0
    end,
    Ids = lists:usort(lists:append([extract_file_ids(Body) || Body <- Bodies])),
    replace_upload_refs(Conn, <<"thread">>, ThreadId, Ids, Now).

sync_message_scope_upload_refs(Conn, Scope, ScopeId, Now)
        when Scope =:= <<"channel">>; Scope =:= <<"direct">> ->
    case rows(Conn,
        "SELECT body FROM messages WHERE scope = $1 AND scope_id = $2 "
        "AND deleted_at IS NULL AND kind = 'text'", [Scope, ScopeId]) of
        {ok, MessageRows} ->
            MessageIds = lists:append(
                [extract_file_ids(load_message(StoredBody)) || [StoredBody] <- MessageRows]),
            ExtraIds = case Scope of
                <<"direct">> ->
                    case one(Conn, "SELECT avatar_url FROM direct_threads WHERE id = $1", [ScopeId]) of
                        {ok, [Avatar]} -> extract_file_ids(pw_util:bin(Avatar));
                        _ -> []
                    end;
                _ -> []
            end,
            Ids = lists:usort(MessageIds ++ ExtraIds),
            replace_upload_refs(Conn, Scope, ScopeId, Ids, Now);
        _ -> ok
    end;
sync_message_scope_upload_refs(_Conn, _Scope, _ScopeId, _Now) -> ok.

replace_upload_refs(Conn, Scope, ScopeId, Ids0, Now)
        when is_binary(Scope), is_integer(ScopeId), ScopeId > 0, is_list(Ids0) ->
    Ids = lists:usort(Ids0),
    Existing = case rows(Conn,
        "SELECT upload_id FROM upload_refs WHERE scope = $1 AND scope_id = $2", [Scope, ScopeId]) of
        {ok, RefRows} -> lists:usort([pw_util:bin(Id) || [Id] <- RefRows]);
        _ -> []
    end,
    ok = exec(Conn, "DELETE FROM upload_refs WHERE scope = $1 AND scope_id = $2", [Scope, ScopeId]),
    lists:foreach(fun(Id) ->
        ok = exec(Conn,
            "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
            "SELECT up.id, $2, $3, $4 FROM uploads up WHERE up.id = $1 "
            "ON CONFLICT DO NOTHING", [Id, Scope, ScopeId, Now])
    end, Ids),
    [pw_upload_gc:invalidate_upload(Id) || Id <- ordsets:subtract(
        ordsets:from_list(Existing), ordsets:from_list(Ids))],
    ok;
replace_upload_refs(_Conn, _Scope, _ScopeId, _Ids, _Now) -> ok.

remove_scope_upload_refs(Conn, Scope, ScopeId)
        when is_binary(Scope), is_integer(ScopeId), ScopeId > 0 ->
    Existing = case rows(Conn,
        "SELECT upload_id FROM upload_refs WHERE scope = $1 AND scope_id = $2", [Scope, ScopeId]) of
        {ok, RefRows} -> lists:usort([pw_util:bin(Id) || [Id] <- RefRows]);
        _ -> []
    end,
    ok = exec(Conn, "DELETE FROM upload_refs WHERE scope = $1 AND scope_id = $2", [Scope, ScopeId]),
    [pw_upload_gc:invalidate_upload(Id) || Id <- Existing],
    ok;
remove_scope_upload_refs(_Conn, _Scope, _ScopeId) -> ok.

removed_upload_refs(OldBody, NewBody) ->
    ordsets:subtract(
        ordsets:from_list(extract_file_ids(pw_util:bin(OldBody))),
        ordsets:from_list(extract_file_ids(pw_util:bin(NewBody)))).

%% pull file ids out before the body becomes ciphertext soup.
extract_file_ids(Body) when is_binary(Body) ->
    lists:usort(collect_file_ids(Body, 0, []));
extract_file_ids(_) -> [].

collect_file_ids(_Bin, Found, Acc) when Found >= 20 -> Acc;
collect_file_ids(Bin, Found, Acc) ->
    case binary:match(Bin, <<"/api/files/">>) of
        nomatch -> Acc;
        {Pos, Len} ->
            Start = Pos + Len,
            Rest = binary:part(Bin, Start, byte_size(Bin) - Start),
            {Id, Tail} = take_file_id(Rest, 0),
            case valid_file_id(Id) of
                true -> collect_file_ids(Tail, Found + 1, [Id | Acc]);
                false -> collect_file_ids(Tail, Found, Acc)
            end
    end.

take_file_id(Bin, N) when N < byte_size(Bin) ->
    case file_id_char(binary:at(Bin, N)) of
        true -> take_file_id(Bin, N + 1);
        false -> {binary:part(Bin, 0, N), binary:part(Bin, N, byte_size(Bin) - N)}
    end;
take_file_id(Bin, N) -> {binary:part(Bin, 0, N), <<>>}.

server_image_input_allowed(_Conn, _Uid, <<>>) -> true;
server_image_input_allowed(Conn, Uid, <<"/api/files/", Id/binary>>) ->
    profile_upload_allowed(Conn, Uid, Id);
server_image_input_allowed(_Conn, _Uid, <<"data:", _/binary>> = Url) ->
    pw_util:safe_image_data_url(Url);
server_image_input_allowed(_Conn, _Uid, <<"http://", _/binary>>) -> true;
server_image_input_allowed(_Conn, _Uid, <<"https://", _/binary>>) -> true;
server_image_input_allowed(_, _, _) -> false.

current_profile_images(Conn, Uid) ->
    case one(Conn, "SELECT avatar_url, banner_url FROM users WHERE id = $1 FOR UPDATE", [Uid]) of
        {ok, [Avatar, Banner]} -> {pw_util:bin(Avatar), pw_util:bin(Banner)};
        _ -> {<<>>, <<>>}
    end.

store_profile_image(Url0, Current, Conn, Uid) ->
    Url = pw_util:clean_text(Url0, 17825792),
    %% unchanged signed output means "keep the source".
    case Url =:= pw_util:proxied_image(Current) of
        true -> Current;
        false ->
            case Url of
                <<"/api/files/", Id/binary>> ->
                    case profile_upload_allowed(Conn, Uid, Id) of
                        true -> Url;
                        false -> Current
                    end;
                _ -> store_image_url(Url)
            end
    end.

profile_upload_allowed(Conn, Uid, Id) ->
    MaxBytes = pw_client_config:profile_image_max_bytes(),
    case valid_file_id(Id) of
        false -> false;
        true ->
            case one(Conn,
                "SELECT content_type,size,path FROM uploads "
                "WHERE id = $1 AND user_id = $2 AND status = 'ready'", [Id, Uid]) of
                {ok, [Type, Size, Path]} when is_integer(Size), Size > 0, Size =< MaxBytes ->
                    safe_profile_file(Type, Path);
                _ -> false
            end
    end.

safe_profile_file(Type, Path) ->
    case file:open(binary_to_list(Path), [read, raw, binary]) of
        {ok, Io} ->
            Result = case file:read(Io, 64) of
                {ok, Header} -> profile_file_signature(Type, Header);
                _ -> false
            end,
            _ = file:close(Io),
            Result;
        _ -> false
    end.

profile_file_signature(<<"image/jpeg">>, <<16#ff,16#d8,16#ff,_/binary>>) -> true;
profile_file_signature(<<"image/png">>, <<16#89,"PNG",13,10,26,10,_/binary>>) -> true;
profile_file_signature(<<"image/gif">>, <<"GIF87a",_/binary>>) -> true;
profile_file_signature(<<"image/gif">>, <<"GIF89a",_/binary>>) -> true;
profile_file_signature(<<"image/webp">>, <<"RIFF",_:4/binary,"WEBP",_/binary>>) -> true;
profile_file_signature(<<"image/avif">>, <<_:4/binary,"ftyp",Brands/binary>>) ->
    binary:match(Brands, <<"avif">>) =/= nomatch orelse binary:match(Brands, <<"avis">>) =/= nomatch;
profile_file_signature(_, _) -> false.



normalize_theme(<<"light">>) -> <<"light">>;
normalize_theme(<<"dark">>) -> <<"dark">>;
normalize_theme(<<"system">>) -> <<"system">>;
normalize_theme(_) -> <<"system">>.

forum_position(Conn) ->
    case one(Conn, "SELECT COALESCE(max(position), 0) + 1 FROM forums", []) of
        {ok, [P]} -> pw_util:int(P);
        _ -> 1
    end.

clean_slug(<<>>, Name) -> clean_slug(Name, <<>>);
clean_slug(undefined, Name) -> clean_slug(Name, <<>>);
clean_slug(Slug0, _Name) ->
    Lower = string:lowercase(binary_to_list(pw_util:clean_text(Slug0, 40))),
    Filtered = [C || C <- Lower, (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $-],
    pw_util:bin(Filtered).

invite_options(Max, Exp) when is_integer(Max), Max >= 0, Max =< 10000,
                               is_integer(Exp), Exp >= 0, Exp =< 2592000 ->
    case Exp =:= 0 orelse Exp >= 60 of true -> {ok, Max, Exp}; false -> {error, invalid_invite_options} end;
invite_options(_, _) -> {error, invalid_invite_options}.

valid_invite_channel(_Conn, _Sid, undefined) -> true;
valid_invite_channel(Conn, Sid, ChannelId) ->
    case one(Conn, "SELECT id FROM channels WHERE id = $1 AND server_id = $2", [ChannelId, Sid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

ensure_list(L) when is_list(L) -> L;
ensure_list(_) -> [].

strip_username_prefix(<<$@, Rest/binary>>) -> Rest;
strip_username_prefix(Name) -> Name.

user_ids_for_usernames(_Conn, []) -> error;
user_ids_for_usernames(Conn, Usernames) ->
    N = length(Usernames),
    Placeholders = string:join(["$" ++ integer_to_list(I) || I <- lists:seq(1, N)], ","),
    Sql = "SELECT id,username FROM users WHERE username IN (" ++ Placeholders ++ ")",
    case rows(Conn, Sql, Usernames) of
        {ok, Found} when length(Found) =:= N -> {ok, [Id || [Id, _] <- Found]};
        _ -> error
    end.

new_conversation_member_ids(_Conn, _Cid, []) -> [];
new_conversation_member_ids(Conn, Cid, UserIds) ->
    N = length(UserIds),
    Placeholders = string:join(["$" ++ integer_to_list(I + 1) || I <- lists:seq(1, N)], ","),
    Sql = "SELECT user_id FROM direct_members WHERE thread_id = $1 AND user_id IN (" ++ Placeholders ++ ")",
    case rows(Conn, Sql, [Cid | UserIds]) of
        {ok, ExistingRows} -> UserIds -- [Id || [Id] <- ExistingRows];
        _ -> []
    end.

users_exist(_Conn, []) -> true;
users_exist(Conn, UserIds) ->
    UniqueIds = lists:usort([pw_util:int(U) || U <- UserIds, is_integer(pw_util:int(U))]),
    case UniqueIds of
        [] -> true;
        _ ->
            N = length(UniqueIds),
            Placeholders = string:join(["$" ++ integer_to_list(I) || I <- lists:seq(1, N)], ","),
            Sql = "SELECT id FROM users WHERE id IN (" ++ Placeholders ++ ")",
            case rows(Conn, Sql, UniqueIds) of
                {ok, FoundIds} -> length(FoundIds) =:= length(UniqueIds);
                _ -> false
            end
    end.

users_not_blocked(_Conn, _Uid, []) -> true;
users_not_blocked(Conn, Uid, UserIds) ->
    UniqueIds = lists:usort([pw_util:int(U) || U <- UserIds, is_integer(pw_util:int(U)), pw_util:int(U) =/= Uid]),
    case UniqueIds of
        [] -> true;
        _ ->
            Pairs = [{min(Uid, U), max(Uid, U)} || U <- UniqueIds],
            case length(Pairs) > 0 of
                true ->
                    N = length(Pairs),
                    Params = lists:flatten([[L, H] || {L, H} <- Pairs]),
                    PairsSql = string:join(["($" ++ integer_to_list(I*2-1) ++ ",$" ++ integer_to_list(I*2) ++ ")" || I <- lists:seq(1, N)], ","),
                    Sql = "SELECT user_low, user_high FROM friendships WHERE (user_low, user_high) IN (" ++ PairsSql ++ ") AND status = 'blocked'",
                    case rows(Conn, Sql, Params) of
                        {ok, []} -> true;
                        {ok, _} -> false;
                        _ -> true
                    end;
                false -> true
            end
    end.

duplicate_server_name(_Conn, _Uid, _Sid, <<>>) -> false;
duplicate_server_name(Conn, Uid, Sid, Name) ->
    case one(Conn, "SELECT id FROM servers WHERE owner_id = $1 AND id <> $2 AND lower(name) = lower($3) LIMIT 1", [Uid, Sid, Name]) of
        {ok, [_]} -> true;
        _ -> false
    end.

existing_invite(Conn, Sid, undefined, MaxUses) ->
    existing_invite_sql(Conn, "SELECT code FROM server_invites WHERE server_id = $1 AND channel_id IS NULL AND max_uses = $2 AND revoked = false AND expires_at = 0 AND (max_uses = 0 OR uses < max_uses) ORDER BY created_at DESC LIMIT 1", [Sid, MaxUses]);
existing_invite(Conn, Sid, ChannelId, MaxUses) ->
    existing_invite_sql(Conn, "SELECT code FROM server_invites WHERE server_id = $1 AND channel_id = $2 AND max_uses = $3 AND revoked = false AND expires_at = 0 AND (max_uses = 0 OR uses < max_uses) ORDER BY created_at DESC LIMIT 1", [Sid, ChannelId, MaxUses]).

existing_invite_sql(Conn, Sql, Params) ->
    case one(Conn, Sql, Params) of
        {ok, [Code]} -> {ok, Code};
        _ -> not_found
    end.

existing_one_to_one(Conn, Uid, Peer) ->
    Sql = "SELECT dm.thread_id FROM direct_members dm "
          "JOIN direct_members dm2 ON dm2.thread_id = dm.thread_id AND dm2.user_id = $2 "
          "WHERE dm.user_id = $1 "
          "AND (SELECT count(*) FROM direct_members WHERE thread_id = dm.thread_id) = 2 "
          "ORDER BY dm.thread_id ASC LIMIT 1",
    case one(Conn, Sql, [Uid, Peer]) of
        {ok, [Tid]} -> {ok, Tid};
        _ -> not_found
    end.

conversation_member_count(Conn, Cid) ->
    case one(Conn, "SELECT count(*) FROM direct_members WHERE thread_id = $1", [Cid]) of
        {ok, [Count]} when is_integer(Count) -> Count;
        {ok, [Count]} -> case pw_util:int(Count) of I when is_integer(I) -> I; _ -> 0 end;
        _ -> 0
    end.

create_one_to_one0(Conn, Uid, Peer) ->
    Result = with_tx(Conn, fun() ->
        {Low, High} = pair(Uid, Peer),
        %% A stable pair lock makes 1:1 creation idempotent across API nodes.
        _ = rows(Conn, "SELECT pg_advisory_xact_lock($1, $2)", [Low, High]),
        case existing_one_to_one(Conn, Uid, Peer) of
            {ok, Tid} ->
                %% "new DM" also reopens the old one. less ghost chat, yay.
                ok = exec(Conn, "UPDATE direct_members SET hidden = false WHERE thread_id = $1 AND user_id = $2", [Tid, Uid]),
                {ok, #{id => Tid, existing => true}};
            not_found ->
                create_conversation_tx(Conn, Uid, <<>>, [Peer])
        end
    end),
    finish_conversation_create(Conn, Uid, Result).

create_conversation0(Conn, Uid, Name, UserIds) ->
    Result = with_tx(Conn, fun() -> create_conversation_tx(Conn, Uid, Name, UserIds) end),
    finish_conversation_create(Conn, Uid, Result).

create_conversation_tx(Conn, Uid, Name, UserIds) ->
    Now = pw_util:now_ms(),
    {ok, Tid} = insert_returning(Conn,
        "INSERT INTO direct_threads(name, avatar_url, owner_id, created_at, updated_at) VALUES($1,$2,$3,$4,$5) RETURNING id",
        [Name, <<>>, Uid, Now, Now]),
    IsRequest = case UserIds of [OnlyPeer] -> not is_friend(Conn, Uid, OnlyPeer); _ -> false end,
    [begin
        RequestState = case U =:= Uid orelse not IsRequest of true -> <<"accepted">>; false -> <<"pending">> end,
        GroupRole = case U =:= Uid of true -> <<"owner">>; false -> <<"member">> end,
        ok = exec(Conn,
            "INSERT INTO direct_members(thread_id, user_id, last_read_message_id, muted, nickname, joined_at, request_state, group_role) "
            "VALUES($1,$2,0,false,$3,$4,$5,$6) ON CONFLICT (thread_id, user_id) DO NOTHING",
            [Tid, U, <<>>, Now, RequestState, GroupRole])
     end || U <- [Uid | UserIds]],
    {ok, #{id => Tid, request_created => IsRequest, created_at => Now}}.

finish_conversation_create(Conn, Uid, {ok, #{id := Tid, request_created := IsRequest, created_at := Now} = Data}) ->
    CreatedEvent = case IsRequest of
        true -> #{type => message_request, conversation_id => Tid};
        false -> #{type => conversation_created, conversation_id => Tid}
    end,
    best_effort_direct_notifications(Conn, Tid, Uid, CreatedEvent, Now, false),
    {ok, maps:without([request_created, created_at], Data)};
finish_conversation_create(_Conn, _Uid, Other) -> Other.

pair(A, B) when A < B -> {A, B};
pair(A, B) -> {B, A}.

only_id([I]) -> I;
only_id(I) -> I.

user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, LastSeen]) ->
    user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, LastSeen, false]);
user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, LastSeen, IsBot]) ->
    #{id => Id, username => U, display_name => D, bio => Bio,
      avatar_url => pw_util:proxied_image(Avatar),
      banner_url => pw_util:proxied_image(Banner),
      status => Status, theme => Theme, created_at => Created, last_seen => LastSeen, is_bot => IsBot =:= true}.

user_map_full([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, LastSeen]) ->
    (user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, LastSeen])) #{
      avatar_source_url => Avatar, banner_source_url => Banner}.

forum_map([Id, Slug, Name, Desc, Pos, Owner, Tc, Rc, Last, Members, Joined]) ->
    #{id => pw_util:int(Id), slug => Slug, name => Name, description => Desc, position => pw_util:int(Pos),
      owner_id => db_null(Owner),
      thread_count => pw_util:int(Tc), reply_count => pw_util:int(Rc), last_at => db_null(Last),
      member_count => pw_util:int(Members), joined => Joined}.

thread_row_map([Id, Fid, Fname, Uid, U, D, Avatar, Title, Body, Created, Updated, Rc, Views, Pinned, Score, UserVote, ViewerJoined]) ->
    #{id => Id, forum_id => Fid, forum_name => Fname, user_id => Uid, username => U,
       display_name => D, avatar_url => pw_util:proxied_image(Avatar), title => Title, body => Body, created_at => Created, updated_at => Updated,
       reply_count => Rc, views => Views, pinned => Pinned, score => Score, user_vote => UserVote, viewer_joined => ViewerJoined}.

thread_full_map([Id, Fid, Fname, Uid, U, D, Avatar, Title, Body, Created, Updated, Rc, Locked, Pinned, Views, Score, UserVote]) ->
    #{id => Id, forum_id => Fid, forum_name => Fname, user_id => Uid, username => U,
      display_name => D, avatar_url => pw_util:proxied_image(Avatar), title => Title, body => render_forum_body(Body), raw_body => Body,
      created_at => Created, updated_at => Updated, reply_count => Rc, locked => Locked,
      pinned => Pinned, views => Views, score => Score, user_vote => UserVote};
thread_full_map([Id, Fid, Fname, Uid, U, D, Avatar, Title, Body, RawBody, Created, Updated, Rc, Locked, Pinned, Views, Score, UserVote]) ->
    #{id => Id, forum_id => Fid, forum_name => Fname, user_id => Uid, username => U,
      display_name => D, avatar_url => pw_util:proxied_image(Avatar), title => Title, body => render_forum_body(Body), raw_body => RawBody,
      created_at => Created, updated_at => Updated, reply_count => Rc, locked => Locked,
      pinned => Pinned, views => Views, score => Score, user_vote => UserVote}.

reply_map([Id, Tid, Uid, U, D, Avatar, Body, Created, Updated]) ->
    #{id => Id, thread_id => Tid, user_id => Uid, username => U, display_name => D,
      avatar_url => pw_util:proxied_image(Avatar), body => render_forum_body(Body), raw_body => Body, created_at => Created, updated_at => Updated};
reply_map([Id, Tid, Uid, U, D, Avatar, Body, RawBody, Created, Updated]) ->
    #{id => Id, thread_id => Tid, user_id => Uid, username => U, display_name => D,
      avatar_url => pw_util:proxied_image(Avatar), body => render_forum_body(Body), raw_body => RawBody, created_at => Created, updated_at => Updated}.

%% rewrite standalone image URLs on output; stored forum text stays boring.
render_forum_body(Body) when is_binary(Body) ->
    Lines = binary:split(Body, <<"\n">>, [global]),
    iolist_to_binary(lists:join(<<"\n">>, [render_forum_line(Line) || Line <- Lines]));
render_forum_body(Body) -> Body.

render_forum_line(Line) ->
    Url = string:trim(Line),
    case remote_image_url(Url) of
        true -> <<"![image](", (pw_media:proxy_url(Url))/binary, ")">>;
        false -> Line
    end.

remote_image_url(<<"http://", _/binary>> = Url) -> image_url_extension(Url);
remote_image_url(<<"https://", _/binary>> = Url) -> image_url_extension(Url);
remote_image_url(_) -> false.

image_url_extension(Url) ->
    try uri_string:parse(binary_to_list(Url)) of
        #{path := Path} ->
            Ext = string:lowercase(filename:extension(Path)),
            lists:member(Ext, [".gif", ".png", ".jpg", ".jpeg", ".webp", ".avif"]);
        _ -> false
    catch _:_ -> false
    end.

friend_map([Status, Req, Addr, Id, U, D, Bio, Avatar, Banner, St, Theme, Created, Last], Viewer) ->
    #{status => Status,
      incoming => (Status =:= <<"pending">> andalso Addr =:= Viewer),
      outgoing => (Status =:= <<"pending">> andalso Req =:= Viewer),
      blocked_by_me => (Status =:= <<"blocked">> andalso Req =:= Viewer),
      user => user_map([Id, U, D, Bio, Avatar, Banner, St, Theme, Created, Last])}.

server_row_map([Id, Owner, Name, Desc, Icon, Banner, Accent, Welcome, Created, Updated, Role, Members, Permissions]) ->
    #{id => Id, owner_id => Owner, name => Name, description => Desc,
      icon_url => pw_util:proxied_image(Icon), banner_url => pw_util:proxied_image(Banner), accent_color => Accent, welcome_message => Welcome,
      created_at => Created, updated_at => Updated,
      role => Role, member_count => Members, permissions => pw_util:int(Permissions)};
server_row_map([Id, Owner, Name, Desc, Icon, Banner, Accent, Welcome, Created, Updated, Role, Members]) ->
    #{id => Id, owner_id => Owner, name => Name, description => Desc,
      icon_url => pw_util:proxied_image(Icon), banner_url => pw_util:proxied_image(Banner), accent_color => Accent, welcome_message => Welcome,
      created_at => Created, updated_at => Updated,
      role => Role, member_count => Members, permissions => 0}.

server_full_map([Id, Owner, Name, Desc, Icon, Banner, Accent, Welcome, Created, Updated], Role) ->
    server_full_map([Id, Owner, Name, Desc, Icon, Banner, Accent, Welcome, Created, Updated, pw_permissions:member_default()], Role);
server_full_map([Id, Owner, Name, Desc, Icon, Banner, Accent, Welcome, Created, Updated, DefaultPermissions], Role) ->
    #{id => Id, owner_id => Owner, name => Name, description => Desc,
      icon_url => pw_util:proxied_image(Icon), banner_url => pw_util:proxied_image(Banner), accent_color => Accent, welcome_message => Welcome,
      created_at => Created, updated_at => Updated, role => Role, default_permissions => pw_permissions:sanitize(DefaultPermissions)}.

clean_accent(<<"#", Hex:6/binary>>) ->
    case lists:all(fun(C) ->
        (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F)
    end, binary_to_list(Hex)) of
        true -> <<"#", Hex/binary>>;
        false -> undefined
    end;
clean_accent(_) -> undefined.

derived_media_url(<<"/api/media/", _/binary>>) -> true;
derived_media_url(_) -> false.

channel_map([Id, Sid, Name, Kind, Pos, Topic, Created]) ->
    channel_map([Id, Sid, Name, Kind, Pos, Topic, Created, undefined, 0]);
channel_map([Id, Sid, Name, Kind, Pos, Topic, Created, CatId]) ->
    channel_map([Id, Sid, Name, Kind, Pos, Topic, Created, CatId, 0]);
channel_map([Id, Sid, Name, Kind, Pos, Topic, Created, CatId, Slowmode]) ->
    #{id => Id, server_id => Sid, name => Name, kind => Kind, position => Pos, topic => Topic,
      created_at => Created, category_id => db_null(CatId), slowmode_seconds => int_or(pw_util:int(Slowmode), 0)}.

category_map([Id, Sid, Name, Pos, Created]) ->
    #{id => Id, server_id => Sid, name => Name, position => Pos, created_at => Created}.

member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
      role => Role, muted => Muted, joined_at => Joined};
member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio]) ->
    member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio, <<>>, <<>>]);
member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio, RoleColor, RoleNames]) ->
    member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio, RoleColor, RoleNames, false]);
member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio, RoleColor, RoleNames, IsBot]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, IsBot]),
      role => Role, muted => Muted, joined_at => Joined,
      nickname => Nick, server_avatar_url => pw_util:proxied_image(ServerAvatar), server_bio => ServerBio,
      role_color => RoleColor, role_names => RoleNames,
      server_profile => #{nickname => Nick, avatar_url => pw_util:proxied_image(ServerAvatar), bio => ServerBio}}.

server_role_map([Id, Name, Color, Permissions, Position, Hoist, Mentionable, Created, Updated]) ->
    #{id => Id, name => Name, color => Color, permissions => Permissions, position => Position,
      hoist => Hoist, mentionable => Mentionable, created_at => Created, updated_at => Updated}.

role_assignment_map(Rows) ->
    lists:foldl(fun
        ([Uid, RoleId], Acc) -> maps:update_with(Uid, fun(Ids) -> [RoleId | Ids] end, [RoleId], Acc);
        (_, Acc) -> Acc
    end, #{}, Rows).

server_admin_member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, LegacyRole, Nick, ServerAvatar, ServerBio, Joined], RoleIds) ->
    server_admin_member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, LegacyRole, Nick, ServerAvatar, ServerBio, Joined, false], RoleIds);
server_admin_member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, LegacyRole, Nick, ServerAvatar, ServerBio, Joined, IsBot], RoleIds) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, IsBot]),
      legacy_role => LegacyRole, nickname => Nick, server_avatar_url => pw_util:proxied_image(ServerAvatar),
      server_bio => ServerBio, joined_at => Joined, role_ids => lists:reverse(RoleIds)}.

role_color(Value0) ->
    Value = pw_util:clean_text(Value0, 7),
    case clean_accent(Value) of undefined -> <<"#99aab5">>; Color -> Color end.

int_or(I, _Default) when is_integer(I) -> I;
int_or(_, Default) -> Default.

normalize_role_ids(Values) when is_list(Values) ->
    lists:usort([I || Value <- Values, I <- [pw_util:int(Value)], is_integer(I), I > 0]);
normalize_role_ids(_) -> [].

normalize_category_order(Order) when is_list(Order), length(Order) =< 200 ->
    Parsed = [normalize_category_order_item(Item) || Item <- Order],
    case lists:any(fun(Item) -> Item =:= error end, Parsed) of
        true -> {error, invalid_category_order};
        false ->
            Ids = [Id || {Id, _} <- Parsed],
            Positions = [Pos || {_, Pos} <- Parsed],
            case length(lists:usort(Ids)) =:= length(Ids) andalso
                 length(lists:usort(Positions)) =:= length(Positions) of
                true -> {ok, Parsed};
                false -> {error, invalid_category_order}
            end
    end;
normalize_category_order(_) -> {error, invalid_category_order}.

normalize_category_order_item(Item) when is_map(Item) ->
    Id = pw_util:int(maps:get(<<"id">>, Item, undefined)),
    Pos = pw_util:int(maps:get(<<"position">>, Item, undefined)),
    case {Id, Pos} of
        {I, P} when is_integer(I), I > 0, is_integer(P), P >= 0, P =< 10000 -> {I, P};
        _ -> error
    end;
normalize_category_order_item(_) -> error.

grantable_role_permissions(Conn, Uid, Sid, Requested0) ->
    Requested = pw_permissions:sanitize(Requested0),
    case server_member_is_owner(Conn, Sid, Uid) of
        true -> Requested;
        false ->
            case server_permissions0(Conn, Uid, Sid) of
                {ok, ActorPermissions} ->
                    NoAdministrator = pw_permissions:all() bxor pw_permissions:mask(<<"administrator">>),
                    Requested band ActorPermissions band NoAdministrator;
                _ -> 0
            end
    end.

message_map([Id, Scope, ScopeId, Uid, U, D, Avatar, Body, ReplyTo, Created, Edited, Deleted, Kind, ForwardId, ForwardUid, ForwardName, ForwardBody, RoleColor]) ->
    message_map([Id, Scope, ScopeId, Uid, U, D, Avatar, Body, ReplyTo, Created, Edited, Deleted, Kind, ForwardId, ForwardUid, ForwardName, ForwardBody, RoleColor, false, false]);
message_map([Id, Scope, ScopeId, Uid, U, D, Avatar, Body, ReplyTo, Created, Edited, Deleted, Kind, ForwardId, ForwardUid, ForwardName, ForwardBody, RoleColor, IsBot]) ->
    message_map([Id, Scope, ScopeId, Uid, U, D, Avatar, Body, ReplyTo, Created, Edited, Deleted, Kind, ForwardId, ForwardUid, ForwardName, ForwardBody, RoleColor, IsBot, false]);
message_map([Id, Scope, ScopeId, Uid, U, D, Avatar, Body, ReplyTo, Created, Edited, Deleted, Kind, ForwardId, ForwardUid, ForwardName, _ForwardBody, RoleColor, IsBot, Pinned]) ->
    Base = #{id => Id, scope => Scope, scope_id => ScopeId, user_id => Uid, username => U, display_name => D,
      avatar_url => pw_util:proxied_image(Avatar), body => load_message(Body), reply_to_id => db_null(ReplyTo),
      created_at => Created, edited_at => db_null(Edited), deleted_at => db_null(Deleted), kind => Kind,
      role_color => RoleColor, is_bot => IsBot =:= true, pinned => Pinned =:= true, reactions => []},
    case ForwardId of
        null -> Base;
        %% A forward is an immutable snapshot. Never expose the *current* body
        %% of the source message here: the source may be edited later in a
        %% room the forward recipient cannot read. Keep the legacy `body`
        %% field in the provenance object for wire compatibility, but make it
        %% the forwarded snapshot rather than a live cross-scope read.
        _ -> Base#{forwarded_from => #{id => ForwardId, user_id => ForwardUid, display_name => ForwardName, body => load_message(Body)}}
    end.

optional_id(Value) ->
    case pw_util:int(Value) of
        Id when is_integer(Id), Id > 0 -> Id;
        _ -> undefined
    end.

valid_channel_category(_Conn, _Sid, undefined) -> true;
valid_channel_category(Conn, Sid, CategoryId) ->
    case one(Conn, "SELECT id FROM channel_categories WHERE id = $1 AND server_id = $2", [CategoryId, Sid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

sql_optional_id(undefined) -> null;
sql_optional_id(Id) -> Id.

prefer_server_text(null, Fallback) -> Fallback;
prefer_server_text(<<>>, Fallback) -> Fallback;
prefer_server_text(Value, _Fallback) -> Value.

db_null(null) -> undefined;
db_null(X) -> X.
message_map(Conn, Row = [_,Scope,ScopeId,_,_,_,_,_,ReplyTo|_]) ->
    M = message_map(Row),
    case ReplyTo of
        null -> M;
        _ -> M#{reply_to => replied_message(Conn, ReplyTo, Scope, ScopeId)}
    end.
message_map_with_replies(Row = [_,_,_,_,_,_,_,_,ReplyTo|_], ReplyMap) ->
    M = message_map(Row),
    case ReplyTo of
        null -> M;
        _ -> case maps:find(ReplyTo, ReplyMap) of
            {ok, ReplyInfo} -> M#{reply_to => ReplyInfo};
            error -> M
        end
    end.

message_map_with_replies_and_reactions(Row = [Id|_], ReplyMap, ReactionMap) ->
    M = message_map_with_replies(Row, ReplyMap),
    M#{reactions => maps:get(Id, ReactionMap, [])}.

batch_message_reactions(_Conn, [], _Uid, _Scope, _ScopeId) -> #{};
batch_message_reactions(Conn, Rows0, Uid, Scope, ScopeId) ->
    Ids = [Id || [Id|_] <- Rows0, is_integer(Id)],
    case Ids of
        [] -> #{};
        _ ->
            MinId = lists:min(Ids), MaxId = lists:max(Ids),
            case rows(Conn,
                "SELECT mr.message_id,mr.emoji,count(*),bool_or(mr.user_id=$5),min(mr.created_at) "
                "FROM message_reactions mr JOIN messages m ON m.id=mr.message_id "
                "WHERE m.scope=$1 AND m.scope_id=$2 AND mr.message_id >= $3 AND mr.message_id <= $4 "
                "GROUP BY mr.message_id,mr.emoji ORDER BY min(mr.created_at) ASC,mr.emoji ASC",
                [Scope, ScopeId, MinId, MaxId, Uid]) of
                {ok, ReactionRows} ->
                    lists:foldl(fun([MessageId, Emoji, Count, Me, _], Acc) ->
                        Item = #{emoji => Emoji, count => Count, me => Me},
                        maps:update_with(MessageId, fun(Items) -> Items ++ [Item] end, [Item], Acc)
                    end, #{}, ReactionRows);
                _ -> #{}
            end
    end.

reaction_allowed(Emoji) ->
    lists:member(Emoji, [<<240,159,145,128>>, <<240,159,152,132>>, <<240,159,152,130>>, <<240,159,164,163>>, <<240,159,152,137>>, <<240,159,152,141>>, <<240,159,164,148>>, <<240,159,152,133>>, <<240,159,152,173>>, <<240,159,165,186>>, <<240,159,171,160>>, <<240,159,152,142>>, <<240,159,146,128>>, <<240,159,148,165>>, <<226,156,168>>, <<240,159,142,137>>, <<226,157,164,239,184,143>>, <<240,159,146,153>>, <<240,159,145,141>>, <<240,159,145,142>>, <<240,159,145,143>>, <<240,159,153,143>>, <<240,159,145,139>>, <<240,159,153,140>>, <<226,156,133>>, <<226,157,140>>, <<226,154,160,239,184,143>>, <<240,159,154,128>>, <<240,159,144,155>>, <<240,159,147,140>>]).

replied_message(Conn, ReplyTo, Scope, ScopeId) ->
    Sql = "SELECT m.body,m.user_id,COALESCE(NULLIF(sm.nickname,''),u.display_name) "
          "FROM messages m JOIN users u ON u.id=m.user_id "
          "LEFT JOIN channels c ON m.scope='channel' AND c.id=m.scope_id "
          "LEFT JOIN server_members sm ON sm.server_id=c.server_id AND sm.user_id=m.user_id "
          "WHERE m.id=$1 AND m.scope=$2 AND m.scope_id=$3 AND m.deleted_at IS NULL",
    case one(Conn, Sql, [ReplyTo, Scope, ScopeId]) of
        {ok, [Body, RUid, RName]} ->
            #{id => ReplyTo, user_id => RUid, display_name => RName, body => load_message(Body)};
        _ -> undefined
    end.

batch_replied_messages(_Conn, [], _Scope, _ScopeId) -> #{};
batch_replied_messages(Conn, Ids, Scope, ScopeId) ->
    UniqueIds = lists:usort(Ids),
    N = length(UniqueIds),
    Params = UniqueIds ++ [Scope, ScopeId],
    Placeholders = string:join(["$" ++ integer_to_list(I) || I <- lists:seq(1, N)], ","),
    Sql = "SELECT m.id,m.body,m.user_id,COALESCE(NULLIF(sm.nickname,''),u.display_name) "
          "FROM messages m JOIN users u ON u.id=m.user_id "
          "LEFT JOIN channels c ON m.scope='channel' AND c.id=m.scope_id "
          "LEFT JOIN server_members sm ON sm.server_id=c.server_id AND sm.user_id=m.user_id "
          "WHERE m.id IN (" ++ Placeholders ++ ") AND m.scope = $" ++ integer_to_list(N + 1) ++
          " AND m.scope_id = $" ++ integer_to_list(N + 2) ++ " AND m.deleted_at IS NULL",
    case rows(Conn, Sql, Params) of
        {ok, Rows} ->
            maps:from_list([{Id, #{id => Id, user_id => Uid, display_name => D, body => load_message(Body)}}
                            || [Id, Body, Uid, D] <- Rows]);
        _ -> #{}
    end.

conversation_row_map([Id, Name, Avatar, Owner, Created, Updated, LastRead, Muted, RequestState, GroupRole, Count, LastBody, LastMsg, LastSenderId, LastSenderName, LastSenderUsername, Unread, PeerId, PeerName, PeerAvatar, PeerUsername]) ->
    #{id => Id, name => Name, avatar_url => pw_util:proxied_image(Avatar), owner_id => Owner,
      created_at => Created, updated_at => Updated, last_read_message_id => LastRead, muted => Muted, request_state => RequestState, group_role => GroupRole,
      member_count => Count, last_body => conversation_preview_body(LastBody), last_message_id => LastMsg, unread => Unread,
      last_sender_id => LastSenderId, last_sender_name => LastSenderName, last_sender_username => LastSenderUsername,
      peer_id => PeerId, peer_name => PeerName, peer_avatar_url => pw_util:proxied_image(PeerAvatar), peer_username => PeerUsername}.

conversation_full_map([Id, Name, Avatar, Owner, Created, Updated]) ->
    #{id => Id, name => Name, avatar_url => pw_util:proxied_image(Avatar),
      owner_id => Owner, created_at => Created, updated_at => Updated}.

conversation_member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, LastRead, Muted, Nick, Joined]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
      last_read_message_id => LastRead, muted => Muted, nickname => Nick, joined_at => Joined, role => <<"member">>, group_role => <<"member">>};
conversation_member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, LastRead, Muted, Nick, Joined, GroupRole]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
      last_read_message_id => LastRead, muted => Muted, nickname => Nick, joined_at => Joined, role => GroupRole, group_role => GroupRole}.

notification_map([Id, Kind, Body, Url, Seen, Created]) ->
    #{id => Id, kind => Kind, body => Body, url => Url, seen => Seen, created_at => Created}.

thread_sql(undefined, <<>>) ->
    {thread_select() ++ " ORDER BY t.pinned DESC, t.score DESC, t.updated_at DESC LIMIT 120", []};
thread_sql(F, <<>>) ->
    {thread_select() ++ " WHERE t.forum_id = $2 ORDER BY t.pinned DESC, t.score DESC, t.updated_at DESC LIMIT 120", [F]};
thread_sql(undefined, S) ->
    L = <<"%", S/binary, "%">>,
    {thread_select() ++ " WHERE t.title ILIKE $2 OR t.body ILIKE $3 ORDER BY t.score DESC, t.updated_at DESC LIMIT 120", [L, L]};
thread_sql(F, S) ->
    L = <<"%", S/binary, "%">>,
    {thread_select() ++ " WHERE t.forum_id = $2 AND (t.title ILIKE $3 OR t.body ILIKE $4) "
     "ORDER BY t.score DESC, t.updated_at DESC LIMIT 120", [F, L, L]}.

thread_select() ->
    "SELECT t.id, t.forum_id, f.name, t.user_id, u.username, u.display_name, u.avatar_url, t.title, t.body, t.created_at, t.updated_at, "
    "t.reply_count, t.views, t.pinned, COALESCE(t.score,0), COALESCE(tv.value,0), "
    "EXISTS(SELECT 1 FROM forum_members fm WHERE fm.forum_id = t.forum_id AND fm.user_id = $1) "
    "FROM threads t JOIN forums f ON f.id = t.forum_id JOIN users u ON u.id = t.user_id "
    "LEFT JOIN thread_votes tv ON tv.thread_id = t.id AND tv.user_id = $1".

message_select() ->
    "SELECT m.id, m.scope, m.scope_id, m.user_id, u.username, "
    "COALESCE(NULLIF(sm.nickname,''),u.display_name), COALESCE(NULLIF(sm.avatar_url,''),u.avatar_url), "
    "m.body, m.reply_to_id, m.created_at, m.edited_at, m.deleted_at, m.kind, "
    %% The final column is intentionally NULL. Older decoders expect the slot,
    %% but fetching fm.body would pull live source text across scope boundaries.
    "m.forwarded_from_id, fm.user_id, fu.display_name, NULL, "
    "COALESCE((SELECT r.color FROM server_member_roles mr JOIN server_roles r ON r.id=mr.role_id "
    "WHERE mr.server_id=mc.server_id AND mr.user_id=m.user_id ORDER BY "
    "(r.permissions & 1073741824) DESC,(r.permissions & 16) DESC,(r.permissions & 32) DESC,"
    "(r.permissions & 8) DESC,(r.permissions & 4) DESC,(r.permissions & 64) DESC,"
    "(r.permissions & 128) DESC,(r.permissions & 2048) DESC,(r.permissions & 4096) DESC,"
    "(r.permissions & 256) DESC,(r.permissions & 512) DESC,(r.permissions & 2) DESC,"
    "(r.permissions & 1) DESC,r.position DESC,r.id ASC LIMIT 1),''), u.is_bot, "
    "EXISTS(SELECT 1 FROM message_pins pin WHERE pin.message_id=m.id) "
    "FROM messages m JOIN users u ON u.id = m.user_id "
    "LEFT JOIN channels mc ON m.scope='channel' AND mc.id=m.scope_id "
    "LEFT JOIN server_members sm ON sm.server_id=mc.server_id AND sm.user_id=m.user_id "
    "LEFT JOIN messages fm ON fm.id = m.forwarded_from_id LEFT JOIN users fu ON fu.id = fm.user_id".

message_cache_lookup(Uid, Scope, ScopeId, undefined, undefined)
  when is_integer(Uid), is_integer(ScopeId), ScopeId > 0 ->
    VersionKey = message_cache_version_key(Scope, ScopeId),
    case pw_redis:cache_version(VersionKey) of
        {ok, Version} ->
            PayloadKey = message_cache_payload_key(Uid, Scope, ScopeId),
            case pw_redis:cache_get_at_version(PayloadKey, Version) of
                {ok, Bin} ->
                    case safe_cached_term(Bin) of
                        {ok, Messages} when is_list(Messages) ->
                            pw_storage_metrics:incr(redis_message_cache_hit),
                            {hit, Messages};
                        _ ->
                            pw_storage_metrics:incr(redis_message_cache_miss),
                            {miss, Version}
                    end;
                _ ->
                    pw_storage_metrics:incr(redis_message_cache_miss),
                    {miss, Version}
            end;
        _ ->
            pw_storage_metrics:incr(redis_message_cache_unavailable),
            {miss, unavailable}
    end;
message_cache_lookup(_Uid, _Scope, _ScopeId, _Before, _After) -> {miss, not_cacheable}.

maybe_store_message_cache(Uid, Scope, ScopeId, undefined, undefined, VersionBefore, Messages)
  when is_integer(VersionBefore), VersionBefore >= 0 ->
    VersionKey = message_cache_version_key(Scope, ScopeId),
    %% A second generation read closes the race where the DB read overlaps an
    %% edit/delete/send. If the generation changed, do not cache the older view.
    case pw_redis:cache_version(VersionKey) of
        {ok, VersionBefore} ->
            PayloadKey = message_cache_payload_key(Uid, Scope, ScopeId),
            pw_redis:cache_put_at_version(PayloadKey, VersionBefore,
                term_to_binary(Messages, [compressed]), ?MESSAGE_CACHE_TTL_MS);
        _ -> ok
    end;
maybe_store_message_cache(_, _, _, _, _, _, _) -> ok.

invalidate_message_cache(Scope, ScopeId) when is_integer(ScopeId), ScopeId > 0 ->
    _ = pw_redis:cache_bump_version(message_cache_version_key(Scope, ScopeId)),
    ok;
invalidate_message_cache(_, _) -> ok.

message_cache_version_key(Scope, ScopeId) -> term_to_binary({messages, Scope, ScopeId}).
message_cache_payload_key(Uid, Scope, ScopeId) -> term_to_binary({messages_latest, Uid, Scope, ScopeId}).

safe_cached_term(Bin) when is_binary(Bin), byte_size(Bin) =< ?MAX_MESSAGE_CACHE_BYTES ->
    case external_term_decoded_size(Bin) of
        Size when is_integer(Size), Size > ?MAX_MESSAGE_CACHE_DECODED_BYTES -> error;
        _ ->
            try {ok, binary_to_term(Bin, [safe])}
            catch _:_ -> error end
    end;
safe_cached_term(_) -> error.

external_term_decoded_size(<<131, 80, Size:32/unsigned-big, _/binary>>) -> Size;
external_term_decoded_size(_) -> unknown.

load_message_rows(Conn, Scope, ScopeId, Before, After) ->
    case pw_scylla_config:backend() of
        scylla ->
            case scylla_history(Scope, ScopeId, Before, After) of
                {ok, []} ->
                    %% In `scylla` mode a successful Scylla read is authoritative.
                    %% Falling back on an empty result can resurrect stale rows from
                    %% the PostgreSQL recovery mirror after canonical cleanup. The
                    %% migration runbook requires verification before this cutover.
                    {ok, []};
                {ok, CoreRows} ->
                    case hydrate_scylla_rows(Conn, CoreRows) of
                        {ok, Rows} when length(Rows) =:= length(CoreRows) -> {ok, Rows};
                        _ ->
                            pw_storage_metrics:incr(scylla_hydration_fallback),
                            pg_message_rows(Conn, Scope, ScopeId, Before, After)
                    end;
                {error, _Reason} ->
                    pw_storage_metrics:incr(scylla_read_fallback),
                    pg_message_rows(Conn, Scope, ScopeId, Before, After)
            end;
        _ -> pg_message_rows(Conn, Scope, ScopeId, Before, After)
    end.

pg_message_rows(Conn, Scope, ScopeId, Before, After) ->
    {Sql, Params} = message_sql(Scope, ScopeId, Before, After),
    rows(Conn, Sql, Params).

scylla_history(Scope, ScopeId, undefined, undefined) -> pw_message_store:get_recent(Scope, ScopeId, 80);
scylla_history(Scope, ScopeId, Before, undefined) when is_integer(Before) -> pw_message_store:get_before(Scope, ScopeId, Before, 80);
scylla_history(Scope, ScopeId, _Before, After) when is_integer(After) -> pw_message_store:get_after(Scope, ScopeId, After, 250);
scylla_history(Scope, ScopeId, _, _) -> pw_message_store:get_recent(Scope, ScopeId, 80).

hydrate_scylla_rows(_Conn, []) -> {ok, []};
hydrate_scylla_rows(Conn, CoreRows) ->
    Ids = [maps:get(id, M) || M <- CoreRows],
    N = length(Ids),
    Placeholders = string:join(["$" ++ integer_to_list(I) || I <- lists:seq(1, N)], ","),
    Sql = message_select() ++ " WHERE m.id IN (" ++ Placeholders ++ ")",
    case rows(Conn, Sql, Ids) of
        {ok, PgRows} ->
            ById = maps:from_list([{hd(R), R} || R <- PgRows]),
            {ok, [overlay_scylla_row(maps:get(maps:get(id, Core), ById), Core)
                  || Core <- CoreRows, maps:is_key(maps:get(id, Core), ById)]};
        Error -> Error
    end.

overlay_scylla_row([Id, _Scope, _ScopeId, _Uid, U, D, Avatar, _Body, _Reply, _Created, _Edited, _Deleted, _Kind, _ForwardId, ForwardUid, ForwardName, ForwardBody, RoleColor, IsBot], Core) ->
    [Id, maps:get(scope, Core), maps:get(scope_id, Core), maps:get(user_id, Core), U, D, Avatar, maps:get(body, Core),
     db_value(maps:get(reply_to_id, Core, undefined)), maps:get(created_at, Core),
     db_value(maps:get(edited_at, Core, undefined)), db_value(maps:get(deleted_at, Core, undefined)), maps:get(kind, Core, <<"text">>),
     db_value(maps:get(forwarded_from_id, Core, undefined)), ForwardUid, ForwardName, ForwardBody, RoleColor, IsBot].

db_value(undefined) -> null;
db_value(V) -> V.

message_sql(Scope, Id, undefined, undefined) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.deleted_at IS NULL ORDER BY m.id DESC LIMIT 80", [Scope, Id]};
message_sql(Scope, Id, Before, undefined) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.deleted_at IS NULL AND m.id < $3 ORDER BY m.id DESC LIMIT 80", [Scope, Id, Before]};
message_sql(Scope, Id, _, After) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.deleted_at IS NULL AND m.id > $3 ORDER BY m.id ASC LIMIT 250", [Scope, Id, After]}.

validate_thread(Conn, Uid, F, T, B) ->
    case {F, byte_size(T) >= 3, byte_size(B) > 0, one(Conn, "SELECT id FROM forums WHERE id = $1", [F])} of
        {I, true, true, {ok, [_]}} when is_integer(I), I > 0 ->
            case is_forum_member(Conn, Uid, I) of
                true -> ok;
                false -> {error, forum_membership_required}
            end;
        _ -> {error, invalid_thread}
    end.

is_forum_member(Conn, Uid, ForumId) ->
    case one(Conn, "SELECT 1 FROM forum_members WHERE forum_id = $1 AND user_id = $2", [ForumId, Uid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

friendship_status(_, U, U) -> self;
friendship_status(Conn, A, B) ->
    {L, H} = pair(A, B),
    case one(Conn, "SELECT status, requester_id, addressee_id FROM friendships WHERE user_low = $1 AND user_high = $2", [L, H]) of
        {ok, [S, R, Ad]} ->
            #{status => S, incoming => (S =:= <<"pending">> andalso Ad =:= A),
              outgoing => (S =:= <<"pending">> andalso R =:= A),
              blocked_by_me => (S =:= <<"blocked">> andalso R =:= A)};
        _ ->
            #{status => none, blocked_by_me => false}
    end.

is_friend(Conn, A, B) ->
    {L, H} = pair(A, B),
    case one(Conn, "SELECT status FROM friendships WHERE user_low = $1 AND user_high = $2", [L, H]) of
        {ok, [<<"accepted">>]} -> true;
        _ -> false
    end.

is_member(Conn, Uid, Sid) ->
    case one(Conn, "SELECT role FROM server_members WHERE server_id = $1 AND user_id = $2", [Sid, Uid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

server_permissions0(Conn, Uid, Sid) ->
    case one(Conn,
        "SELECT s.owner_id, sm.role, s.default_permissions FROM servers s JOIN server_members sm ON sm.server_id = s.id "
        "WHERE s.id = $1 AND sm.user_id = $2", [Sid, Uid]) of
        {ok, [Uid, _, _]} -> {ok, pw_permissions:all()};
        {ok, [_Owner, <<"owner">>, _]} -> {ok, pw_permissions:all()};
        {ok, [_Owner, <<"admin">>, _]} -> {ok, pw_permissions:admin_default()};
        {ok, [_Owner, _, DefaultPermissions]} ->
            Base = pw_permissions:sanitize(DefaultPermissions),
            case rows(Conn,
                "SELECT r.permissions FROM server_member_roles mr JOIN server_roles r ON r.id = mr.role_id "
                "WHERE mr.server_id = $1 AND mr.user_id = $2", [Sid, Uid]) of
                {ok, RoleRows} ->
                    {ok, lists:foldl(fun
                        ([P], Acc) when is_integer(P) -> Acc bor pw_permissions:sanitize(P);
                        (_, Acc) -> Acc
                    end, Base, RoleRows)};
                _ -> {ok, Base}
            end;
        _ -> {error, forbidden}
    end.

has_server_permission(Conn, Uid, Sid, Permission) ->
    case server_permissions0(Conn, Uid, Sid) of
        {ok, Permissions} -> pw_permissions:has(Permissions, pw_permissions:mask(Permission));
        _ -> false
    end.

server_member_rank0(Conn, Sid, Uid) ->
    case one(Conn,
        "SELECT s.owner_id, sm.role FROM servers s JOIN server_members sm ON sm.server_id = s.id "
        "WHERE s.id = $1 AND sm.user_id = $2", [Sid, Uid]) of
        {ok, [Uid, _]} -> 1000000;
        {ok, [_Owner, <<"owner">>]} -> 1000000;
        {ok, [_Owner, <<"admin">>]} -> 10000;
        {ok, [_Owner, _]} ->
            case one(Conn,
                "SELECT COALESCE(max(r.position),0) FROM server_member_roles mr JOIN server_roles r ON r.id = mr.role_id "
                "WHERE mr.server_id = $1 AND mr.user_id = $2", [Sid, Uid]) of
                {ok, [Rank]} when is_integer(Rank) -> Rank;
                _ -> 0
            end;
        _ -> -1
    end.

server_member_is_owner(Conn, Sid, Uid) ->
    case one(Conn, "SELECT owner_id FROM servers WHERE id = $1", [Sid]) of
        {ok, [Uid]} -> true;
        _ -> false
    end.

can_moderate_server_member(_Conn, Actor, _Sid, Target) when Actor =:= Target -> false;
can_moderate_server_member(Conn, Actor, Sid, Target) ->
    not server_member_is_owner(Conn, Sid, Target) andalso
    (server_member_is_owner(Conn, Sid, Actor) orelse server_member_rank0(Conn, Sid, Actor) > server_member_rank0(Conn, Sid, Target)).

can_manage_server(Conn, Uid, Sid) ->
    has_server_permission(Conn, Uid, Sid, <<"manage_server">>).

channel_server_member(Conn, Uid, Cid) ->
    case one(Conn,
        "SELECT c.server_id FROM channels c JOIN server_members sm ON sm.server_id = c.server_id AND sm.user_id = $1 WHERE c.id = $2",
        [Uid, Cid]) of
        {ok, [Sid]} -> {ok, Sid};
        _ -> {error, forbidden}
    end.

channel_text_server_member(Conn, Uid, Cid) ->
    case one(Conn,
        "SELECT c.server_id FROM channels c JOIN server_members sm ON sm.server_id = c.server_id AND sm.user_id = $1 "
        "WHERE c.id = $2 AND c.kind = 'text'", [Uid, Cid]) of
        {ok, [Sid]} -> {ok, Sid};
        _ -> {error, forbidden}
    end.

is_voice_note_body(Body) when is_binary(Body) ->
    %% Voice notes are normal durable messages plus a private upload reference.
    %% The fragment is never sent to the server by browsers when fetching the
    %% file, so it is safe as message metadata while reusing the upload ACL path.
    binary:match(Body, <<"#plainwire-voice-note">>) =/= nomatch;
is_voice_note_body(_) -> false.

channel_message_access(Conn, Uid, Cid) ->
    case channel_text_server_member(Conn, Uid, Cid) of
        {ok, Sid} ->
            case has_server_permission(Conn, Uid, Sid, <<"view_channels">>) andalso
                 has_server_permission(Conn, Uid, Sid, <<"send_messages">>) of
                true -> {ok, Sid};
                false -> {error, forbidden}
            end;
        Error -> Error
    end.

server_member_identity(Conn, Uid, Sid) ->
    case one(Conn,
        "SELECT u.username,u.display_name,u.avatar_url,sm.nickname,sm.avatar_url "
        "FROM server_members sm JOIN users u ON u.id=sm.user_id WHERE sm.server_id=$1 AND sm.user_id=$2",
        [Sid, Uid]) of
        {ok, [Username, DisplayName, Avatar, Nickname, ServerAvatar]} ->
            ScopedName = prefer_server_text(Nickname, DisplayName),
            ScopedAvatar = prefer_server_text(ServerAvatar, Avatar),
            {ok, #{id => Uid, username => Username, display_name => ScopedName,
                avatar_url => pw_util:proxied_image(ScopedAvatar), server_id => Sid}};
        _ -> {error, forbidden}
    end.

can_read_messages(Conn, Uid, <<"channel">>, Id) ->
    case channel_text_server_member(Conn, Uid, Id) of
        {ok, Sid} -> has_server_permission(Conn, Uid, Sid, <<"view_channels">>);
        _ -> false
    end;
%% blocked means no reading either. the old half-block was not much of a block.
can_read_messages(Conn, Uid, <<"direct">>, Id) ->
    is_conversation_member(Conn, Uid, Id) andalso not is_blocked_in_conversation(Conn, Uid, Id);
can_read_messages(_, _, _, _) -> false.

enforce_channel_slowmode(Conn, Uid, Cid, Sid) ->
    case one(Conn, "SELECT COALESCE(slowmode_seconds,0) FROM channels WHERE id=$1 AND server_id=$2 AND kind='text'", [Cid,Sid]) of
        {ok, [Slow]} when is_integer(Slow), Slow > 0 ->
            %% Bots and moderators are automation/moderation actors and bypass
            %% user slowmode, matching the normal Manage Messages expectation.
            IsBot = case one(Conn, "SELECT is_bot FROM users WHERE id=$1", [Uid]) of {ok,[true]} -> true; _ -> false end,
            Bypass = IsBot orelse has_server_permission(Conn, Uid, Sid, <<"manage_messages">>),
            case Bypass of
                true -> ok;
                false ->
                    %% Two-key advisory lock is scoped to this transaction and
                    %% prevents concurrent sends on separate app nodes from both
                    %% observing the same previous-message timestamp.
                    _ = one(Conn, "SELECT pg_advisory_xact_lock($1,$2)", [Uid,Cid]),
                    Now = pw_util:now_ms(),
                    case one(Conn, "SELECT COALESCE(max(created_at),0) FROM messages WHERE scope='channel' AND scope_id=$1 AND user_id=$2 AND deleted_at IS NULL", [Cid,Uid]) of
                        {ok, [Last]} when is_integer(Last), Last > 0 ->
                            Remaining = Slow * 1000 - (Now - Last),
                            case Remaining > 0 of true -> {error, {slowmode, (Remaining + 999) div 1000}}; false -> ok end;
                        _ -> ok
                    end
            end;
        _ -> ok
    end.

%% Editing/deleting is an ownership operation, but ownership alone must not let a
%% departed member keep mutating history in a scope they can no longer access.
%% For direct conversations we intentionally ignore block state here: a member
%% may still clean up their own messages after a block, but not after leaving.
can_modify_message_scope(Conn, Uid, <<"channel">>, Id) ->
    case channel_server_member(Conn, Uid, Id) of
        {ok, Sid} -> has_server_permission(Conn, Uid, Sid, <<"view_channels">>);
        _ -> false
    end;
can_modify_message_scope(Conn, Uid, <<"direct">>, Id) ->
    is_conversation_member(Conn, Uid, Id);
can_modify_message_scope(_, _, _, _) -> false.

can_delete_message(Conn, Uid, Uid, Scope, ScopeId) ->
    can_modify_message_scope(Conn, Uid, Scope, ScopeId);
can_delete_message(Conn, Uid, AuthorId, <<"channel">>, ScopeId) ->
    case channel_server_member(Conn, Uid, ScopeId) of
        {ok, Sid} ->
            %% Moderation must not become a side door into a channel the actor
            %% cannot see. The message may have arrived by id from an old UI,
            %% a stale notification, or a crafted request.
            has_server_permission(Conn, Uid, Sid, <<"view_channels">>) andalso
            has_server_permission(Conn, Uid, Sid, <<"manage_messages">>) andalso
            can_moderate_server_member(Conn, Uid, Sid, AuthorId);
        _ -> false
    end;
can_delete_message(_, _, _, _, _) -> false.

valid_reply_to(_, _, _, undefined) -> true;
valid_reply_to(Conn, Scope, ScopeId, ReplyTo) when is_integer(ReplyTo) ->
    case one(Conn, "SELECT id FROM messages WHERE id = $1 AND scope = $2 AND scope_id = $3 AND deleted_at IS NULL", [ReplyTo, Scope, ScopeId]) of
        {ok, [_]} -> true;
        _ -> false
    end.

is_conversation_member(Conn, Uid, Cid) ->
    case one(Conn, "SELECT user_id FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

conversation_can_send(Conn, Uid, Cid) ->
    case one(Conn, "SELECT request_state FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]) of
        {ok, [<<"accepted">>]} ->
            not is_blocked_in_conversation(Conn, Uid, Cid);
        _ -> false
    end.

is_blocked_in_conversation(Conn, Uid, Cid) ->
    case one(Conn, "SELECT dm2.user_id FROM direct_members dm1 "
                   "JOIN direct_members dm2 ON dm2.thread_id = dm1.thread_id AND dm2.user_id <> dm1.user_id "
                   "JOIN friendships f ON (f.user_low = LEAST(dm1.user_id, dm2.user_id) AND f.user_high = GREATEST(dm1.user_id, dm2.user_id)) "
                   "WHERE dm1.thread_id = $1 AND dm1.user_id = $2 AND f.status = 'blocked'", [Cid, Uid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

is_conversation_owner(Conn, Uid, Cid) ->
    case one(Conn, "SELECT owner_id FROM direct_threads WHERE id = $1 AND owner_id = $2", [Cid, Uid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

conversation_role0(Conn, Uid, Cid) ->
    case one(Conn, "SELECT group_role FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]) of
        {ok, [<<"owner">>]} -> owner;
        {ok, [<<"moderator">>]} -> moderator;
        {ok, [_]} -> member;
        _ -> none
    end.

conversation_can_manage_members(Conn, Uid, Cid) ->
    case conversation_role0(Conn, Uid, Cid) of
        owner -> true;
        moderator -> true;
        _ -> false
    end.

best_effort_thread_notifications(Conn, Tid, Sender, Body, Now) ->
    try notify_thread_participants(Conn, Tid, Sender, Body, Now) of
        _ -> ok
    catch
        C:R:S ->
            error_logger:error_msg("thread notification failure ~p:~p ~p tid=~p sender=~p~n", [C,R,S,Tid,Sender]),
            ok
    end.

notify_thread_participants(Conn, Tid, Sender, Body, Now) ->
    {ok, Rows} = rows(Conn,
        "SELECT DISTINCT p.user_id FROM (SELECT user_id FROM threads WHERE id = $1 "
        "UNION SELECT user_id FROM replies WHERE thread_id = $1) p "
        "JOIN threads t ON t.id = $1 JOIN forum_members fm ON fm.forum_id = t.forum_id AND fm.user_id = p.user_id "
        "WHERE p.user_id <> $2",
        [Tid, Sender]),
    {ok, Roster} = rows(Conn,
        "SELECT DISTINCT u.id, u.username FROM users u JOIN "
        "(SELECT user_id FROM threads WHERE id = $1 UNION SELECT user_id FROM replies WHERE thread_id = $1) p "
        "ON u.id = p.user_id JOIN threads t ON t.id = $1 "
        "JOIN forum_members fm ON fm.forum_id = t.forum_id AND fm.user_id = u.id WHERE u.id <> $2",
        [Tid, Sender]),
    Mentioned = pw_mention:resolve(Body, Roster),
    Url = <<"#/t/", (integer_to_binary(Tid))/binary>>,
    Snippet = pw_util:clean_text(Body, 140),
    [begin
         U = only_id(R),
         case lists:member(U, Mentioned) of
             true ->
                 notify_mention(Conn, U, Body, Url,
                     #{type => mention, scope => thread, thread_id => Tid, body => Snippet}, Now);
             false ->
                 create_notification(Conn, U, <<"thread_reply">>, Snippet, Url, Now),
                 pw_hub:notify_user(U, #{type => thread_reply, thread_id => Tid})
         end
     end || R <- Rows],
    ok.

notify_mention(Conn, Uid, Body, Url, Event, Now) ->
    create_notification(Conn, Uid, <<"mention">>, pw_util:clean_text(Body, 180), Url, Now),
    pw_hub:notify_user(Uid, Event).

notify_channel_members(Conn, Sid, Sender, Cid, Msg, Now, SuppressMentions) ->
    Body = maps:get(body, Msg),
    {ok, MemberRows} = rows(Conn, "SELECT user_id FROM server_members WHERE server_id = $1 AND user_id <> $2", [Sid, Sender]),
    %% Notifications carry message bodies, so recipient selection is an
    %% authorization boundary too. Never leak a hidden channel through a toast,
    %% mention, or notification row after role/default-permission changes.
    Rows = [R || R <- MemberRows,
        has_server_permission(Conn, only_id(R), Sid, <<"view_channels">>)],
    VisibleIds = [only_id(R) || R <- Rows],
    {ok, AllRoster} = rows(Conn,
        "SELECT u.id, u.username FROM users u JOIN server_members sm ON sm.user_id = u.id "
        "WHERE sm.server_id = $1 AND u.id <> $2", [Sid, Sender]),
    Roster = [R || R = [MemberId, _] <- AllRoster, lists:member(MemberId, VisibleIds)],
    DirectMentioned = case SuppressMentions of true -> []; false -> pw_mention:resolve(Body, Roster) end,
    ServerWideMention = (not SuppressMentions) andalso
        has_server_permission(Conn, Sender, Sid, <<"mention_everyone">>) andalso
        has_server_wide_mention(Body),
    Mentioned = case ServerWideMention of
        true -> [only_id(R) || R <- Rows];
        false -> DirectMentioned
    end,
    Url = <<"#/channel/", (integer_to_binary(Cid))/binary>>,
    [begin
         U = only_id(R),
         case lists:member(U, Mentioned) of
             true ->
                 notify_mention(Conn, U, Body, Url,
                     #{type => mention, scope => channel, scope_id => Cid, channel_id => Cid, message => Msg}, Now);
             false ->
                 create_notification(Conn, U, <<"channel_message">>, Body, Url, Now),
                 pw_hub:notify_user(U, #{type => channel_message, channel_id => Cid, message => Msg})
         end
     end || R <- Rows],
    ok.

has_server_wide_mention(Body0) ->
    Body = pw_mention:strip_fences(pw_util:bin(Body0)),
    case re:run(Body, <<"(?:^|[^A-Za-z0-9_.-])@(everyone|here)(?:$|[^A-Za-z0-9_.-])">>, [caseless]) of
        {match, _} -> true;
        nomatch -> false
    end.

%% server chrome changes go to every member, whatever page they're on.
publish_server_event(Conn, Sid, Event) ->
    ok = maybe_queue_server_event(Conn, Sid, Event),
    ok = maybe_enqueue_server_webhook_event(Conn, Sid, Event),
    case rows(Conn, "SELECT user_id FROM server_members WHERE server_id = $1", [Sid]) of
        {ok, Members} ->
            [pw_hub:notify_user(only_id(Row), Event) || Row <- Members],
            ok;
        _ ->
            ok
    end.

maybe_enqueue_server_webhook_event(Conn, Sid, Event) ->
    Type = maps:get(type, Event, undefined),
    WebhookType = case Type of
        member_joined -> <<"member.joined">>;
        server_member_removed -> <<"member.removed">>;
        server_updated -> <<"server.updated">>;
        _ -> undefined
    end,
    case WebhookType of
        undefined -> ok;
        _ -> enqueue_server_webhooks(Conn, Sid, WebhookType, maps:remove(type, Event))
    end.

maybe_queue_server_event(Conn, Sid, Event) ->
    case pw_scylla_config:enabled() andalso durable_server_event(maps:get(type, Event, undefined)) of
        false -> ok;
        true ->
            Type = maps:get(type, Event),
            EntityId = event_entity_id(Event),
            case optional_storage_event_id() of
                {ok, EventId} ->
                    Stored = Event#{event_id => EventId, type => Type, scope => <<"server">>, scope_id => Sid,
                                    server_id => Sid, entity_id => EntityId, timestamp => pw_util:now_ms()},
                    ok = enqueue_storage_outbox(Conn, <<"message.event">>, EntityId, Stored),
                    enqueue_storage_outbox(Conn, <<"audit.event">>, EntityId, Stored);
                {error, _} -> ok
            end
    end.

maybe_queue_reaction_event(Conn, Scope, ScopeId, Mid, ActorId, Emoji, Added) ->
    case pw_scylla_config:enabled() of
        false -> ok;
        true ->
            Type = case Added of true -> <<"reaction.added">>; false -> <<"reaction.removed">> end,
            case optional_storage_event_id() of
                {ok, EventId} ->
                    Event = #{event_id => EventId, type => Type, scope => Scope, scope_id => ScopeId,
                              actor_id => ActorId, entity_id => Mid, timestamp => pw_util:now_ms(), emoji => Emoji},
                    enqueue_storage_outbox(Conn, <<"message.event">>, Mid, Event);
                {error, _} -> ok
            end
    end.

durable_server_event(member_joined) -> true;
durable_server_event(server_member_removed) -> true;
durable_server_event(server_member_roles_updated) -> true;
durable_server_event(server_roles_updated) -> true;
durable_server_event(channel_created) -> true;
durable_server_event(channel_updated) -> true;
durable_server_event(channel_deleted) -> true;
durable_server_event(channel_moved) -> true;
durable_server_event(category_created) -> true;
durable_server_event(category_updated) -> true;
durable_server_event(category_deleted) -> true;
durable_server_event(bot_added) -> true;
durable_server_event(bot_removed) -> true;
durable_server_event(_) -> false.

event_entity_id(Event) ->
    Candidates = [channel_id, user_id, role_id, bot_user_id, category_id, server_id],
    event_entity_id(Candidates, Event).
event_entity_id([], _Event) -> 0;
event_entity_id([K|Rest], Event) ->
    case maps:get(K, Event, undefined) of
        I when is_integer(I), I > 0 -> I;
        _ -> event_entity_id(Rest, Event)
    end.

%% group housekeeping, without pretending a message arrived.
publish_conversation_event(Conn, Cid, Event) ->
    case rows(Conn, "SELECT user_id FROM direct_members WHERE thread_id = $1", [Cid]) of
        {ok, Members} ->
            [pw_hub:notify_user(only_id(Row), Event) || Row <- Members],
            ok;
        _ ->
            ok
    end.

message_broadcast_key(<<"direct">>, ScopeId) -> {direct, ScopeId};
message_broadcast_key(<<"channel">>, ScopeId) -> {channel, ScopeId}.


best_effort_reaction_notification(_Conn, AuthorUid, ReactorUid, _ReactorName, _Mid, _Emoji, _Scope, _ScopeId, _Added)
  when AuthorUid =:= ReactorUid ->
    ok;
best_effort_reaction_notification(_Conn, _AuthorUid, _ReactorUid, _ReactorName, _Mid, _Emoji, _Scope, _ScopeId, false) ->
    ok;
best_effort_reaction_notification(Conn, AuthorUid, ReactorUid, ReactorName, Mid, Emoji, Scope, ScopeId, true) ->
    %% Reactions are lightweight and reversible. Keep the notification useful
    %% without allowing add/remove loops to flood somebody's activity inbox.
    case can_read_messages(Conn, AuthorUid, Scope, ScopeId)
         andalso pw_rate:allow({reaction_notify, ReactorUid, AuthorUid, Mid}, 3, 300000) of
        false -> ok;
        true ->
            try
                Url = case Scope of
                    <<"direct">> -> <<"#/dm/", (integer_to_binary(ScopeId))/binary>>;
                    <<"channel">> -> <<"#/channel/", (integer_to_binary(ScopeId))/binary>>
                end,
                Body = <<ReactorName/binary, " reacted ", Emoji/binary, " to your message">>,
                Now = pw_util:now_ms(),
                create_notification(Conn, AuthorUid, <<"message_reaction">>, Body, Url, Now),
                pw_hub:notify_user(AuthorUid, #{type => notification, kind => message_reaction,
                    body => pw_util:clean_text(Body, 180), url => Url, message_id => Mid,
                    emoji => Emoji, reactor_user_id => ReactorUid}),
                ok
            catch C:R:S ->
                error_logger:error_msg("reaction notification failure ~p:~p ~p author=~p reactor=~p message=~p~n",
                    [C,R,S,AuthorUid,ReactorUid,Mid]),
                ok
            end
    end.

best_effort_user_notification(Conn, Uid, Kind, Body, Url, Now, Event) ->
    try
        create_notification(Conn, Uid, Kind, Body, Url, Now),
        pw_hub:notify_user(Uid, Event),
        ok
    catch C:R:S ->
        error_logger:error_msg("user notification failure ~p:~p ~p uid=~p kind=~p~n", [C,R,S,Uid,Kind]),
        ok
    end.

best_effort_channel_notifications(Conn, Sid, Sender, Cid, Msg, Now, SuppressMentions) ->
    try notify_channel_members(Conn, Sid, Sender, Cid, Msg, Now, SuppressMentions) of
        _ -> ok
    catch C:R:S ->
        error_logger:error_msg("channel notification failure ~p:~p ~p sid=~p cid=~p sender=~p~n", [C,R,S,Sid,Cid,Sender]),
        ok
    end.

best_effort_direct_notifications(Conn, Cid, Sender, Event, Now, SuppressMentions) ->
    try notify_direct_members(Conn, Cid, Sender, Event, Now, SuppressMentions) of
        _ -> ok
    catch C:R:S ->
        error_logger:error_msg("direct notification failure ~p:~p ~p cid=~p sender=~p~n", [C,R,S,Cid,Sender]),
        ok
    end.

best_effort_missed_call_notifications(Conn, Cid, Caller, Msg, Now) ->
    try notify_missed_call_members(Conn, Cid, Caller, Msg, Now) of
        _ -> ok
    catch C:R:S ->
        error_logger:error_msg("missed-call notification failure ~p:~p ~p cid=~p caller=~p~n", [C,R,S,Cid,Caller]),
        ok
    end.

notify_direct_members(Conn, Cid, Sender, Event, Now, SuppressMentions) ->
    Msg = maps:get(message, Event, #{}),
    PlainBody = maps:get(body, Msg, <<>>),
    {ok, Rows} = rows(Conn, "SELECT user_id, request_state FROM direct_members WHERE thread_id = $1 AND user_id <> $2 AND muted = false", [Cid, Sender]),
    {ok, Roster} = rows(Conn,
        "SELECT u.id, u.username FROM users u JOIN direct_members dm ON dm.user_id = u.id "
        "WHERE dm.thread_id = $1 AND dm.request_state = 'accepted' AND u.id <> $2", [Cid, Sender]),
    Mentioned = case SuppressMentions of true -> []; false -> pw_mention:resolve(PlainBody, Roster) end,
    Url = <<"#/dm/", (integer_to_binary(Cid))/binary>>,
    [begin
         [U, RequestState] = R,
         EventType = maps:get(type, Event, direct_message),
         case {EventType, RequestState, lists:member(U, Mentioned)} of
             {direct_message, <<"pending">>, _} ->
                 create_notification_once(Conn, U, <<"message_request">>, <<"New message request">>, <<"#/dms">>, Now),
                 pw_hub:notify_user(U, Event);
             {direct_message, <<"accepted">>, true} ->
                 notify_mention(Conn, U, PlainBody, Url,
                     #{type => mention, scope => direct, scope_id => Cid, conversation_id => Cid, message => Msg}, Now);
             {direct_message, _, _} ->
                 create_notification(Conn, U, <<"direct_message">>, <<"New direct message">>, Url, Now),
                 pw_hub:notify_user(U, Event);
             {message_request, _, _} ->
                 create_notification_once(Conn, U, <<"message_request">>, <<"New message request">>, <<"#/dms">>, Now),
                 pw_hub:notify_user(U, Event);
             {message_request_accepted, _, _} ->
                 create_notification(Conn, U, <<"message_request_accepted">>, <<"Message request accepted">>, Url, Now),
                 pw_hub:notify_user(U, Event);
             {conversation_closed, _, _} ->
                 create_notification(Conn, U, <<"conversation_closed">>, <<"Message request declined">>, <<"#/dms">>, Now),
                 pw_hub:notify_user(U, Event);
             {conversation_created, _, _} ->
                 create_notification(Conn, U, <<"conversation_created">>, <<"New conversation">>, Url, Now),
                 pw_hub:notify_user(U, Event)
         end
     end || R <- Rows],
    ok.

notify_missed_call_members(Conn, Cid, Caller, Msg, Now) ->
    {ok, Rows} = rows(Conn,
        "SELECT user_id FROM direct_members WHERE thread_id = $1 AND user_id <> $2 "
        "AND request_state = 'accepted'", [Cid, Caller]),
    Name = maps:get(display_name, Msg, <<"Someone">>),
    Url = <<"#/dm/", (integer_to_binary(Cid))/binary>>,
    [begin
         U = only_id(R),
         create_notification(Conn, U, <<"missed_call">>, <<"Missed call from ", Name/binary>>, Url, Now),
         pw_hub:notify_user(U, #{type => direct_message, conversation_id => Cid, message => Msg})
     end || R <- Rows],
    ok.

create_notification(Conn, U, K, B, Url, Now) ->
    ok = exec(Conn, "INSERT INTO notifications(user_id, kind, body, url, seen, created_at) VALUES($1,$2,$3,$4,false,$5)",
        [U, K, pw_util:clean_text(B, 180), Url, Now]).

create_notification_once(Conn, U, K, B, Url, Now) ->
    case one(Conn, "SELECT id FROM notifications WHERE user_id = $1 AND kind = $2 AND url = $3 AND seen = false LIMIT 1", [U, K, Url]) of
        {ok, [_]} -> ok;
        _ -> create_notification(Conn, U, K, B, Url, Now)
    end.

mark_url_seen0(Conn, Uid, Url) ->
    _ = exec(Conn, "UPDATE notifications SET seen = true WHERE user_id = $1 AND url = $2", [Uid, Url]),
    ok.

record_thread_view(_Conn, undefined, _Uid) -> ok;
record_thread_view(Conn, ThreadId, Uid) ->
    %% one statement + primary key = refreshes don't count twice.
    exec(Conn,
        "WITH existing AS (SELECT id FROM threads WHERE id = $1), "
        "inserted AS (INSERT INTO thread_views(thread_id,user_id,first_viewed_at) "
        "SELECT id,$2,$3 FROM existing ON CONFLICT DO NOTHING RETURNING 1) "
        "UPDATE threads SET views = views + (SELECT count(*) FROM inserted) WHERE id = $1",
        [ThreadId, Uid, pw_util:now_ms()]).

seed_forums(Conn) ->
    case rows(Conn, "SELECT count(*) FROM forums", []) of
        {ok, [[C]]} when C =:= 0; C =:= <<"0">> ->
            Fs = [{<<"general">>, <<"General">>, <<"General forum discussion and project notes.">>, 1},
                  {<<"support">>, <<"Support">>, <<"Errors, logs, drivers, packages, services.">>, 2},
                  {<<"development">>, <<"Development">>, <<"Programming, systems, tooling, and releases.">>, 3},
                  {<<"security">>, <<"Security">>, <<"Hardening, auth, permissions, and incident notes.">>, 4}],
            [exec(Conn, "INSERT INTO forums(slug, name, description, position) VALUES($1,$2,$3,$4)", [S, N, D, P]) || {S, N, D, P} <- Fs],
            ok;
        _ ->
            ok
    end.

maybe_expire_account_restriction(Conn, Uid, State, ExpiresAt, Now)
  when (State =:= <<"suspended">> orelse State =:= <<"banned">>), is_integer(ExpiresAt), ExpiresAt > 0, ExpiresAt =< Now ->
    ok = exec(Conn,
        "UPDATE users SET account_state='active',moderation_title='',moderation_reason='',moderation_severity='warning',moderation_expires_at=0,moderated_by=NULL,moderated_at=$2,updated_at=$2 WHERE id=$1",
        [Uid, Now]),
    ok = exec(Conn,
        "INSERT INTO instance_account_actions(user_id,actor_user_id,action,title,reason,severity,expires_at,created_at) VALUES($1,NULL,'restore','Automatic restoration','Restriction expired','info',0,$2)",
        [Uid, Now]),
    {<<"active">>, true};
maybe_expire_account_restriction(_Conn, _Uid, State, _ExpiresAt, _Now) -> {State, false}.

verify_admin_user(Conn, Username, Password) ->
    case one(Conn,
        "SELECT id,username,display_name,password_hash,password_salt FROM users WHERE username=$1 AND account_state='active' FOR UPDATE",
        [Username]) of
        {ok, [Uid, StoredUsername, DisplayName, PasswordHash, Salt]} ->
            case pw_util:verify_password(Password, Salt, PasswordHash) of
                true ->
                    maybe_upgrade_password_hash(Conn, Uid, Password, PasswordHash),
                    {ok, Uid, StoredUsername, DisplayName};
                false -> {error, bad_login}
            end;
        _ ->
            _ = pw_util:pbkdf2(Password, <<"plainwire-admin-user-timing-pad">>),
            {error, bad_login}
    end.

normalize_admin_role(<<"owner">>) -> <<"owner">>;
normalize_admin_role(<<"operator">>) -> <<"operator">>;
normalize_admin_role(<<"viewer">>) -> <<"viewer">>;
normalize_admin_role(owner) -> <<"owner">>;
normalize_admin_role(operator) -> <<"operator">>;
normalize_admin_role(viewer) -> <<"viewer">>;
normalize_admin_role(_) -> undefined.

admin_actor_role(Conn, Uid) ->
    case one(Conn, "SELECT role FROM admin_operators WHERE user_id=$1", [Uid]) of
        {ok, [Role]} -> Role;
        _ -> undefined
    end.

can_change_owner(Conn, <<"owner">>, NewRole) when NewRole =/= <<"owner">> ->
    admin_owner_count(Conn) > 1;
can_change_owner(_Conn, _CurrentRole, _NewRole) -> true.

can_remove_owner(Conn, <<"owner">>) -> admin_owner_count(Conn) > 1;
can_remove_owner(_Conn, _Role) -> true.

admin_owner_count(Conn) ->
    case one(Conn, "SELECT count(*) FROM admin_operators WHERE role='owner'", []) of
        {ok, [N]} -> N;
        _ -> 0
    end.

new_message_id() ->
    case pw_message_id:next() of
        {ok, Id} -> Id;
        {error, Reason} -> throw({plainwire_error, {message_id_unavailable, Reason}})
    end.

storage_after_message_change(Conn, Mid, EventType, ActorId) ->
    case message_core(Conn, Mid) of
        {ok, Msg} ->
            ok = sync_message_search_index(Conn, Msg),
            EventId = required_storage_event_id(),
            Event = #{event_id => EventId, type => EventType, scope => maps:get(scope, Msg),
                      scope_id => maps:get(scope_id, Msg), actor_id => ActorId, entity_id => Mid,
                      timestamp => pw_util:now_ms()},
            case pw_scylla_config:backend() of
                postgres -> ok;
                dual ->
                    ok = enqueue_storage_outbox(Conn, <<"message.upsert">>, Mid, Msg),
                    ok = enqueue_storage_outbox(Conn, <<"message.event">>, Mid, Event),
                    ok;
                scylla ->
                    Prior = storage_prior_scylla_state(EventType, Mid),
                    case pw_message_store_scylla:transactional_upsert(Msg) of
                        {ok, Intent} ->
                            register_storage_compensation(Mid, Prior, Intent),
                            register_tx_after_commit(fun() -> pw_message_store_scylla:complete_transactional_upsert(Intent) end),
                            ok = enqueue_storage_outbox(Conn, <<"message.event">>, Mid, Event),
                            ok;
                        {error, Reason} -> throw({plainwire_error, {storage_unavailable, Reason}});
                        Other -> throw({plainwire_error, {storage_unavailable, Other}})
                    end
            end;
        {error, Reason} -> throw({plainwire_error, {storage_message_missing, Reason}})
    end.

storage_prior_scylla_state(<<"message.created">>, _Mid) -> absent;
storage_prior_scylla_state(_EventType, Mid) ->
    case pw_message_store_scylla:get(Mid) of
        {ok, Prior} -> {present, Prior};
        {error, not_found} -> absent;
        {error, Reason} -> throw({plainwire_error, {storage_unavailable, Reason}});
        Other -> throw({plainwire_error, {storage_unavailable, Other}})
    end.

register_storage_compensation(Mid, absent, Intent) ->
    register_tx_compensation(fun() ->
        case pw_message_store_scylla:hard_delete(Mid) of
            ok -> pw_message_store_scylla:complete_transactional_upsert(Intent);
            Error -> Error
        end
    end);
register_storage_compensation(_Mid, {present, Prior}, Intent) ->
    register_tx_compensation(fun() ->
        case pw_message_store_scylla:insert(Prior) of
            ok -> pw_message_store_scylla:complete_transactional_upsert(Intent);
            Error -> Error
        end
    end).

message_core(Conn, Mid) ->
    case one(Conn,
        "SELECT id,scope,scope_id,user_id,body,COALESCE(reply_to_id,0),created_at,COALESCE(edited_at,0),COALESCE(deleted_at,0),kind,COALESCE(forwarded_from_id,0) FROM messages WHERE id=$1",
        [Mid]) of
        {ok, Row} when is_list(Row) -> {ok, message_core_map(Row)};
        _ -> {error, not_found}
    end.

enqueue_storage_outbox(Conn, Kind, EntityId, Payload) ->
    Now = pw_util:now_ms(),
    Safe = term_to_binary(Payload, [compressed]),
    ok = validate_storage_outbox_payload(Safe),
    %% Once work is queued for Scylla, remember durably that this PostgreSQL
    %% instance may have data in an external Scylla cluster. Privacy erasure
    %% must keep queuing hard-deletes after an operator rolls back to PostgreSQL
    %% and temporarily disables Scylla; otherwise dormant Scylla rows could be
    %% stranded forever. Instances that have never used Scylla never set this.
    ok = mark_scylla_seen(Conn, Now),
    ok = exec(Conn,
        "INSERT INTO storage_outbox(kind,entity_id,payload,status,attempts,next_attempt_at,locked_at,last_error,created_at,updated_at) "
        "VALUES($1,$2,$3,'pending',0,$4,0,'',$4,$4)", [Kind,EntityId,Safe,Now]),
    ok.


validate_storage_outbox_payload(Bin) when is_binary(Bin), byte_size(Bin) =< 2097152 ->
    case Bin of
        <<131, 80, Size:32/unsigned-big, _/binary>> when Size > 8388608 ->
            erlang:error(storage_outbox_payload_too_large);
        _ -> ok
    end;
validate_storage_outbox_payload(_) ->
    erlang:error(storage_outbox_payload_too_large).

queue_server_storage_event(Conn, Type, Sid, EntityId, ActorId, Payload0, Now) ->
    case pw_scylla_config:enabled() of
        false -> ok;
        true ->
            case optional_storage_event_id() of
                {ok, EventId} ->
                    Payload = Payload0#{server_id => Sid, user_id => EntityId},
                    Event = #{event_id => EventId, type => Type, server_id => Sid, scope => <<"server">>, scope_id => Sid,
                              actor_id => ActorId, entity_id => EntityId, timestamp => Now, payload => Payload},
                    enqueue_storage_outbox(Conn, <<"audit.event">>, Sid, Event);
                {error, _} -> ok
            end
    end.

message_core_map([Id,Scope,ScopeId,UserId,Body,Reply,Created,Edited,Deleted,Kind,Forwarded]) ->
    #{id => Id, scope => Scope, scope_id => ScopeId, user_id => UserId, body => Body, reply_to_id => zero_undefined(Reply),
      created_at => Created, edited_at => zero_undefined(Edited), deleted_at => zero_undefined(Deleted),
      kind => Kind, forwarded_from_id => zero_undefined(Forwarded)}.

zero_undefined(0) -> undefined;
zero_undefined(null) -> undefined;
zero_undefined(V) -> V.

storage_pg_timeline(Conn, Scope0, ScopeId0, Mode, Cursor0, Limit0) ->
    Scope = normalize_storage_scope(Scope0),
    ScopeId = pw_util:int(ScopeId0),
    Limit = min(250, max(1, case pw_util:int(Limit0) of undefined -> 80; L -> L end)),
    Cursor = pw_util:int(Cursor0),
    case {Scope, ScopeId, Mode, Cursor} of
        {invalid, _, _, _} -> {error, bad_request};
        {_, Sid, _, _} when not is_integer(Sid); Sid =< 0 -> {error, bad_request};
        {S, Sid, recent, _} -> storage_pg_timeline_query(Conn, S, Sid, "", [], "DESC", Limit);
        {S, Sid, before, C} when is_integer(C), C > 0 -> storage_pg_timeline_query(Conn, S, Sid, " AND id < $3", [C], "DESC", Limit);
        {S, Sid, 'after', C} when is_integer(C), C > 0 -> storage_pg_timeline_query(Conn, S, Sid, " AND id > $3", [C], "ASC", Limit);
        _ -> {error, bad_request}
    end.

storage_pg_timeline_query(Conn, Scope, ScopeId, CursorSql, CursorParams, Order, Limit) ->
    LimitPos = 3 + length(CursorParams),
    Sql = "SELECT id,scope,scope_id,user_id,body,COALESCE(reply_to_id,0),created_at,COALESCE(edited_at,0),COALESCE(deleted_at,0),kind,COALESCE(forwarded_from_id,0) "
          "FROM messages WHERE scope=$1 AND scope_id=$2 AND deleted_at IS NULL" ++ CursorSql ++
          " ORDER BY id " ++ Order ++ " LIMIT $" ++ integer_to_list(LimitPos),
    case rows(Conn, Sql, [Scope, ScopeId] ++ CursorParams ++ [Limit]) of
        {ok, Rs} -> {ok, [message_core_map(R) || R <- Rs]};
        Error -> Error
    end.

normalize_storage_scope(<<"channel">>) -> <<"channel">>;
normalize_storage_scope(<<"direct">>) -> <<"direct">>;
normalize_storage_scope(channel) -> <<"channel">>;
normalize_storage_scope(direct) -> <<"direct">>;
normalize_storage_scope(_) -> invalid.

normalize_list(V) when is_list(V) -> V;
normalize_list(_) -> [].

storage_retry_delay_ms(Attempts) ->
    Base = min(300000, 1000 bsl min(8, max(0, Attempts - 1))),
    Base + rand:uniform(max(1, Base div 5)).

maybe_queue_admin_server_audit(Conn, ActorUid, Action, TargetType, TargetId, Detail, Now) ->
    case {pw_scylla_config:enabled(), TargetType, pw_util:int(TargetId)} of
        {true, <<"server">>, Sid} when is_integer(Sid), Sid > 0 ->
            case optional_storage_event_id() of
                {ok, EventId} ->
                    Event = #{event_id => EventId, type => Action, server_id => Sid, scope => <<"server">>,
                              scope_id => Sid, actor_id => ActorUid, entity_id => Sid, timestamp => Now,
                              detail => Detail},
                    enqueue_storage_outbox(Conn, <<"audit.event">>, Sid, Event);
                {error, _} -> ok
            end;
        _ -> ok
    end.

required_storage_event_id() ->
    case pw_message_id:next() of
        {ok, Id} -> Id;
        {error, Reason} -> throw({plainwire_error, {event_id_unavailable, Reason}})
    end.

optional_storage_event_id() ->
    case pw_message_id:next() of
        {ok, Id} -> {ok, Id};
        {error, Reason} ->
            pw_storage_metrics:incr(storage_event_id_unavailable),
            logger:warning("[plainwire:storage] durable auxiliary event skipped reason=~p", [Reason]),
            {error, Reason}
    end.

normalize_webhook_finish_result({ok, Code, Latency}) -> {{ok, Code}, clamp_latency(Latency)};
normalize_webhook_finish_result({error, Reason, Latency}) -> {{error, Reason}, clamp_latency(Latency)};
normalize_webhook_finish_result(Result) -> {Result, 0}.

clamp_latency(N) when is_integer(N), N >= 0 -> min(N, 3600000);
clamp_latency(_) -> 0.

maybe_queue_webhook_delivery_event(Conn, WebhookId, DeliveryId, Attempts, Status, HttpCode, LatencyMs, Reason, Now) ->
    case pw_scylla_config:enabled() of
        false -> ok;
        true ->
            case one(Conn, "SELECT server_id FROM server_webhooks WHERE id=$1", [WebhookId]) of
                {ok, [Sid]} when is_integer(Sid), Sid > 0 ->
                    case optional_storage_event_id() of
                        {ok, EventId} ->
                            Event = #{event_id => EventId, server_id => Sid, timestamp => Now,
                                      target_type => <<"webhook">>, target_id => WebhookId,
                                      delivery_id => DeliveryId, status => Status, http_status => HttpCode,
                                      attempt => Attempts, latency_ms => LatencyMs,
                                      error_code => pw_util:clean_text(Reason, 96)},
                            enqueue_storage_outbox(Conn, <<"delivery.event">>, DeliveryId, Event);
                        {error, _} -> ok
                    end;
                _ -> ok
            end
    end.

storage_health_summary() ->
    Redis0 = pw_redis:stats(),
    RedisStatus = case {maps:get(enabled, Redis0, false), maps:get(connected, Redis0, false)} of
        {false, _} -> disabled;
        {true, true} -> healthy;
        {true, false} -> degraded
    end,
    Scylla0 = pw_scylla:health(),
    #{postgresql => #{status => healthy},
      redis => Redis0#{status => RedisStatus},
      scylla => Scylla0}.

admin_audit_insert(Conn, ActorUid, Action, TargetType, TargetId, Detail, IpHash, Now) ->
    ok = exec(Conn,
        "INSERT INTO admin_audit(actor_user_id,action,target_type,target_id,detail,ip_hash,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)",
        [ActorUid, Action, TargetType, TargetId, Detail, IpHash, Now]).

clamp_page_limit(Value) ->
    case pw_util:int(Value) of
        undefined -> 50;
        N -> min(100, max(1, N))
    end.

clamp_offset(Value) ->
    case pw_util:int(Value) of
        undefined -> 0;
        N -> min(1000000, max(0, N))
    end.

admin_user_summary([Uid, Username, DisplayName, CreatedAt, LastSeen, Servers, Conversations, ActiveSessions, UploadBytes,
                    AccountState, IsBot, ModerationExpiresAt]) ->
    #{id => Uid, username => Username, display_name => DisplayName, created_at => CreatedAt, last_seen => LastSeen,
      server_count => Servers, conversation_count => Conversations, active_sessions => ActiveSessions, upload_bytes => UploadBytes,
      account_state => AccountState, is_bot => IsBot, moderation_expires_at => ModerationExpiresAt}.

admin_user_detail([Uid, Username, DisplayName, CreatedAt, UpdatedAt, LastSeen, Servers, OwnedServers,
                   Conversations, Messages, Uploads, UploadBytes, ActiveSessions, AccountState, IsBot,
                   Title, Reason, Severity, ExpiresAt, ModeratedBy, ModeratedAt]) ->
    #{id => Uid, username => Username, display_name => DisplayName, created_at => CreatedAt, updated_at => UpdatedAt,
      last_seen => LastSeen, server_count => Servers, owned_server_count => OwnedServers,
      conversation_count => Conversations, message_count => Messages, upload_count => Uploads,
      upload_bytes => UploadBytes, active_sessions => ActiveSessions, account_state => AccountState, is_bot => IsBot,
      moderation => moderation_public_map(AccountState, Title, Reason, Severity, ExpiresAt, ModeratedBy, ModeratedAt)}.

admin_server_summary([Sid, Name, CreatedAt, UpdatedAt, OwnerId, OwnerUsername, OwnerDisplayName, Members, Channels]) ->
    #{id => Sid, name => Name, created_at => CreatedAt, updated_at => UpdatedAt,
      owner => #{id => OwnerId, username => OwnerUsername, display_name => OwnerDisplayName},
      member_count => Members, channel_count => Channels}.

admin_server_detail([Sid, Name, CreatedAt, UpdatedAt, OwnerId, OwnerUsername, OwnerDisplayName,
                     Members, Channels, Roles, Invites, Messages, LastMessageAt]) ->
    #{id => Sid, name => Name, created_at => CreatedAt, updated_at => UpdatedAt,
      owner => #{id => OwnerId, username => OwnerUsername, display_name => OwnerDisplayName},
      member_count => Members, channel_count => Channels, role_count => Roles,
      active_invite_count => Invites, message_count => Messages, last_message_at => LastMessageAt}.


admin_can_inspect_user(Conn, ActorUid, TargetUid) ->
    is_integer(TargetUid) andalso TargetUid > 0 andalso
    case admin_actor_role(Conn, ActorUid) of
        <<"owner">> -> true;
        <<"operator">> -> true;
        <<"viewer">> -> true;
        _ -> false
    end.

moderation_actor_allowed(_Conn, ActorUid, TargetUid) when ActorUid =:= TargetUid -> {error, cannot_moderate_self};
moderation_actor_allowed(Conn, ActorUid, TargetUid) ->
    ActorRole = admin_actor_role(Conn, ActorUid),
    TargetRole = admin_actor_role(Conn, TargetUid),
    case {ActorRole, TargetRole} of
        {<<"owner">>, <<"owner">>} -> {error, owner_protected};
        {<<"owner">>, _} -> ok;
        {<<"operator">>, undefined} -> ok;
        {<<"operator">>, _} -> {error, operator_protected};
        _ -> {error, forbidden}
    end.

normalize_instance_moderation_action(<<"suspend">>) -> suspend;
normalize_instance_moderation_action(<<"ban">>) -> ban;
normalize_instance_moderation_action(<<"restore">>) -> restore;
normalize_instance_moderation_action(suspend) -> suspend;
normalize_instance_moderation_action(ban) -> ban;
normalize_instance_moderation_action(restore) -> restore;
normalize_instance_moderation_action(_) -> invalid.

moderation_action_state(suspend) -> <<"suspended">>;
moderation_action_state(ban) -> <<"banned">>;
moderation_action_state(restore) -> <<"active">>.

normalize_instance_moderation_patch(_Patch0, restore) ->
    {ok, #{title => <<>>, reason => <<>>, severity => <<"warning">>, expires_at => 0}};
normalize_instance_moderation_patch(Patch0, Action) when is_map(Patch0) ->
    Patch = normalize_patch_keys(Patch0), Now = pw_util:now_ms(),
    DefaultTitle = case Action of suspend -> <<"Account suspended">>; ban -> <<"Account banned">> end,
    Title0 = pw_util:clean_text(maps:get(<<"title">>, Patch, DefaultTitle), 100),
    Title = case Title0 of <<>> -> DefaultTitle; _ -> Title0 end,
    Reason = pw_util:clean_text(maps:get(<<"reason">>, Patch, <<>>), 1000),
    Severity0 = pw_util:clean_text(maps:get(<<"severity">>, Patch, case Action of ban -> <<"critical">>; _ -> <<"warning">> end), 16),
    Severity = case Severity0 of <<"info">> -> <<"info">>; <<"warning">> -> <<"warning">>; <<"critical">> -> <<"critical">>; _ -> invalid end,
    Expires0 = pw_util:int(maps:get(<<"expires_at">>, Patch, 0)),
    ExpiresAt = case Expires0 of
        undefined -> 0;
        I when is_integer(I), I =:= 0 -> 0;
        I when is_integer(I), I > Now, I =< Now + 315360000000 -> I;
        _ -> invalid
    end,
    case {Severity, ExpiresAt, byte_size(Reason)} of
        {invalid, _, _} -> {error, invalid_severity};
        {_, invalid, _} -> {error, invalid_expiry};
        {_, _, 0} -> {error, moderation_reason_required};
        _ -> {ok, #{title => Title, reason => Reason, severity => Severity, expires_at => ExpiresAt}}
    end;
normalize_instance_moderation_patch(_, _) -> {error, invalid_moderation}.

moderation_public_map(State, Title, Reason, Severity, ExpiresAt, ModeratedBy, ModeratedAt) ->
    #{state => State, title => Title, reason => Reason, severity => Severity,
      expires_at => ExpiresAt, moderated_by => db_null(ModeratedBy), moderated_at => ModeratedAt}.

moderation_audit_detail(Action, Title, Reason, Severity, ExpiresAt) ->
    %% Audit detail is bounded operational metadata. It intentionally contains
    %% the moderation reason entered by the operator, never private user content.
    pw_util:clean_text(pw_util:json(#{action => atom_to_binary(Action, utf8), title => Title,
        reason => Reason, severity => Severity, expires_at => ExpiresAt}), 240).

admin_can_operate(Conn, ActorUid) ->
    case admin_actor_role(Conn, ActorUid) of
        <<"owner">> -> true;
        <<"operator">> -> true;
        _ -> false
    end.

banner_map([Id, Title, Body, Severity, StartsAt, EndsAt, Dismissible, LinkLabel, LinkUrl, UpdatedAt]) ->
    #{id => Id, title => Title, body => Body, severity => Severity, starts_at => StartsAt, ends_at => EndsAt,
      dismissible => Dismissible, link_label => LinkLabel, link_url => LinkUrl, updated_at => UpdatedAt}.

admin_banner_map([Id, Title, Body, Severity, StartsAt, EndsAt, Dismissible, LinkLabel, LinkUrl, Enabled,
                  CreatedBy, CreatedByUsername, CreatedAt, UpdatedAt]) ->
    Base = banner_map([Id, Title, Body, Severity, StartsAt, EndsAt, Dismissible, LinkLabel, LinkUrl, UpdatedAt]),
    Base#{enabled => Enabled, created_by => CreatedBy, created_by_username => CreatedByUsername, created_at => CreatedAt}.

banner_patch_from_row([Title, Body, Severity, StartsAt, EndsAt, Dismissible, LinkLabel, LinkUrl, Enabled]) ->
    #{<<"title">> => Title, <<"body">> => Body, <<"severity">> => Severity, <<"starts_at">> => StartsAt,
      <<"ends_at">> => EndsAt, <<"dismissible">> => Dismissible, <<"link_label">> => LinkLabel,
      <<"link_url">> => LinkUrl, <<"enabled">> => Enabled}.

normalize_patch_keys(Map) when is_map(Map) ->
    maps:from_list([{pw_util:bin(K), V} || {K, V} <- maps:to_list(Map)]);
normalize_patch_keys(_) -> #{}.

normalize_banner_patch(Patch0, Now) when is_map(Patch0), is_integer(Now), Now >= 0 ->
    Patch = normalize_patch_keys(Patch0),
    TitleResult = banner_text(Patch, <<"title">>, <<>>, 80),
    BodyResult = banner_text(Patch, <<"body">>, <<>>, 500),
    Severity = normalize_banner_severity(maps:get(<<"severity">>, Patch, <<"info">>)),
    StartResult = banner_time(Patch, <<"starts_at">>, Now),
    EndResult = banner_time(Patch, <<"ends_at">>, 0),
    DismissibleResult = banner_bool(Patch, <<"dismissible">>, true),
    EnabledResult = banner_bool(Patch, <<"enabled">>, true),
    LinkLabelResult = banner_text(Patch, <<"link_label">>, <<>>, 40),
    LinkUrlResult = banner_text(Patch, <<"link_url">>, <<>>, 512),
    case {TitleResult, BodyResult, Severity, StartResult, EndResult,
          DismissibleResult, EnabledResult, LinkLabelResult, LinkUrlResult} of
        {{ok, Title}, {ok, Body}, ValidSeverity, {ok, StartsAt}, {ok, EndsAt},
         {ok, Dismissible}, {ok, Enabled}, {ok, LinkLabel0}, {ok, LinkUrl0}}
          when ValidSeverity =/= invalid, byte_size(Body) > 0,
               (EndsAt =:= 0 orelse EndsAt > StartsAt) ->
            LinkUrl = safe_banner_link(LinkUrl0),
            case LinkUrl0 =:= <<>> orelse LinkUrl =/= <<>> of
                true ->
                    LinkLabel = case LinkUrl of <<>> -> <<>>; _ -> LinkLabel0 end,
                    {ok, #{title => Title, body => Body, severity => ValidSeverity,
                           starts_at => StartsAt, ends_at => EndsAt,
                           dismissible => Dismissible, link_label => LinkLabel,
                           link_url => LinkUrl, enabled => Enabled}};
                false -> {error, invalid_banner_link}
            end;
        {{error, text_type}, _, _, _, _, _, _, _, _} -> {error, invalid_banner};
        {_, {error, text_type}, _, _, _, _, _, _, _} -> {error, invalid_banner};
        {_, {ok, <<>>}, _, _, _, _, _, _, _} -> {error, invalid_banner};
        {_, _, invalid, _, _, _, _, _, _} -> {error, invalid_banner};
        {_, _, _, error, _, _, _, _, _} -> {error, invalid_banner_window};
        {_, _, _, _, error, _, _, _, _} -> {error, invalid_banner_window};
        {_, _, _, _, _, {error, bool_type}, _, _, _} -> {error, invalid_banner};
        {_, _, _, _, _, _, {error, bool_type}, _, _} -> {error, invalid_banner};
        {_, _, _, _, _, _, _, {error, text_type}, _} -> {error, invalid_banner_link};
        {_, _, _, _, _, _, _, _, {error, text_type}} -> {error, invalid_banner_link};
        _ -> {error, invalid_banner_window}
    end;
normalize_banner_patch(_, _) -> {error, invalid_banner}.

banner_text(Patch, Key, Default, Max) ->
    case maps:find(Key, Patch) of
        error -> {ok, pw_util:clean_text(Default, Max)};
        {ok, Value} when is_binary(Value) -> {ok, pw_util:clean_text(Value, Max)};
        {ok, _} -> {error, text_type}
    end.

banner_bool(Patch, Key, Default) ->
    case maps:find(Key, Patch) of
        error -> {ok, Default};
        {ok, true} -> {ok, true};
        {ok, false} -> {ok, false};
        {ok, _} -> {error, bool_type}
    end.

banner_time(Patch, Key, Default) ->
    case maps:find(Key, Patch) of
        error -> parse_banner_time(Default);
        {ok, Value} when is_integer(Value) -> parse_banner_time(Value);
        {ok, _} -> error
    end.

normalize_banner_severity(<<"info">>) -> <<"info">>;
normalize_banner_severity(<<"success">>) -> <<"success">>;
normalize_banner_severity(<<"warning">>) -> <<"warning">>;
normalize_banner_severity(<<"critical">>) -> <<"critical">>;
normalize_banner_severity(_) -> invalid.

parse_banner_time(Value) ->
    case pw_util:int(Value) of N when is_integer(N), N >= 0 -> {ok, N}; _ -> error end.

safe_banner_link(<<>>) -> <<>>;
safe_banner_link(<<"https://", Rest/binary>> = Url) when byte_size(Rest) > 0 -> Url;
safe_banner_link(<<"/", "/", _/binary>>) -> <<>>;
safe_banner_link(<<"/", _/binary>> = Url) -> Url;
safe_banner_link(_) -> <<>>.

banner_audit_detail(Banner) ->
    Severity = maps:get(severity, Banner, <<"info">>),
    EndsAt = maps:get(ends_at, Banner, 0),
    Enabled = maps:get(enabled, Banner, true),
    pw_util:clean_text(iolist_to_binary(io_lib:format("severity=~ts ends_at=~p enabled=~p", [Severity, EndsAt, Enabled])), 240).

normalize_registration_mode(<<"inherit">>) -> <<"inherit">>;
normalize_registration_mode(<<"enabled">>) -> <<"enabled">>;
normalize_registration_mode(<<"disabled">>) -> <<"disabled">>;
normalize_registration_mode(inherit) -> <<"inherit">>;
normalize_registration_mode(enabled) -> <<"enabled">>;
normalize_registration_mode(disabled) -> <<"disabled">>;
normalize_registration_mode(_) -> invalid.

mark_scylla_seen(Conn, Now) ->
    exec(Conn,
        "INSERT INTO storage_migration_checkpoints(name,last_id,rows_done,updated_at) VALUES('scylla_seen',0,1,$1) "
        "ON CONFLICT(name) DO UPDATE SET rows_done=1,updated_at=EXCLUDED.updated_at",
        [Now]).

scylla_may_have_data(Conn) ->
    case pw_scylla_config:enabled() of
        true -> true;
        false ->
            case one(Conn, "SELECT rows_done FROM storage_migration_checkpoints WHERE name='scylla_seen'", []) of
                {ok, [N]} when is_integer(N), N > 0 -> true;
                _ -> false
            end
    end.

enqueue_upload_delete_path(Conn, Path0) ->
    Path = pw_util:clean_text(Path0, 4096),
    case byte_size(Path) of
        0 -> ok;
        _ ->
            Now = pw_util:now_ms(),
            exec(Conn,
                "INSERT INTO upload_delete_queue(path,status,attempts,next_attempt_at,locked_at,last_error,created_at,updated_at) "
                "VALUES($1,'pending',0,$2,0,'',$2,$2) ON CONFLICT(path) DO UPDATE SET "
                "status='pending',next_attempt_at=LEAST(upload_delete_queue.next_attempt_at,EXCLUDED.next_attempt_at),locked_at=0,updated_at=EXCLUDED.updated_at",
                [Path, Now])
    end.

enqueue_upload_deletes_for_user(Conn, Uid) ->
    Now = pw_util:now_ms(),
    exec(Conn,
        "INSERT INTO upload_delete_queue(path,status,attempts,next_attempt_at,locked_at,last_error,created_at,updated_at) "
        "SELECT path,'pending',0,$2,0,'',$2,$2 FROM uploads WHERE user_id=$1 "
        "ON CONFLICT(path) DO UPDATE SET status='pending',next_attempt_at=LEAST(upload_delete_queue.next_attempt_at,EXCLUDED.next_attempt_at),locked_at=0,updated_at=EXCLUDED.updated_at",
        [Uid, Now]).

enqueue_scylla_hard_deletes_for_user(Conn, Uid) ->
    case scylla_may_have_data(Conn) of
        false -> ok;
        true ->
            Now = pw_util:now_ms(),
            exec(Conn,
                "INSERT INTO storage_outbox(kind,entity_id,payload,entity_scope,entity_scope_id,entity_created_at,status,attempts,next_attempt_at,locked_at,last_error,created_at,updated_at) "
                "SELECT 'message.hard_delete',m.id,''::bytea,m.scope,m.scope_id,m.created_at,'pending',0,$1,0,'',$1,$1 FROM messages m WHERE m.user_id=$2",
                [Now, Uid])
    end.

enqueue_scylla_hard_deletes_for_scope(Conn, Scope, ScopeId) ->
    case scylla_may_have_data(Conn) of
        false -> ok;
        true ->
            Now = pw_util:now_ms(),
            exec(Conn,
                "INSERT INTO storage_outbox(kind,entity_id,payload,entity_scope,entity_scope_id,entity_created_at,status,attempts,next_attempt_at,locked_at,last_error,created_at,updated_at) "
                "SELECT 'message.hard_delete',m.id,''::bytea,m.scope,m.scope_id,m.created_at,'pending',0,$1,0,'',$1,$1 FROM messages m WHERE m.scope=$2 AND m.scope_id=$3",
                [Now, Scope, ScopeId])
    end.

enqueue_scylla_hard_deletes_for_server(Conn, Sid) ->
    case scylla_may_have_data(Conn) of
        false -> ok;
        true ->
            Now = pw_util:now_ms(),
            exec(Conn,
                "INSERT INTO storage_outbox(kind,entity_id,payload,entity_scope,entity_scope_id,entity_created_at,status,attempts,next_attempt_at,locked_at,last_error,created_at,updated_at) "
                "SELECT 'message.hard_delete',m.id,''::bytea,m.scope,m.scope_id,m.created_at,'pending',0,$1,0,'',$1,$1 FROM messages m "
                "WHERE m.scope='channel' AND EXISTS (SELECT 1 FROM channels c WHERE c.server_id=$2 AND c.id=m.scope_id)",
                [Now, Sid])
    end.

prepare_owned_servers_for_account_delete(Conn, Uid) ->
    {ok, Owned} = rows(Conn, "SELECT id FROM servers WHERE owner_id=$1 FOR UPDATE", [Uid]),
    lists:foreach(fun([Sid]) ->
        case one(Conn, "SELECT user_id FROM server_members WHERE server_id=$1 AND user_id<>$2 ORDER BY joined_at ASC,user_id ASC LIMIT 1", [Sid, Uid]) of
            {ok, [NewOwner]} ->
                ok = exec(Conn, "UPDATE servers SET owner_id=$2,updated_at=$3 WHERE id=$1", [Sid, NewOwner, pw_util:now_ms()]),
                ok = exec(Conn, "UPDATE server_members SET role='owner' WHERE server_id=$1 AND user_id=$2", [Sid, NewOwner]);
            _ ->
                ok = enqueue_scylla_hard_deletes_for_server(Conn, Sid),
                ok = exec(Conn, "DELETE FROM messages m WHERE m.scope='channel' AND EXISTS (SELECT 1 FROM channels c WHERE c.server_id=$1 AND c.id=m.scope_id)", [Sid]),
                ok = exec(Conn, "DELETE FROM servers WHERE id=$1", [Sid])
        end
    end, Owned),
    ok.

prepare_owned_conversations_for_account_delete(Conn, Uid) ->
    {ok, Owned} = rows(Conn, "SELECT id FROM direct_threads WHERE owner_id=$1 FOR UPDATE", [Uid]),
    lists:foreach(fun([Cid]) ->
        case one(Conn, "SELECT user_id FROM direct_members WHERE thread_id=$1 AND user_id<>$2 ORDER BY joined_at ASC,user_id ASC LIMIT 1", [Cid, Uid]) of
            {ok, [NewOwner]} ->
                ok = exec(Conn, "UPDATE direct_threads SET owner_id=$2,updated_at=$3 WHERE id=$1", [Cid, NewOwner, pw_util:now_ms()]),
                ok = exec(Conn, "UPDATE direct_members SET group_role='owner' WHERE thread_id=$1 AND user_id=$2", [Cid, NewOwner]);
            _ ->
                ok = enqueue_scylla_hard_deletes_for_scope(Conn, <<"direct">>, Cid),
                ok = exec(Conn, "DELETE FROM messages WHERE scope='direct' AND scope_id=$1", [Cid]),
                ok = exec(Conn, "DELETE FROM direct_threads WHERE id=$1", [Cid])
        end
    end, Owned),
    ok.

prepare_owned_forums_for_account_delete(Conn, Uid) ->
    {ok, Owned} = rows(Conn, "SELECT id FROM forums WHERE owner_id=$1 FOR UPDATE", [Uid]),
    lists:foreach(fun([Fid]) ->
        case one(Conn, "SELECT user_id FROM forum_members WHERE forum_id=$1 AND user_id<>$2 ORDER BY joined_at ASC,user_id ASC LIMIT 1", [Fid, Uid]) of
            {ok, [NewOwner]} -> ok = exec(Conn, "UPDATE forums SET owner_id=$2 WHERE id=$1", [Fid, NewOwner]);
            _ -> ok = exec(Conn, "DELETE FROM forums WHERE id=$1", [Fid])
        end
    end, Owned),
    ok.

maybe_upgrade_password_hash(Conn, Uid, Password, StoredHash) ->
    case pw_util:password_needs_rehash(StoredHash) of
        false -> ok;
        true ->
            Salt = pw_util:random_token(18),
            Hash = pw_util:pbkdf2(Password, Salt),
            %% Compare the old hash in the UPDATE so concurrent successful
            %% logins cannot overwrite a newer password hash.
            _ = exec(Conn,
                "UPDATE users SET password_hash = $1, password_salt = $2, updated_at = $3 "
                "WHERE id = $4 AND password_hash = $5",
                [Hash, Salt, pw_util:now_ms(), Uid, StoredHash]),
            ok
    end.
