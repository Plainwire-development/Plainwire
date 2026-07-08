-module(pw_db).
-behaviour(gen_server).
-export([
    start_link/0,
    register/3, login/2, session/1, logout/1, me/1, update_profile/3,
    sync/2, users/1, profile/2,
    friend_request/2, friend_accept/2, friend_remove/2, friend_block/2, friends/1,
    forums/0, threads/2, thread/2, create_thread/4, reply_thread/3,
    servers/1, create_server/3, server/2, create_channel/4, create_invite/4, join_invite/2,
    messages/5, post_channel_message/4,
    conversations/1, create_conversation/3, update_conversation/4, add_conversation_members/3, conversation/2, post_direct_message/3,
    notifications/1, mark_notifications_seen/1, mark_url_seen/2,
    member_of_channel/2, member_of_conversation/2
]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-record(st, {conn}).
-define(SERVER, ?MODULE).
-define(MAX_BODY, 12000).
-define(MAX_MSG, 5000).

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []). 
call(Msg) -> gen_server:call(?SERVER, Msg, 30000).

register(U,D,P) -> call({register,U,D,P}).
login(U,P) -> call({login,U,P}).
session(T) -> call({session,T}).
logout(T) -> call({logout,T}).
me(Uid) -> call({me,Uid}).
update_profile(Uid, Display, Patch) -> call({update_profile,Uid,Display,Patch}).
sync(Uid, Since) -> call({sync,Uid,Since}).
users(Q) -> call({users,Q}).
profile(Viewer, UserId) -> call({profile,Viewer,UserId}).
friend_request(Uid, Target) -> call({friend_request,Uid,Target}).
friend_accept(Uid, Target) -> call({friend_accept,Uid,Target}).
friend_remove(Uid, Target) -> call({friend_remove,Uid,Target}).
friend_block(Uid, Target) -> call({friend_block,Uid,Target}).
friends(Uid) -> call({friends,Uid}).
forums() -> call(forums).
threads(ForumId, Search) -> call({threads,ForumId,Search}).
thread(Uid, ThreadId) -> call({thread,Uid,ThreadId}).
create_thread(Uid, ForumId, Title, Body) -> call({create_thread,Uid,ForumId,Title,Body}).
reply_thread(Uid, ThreadId, Body) -> call({reply_thread,Uid,ThreadId,Body}).
servers(Uid) -> call({servers,Uid}).
create_server(Uid, Name, Desc) -> call({create_server,Uid,Name,Desc}).
server(Uid, ServerId) -> call({server,Uid,ServerId}).
create_channel(Uid, ServerId, Name, Kind) -> call({create_channel,Uid,ServerId,Name,Kind}).
create_invite(Uid, ServerId, ChannelId, MaxUses) -> call({create_invite,Uid,ServerId,ChannelId,MaxUses}).
join_invite(Uid, Code) -> call({join_invite,Uid,Code}).
messages(Uid, Scope, ScopeId, Before, After) -> call({messages,Uid,Scope,ScopeId,Before,After}).
post_channel_message(Uid, ChannelId, Body, ReplyTo) -> call({post_channel_message,Uid,ChannelId,Body,ReplyTo}).
conversations(Uid) -> call({conversations,Uid}).
create_conversation(Uid, Name, UserIds) -> call({create_conversation,Uid,Name,UserIds}).
update_conversation(Uid, Cid, Name, Patch) -> call({update_conversation,Uid,Cid,Name,Patch}).
add_conversation_members(Uid, Cid, UserIds) -> call({add_conversation_members,Uid,Cid,UserIds}).
conversation(Uid, ThreadId) -> call({conversation,Uid,ThreadId}).
post_direct_message(Uid, ThreadId, Body) -> call({post_direct_message,Uid,ThreadId,Body}).
notifications(Uid) -> call({notifications,Uid}).
mark_notifications_seen(Uid) -> call({mark_notifications_seen,Uid}).
mark_url_seen(Uid, Url) -> call({mark_url_seen,Uid,Url}).
member_of_channel(Uid, ChannelId) -> call({member_of_channel,Uid,ChannelId}).
member_of_conversation(Uid, Cid) -> call({member_of_conversation,Uid,Cid}).

