-module(pw_db).
-behaviour(gen_server).
-export([
    start_link/0,
    health/0,
    register/3, login/2, session/1, session_fast/1, logout/1, sessions/2, logout_other_sessions/2, change_password/4, me/1, update_profile/3, update_theme/2,
    sync/2, users/1, profile/2, profile_by_username/2,
    friend_request/2, friend_accept/2, friend_remove/2, friend_block/2, friend_unblock/2, friends/1,
    forums/1, create_forum/4, delete_forum/2, join_forum/2, leave_forum/2, threads/3, thread/2, create_thread/4, delete_thread/2, reply_thread/3, vote_thread/3,
    servers/1, create_server/3, update_server/3, server/2, create_channel/4, create_channel/5,
    create_invite/4, create_invite/5, list_invites/2, revoke_invite/3, invite_options/2, invite_preview/1, join_invite/2,
    messages/5, post_channel_message/4, delete_message/2, edit_message/3, forward_message/4, record_missed_call/2,
    conversations/1, create_conversation/3, create_conversation_usernames/3, update_conversation/4,
    add_conversation_members/3, add_conversation_members_usernames/3, conversation/2, post_direct_message/4,
    close_conversation/2, leave_conversation/2, accept_message_request/2, deny_message_request/2,
    mark_conversation_read/2, notifications/1, mark_notifications_seen/1, clear_notifications/1, mark_url_seen/2,
    member_of_channel/2, member_of_conversation/2, member_of_server/2, conversation_peer_ids/2,
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
-define(UPLOAD_REFS_READY, pw_db_upload_refs_ready).

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
servers(Uid) -> call({servers, Uid}).
create_server(Uid, Name, Desc) -> call({create_server, Uid, Name, Desc}).
update_server(Uid, Sid, Patch) -> call({update_server, Uid, Sid, Patch}).
server(Uid, ServerId) -> call({server, Uid, ServerId}).
create_channel(Uid, ServerId, Name, Kind) -> create_channel(Uid, ServerId, Name, Kind, undefined).
create_channel(Uid, ServerId, Name, Kind, CategoryId) -> call({create_channel, Uid, ServerId, Name, Kind, CategoryId}).
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
member_of_conversation(Uid, Cid) -> call({member_of_conversation, Uid, Cid}).
member_of_server(Uid, Sid) -> call({member_of_server, Uid, Sid}).
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
read_msg({friend_request, _, _}) -> false;
read_msg({friend_accept, _, _}) -> false;
read_msg({friend_remove, _, _}) -> false;
read_msg({friend_block, _, _}) -> false;
read_msg({friend_unblock, _, _}) -> false;
read_msg({create_forum, _, _, _, _}) -> false;
read_msg({join_forum, _, _}) -> false;
read_msg({leave_forum, _, _}) -> false;
read_msg({create_thread, _, _, _, _}) -> false;
read_msg({delete_thread, _, _}) -> false;
read_msg({delete_forum, _, _}) -> false;
read_msg({reply_thread, _, _, _}) -> false;
read_msg({vote_thread, _, _, _}) -> false;
read_msg({create_server, _, _, _}) -> false;
read_msg({update_server, _, _, _}) -> false;
read_msg({create_channel, _, _, _, _, _}) -> false;
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
read_msg({create_conversation, _, _, _}) -> false;
read_msg({create_conversation_usernames, _, _, _}) -> false;
read_msg({update_conversation, _, _, _, _}) -> false;
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
                "INSERT INTO users(username,display_name,password_hash,password_salt,bio,avatar_url,banner_url,status,theme,created_at,updated_at,last_seen) "
                "VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) ON CONFLICT (username) DO NOTHING RETURNING id",
                [U, D, Hash, Salt, <<>>, <<>>, <<>>, <<>>, <<"system">>, Now, Now, Now]) of
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
route({me, Uid}, Conn) ->
    case one(Conn,
        "SELECT id, username, display_name, bio, avatar_url, banner_url, status, theme, created_at, last_seen "
        "FROM users WHERE id = $1", [Uid]) of
        {ok, Row} when is_list(Row) -> {ok, user_map_full(Row)};
        _ -> {error, not_found}
    end;
route({update_profile, Uid, Display0, Patch}, Conn) ->
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
    insert_profile_upload_ref(Conn, Uid, Avatar),
    insert_profile_upload_ref(Conn, Uid, Banner),
    invalidate_session_cache(Uid),
    {ok, #{updated => true}};
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
                            create_notification(Conn, Target, <<"friend_request">>, <<"New friend request">>, <<"#/friends">>, Now),
                            pw_hub:notify_user(Target, #{type => friend_request, from_user_id => Uid}),
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
                    create_notification(Conn, Target, <<"friend_accept">>, <<"Friend request accepted">>, <<"#/friends">>, Now),
                    pw_hub:notify_user(Target, #{type => friend_accept, user_id => Uid}),
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
        false ->
            {error, invalid_forum};
        true ->
            case one(Conn, "SELECT id FROM forums WHERE lower(slug) = lower($1) LIMIT 1", [Slug]) of
                {ok, [_]} ->
                    {error, forum_exists};
                _ ->
                    Pos = forum_position(Conn),
                    Now = pw_util:now_ms(),
                    {ok, Fid} = insert_returning(Conn,
                        "INSERT INTO forums(slug, name, description, position, owner_id) VALUES($1,$2,$3,$4,$5) RETURNING id",
                        [Slug, Name, Desc, Pos, Uid]),
                    ok = exec(Conn, "INSERT INTO forum_members(forum_id, user_id, joined_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [Fid, Uid, Now]),
                    {ok, #{id => Fid}}
            end
    end;
route({delete_forum, Uid, ForumId0}, Conn) ->
    ForumId = pw_util:int(ForumId0),
    Result = with_tx(Conn, fun() ->
        case one(Conn, "SELECT owner_id FROM forums WHERE id = $1 FOR UPDATE", [ForumId]) of
            {ok, [Uid]} ->
                {ok, ThreadRows} = rows(Conn, "SELECT id FROM threads WHERE forum_id = $1", [ForumId]),
                ok = exec(Conn,
                    "DELETE FROM notifications WHERE url IN "
                    "(SELECT '#/thread/' || id::text FROM threads WHERE forum_id = $1)", [ForumId]),
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
    ok = exec(Conn, "DELETE FROM forum_members WHERE forum_id = $1 AND user_id = $2", [ForumId, Uid]),
    {ok, #{id => ForumId}};
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
           "t.title, t.body, t.created_at, t.updated_at, t.reply_count, t.locked, t.pinned, t.views, "
           "COALESCE(t.score,0), COALESCE(tv.value,0) "
           "FROM threads t JOIN forums f ON f.id = t.forum_id JOIN users u ON u.id = t.user_id "
           "LEFT JOIN thread_votes tv ON tv.thread_id = t.id AND tv.user_id = $2 WHERE t.id = $1",
    case one(Conn, Sql1, [ThreadId, Uid]) of
        {ok, T} when is_list(T) ->
            {ok, Rs} = rows(Conn,
                "SELECT r.id, r.thread_id, r.user_id, u.username, u.display_name, u.avatar_url, "
                "r.body, r.created_at, r.updated_at FROM replies r JOIN users u ON u.id = r.user_id "
                "WHERE r.thread_id = $1 ORDER BY r.created_at ASC LIMIT 800", [ThreadId]),
            _ = mark_url_seen0(Conn, Uid, <<"#/thread/", (integer_to_binary(ThreadId))/binary>>),
            {ok, #{thread => thread_full_map(T), replies => [reply_map(R) || R <- Rs]}};
        _ ->
            {error, not_found}
    end;
route({create_thread, Uid, ForumId0, Title0, Body0}, Conn) ->
    ForumId = pw_util:int(ForumId0),
    Title = pw_util:clean_text(Title0, 160),
    Body = pw_util:clean_text(Body0, ?MAX_BODY),
    case validate_thread(Conn, ForumId, Title, Body) of
        ok ->
            Now = pw_util:now_ms(),
            {ok, Tid} = insert_returning(Conn,
                "INSERT INTO threads(forum_id, user_id, title, body, created_at, updated_at, reply_count, locked, pinned, views) "
                "VALUES($1,$2,$3,$4,$5,$6,0,false,false,0) RETURNING id",
                [ForumId, Uid, Title, Body, Now, Now]),
            pw_hub:broadcast({forum, ForumId}, #{type => thread_created, thread_id => Tid, forum_id => ForumId}),
            {ok, #{id => Tid}};
        Err ->
            Err
    end;
route({delete_thread, Uid, ThreadId0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    Result = with_tx(Conn, fun() ->
        case one(Conn,
            "SELECT t.user_id,f.owner_id,t.forum_id FROM threads t "
            "JOIN forums f ON f.id = t.forum_id WHERE t.id = $1 FOR UPDATE", [ThreadId]) of
            {ok, [AuthorId, ForumOwnerId, ForumId]} when Uid =:= AuthorId; Uid =:= ForumOwnerId ->
                ok = exec(Conn, "DELETE FROM notifications WHERE url = $1", [<<"#/thread/", (integer_to_binary(ThreadId))/binary>>]),
                ok = exec(Conn, "DELETE FROM threads WHERE id = $1", [ThreadId]),
                {ok, #{deleted => true, id => ThreadId, forum_id => ForumId}};
            {ok, _} -> {error, forbidden};
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
    case {ThreadId, byte_size(Body) > 0, one(Conn, "SELECT locked FROM threads WHERE id = $1", [ThreadId])} of
        {I, true, {ok, [false]}} when is_integer(I) ->
            Now = pw_util:now_ms(),
            {ok, Rid} = insert_returning(Conn,
                "INSERT INTO replies(thread_id, user_id, body, created_at, updated_at) VALUES($1,$2,$3,$4,$5) RETURNING id",
                [ThreadId, Uid, Body, Now, Now]),
            ok = exec(Conn, "UPDATE threads SET updated_at = $1, reply_count = reply_count + 1 WHERE id = $2", [Now, ThreadId]),
            notify_thread_participants(Conn, ThreadId, Uid, Body, Now),
            {ok, Row} = one(Conn,
                "SELECT r.id, r.thread_id, r.user_id, u.username, u.display_name, u.avatar_url, "
                "r.body, r.created_at, r.updated_at FROM replies r JOIN users u ON u.id = r.user_id WHERE r.id = $1",
                [Rid]),
            Reply = reply_map(Row),
            pw_hub:broadcast({thread, ThreadId}, #{type => thread_reply, thread_id => ThreadId, reply => Reply}),
            {ok, Reply};
        {_, _, {ok, [true]}} ->
            {error, locked};
        _ ->
            {error, invalid_reply}
    end;
route({vote_thread, Uid, ThreadId0, Value0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0),
    Value = case pw_util:int(Value0) of 1 -> 1; -1 -> -1; _ -> 0 end,
    case one(Conn, "SELECT id FROM threads WHERE id = $1", [ThreadId]) of
        {ok, [_]} ->
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
        _ ->
            {error, not_found}
    end;
route({servers, Uid}, Conn) ->
    Sql = "SELECT s.id, s.owner_id, s.name, s.description, s.icon_url, s.banner_url, s.accent_color, s.welcome_message, s.created_at, s.updated_at, sm.role, "
          "(SELECT count(*) FROM server_members WHERE server_id = s.id) "
          "FROM servers s JOIN server_members sm ON sm.server_id = s.id AND sm.user_id = $1 "
          "ORDER BY sm.joined_at ASC",
    {ok, Rows} = rows(Conn, Sql, [Uid]),
    {ok, [server_row_map(R) || R <- Rows]};
route({create_server, Uid, Name0, Desc0}, Conn) ->
    Name = pw_util:clean_text(Name0, 80),
    Desc = pw_util:clean_text(Desc0, 280),
    case byte_size(Name) >= 2 of
        false ->
            {error, invalid_server_name};
        true ->
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
    end;
route({update_server, Uid, Sid0, Patch}, Conn) ->
    Sid = pw_util:int(Sid0),
    case can_manage_server(Conn, Uid, Sid) of
        true ->
            Now = pw_util:now_ms(),
            Name = pw_util:clean_text(maps:get(<<"name">>, Patch, <<>>), 80),
            Desc = pw_util:clean_text(maps:get(<<"description">>, Patch, <<>>), 280),
            RawIcon = maps:get(<<"icon_url">>, Patch, <<>>),
            RawBanner = maps:get(<<"banner_url">>, Patch, <<>>),
            Icon = store_image_url(RawIcon),
            Banner = store_image_url(RawBanner),
            Accent = clean_accent(maps:get(<<"accent_color">>, Patch, <<>>)),
            Welcome = pw_util:clean_text(maps:get(<<"welcome_message">>, Patch, <<>>), 2000),
            HasWelcome = maps:is_key(<<"welcome_message">>, Patch),
            HasDesc = maps:is_key(<<"description">>, Patch),
            %% /api/media is derived output. don't save it over the real source.
            HasIcon = maps:is_key(<<"icon_url">>, Patch) andalso not derived_media_url(RawIcon)
                andalso server_image_input_allowed(Conn, Uid, RawIcon),
            HasBanner = maps:is_key(<<"banner_url">>, Patch) andalso not derived_media_url(RawBanner)
                andalso server_image_input_allowed(Conn, Uid, RawBanner),
            HasAccent = maps:is_key(<<"accent_color">>, Patch) andalso Accent =/= undefined,
            case duplicate_server_name(Conn, Uid, Sid, Name) of
                true ->
                    {error, server_exists};
                false ->
                    ok = exec(Conn,
                        "UPDATE servers SET name = COALESCE(NULLIF($1,''), name), "
                        "description = CASE WHEN $3 THEN $2 ELSE description END, "
                        "icon_url = CASE WHEN $4 THEN $5 ELSE icon_url END, "
                        "banner_url = CASE WHEN $6 THEN $7 ELSE banner_url END, "
                        "accent_color = CASE WHEN $8 THEN $9 ELSE accent_color END, welcome_message = CASE WHEN $12 THEN $13 ELSE welcome_message END, updated_at = $10 WHERE id = $11",
                        [Name, Desc, HasDesc, HasIcon, Icon, HasBanner, Banner, HasAccent, Accent, Now, Sid, HasWelcome, Welcome]),
                    case HasIcon of true -> insert_server_upload_ref(Conn, Sid, Icon); false -> ok end,
                    case HasBanner of true -> insert_server_upload_ref(Conn, Sid, Banner); false -> ok end,
                    publish_server_event(Conn, Sid, #{type => server_updated, server_id => Sid}),
                    route({server, Uid, Sid}, Conn)
            end;
        false ->
            {error, forbidden}
    end;
route({server, Uid, ServerId0}, Conn) ->
    Sid = pw_util:int(ServerId0),
    case one(Conn, "SELECT role FROM server_members WHERE server_id = $1 AND user_id = $2", [Sid, Uid]) of
        {ok, [Role]} ->
            {ok, S} = one(Conn, "SELECT id, owner_id, name, description, icon_url, banner_url, accent_color, welcome_message, created_at, updated_at FROM servers WHERE id = $1", [Sid]),
            {ok, Ch} = rows(Conn, "SELECT id, server_id, name, kind, position, topic, created_at, category_id FROM channels WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]),
            {ok, Cats} = rows(Conn, "SELECT id, server_id, name, position, created_at FROM channel_categories WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]),
            {ok, Ms} = rows(Conn,
                "SELECT u.id, u.username, u.display_name, u.bio, u.avatar_url, u.banner_url, u.status, u.theme, "
                "u.created_at, u.last_seen, sm.role, sm.muted, sm.joined_at "
                "FROM server_members sm JOIN users u ON u.id = sm.user_id WHERE sm.server_id = $1 "
                "ORDER BY CASE sm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, u.display_name ASC",
                [Sid]),
            {ok, #{server => server_full_map(S, Role), channels => [channel_map(R) || R <- Ch], members => [member_map(R) || R <- Ms], categories => [category_map(R) || R <- Cats]}};
        _ ->
            {error, forbidden}
    end;
route({create_channel, Uid, Sid0, Name0, Kind0, CategoryId0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 40),
    Kind = case pw_util:clean_text(Kind0, 10) of <<"voice">> -> <<"voice">>; _ -> <<"text">> end,
    CategoryId = optional_id(CategoryId0),
    case {byte_size(Name) >= 1, can_manage_server(Conn, Uid, Sid), valid_channel_category(Conn, Sid, CategoryId)} of
        {true, true, true} ->
            case one(Conn, "SELECT id FROM channels WHERE server_id = $1 AND lower(name) = lower($2) LIMIT 1", [Sid, Name]) of
                {ok, [_]} ->
                    {error, channel_exists};
                _ ->
                    Now = pw_util:now_ms(),
                    {ok, [Pos]} = one(Conn, "SELECT COALESCE(max(position), 0) + 1 FROM channels WHERE server_id = $1", [Sid]),
                    {ok, Cid} = insert_returning(Conn,
                        "INSERT INTO channels(server_id, name, kind, position, topic, created_at, category_id) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id",
                        [Sid, Name, Kind, Pos, <<>>, Now, sql_optional_id(CategoryId)]),
                    publish_server_event(Conn, Sid, #{type => channel_created, server_id => Sid, channel_id => Cid}),
                    {ok, #{id => Cid}}
            end;
        {false, _, _} ->
            {error, invalid_channel_name};
        {_, false, _} ->
            {error, forbidden};
        {_, _, false} ->
            {error, invalid_category}
    end;
route({categories, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case is_member(Conn, Uid, Sid) of
        true ->
            {ok, Rows} = rows(Conn, "SELECT id, server_id, name, position, created_at FROM channel_categories WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]),
            {ok, [category_map(R) || R <- Rows]};
        false ->
            {error, forbidden}
    end;
route({create_category, Uid, Sid0, Name0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 80),
    case {byte_size(Name) >= 1, can_manage_server(Conn, Uid, Sid)} of
        {true, true} ->
            Now = pw_util:now_ms(),
            {ok, [Pos]} = one(Conn, "SELECT COALESCE(max(position), 0) + 1 FROM channel_categories WHERE server_id = $1", [Sid]),
            {ok, Cid} = insert_returning(Conn,
                "INSERT INTO channel_categories(server_id, name, position, created_at) VALUES($1,$2,$3,$4) RETURNING id",
                [Sid, Name, Pos, Now]),
            publish_server_event(Conn, Sid, #{type => category_created, server_id => Sid, category_id => Cid}),
            {ok, #{id => Cid}};
        {false, _} -> {error, invalid_category_name};
        {_, false} -> {error, forbidden}
    end;
route({update_category, Uid, Sid0, CatId0, Patch}, Conn) ->
    Sid = pw_util:int(Sid0),
    CatId = pw_util:int(CatId0),
    case can_manage_server(Conn, Uid, Sid) of
        true ->
            Name = pw_util:clean_text(maps:get(<<"name">>, Patch, <<>>), 80),
            case byte_size(Name) >= 1 of
                true ->
                    ok = exec(Conn, "UPDATE channel_categories SET name = $1 WHERE id = $2 AND server_id = $3", [Name, CatId, Sid]),
                    publish_server_event(Conn, Sid, #{type => category_updated, server_id => Sid, category_id => CatId}),
                    {ok, #{updated => true}};
                false -> {error, invalid_category_name}
            end;
        false -> {error, forbidden}
    end;
route({reorder_categories, Uid, Sid0, Order0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case can_manage_server(Conn, Uid, Sid) of
        true ->
            Order = case Order0 of L when is_list(L) -> L; _ -> [] end,
            lists:foreach(fun(Item) ->
                CatId = pw_util:int(maps:get(<<"id">>, Item, undefined)),
                Pos = pw_util:int(maps:get(<<"position">>, Item, undefined)),
                case {CatId, Pos} of
                    {I, P} when is_integer(I), is_integer(P) ->
                        exec(Conn, "UPDATE channel_categories SET position = $1 WHERE id = $2 AND server_id = $3", [P, I, Sid]);
                    _ -> ok
                end
            end, Order),
            publish_server_event(Conn, Sid, #{type => categories_reordered, server_id => Sid}),
            {ok, #{updated => true}};
        false -> {error, forbidden}
    end;
route({delete_category, Uid, Sid0, CatId0}, Conn) ->
    Sid = pw_util:int(Sid0),
    CatId = pw_util:int(CatId0),
    case can_manage_server(Conn, Uid, Sid) of
        true ->
            ok = exec(Conn, "UPDATE channels SET category_id = NULL WHERE category_id = $1 AND server_id = $2", [CatId, Sid]),
            ok = exec(Conn, "DELETE FROM channel_categories WHERE id = $1 AND server_id = $2", [CatId, Sid]),
            publish_server_event(Conn, Sid, #{type => category_deleted, server_id => Sid, category_id => CatId}),
            {ok, #{deleted => true}};
        false -> {error, forbidden}
    end;
route({move_channel, Uid, ChannelId0, CatId0, Position0}, Conn) ->
    ChannelId = pw_util:int(ChannelId0),
    CatId = optional_id(CatId0),
    Position = pw_util:int(Position0),
    case one(Conn, "SELECT server_id FROM channels WHERE id = $1", [ChannelId]) of
        {ok, [Sid]} ->
            case {can_manage_server(Conn, Uid, Sid), valid_channel_category(Conn, Sid, CatId)} of
                {true, true} ->
                    CatIdSafe = sql_optional_id(CatId),
                    PosSafe = case Position of undefined -> 0; P when is_integer(P) -> min(10000, max(0, P)) end,
                    ok = exec(Conn, "UPDATE channels SET category_id = $1, position = $2 WHERE id = $3", [CatIdSafe, PosSafe, ChannelId]),
                    publish_server_event(Conn, Sid, #{type => channel_moved, server_id => Sid, channel_id => ChannelId}),
                    {ok, #{updated => true}};
                {false, _} -> {error, forbidden};
                {_, false} -> {error, invalid_category}
            end;
        _ -> {error, not_found}
    end;
route({create_invite, Uid, Sid0, ChannelId0, MaxUses0, ExpiresIn0}, Conn) ->
    Sid = pw_util:int(Sid0), ChannelId = pw_util:int(ChannelId0),
    case invite_options(MaxUses0, ExpiresIn0) of
        {error, _} = Error -> Error;
        {ok, MaxUses, ExpiresIn} -> with_tx(Conn, fun() ->
            %% Serialize the per-server cap and code reuse across API nodes.
            _ = one(Conn, "SELECT id FROM servers WHERE id = $1 FOR UPDATE", [Sid]),
            case {can_manage_server(Conn, Uid, Sid), valid_invite_channel(Conn, Sid, ChannelId)} of
                {true, true} ->
                    Existing = case ExpiresIn of 0 -> existing_invite(Conn, Sid, ChannelId, MaxUses); _ -> not_found end,
                    Now = pw_util:now_ms(),
                    case Existing of
                        {ok, Code} -> {ok, #{code => Code, url => <<"#invite/", Code/binary>>, existing => true, expires_at => 0}};
                        not_found ->
                            {ok, [Count]} = one(Conn, "SELECT count(*) FROM server_invites WHERE server_id = $1 AND revoked = false AND (expires_at = 0 OR expires_at > $2) AND (max_uses = 0 OR uses < max_uses)", [Sid, Now]),
                            case Count >= 100 of
                                true -> {error, invite_limit};
                                false ->
                                    Code = pw_util:random_token(24),
                                    Expires = case ExpiresIn of 0 -> 0; _ -> Now + ExpiresIn * 1000 end,
                                    ok = exec(Conn, "INSERT INTO server_invites(code, server_id, channel_id, creator_id, max_uses, uses, created_at, expires_at, revoked) VALUES($1,$2,$3,$4,$5,0,$6,$7,false)",
                                              [Code, Sid, ChannelId, Uid, MaxUses, Now, Expires]),
                                    {ok, #{code => Code, url => <<"#invite/", Code/binary>>, expires_at => Expires, max_uses => MaxUses}}
                            end
                    end;
                {false, _} -> {error, forbidden};
                _ -> {error, invalid_channel}
            end
        end)
    end;
route({list_invites, Uid, Sid0}, Conn) ->
    Sid = pw_util:int(Sid0),
    case can_manage_server(Conn, Uid, Sid) of
        false -> {error, forbidden};
        true ->
            {ok, Rs} = rows(Conn, "SELECT code, channel_id, max_uses, uses, created_at, expires_at, revoked FROM server_invites WHERE server_id = $1 ORDER BY created_at DESC LIMIT 100", [Sid]),
            {ok, [#{code => Code, channel_id => C, max_uses => Max, uses => Uses, created_at => At, expires_at => Exp, revoked => Rev} || [Code, C, Max, Uses, At, Exp, Rev] <- Rs]}
    end;
route({revoke_invite, Uid, Sid0, Code0}, Conn) ->
    Sid = pw_util:int(Sid0), Code = pw_util:clean_text(Code0, 80),
    case can_manage_server(Conn, Uid, Sid) of
        false -> {error, forbidden};
        true -> exec(Conn, "UPDATE server_invites SET revoked = true WHERE server_id = $1 AND code = $2", [Sid, Code]), ok
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
    case one(Conn, "SELECT user_id, scope, scope_id FROM messages WHERE id = $1 AND kind = 'text' AND deleted_at IS NULL", [Mid]) of
        {ok, [Uid, Scope, ScopeId]} ->
            case can_modify_message_scope(Conn, Uid, Scope, ScopeId) of
                true ->
                    Now = pw_util:now_ms(),
                    ok = exec(Conn, "UPDATE messages SET deleted_at = $1, body = '' WHERE id = $2", [Now, Mid]),
                    BroadcastKey = case Scope of <<"direct">> -> {direct, ScopeId}; <<"channel">> -> {channel, ScopeId} end,
                    pw_hub:broadcast(BroadcastKey, #{type => message_deleted, scope => Scope, scope_id => ScopeId, message_id => Mid}),
                    {ok, #{deleted => true}};
                false ->
                    {error, forbidden}
            end;
        {ok, _} ->
            {error, forbidden};
        _ ->
            {error, not_found}
    end;
route({edit_message, Uid, Mid0, Body0}, Conn) ->
    Mid = pw_util:int(Mid0),
    Plain = pw_util:clean_text(Body0, ?MAX_MSG),
    Body = store_message(Plain),
    case {message_body_valid(Plain), one(Conn, "SELECT user_id, scope, scope_id FROM messages WHERE id = $1 AND kind = 'text' AND deleted_at IS NULL AND forwarded_from_id IS NULL", [Mid])} of
        {true, {ok, [Uid, Scope, ScopeId]}} ->
            case can_modify_message_scope(Conn, Uid, Scope, ScopeId) of
                true ->
                    Now = pw_util:now_ms(),
                    ok = exec(Conn, "UPDATE messages SET body = $1, edited_at = $2 WHERE id = $3", [Body, Now, Mid]),
                    insert_upload_refs(Conn, Plain, Scope, ScopeId, Now),
                    {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
                    Msg = message_map(Conn, Row),
                    BroadcastKey = case Scope of <<"direct">> -> {direct, ScopeId}; <<"channel">> -> {channel, ScopeId} end,
                    pw_hub:broadcast(BroadcastKey, #{type => message_updated, scope => Scope, scope_id => ScopeId, message => Msg}),
                    {ok, Msg};
                false ->
                    {error, forbidden}
            end;
        {false, _} ->
            {error, invalid_message};
        {_, {ok, _}} ->
            {error, forbidden};
        _ ->
            {error, not_found}
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
    case one(Conn, "SELECT scope, scope_id, body, COALESCE(forwarded_from_id, id) FROM messages WHERE id = $1 AND kind = 'text' AND deleted_at IS NULL", [Mid]) of
        {ok, [SourceScope, SourceId, StoredBody, OriginalId]} when TargetScope =/= invalid ->
            CanReadSource = can_read_messages(Conn, Uid, SourceScope, SourceId),
            CanSendTarget = case TargetScope of
                <<"direct">> -> conversation_can_send(Conn, Uid, TargetId);
                <<"channel">> -> case channel_server_member(Conn, Uid, TargetId) of {ok, _} -> true; _ -> false end
            end,
            case CanReadSource andalso CanSendTarget of
                true ->
                    Now = pw_util:now_ms(),
                    {ok, NewId} = insert_returning(Conn,
                        "INSERT INTO messages(scope, scope_id, user_id, body, reply_to_id, created_at, forwarded_from_id) VALUES($1,$2,$3,$4,NULL,$5,$6) RETURNING id",
                        [TargetScope, TargetId, Uid, StoredBody, Now, OriginalId]),
                    %% Forwarded attachment references must be granted to the target scope too.
                    %% Keep the stored message encrypted at rest, but parse upload tokens from plaintext.
                    insert_upload_refs(Conn, load_message(StoredBody), TargetScope, TargetId, Now),
                    case TargetScope of
                        <<"direct">> ->
                            ok = exec(Conn, "UPDATE direct_threads SET updated_at = $1 WHERE id = $2", [Now, TargetId]),
                            ok = exec(Conn, "UPDATE direct_members SET last_read_message_id = $1 WHERE thread_id = $2 AND user_id = $3", [NewId, TargetId, Uid]),
                            ok = exec(Conn, "UPDATE direct_members SET hidden = false WHERE thread_id = $1 AND user_id <> $2", [TargetId, Uid]);
                        <<"channel">> -> ok
                    end,
                    {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [NewId]),
                    Msg = message_map(Conn, Row),
                    case TargetScope of
                        <<"direct">> ->
                            pw_hub:broadcast({direct, TargetId}, #{type => message_created, scope => direct, scope_id => TargetId, message => Msg}),
                            notify_direct_members(Conn, TargetId, Uid, #{type => direct_message, conversation_id => TargetId, message => Msg}, Now, true);
                        <<"channel">> ->
                            {ok, Sid} = channel_server_member(Conn, Uid, TargetId),
                            pw_hub:broadcast({channel, TargetId}, #{type => message_created, scope => channel, scope_id => TargetId, message => Msg}),
                            notify_channel_members(Conn, Sid, Uid, TargetId, Msg, Now, true)
                    end,
                    {ok, Msg};
                false ->
                    {error, forbidden}
            end;
        {ok, _} ->
            {error, invalid_target};
        _ ->
            {error, not_found}
    end;
route({post_channel_message, Uid, ChannelId0, Body0, ReplyTo0}, Conn) ->
    Cid = pw_util:int(ChannelId0),
    Plain = pw_util:clean_text(Body0, ?MAX_MSG),
    Body = store_message(Plain),
    ReplyTo = pw_util:int(ReplyTo0),
    case {message_body_valid(Plain), channel_server_member(Conn, Uid, Cid), valid_reply_to(Conn, <<"channel">>, Cid, ReplyTo)} of
        {true, {ok, Sid}, true} ->
            Now = pw_util:now_ms(),
            {ok, Mid} = insert_returning(Conn,
                "INSERT INTO messages(scope, scope_id, user_id, body, reply_to_id, created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                [<<"channel">>, Cid, Uid, Body, ReplyTo, Now]),
            insert_upload_refs(Conn, Plain, <<"channel">>, Cid, Now),
            {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
            Msg = message_map(Conn, Row),
            pw_hub:broadcast({channel, Cid}, #{type => message_created, scope => channel, scope_id => Cid, message => Msg}),
            notify_channel_members(Conn, Sid, Uid, Cid, Msg, Now),
            {ok, Msg};
        _ ->
            {error, invalid_message}
    end;
route({conversations, Uid}, Conn) ->
    Sql = "SELECT dt.id, dt.name, dt.avatar_url, dt.owner_id, dt.created_at, dt.updated_at, "
          "dm.last_read_message_id, dm.muted, dm.request_state, "
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
            case existing_one_to_one(Conn, Uid, Peer) of
                {ok, Tid} ->
                    %% "new DM" also reopens the old one. less ghost chat, yay.
                    ok = exec(Conn, "UPDATE direct_members SET hidden = false WHERE thread_id = $1 AND user_id = $2", [Tid, Uid]),
                    {ok, #{id => Tid, existing => true}};
                not_found -> create_conversation0(Conn, Uid, Name, UserIds)
            end;
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
    HasAvatar = maps:is_key(<<"avatar_url">>, Patch) andalso not derived_media_url(RawAvatar),
    case is_conversation_owner(Conn, Uid, Cid) of
        true ->
            Now = pw_util:now_ms(),
            ok = exec(Conn, "UPDATE direct_threads SET name = $1, avatar_url = CASE WHEN $2 THEN $3 ELSE avatar_url END, updated_at = $4 WHERE id = $5",
                [Name, HasAvatar, Avatar, Now, Cid]),
            publish_conversation_event(Conn, Cid, #{type => conversation_updated, conversation_id => Cid}),
            {ok, #{updated => true}};
        false ->
            {error, forbidden}
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
    case {is_conversation_owner(Conn, Uid, Cid), RequestedIds, UserIds, users_exist(Conn, RequestedIds), users_not_blocked(Conn, Uid, RequestedIds), ExistingCount + length(UserIds) =< 50} of
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
                                pw_upload_gc:invalidate_user(Uid),
                                case OwnerId =:= Uid of
                                    true ->
                                        %% pass the keys on before the owner leaves.
                                        ok = exec(Conn,
                                            "UPDATE direct_threads SET owner_id = (SELECT user_id FROM direct_members WHERE thread_id = $1 ORDER BY joined_at ASC LIMIT 1) WHERE id = $1",
                                            [Cid]);
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
            publish_conversation_event(Conn, Cid, #{type => conversation_members_changed, conversation_id => Cid}),
            Result;
        _ -> Result
    end;
route({accept_message_request, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case one(Conn, "SELECT request_state FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]) of
        {ok, [<<"pending">>]} ->
            Now = pw_util:now_ms(),
            ok = exec(Conn, "UPDATE direct_members SET request_state = 'accepted' WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]),
            notify_direct_members(Conn, Cid, Uid, #{type => message_request_accepted, conversation_id => Cid}, Now),
            {ok, #{accepted => true, conversation_id => Cid}};
        {ok, [<<"accepted">>]} -> {ok, #{accepted => true, conversation_id => Cid}};
        _ -> {error, no_message_request}
    end;
route({deny_message_request, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case one(Conn, "SELECT request_state FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]) of
        {ok, [<<"pending">>]} ->
            Now = pw_util:now_ms(),
            {ok, MemberRows} = rows(Conn, "SELECT user_id FROM direct_members WHERE thread_id = $1", [Cid]),
            notify_direct_members(Conn, Cid, Uid, #{type => conversation_closed, conversation_id => Cid, reason => request_denied}, Now),
            ok = exec(Conn, "DELETE FROM messages WHERE scope = 'direct' AND scope_id = $1", [Cid]),
            ok = exec(Conn, "DELETE FROM direct_threads WHERE id = $1", [Cid]),
            [pw_upload_gc:invalidate_user(only_id(Row)) || Row <- MemberRows],
            {ok, #{denied => true, conversation_id => Cid}};
        _ -> {error, no_message_request}
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
                "u.created_at, u.last_seen, dm.last_read_message_id, dm.muted, dm.nickname, dm.joined_at "
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
    case {message_body_valid(Plain), conversation_can_send(Conn, Uid, Cid), valid_reply_to(Conn, <<"direct">>, Cid, ReplyTo)} of
        {true, true, true} ->
            Now = pw_util:now_ms(),
            {ok, Mid} = insert_returning(Conn,
                "INSERT INTO messages(scope, scope_id, user_id, body, reply_to_id, created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                [<<"direct">>, Cid, Uid, Body, ReplyTo, Now]),
            insert_upload_refs(Conn, Plain, <<"direct">>, Cid, Now),
            ok = exec(Conn, "UPDATE direct_threads SET updated_at = $1 WHERE id = $2", [Now, Cid]),
            ok = exec(Conn, "UPDATE direct_members SET last_read_message_id = $1 WHERE thread_id = $2 AND user_id = $3", [Mid, Cid, Uid]),
            ok = exec(Conn, "UPDATE direct_members SET hidden = false WHERE thread_id = $1 AND user_id <> $2", [Cid, Uid]),
            {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
            Msg = message_map(Conn, Row),
            pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
            notify_direct_members(Conn, Cid, Uid, #{type => direct_message, conversation_id => Cid, message => Msg}, Now),
            {ok, Msg};
        _ ->
            {error, invalid_message}
    end;
route({record_missed_call, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case conversation_can_send(Conn, Uid, Cid) of
        true ->
            Now = pw_util:now_ms(),
            Body = store_message(<<"Missed call">>),
            {ok, Mid} = insert_returning(Conn,
                "INSERT INTO messages(scope, scope_id, user_id, body, reply_to_id, created_at, kind) "
                "VALUES('direct',$1,$2,$3,NULL,$4,'missed_call') RETURNING id",
                [Cid, Uid, Body, Now]),
            ok = exec(Conn, "UPDATE direct_threads SET updated_at = $1 WHERE id = $2", [Now, Cid]),
            ok = exec(Conn, "UPDATE direct_members SET last_read_message_id = $1 WHERE thread_id = $2 AND user_id = $3", [Mid, Cid, Uid]),
            ok = exec(Conn, "UPDATE direct_members SET hidden = false WHERE thread_id = $1", [Cid]),
            {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
            Msg = message_map(Conn, Row),
            pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
            notify_missed_call_members(Conn, Cid, Uid, Msg, Now),
            {ok, Msg};
        false ->
            {error, forbidden}
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
    exec(Conn, "UPDATE uploads SET status = 'ready', sha256 = $1 WHERE id = $2 AND user_id = $3 AND status = 'pending'", [Hash, Id, Uid]);
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
        {ok, _} -> true;
        _ -> false
    end;
route({member_of_conversation, Uid, Cid0}, Conn) ->
    conversation_can_send(Conn, Uid, pw_util:int(Cid0));
route({member_of_server, Uid, Sid0}, Conn) ->
    is_member(Conn, Uid, pw_util:int(Sid0));
route({conversation_peer_ids, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case conversation_can_send(Conn, Uid, Cid) of
        true ->
            {ok, Rows} = rows(Conn, "SELECT user_id FROM direct_members WHERE thread_id = $1 AND user_id <> $2 AND request_state = 'accepted'", [Cid, Uid]),
            {ok, [only_id(R) || R <- Rows]};
        false ->
            {error, forbidden}
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
    lists:foreach(fun({V, Sqls}) -> migrate_to(Conn, V, Sqls) end, migrations()),
    seed_forums(Conn),
    ok.

ensure_schema_table(Conn) ->
    _ = exec(Conn, "CREATE TABLE IF NOT EXISTS schema_migrations(version integer PRIMARY KEY, applied_at bigint NOT NULL)", []),
    ok.

migrate_to(Conn, Version, Sqls) ->
    case one(Conn, "SELECT version FROM schema_migrations WHERE version = $1", [Version]) of
        {ok, undefined} ->
            [safe_exec(Conn, Sql) || Sql <- Sqls],
            exec(Conn, "INSERT INTO schema_migrations(version, applied_at) VALUES($1,$2)", [Version, pw_util:now_ms()]),
            ok;
        _ ->
            ok
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

%% owner, public profile image, or a readable message scope.
upload_readable(_Conn, Uid, _Id, Uid) when is_integer(Uid) -> true;
upload_readable(Conn, Uid, Id, _OwnerId) ->
    case upload_refs_enforced(Conn) of
        false -> true;
        true ->
            case rows(Conn, "SELECT scope, scope_id FROM upload_refs WHERE upload_id = $1 LIMIT 200", [Id]) of
                {ok, Refs} -> lists:any(fun(Ref) -> upload_ref_grants(Conn, Uid, Ref) end, Refs);
                _ -> false
            end
    end.

upload_ref_grants(_Conn, _Uid, [<<"profile">>, _]) -> true;
upload_ref_grants(_Conn, _Uid, [<<"server">>, _]) -> true;
upload_ref_grants(Conn, Uid, [Scope, ScopeId]) when Scope =:= <<"channel">>; Scope =:= <<"direct">> ->
    can_read_messages(Conn, Uid, Scope, pw_util:int(ScopeId));
upload_ref_grants(_Conn, _Uid, _Ref) -> false.

%% encrypted old messages need a resumable backfill before ACLs turn on.
upload_refs_enforced(Conn) ->
    case persistent_term:get(?UPLOAD_REFS_READY, false) of
        true -> true;
        false ->
            case one(Conn, "SELECT done FROM upload_ref_backfill WHERE id = 1", []) of
                {ok, [true]} ->
                    persistent_term:put(?UPLOAD_REFS_READY, true),
                    true;
                _ -> false
            end
    end.

insert_upload_refs(Conn, Body, Scope, ScopeId, Now)
        when is_binary(Body), is_integer(ScopeId), ScopeId > 0,
             Scope =:= <<"channel">> orelse Scope =:= <<"direct">> ->
    lists:foreach(fun(Id) ->
        %% unknown/deleted ids should not trip the shared DB connection.
        _ = try exec(Conn,
                "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
                "SELECT up.id, $2, $3, $4 FROM uploads up WHERE up.id = $1 "
                "ON CONFLICT DO NOTHING", [Id, Scope, ScopeId, Now])
            catch _:_ -> ok end
    end, extract_file_ids(Body)),
    ok;
insert_upload_refs(_Conn, _Body, _Scope, _ScopeId, _Now) -> ok.

insert_profile_upload_ref(Conn, Uid, <<"/api/files/", Id/binary>>) ->
    case valid_file_id(Id) of
        true ->
            _ = try exec(Conn,
                    "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
                    "SELECT up.id, 'profile', $2, $3 FROM uploads up WHERE up.id = $1 "
                    "ON CONFLICT DO NOTHING", [Id, Uid, pw_util:now_ms()])
                catch _:_ -> ok end,
            ok;
        false -> ok
    end;
insert_profile_upload_ref(_Conn, _Uid, _Url) -> ok.

insert_server_upload_ref(Conn, Sid, <<"/api/files/", Id/binary>>) ->
    case valid_file_id(Id) of
        true ->
            _ = try exec(Conn,
                    "INSERT INTO upload_refs(upload_id, scope, scope_id, created_at) "
                    "SELECT up.id, 'server', $2, $3 FROM uploads up WHERE up.id = $1 "
                    "ON CONFLICT DO NOTHING", [Id, Sid, pw_util:now_ms()])
                catch _:_ -> ok end,
            ok;
        false -> ok
    end;
insert_server_upload_ref(_Conn, _Sid, _Url) -> ok.

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
    case one(Conn, "SELECT avatar_url, banner_url FROM users WHERE id = $1", [Uid]) of
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

create_conversation0(Conn, Uid, Name, UserIds) ->
    Now = pw_util:now_ms(),
    {ok, Tid} = insert_returning(Conn,
        "INSERT INTO direct_threads(name, avatar_url, owner_id, created_at, updated_at) VALUES($1,$2,$3,$4,$5) RETURNING id",
        [Name, <<>>, Uid, Now, Now]),
    IsRequest = case UserIds of [OnlyPeer] -> not is_friend(Conn, Uid, OnlyPeer); _ -> false end,
    [begin
        RequestState = case U =:= Uid orelse not IsRequest of true -> <<"accepted">>; false -> <<"pending">> end,
        exec(Conn,
            "INSERT INTO direct_members(thread_id, user_id, last_read_message_id, muted, nickname, joined_at, request_state) "
            "VALUES($1,$2,0,false,$3,$4,$5) ON CONFLICT (thread_id, user_id) DO NOTHING",
            [Tid, U, <<>>, Now, RequestState])
     end || U <- [Uid | UserIds]],
    CreatedEvent = case IsRequest of
        true -> #{type => message_request, conversation_id => Tid};
        false -> #{type => conversation_created, conversation_id => Tid}
    end,
    notify_direct_members(Conn, Tid, Uid, CreatedEvent, Now),
    {ok, #{id => Tid}}.

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

thread_row_map([Id, Fid, Fname, Uid, U, D, Avatar, Title, Body, Created, Updated, Rc, Views, Pinned, Score, UserVote]) ->
    #{id => Id, forum_id => Fid, forum_name => Fname, user_id => Uid, username => U,
       display_name => D, avatar_url => pw_util:proxied_image(Avatar), title => Title, body => Body, created_at => Created, updated_at => Updated,
       reply_count => Rc, views => Views, pinned => Pinned, score => Score, user_vote => UserVote}.

thread_full_map([Id, Fid, Fname, Uid, U, D, Avatar, Title, Body, Created, Updated, Rc, Locked, Pinned, Views, Score, UserVote]) ->
    #{id => Id, forum_id => Fid, forum_name => Fname, user_id => Uid, username => U,
      display_name => D, avatar_url => pw_util:proxied_image(Avatar), title => Title, body => render_forum_body(Body),
      created_at => Created, updated_at => Updated, reply_count => Rc, locked => Locked,
      pinned => Pinned, views => Views, score => Score, user_vote => UserVote}.

reply_map([Id, Tid, Uid, U, D, Avatar, Body, Created, Updated]) ->
    #{id => Id, thread_id => Tid, user_id => Uid, username => U, display_name => D,
      avatar_url => pw_util:proxied_image(Avatar), body => render_forum_body(Body), created_at => Created, updated_at => Updated}.

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

server_row_map([Id, Owner, Name, Desc, Icon, Banner, Accent, Welcome, Created, Updated, Role, Members]) ->
    #{id => Id, owner_id => Owner, name => Name, description => Desc,
      icon_url => pw_util:proxied_image(Icon), banner_url => pw_util:proxied_image(Banner), accent_color => Accent, welcome_message => Welcome,
      created_at => Created, updated_at => Updated,
      role => Role, member_count => Members}.

server_full_map([Id, Owner, Name, Desc, Icon, Banner, Accent, Welcome, Created, Updated], Role) ->
    #{id => Id, owner_id => Owner, name => Name, description => Desc,
      icon_url => pw_util:proxied_image(Icon), banner_url => pw_util:proxied_image(Banner), accent_color => Accent, welcome_message => Welcome,
      created_at => Created, updated_at => Updated, role => Role}.

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
      role => Role, muted => Muted, joined_at => Joined}.

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
    Sql = "SELECT body, user_id, display_name FROM messages JOIN users ON users.id = messages.user_id WHERE messages.id = $1 AND scope = $2 AND scope_id = $3 AND messages.deleted_at IS NULL",
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
    Sql = "SELECT m.id, m.body, m.user_id, u.display_name FROM messages m JOIN users u ON u.id = m.user_id "
          "WHERE m.id IN (" ++ Placeholders ++ ") AND m.scope = $" ++ integer_to_list(N + 1) ++
          " AND m.scope_id = $" ++ integer_to_list(N + 2) ++ " AND m.deleted_at IS NULL",
    case rows(Conn, Sql, Params) of
        {ok, Rows} ->
            maps:from_list([{Id, #{id => Id, user_id => Uid, display_name => D, body => load_message(Body)}}
                            || [Id, Body, Uid, D] <- Rows]);
        _ -> #{}
    end.

conversation_row_map([Id, Name, Avatar, Owner, Created, Updated, LastRead, Muted, RequestState, Count, LastBody, LastMsg, LastSenderId, LastSenderName, LastSenderUsername, Unread, PeerId, PeerName, PeerAvatar, PeerUsername]) ->
    #{id => Id, name => Name, avatar_url => pw_util:proxied_image(Avatar), owner_id => Owner,
      created_at => Created, updated_at => Updated, last_read_message_id => LastRead, muted => Muted, request_state => RequestState,
      member_count => Count, last_body => load_message(LastBody), last_message_id => LastMsg, unread => Unread,
      last_sender_id => LastSenderId, last_sender_name => LastSenderName, last_sender_username => LastSenderUsername,
      peer_id => PeerId, peer_name => PeerName, peer_avatar_url => pw_util:proxied_image(PeerAvatar), peer_username => PeerUsername}.

conversation_full_map([Id, Name, Avatar, Owner, Created, Updated]) ->
    #{id => Id, name => Name, avatar_url => pw_util:proxied_image(Avatar),
      owner_id => Owner, created_at => Created, updated_at => Updated}.

conversation_member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, LastRead, Muted, Nick, Joined]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
      last_read_message_id => LastRead, muted => Muted, nickname => Nick, joined_at => Joined}.

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
    "t.reply_count, t.views, t.pinned, COALESCE(t.score,0), COALESCE(tv.value,0) "
    "FROM threads t JOIN forums f ON f.id = t.forum_id JOIN users u ON u.id = t.user_id "
    "LEFT JOIN thread_votes tv ON tv.thread_id = t.id AND tv.user_id = $1".

message_select() ->
    "SELECT m.id, m.scope, m.scope_id, m.user_id, u.username, u.display_name, u.avatar_url, "
    "m.body, m.reply_to_id, m.created_at, m.edited_at, m.deleted_at, m.kind, "
    %% The final column is intentionally NULL. Older decoders expect the slot,
    %% but fetching fm.body would pull live source text across scope boundaries.
    "m.forwarded_from_id, fm.user_id, fu.display_name, NULL "
    "FROM messages m JOIN users u ON u.id = m.user_id "
    "LEFT JOIN messages fm ON fm.id = m.forwarded_from_id LEFT JOIN users fu ON fu.id = fm.user_id".

message_sql(Scope, Id, undefined, undefined) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.deleted_at IS NULL ORDER BY m.id DESC LIMIT 80", [Scope, Id]};
message_sql(Scope, Id, Before, undefined) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.deleted_at IS NULL AND m.id < $3 ORDER BY m.id DESC LIMIT 80", [Scope, Id, Before]};
message_sql(Scope, Id, _, After) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.deleted_at IS NULL AND m.id > $3 ORDER BY m.id ASC LIMIT 250", [Scope, Id, After]}.

validate_thread(Conn, F, T, B) ->
    case {F, byte_size(T) >= 3, byte_size(B) > 0, one(Conn, "SELECT id FROM forums WHERE id = $1", [F])} of
        {I, true, true, {ok, [_]}} when is_integer(I) -> ok;
        _ -> {error, invalid_thread}
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

can_manage_server(Conn, Uid, Sid) ->
    case one(Conn, "SELECT role FROM server_members WHERE server_id = $1 AND user_id = $2", [Sid, Uid]) of
        {ok, [<<"owner">>]} -> true;
        {ok, [<<"admin">>]} -> true;
        _ -> false
    end.

channel_server_member(Conn, Uid, Cid) ->
    case one(Conn,
        "SELECT c.server_id FROM channels c JOIN server_members sm ON sm.server_id = c.server_id AND sm.user_id = $1 WHERE c.id = $2",
        [Uid, Cid]) of
        {ok, [Sid]} -> {ok, Sid};
        _ -> {error, forbidden}
    end.

can_read_messages(Conn, Uid, <<"channel">>, Id) ->
    case channel_server_member(Conn, Uid, Id) of
        {ok, _} -> true;
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
        {ok, _} -> true;
        _ -> false
    end;
can_modify_message_scope(Conn, Uid, <<"direct">>, Id) ->
    is_conversation_member(Conn, Uid, Id);
can_modify_message_scope(_, _, _, _) -> false.

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

notify_thread_participants(Conn, Tid, Sender, Body, Now) ->
    {ok, Rows} = rows(Conn,
        "SELECT DISTINCT user_id FROM (SELECT user_id FROM threads WHERE id = $1 "
        "UNION SELECT user_id FROM replies WHERE thread_id = $1) u WHERE user_id <> $2",
        [Tid, Sender]),
    {ok, Roster} = rows(Conn,
        "SELECT DISTINCT u.id, u.username FROM users u JOIN "
        "(SELECT user_id FROM threads WHERE id = $1 UNION SELECT user_id FROM replies WHERE thread_id = $1) p "
        "ON u.id = p.user_id WHERE u.id <> $2",
        [Tid, Sender]),
    Mentioned = pw_mention:resolve(Body, Roster),
    Url = <<"#/thread/", (integer_to_binary(Tid))/binary>>,
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
    {ok, Rows} = rows(Conn, "SELECT user_id FROM server_members WHERE server_id = $1 AND user_id <> $2", [Sid, Sender]),
    {ok, Roster} = rows(Conn,
        "SELECT u.id, u.username FROM users u JOIN server_members sm ON sm.user_id = u.id "
        "WHERE sm.server_id = $1 AND u.id <> $2", [Sid, Sender]),
    Mentioned = case SuppressMentions of true -> []; false -> pw_mention:resolve(Body, Roster) end,
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
            Fs = [{<<"general">>, <<"General">>, <<"Community discussion and project notes.">>, 1},
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
