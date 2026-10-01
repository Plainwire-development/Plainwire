-module(pw_reports).
-export([config/0, validate/1, image_type/1, submit/4, mine/3, withdraw/4,
         list/3, detail/3, update/4, evidence/5, lock_action/4, action_done/5, gc/1]).

%% All database entry points run on a pw_db lane. Mutations are wrapped in its
%% transaction boundary; this module never opens a second connection or commits.
-define(FILE_MAX, 5242880).
-define(OWNER_MAX, 33554432).
-define(DAY, 86400000).

config() -> #{categories => categories(), max_evidence_files => 3, max_evidence_bytes => ?FILE_MAX,
              reports_per_day => 5, evidence_retention_days => retention_days()}.
categories() -> [<<"harassment">>, <<"hate">>, <<"threats">>, <<"spam">>, <<"scam">>,
                 <<"privacy">>, <<"impersonation">>, <<"other">>].
statuses() -> [<<"open">>, <<"in_review">>, <<"resolved">>, <<"dismissed">>, <<"withdrawn">>].
priorities() -> [<<"low">>, <<"normal">>, <<"high">>, <<"urgent">>].

validate(M) when is_map(M) -> checked(fun() ->
    Subject = entity_id(maps:get(<<"user_id">>, M, undefined)),
    Category = choice(maps:get(<<"category">>, M, <<"other">>), categories(), invalid_report),
    Reason = text(maps:get(<<"reason">>, M, <<>>), 4000),
    Key = maps:get(<<"request_key">>, M, <<>>),
    need(token(Key, 16, 80), invalid_report),
    Files = maps:get(<<"evidence_ids">>, M, []),
    need(is_list(Files), invalid_evidence),
    need(length(Files) =< 3 andalso length(Files) =:= length(lists:usort(Files)), invalid_evidence),
    need(lists:all(fun(Id) -> token(Id, 24, 64) end, Files), invalid_evidence),
    need(Reason =/= <<>> orelse Files =/= [], report_reason_required),
    Mid0 = maps:get(<<"message_id">>, M, 0),
    Mid = case Mid0 of 0 -> 0; null -> 0; _ -> positive(Mid0) end,
    Include = maps:get(<<"include_message">>, M, false),
    need(is_boolean(Include) andalso (not Include orelse Mid > 0), invalid_report),
    {ok, #{subject => Subject, category => Category, reason => Reason, key => Key,
           files => Files, message_id => Mid, include_message => Include}}
end);
validate(_) -> {error, invalid_report}.

submit(Conn, Uid, Body, ContextFun) -> checked(fun() ->
    P = unwrap(validate(Body)), Subject = maps:get(subject, P),
    need(Subject =/= Uid, cannot_report_self),
    %% Per-account serialization protects durable quotas and retry idempotency
    %% across lanes/nodes. The HTTP limiter is only the first flood guard.
    _ = rows(Conn, "SELECT pg_advisory_xact_lock(21427,$1)", [Uid]),
    [Username, Display] = active_reporter(Conn, Uid),
    Hash = pw_util:sha256_hex(pw_util:json(maps:without([key], P))),
    case row(Conn, "SELECT id,request_hash FROM moderation_reports WHERE reporter_id=$1 AND request_key=$2", [Uid,maps:get(key,P)]) of
        [Id, Hash] -> {ok, public_report(Conn, Uid, Id)};
        [_, _] -> fail(report_request_conflict);
        undefined ->
            [TargetName, TargetDisplay] = existing_subject(Conn, Subject),
            [[Count]] = rows(Conn, "SELECT count(*) FROM moderation_reports WHERE reporter_id=$1 AND created_at>$2", [Uid,pw_util:now_ms()-?DAY]),
            need(Count < 5, report_rate_limited),
            Context = case maps:get(message_id,P) of
                0 -> #{};
                Mid -> unwrap(ContextFun(Mid, Subject, maps:get(include_message,P)))
            end,
            Files = [snapshot_upload(Conn, Uid, F) || F <- maps:get(files,P)],
            reserve_evidence(Conn, Uid, Files),
            Now = pw_util:now_ms(),
            Priority = case maps:get(category,P) of <<"threats">> -> <<"high">>; _ -> <<"normal">> end,
            [Id] = row(Conn,
                "INSERT INTO moderation_reports(reporter_id,subject_id,reporter_username,reporter_display_name,subject_username,subject_display_name,category,reason,message_context,priority,request_key,request_hash,created_at,updated_at) "
                "VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11,$12,$13,$13) RETURNING id",
                [Uid,Subject,Username,Display,TargetName,TargetDisplay,maps:get(category,P),pw_crypto:encrypt(maps:get(reason,P)),pw_util:json(protect_context(Context)),Priority,maps:get(key,P),Hash,Now]),
            [insert_evidence(Conn, Id, Uid, F) || F <- Files],
            event(Conn, Id, Uid, Username, <<"submitted">>, <<>>, Now),
            {ok, public_report(Conn, Uid, Id)}
    end
end).

