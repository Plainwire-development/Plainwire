-module(pw_db).
-behaviour(gen_server).
-export([
    start_link/0,
    health/0,
    register/3, login/2, session/1, session_fast/1, logout/1, me/1, update_profile/3,
    sync/2, users/1, profile/2,
    friend_request/2, friend_accept/2, friend_remove/2, friend_block/2, friends/1,
    forums/1, create_forum/4, join_forum/2, leave_forum/2, threads/3, thread/2, create_thread/4, reply_thread/3, vote_thread/3,
    servers/1, create_server/3, update_server/3, server/2, create_channel/4,
    create_invite/4, invite_preview/1, join_invite/2,
    messages/5, post_channel_message/4, delete_message/2,
    conversations/1, create_conversation/3, update_conversation/4,
    add_conversation_members/3, conversation/2, post_direct_message/4,
    leave_conversation/2, accept_message_request/2, deny_message_request/2,
    mark_conversation_read/2, notifications/1, mark_notifications_seen/1, mark_url_seen/2,
    member_of_channel/2, member_of_conversation/2, member_of_server/2, conversation_peer_ids/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(st, {}).
-record(pool, {conns, size, counter}).
-define(SERVER, ?MODULE).
-define(POOL_KEY, pw_db_pool).
-define(MAX_BODY, 12000).
-define(MAX_MSG, 5000).

-define(SESSION_CACHE, pw_session_cache).

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

health() ->
    try
        #pool{conns = Conns} = persistent_term:get(?POOL_KEY),
        Conn = element(1, Conns),
        case rows(Conn, "SELECT 1", []) of
            {ok, _} -> ok;
            _ -> {error, database_unavailable}
        end
    catch
        _:_ -> {error, database_unavailable}
    end.

session_fast(Token) ->
    case Token of
        undefined -> {error, no_session};
        <<>> -> {error, no_session};
        _ ->
            H = pw_util:sha256_hex(Token),
            Now = pw_util:now_ms(),
            case ets:lookup(?SESSION_CACHE, H) of
                [{H, Uid, Expires}] when Expires > Now ->
                    case ets:lookup(?SESSION_CACHE, {user, Uid}) of
                        [{_, Session}] -> {ok, Session};
                        _ -> {error, no_session}
                    end;
                _ -> {error, no_session}
            end
    end.

call(Msg) ->
    #pool{conns = Conns, size = Size, counter = Counter} = persistent_term:get(?POOL_KEY),
    Idx = atomics:add_get(Counter, 1, 1) rem Size + 1,
    Conn = element(Idx, Conns),
    try route_with_reconnect(Msg, Conn) of
        {Reply, Conn} ->
            Reply;
        {Reply, Conn1} ->
            update_pool_conn(Idx, Conn1),
            Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, database_unavailable};
        exit:{normal, _} -> {error, database_unavailable};
        exit:Reason ->
            error_logger:error_msg("DB call exit ~p for ~p~n", [Reason, safe_log_msg(Msg)]),
            {error, database_unavailable}
    end.

update_pool_conn(Idx, NewConn) ->
    Pool = persistent_term:get(?POOL_KEY),
    NewConns = setelement(Idx, Pool#pool.conns, NewConn),
    persistent_term:put(?POOL_KEY, Pool#pool{conns = NewConns}).

register(U, D, P) -> call({register, U, D, P}).
login(U, P) -> call({login, U, P}).
session(T) -> call({session, T}).
logout(T) -> call({logout, T}).
me(Uid) -> call({me, Uid}).
update_profile(Uid, Display, Patch) -> call({update_profile, Uid, Display, Patch}).
sync(Uid, Since) -> call({sync, Uid, Since}).
users(Q) -> call({users, Q}).
profile(Viewer, UserId) -> call({profile, Viewer, UserId}).
friend_request(Uid, Target) -> call({friend_request, Uid, Target}).
friend_accept(Uid, Target) -> call({friend_accept, Uid, Target}).
friend_remove(Uid, Target) -> call({friend_remove, Uid, Target}).
friend_block(Uid, Target) -> call({friend_block, Uid, Target}).
friends(Uid) -> call({friends, Uid}).
forums(Uid) -> call({forums, Uid}).
create_forum(Uid, Name, Slug, Description) -> call({create_forum, Uid, Name, Slug, Description}).
join_forum(Uid, ForumId) -> call({join_forum, Uid, ForumId}).
leave_forum(Uid, ForumId) -> call({leave_forum, Uid, ForumId}).
threads(Uid, ForumId, Search) -> call({threads, Uid, ForumId, Search}).
thread(Uid, ThreadId) -> call({thread, Uid, ThreadId}).
create_thread(Uid, ForumId, Title, Body) -> call({create_thread, Uid, ForumId, Title, Body}).
reply_thread(Uid, ThreadId, Body) -> call({reply_thread, Uid, ThreadId, Body}).
vote_thread(Uid, ThreadId, Value) -> call({vote_thread, Uid, ThreadId, Value}).
servers(Uid) -> call({servers, Uid}).
create_server(Uid, Name, Desc) -> call({create_server, Uid, Name, Desc}).
update_server(Uid, Sid, Patch) -> call({update_server, Uid, Sid, Patch}).
server(Uid, ServerId) -> call({server, Uid, ServerId}).
create_channel(Uid, ServerId, Name, Kind) -> call({create_channel, Uid, ServerId, Name, Kind}).
create_invite(Uid, ServerId, ChannelId, MaxUses) -> call({create_invite, Uid, ServerId, ChannelId, MaxUses}).
invite_preview(Code) -> call({invite_preview, Code}).
join_invite(Uid, Code) -> call({join_invite, Uid, Code}).
messages(Uid, Scope, ScopeId, Before, After) -> call({messages, Uid, Scope, ScopeId, Before, After}).
post_channel_message(Uid, ChannelId, Body, ReplyTo) -> call({post_channel_message, Uid, ChannelId, Body, ReplyTo}).
delete_message(Uid, Mid) -> call({delete_message, Uid, Mid}).
conversations(Uid) -> call({conversations, Uid}).
create_conversation(Uid, Name, UserIds) -> call({create_conversation, Uid, Name, UserIds}).
update_conversation(Uid, Cid, Name, Patch) -> call({update_conversation, Uid, Cid, Name, Patch}).
add_conversation_members(Uid, Cid, UserIds) -> call({add_conversation_members, Uid, Cid, UserIds}).
conversation(Uid, Cid) -> call({conversation, Uid, Cid}).
leave_conversation(Uid, Cid) -> call({leave_conversation, Uid, Cid}).
accept_message_request(Uid, Cid) -> call({accept_message_request, Uid, Cid}).
deny_message_request(Uid, Cid) -> call({deny_message_request, Uid, Cid}).
mark_conversation_read(Uid, Cid) -> call({mark_conversation_read, Uid, Cid}).
post_direct_message(Uid, Cid, Body, ReplyTo) -> call({post_direct_message, Uid, Cid, Body, ReplyTo}).
notifications(Uid) -> call({notifications, Uid}).
mark_notifications_seen(Uid) -> call({mark_notifications_seen, Uid}).
mark_url_seen(Uid, Url) -> call({mark_url_seen, Uid, Url}).
member_of_channel(Uid, ChannelId) -> call({member_of_channel, Uid, ChannelId}).
member_of_conversation(Uid, Cid) -> call({member_of_conversation, Uid, Cid}).
member_of_server(Uid, Sid) -> call({member_of_server, Uid, Sid}).
conversation_peer_ids(Uid, Cid) -> call({conversation_peer_ids, Uid, Cid}).

init([]) ->
    application:ensure_all_started(inets),
    _ = ets:new(?SESSION_CACHE, [named_table, public, set, {read_concurrency, true}]),
    {ok, MigConn} = connect_with_retry(10, 500),
    ok = migrate(MigConn),
    try epgsql:close(MigConn) catch _:_ -> ok end,
    PoolSize = pw_util:env_int("PLAINWIRE_DB_POOL_SIZE", 10),
    Conns = list_to_tuple([
        begin
            {ok, C} = connect_with_retry(5, 500),
            C
        end || _ <- lists:seq(1, PoolSize)
    ]),
    Counter = atomics:new(1, [{signed, false}]),
    persistent_term:put(?POOL_KEY, #pool{conns = Conns, size = PoolSize, counter = Counter}),
    {ok, #st{}}.

handle_call(_, _From, St) -> {reply, {error, unknown}, St}.

handle_cast(_, St) -> {noreply, St}.
handle_info(_, St) -> {noreply, St}.
terminate(_, _) ->
    try
        #pool{conns = Conns, size = Size} = persistent_term:get(?POOL_KEY),
        [try epgsql:close(element(I, Conns)) catch _:_ -> ok end || I <- lists:seq(1, Size)],
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
read_msg({update_profile, _, _, _}) -> false;
read_msg({friend_request, _, _}) -> false;
read_msg({friend_accept, _, _}) -> false;
read_msg({friend_remove, _, _}) -> false;
read_msg({friend_block, _, _}) -> false;
read_msg({create_thread, _, _, _, _}) -> false;
read_msg({reply_thread, _, _, _}) -> false;
read_msg({create_server, _, _, _}) -> false;
read_msg({update_server, _, _, _}) -> false;
read_msg({create_channel, _, _, _, _}) -> false;
read_msg({create_invite, _, _, _, _}) -> false;
read_msg({join_invite, _, _}) -> false;
read_msg({post_channel_message, _, _, _, _}) -> false;
read_msg({delete_message, _, _}) -> false;
read_msg({create_conversation, _, _, _}) -> false;
read_msg({update_conversation, _, _, _, _}) -> false;
read_msg({add_conversation_members, _, _, _}) -> false;
read_msg({leave_conversation, _, _}) -> false;
read_msg({accept_message_request, _, _}) -> false;
read_msg({deny_message_request, _, _}) -> false;
read_msg({mark_conversation_read, _, _}) -> false;
read_msg({post_direct_message, _, _, _, _}) -> false;
read_msg({mark_notifications_seen, _}) -> false;
read_msg({mark_url_seen, _, _}) -> false;
read_msg(_) -> true.

safe_log_msg({register, _, _, _}) -> {register, redacted};
safe_log_msg({login, _, _}) -> {login, redacted};
safe_log_msg({session, _}) -> {session, redacted};
safe_log_msg({logout, _}) -> {logout, redacted};
safe_log_msg({post_channel_message, Uid, ChannelId, _, ReplyTo}) ->
    {post_channel_message, Uid, ChannelId, redacted, ReplyTo};
safe_log_msg({post_direct_message, Uid, Cid, _, ReplyTo}) ->
    {post_direct_message, Uid, Cid, redacted, ReplyTo};
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
    _ = epgsql:squery(Conn, "SET statement_timeout = " ++ integer_to_list(StatementMs)),
    _ = epgsql:squery(Conn, "SET idle_in_transaction_session_timeout = " ++ integer_to_list(TxMs)),
    ok.

clamp_timeout(N) when is_integer(N), N >= 1000, N =< 120000 -> N;
clamp_timeout(N) when is_integer(N), N < 1000 -> 1000;
clamp_timeout(_) -> 15000.

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
    case {byte_size(U) >= 3, byte_size(U) =< 24, byte_size(P) >= 8} of
        {true, true, true} ->
            case one(Conn, "SELECT id FROM users WHERE username = $1", [U]) of
                {ok, undefined} ->
                    Salt = pw_util:random_token(18),
                    Hash = pw_util:pbkdf2(P, Salt),
                    Now = pw_util:now_ms(),
                    {ok, Id} = insert_returning(Conn,
                        "INSERT INTO users(username,display_name,password_hash,password_salt,bio,avatar_url,banner_url,status,theme,created_at,updated_at,last_seen) "
                        "VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING id",
                        [U, D, Hash, Salt, <<>>, <<>>, <<>>, <<>>, <<"system">>, Now, Now, Now]),
                    {ok, make_session(Conn, Id)};
                _ ->
                    {error, username_taken}
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
                true -> {ok, make_session(Conn, Id)};
                false -> {error, bad_login}
            end;
        _ ->
            _ = pw_util:pbkdf2(P, <<"plainwire-login-timing-pad">>),
            {error, bad_login}
    end;
route(health, Conn) ->
    case one(Conn, "SELECT 1", []) of
        {ok, [1]} -> {ok, #{database => ok}};
        _ -> {error, database_unavailable}
    end;
route({session, Token}, Conn) ->
    case Token of
        undefined -> {error, no_session};
        <<>> -> {error, no_session};
        _ ->
            H = pw_util:sha256_hex(Token),
            Now = pw_util:now_ms(),
            Sql = "SELECT s.user_id, s.csrf, u.username, u.display_name, u.bio, u.avatar_url, "
                  "u.banner_url, u.status, u.theme, u.created_at, u.last_seen "
                  "FROM sessions s JOIN users u ON u.id = s.user_id "
                  "WHERE s.token_hash = $1 AND s.expires_at > $2",
            case one(Conn, Sql, [H, Now]) of
                {ok, [Uid, Csrf, Un, Dn, Bio, Av, Ban, St, Th, Cr, Ls]} ->
                    Cutoff = Now - 60000,
                    _ = exec(Conn, "UPDATE sessions SET last_seen = $1 WHERE token_hash = $2 AND last_seen < $3", [Now, H, Cutoff]),
                    _ = exec(Conn, "UPDATE users SET last_seen = $1 WHERE id = $2 AND last_seen < $3", [Now, Uid, Cutoff]),
                    Session = #{user => user_map_full([Uid, Un, Dn, Bio, Av, Ban, St, Th, Cr, Ls]),
                           csrf => Csrf, server_time => Now},
                    ets:insert(?SESSION_CACHE, [{H, Uid, Now + 300000}, {{user, Uid}, Session}]),
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
    Avatar = store_image_url(maps:get(<<"avatar_url">>, Patch, <<>>)),
    Banner = store_image_url(maps:get(<<"banner_url">>, Patch, <<>>)),
    Status = pw_util:clean_text(maps:get(<<"status">>, Patch, <<>>), 100),
    Theme = pw_util:clean_text(maps:get(<<"theme">>, Patch, <<"system">>), 32),
    Now = pw_util:now_ms(),
    ok = exec(Conn,
        "UPDATE users SET display_name = $1, bio = $2, avatar_url = $3, banner_url = $4, "
        "status = $5, theme = $6, updated_at = $7 WHERE id = $8",
        [Display, Bio, Avatar, Banner, Status, Theme, Now, Uid]),
    {ok, #{updated => true}};
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
    Like = <<"%", Q/binary, "%">>,
    {ok, Rows} = rows(Conn,
        "SELECT id, username, display_name, bio, avatar_url, banner_url, status, theme, created_at, last_seen "
        "FROM users WHERE username ILIKE $1 OR display_name ILIKE $2 "
        "ORDER BY last_seen DESC LIMIT 40", [Like, Like]),
    {ok, [user_map(R) || R <- Rows]};
route({profile, Viewer, UserId0}, Conn) ->
    UserId = pw_util:int(UserId0),
    case route({me, UserId}, Conn) of
        {ok, U} ->
            Rel = friendship_status(Conn, Viewer, UserId),
            {ok, #{user => U, relationship => Rel}};
        E ->
            E
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
            {ok, #{status => blocked}}
    end;
route({friends, Uid}, Conn) ->
    Sql = "SELECT fr.status, fr.requester_id, fr.addressee_id, u.id, u.username, u.display_name, "
          "u.bio, u.avatar_url, u.banner_url, u.status, u.theme, u.created_at, u.last_seen "
          "FROM friendships fr JOIN users u ON u.id = CASE WHEN fr.user_low = $1 THEN fr.user_high ELSE fr.user_low END "
          "WHERE fr.user_low = $1 OR fr.user_high = $1 ORDER BY fr.updated_at DESC",
    {ok, Rows} = rows(Conn, Sql, [Uid]),
    {ok, [friend_map(R, Uid) || R <- Rows]};
route({forums, Uid}, Conn) ->
    Sql = "SELECT f.id, f.slug, f.name, f.description, f.position, "
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
                        "INSERT INTO forums(slug, name, description, position) VALUES($1,$2,$3,$4) RETURNING id",
                        [Slug, Name, Desc, Pos]),
                    ok = exec(Conn, "INSERT INTO forum_members(forum_id, user_id, joined_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING", [Fid, Uid, Now]),
                    {ok, #{id => Fid}}
            end
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
    _ = exec(Conn, "UPDATE threads SET views = views + 1 WHERE id = $1", [ThreadId]),
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
    Sql = "SELECT s.id, s.owner_id, s.name, s.description, s.icon_url, s.created_at, s.updated_at, sm.role, "
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
                        [Sid, <<"Lobby">>, <<"voice">>, 2, <<>>, Now]),
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
            Icon = store_image_url(maps:get(<<"icon_url">>, Patch, <<>>)),
            case duplicate_server_name(Conn, Uid, Sid, Name) of
                true ->
                    {error, server_exists};
                false ->
                    ok = exec(Conn,
                        "UPDATE servers SET name = COALESCE(NULLIF($1,''), name), "
                        "description = COALESCE(NULLIF($2,''), description), "
                        "icon_url = CASE WHEN $3 = '' THEN icon_url ELSE $3 END, updated_at = $4 WHERE id = $5",
                        [Name, Desc, Icon, Now, Sid]),
                    pw_hub:broadcast({server, Sid}, #{type => server_updated, server_id => Sid}),
                    route({server, Uid, Sid}, Conn)
            end;
        false ->
            {error, forbidden}
    end;
route({server, Uid, ServerId0}, Conn) ->
    Sid = pw_util:int(ServerId0),
    case one(Conn, "SELECT role FROM server_members WHERE server_id = $1 AND user_id = $2", [Sid, Uid]) of
        {ok, [Role]} ->
            {ok, S} = one(Conn, "SELECT id, owner_id, name, description, icon_url, created_at, updated_at FROM servers WHERE id = $1", [Sid]),
            {ok, Ch} = rows(Conn, "SELECT id, server_id, name, kind, position, topic, created_at FROM channels WHERE server_id = $1 ORDER BY position ASC, id ASC", [Sid]),
            {ok, Ms} = rows(Conn,
                "SELECT u.id, u.username, u.display_name, u.bio, u.avatar_url, u.banner_url, u.status, u.theme, "
                "u.created_at, u.last_seen, sm.role, sm.muted, sm.joined_at "
                "FROM server_members sm JOIN users u ON u.id = sm.user_id WHERE sm.server_id = $1 "
                "ORDER BY CASE sm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, u.display_name ASC",
                [Sid]),
            {ok, #{server => server_full_map(S, Role), channels => [channel_map(R) || R <- Ch], members => [member_map(R) || R <- Ms]}};
        _ ->
            {error, forbidden}
    end;
route({create_channel, Uid, Sid0, Name0, Kind0}, Conn) ->
    Sid = pw_util:int(Sid0),
    Name = pw_util:clean_text(Name0, 40),
    Kind = case pw_util:clean_text(Kind0, 10) of <<"voice">> -> <<"voice">>; _ -> <<"text">> end,
    case {byte_size(Name) >= 1, can_manage_server(Conn, Uid, Sid)} of
        {true, true} ->
            case one(Conn, "SELECT id FROM channels WHERE server_id = $1 AND lower(name) = lower($2) LIMIT 1", [Sid, Name]) of
                {ok, [_]} ->
                    {error, channel_exists};
                _ ->
                    Now = pw_util:now_ms(),
                    {ok, [Pos]} = one(Conn, "SELECT COALESCE(max(position), 0) + 1 FROM channels WHERE server_id = $1", [Sid]),
                    {ok, Cid} = insert_returning(Conn,
                        "INSERT INTO channels(server_id, name, kind, position, topic, created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                        [Sid, Name, Kind, Pos, <<>>, Now]),
                    pw_hub:broadcast({server, Sid}, #{type => channel_created, server_id => Sid, channel_id => Cid}),
                    {ok, #{id => Cid}}
            end;
        {false, _} ->
            {error, invalid_channel_name};
        {_, false} ->
            {error, forbidden}
    end;
route({create_invite, Uid, Sid0, ChannelId0, MaxUses0}, Conn) ->
    Sid = pw_util:int(Sid0),
    ChannelId = pw_util:int(ChannelId0),
    MaxUses = normalize_max_uses(pw_util:int(MaxUses0)),
    case {can_manage_server(Conn, Uid, Sid), valid_invite_channel(Conn, Sid, ChannelId)} of
        {true, true} ->
            case existing_invite(Conn, Sid, ChannelId, MaxUses) of
                {ok, Code} ->
                    {ok, #{code => Code, url => <<"#invite/", Code/binary>>, existing => true}};
                not_found ->
                    Code = pw_util:random_token(12),
                    Now = pw_util:now_ms(),
                    ok = exec(Conn,
                        "INSERT INTO server_invites(code, server_id, channel_id, creator_id, max_uses, uses, created_at, expires_at, revoked) "
                        "VALUES($1,$2,$3,$4,$5,0,$6,0,false)",
                        [Code, Sid, ChannelId, Uid, MaxUses, Now]),
                    {ok, #{code => Code, url => <<"#invite/", Code/binary>>}}
            end;
        {false, _} ->
            {error, forbidden};
        {_, false} ->
            {error, invalid_channel}
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
    with_tx(Conn, fun() -> join_invite_tx(Conn, Uid, Code, Now) end);
route({messages, Uid, Scope0, ScopeId0, Before0, After0}, Conn) ->
    Scope = pw_util:clean_text(Scope0, 16),
    ScopeId = pw_util:int(ScopeId0),
    Before = pw_util:int(Before0),
    After = pw_util:int(After0),
    case can_read_messages(Conn, Uid, Scope, ScopeId) of
        true ->
            {Sql, Params} = message_sql(Scope, ScopeId, Before, After),
            {ok, Rows} = rows(Conn, Sql, Params),
            ReplyIds = [R || [_,_,_,_,_,_,_,_,R,_] <- Rows, R =/= null, is_integer(R)],
            ReplyMap = batch_replied_messages(Conn, ReplyIds, Scope, ScopeId),
            {ok, [message_map_with_replies(R, ReplyMap) || R <- Rows]};
        false ->
            {error, forbidden}
    end;
route({delete_message, Uid, Mid0}, Conn) ->
    Mid = pw_util:int(Mid0),
    case one(Conn, "SELECT user_id, scope, scope_id FROM messages WHERE id = $1 AND deleted_at IS NULL", [Mid]) of
        {ok, [Uid, Scope, ScopeId]} ->
            Now = pw_util:now_ms(),
            ok = exec(Conn, "UPDATE messages SET deleted_at = $1, body = '' WHERE id = $2", [Now, Mid]),
            BroadcastKey = case Scope of <<"direct">> -> {direct, ScopeId}; <<"channel">> -> {channel, ScopeId} end,
            pw_hub:broadcast(BroadcastKey, #{type => message_deleted, scope => Scope, scope_id => ScopeId, message_id => Mid}),
            {ok, #{deleted => true}};
        {ok, _} ->
            {error, forbidden};
        _ ->
            {error, not_found}
    end;
route({post_channel_message, Uid, ChannelId0, Body0, ReplyTo0}, Conn) ->
    Cid = pw_util:int(ChannelId0),
    Body = store_message(pw_util:clean_text(Body0, ?MAX_MSG)),
    ReplyTo = pw_util:int(ReplyTo0),
    case {byte_size(Body) > 0, channel_server_member(Conn, Uid, Cid), valid_reply_to(Conn, <<"channel">>, Cid, ReplyTo)} of
        {true, {ok, Sid}, true} ->
            Now = pw_util:now_ms(),
            {ok, Mid} = insert_returning(Conn,
                "INSERT INTO messages(scope, scope_id, user_id, body, reply_to_id, created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                [<<"channel">>, Cid, Uid, Body, ReplyTo, Now]),
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
          "(SELECT body FROM messages WHERE scope = 'direct' AND scope_id = dt.id ORDER BY id DESC LIMIT 1), "
          "(SELECT id FROM messages WHERE scope = 'direct' AND scope_id = dt.id ORDER BY id DESC LIMIT 1), "
          "(SELECT count(*) FROM messages WHERE scope = 'direct' AND scope_id = dt.id "
          "AND id > dm.last_read_message_id AND user_id <> $1), "
          "COALESCE((SELECT u.display_name FROM direct_members dm2 JOIN users u ON u.id = dm2.user_id "
          "WHERE dm2.thread_id = dt.id AND dm2.user_id <> $1 ORDER BY u.display_name ASC LIMIT 1), ''), "
          "COALESCE((SELECT u.avatar_url FROM direct_members dm2 JOIN users u ON u.id = dm2.user_id "
          "WHERE dm2.thread_id = dt.id AND dm2.user_id <> $1 ORDER BY u.display_name ASC LIMIT 1), ''), "
          "COALESCE((SELECT u.username FROM direct_members dm2 JOIN users u ON u.id = dm2.user_id "
          "WHERE dm2.thread_id = dt.id AND dm2.user_id <> $1 ORDER BY u.display_name ASC LIMIT 1), '') "
          "FROM direct_threads dt JOIN direct_members dm ON dm.thread_id = dt.id AND dm.user_id = $1 "
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
                {ok, Tid} -> {ok, #{id => Tid, existing => true}};
                not_found -> create_conversation0(Conn, Uid, Name, UserIds)
            end;
        {_, _, true, true} ->
            create_conversation0(Conn, Uid, Name, UserIds)
    end;
route({update_conversation, Uid, Cid0, Name0, Patch}, Conn) ->
    Cid = pw_util:int(Cid0),
    Name = pw_util:clean_text(Name0, 80),
    Avatar = store_image_url(maps:get(<<"avatar_url">>, Patch, <<>>)),
    case is_conversation_owner(Conn, Uid, Cid) of
        true ->
            Now = pw_util:now_ms(),
            ok = exec(Conn, "UPDATE direct_threads SET name = $1, avatar_url = $2, updated_at = $3 WHERE id = $4",
                [Name, Avatar, Now, Cid]),
            pw_hub:broadcast({direct, Cid}, #{type => conversation_updated, conversation_id => Cid}),
            {ok, #{updated => true}};
        false ->
            {error, forbidden}
    end;
route({add_conversation_members, Uid, Cid0, UserIds0}, Conn) ->
    Cid = pw_util:int(Cid0),
    UserIds = lists:usort([X || X <- [pw_util:int(Y) || Y <- ensure_list(UserIds0)], is_integer(X), X =/= Uid]),
    ExistingCount = conversation_member_count(Conn, Cid),
    case {is_conversation_owner(Conn, Uid, Cid), UserIds, users_exist(Conn, UserIds), users_not_blocked(Conn, Uid, UserIds), ExistingCount + length(UserIds) =< 50} of
        {true, [], _, _, _} ->
            {error, invalid_members};
        {true, _, false, _, _} ->
            {error, invalid_members};
        {true, _, _, false, _} ->
            {error, forbidden};
        {true, _, _, _, false} ->
            {error, too_many_members};
        {true, _, true, true, true} ->
            Now = pw_util:now_ms(),
            [exec(Conn,
                "INSERT INTO direct_members(thread_id, user_id, last_read_message_id, muted, nickname, joined_at) "
                "VALUES($1,$2,0,false,$3,$4) ON CONFLICT (thread_id, user_id) DO NOTHING",
                [Cid, U, <<>>, Now]) || U <- UserIds],
            notify_direct_members(Conn, Cid, Uid, #{type => conversation_members_added, conversation_id => Cid}, Now),
            {ok, #{added => length(UserIds)}};
        {false, _, _, _, _} ->
            {error, forbidden}
    end;
route({leave_conversation, Uid, Cid0}, Conn) ->
    Cid = pw_util:int(Cid0),
    case is_conversation_member(Conn, Uid, Cid) of
        true ->
            case conversation_member_count(Conn, Cid) =< 2 of
                true ->
                    {ok, #{left => false, closed => true}};
                false ->
                    ok = exec(Conn, "DELETE FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]),
                    {ok, #{left => true}}
            end;
        false ->
            {error, not_found}
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
            notify_direct_members(Conn, Cid, Uid, #{type => conversation_closed, conversation_id => Cid, reason => request_denied}, Now),
            ok = exec(Conn, "DELETE FROM messages WHERE scope = 'direct' AND scope_id = $1", [Cid]),
            ok = exec(Conn, "DELETE FROM direct_threads WHERE id = $1", [Cid]),
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
    Body = store_message(pw_util:clean_text(Body0, ?MAX_MSG)),
    ReplyTo = pw_util:int(ReplyTo0),
    case {byte_size(Body) > 0, conversation_can_send(Conn, Uid, Cid), valid_reply_to(Conn, <<"direct">>, Cid, ReplyTo)} of
        {true, true, true} ->
            Now = pw_util:now_ms(),
            {ok, Mid} = insert_returning(Conn,
                "INSERT INTO messages(scope, scope_id, user_id, body, reply_to_id, created_at) VALUES($1,$2,$3,$4,$5,$6) RETURNING id",
                [<<"direct">>, Cid, Uid, Body, ReplyTo, Now]),
            ok = exec(Conn, "UPDATE direct_threads SET updated_at = $1 WHERE id = $2", [Now, Cid]),
            ok = exec(Conn, "UPDATE direct_members SET last_read_message_id = $1 WHERE thread_id = $2 AND user_id = $3", [Mid, Cid, Uid]),
            {ok, Row} = one(Conn, message_select() ++ " WHERE m.id = $1", [Mid]),
            Msg = message_map(Conn, Row),
            pw_hub:broadcast({direct, Cid}, #{type => message_created, scope => direct, scope_id => Cid, message => Msg}),
            notify_direct_members(Conn, Cid, Uid, #{type => direct_message, conversation_id => Cid, message => Msg}, Now),
            {ok, Msg};
        _ ->
            {error, invalid_message}
    end;
route({notifications, Uid}, Conn) ->
    {ok, Rows} = rows(Conn, "SELECT id, kind, body, url, seen, created_at FROM notifications WHERE user_id = $1 ORDER BY id DESC LIMIT 120", [Uid]),
    {ok, [notification_map(R) || R <- Rows]};
route({mark_notifications_seen, Uid}, Conn) ->
    ok = exec(Conn, "UPDATE notifications SET seen = true WHERE user_id = $1", [Uid]),
    {ok, #{seen => true}};
route({mark_url_seen, Uid, Url}, Conn) ->
    mark_url_seen0(Conn, Uid, pw_util:clean_text(Url, 240)),
    {ok, #{seen => true}};
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

make_session(Conn, Uid) ->
    Token = pw_util:random_token(32),
    Csrf = pw_util:random_token(24),
    H = pw_util:sha256_hex(Token),
    Now = pw_util:now_ms(),
    Expires = Now + 30 * 24 * 60 * 60 * 1000,
    ok = exec(Conn, "INSERT INTO sessions(token_hash, user_id, csrf, created_at, expires_at, last_seen) VALUES($1,$2,$3,$4,$5,$6)",
        [H, Uid, Csrf, Now, Expires, Now]),
    {ok, User} = route({me, Uid}, Conn),
    Session = #{token => Token, csrf => Csrf, user => User, server_time => Now},
    ets:insert(?SESSION_CACHE, [{H, Uid, Now + 300000}, {{user, Uid}, Session}]),
    Session.

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
                    pw_hub:broadcast({server, Sid}, #{type => member_joined, server_id => Sid, user_id => Uid}),
                    ok
            end,
            {ok, #{server_id => Sid, channel_id => ChannelId}};
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
    R = if Params =:= [] -> epgsql:squery(Conn, Sql);
           true -> epgsql:equery(Conn, Sql, Params)
        end,
    case R of
        {ok, _, _, Rows} when is_list(Rows), Rows =/= [] -> {ok, hd(to_list(hd(Rows)))};
        {ok, _, _} -> {ok, 1};
        {ok, _} -> {ok, 1};
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    end.

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
                true -> pw_media:cache_data_url(Url);
                false -> <<>>
            end;
        <<"/api/media/", _/binary>> -> Url;
        <<"http://", _/binary>> -> Url;
        <<"https://", _/binary>> -> Url;
        _ -> <<>>
    end.

normalize_max_uses(undefined) -> 0;
normalize_max_uses(I) when is_integer(I), I > 0, I =< 1000 -> I;
normalize_max_uses(I) when is_integer(I), I > 1000 -> 1000;
normalize_max_uses(_) -> 0.

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

valid_invite_channel(_Conn, _Sid, undefined) -> true;
valid_invite_channel(Conn, Sid, ChannelId) ->
    case one(Conn, "SELECT id FROM channels WHERE id = $1 AND server_id = $2", [ChannelId, Sid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

ensure_list(L) when is_list(L) -> L;
ensure_list(_) -> [].

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

forum_map([Id, Slug, Name, Desc, Pos, Tc, Rc, Last, Members, Joined]) ->
    #{id => pw_util:int(Id), slug => Slug, name => Name, description => Desc, position => pw_util:int(Pos),
      thread_count => pw_util:int(Tc), reply_count => pw_util:int(Rc), last_at => db_null(Last),
      member_count => pw_util:int(Members), joined => Joined}.

thread_row_map([Id, Fid, Fname, Uid, U, D, Avatar, Title, Body, Created, Updated, Rc, Views, Pinned, Score, UserVote]) ->
    #{id => Id, forum_id => Fid, forum_name => Fname, user_id => Uid, username => U,
       display_name => D, avatar_url => pw_util:proxied_image(Avatar), title => Title, body => Body, created_at => Created, updated_at => Updated,
       reply_count => Rc, views => Views, pinned => Pinned, score => Score, user_vote => UserVote}.

thread_full_map([Id, Fid, Fname, Uid, U, D, Avatar, Title, Body, Created, Updated, Rc, Locked, Pinned, Views, Score, UserVote]) ->
    #{id => Id, forum_id => Fid, forum_name => Fname, user_id => Uid, username => U,
      display_name => D, avatar_url => pw_util:proxied_image(Avatar), title => Title, body => Body,
      created_at => Created, updated_at => Updated, reply_count => Rc, locked => Locked,
      pinned => Pinned, views => Views, score => Score, user_vote => UserVote}.

reply_map([Id, Tid, Uid, U, D, Avatar, Body, Created, Updated]) ->
    #{id => Id, thread_id => Tid, user_id => Uid, username => U, display_name => D,
      avatar_url => pw_util:proxied_image(Avatar), body => Body, created_at => Created, updated_at => Updated}.

friend_map([Status, Req, Addr, Id, U, D, Bio, Avatar, Banner, St, Theme, Created, Last], Viewer) ->
    #{status => Status,
      incoming => (Status =:= <<"pending">> andalso Addr =:= Viewer),
      outgoing => (Status =:= <<"pending">> andalso Req =:= Viewer),
      user => user_map([Id, U, D, Bio, Avatar, Banner, St, Theme, Created, Last])}.

server_row_map([Id, Owner, Name, Desc, Icon, Created, Updated, Role, Members]) ->
    #{id => Id, owner_id => Owner, name => Name, description => Desc,
      icon_url => pw_util:proxied_image(Icon), created_at => Created, updated_at => Updated,
      role => Role, member_count => Members}.

server_full_map([Id, Owner, Name, Desc, Icon, Created, Updated], Role) ->
    #{id => Id, owner_id => Owner, name => Name, description => Desc,
      icon_url => pw_util:proxied_image(Icon), created_at => Created, updated_at => Updated, role => Role}.

channel_map([Id, Sid, Name, Kind, Pos, Topic, Created]) ->
    #{id => Id, server_id => Sid, name => Name, kind => Kind, position => Pos, topic => Topic, created_at => Created}.

member_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last, Role, Muted, Joined]) ->
    #{user => user_map([Id, U, D, Bio, Avatar, Banner, Status, Theme, Created, Last]),
      role => Role, muted => Muted, joined_at => Joined}.

message_map([Id, Scope, ScopeId, Uid, U, D, Avatar, Body, ReplyTo, Created, Edited, Deleted]) ->
    #{id => Id, scope => Scope, scope_id => ScopeId, user_id => Uid, username => U, display_name => D,
      avatar_url => pw_util:proxied_image(Avatar), body => load_message(Body), reply_to_id => db_null(ReplyTo),
      created_at => Created, edited_at => db_null(Edited), deleted_at => db_null(Deleted)}.

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
    Sql = "SELECT body, user_id, display_name FROM messages JOIN users ON users.id = messages.user_id WHERE messages.id = $1 AND scope = $2 AND scope_id = $3",
    case one(Conn, Sql, [ReplyTo, Scope, ScopeId]) of
        {ok, [Body, RUid, RName]} ->
            #{id => ReplyTo, user_id => RUid, display_name => RName, body => load_message(Body)};
        _ -> undefined
    end.

batch_replied_messages(_Conn, [], _Scope, _ScopeId) -> #{};
batch_replied_messages(Conn, Ids, Scope, ScopeId) ->
    UniqueIds = lists:usort(Ids),
    case UniqueIds of
        [] -> #{};
        _ ->
            N = length(UniqueIds),
            Params = UniqueIds ++ [Scope, ScopeId],
            Placeholders = string:join(["$" ++ integer_to_list(I) || I <- lists:seq(1, N)], ","),
            Sql = "SELECT m.id, m.body, m.user_id, u.display_name FROM messages m JOIN users u ON u.id = m.user_id "
                  "WHERE m.id IN (" ++ Placeholders ++ ") AND m.scope = $" ++ integer_to_list(N + 1) ++
                  " AND m.scope_id = $" ++ integer_to_list(N + 2),
            case rows(Conn, Sql, Params) of
                {ok, Rows} ->
                    maps:from_list([{Id, #{id => Id, user_id => Uid, display_name => D, body => load_message(Body)}}
                                    || [Id, Body, Uid, D] <- Rows]);
                _ -> #{}
            end
    end.

conversation_row_map([Id, Name, Avatar, Owner, Created, Updated, LastRead, Muted, RequestState, Count, LastBody, LastMsg, Unread, PeerName, PeerAvatar, PeerUsername]) ->
    #{id => Id, name => Name, avatar_url => pw_util:proxied_image(Avatar), owner_id => Owner,
      created_at => Created, updated_at => Updated, last_read_message_id => LastRead, muted => Muted, request_state => RequestState,
      member_count => Count, last_body => load_message(LastBody), last_message_id => LastMsg, unread => Unread,
      peer_name => PeerName, peer_avatar_url => pw_util:proxied_image(PeerAvatar), peer_username => PeerUsername}.

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
    "m.body, m.reply_to_id, m.created_at, m.edited_at, m.deleted_at FROM messages m JOIN users u ON u.id = m.user_id".

message_sql(Scope, Id, undefined, undefined) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 ORDER BY m.id DESC LIMIT 80", [Scope, Id]};
message_sql(Scope, Id, Before, undefined) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.id < $3 ORDER BY m.id DESC LIMIT 80", [Scope, Id, Before]};
message_sql(Scope, Id, _, After) ->
    {message_select() ++ " WHERE m.scope = $1 AND m.scope_id = $2 AND m.id > $3 ORDER BY m.id ASC LIMIT 250", [Scope, Id, After]}.

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
            #{status => S, incoming => (S =:= <<"pending">> andalso Ad =:= A), outgoing => (S =:= <<"pending">> andalso R =:= A)};
        _ ->
            #{status => none}
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
can_read_messages(Conn, Uid, <<"direct">>, Id) -> is_conversation_member(Conn, Uid, Id);
can_read_messages(_, _, _, _) -> false.

valid_reply_to(_, _, _, undefined) -> true;
valid_reply_to(_, _, _, null) -> true;
valid_reply_to(Conn, Scope, ScopeId, ReplyTo) when is_integer(ReplyTo) ->
    case one(Conn, "SELECT id FROM messages WHERE id = $1 AND scope = $2 AND scope_id = $3 AND deleted_at IS NULL", [ReplyTo, Scope, ScopeId]) of
        {ok, [_]} -> true;
        _ -> false
    end;
valid_reply_to(_, _, _, _) -> false.

is_conversation_member(Conn, Uid, Cid) ->
    case one(Conn, "SELECT user_id FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]) of
        {ok, [_]} -> true;
        _ -> false
    end.

conversation_can_send(Conn, Uid, Cid) ->
    case one(Conn, "SELECT request_state FROM direct_members WHERE thread_id = $1 AND user_id = $2", [Cid, Uid]) of
        {ok, [<<"accepted">>]} -> true;
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
    Url = <<"#/thread/", (integer_to_binary(Tid))/binary>>,
    [begin
         U = only_id(R),
         create_notification(Conn, U, <<"thread_reply">>, pw_util:clean_text(Body, 140), Url, Now),
         pw_hub:notify_user(U, #{type => thread_reply, thread_id => Tid})
     end || R <- Rows],
    ok.

notify_channel_members(Conn, Sid, Sender, Cid, Msg, Now) ->
    {ok, Rows} = rows(Conn, "SELECT user_id FROM server_members WHERE server_id = $1 AND user_id <> $2", [Sid, Sender]),
    [begin
         U = only_id(R),
         create_notification(Conn, U, <<"channel_message">>, maps:get(body, Msg),
             <<"#/channel/", (integer_to_binary(Cid))/binary>>, Now),
         pw_hub:notify_user(U, #{type => channel_message, channel_id => Cid})
     end || R <- Rows],
    ok.

notify_direct_members(Conn, Cid, Sender, Event, Now) ->
    {ok, Rows} = rows(Conn, "SELECT user_id, request_state FROM direct_members WHERE thread_id = $1 AND user_id <> $2 AND muted = false", [Cid, Sender]),
    [begin
         [U, RequestState] = R,
         EventType = maps:get(type, Event, direct_message),
         {Kind, Body, Url} = case {EventType, RequestState} of
             {direct_message, <<"pending">>} -> {<<"message_request">>, <<"New message request">>, <<"#/dms">>};
             _ -> case EventType of
             message_request_accepted -> {<<"message_request_accepted">>, <<"Message request accepted">>, <<"#/dm/", (integer_to_binary(Cid))/binary>>};
             conversation_closed -> {<<"conversation_closed">>, <<"Message request declined">>, <<"#/dms">>};
             message_request -> {<<"message_request">>, <<"New message request">>, <<"#/dms">>};
             conversation_created -> {<<"conversation_created">>, <<"New conversation">>, <<"#/dm/", (integer_to_binary(Cid))/binary>>};
             _ -> {<<"direct_message">>, <<"New direct message">>, <<"#/dm/", (integer_to_binary(Cid))/binary>>}
             end
         end,
         case Kind of
             <<"message_request">> -> create_notification_once(Conn, U, Kind, Body, Url, Now);
             _ -> create_notification(Conn, U, Kind, Body, Url, Now)
         end,
         pw_hub:notify_user(U, Event)
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