init([]) ->
    process_flag(trap_exit, true),
    Path = db_path(),
    ok = filelib:ensure_dir(Path),
    {ok, Conn} = esqlite3:open(binary_to_list(Path)),
    ok = migrate(Conn),
    {ok, #st{conn=Conn}}.

handle_call(Msg, _From, #st{conn=Conn}=St) ->
    Reply = try route(Msg, Conn)
            catch C:R:S ->
                error_logger:error_msg("DB route failed ~p:~p ~p for ~p~n", [C,R,S,Msg]),
                {error, internal_error}
            end,
    {reply, Reply, St}.
handle_cast(_, St) -> {noreply, St}.
terminate(_, #st{conn=Conn}) -> catch esqlite3:close(Conn), ok.
code_change(_, St, _) -> {ok, St}.

db_path() ->
    case os:getenv("PLAINWIRE_DB") of
        false -> <<"data/plainwire.sqlite3">>;
        V -> pw_util:bin(V)
    end.

route({register, U0, D0, P0}, Conn) ->
    U = pw_util:normalize_username(U0), D0b = pw_util:clean_text(D0, 48), P = pw_util:clean_text(P0, 256),
    D = case D0b of <<>> -> U; _ -> D0b end,
    case {byte_size(U) >= 3, byte_size(U) =< 24, byte_size(P) >= 8} of
        {true,true,true} ->
            case one(Conn, "select id from users where username=?", [U]) of
                {ok, undefined} ->
                    Salt = pw_util:random_token(18), Hash = pw_util:pbkdf2(P, Salt), Now = pw_util:now_ms(),
                    ok = exec(Conn, "insert into users(username,display_name,password_hash,password_salt,bio,avatar_url,banner_url,status,theme,created_at,updated_at,last_seen) values(?,?,?,?,?,?,?,?,?,?,?,?)", [U,D,Hash,Salt,<<>>,<<>>,<<>>,<<>>,<<"system">>,Now,Now,Now]),
                    {ok, [Id]} = one(Conn, "select last_insert_rowid()", []),
                    {ok, make_session(Conn, Id)};
                _ -> {error, username_taken}
            end;
        _ -> {error, invalid_registration}
    end;
route({login, U0, P0}, Conn) ->
    U = pw_util:normalize_username(U0), P = pw_util:clean_text(P0, 256),
    case one(Conn, "select id,password_hash,password_salt from users where username=?", [U]) of
        {ok, [Id,Hash,Salt]} ->
            case pw_util:verify_password(P, Salt, Hash) of true -> {ok, make_session(Conn, Id)}; false -> {error, bad_login} end;
        _ -> {error, bad_login}
    end;
route({session, Token}, Conn) ->
    case Token of
        undefined -> {error, no_session}; <<>> -> {error, no_session}; _ ->
            H = pw_util:sha256_hex(Token), Now = pw_util:now_ms(),
            case one(Conn, "select s.user_id,s.csrf,u.username,u.display_name,u.bio,u.avatar_url,u.banner_url,u.status,u.theme,u.created_at,u.last_seen from sessions s join users u on u.id=s.user_id where s.token_hash=? and s.expires_at>?", [H,Now]) of
                {ok, [Uid,Csrf,U,D,Bio,Avatar,Banner,Status,Theme,Created,LastSeen]} ->
                    _ = exec(Conn, "update sessions set last_seen=? where token_hash=?", [Now,H]),
                    _ = exec(Conn, "update users set last_seen=? where id=?", [Now,Uid]),
                    {ok, #{user => user_map([Uid,U,D,Bio,Avatar,Banner,Status,Theme,Created,LastSeen]), csrf => Csrf, server_time => Now}};
                _ -> {error, no_session}
            end
    end;
route({logout, Token}, Conn) -> _ = exec(Conn, "delete from sessions where token_hash=?", [pw_util:sha256_hex(Token)]), ok;
route({me, Uid}, Conn) ->
    case one(Conn, "select id,username,display_name,bio,avatar_url,banner_url,status,theme,created_at,last_seen from users where id=?", [Uid]) of
        {ok, Row} when is_list(Row) -> {ok, user_map(Row)}; _ -> {error, not_found}
    end;
route({update_profile, Uid, Display0, Patch}, Conn) ->
    Display = pw_util:clean_text(Display0, 48), Bio = pw_util:clean_text(maps:get(<<"bio">>, Patch, <<>>), 600),
    Avatar = pw_util:clean_text(maps:get(<<"avatar_url">>, Patch, <<>>), 260000), Banner = pw_util:clean_text(maps:get(<<"banner_url">>, Patch, <<>>), 260000),
    Status = pw_util:clean_text(maps:get(<<"status">>, Patch, <<>>), 100), Theme = pw_util:clean_text(maps:get(<<"theme">>, Patch, <<"system">>), 32), Now = pw_util:now_ms(),
    ok = exec(Conn, "update users set display_name=?,bio=?,avatar_url=?,banner_url=?,status=?,theme=?,updated_at=? where id=?", [Display,Bio,Avatar,Banner,Status,Theme,Now,Uid]),
    {ok, #{updated => true}};
route({sync, Uid, Since0}, Conn) ->
    Since = case pw_util:int(Since0) of undefined -> 0; I -> I end,
    {ok, Notifs} = route({notifications, Uid}, Conn),
    {ok, Convs} = route({conversations, Uid}, Conn),
    {ok, Servers} = route({servers, Uid}, Conn),
    {ok, Friends} = route({friends, Uid}, Conn),
    {ok, #{now=>pw_util:now_ms(), since=>Since, notifications=>Notifs, conversations=>Convs, servers=>Servers, friends=>Friends}};
route({users, Q0}, Conn) ->
    Q = pw_util:clean_text(Q0, 80), Like = <<"%", Q/binary, "%">>,
    {ok, Rows} = rows(Conn, "select id,username,display_name,bio,avatar_url,banner_url,status,theme,created_at,last_seen from users where username like ? or display_name like ? order by last_seen desc limit 40", [Like,Like]),
    {ok, [user_map(R) || R <- Rows]};
route({profile, Viewer, UserId0}, Conn) ->
    UserId = pw_util:int(UserId0),
    case route({me, UserId}, Conn) of
        {ok, U} ->
            Rel = friendship_status(Conn, Viewer, UserId),
            {ok, #{user=>U, relationship=>Rel}};
        E -> E
    end;
route({friend_request, Uid, Target0}, Conn) ->
    Target = pw_util:int(Target0),
    case Target of
        Uid -> {error, cannot_friend_self};
        undefined -> {error, invalid_user};
        _ ->
            {A,B} = pair(Uid, Target), Now = pw_util:now_ms(),
            case one(Conn, "select id from users where id=?", [Target]) of
                {ok, [_]} ->
                    ok = exec(Conn, "insert into friendships(user_low,user_high,requester_id,addressee_id,status,created_at,updated_at) values(?,?,?,?,?,?,?) on conflict(user_low,user_high) do update set requester_id=excluded.requester_id,addressee_id=excluded.addressee_id,status=case when status='blocked' then status else 'pending' end,updated_at=excluded.updated_at", [A,B,Uid,Target,<<"pending">>,Now,Now]),
                    create_notification(Conn, Target, <<"friend_request">>, <<"New friend request">>, <<"#/friends">>, Now),
                    pw_hub:notify_user(Target, #{type=>friend_request, from_user_id=>Uid}),
                    {ok, #{status=>pending}};
                _ -> {error, invalid_user}
            end
    end;
route({friend_accept, Uid, Target0}, Conn) ->
    Target = pw_util:int(Target0), {A,B} = pair(Uid, Target), Now = pw_util:now_ms(),
    case one(Conn, "select status,requester_id,addressee_id from friendships where user_low=? and user_high=?", [A,B]) of
        {ok, [<<"pending">>,Target,Uid]} ->
            ok = exec(Conn, "update friendships set status='accepted',updated_at=? where user_low=? and user_high=?", [Now,A,B]),
            create_notification(Conn, Target, <<"friend_accept">>, <<"Friend request accepted">>, <<"#/friends">>, Now),
            pw_hub:notify_user(Target, #{type=>friend_accept, user_id=>Uid}),
            {ok, #{status=>accepted}};
        {ok, [<<"accepted">>,_,_]} -> {ok, #{status=>accepted}};
        _ -> {error, no_pending_request}
    end;
route({friend_remove, Uid, Target0}, Conn) -> Target=pw_util:int(Target0), {A,B}=pair(Uid,Target), _=exec(Conn,"delete from friendships where user_low=? and user_high=?",[A,B]), {ok, #{removed=>true}};
route({friend_block, Uid, Target0}, Conn) -> Target=pw_util:int(Target0), {A,B}=pair(Uid,Target), Now=pw_util:now_ms(), ok=exec(Conn,"insert into friendships(user_low,user_high,requester_id,addressee_id,status,created_at,updated_at) values(?,?,?,?,?,?,?) on conflict(user_low,user_high) do update set requester_id=excluded.requester_id,addressee_id=excluded.addressee_id,status='blocked',updated_at=excluded.updated_at",[A,B,Uid,Target,<<"blocked">>,Now,Now]), {ok, #{status=>blocked}};
route({friends, Uid}, Conn) ->
    {ok, Rows} = rows(Conn, "select fr.status,fr.requester_id,fr.addressee_id,u.id,u.username,u.display_name,u.bio,u.avatar_url,u.banner_url,u.status,u.theme,u.created_at,u.last_seen from friendships fr join users u on u.id=case when fr.user_low=? then fr.user_high else fr.user_low end where fr.user_low=? or fr.user_high=? order by fr.updated_at desc", [Uid,Uid,Uid]),
    {ok, [friend_map(R, Uid) || R <- Rows]};
route(forums, Conn) ->
    {ok, Rows} = rows(Conn, "select f.id,f.slug,f.name,f.description,f.position,(select count(*) from threads t where t.forum_id=f.id),(select count(*) from replies r join threads t2 on t2.id=r.thread_id where t2.forum_id=f.id),(select max(updated_at) from threads t3 where t3.forum_id=f.id) from forums f order by f.position asc", []),
    {ok, [forum_map(R) || R <- Rows]};
route({threads, ForumId0, Search0}, Conn) ->
    ForumId = pw_util:int(ForumId0), Search = pw_util:clean_text(Search0, 80), {Sql, Params} = thread_sql(ForumId, Search),
    {ok, Rows} = rows(Conn, Sql, Params), {ok, [thread_row_map(R) || R <- Rows]};
route({thread, Uid, ThreadId0}, Conn) ->
    ThreadId = pw_util:int(ThreadId0), _ = exec(Conn, "update threads set views=views+1 where id=?", [ThreadId]),
    case one(Conn, "select t.id,t.forum_id,f.name,t.user_id,u.username,u.display_name,u.avatar_url,t.title,t.body,t.created_at,t.updated_at,t.reply_count,t.locked,t.pinned,t.views from threads t join forums f on f.id=t.forum_id join users u on u.id=t.user_id where t.id=?", [ThreadId]) of
        {ok, T} when is_list(T) ->
            {ok, Rs} = rows(Conn, "select r.id,r.thread_id,r.user_id,u.username,u.display_name,u.avatar_url,r.body,r.created_at,r.updated_at from replies r join users u on u.id=r.user_id where r.thread_id=? order by r.created_at asc limit 800", [ThreadId]),
            _ = mark_url_seen0(Conn, Uid, <<"#/thread/", (integer_to_binary(ThreadId))/binary>>),
            {ok, #{thread=>thread_full_map(T), replies=>[reply_map(R) || R <- Rs]}};
        _ -> {error, not_found}
    end;
route({create_thread, Uid, ForumId0, Title0, Body0}, Conn) ->
    ForumId = pw_util:int(ForumId0), Title = pw_util:clean_text(Title0, 160), Body = pw_util:clean_text(Body0, ?MAX_BODY),
    case validate_thread(Conn, ForumId, Title, Body) of
        ok -> Now=pw_util:now_ms(), ok=exec(Conn,"insert into threads(forum_id,user_id,title,body,created_at,updated_at,reply_count,locked,pinned,views) values(?,?,?,?,?,?,?,?,?,?)",[ForumId,Uid,Title,Body,Now,Now,0,0,0,0]), {ok,[Tid]}=one(Conn,"select last_insert_rowid()",[]), pw_hub:broadcast({forum,ForumId}, #{type=>thread_created, thread_id=>Tid, forum_id=>ForumId}), {ok, #{id=>Tid}};
        Err -> Err
    end;
route({reply_thread, Uid, ThreadId0, Body0}, Conn) ->
    ThreadId=pw_util:int(ThreadId0), Body=pw_util:clean_text(Body0, ?MAX_BODY),
    case {ThreadId, byte_size(Body)>0, one(Conn,"select locked from threads where id=?",[ThreadId])} of
        {I,true,{ok,[0]}} when is_integer(I) -> Now=pw_util:now_ms(), ok=exec(Conn,"insert into replies(thread_id,user_id,body,created_at,updated_at) values(?,?,?,?,?)",[ThreadId,Uid,Body,Now,Now]), {ok,[Rid]}=one(Conn,"select last_insert_rowid()",[]), ok=exec(Conn,"update threads set updated_at=?, reply_count=reply_count+1 where id=?",[Now,ThreadId]), notify_thread_participants(Conn,ThreadId,Uid,Body,Now), {ok,Row}=one(Conn,"select r.id,r.thread_id,r.user_id,u.username,u.display_name,u.avatar_url,r.body,r.created_at,r.updated_at from replies r join users u on u.id=r.user_id where r.id=?",[Rid]), Reply=reply_map(Row), pw_hub:broadcast({thread,ThreadId}, #{type=>thread_reply, thread_id=>ThreadId, reply=>Reply}), {ok,Reply};
        {_,_,{ok,[1]}} -> {error, locked}; _ -> {error, invalid_reply}
    end;
route({servers, Uid}, Conn) ->
    {ok, Rows}=rows(Conn,"select s.id,s.owner_id,s.name,s.description,s.icon_url,s.created_at,s.updated_at,sm.role,(select count(*) from server_members where server_id=s.id) from servers s join server_members sm on sm.server_id=s.id and sm.user_id=? order by sm.joined_at asc",[Uid]),
    {ok,[server_row_map(R)||R<-Rows]};
route({create_server, Uid, Name0, Desc0}, Conn) ->
    Name=pw_util:clean_text(Name0,80), Desc=pw_util:clean_text(Desc0,280),
    case byte_size(Name)>=2 of false->{error,invalid_server_name}; true ->
        Now=pw_util:now_ms(), ok=exec(Conn,"insert into servers(owner_id,name,description,icon_url,created_at,updated_at) values(?,?,?,?,?,?)",[Uid,Name,Desc,<<>>,Now,Now]), {ok,[Sid]}=one(Conn,"select last_insert_rowid()",[]), ok=exec(Conn,"insert into server_members(server_id,user_id,role,muted,joined_at) values(?,?,?,?,?)",[Sid,Uid,<<"owner">>,0,Now]), ok=exec(Conn,"insert into channels(server_id,name,kind,position,topic,created_at) values(?,?,?,?,?,?)",[Sid,<<"general">>,<<"text">>,1,<<>>,Now]), ok=exec(Conn,"insert into channels(server_id,name,kind,position,topic,created_at) values(?,?,?,?,?,?)",[Sid,<<"Lobby">>,<<"voice">>,2,<<>>,Now]), {ok,#{id=>Sid}}
    end;
route({server, Uid, ServerId0}, Conn) ->
    Sid=pw_util:int(ServerId0),
    case one(Conn,"select role from server_members where server_id=? and user_id=?",[Sid,Uid]) of
        {ok,[Role]} ->
            {ok,S}=one(Conn,"select id,owner_id,name,description,icon_url,created_at,updated_at from servers where id=?",[Sid]),
            {ok,Ch}=rows(Conn,"select id,server_id,name,kind,position,topic,created_at from channels where server_id=? order by position asc,id asc",[Sid]),
            {ok,Ms}=rows(Conn,"select u.id,u.username,u.display_name,u.bio,u.avatar_url,u.banner_url,u.status,u.theme,u.created_at,u.last_seen,sm.role,sm.muted,sm.joined_at from server_members sm join users u on u.id=sm.user_id where sm.server_id=? order by sm.role='owner' desc, u.display_name asc",[Sid]),
            {ok, #{server=>server_full_map(S,Role), channels=>[channel_map(R)||R<-Ch], members=>[member_map(R)||R<-Ms]}};
        _ -> {error, forbidden}
    end;
route({create_channel, Uid, Sid0, Name0, Kind0}, Conn) ->
    Sid=pw_util:int(Sid0), Name=pw_util:clean_text(Name0,40), Kind=case pw_util:clean_text(Kind0,10) of <<"voice">>-><<"voice">>; _-><<"text">> end,
    case can_manage_server(Conn, Uid, Sid) of
        true -> Now=pw_util:now_ms(), {ok,[Pos]}=one(Conn,"select coalesce(max(position),0)+1 from channels where server_id=?",[Sid]), ok=exec(Conn,"insert into channels(server_id,name,kind,position,topic,created_at) values(?,?,?,?,?,?)",[Sid,Name,Kind,Pos,<<>>,Now]), {ok,[Cid]}=one(Conn,"select last_insert_rowid()",[]), pw_hub:broadcast({server,Sid},#{type=>channel_created,server_id=>Sid,channel_id=>Cid}), {ok,#{id=>Cid}};
        false -> {error, forbidden}
    end;
route({create_invite, Uid, Sid0, ChannelId0, MaxUses0}, Conn) ->
    Sid=pw_util:int(Sid0), ChannelId=pw_util:int(ChannelId0), MaxUses=case pw_util:int(MaxUses0) of undefined -> 0; I -> I end,
    case is_member(Conn, Uid, Sid) of
        true -> Code=pw_util:random_token(12), Now=pw_util:now_ms(), ok=exec(Conn,"insert into server_invites(code,server_id,channel_id,creator_id,max_uses,uses,created_at,expires_at,revoked) values(?,?,?,?,?,?,?,?,?)",[Code,Sid,ChannelId,Uid,MaxUses,0,Now,0,0]), {ok,#{code=>Code, url=><<"#/invite/",Code/binary>>}};
        false -> {error, forbidden}
    end;
route({join_invite, Uid, Code0}, Conn) ->
    Code=pw_util:clean_text(Code0,80), Now=pw_util:now_ms(),
    case one(Conn,"select code,server_id,channel_id,max_uses,uses,expires_at,revoked from server_invites where code=?",[Code]) of
        {ok,[Code,Sid,ChannelId,Max,Uses,Expires,0]} when (Max=:=0 orelse Uses<Max), (Expires=:=0 orelse Expires>Now) ->
            _=exec(Conn,"insert or ignore into server_members(server_id,user_id,role,muted,joined_at) values(?,?,?,?,?)",[Sid,Uid,<<"member">>,0,Now]), _=exec(Conn,"update server_invites set uses=uses+1 where code=?",[Code]), {ok,#{server_id=>Sid, channel_id=>ChannelId}};
        _ -> {error, invalid_invite}
    end;
route({messages, Uid, Scope0, ScopeId0, Before0, After0}, Conn) ->
    Scope=pw_util:clean_text(Scope0,16), ScopeId=pw_util:int(ScopeId0), Before=pw_util:int(Before0), After=pw_util:int(After0),
    case can_read_messages(Conn, Uid, Scope, ScopeId) of
        true -> {Sql,Params}=message_sql(Scope,ScopeId,Before,After), {ok,Rows}=rows(Conn,Sql,Params), {ok,[message_map(R)||R<-Rows]};
        false -> {error, forbidden}
    end;
route({post_channel_message, Uid, ChannelId0, Body0, ReplyTo0}, Conn) ->
    Cid=pw_util:int(ChannelId0), Body=pw_util:clean_text(Body0, ?MAX_MSG), ReplyTo=pw_util:int(ReplyTo0),
    case {byte_size(Body)>0, channel_server_member(Conn, Uid, Cid)} of
        {true,{ok,Sid}} -> Now=pw_util:now_ms(), ok=exec(Conn,"insert into messages(scope,scope_id,user_id,body,reply_to_id,created_at) values(?,?,?,?,?,?)",[<<"channel">>,Cid,Uid,Body,ReplyTo,Now]), {ok,[Mid]}=one(Conn,"select last_insert_rowid()",[]), {ok,Row}=one(Conn,message_select()++" where m.id=?",[Mid]), Msg=message_map(Row), pw_hub:broadcast({channel,Cid}, #{type=>message_created, scope=>channel, scope_id=>Cid, message=>Msg}), notify_channel_members(Conn,Sid,Uid,Cid,Msg,Now), {ok,Msg};
        _ -> {error, invalid_message}
    end;
route({conversations, Uid}, Conn) ->
    {ok,Rows}=rows(Conn,"select dt.id,dt.name,dt.avatar_url,dt.owner_id,dt.created_at,dt.updated_at,dm.last_read_message_id,dm.muted,(select count(*) from direct_members where thread_id=dt.id),(select body from messages where scope='direct' and scope_id=dt.id order by id desc limit 1),(select id from messages where scope='direct' and scope_id=dt.id order by id desc limit 1),(select count(*) from messages where scope='direct' and scope_id=dt.id and id>dm.last_read_message_id and user_id<>?) from direct_threads dt join direct_members dm on dm.thread_id=dt.id and dm.user_id=? order by dt.updated_at desc",[Uid,Uid]),
    {ok,[conversation_row_map(R)||R<-Rows]};
route({create_conversation, Uid, Name0, UserIds0}, Conn) ->
    UserIds1=[pw_util:int(X)||X<-ensure_list(UserIds0)], UserIds=lists:usort([X||X<-UserIds1, is_integer(X), X=/=Uid]), Name=pw_util:clean_text(Name0,80),
    case UserIds of
        [] -> {error, invalid_members};
        _ -> Now=pw_util:now_ms(), ok=exec(Conn,"insert into direct_threads(name,avatar_url,owner_id,created_at,updated_at) values(?,?,?,?,?)",[Name,<<>>,Uid,Now,Now]), {ok,[Tid]}=one(Conn,"select last_insert_rowid()",[]), [exec(Conn,"insert or ignore into direct_members(thread_id,user_id,last_read_message_id,muted,nickname,joined_at) values(?,?,?,?,?,?)",[Tid,U,0,0,<<>>,Now]) || U <- [Uid|UserIds]], notify_direct_members(Conn,Tid,Uid,#{type=>conversation_created,conversation_id=>Tid},Now), {ok,#{id=>Tid}}
    end;
route({update_conversation, Uid, Cid0, Name0, Patch}, Conn) ->
    Cid=pw_util:int(Cid0), Name=pw_util:clean_text(Name0,80), Avatar=pw_util:clean_text(maps:get(<<"avatar_url">>,Patch,<<>>),260000),
    case is_conversation_member(Conn,Uid,Cid) of true -> Now=pw_util:now_ms(), ok=exec(Conn,"update direct_threads set name=?,avatar_url=?,updated_at=? where id=?",[Name,Avatar,Now,Cid]), pw_hub:broadcast({direct,Cid},#{type=>conversation_updated,conversation_id=>Cid}), {ok,#{updated=>true}}; false->{error,forbidden} end;
route({add_conversation_members, Uid, Cid0, UserIds0}, Conn) ->
    Cid=pw_util:int(Cid0), UserIds=lists:usort([X||X<-[pw_util:int(Y)||Y<-ensure_list(UserIds0)], is_integer(X)]),
    case is_conversation_member(Conn,Uid,Cid) of
        true -> Now=pw_util:now_ms(), [exec(Conn,"insert or ignore into direct_members(thread_id,user_id,last_read_message_id,muted,nickname,joined_at) values(?,?,?,?,?,?)",[Cid,U,0,0,<<>>,Now]) || U<-UserIds], notify_direct_members(Conn,Cid,Uid,#{type=>conversation_members_added,conversation_id=>Cid},Now), {ok,#{added=>length(UserIds)}};
        false -> {error,forbidden}
    end;
route({conversation, Uid, Cid0}, Conn) ->
    Cid=pw_util:int(Cid0),
    case is_conversation_member(Conn,Uid,Cid) of
        true -> {ok,Info}=one(Conn,"select id,name,avatar_url,owner_id,created_at,updated_at from direct_threads where id=?",[Cid]), {ok,Members}=rows(Conn,"select u.id,u.username,u.display_name,u.bio,u.avatar_url,u.banner_url,u.status,u.theme,u.created_at,u.last_seen,dm.last_read_message_id,dm.muted,dm.nickname,dm.joined_at from direct_members dm join users u on u.id=dm.user_id where dm.thread_id=? order by u.display_name asc",[Cid]), {ok,#{conversation=>conversation_full_map(Info), members=>[conversation_member_map(M)||M<-Members]}};
        false -> {error,forbidden}
    end;
route({post_direct_message, Uid, Cid0, Body0}, Conn) ->
    Cid=pw_util:int(Cid0), Body=pw_util:clean_text(Body0, ?MAX_MSG),
    case {byte_size(Body)>0, is_conversation_member(Conn,Uid,Cid)} of
        {true,true} -> Now=pw_util:now_ms(), ok=exec(Conn,"insert into messages(scope,scope_id,user_id,body,created_at) values(?,?,?,?,?)",[<<"direct">>,Cid,Uid,Body,Now]), {ok,[Mid]}=one(Conn,"select last_insert_rowid()",[]), ok=exec(Conn,"update direct_threads set updated_at=? where id=?",[Now,Cid]), {ok,Row}=one(Conn,message_select()++" where m.id=?",[Mid]), Msg=message_map(Row), pw_hub:broadcast({direct,Cid},#{type=>message_created,scope=>direct,scope_id=>Cid,message=>Msg}), notify_direct_members(Conn,Cid,Uid,#{type=>direct_message,conversation_id=>Cid,message=>Msg},Now), {ok,Msg};
        _ -> {error,invalid_message}
    end;
route({notifications, Uid}, Conn) -> {ok,Rows}=rows(Conn,"select id,kind,body,url,seen,created_at from notifications where user_id=? order by id desc limit 120",[Uid]), {ok,[notification_map(R)||R<-Rows]};
route({mark_notifications_seen, Uid}, Conn) -> ok=exec(Conn,"update notifications set seen=1 where user_id=?",[Uid]), {ok,#{seen=>true}};
route({mark_url_seen, Uid, Url}, Conn) -> mark_url_seen0(Conn,Uid,pw_util:clean_text(Url,240)), {ok,#{seen=>true}};
route({member_of_channel, Uid, Cid0}, Conn) -> case channel_server_member(Conn,Uid,pw_util:int(Cid0)) of {ok,_}->true; _->false end;
route({member_of_conversation, Uid, Cid0}, Conn) -> is_conversation_member(Conn,Uid,pw_util:int(Cid0)).

make_session(Conn, Uid) ->
    Token=pw_util:random_token(32), Csrf=pw_util:random_token(24), H=pw_util:sha256_hex(Token), Now=pw_util:now_ms(), Expires=Now+30*24*60*60*1000,
    ok=exec(Conn,"insert into sessions(token_hash,user_id,csrf,created_at,expires_at,last_seen) values(?,?,?,?,?,?)",[H,Uid,Csrf,Now,Expires,Now]), {ok,User}=route({me,Uid},Conn), #{token=>Token,csrf=>Csrf,user=>User,server_time=>Now}.

migrate(Conn) ->
    _ = catch exec(Conn, "pragma foreign_keys = on", []),
    _ = catch exec(Conn, "pragma journal_mode = wal", []),
    ensure_schema_table(Conn),
    lists:foreach(fun({V,Sqls}) -> migrate_to(Conn,V,Sqls) end, migrations()),
    seed_forums(Conn), ok.

ensure_schema_table(Conn) -> _ = exec(Conn,"create table if not exists schema_migrations(version integer primary key, applied_at integer not null)",[]), ok.

migrate_to(Conn, Version, Sqls) ->
    case one(Conn,"select version from schema_migrations where version=?",[Version]) of
        {ok, undefined} -> [safe_exec(Conn,Sql) || Sql <- Sqls], exec(Conn,"insert into schema_migrations(version,applied_at) values(?,?)",[Version,pw_util:now_ms()]), ok;
        _ -> ok
    end.

migrations() -> [
{1, [
"create table if not exists users(id integer primary key autoincrement, username text unique not null, display_name text not null, password_hash text not null, password_salt text not null, bio text not null default '', avatar_url text not null default '', banner_url text not null default '', status text not null default '', theme text not null default 'system', created_at integer not null, updated_at integer not null, last_seen integer not null)",
"create table if not exists sessions(token_hash text primary key, user_id integer not null references users(id) on delete cascade, csrf text not null, created_at integer not null, expires_at integer not null, last_seen integer not null)",
"create table if not exists forums(id integer primary key autoincrement, slug text unique not null, name text not null, description text not null, position integer not null)",
"create table if not exists threads(id integer primary key autoincrement, forum_id integer not null references forums(id) on delete cascade, user_id integer not null references users(id), title text not null, body text not null, created_at integer not null, updated_at integer not null, reply_count integer not null default 0, locked integer not null default 0, pinned integer not null default 0, views integer not null default 0)",
"create table if not exists replies(id integer primary key autoincrement, thread_id integer not null references threads(id) on delete cascade, user_id integer not null references users(id), body text not null, created_at integer not null, updated_at integer not null)",
"create table if not exists friendships(user_low integer not null references users(id) on delete cascade, user_high integer not null references users(id) on delete cascade, requester_id integer not null references users(id), addressee_id integer not null references users(id), status text not null check(status in ('pending','accepted','blocked')), created_at integer not null, updated_at integer not null, primary key(user_low,user_high))",
"create table if not exists servers(id integer primary key autoincrement, owner_id integer not null references users(id), name text not null, description text not null, icon_url text not null default '', created_at integer not null, updated_at integer not null)",
"create table if not exists server_members(server_id integer not null references servers(id) on delete cascade, user_id integer not null references users(id) on delete cascade, role text not null default 'member', muted integer not null default 0, joined_at integer not null, primary key(server_id,user_id))",
"create table if not exists channels(id integer primary key autoincrement, server_id integer not null references servers(id) on delete cascade, name text not null, kind text not null check(kind in ('text','voice')), position integer not null, topic text not null default '', created_at integer not null)",
"create table if not exists direct_threads(id integer primary key autoincrement, name text not null default '', avatar_url text not null default '', owner_id integer not null references users(id), created_at integer not null, updated_at integer not null)",
"create table if not exists direct_members(thread_id integer not null references direct_threads(id) on delete cascade, user_id integer not null references users(id) on delete cascade, last_read_message_id integer not null default 0, muted integer not null default 0, nickname text not null default '', joined_at integer not null, primary key(thread_id,user_id))",
"create table if not exists messages(id integer primary key autoincrement, scope text not null check(scope in ('channel','direct')), scope_id integer not null, user_id integer not null references users(id), body text not null, reply_to_id integer, created_at integer not null, edited_at integer, deleted_at integer)",
"create table if not exists notifications(id integer primary key autoincrement, user_id integer not null references users(id) on delete cascade, kind text not null, body text not null, url text not null, seen integer not null default 0, created_at integer not null)",
"create table if not exists server_invites(code text primary key, server_id integer not null references servers(id) on delete cascade, channel_id integer, creator_id integer not null references users(id), max_uses integer not null default 0, uses integer not null default 0, created_at integer not null, expires_at integer not null default 0, revoked integer not null default 0)",
"create index if not exists idx_threads_forum on threads(forum_id,updated_at desc)", "create index if not exists idx_replies_thread on replies(thread_id,created_at)", "create index if not exists idx_messages_scope on messages(scope,scope_id,id desc)", "create index if not exists idx_notifications_user on notifications(user_id,seen,id desc)", "create index if not exists idx_direct_members_user on direct_members(user_id,thread_id)", "create index if not exists idx_server_members_user on server_members(user_id,server_id)", "create index if not exists idx_invites_server on server_invites(server_id,revoked)"
]},
{2, [
"alter table users add column banner_url text not null default ''",
"alter table users add column theme text not null default 'system'",
"alter table channels add column topic text not null default ''",
"create table if not exists server_invites(code text primary key, server_id integer not null references servers(id) on delete cascade, channel_id integer, creator_id integer not null references users(id), max_uses integer not null default 0, uses integer not null default 0, created_at integer not null, expires_at integer not null default 0, revoked integer not null default 0)"
]}
].

safe_exec(Conn, Sql) ->
    case catch exec(Conn, Sql, []) of
        ok -> ok;
        _ -> ok
    end.

exec(Conn, Sql, Params) ->
    case query(Conn, Sql, Params) of
        {ok, _} -> ok; {error, '$done'} -> ok; {error, done} -> ok; {error, {sql_error, _}} -> ok; {error, Reason} -> erlang:error({sql_error, Reason, Sql})
    end.
rows(Conn, Sql, Params) -> query(Conn, Sql, Params).
one(Conn, Sql, Params) -> case query(Conn, Sql, Params) of {ok,[]}->{ok,undefined}; {ok,[R|_]}->{ok,R}; E->E end.
query(Conn, Sql, Params) ->
    case esqlite3:prepare(Conn, Sql) of
        {ok, Stmt} -> try _ = bind(Stmt, Params), collect(Stmt, []) after catch esqlite3:finalize(Stmt) end;
        Error -> Error
    end.
bind(Stmt, Params) -> case catch esqlite3:bind(Stmt, Params) of ok->ok; '$done'->ok; done->ok; {error,R}->erlang:error({bind_error,R}); _->ok end.
collect(Stmt, Acc) ->
    case catch esqlite3:step(Stmt) of
        done -> {ok, lists:reverse(Acc)}; '$done' -> {ok, lists:reverse(Acc)}; {done,_}->{ok,lists:reverse(Acc)}; {error,'$done'}->{ok,lists:reverse(Acc)}; {error,done}->{ok,lists:reverse(Acc)};
        {row, Row0} -> collect(Stmt, [row_to_list(Row0)|Acc]); Row0 when is_tuple(Row0) -> collect(Stmt, [tuple_to_list(Row0)|Acc]); Row0 when is_list(Row0) -> collect(Stmt, [Row0|Acc]); {error,R}->{error,R}; {'EXIT',R}->{error,R}; Other->{error,Other}
    end.
row_to_list(Row) when is_tuple(Row) -> tuple_to_list(Row); row_to_list(Row) when is_list(Row) -> Row; row_to_list(Row) -> [Row].

seed_forums(Conn) -> case one(Conn,"select count(*) from forums",[]) of {ok,[0]} -> Fs=[{<<"general">>,<<"General">>,<<"Community discussion and project notes.">>,1},{<<"support">>,<<"Support">>,<<"Errors, logs, drivers, packages, services.">>,2},{<<"development">>,<<"Development">>,<<"Programming, systems, tooling, and releases.">>,3},{<<"security">>,<<"Security">>,<<"Hardening, auth, permissions, and incident notes.">>,4}], [exec(Conn,"insert into forums(slug,name,description,position) values(?,?,?,?)",[S,N,D,P]) || {S,N,D,P}<-Fs], ok; _ -> ok end.

ensure_list(L) when is_list(L) -> L; ensure_list(_) -> [].
pair(A,B) when A < B -> {A,B}; pair(A,B) -> {B,A}.
only_id([I]) -> I; only_id(I) -> I.

user_map([Id,U,D,Bio,Avatar,Banner,Status,Theme,Created,LastSeen]) -> #{id=>Id,username=>U,display_name=>D,bio=>Bio,avatar_url=>Avatar,banner_url=>Banner,status=>Status,theme=>Theme,created_at=>Created,last_seen=>LastSeen}.
forum_map([Id,Slug,Name,Desc,Pos,Tc,Rc,Last]) -> #{id=>Id,slug=>Slug,name=>Name,description=>Desc,position=>Pos,thread_count=>Tc,reply_count=>Rc,last_at=>Last}.
thread_row_map([Id,Fid,Fname,Uid,U,D,Title,Created,Updated,Rc,Views,Pinned]) -> #{id=>Id,forum_id=>Fid,forum_name=>Fname,user_id=>Uid,username=>U,display_name=>D,title=>Title,created_at=>Created,updated_at=>Updated,reply_count=>Rc,views=>Views,pinned=>Pinned}.
thread_full_map([Id,Fid,Fname,Uid,U,D,Avatar,Title,Body,Created,Updated,Rc,Locked,Pinned,Views]) -> #{id=>Id,forum_id=>Fid,forum_name=>Fname,user_id=>Uid,username=>U,display_name=>D,avatar_url=>Avatar,title=>Title,body=>Body,created_at=>Created,updated_at=>Updated,reply_count=>Rc,locked=>Locked,pinned=>Pinned,views=>Views}.
reply_map([Id,Tid,Uid,U,D,Avatar,Body,Created,Updated]) -> #{id=>Id,thread_id=>Tid,user_id=>Uid,username=>U,display_name=>D,avatar_url=>Avatar,body=>Body,created_at=>Created,updated_at=>Updated}.
friend_map([Status,Req,Addr,Id,U,D,Bio,Avatar,Banner,St,Theme,Created,Last], Viewer) -> #{status=>Status, incoming=>(Status=:=<<"pending">> andalso Addr=:=Viewer), outgoing=>(Status=:=<<"pending">> andalso Req=:=Viewer), user=>user_map([Id,U,D,Bio,Avatar,Banner,St,Theme,Created,Last])}.
server_row_map([Id,Owner,Name,Desc,Icon,Created,Updated,Role,Members]) -> #{id=>Id,owner_id=>Owner,name=>Name,description=>Desc,icon_url=>Icon,created_at=>Created,updated_at=>Updated,role=>Role,member_count=>Members}.
server_full_map([Id,Owner,Name,Desc,Icon,Created,Updated], Role) -> #{id=>Id,owner_id=>Owner,name=>Name,description=>Desc,icon_url=>Icon,created_at=>Created,updated_at=>Updated,role=>Role}.
channel_map([Id,Sid,Name,Kind,Pos,Topic,Created]) -> #{id=>Id,server_id=>Sid,name=>Name,kind=>Kind,position=>Pos,topic=>Topic,created_at=>Created}.
member_map([Id,U,D,Bio,Avatar,Banner,Status,Theme,Created,Last,Role,Muted,Joined]) -> #{user=>user_map([Id,U,D,Bio,Avatar,Banner,Status,Theme,Created,Last]),role=>Role,muted=>Muted,joined_at=>Joined}.
message_map([Id,Scope,ScopeId,Uid,U,D,Avatar,Body,ReplyTo,Created,Edited,Deleted]) -> #{id=>Id,scope=>Scope,scope_id=>ScopeId,user_id=>Uid,username=>U,display_name=>D,avatar_url=>Avatar,body=>Body,reply_to_id=>ReplyTo,created_at=>Created,edited_at=>Edited,deleted_at=>Deleted}.
conversation_row_map([Id,Name,Avatar,Owner,Created,Updated,LastRead,Muted,Count,LastBody,LastMsg,Unread]) -> #{id=>Id,name=>Name,avatar_url=>Avatar,owner_id=>Owner,created_at=>Created,updated_at=>Updated,last_read_message_id=>LastRead,muted=>Muted,member_count=>Count,last_body=>LastBody,last_message_id=>LastMsg,unread=>Unread}.
conversation_full_map([Id,Name,Avatar,Owner,Created,Updated]) -> #{id=>Id,name=>Name,avatar_url=>Avatar,owner_id=>Owner,created_at=>Created,updated_at=>Updated}.
conversation_member_map([Id,U,D,Bio,Avatar,Banner,Status,Theme,Created,Last,LastRead,Muted,Nick,Joined]) -> #{user=>user_map([Id,U,D,Bio,Avatar,Banner,Status,Theme,Created,Last]),last_read_message_id=>LastRead,muted=>Muted,nickname=>Nick,joined_at=>Joined}.
notification_map([Id,Kind,Body,Url,Seen,Created]) -> #{id=>Id,kind=>Kind,body=>Body,url=>Url,seen=>Seen,created_at=>Created}.

thread_sql(undefined, <<>>) -> {"select t.id,t.forum_id,f.name,t.user_id,u.username,u.display_name,t.title,t.created_at,t.updated_at,t.reply_count,t.views,t.pinned from threads t join forums f on f.id=t.forum_id join users u on u.id=t.user_id order by t.pinned desc,t.updated_at desc limit 120", []};
thread_sql(F, <<>>) -> {"select t.id,t.forum_id,f.name,t.user_id,u.username,u.display_name,t.title,t.created_at,t.updated_at,t.reply_count,t.views,t.pinned from threads t join forums f on f.id=t.forum_id join users u on u.id=t.user_id where t.forum_id=? order by t.pinned desc,t.updated_at desc limit 120", [F]};
thread_sql(undefined, S) -> L= <<"%",S/binary,"%">>, {"select t.id,t.forum_id,f.name,t.user_id,u.username,u.display_name,t.title,t.created_at,t.updated_at,t.reply_count,t.views,t.pinned from threads t join forums f on f.id=t.forum_id join users u on u.id=t.user_id where t.title like ? or t.body like ? order by t.updated_at desc limit 120", [L,L]};
thread_sql(F, S) -> L= <<"%",S/binary,"%">>, {"select t.id,t.forum_id,f.name,t.user_id,u.username,u.display_name,t.title,t.created_at,t.updated_at,t.reply_count,t.views,t.pinned from threads t join forums f on f.id=t.forum_id join users u on u.id=t.user_id where t.forum_id=? and (t.title like ? or t.body like ?) order by t.updated_at desc limit 120", [F,L,L]}.

message_select() -> "select m.id,m.scope,m.scope_id,m.user_id,u.username,u.display_name,u.avatar_url,m.body,m.reply_to_id,m.created_at,m.edited_at,m.deleted_at from messages m join users u on u.id=m.user_id".
message_sql(Scope,Id,undefined,undefined) -> {message_select()++" where m.scope=? and m.scope_id=? order by m.id desc limit 80",[Scope,Id]};
message_sql(Scope,Id,Before,undefined) -> {message_select()++" where m.scope=? and m.scope_id=? and m.id<? order by m.id desc limit 80",[Scope,Id,Before]};
message_sql(Scope,Id,_,After) -> {message_select()++" where m.scope=? and m.scope_id=? and m.id>? order by m.id asc limit 250",[Scope,Id,After]}.

validate_thread(Conn,F,T,B) -> case {F,byte_size(T)>=3,byte_size(B)>0,one(Conn,"select id from forums where id=?",[F])} of {I,true,true,{ok,[_]}} when is_integer(I)->ok; _->{error,invalid_thread} end.
friendship_status(_, U, U) -> self;
friendship_status(Conn,A,B) -> {L,H}=pair(A,B), case one(Conn,"select status,requester_id,addressee_id from friendships where user_low=? and user_high=?",[L,H]) of {ok,[S,R,Ad]} -> #{status=>S,incoming=>(S=:=<<"pending">> andalso Ad=:=A),outgoing=>(S=:=<<"pending">> andalso R=:=A)}; _ -> #{status=>none} end.
is_member(Conn,Uid,Sid) -> case one(Conn,"select role from server_members where server_id=? and user_id=?",[Sid,Uid]) of {ok,[_]}->true; _->false end.
can_manage_server(Conn,Uid,Sid) -> case one(Conn,"select role from server_members where server_id=? and user_id=?",[Sid,Uid]) of {ok,[<<"owner">>]}->true; {ok,[<<"admin">>]}->true; _->false end.
channel_server_member(Conn,Uid,Cid) -> case one(Conn,"select c.server_id from channels c join server_members sm on sm.server_id=c.server_id and sm.user_id=? where c.id=?",[Uid,Cid]) of {ok,[Sid]}->{ok,Sid}; _->{error,forbidden} end.
can_read_messages(Conn,Uid,<<"channel">>,Id) -> case channel_server_member(Conn,Uid,Id) of {ok,_}->true; _->false end;
can_read_messages(Conn,Uid,<<"direct">>,Id) -> is_conversation_member(Conn,Uid,Id);
can_read_messages(_,_,_,_) -> false.
is_conversation_member(Conn,Uid,Cid) -> case one(Conn,"select user_id from direct_members where thread_id=? and user_id=?",[Cid,Uid]) of {ok,[_]}->true; _->false end.

notify_thread_participants(Conn,Tid,Sender,Body,Now) -> {ok,Rows}=rows(Conn,"select distinct user_id from (select user_id from threads where id=? union select user_id from replies where thread_id=?) where user_id<>?",[Tid,Tid,Sender]), Url= <<"#/thread/",(integer_to_binary(Tid))/binary>>, [begin U=only_id(R), create_notification(Conn,U,<<"thread_reply">>,pw_util:clean_text(Body,140),Url,Now), pw_hub:notify_user(U,#{type=>thread_reply,thread_id=>Tid}) end || R<-Rows], ok.
notify_channel_members(Conn,Sid,Sender,Cid,Msg,Now) -> {ok,Rows}=rows(Conn,"select user_id from server_members where server_id=? and user_id<>?",[Sid,Sender]), [begin U=only_id(R), create_notification(Conn,U,<<"channel_message">>,maps:get(body,Msg),<<"#/channel/",(integer_to_binary(Cid))/binary>>,Now), pw_hub:notify_user(U,#{type=>channel_message,channel_id=>Cid}) end || R<-Rows], ok.
notify_direct_members(Conn,Cid,Sender,Event,Now) -> {ok,Rows}=rows(Conn,"select user_id from direct_members where thread_id=? and user_id<>? and muted=0",[Cid,Sender]), [begin U=only_id(R), create_notification(Conn,U,<<"direct_message">>,<<"New direct message">>,<<"#/dm/",(integer_to_binary(Cid))/binary>>,Now), pw_hub:notify_user(U,Event) end || R<-Rows], ok.
create_notification(Conn,U,K,B,Url,Now) -> ok=exec(Conn,"insert into notifications(user_id,kind,body,url,seen,created_at) values(?,?,?,?,?,?)",[U,K,pw_util:clean_text(B,180),Url,0,Now]).
mark_url_seen0(Conn,Uid,Url) -> _=exec(Conn,"update notifications set seen=1 where user_id=? and url=?",[Uid,Url]), ok.