mine(Conn, Uid, Opts) -> checked(fun() ->
    Before = cursor(maps:get(<<"before">>,Opts,undefined)), Limit = limit(maps:get(<<"limit">>,Opts,30)),
    Reports = rows(Conn, select_report() ++ " WHERE r.reporter_id=$1 AND r.id<$2 ORDER BY r.id DESC LIMIT $3", [Uid,Before,Limit+1]),
    page([(public_map(R))#{evidence=>evidence_list(Conn,hd(R))} || R <- Reports], Limit)
end).

withdraw(Conn, Uid, Id0, Body) -> checked(fun() ->
    Id = positive(Id0),
    R = get_report(Conn, Id, true),
    need(maps:get(reporter_id,R) =:= Uid, not_found),
    need(is_map(Body),invalid_report), revision(R, Body),
    need(active(R), report_closed),
    Now = pw_util:now_ms(),
    exec(Conn, "UPDATE moderation_reports SET status='withdrawn',resolution='withdrawn',closed_at=$2,updated_at=$2,revision=revision+1 WHERE id=$1", [Id,Now]),
    event(Conn, Id, Uid, maps:get(reporter_username,R), <<"withdrawn">>, <<>>, Now),
    {ok, public_report(Conn, Uid, Id)}
end).

list(Conn, Actor, Opts) -> checked(fun() ->
    _ = reviewer(Conn, Actor),
    Status = choice(maps:get(<<"status">>,Opts,<<"active">>), [<<"all">>,<<"active">>|statuses()], invalid_report_filter),
    Priority = choice(maps:get(<<"priority">>,Opts,<<"all">>), [<<"all">>|priorities()], invalid_report_filter),
    Q = text(maps:get(<<"q">>,Opts,<<>>),100),
    Assigned = choice(maps:get(<<"assigned">>,Opts,<<"all">>), [<<"all">>,<<"mine">>,<<"unassigned">>], invalid_report_filter),
    Before = cursor(maps:get(<<"before">>,Opts,undefined)), Limit = limit(maps:get(<<"limit">>,Opts,30)),
    %% A reviewer does not gain access to reports they submitted or are about
    %% them. Another operator must handle that conflict of interest.
    Reports = rows(Conn, select_report() ++
        " WHERE r.reporter_id IS DISTINCT FROM $1 AND r.subject_id IS DISTINCT FROM $1 AND r.id<$2 "
        "AND ($3='all' OR ($3='active' AND r.status IN ('open','in_review')) OR r.status=$3) "
        "AND ($4='all' OR r.priority=$4) "
        "AND ($5='' OR r.subject_username ILIKE $6 OR r.reporter_username ILIKE $6) "
        "AND ($7='all' OR ($7='mine' AND r.assignee_id=$1) OR ($7='unassigned' AND r.assignee_id IS NULL)) "
        "ORDER BY r.id DESC LIMIT $8", [Actor,Before,Status,Priority,Q,<<"%",Q/binary,"%">>,Assigned,Limit+1]),
    {ok, P} = page([summary_map(R) || R <- Reports], Limit),
    Counts = rows(Conn, "SELECT status,count(*) FROM moderation_reports WHERE reporter_id IS DISTINCT FROM $1 AND subject_id IS DISTINCT FROM $1 GROUP BY status", [Actor]),
    {ok,P#{counts => maps:from_list([{S,N} || [S,N] <- Counts])}}
end).

detail(Conn, Actor, Id0) -> checked(fun() ->
    _ = reviewer(Conn,Actor), Id = positive(Id0), R = get_report(Conn,Id,false),
    neutral(R,Actor),
    audit(Conn,Actor,Id,<<"view">>,pw_util:now_ms()),
    History = rows(Conn,"SELECT id,actor_id,actor_username,action,note,created_at FROM moderation_report_events WHERE report_id=$1 ORDER BY id DESC LIMIT 100",[Id]),
    {ok,R#{evidence => evidence_list(Conn,Id),history => [#{id=>I,actor_id=>A,actor_username=>U,action=>Act,note=>pw_crypto:decrypt(N),created_at=>T} || [I,A,U,Act,N,T] <- History]}}
end).

update(Conn, Actor, Id0, M) -> checked(fun() ->
    exec(Conn,"LOCK TABLE admin_operators IN SHARE MODE",[]),
    need(is_map(M),invalid_report),
    Role = reviewer(Conn,Actor), Id = positive(Id0), R = get_report(Conn,Id,true),
    neutral(R,Actor), revision(R,M),
    Assigned = maps:get(assignee_id,R),
    need(Assigned =:= null orelse Assigned =:= Actor orelse Role =:= <<"owner">>, report_assigned_elsewhere),
    Action = choice(maps:get(<<"action">>,M,<<>>),[<<"claim">>,<<"unassign">>,<<"note">>,<<"priority">>,<<"resolve">>,<<"dismiss">>,<<"reopen">>],invalid_report_action),
    Note = text(maps:get(<<"note">>,M,<<>>),4000),
    Now = pw_util:now_ms(),
    case Action of
        <<"claim">> ->
            need(active(R),report_closed),
            exec(Conn,"UPDATE moderation_reports SET assignee_id=$2,status='in_review' WHERE id=$1",[Id,Actor]);
        <<"unassign">> ->
            need(active(R),report_closed),
            exec(Conn,"UPDATE moderation_reports SET assignee_id=NULL,status='open' WHERE id=$1",[Id]);
        <<"priority">> ->
            need(active(R),report_closed),
            Priority = choice(maps:get(<<"priority">>,M,<<>>),priorities(),invalid_report_action),
            exec(Conn,"UPDATE moderation_reports SET priority=$2 WHERE id=$1",[Id,Priority]);
        <<"note">> -> need(Note =/= <<>>,report_note_required);
        <<"reopen">> ->
            need(lists:member(maps:get(status,R),[<<"resolved">>,<<"dismissed">>]),report_closed),
            need(Note =/= <<>>,report_note_required),
            exec(Conn,"UPDATE moderation_reports SET status='in_review',assignee_id=$2,resolution='',public_response='',closed_at=0 WHERE id=$1",[Id,Actor]);
        _ ->
            need(active(R),report_closed), need(Note =/= <<>>,report_note_required),
            need(Assigned =:= Actor orelse Role =:= <<"owner">>,report_not_assigned),
            Resolution = choice(maps:get(<<"resolution">>,M,<<>>),[<<"no_violation">>,<<"insufficient_evidence">>,<<"duplicate">>,<<"invalid_report">>],invalid_report_action),
            Response = text(maps:get(<<"public_response">>,M,<<>>),1000),
            Status = case Action of <<"resolve">> -> <<"resolved">>; _ -> <<"dismissed">> end,
            exec(Conn,"UPDATE moderation_reports SET status=$2,resolution=$3,public_response=$4,closed_at=$5 WHERE id=$1",[Id,Status,Resolution,pw_crypto:encrypt(Response),Now])
    end,
    exec(Conn,"UPDATE moderation_reports SET updated_at=$2,revision=revision+1 WHERE id=$1",[Id,Now]),
    event(Conn,Id,Actor,actor_name(Conn,Actor),Action,Note,Now), audit(Conn,Actor,Id,Action,Now),
    {ok,summary_map(get_report(Conn,Id,false))}
end).

%% Called inside the existing account-moderation transaction. A linked action
%% cannot target a different account, bypass a reviewer's assignment, or race a
%% closed case. Failure rolls back both the restriction and report resolution.
lock_action(Conn, Actor, Subject, Patch) -> checked(fun() ->
    case maps:get(<<"report_id">>,Patch,undefined) of
        undefined -> {ok,none};
        Id0 ->
            Role = reviewer(Conn,Actor), Id = positive(Id0), R = get_report(Conn,Id,true), neutral(R,Actor),
            revision(R,#{<<"expected_revision">> => maps:get(<<"report_revision">>,Patch,undefined)}),
            need(maps:get(subject_id,R) =:= Subject,invalid_report_action),
            need(maps:get(status,R) =:= <<"in_review">>,report_not_assigned),
            need(maps:get(assignee_id,R) =:= Actor orelse Role =:= <<"owner">>,report_assigned_elsewhere),
            {ok,R}
    end
end).

action_done(_Conn,_Actor,none,_Action,_Now) -> ok;
action_done(Conn,Actor,R,Action,Now) ->
    Id = maps:get(id,R),
    exec(Conn,"UPDATE moderation_reports SET status='resolved',resolution='action_taken',public_response='Reviewed. Moderation action was taken.',closed_at=$2,updated_at=$2,revision=revision+1 WHERE id=$1",[Id,Now]),
    event(Conn,Id,Actor,actor_name(Conn,Actor),<<"account.",(atom_to_binary(Action,utf8))/binary>>,<<>>,Now),
    audit(Conn,Actor,Id,<<"action_taken">>,Now).

evidence(Conn, Role, Uid, Id0, Evidence0) -> checked(fun() ->
    Id = positive(Id0), EId = positive(Evidence0), R = get_report(Conn,Id,false),
    case Role of
        admin -> _ = reviewer(Conn,Uid), neutral(R,Uid);
        reporter -> need(maps:get(reporter_id,R) =:= Uid,not_found)
    end,
    case row(Conn,"SELECT content_type,name,size,sha256,data FROM moderation_report_evidence WHERE report_id=$1 AND id=$2",[Id,EId]) of
        [Type,Name,Size,Hash,Data] ->
            case Role of admin -> audit(Conn,Uid,Id,<<"evidence_view">>,pw_util:now_ms()); _ -> ok end,
            Plain = pw_crypto:decrypt(Data),
            need(byte_size(Plain)=:=Size andalso pw_util:sha256_hex(Plain)=:=Hash,report_evidence_unavailable),
            {ok,#{content_type=>Type,name=>Name,size=>Size,sha256=>Hash,data=>Plain}};
        _ -> fail(not_found)
    end
end).

gc(Conn) ->
    %% Lock the singleton budget before deleting evidence so quota accounting
    %% remains atomic with concurrent submissions. A sweep handles 100 cases.
    _ = rows(Conn,"SELECT bytes FROM moderation_evidence_budget WHERE id=1 FOR UPDATE",[]),
    Cutoff = pw_util:now_ms()-retention_days()*?DAY,
    Ids = [Id || [Id] <- rows(Conn,"SELECT id FROM moderation_reports WHERE closed_at>0 AND closed_at<$1 AND evidence_purged_at=0 ORDER BY closed_at,id LIMIT 100 FOR UPDATE SKIP LOCKED",[Cutoff])],
    lists:foreach(fun(Id) ->
        Removed = rows(Conn,"DELETE FROM moderation_report_evidence WHERE report_id=$1 RETURNING stored_size",[Id]),
        Bytes = lists:sum([S || [S] <- Removed]),
        exec(Conn,"UPDATE moderation_evidence_budget SET bytes=bytes-$1 WHERE id=1",[Bytes]),
        exec(Conn,"UPDATE moderation_reports SET message_context='{}'::jsonb,evidence_purged_at=$2,revision=revision+1 WHERE id=$1",[Id,pw_util:now_ms()])
    end,Ids),
    {ok,#{purged=>length(Ids)}}.

retention_days() -> min(365,max(7,pw_util:env_int("PLAINWIRE_REPORT_EVIDENCE_RETENTION_DAYS",90))).
budget_max() -> min(10737418240,max(?FILE_MAX,pw_util:env_int("PLAINWIRE_REPORT_EVIDENCE_BUDGET_BYTES",536870912))).

snapshot_upload(Conn,Uid,Id) ->
    case row(Conn,"SELECT name,content_type,size,path,sha256 FROM uploads WHERE id=$1 AND user_id=$2 AND status='ready' FOR SHARE",[Id,Uid]) of
        [Name,_Declared,Size,Path,ExpectedHash] when Size > 0, Size =< ?FILE_MAX ->
            Data = read_bounded(Path),
            need(byte_size(Data) =:= Size andalso pw_util:sha256_hex(Data) =:= ExpectedHash,invalid_evidence),
            Type = unwrap(image_type(Data)),
            Stored = pw_crypto:encrypt(Data),
            #{name=>pw_util:clean_text(Name,150),content_type=>Type,size=>Size,stored_size=>byte_size(Stored),sha256=>ExpectedHash,data=>Stored};
        _ -> fail(invalid_evidence)
    end.

read_bounded(Path) ->
    case file:open(Path,[read,binary,raw]) of
        {ok,Fd} -> try
            case file:pread(Fd,0,?FILE_MAX+1) of {ok,B} when byte_size(B)=< ?FILE_MAX -> B; _ -> fail(invalid_evidence) end
        after file:close(Fd) end;
        _ -> fail(invalid_evidence)
    end.

%% Never trust an upload's declared MIME type. Only passive raster signatures
%% with bounded dimensions enter the immutable review store. SVG/HTML are denied.
image_type(<<137,80,78,71,13,10,26,10,13:32/big,"IHDR",W:32/big,H:32/big,Rest/binary>>) when byte_size(Rest)>=9 ->
    case dimensions(W,H) of true -> {ok,<<"image/png">>}; false -> {error,invalid_evidence} end;
image_type(<<255,216,Rest/binary>>) -> jpeg_type(Rest,0);
image_type(_) -> {error,invalid_evidence}.
jpeg_type(<<255,Marker,Length:16/big,Rest/binary>>,Steps) when Length>=2, byte_size(Rest)>=Length-2, Steps<256 ->
    N=Length-2, <<Segment:N/binary,Tail/binary>>=Rest,
    case lists:member(Marker,[192,193,194,195,197,198,199,201,202,203,205,206,207]) of
        true -> case Segment of <<_Depth,H:16/big,W:16/big,_/binary>> ->
            case dimensions(W,H) of true -> {ok,<<"image/jpeg">>}; false -> {error,invalid_evidence} end;
            _ -> {error,invalid_evidence} end;
        false -> jpeg_type(Tail,Steps+1)
    end;
jpeg_type(<<255,255,Rest/binary>>,Steps) when Steps<256 -> jpeg_type(<<255,Rest/binary>>,Steps+1);
jpeg_type(_,_) -> {error,invalid_evidence}.
dimensions(W,H) -> W>0 andalso H>0 andalso W=<8192 andalso H=<8192 andalso W*H=<33554432.

reserve_evidence(_Conn,_Uid,[]) -> ok;
reserve_evidence(Conn,Uid,Files) ->
    Bytes = lists:sum([maps:get(stored_size,F) || F<-Files]),
    [[Own]] = rows(Conn,"SELECT COALESCE(sum(stored_size),0)::bigint FROM moderation_report_evidence WHERE owner_id=$1",[Uid]),
    need(Own+Bytes=< ?OWNER_MAX,report_evidence_quota),
    case row(Conn,"UPDATE moderation_evidence_budget SET bytes=bytes+$1 WHERE id=1 AND bytes+$1<=$2 RETURNING bytes",[Bytes,budget_max()]) of
        [_] -> ok;
        _ -> fail(report_evidence_storage_full)
    end.
insert_evidence(Conn,Id,Uid,F) ->
    exec(Conn,"INSERT INTO moderation_report_evidence(report_id,owner_id,name,content_type,size,sha256,data) VALUES($1,$2,$3,$4,$5,$6,$7)",
        [Id,Uid,maps:get(name,F),maps:get(content_type,F),maps:get(size,F),maps:get(sha256,F),maps:get(data,F)]).

active_reporter(Conn,Uid) ->
    case row(Conn,"SELECT username,display_name FROM users WHERE id=$1 AND account_state='active' AND NOT is_bot FOR SHARE",[Uid]) of
        [_,_]=R -> R;
        _ -> fail(forbidden)
    end.
existing_subject(Conn,Uid) ->
    case row(Conn,"SELECT username,display_name FROM users WHERE id=$1 FOR SHARE",[Uid]) of [_,_]=R -> R; _ -> fail(not_found) end.
reviewer(Conn,Uid) ->
    case row(Conn,"SELECT a.role FROM admin_operators a JOIN users u ON u.id=a.user_id WHERE a.user_id=$1 AND u.account_state='active' FOR SHARE OF u,a",[Uid]) of
        [Role] when Role=:= <<"owner">>; Role=:= <<"operator">> -> Role;
        _ -> fail(forbidden)
    end.
actor_name(Conn,Uid) -> [Name] = row(Conn,"SELECT username FROM users WHERE id=$1",[Uid]),Name.
neutral(R,Uid) -> need(maps:get(reporter_id,R)=/=Uid andalso maps:get(subject_id,R)=/=Uid,forbidden).
active(R) -> lists:member(maps:get(status,R),[<<"open">>,<<"in_review">>]).
revision(R,M) -> need(maps:get(<<"expected_revision">>,M,undefined)=:=maps:get(revision,R),report_conflict).

select_report() -> "SELECT r.id,r.reporter_id,r.subject_id,r.reporter_username,r.reporter_display_name,r.subject_username,r.subject_display_name,r.category,r.reason,r.message_context::text,r.status,r.priority,r.assignee_id,r.resolution,r.public_response,r.revision,r.created_at,r.updated_at,r.closed_at,r.evidence_purged_at FROM moderation_reports r".
get_report(Conn,Id,Lock) ->
    Suffix=case Lock of true -> " FOR UPDATE"; false -> "" end,
    case row(Conn,select_report()++" WHERE r.id=$1"++Suffix,[Id]) of undefined -> fail(not_found); R -> report_map(R) end.
report_map([Id,Reporter,Subject,RU,RD,SU,SD,C,Reason,Context,Status,Priority,Assignee,Resolution,Response,Revision,Created,Updated,Closed,Purged]) ->
    #{id=>Id,reporter_id=>Reporter,subject_id=>Subject,reporter_username=>RU,reporter_display_name=>RD,subject_username=>SU,subject_display_name=>SD,
      category=>C,reason=>pw_crypto:decrypt(Reason),message_context=>reveal_context(jsx:decode(Context,[return_maps])),status=>Status,priority=>Priority,assignee_id=>Assignee,resolution=>Resolution,
      public_response=>pw_crypto:decrypt(Response),revision=>Revision,created_at=>Created,updated_at=>Updated,closed_at=>Closed,evidence_purged_at=>Purged}.
summary_map(R) when is_list(R) -> summary_map(report_map(R));
summary_map(R) -> maps:without([reason,message_context,request_key,request_hash],R).
public_map(R) when is_list(R) -> public_map(report_map(R));
public_map(R) -> maps:with([id,subject_id,subject_username,subject_display_name,category,reason,status,public_response,revision,created_at,updated_at,evidence_purged_at],R).
public_report(Conn,Uid,Id) ->
    R=get_report(Conn,Id,false),need(maps:get(reporter_id,R)=:=Uid,not_found),
    (public_map(R))#{evidence=>evidence_list(Conn,Id)}.
evidence_list(Conn,Id) ->
    [#{id=>E,name=>N,content_type=>T,size=>S,sha256=>H} || [E,N,T,S,H]<-rows(Conn,"SELECT id,name,content_type,size,sha256 FROM moderation_report_evidence WHERE report_id=$1 ORDER BY id",[Id])].
page(Reports,Limit) ->
    Items=lists:sublist(Reports,Limit),
    Next=case length(Reports)>Limit of true -> maps:get(id,lists:last(Items)); false -> null end,
    {ok,#{items=>Items,next_before=>Next}}.

event(Conn,Id,Actor,Name,Action,Note,Now) ->
    exec(Conn,"INSERT INTO moderation_report_events(report_id,actor_id,actor_username,action,note,created_at) VALUES($1,$2,$3,$4,$5,$6)",[Id,Actor,Name,Action,pw_crypto:encrypt(Note),Now]).
audit(Conn,Actor,Id,Action,Now) ->
    exec(Conn,"INSERT INTO admin_audit(actor_user_id,action,target_type,target_id,detail,ip_hash,created_at) VALUES($1,$2,'report',$3,'','',$4)",
        [Actor,<<"report.",Action/binary>>,integer_to_binary(Id),Now]).

protect_context(#{body := Body}=M) -> M#{body=>pw_crypto:encrypt(Body)};
protect_context(M) -> M.
reveal_context(#{<<"body">> := Body}=M) -> M#{<<"body">>=>pw_crypto:decrypt(Body)};
reveal_context(M) -> M.

checked(Fun) -> try Fun() catch throw:{report_error,Reason} -> {error,Reason} end.
unwrap({ok,Value}) -> Value;
unwrap({error,Reason}) -> fail(Reason).
need(true,_) -> ok;
need(_,Reason) -> fail(Reason).
fail(Reason) -> throw({report_error,Reason}).
positive(V) -> case pw_util:int(V) of I when is_integer(I),I>0,I=<9223372036854775807 -> I; _ -> fail(invalid_report) end.
entity_id(V) -> I = positive(V), need(I =< 2147483647, invalid_report), I.
cursor(undefined) -> 9223372036854775807;
cursor(null) -> 9223372036854775807;
cursor(V) -> positive(V).
limit(V) -> min(50,positive(V)).
choice(V,Values,Reason) -> need(lists:member(V,Values),Reason),V.
text(V,Max) when is_binary(V),byte_size(V)=<Max*4 ->
    case unicode:characters_to_list(V) of
        L when is_list(L),length(L)=<Max -> string:trim(pw_util:clean_text(V,Max*4));
        _ -> fail(invalid_report)
    end;
text(_,_) -> fail(invalid_report).
token(V,Min,Max) when is_binary(V),byte_size(V)>=Min,byte_size(V)=<Max ->
    lists:all(fun(C)->(C>=$a andalso C=<$z) orelse (C>=$A andalso C=<$Z) orelse (C>=$0 andalso C=<$9) orelse C=:=$_ orelse C=:=$- end,binary_to_list(V));
token(_,_,_) -> false.
rows(Conn,Sql,Params) ->
    Result=case Params of [] -> epgsql:squery(Conn,Sql); _ -> epgsql:equery(Conn,Sql,Params) end,
    case Result of
        {ok,_} -> [];
        {ok,_,Rs} when is_list(Rs) -> [tuple_to_list(R)||R<-Rs];
        {ok,_,_,Rs} when is_list(Rs) -> [tuple_to_list(R)||R<-Rs];
        Other -> erlang:error({report_database,Other})
    end.
row(Conn,Sql,Params) -> case rows(Conn,Sql,Params) of [] -> undefined; [R|_] -> R end.
exec(Conn,Sql,Params) -> _=rows(Conn,Sql,Params),ok.
