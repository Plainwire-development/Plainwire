-module(pw_reports_tests).
-include_lib("eunit/include/eunit.hrl").

validation_test() ->
    B=body(),
    ?assertMatch({ok,_},pw_reports:validate(B)),
    Unicode=binary:copy(unicode:characters_to_binary([16#1f642]),4000),
    ?assertMatch({ok,#{reason:=Unicode}},pw_reports:validate(B#{<<"reason">>=>Unicode})),
    ?assertMatch({error,report_reason_required},pw_reports:validate(B#{<<"reason">>=><<" \n ">>})),
    ?assertMatch({ok,_},pw_reports:validate(B#{<<"reason">>=><<>>,<<"evidence_ids">>=>[file_id()]})),
    lists:foreach(fun(Patch)->?assertMatch({error,_},pw_reports:validate(maps:merge(B,Patch))) end,
        [#{<<"reason">>=>lists:duplicate(4001,$a)},#{<<"reason">>=>binary:copy(<<"a">>,4001)},
         #{<<"category">>=><<"made_up">>},#{<<"user_id">>=>-1},#{<<"user_id">>=>9223372036854775808},
         #{<<"user_id">>=>2147483648},
         #{<<"request_key">>=><<"bad key">>},#{<<"evidence_ids">>=>[file_id(),file_id()]},
         #{<<"evidence_ids">>=>[<<"../private.png">>]},#{<<"evidence_ids">>=><<"oops">>},
         #{<<"include_message">>=>true},#{<<"include_message">>=><<"false">>}]),
    ?assertMatch({ok,#{message_id:=9007199254740991}},pw_reports:validate(B#{<<"message_id">>=>9007199254740991})),
    ?assertEqual({error,invalid_report},pw_reports:validate([])).

raster_validation_test() ->
    ?assertEqual({ok,<<"image/png">>},pw_reports:image_type(png())),
    Jpeg= <<255,216,255,224,4:16,0,0,255,192,7:16,8,1:16,1:16>>,
    ?assertEqual({ok,<<"image/jpeg">>},pw_reports:image_type(Jpeg)),
    ?assertEqual({error,invalid_evidence},pw_reports:image_type(<<"<svg onload='alert(1)'/>">>)),
    ?assertEqual({error,invalid_evidence},pw_reports:image_type(<<137,80,78,71,13,10,26,10>>)),
    ?assertEqual({error,invalid_evidence},pw_reports:image_type(<<137,80,78,71,13,10,26,10,13:32,"IHDR",65535:32,65535:32,0:72>>)),
    ?assertEqual({error,invalid_evidence},pw_reports:image_type(<<255,216,255,224,65535:16,0>>)).

reports_postgres_test_() ->
    case os:getenv("PLAINWIRE_TEST_POSTGRES_PORT") of
        false -> [];
        Port -> {setup,fun()->setup(list_to_integer(Port)) end,fun cleanup/1,
            fun({C,_})->[
                ?_test(idempotent_submission(C)),
                ?_test(durable_daily_limit(C)),
                ?_test(filtered_cursor_pagination(C)),
                ?_test(owner_quota(C)),
                ?_test(protected_accounts(C)),
                ?_test(reporter_eligibility(C)),
                ?_test(immutable_owned_evidence(C)),
                ?_test(evidence_quota_rollback(C)),
                ?_test(optional_scoped_message(C)),
                ?_test(reviewer_privacy(C)),
                ?_test(own_submission_visibility(C)),
                ?_test(assignment_revisions_and_notes(C)),
                ?_test(withdrawal_and_decisions(C)),
                ?_test(linked_action_is_atomic(C)),
                ?_test(retention_preserves_case_history(C)),
                ?_test(encrypted_evidence(C))
            ] end}
    end.

setup(Port) ->
    {ok,C}=epgsql:connect(#{host=>"127.0.0.1",port=>Port,username=>os:getenv("PLAINWIRE_TEST_POSTGRES_USER","plainwire_audit"),database=>os:getenv("PLAINWIRE_TEST_POSTGRES_DB","postgres"),timeout=>5000}),
    sql(C,"CREATE TEMP TABLE users(id integer PRIMARY KEY,username text,display_name text,account_state text DEFAULT 'active',is_bot boolean DEFAULT false,disabled_at bigint DEFAULT 0,moderation_title text DEFAULT '',moderation_reason text DEFAULT '',moderation_severity text DEFAULT 'warning',moderation_expires_at bigint DEFAULT 0,moderated_by integer,moderated_at bigint DEFAULT 0,updated_at bigint DEFAULT 0)"),
    sql(C,"CREATE TEMP TABLE admin_operators(user_id integer PRIMARY KEY,role text)"),
    sql(C,"CREATE TEMP TABLE admin_audit(actor_user_id integer,action text,target_type text,target_id text,detail text,ip_hash text,created_at bigint)"),
    sql(C,"CREATE TEMP TABLE uploads(id text PRIMARY KEY,user_id integer,name text,content_type text,size bigint,path text,sha256 text,status text)"),
    sql(C,"CREATE TEMP TABLE messages(id integer PRIMARY KEY,user_id integer,scope text,scope_id integer,body text,created_at bigint,edited_at bigint,kind text DEFAULT 'text',deleted_at bigint)"),
    sql(C,"CREATE TEMP TABLE direct_members(thread_id integer,user_id integer)"),
    sql(C,"CREATE TEMP TABLE friendships(user_low integer,user_high integer,status text)"),
    sql(C,"CREATE TEMP TABLE sessions(token_hash text PRIMARY KEY,user_id integer)"),
    sql(C,"CREATE TEMP TABLE admin_sessions(token_hash text PRIMARY KEY,user_id integer)"),
    sql(C,"CREATE TEMP TABLE instance_account_actions(user_id integer,actor_user_id integer,action text,title text,reason text,severity text,expires_at bigint,created_at bigint)"),
    {54,Statements}=lists:keyfind(54,1,pw_db_schema:migrations()),
    lists:foreach(fun(S)->sql(C,string:replace(S,"CREATE TABLE IF NOT EXISTS","CREATE TEMP TABLE IF NOT EXISTS",all)) end,Statements),
    sql(C,"INSERT INTO users(id,username,display_name) VALUES(1,'reporter','Reporter'),(2,'subject','Subject'),(3,'owner','Owner'),(4,'operator','Operator'),(5,'viewer','Viewer'),(6,'other_reviewer','Other Reviewer'),(8,'bot','Bot')"),
    sql(C,"UPDATE users SET is_bot=true WHERE id=8"),
    sql(C,"INSERT INTO admin_operators VALUES(3,'owner'),(4,'operator'),(5,'viewer'),(6,'operator')"),
    sql(C,"INSERT INTO direct_members VALUES(100,1),(100,2),(200,2)"),
    sql(C,"INSERT INTO messages(id,user_id,scope,scope_id,body,created_at) VALUES(10,2,'direct',100,'submitted message',1000),(11,1,'direct',100,'wrong author',1001),(12,2,'direct',200,'unrelated private message',1002),(13,2,'direct',100,'deleted',1003),(14,2,'direct',100,'missed call',1004)"),
    sql(C,"UPDATE messages SET deleted_at=1 WHERE id=13"),sql(C,"UPDATE messages SET kind='call' WHERE id=14"),
    OwnCache=case ets:whereis(pw_session_cache) of undefined->ets:new(pw_session_cache,[named_table,public,set]),true; _->false end,
    {C,OwnCache}.
cleanup({C,OwnCache}) -> epgsql:close(C),case OwnCache of true->ets:delete(pw_session_cache);false->ok end.

seed(C) ->
    sql(C,"TRUNCATE moderation_reports,uploads,sessions,admin_sessions,instance_account_actions,admin_audit RESTART IDENTITY CASCADE"),
    sql(C,"UPDATE moderation_evidence_budget SET bytes=0"),sql(C,"UPDATE users SET account_state='active',moderation_title='',moderation_reason='',moderated_at=0"),
    sql(C,"UPDATE admin_operators SET role='operator' WHERE user_id=4"),sql(C,"DELETE FROM friendships"),
    ok.
body() -> #{<<"user_id">>=>2,<<"category">>=><<"harassment">>,<<"reason">>=><<"report reason">>,<<"request_key">>=><<"report-request-key-0001">>}.
new_body(N) -> (body())#{<<"request_key">>=>list_to_binary("report-request-key-"++integer_to_list(1000+N))}.
file_id() -> <<"report-file-1234567890123456">>.
png() -> base64:decode(<<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3qkAAAAASUVORK5CYII=">>).
call(C,Op) -> pw_db:test_reports(Op,C).
submit(C,B) -> call(C,{create_report,1,B}).
create(C) -> {ok,R}=submit(C,body()),R.
update(C,U,R,M) -> call(C,{admin_update_report,U,maps:get(id,R),M#{<<"expected_revision">>=>maps:get(revision,R)}}).
detail(C,R) -> {ok,D}=call(C,{admin_report,3,maps:get(id,R)}),D.
add_upload(C,Owner,Data,Declared) ->
    Path=filename:join("/tmp","plainwire-report-case-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:write_file(Path,Data),
    query(C,"INSERT INTO uploads VALUES($1,$2,'screenshot.png',$3,$4,$5,$6,'ready')",[file_id(),Owner,Declared,byte_size(Data),list_to_binary(Path),pw_util:sha256_hex(Data)]),Path.

idempotent_submission(C) ->
    seed(C),R=create(C),?assertEqual({ok,R},submit(C,body())),
    ?assertEqual([[1]],rows(C,"SELECT count(*) FROM moderation_reports")),
    ?assertEqual({error,report_request_conflict},submit(C,(body())#{<<"reason">>=><<"changed">>})).
durable_daily_limit(C) ->
    seed(C),lists:foreach(fun(N)->?assertMatch({ok,_},submit(C,new_body(N))) end,lists:seq(1,5)),
    ?assertEqual({error,report_rate_limited},submit(C,new_body(6))),
    ?assertMatch({ok,_},submit(C,new_body(1))).
filtered_cursor_pagination(C) ->
    seed(C),
    lists:foreach(fun(N)->?assertMatch({ok,_},submit(C,new_body(N))) end,lists:seq(1,5)),
    {ok,#{items:=First,next_before:=Cursor}}=call(C,{admin_reports,3,#{<<"limit">>=>2}}),
    ?assertEqual([5,4],[maps:get(id,R)||R<-First]),?assertEqual(4,Cursor),
    {ok,#{items:=Second,next_before:=Next}}=call(C,{admin_reports,3,#{<<"limit">>=>2,<<"before">>=>Cursor}}),
    ?assertEqual([3,2],[maps:get(id,R)||R<-Second]),?assertEqual(2,Next),
    ?assertMatch({ok,#{items:=[],next_before:=null}},call(C,{admin_reports,3,#{<<"q">>=><<"' OR 1=1 --">>}})),
    ?assertMatch({ok,#{items:=[_,_,_,_,_]}},call(C,{admin_reports,3,#{<<"q">>=><<"subject">>}})),
    ?assertMatch({ok,#{items:=[]}},call(C,{admin_reports,3,#{<<"priority">>=><<"urgent">>}})),
    ?assertEqual({error,invalid_report_filter},call(C,{admin_reports,3,#{<<"status">>=><<"bad">>}})).
owner_quota(C) ->
    seed(C),Data= <<(png())/binary,0:(5242880-byte_size(png()))/unit:8>>,
    Path=add_upload(C,1,Data,<<"image/png">>),
    Ids=[file_id(),<<"report-file-2234567890123456">>,<<"report-file-3234567890123456">>],
    try
        [query(C,"INSERT INTO uploads SELECT $1,user_id,name,content_type,size,path,sha256,status FROM uploads WHERE id=$2",[Id,file_id()]) || Id<-tl(Ids)],
        ?assertMatch({ok,_},submit(C,(new_body(1))#{<<"evidence_ids">>=>Ids})),
        ?assertMatch({ok,_},submit(C,(new_body(2))#{<<"evidence_ids">>=>Ids})),
        [[Budget]]=rows(C,"SELECT bytes FROM moderation_evidence_budget"),
        ?assertEqual({error,report_evidence_quota},submit(C,(new_body(3))#{<<"evidence_ids">>=>[file_id()]})),
        ?assertEqual([[Budget]],rows(C,"SELECT bytes FROM moderation_evidence_budget")),
        ?assertEqual([[2]],rows(C,"SELECT count(*) FROM moderation_reports"))
    after file:delete(Path) end.
protected_accounts(C) ->
    seed(C),{ok,R}=submit(C,(body())#{<<"user_id">>=>6}),
    {ok,_}=update(C,4,R,#{<<"action">>=><<"claim">>}),D=detail(C,R),
    Patch=#{<<"reason">>=><<"policy">>,<<"report_id">>=>maps:get(id,R),<<"report_revision">>=>maps:get(revision,D)},
    ?assertEqual({error,operator_protected},call(C,{admin_apply_user_moderation,4,6,<<"ban">>,Patch})),
    ?assertEqual(<<"in_review">>,maps:get(status,detail(C,R))),
    ?assertEqual({error,forbidden},call(C,{admin_report,6,maps:get(id,R)})).
reporter_eligibility(C) ->
    seed(C),?assertEqual({error,cannot_report_self},submit(C,(body())#{<<"user_id">>=>1})),
    ?assertEqual({error,not_found},submit(C,(body())#{<<"user_id">>=>999})),
    ?assertEqual({error,forbidden},call(C,{create_report,8,body()})),
    sql(C,"UPDATE users SET account_state='suspended' WHERE id=1"),?assertEqual({error,forbidden},submit(C,body())).
immutable_owned_evidence(C) ->
    seed(C),Path=add_upload(C,2,png(),<<"image/png">>),
    try
        B=(body())#{<<"reason">>=><<>>,<<"evidence_ids">>=>[file_id()]},
        ?assertEqual({error,invalid_evidence},submit(C,B)),
        query(C,"UPDATE uploads SET user_id=1,content_type='text/html' WHERE id=$1",[file_id()]),
        {ok,R}=submit(C,B),[Image]=maps:get(evidence,R),
        sql(C,"DELETE FROM uploads"),ok=file:delete(Path),
        ?assertMatch({ok,#{data:=_}},call(C,{report_evidence,reporter,1,maps:get(id,R),maps:get(id,Image)})),
        {ok,#{data:=Bytes,content_type:=Type}}=call(C,{report_evidence,admin,3,maps:get(id,R),maps:get(id,Image)}),
        ?assertEqual(png(),Bytes),?assertEqual(<<"image/png">>,Type),
        ?assertEqual({error,not_found},call(C,{report_evidence,reporter,2,maps:get(id,R),maps:get(id,Image)})),
        ?assertEqual({error,forbidden},call(C,{report_evidence,admin,5,maps:get(id,R),maps:get(id,Image)})),
        ?assertEqual({error,not_found},call(C,{report_evidence,admin,3,999,maps:get(id,Image)}))
    after file:delete(Path) end.
evidence_quota_rollback(C) ->
    seed(C),Path=add_upload(C,1,png(),<<"image/png">>),
    try
        sql(C,"UPDATE moderation_evidence_budget SET bytes=536870912"),
        ?assertEqual({error,report_evidence_storage_full},submit(C,(body())#{<<"evidence_ids">>=>[file_id()]})),
        ?assertEqual([[0]],rows(C,"SELECT count(*) FROM moderation_reports")),
        ?assertEqual([[536870912]],rows(C,"SELECT bytes FROM moderation_evidence_budget")),
        sql(C,"UPDATE moderation_evidence_budget SET bytes=0"),
        ?assertMatch({ok,_},submit(C,(body())#{<<"evidence_ids">>=>[file_id()]}))
    after file:delete(Path) end.
optional_scoped_message(C) ->
    seed(C),{ok,R}=submit(C,(body())#{<<"message_id">>=>10}),D=detail(C,R),
    ?assertNot(maps:is_key(<<"body">>,maps:get(message_context,D))),
    {ok,R2}=submit(C,(new_body(2))#{<<"message_id">>=>10,<<"include_message">>=>true}),
    ?assertEqual(<<"submitted message">>,maps:get(<<"body">>,maps:get(message_context,detail(C,R2)))),
    lists:foreach(fun(Mid)->?assertEqual({error,invalid_report_message},submit(C,(new_body(Mid))#{<<"message_id">>=>Mid,<<"include_message">>=>true})) end,[11,13,14]),
    ?assertEqual({error,forbidden},submit(C,(new_body(12))#{<<"message_id">>=>12,<<"include_message">>=>true})),
    sql(C,"INSERT INTO friendships VALUES(1,2,'blocked')"),
    ?assertEqual({error,forbidden},submit(C,(new_body(20))#{<<"message_id">>=>10})).
reviewer_privacy(C) ->
    seed(C),R=create(C),Id=maps:get(id,R),
    ?assertEqual({error,forbidden},call(C,{admin_reports,5,#{}})),
    ?assertEqual({error,forbidden},call(C,{admin_report,1,Id})),
    ?assertEqual({error,forbidden},call(C,{admin_report,2,Id})),
    ?assertMatch({ok,#{items:=[_] }},call(C,{admin_reports,3,#{}})),
    {ok,Own}=call(C,{create_report,4,(body())#{<<"user_id">>=>2}}),
    ?assertMatch({ok,#{own_submission:=true}},call(C,{admin_report,4,maps:get(id,Own)})),
    {ok,#{items:=Items}}=call(C,{admin_reports,4,#{}}),?assertEqual([maps:get(id,Own),Id],[maps:get(id,I)||I<-Items]),
    sql(C,"UPDATE admin_operators SET role='viewer' WHERE user_id=4"),
    ?assertEqual({error,forbidden},call(C,{admin_report,4,Id})),
    _=detail(C,R),
    ?assertEqual([[<<>>]],rows(C,"SELECT detail FROM admin_audit WHERE action='report.view' LIMIT 1")).
own_submission_visibility(C) ->
    seed(C),Path=add_upload(C,1,png(),<<"image/png">>),
    sql(C,"INSERT INTO admin_operators VALUES(1,'owner')"),
    try
        {ok,R}=submit(C,(body())#{<<"evidence_ids">>=>[file_id()],<<"message_id">>=>10,<<"include_message">>=>true}),
        Id=maps:get(id,R),[Image]=maps:get(evidence,R),EId=maps:get(id,Image),
        {ok,#{items:=[First],counts:=Counts}}=call(C,{admin_reports,1,#{}}),
        ?assertEqual(true,maps:get(own_submission,First)),?assertEqual(1,maps:get(reporter_id,First)),
        ?assertEqual(2,maps:get(subject_id,First)),?assertEqual(1,maps:get(<<"open">>,Counts)),
        ?assertNot(maps:is_key(reason,First)),
        {ok,_}=update(C,4,R,#{<<"action">>=><<"claim">>}),
        {ok,_}=update(C,4,detail(C,R),#{<<"action">>=><<"priority">>,<<"priority">>=><<"urgent">>}),
        {ok,_}=update(C,4,detail(C,R),#{<<"action">>=><<"note">>,<<"note">>=><<"private reviewer assessment">>}),
        {ok,Own}=call(C,{admin_report,1,Id}),
        ?assertEqual(<<"report reason">>,maps:get(reason,Own)),?assertEqual([Image],maps:get(evidence,Own)),
        {ok,#{items:=[Summary]}}=call(C,{admin_reports,1,#{}}),
        lists:foreach(fun(Key)->?assertNot(maps:is_key(Key,Own)),?assertNot(maps:is_key(Key,Summary)) end,
            [history,assignee_id,priority,resolution,message_context,request_key,request_hash]),
        %% Private review metadata cannot be inferred through queue filters.
        lists:foreach(fun(Filter)->?assertMatch({ok,#{items:=[]}},call(C,{admin_reports,1,Filter})) end,
            [#{<<"priority">>=><<"urgent">>},#{<<"priority">>=><<"normal">>},#{<<"assigned">>=><<"mine">>},#{<<"assigned">>=><<"unassigned">>}]),
        ?assertMatch({ok,#{data:=_}},call(C,{report_evidence,admin,1,Id,EId})),
        D=detail(C,R),
        lists:foreach(fun(Action)->?assertEqual({error,forbidden},update(C,1,D,
            #{<<"action">>=>Action,<<"note">>=><<"cannot review own case">>,<<"priority">>=><<"low">>,<<"resolution">>=><<"no_violation">>})) end,
            [<<"claim">>,<<"unassign">>,<<"note">>,<<"priority">>,<<"resolve">>,<<"dismiss">>,<<"reopen">>]),
        sql(C,"INSERT INTO sessions VALUES('subject-session',2)"),
        Patch=#{<<"reason">>=><<"cannot action own case">>,<<"report_id">>=>Id,<<"report_revision">>=>maps:get(revision,D)},
        ?assertEqual({error,forbidden},call(C,{admin_apply_user_moderation,1,2,<<"ban">>,Patch})),
        ?assertEqual([[<<"active">>]],rows(C,"SELECT account_state FROM users WHERE id=2")),
        ?assertEqual([[1]],rows(C,"SELECT count(*) FROM sessions WHERE user_id=2")),
        ?assertEqual([[0]],rows(C,"SELECT count(*) FROM instance_account_actions")),
        ?assertEqual(maps:get(revision,D),maps:get(revision,detail(C,R))),
        ?assert(lists:any(fun(H)->maps:get(note,H)=:= <<"private reviewer assessment">> end,maps:get(history,D))),
        {ok,_}=update(C,4,D,#{<<"action">>=><<"dismiss">>,<<"resolution">>=><<"no_violation">>,<<"note">>=><<"private decision">>,<<"public_response">>=><<"Reviewed your report.">>}),
        {ok,Closed}=call(C,{admin_report,1,Id}),?assertEqual(<<"Reviewed your report.">>,maps:get(public_response,Closed)),
        ?assertMatch({ok,#{items:=[]}},call(C,{admin_reports,1,#{}})),
        ?assertMatch({ok,#{items:=[#{own_submission:=true}]}},call(C,{admin_reports,1,#{<<"status">>=><<"all">>}})),
        sql(C,"UPDATE admin_operators SET role='operator' WHERE user_id=1"),
        ?assertMatch({ok,#{own_submission:=true}},call(C,{admin_report,1,Id})),
        {ok,About}=call(C,{create_report,4,(new_body(2))#{<<"user_id">>=>1}}),
        AboutId=maps:get(id,About),
        ?assertMatch({ok,#{items:=[#{id:=Id}]}},call(C,{admin_reports,1,#{<<"status">>=><<"all">>}})),
        ?assertEqual({error,forbidden},call(C,{admin_report,1,AboutId})),
        ?assertEqual({error,forbidden},call(C,{report_evidence,admin,1,AboutId,EId})),
        sql(C,"UPDATE admin_operators SET role='viewer' WHERE user_id=1"),
        ?assertEqual({error,forbidden},call(C,{admin_reports,1,#{}})),
        ?assertEqual({error,forbidden},call(C,{admin_report,1,Id})),
        ?assertEqual({error,forbidden},call(C,{report_evidence,admin,1,Id,EId}))
    after sql(C,"DELETE FROM admin_operators WHERE user_id=1"),file:delete(Path) end.
assignment_revisions_and_notes(C) ->
    seed(C),R=create(C),{ok,_}=update(C,4,R,#{<<"action">>=><<"claim">>}),
    D=detail(C,R),?assertEqual(4,maps:get(assignee_id,D)),
    ?assertEqual({error,report_conflict},update(C,4,R,#{<<"action">>=><<"note">>,<<"note">>=><<"stale">>})),
    ?assertEqual({error,report_assigned_elsewhere},update(C,6,D,#{<<"action">>=><<"claim">>})),
    ?assertEqual({error,report_note_required},update(C,4,D,#{<<"action">>=><<"note">>})),
    ?assertMatch({ok,_},update(C,4,D,#{<<"action">>=><<"note">>,<<"note">>=><<"private review note">>})),
    {ok,#{items:=[Public]}}=call(C,{my_reports,1,#{}}),
    ?assertNot(maps:is_key(history,Public)),?assertNot(maps:is_key(assignee_id,Public)),
    ?assertEqual(2,length([H||H<-maps:get(history,detail(C,R)),maps:get(action,H)=/= <<"submitted">>])).
withdrawal_and_decisions(C) ->
    seed(C),R=create(C),Id=maps:get(id,R),
    ?assertEqual({error,not_found},call(C,{withdraw_report,2,Id,#{<<"expected_revision">>=>1}})),
    ?assertMatch({ok,#{status:=<<"withdrawn">>}},call(C,{withdraw_report,1,Id,#{<<"expected_revision">>=>1}})),
    ?assertEqual({error,report_closed},update(C,3,detail(C,R),#{<<"action">>=><<"reopen">>,<<"note">>=><<"cannot reopen withdrawn">>})),
    {ok,R2}=submit(C,new_body(2)),
    ?assertMatch({ok,_},update(C,3,R2,#{<<"action">>=><<"dismiss">>,<<"resolution">>=><<"insufficient_evidence">>,<<"note">>=><<"reviewed">>,<<"public_response">>=><<"Please provide additional context.">>})),
    {ok,#{items:=[Public|_]}}=call(C,{my_reports,1,#{}}),?assertEqual(<<"Please provide additional context.">>,maps:get(public_response,Public)),
    ?assertMatch({ok,_},update(C,3,detail(C,R2),#{<<"action">>=><<"reopen">>,<<"note">>=><<"new evidence">>})).
linked_action_is_atomic(C) ->
    seed(C),R=create(C),{ok,_}=update(C,4,R,#{<<"action">>=><<"claim">>}),D=detail(C,R),
    sql(C,"INSERT INTO sessions VALUES('subject-session',2)"),sql(C,"INSERT INTO admin_sessions VALUES('subject-admin-session',2)"),
    Patch=#{<<"reason">>=><<"policy violation">>,<<"report_id">>=>maps:get(id,R),<<"report_revision">>=>maps:get(revision,D)},
    ?assertEqual({error,invalid_report_action},call(C,{admin_apply_user_moderation,4,1,<<"ban">>,Patch})),
    ?assertEqual({error,invalid_report_action},call(C,{admin_apply_user_moderation,4,2,<<"restore">>,Patch})),
    ?assertEqual({error,invalid_report_action},call(C,{admin_apply_user_moderation,4,2,<<"revoke_sessions">>,Patch})),
    sql(C,"ALTER TABLE moderation_reports ADD CONSTRAINT reject_case_resolution CHECK(status<>'resolved')"),
    try ?assertException(error,_,call(C,{admin_apply_user_moderation,4,2,<<"ban">>,Patch}))
    after sql(C,"ALTER TABLE moderation_reports DROP CONSTRAINT reject_case_resolution") end,
    ?assertEqual([[<<"active">>]],rows(C,"SELECT account_state FROM users WHERE id=2")),
    ?assertEqual([[1]],rows(C,"SELECT count(*) FROM sessions WHERE user_id=2")),
    ?assertEqual([[0]],rows(C,"SELECT count(*) FROM instance_account_actions")),
    ?assertMatch({ok,#{account_state:=<<"banned">>}},call(C,{admin_apply_user_moderation,4,2,<<"ban">>,Patch})),
    ?assertEqual([[0]],rows(C,"SELECT count(*) FROM sessions WHERE user_id=2")),
    ?assertEqual([[0]],rows(C,"SELECT count(*) FROM admin_sessions WHERE user_id=2")),
    ?assertEqual(<<"action_taken">>,maps:get(resolution,detail(C,R))),
    ?assertEqual({error,report_conflict},call(C,{admin_apply_user_moderation,4,2,<<"ban">>,Patch})).
retention_preserves_case_history(C) ->
    seed(C),Path=add_upload(C,1,png(),<<"image/png">>),
    try
        {ok,R}=submit(C,(body())#{<<"evidence_ids">>=>[file_id()],<<"message_id">>=>10,<<"include_message">>=>true}),
        ?assertMatch({ok,_},call(C,reports_gc)),?assertMatch([[_]],rows(C,"SELECT id FROM moderation_report_evidence")),
        ?assertMatch({ok,_},update(C,3,R,#{<<"action">>=><<"resolve">>,<<"note">>=><<"review complete">>,<<"resolution">>=><<"no_violation">>})),
        query(C,"UPDATE moderation_reports SET closed_at=$1",[pw_util:now_ms()-366*86400000]),
        ?assertEqual({ok,#{purged=>1}},call(C,reports_gc)),D=detail(C,R),
        ?assertEqual([],maps:get(evidence,D)),?assertEqual(#{},maps:get(message_context,D)),
        ?assertEqual(<<"report reason">>,maps:get(reason,D)),?assertEqual(2,length(maps:get(history,D))),
        ?assertEqual([[0]],rows(C,"SELECT bytes FROM moderation_evidence_budget")),
        ?assertEqual({ok,#{purged=>0}},call(C,reports_gc))
    after file:delete(Path) end.
encrypted_evidence(C) ->
    seed(C),Path=add_upload(C,1,png(),<<"image/png">>),OldKey=os:getenv("PLAINWIRE_ENC_KEY"),
    os:putenv("PLAINWIRE_ENC_KEY",binary_to_list(base64:encode(crypto:strong_rand_bytes(32)))),
    try
        {ok,R}=submit(C,(body())#{<<"evidence_ids">>=>[file_id()],<<"message_id">>=>10,<<"include_message">>=>true}),
        [[StoredReason,StoredContext]]=rows(C,"SELECT reason,message_context::text FROM moderation_reports"),
        ?assertMatch(<<"e1:",_/binary>>,StoredReason),?assertEqual(nomatch,binary:match(StoredContext,<<"submitted message">>)),
        [[StoredBytes]]=rows(C,"SELECT data FROM moderation_report_evidence"),?assertNotEqual(png(),StoredBytes),
        ?assertEqual(<<"report reason">>,maps:get(reason,detail(C,R))),
        [Image]=maps:get(evidence,R),{ok,#{data:=Bytes}}=call(C,{report_evidence,admin,3,maps:get(id,R),maps:get(id,Image)}),?assertEqual(png(),Bytes)
    after case OldKey of false->os:unsetenv("PLAINWIRE_ENC_KEY");_->os:putenv("PLAINWIRE_ENC_KEY",OldKey) end,file:delete(Path) end.

sql(C,S) -> case epgsql:squery(C,S) of {ok,_}->ok;{ok,_,_}->ok;Other->erlang:error({fixture_sql,Other}) end.
query(C,S,P) -> case epgsql:equery(C,S,P) of {ok,_}->ok;{ok,_,_}->ok;{ok,_,_,_}->ok;Other->erlang:error({fixture_sql,Other}) end.
rows(C,S) -> {ok,_,Rs}=epgsql:equery(C,S,[]),[tuple_to_list(R)||R<-Rs].
