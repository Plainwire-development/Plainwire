-module(pw_db).
-behaviour(gen_server).
-export([
    start_link/0,
    health/0,
    register/3, login/2, session/1, session_fast/1, logout/1, sessions/2, logout_other_sessions/2, change_password/4, me/1, update_profile/3, update_theme/2,
    onboarding/1, start_onboarding/1, update_onboarding/2, complete_onboarding/1, dismiss_onboarding/1, replay_onboarding/1,
    sync/2, users/1, profile/2, profile_by_username/2,
    friend_request/2, friend_accept/2, friend_remove/2, friend_block/2, friend_unblock/2, friends/1,
    forums/1, create_forum/4, delete_forum/2, join_forum/2, leave_forum/2, threads/3, thread/2, create_thread/4, edit_thread/4, moderate_thread/4, delete_thread/2, reply_thread/3, edit_reply/4, delete_reply/3, vote_thread/3,
    servers/1, create_server/3, update_server/3, server/2, create_channel/4, create_channel/5,
    server_roles/2, create_server_role/4, update_server_role/4, delete_server_role/3, set_server_member_roles/4,
    kick_server_member/3, update_server_member_profile/4, server_permissions/2, update_server_default_permissions/3,
    create_invite/4, create_invite/5, list_invites/2, revoke_invite/3, invite_options/2, invite_preview/1, join_invite/2,
    messages/5, post_channel_message/4, delete_message/2, edit_message/3, forward_message/4, record_missed_call/2,
    conversations/1, create_conversation/3, create_conversation_usernames/3, update_conversation/4,
    set_conversation_member_role/4, kick_conversation_member/3,
    add_conversation_members/3, add_conversation_members_usernames/3, conversation/2, post_direct_message/4,
    close_conversation/2, leave_conversation/2, accept_message_request/2, deny_message_request/2,
    mark_conversation_read/2, notifications/1, mark_notifications_seen/1, clear_notifications/1, mark_url_seen/2,
    member_of_channel/2, channel_identity/2, channel_message_identity/2, voice_access/2, member_of_conversation/2, member_of_server/2, member_of_thread_forum/2, conversation_peer_ids/2,
    subscribable/2,
    begin_upload/6, finish_upload/3, abort_upload/2, get_upload/2, stale_uploads/2, delete_upload/1,
    upload_ref_backfill/1,
    categories/2, create_category/3, update_category/4, reorder_categories/3, delete_category/3, move_channel/4
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([profile_file_signature/2, extract_file_ids/1]).
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

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

health() ->
    try
        #pool{conns = Conns, size = Size} = persistent_term:get(?POOL_KEY),
        Conn = pool_conn(1, Conns),
        case rows(Conn, "SELECT 1", []) of
            {ok, _} ->
                Queues = [connection_load(I, pool_conn(I, Conns)) || I <- lists:seq(1, Size)],
                {ok, #{database => ok, pool_size => Size, max_connection_queue => lists:max(Queues)}};
            _ -> {error, database_unavailable}
        end
    catch
        _:_ -> {error, database_unavailable}
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
    case pick_connection(Conns, Size, Counter) of
        overloaded ->
            logger:warning("[plainwire:db] pool_overloaded operation=~p", [element(1, Msg)]),
            {error, database_busy};
        {Idx, Conn, QueueLen} ->
            Started = erlang:monotonic_time(millisecond),
            _ = ets:update_counter(?POOL_LOAD, Idx, {2, 1}, {Idx, 0}),
            try run_connection_locked(Idx, Msg, Conn, Started, QueueLen)
            after ets:update_counter(?POOL_LOAD, Idx, {2, -1}, {Idx, 1}) end
    end.

run_connection_locked(Idx, Msg, Conn, Started, QueueLen) ->
    %% epgsql locks queries, not whole transactions. lock the whole route.
    LockId = {{?MODULE, connection, Idx}, self()},
    try global:trans(LockId, fun() ->
        CurrentConn = case ets:lookup(?POOL_CONNS, Idx) of [{Idx, C}] -> C; [] -> Conn end,
        case route_with_reconnect(Msg, CurrentConn) of
            {Reply, CurrentConn} -> Reply;
            {Reply, Conn1} -> update_pool_conn(Idx, Conn1), Reply
        end
    end, [node()], infinity) of
        aborted -> {error, database_busy};
        Reply -> log_db_latency(Msg, Started, QueueLen), Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, database_unavailable};
        exit:{normal, _} -> {error, database_unavailable};
        exit:Reason ->
            error_logger:error_msg("DB call exit ~p for ~p~n", [Reason, safe_log_msg(Msg)]),
            {error, database_unavailable}
    end.

%% two random choices keeps one connection from getting dogpiled.
pick_connection(Conns, Size, Counter) ->
    A = atomics:add_get(Counter, 1, 1) rem Size + 1,
    B = case Size of 1 -> A; _ -> atomics:add_get(Counter, 1, 1) rem Size + 1 end,
    ConnA = pool_conn(A, Conns),
    ConnB = pool_conn(B, Conns),
    QA = connection_load(A, ConnA),
    QB = connection_load(B, ConnB),
    {Idx, Conn, Q} = case QA =< QB of true -> {A, ConnA, QA}; false -> {B, ConnB, QB} end,
    MaxQueue = max(10, pw_util:env_int("PLAINWIRE_DB_MAX_QUEUE", 250)),
    case Q >= MaxQueue of true -> overloaded; false -> {Idx, Conn, Q} end.

connection_queue_len(Pid) when is_pid(Pid) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        _ -> 1000000
    end;
connection_queue_len(_) -> 1000000.

connection_load(Idx, Conn) ->
    Waiting = case ets:lookup(?POOL_LOAD, Idx) of [{Idx, N}] -> N; [] -> 0 end,
    max(Waiting, connection_queue_len(Conn)).

log_db_latency(Msg, Started, QueueLen) ->
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    SlowMs = pw_util:env_int("PLAINWIRE_DB_SLOW_MS", 250),
    case Elapsed >= SlowMs of
        true -> logger:warning("[plainwire:db] slow operation=~p duration_ms=~p initial_queue=~p", [element(1, Msg), Elapsed, QueueLen]);
        false -> ok
    end.

update_pool_conn(Idx, NewConn) ->
    ets:insert(?POOL_CONNS, {Idx, NewConn}),
    ok.

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
server(Uid, ServerId) -> call({server, Uid, ServerId}).
create_channel(Uid, ServerId, Name, Kind) -> create_channel(Uid, ServerId, Name, Kind, undefined).
create_channel(Uid, ServerId, Name, Kind, CategoryId) -> call({create_channel, Uid, ServerId, Name, Kind, CategoryId}).
server_roles(Uid, ServerId) -> call({server_roles, Uid, ServerId}).
create_server_role(Uid, ServerId, Name, Patch) -> call({create_server_role, Uid, ServerId, Name, Patch}).
update_server_role(Uid, ServerId, RoleId, Patch) -> call({update_server_role, Uid, ServerId, RoleId, Patch}).
delete_server_role(Uid, ServerId, RoleId) -> call({delete_server_role, Uid, ServerId, RoleId}).
set_server_member_roles(Uid, ServerId, TargetUid, RoleIds) -> call({set_server_member_roles, Uid, ServerId, TargetUid, RoleIds}).
kick_server_member(Uid, ServerId, TargetUid) -> call({kick_server_member, Uid, ServerId, TargetUid}).
update_server_member_profile(Uid, ServerId, TargetUid, Patch) -> call({update_server_member_profile, Uid, ServerId, TargetUid, Patch}).
server_permissions(Uid, ServerId) -> call({server_permissions, Uid, ServerId}).
update_server_default_permissions(Uid, ServerId, Permissions) -> call({update_server_default_permissions, Uid, ServerId, Permissions}).
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
notifications(Uid) -> call({notifications, Uid}).
mark_notifications_seen(Uid) -> call({mark_notifications_seen, Uid}).
clear_notifications(Uid) -> call({clear_notifications, Uid}).
mark_url_seen(Uid, Url) -> call({mark_url_seen, Uid, Url}).
member_of_channel(Uid, ChannelId) -> call({member_of_channel, Uid, ChannelId}).
channel_identity(Uid, ChannelId) -> call({channel_identity, Uid, ChannelId}).
channel_message_identity(Uid, ChannelId) -> call({channel_message_identity, Uid, ChannelId}).
voice_access(Uid, ChannelId) -> call({voice_access, Uid, ChannelId}).
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
upload_ref_backfill(Batch) -> call({upload_ref_backfill, Batch}).

init([]) ->
    application:ensure_all_started(inets),
    _ = ets:new(?SESSION_CACHE, [named_table, public, set, {read_concurrency, true}]),
    _ = ets:new(?POOL_CONNS, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    _ = ets:new(?POOL_LOAD, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
    {ok, MigConn} = connect_with_retry(10, 500),
    ok = migrate(MigConn),
    try epgsql:close(MigConn) catch _:_ -> ok end,
    %% clamp this before tuple math (and before opening 9000 connections).
    PoolSize = min(128, max(1, pw_util:env_int("PLAINWIRE_DB_POOL_SIZE", 10))),
    Conns = list_to_tuple([
        begin
            {ok, C} = connect_with_retry(5, 500),
            C
        end || _ <- lists:seq(1, PoolSize)
    ]),
    Counter = atomics:new(1, [{signed, false}]),
    [begin ets:insert(?POOL_CONNS, {I, element(I, Conns)}), ets:insert(?POOL_LOAD, {I, 0}) end || I <- lists:seq(1, PoolSize)],
    persistent_term:put(?POOL_KEY, #pool{conns = Conns, size = PoolSize, counter = Counter}),
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
handle_info(_, St) -> {noreply, St}.
terminate(_, _) ->
    try
        #pool{conns = Conns, size = Size} = persistent_term:get(?POOL_KEY),
        [try epgsql:close(pool_conn(I, Conns)) catch _:_ -> ok end || I <- lists:seq(1, Size)],
        persistent_term:erase(?POOL_KEY)
    catch _:_ -> ok end,
    ok.
code_change(_, St, _) -> {ok, St}.

route_with_reconnect(Msg, Conn) ->
    try route(Msg, Conn) of
        Reply -> {Reply, Conn}
    catch
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
read_msg({create_channel, _, _, _, _, _}) -> false;
read_msg({create_server_role, _, _, _, _}) -> false;
read_msg({update_server_role, _, _, _, _}) -> false;
read_msg({delete_server_role, _, _, _}) -> false;
read_msg({set_server_member_roles, _, _, _, _}) -> false;
read_msg({kick_server_member, _, _, _}) -> false;
read_msg({update_server_member_profile, _, _, _, _}) -> false;
read_msg({update_server_default_permissions, _, _, _}) -> false;
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
read_msg({record_missed_call, _, _}) -> false;
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
read_msg({upload_ref_backfill, _}) -> false;
read_msg({prune_sessions, _}) -> false;
read_msg(_) -> true.

safe_log_msg({register, _, _, _}) -> {register, redacted};
safe_log_msg({login, _, _}) -> {login, redacted};
safe_log_msg({session, _}) -> {session, redacted};
safe_log_msg({logout, _}) -> {logout, redacted};
safe_log_msg({logout_other_sessions, Uid, _}) -> {logout_other_sessions, Uid, redacted};
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
safe_log_msg(Msg) -> Msg.

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
    case one(Conn, "SELECT id, password_hash, password_salt FROM users WHERE username = $1", [U]) of
        {ok, [Id, Hash, Salt]} ->
            case pw_util:verify_password(P, Salt, Hash) of
                true ->
                    maybe_upgrade_password_hash(Conn, Id, P, Hash),
                    {ok, make_session(Conn, Id)};
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
                  "WHERE s.token_hash = $1 AND s.expires_at > $2",
            case one(Conn, Sql, [H, Now]) of
                {ok, [Uid, Csrf, Un, Dn, Bio, Av, Ban, St, Th, Cr, Ls, ExpiresAt]} ->
                    Cutoff = Now - 60000,
                    _ = exec(Conn, "UPDATE sessions SET last_seen = $1 WHERE token_hash = $2 AND last_seen < $3", [Now, H, Cutoff]),
                    _ = exec(Conn, "UPDATE users SET last_seen = $1 WHERE id = $2 AND last_seen < $3", [Now, Uid, Cutoff]),
                    Session = #{user => user_map_full([Uid, Un, Dn, Bio, Av, Ban, St, Th, Cr, Ls]),
                           csrf => Csrf, server_time => Now},
                    ets:insert(?SESSION_CACHE, {H, Session, session_cache_expiry(Now, ExpiresAt)}),
                    {ok, Session};
                _ ->
                    {error, no_session}
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
route({me, Uid}, Conn) ->
    case one(Conn,
        "SELECT id, username, display_name, bio, avatar_url, banner_url, status, theme, created_at, last_seen "
        "FROM users WHERE id = $1", [Uid]) of
        {ok, Row} when is_list(Row) -> {ok, user_map_full(Row)};
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
    Notifs = case Since > 0 of
        true ->
            {ok, Rows} = rows(Conn, "SELECT id, kind, body, url, seen, created_at FROM notifications WHERE user_id = $1 AND created_at > $2 ORDER BY id DESC LIMIT 120", [Uid, Since]),
            {ok, [notification_map(R) || R <- Rows]};
        false ->
            route({notifications, Uid}, Conn)
    end,
    {ok, Convs} = route({conversations, Uid}, Conn),
    {ok, Servers} = route({servers, Uid}, Conn),
    {ok, Friends} = route({friends, Uid}, Conn),
    {ok, #{now => pw_util:now_ms(), since => Since,
          notifications => case Notifs of {ok, N} -> N; _ -> [] end,
          conversations => Convs,
          servers => Servers, friends => Friends}};
route({users, Q0}, Conn) ->
    Q = pw_util:clean_text(Q0, 80),
    case byte_size(Q) >= 2 of
        false ->
            {ok, []};
        true ->
            Like = <<"%", Q/binary, "%">>,
            {ok, Rows} = rows(Conn,
                "SELECT id, username, display_name, bio, avatar_url, banner_url, status, theme, created_at, last_seen "
                "FROM users WHERE username ILIKE $1 OR display_name ILIKE $2 "
                "ORDER BY last_seen DESC LIMIT 40", [Like, Like]),
            {ok, [user_map(R) || R <- Rows]}
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
        _ ->
            {A, B} = pair(Uid, Target),
            _ = exec(Conn, "DELETE FROM friendships WHERE user_low = $1 AND user_high = $2", [A, B]),
            {ok, #{removed => true}}
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
          "WHERE fr.user_low = $1 OR fr.user_high = $1 ORDER BY fr.updated_at DESC",
    {ok, Rows} = rows(Conn, Sql, [Uid]),
    {ok, [friend_map(R, Uid) || R <- Rows]};
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
    {ok, [server_row_map(R) || R <- Rows]};
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
            publish_server_event(Conn, Sid, #{type => server_updated, server_id => Sid}),
            route({server, Uid, Sid}, Conn);
        _ -> Result
    end;
route({server, Uid, ServerId0}, Conn) ->
    Sid = pw_util:int(ServerId0),
    case one(Conn, "SELECT role FROM server_members WHERE server_id = $1 AND user_id = $2", [Sid, Uid]) of
        {ok, [Role]} ->
            {ok, S} = one(Conn, "SELECT id, owner_id, name, description, icon_url, banner_url, accent_color, welcome_message, created_at, updated_at, default_permissions FROM servers WHERE id = $1", [Sid]),
            {ok, Permissions} = server_permissions0(Conn, Uid, Sid),
            CanViewChannels = pw_permissions:has(Permissions, pw_permissions:mask(<<"view_channels">>)),
            {ok, Ch} = case CanViewChannels of
                true -> rows(Conn, "SELECT id, server_id, name, kind, position, topic, created_at, category_id FROM channels WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]);
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
                "WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id ORDER BY r.position DESC,r.id ASC LIMIT 1),''), "
                "COALESCE((SELECT string_agg(r.name, ', ' ORDER BY r.position DESC,r.id ASC) FROM server_member_roles mr "
                "JOIN server_roles r ON r.id=mr.role_id WHERE mr.server_id=sm.server_id AND mr.user_id=sm.user_id),'') "
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
                "sm.role,sm.nickname,sm.avatar_url,sm.bio,sm.joined_at "
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
                    case has_server_permission(Conn, Uid, Sid, <<"manage_roles">>) andalso can_moderate_server_member(Conn, Uid, Sid, Target) of
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
            publish_server_event(Conn, Sid, #{type => server_member_removed, server_id => Sid, user_id => Target}),
            {ok, maps:remove(revoke_channels, Data)};
        Other -> Other
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
                    Result;
                _ -> Result
            end
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
        case one(Conn, "SELECT server_id FROM channels WHERE id = $1 FOR UPDATE", [ChannelId]) of
            {ok, [Sid]} ->
                _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
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
        end
    end),
    case Result of
        {ok, #{server_id := Sid} = Data} ->
            publish_server_event(Conn, Sid, #{type => channel_moved, server_id => Sid, channel_id => ChannelId}),
            {ok, maps:remove(server_id, Data)};
        _ -> Result
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
          "s.name, s.description, s.icon_url, "
          "(SELECT count(*) FROM server_members WHERE server_id = s.id) "
          "FROM server_invites i JOIN servers s ON s.id = i.server_id WHERE i.code = $1",
    case one(Conn, Sql, [Code]) of
        {ok, [Code, Sid, Cid, Max, Uses, Expires, Revoked, Name, Desc, Icon, Count]} ->
            Valid = (Revoked =:= false) andalso (Max =:= 0 orelse Uses < Max) andalso (Expires =:= 0 orelse Expires > Now),
            {ok, #{code => Code, server_id => Sid, channel_id => Cid, valid => Valid,
                   server => #{name => Name, description => Desc, icon_url => Icon, member_count => Count}}};
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
            publish_server_event(Conn, Sid, #{type => member_joined, server_id => Sid, user_id => Uid}),
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
            {Sql, Params} = message_sql(Scope, ScopeId, Before, After),
            {ok, Rows} = rows(Conn, Sql, Params),
            ReplyIds = [R || [_,_,_,_,_,_,_,_,R|_] <- Rows, R =/= null, is_integer(R)],
            ReplyMap = batch_replied_messages(Conn, ReplyIds, Scope, ScopeId),
            {ok, [message_map_with_replies(R, ReplyMap) || R <- Rows]};
        false ->
            {error, forbidden}
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
                        ok = exec(Conn, "UPDATE messages SET deleted_at=$1,body='' WHERE id=$2", [Now, Mid]),
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
                                case removed_upload_refs(load_message(OldStoredBody), Plain) of
                                    [] -> insert_upload_refs(Conn, Plain, Scope, ScopeId, Now);
                                    _ -> sync_message_scope_upload_refs(Conn, Scope, ScopeId, Now)
                                end,
                                {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                                {ok, #{message => message_map(Conn, Row), scope => Scope, scope_id => ScopeId}}
                        end;
                    {ok, [_Author, _Scope, _ScopeId, _Body]} -> {error, forbidden};
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{message := Msg, scope := Scope, scope_id := ScopeId}} ->
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
                                Now = pw_util:now_ms(),
                                {ok, NewId} = insert_returning(Conn,
                                    "INSERT INTO messages(scope,scope_id,user_id,body,reply_to_id,created_at,forwarded_from_id) VALUES($1,$2,$3,$4,NULL,$5,$6) RETURNING id",
                                    [TargetScope, TargetId, Uid, StoredBody, Now, OriginalId]),
                                insert_upload_refs(Conn, load_message(StoredBody), TargetScope, TargetId, Now),
                                case TargetScope of
                                    <<"direct">> ->
                                        ok = exec(Conn, "UPDATE direct_threads SET updated_at=$1 WHERE id=$2", [Now, TargetId]),
                                        ok = exec(Conn, "UPDATE direct_members SET last_read_message_id=$1 WHERE thread_id=$2 AND user_id=$3", [NewId, TargetId, Uid]),
                                        ok = exec(Conn, "UPDATE direct_members SET hidden=false WHERE thread_id=$1 AND user_id<>$2", [TargetId, Uid]);
                                    <<"channel">> -> ok
                                end,
                                {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [NewId]),
                                {ok, #{message => message_map(Conn, Row), scope => TargetScope, scope_id => TargetId, server_id => Sid, notify_at => Now}};
                            _ -> {error, forbidden}
                        end;
                    _ -> {error, not_found}
                end
            end),
            case Result of
                {ok, #{message := Msg, scope := <<"direct">>, scope_id := Cid, notify_at := Now}} ->
                    pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
                    best_effort_direct_notifications(Conn, Cid, Uid, #{type => direct_message, conversation_id => Cid, message => Msg}, Now, true),
                    {ok, Msg};
                {ok, #{message := Msg, scope := <<"channel">>, scope_id := Cid, server_id := Sid, notify_at := Now}} ->
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
                case {channel_message_access(Conn, Uid, Cid), valid_reply_to(Conn, <<"channel">>, Cid, ReplyTo)} of
                    {{ok, Sid}, true} ->
                        Now = pw_util:now_ms(),
                        {ok, Mid} = insert_returning(Conn,
                            "INSERT INTO messages(scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                            [<<"channel">>, Cid, Uid, Body, ReplyTo, Now]),
                        insert_upload_refs(Conn, Plain, <<"channel">>, Cid, Now),
                        {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                        {ok, #{message => message_map(Conn, Row), server_id => Sid, notify_at => Now}};
                    {{error, _}, _} -> {error, forbidden};
                    _ -> {error, invalid_message}
                end
            end),
            case Result of
                {ok, #{message := Msg, server_id := Sid, notify_at := Now}} ->
                    pw_hub:broadcast({channel, Cid}, #{type => message_created, scope => channel, scope_id => Cid, message => Msg}),
                    best_effort_channel_notifications(Conn, Sid, Uid, Cid, Msg, Now, false),
                    {ok, Msg};
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
    {ok, [conversation_row_map(R) || R <- Rows]};
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
                Now = pw_util:now_ms(),
                {ok, MemberRows} = rows(Conn, "SELECT user_id, muted FROM direct_members WHERE thread_id = $1", [Cid]),
                MemberIds = [MemberId || [MemberId, _Muted] <- MemberRows],
                NotifyIds = [MemberId || [MemberId, false] <- MemberRows, MemberId =/= Uid],
                %% Reconcile through the ACL helper rather than deleting rows
                %% directly so cached positive grants are revoked immediately.
                ok = remove_scope_upload_refs(Conn, <<"direct">>, Cid),
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
                        {ok, Mid} = insert_returning(Conn,
                            "INSERT INTO messages(scope,scope_id,user_id,body,reply_to_id,created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                            [<<"direct">>, Cid, Uid, Body, ReplyTo, Now]),
                        insert_upload_refs(Conn, Plain, <<"direct">>, Cid, Now),
                        ok = exec(Conn, "UPDATE direct_threads SET updated_at=$1 WHERE id=$2", [Now, Cid]),
                        ok = exec(Conn, "UPDATE direct_members SET last_read_message_id=$1 WHERE thread_id=$2 AND user_id=$3", [Mid, Cid, Uid]),
                        ok = exec(Conn, "UPDATE direct_members SET hidden=false WHERE thread_id=$1 AND user_id<>$2", [Cid, Uid]),
                        {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                        {ok, #{message => message_map(Conn, Row), notify_at => Now}};
                    {false, _} -> {error, forbidden};
                    _ -> {error, invalid_message}
                end
            end),
            case Result of
                {ok, #{message := Msg, notify_at := Now}} ->
                    pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
                    best_effort_direct_notifications(Conn, Cid, Uid, #{type => direct_message, conversation_id => Cid, message => Msg}, Now, false),
                    {ok, Msg};
                Other -> Other
            end
    end;
route({record_missed_call, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    Result = with_tx(Conn, fun() ->
        case conversation_can_send(Conn, Uid, Cid) of
            false -> {error, forbidden};
            true ->
                Now = pw_util:now_ms(),
                Body = store_message(<<"Missed call">>),
                {ok, Mid} = insert_returning(Conn,
                    "INSERT INTO messages(scope,scope_id,user_id,body,reply_to_id,created_at,kind) VALUES('direct',$1,$2,$3,NULL,$4,'missed_call') RETURNING id",
                    [Cid, Uid, Body, Now]),
                ok = exec(Conn, "UPDATE direct_threads SET updated_at=$1 WHERE id=$2", [Now, Cid]),
                ok = exec(Conn, "UPDATE direct_members SET last_read_message_id=$1 WHERE thread_id=$2 AND user_id=$3", [Mid, Cid, Uid]),
                ok = exec(Conn, "UPDATE direct_members SET hidden=false WHERE thread_id=$1", [Cid]),
                {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                {ok, #{message => message_map(Conn, Row), notify_at => Now}}
        end
    end),
    case Result of
        {ok, #{message := Msg, notify_at := Now}} ->
            pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
            best_effort_missed_call_notifications(Conn, Cid, Uid, Msg, Now),
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
    case one(Conn, "SELECT cursor, done FROM upload_ref_backfill WHERE id = 1", []) of
        {ok, [_, true]} -> {ok, done};
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
    exec(Conn, "DELETE FROM uploads WHERE id = $1", [Id]);
%% public-to-members, yes. imaginary ids, no; they bloat hub subscriptions.
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
    ]}
].

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
    try Fun() of
        {ok, _} = Ok -> ok = exec(Conn, "COMMIT", []), Ok;
        Other -> ok = exec(Conn, "ROLLBACK", []), Other
    catch
        C:R:S ->
            try exec(Conn, "ROLLBACK", []) catch _:_ -> ok end,
            erlang:raise(C, R, S)
    end.

join_invite_tx(Conn, Uid, Code, Now) ->
    case one(Conn, "SELECT code, server_id, channel_id, max_uses, uses, expires_at, revoked FROM server_invites WHERE code = $1 FOR UPDATE", [Code]) of
        {ok, [Code, Sid, ChannelId, Max, Uses, Expires, false]} when (Max =:= 0 orelse Uses < Max), (Expires =:= 0 orelse Expires > Now) ->
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
            {ok, #{server_id => Sid, channel_id => ChannelId, membership_created => not AlreadyMember}};
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
    #{id => Id, username => U, display_name => D, bio => Bio,
      avatar_url => pw_util:proxied_image(Avatar),
      banner_url => pw_util:proxied_image(Banner),
      status => Status, theme => Theme, created_at => Created, last_seen => LastSeen}.

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
    channel_map([Id, Sid, Name, Kind, Pos, Topic, Created, undefined]);
channel_map([Id, Sid, Name, Kind, Pos, Topic, Created, CatId]) ->
    #{id => Id, server_id => Sid, name => Name, kind => Kind, position => Pos, topic => Topic,
      created_at => Created, category_id => db_null(CatId)}.

category_map([Id, Sid, Name, Pos, Created]) ->
    #{id => Id, server_id => Sid, name => Name, position => Pos, created_at => Created}.

member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
      role => Role, muted => Muted, joined_at => Joined};
member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio]) ->
    member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio, <<>>, <<>>]);
member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined, Nick, ServerAvatar, ServerBio, RoleColor, RoleNames]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
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
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
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

message_map([Id, Scope, ScopeId, Uid, U, D, Avatar, Body, ReplyTo, Created, Edited, Deleted, Kind, ForwardId, ForwardUid, ForwardName, _ForwardBody]) ->
    Base = #{id => Id, scope => Scope, scope_id => ScopeId, user_id => Uid, username => U, display_name => D,
      avatar_url => pw_util:proxied_image(Avatar), body => load_message(Body), reply_to_id => db_null(ReplyTo),
      created_at => Created, edited_at => db_null(Edited), deleted_at => db_null(Deleted), kind => Kind},
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
      member_count => Count, last_body => load_message(LastBody), last_message_id => LastMsg, unread => Unread,
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
    "m.forwarded_from_id, fm.user_id, fu.display_name, NULL "
    "FROM messages m JOIN users u ON u.id = m.user_id "
    "LEFT JOIN channels mc ON m.scope='channel' AND mc.id=m.scope_id "
    "LEFT JOIN server_members sm ON sm.server_id=mc.server_id AND sm.user_id=m.user_id "
    "LEFT JOIN messages fm ON fm.id = m.forwarded_from_id LEFT JOIN users fu ON fu.id = fm.user_id".

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

can_moderate_server_member(Conn, Actor, Sid, Target) when Actor =:= Target -> false;
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

notify_channel_members(Conn, Sid, Sender, Cid, Msg, Now) ->
    notify_channel_members(Conn, Sid, Sender, Cid, Msg, Now, false).

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
    case rows(Conn, "SELECT user_id FROM server_members WHERE server_id = $1", [Sid]) of
        {ok, Members} ->
            [pw_hub:notify_user(only_id(Row), Event) || Row <- Members],
            ok;
        _ ->
            ok
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

notify_direct_members(Conn, Cid, Sender, Event, Now) ->
    notify_direct_members(Conn, Cid, Sender, Event, Now, false).

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
