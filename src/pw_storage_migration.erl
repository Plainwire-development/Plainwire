-module(pw_storage_migration).
-export([backfill/0, backfill/1, verify/0, verify/2, verify_json/0, verify_json/2,
         parity/0, parity/1, parity_json/0, parity_json/1,
         shadow_sample/0, shadow_sample/1, shadow_json/0, shadow_json/1,
         reconcile/0, reconcile/1, reconcile_json/0, reconcile_json/1,
         reconcile_write_intents/0, reconcile_write_intents/1]).

backfill() -> backfill(#{}).
backfill(Opts) when is_map(Opts) ->
    case ensure_ready() of
        ok ->
            Batch = clamp(maps:get(batch_size, Opts, pw_util:env_int("PLAINWIRE_SCYLLA_BACKFILL_BATCH", 250)), 1, 1000),
            Concurrency = clamp(maps:get(concurrency, Opts, pw_util:env_int("PLAINWIRE_SCYLLA_BACKFILL_CONCURRENCY", 8)), 1, 64),
            MaxRows = clamp(maps:get(max_rows, Opts, pw_util:env_int("PLAINWIRE_SCYLLA_BACKFILL_MAX_ROWS", 0)), 0, 1000000000),
            case pw_db:storage_migration_checkpoint() of
                {ok, #{last_id := Last, rows_done := Done}} ->
                    backfill_loop(Last, Done, Batch, Concurrency, MaxRows, 0, pw_util:now_ms());
                Error -> Error
            end;
        Error -> Error
    end.

backfill_loop(Last, Done, Batch, Concurrency, MaxRows, ThisRun, Started) ->
    case MaxRows > 0 andalso ThisRun >= MaxRows of
        true -> result(backfill_paused, Last, Done, ThisRun, Started, []);
        false ->
            Want = case MaxRows of 0 -> Batch; _ -> erlang:min(Batch, MaxRows - ThisRun) end,
            case pw_db:storage_migration_page(Last, Want) of
                {ok, []} -> result(backfill_complete, Last, Done, ThisRun, Started, []);
                {ok, Rows} ->
                    case parallel_upsert(Rows, Concurrency) of
                        ok ->
                            NewLast = maps:get(id, lists:last(Rows)),
                            Count = length(Rows),
                            NewDone = Done + Count,
                            case pw_db:storage_migration_set_checkpoint(NewLast, NewDone) of
                                {ok, _} ->
                                    pw_storage_metrics:add(migration_rows, Count),
                                    pw_storage_metrics:set_gauge(migration_last_id, NewLast),
                                    backfill_loop(NewLast, NewDone, Batch, Concurrency, MaxRows, ThisRun + Count, Started);
                                Error -> Error
                            end;
                        {error, Failures} ->
                            result(backfill_failed, Last, Done, ThisRun, Started, Failures)
                    end;
                Error -> Error
            end
    end.

verify() ->
    After = max(0, pw_util:env_int("PLAINWIRE_SCYLLA_VERIFY_AFTER_ID", 0)),
    Limit = clamp(pw_util:env_int("PLAINWIRE_SCYLLA_VERIFY_LIMIT", 1000), 1, 5000),
    verify(After, Limit).

verify(After, Limit0) ->
    Limit = clamp(Limit0, 1, 5000),
    case ensure_ready() of
        ok ->
            case pw_db:storage_migration_page(After, Limit) of
                {ok, PgRows} -> verify_rows(PgRows, [], 0, pw_util:now_ms());
                Error -> Error
            end;
        Error -> Error
    end.

verify_json() -> verify_json_result(verify()).
verify_json(After, Limit) -> verify_json_result(verify(After, Limit)).
verify_json_result({ok, Report}) -> jsx:encode(Report);
verify_json_result({error, Reason}) -> jsx:encode(#{ok => false, error => printable(Reason)}).

parity() -> parity(clamp(pw_util:env_int("PLAINWIRE_SCYLLA_PARITY_SAMPLE_ROWS", 500), 50, 5000)).
parity(SampleRows0) ->
    SampleRows = clamp(SampleRows0, 50, 5000),
    case ensure_ready() of
        ok ->
            case pw_db:storage_reconcile_page(SampleRows) of
                {ok, Rows} ->
                    Scopes = lists:usort([{maps:get(scope, M), maps:get(scope_id, M)} || M <- Rows]),
                    Started = pw_util:now_ms(),
                    Results = [parity_scope(Scope, ScopeId) || {Scope, ScopeId} <- Scopes],
                    Failures = [R || R <- Results, maps:get(ok, R, false) =:= false],
                    Report = #{ok => Failures =:= [], sampled_rows => length(Rows), scopes_checked => length(Scopes),
                               failure_count => length(Failures), failures => Failures,
                               duration_ms => pw_util:now_ms() - Started},
                    pw_storage_metrics:set_gauge(parity_scopes_checked, length(Scopes)),
                    pw_storage_metrics:set_gauge(parity_failures, length(Failures)),
                    {ok, Report};
                Error -> Error
            end;
        Error -> Error
    end.

parity_json() -> parity_json_result(parity()).
parity_json(SampleRows) -> parity_json_result(parity(SampleRows)).
parity_json_result({ok, Report}) -> jsx:encode(Report);
parity_json_result({error, Reason}) -> jsx:encode(#{ok => false, error => printable(Reason)}).

parity_scope(Scope, ScopeId) ->
    case compare_store_call(fun() -> pw_message_store_pg:get_recent(Scope, ScopeId, 80) end,
                            fun() -> pw_message_store_scylla:get_recent(Scope, ScopeId, 80) end) of
        {ok, Recent} ->
            Checks0 = [{recent, ok}],
            Checks1 = case Recent of
                [] -> Checks0;
                _ ->
                    Oldest = maps:get(id, lists:last(Recent)),
                    Mid = maps:get(id, lists:nth(erlang:max(1, (length(Recent) + 1) div 2), Recent)),
                    Ids = lists:sublist([maps:get(id, M) || M <- Recent], 25),
                    [{before, parity_check(compare_store_call(fun() -> pw_message_store_pg:get_before(Scope, ScopeId, Oldest, 80) end,
                                                               fun() -> pw_message_store_scylla:get_before(Scope, ScopeId, Oldest, 80) end))},
                     {'after', parity_check(compare_store_call(fun() -> pw_message_store_pg:get_after(Scope, ScopeId, Mid, 80) end,
                                                              fun() -> pw_message_store_scylla:get_after(Scope, ScopeId, Mid, 80) end))},
                     {around, parity_check(compare_store_call(fun() -> pw_message_store_pg:get_around(Scope, ScopeId, Mid, 10, 10) end,
                                                               fun() -> pw_message_store_scylla:get_around(Scope, ScopeId, Mid, 10, 10) end))},
                     {bulk_get, compare_bulk(Ids)} | Checks0]
            end,
            Failures = [#{check => atom_to_binary(Name, utf8), detail => printable(Result)}
                        || {Name, Result} <- Checks1, Result =/= ok],
            #{ok => Failures =:= [], scope => Scope, scope_id => ScopeId, failures => Failures};
        Error ->
            #{ok => false, scope => Scope, scope_id => ScopeId,
              failures => [#{check => <<"recent">>, detail => printable(Error)}]}
    end.

compare_store_call(PgFun, ScyllaFun) ->
    case {PgFun(), ScyllaFun()} of
        {{ok, PgRows}, {ok, ScyllaRows}} ->
            PgComparable = [comparable(M) || M <- PgRows],
            ScyllaComparable = [comparable(M) || M <- ScyllaRows],
            case PgComparable =:= ScyllaComparable of
                true -> {ok, PgRows};
                false -> {error, #{pg_ids => [maps:get(id, M) || M <- PgRows],
                                   scylla_ids => [maps:get(id, M) || M <- ScyllaRows]}}
            end;
        {Pg, Scylla} -> {error, #{postgres => printable(Pg), scylla => printable(Scylla)}}
    end.

parity_check({ok, _Rows}) -> ok;
parity_check(Error) -> Error.

compare_bulk(Ids) ->
    case {pw_message_store_pg:bulk_get(Ids), pw_message_store_scylla:bulk_get(Ids)} of
        {{ok, Pg}, {ok, Scylla}} ->
            PgC = maps:map(fun(_K, V) -> comparable(V) end, Pg),
            ScC = maps:map(fun(_K, V) -> comparable(V) end, Scylla),
            case PgC =:= ScC of true -> ok; false -> {error, bulk_mismatch} end;
        {PgResult, ScResult} -> {error, #{postgres => printable(PgResult), scylla => printable(ScResult)}}
    end.

shadow_sample() -> shadow_sample(clamp(pw_util:env_int("PLAINWIRE_SCYLLA_SHADOW_SAMPLE_ROWS", 200), 1, 2000)).
shadow_sample(Limit0) ->
    Limit = clamp(Limit0, 1, 2000),
    case ensure_ready() of
        ok ->
            case pw_db:storage_reconcile_page(Limit) of
                {ok, PgRows} ->
                    Started = pw_util:now_ms(),
                    {Mismatches, Checked} = shadow_rows(PgRows, [], 0),
                    Count = length(Mismatches),
                    pw_storage_metrics:set_gauge(shadow_checked, Checked),
                    pw_storage_metrics:set_gauge(shadow_mismatches, Count),
                    case Count of 0 -> pw_storage_metrics:incr(shadow_pass); _ -> pw_storage_metrics:incr(shadow_fail) end,
                    {ok, #{ok => Count =:= 0, checked => Checked, mismatch_count => Count,
                           mismatches => lists:reverse(Mismatches), duration_ms => pw_util:now_ms() - Started}};
                Error -> Error
            end;
        Error -> Error
    end.

shadow_json() -> shadow_json_result(shadow_sample()).
shadow_json(Limit) -> shadow_json_result(shadow_sample(Limit)).
shadow_json_result({ok, Report}) -> jsx:encode(Report);
shadow_json_result({error, Reason}) -> jsx:encode(#{ok => false, error => printable(Reason)}).

shadow_rows([], Mismatches, Checked) -> {Mismatches, Checked};
shadow_rows([Pg | Rest], Mismatches0, Checked) ->
    Id = maps:get(id, Pg),
    Mismatches1 = case pw_message_store_scylla:get(Id) of
        {ok, Scylla} ->
            case comparable(Pg) =:= comparable(Scylla) of
                true -> Mismatches0;
                false -> [mismatch(Id, Pg, Scylla) | Mismatches0]
            end;
        {error, not_found} -> [#{id => Id, reason => <<"missing_in_scylla">>} | Mismatches0];
        Error -> [#{id => Id, reason => printable(Error)} | Mismatches0]
    end,
    shadow_rows(Rest, Mismatches1, Checked + 1).

reconcile_write_intents() ->
    reconcile_write_intents(clamp(pw_util:env_int("PLAINWIRE_SCYLLA_WRITE_INTENT_RECONCILE_ROWS", 500), 1, 5000)).
reconcile_write_intents(Limit0) ->
    Limit = clamp(Limit0, 1, 5000),
    case ensure_ready() of
        ok ->
            case pw_message_store_scylla:pending_write_intents(Limit) of
                {ok, Intents} ->
                    Grace = clamp(pw_util:env_int("PLAINWIRE_SCYLLA_WRITE_INTENT_GRACE_MS", 300000), 60000, 86400000),
                    Cutoff = pw_util:now_ms() - Grace,
                    Mature = [I || I <- Intents, maps:get(marked_at, I, 0) =< Cutoff],
                    reconcile_intent_rows(Mature, length(Intents), 0, 0, []);
                Error -> Error
            end;
        Error -> Error
    end.

reconcile_intent_rows([], Seen, Checked, Repaired, Errors) ->
    pw_storage_metrics:set_gauge(write_intents_seen, Seen),
    pw_storage_metrics:set_gauge(write_intents_reconciled, Repaired),
    pw_storage_metrics:set_gauge(write_intent_errors, length(Errors)),
    {ok, #{seen => Seen, mature_checked => Checked, reconciled => Repaired,
           errors => lists:reverse(Errors)}};
reconcile_intent_rows([Intent | Rest], Seen, Checked, Repaired, Errors0) ->
    Id = maps:get(id, Intent),
    Token = maps:with([id, bucket], Intent),
    case pw_message_store_pg:get(Id) of
        {ok, Pg} ->
            %% PostgreSQL committed. Re-apply its exact core state before clearing
            %% the intent, covering both an interrupted create and an interrupted
            %% edit/delete. Scylla upsert is idempotent by message id.
            case pw_message_store_scylla:insert(Pg) of
                ok ->
                    case pw_message_store_scylla:complete_transactional_upsert(Token) of
                        ok -> reconcile_intent_rows(Rest, Seen, Checked+1, Repaired+1, Errors0);
                        Error -> reconcile_intent_rows(Rest, Seen, Checked+1, Repaired, [{Id, printable(Error)}|Errors0])
                    end;
                Error -> reconcile_intent_rows(Rest, Seen, Checked+1, Repaired, [{Id, printable(Error)}|Errors0])
            end;
        {error, not_found} ->
            %% The PostgreSQL transaction never committed. The grace period keeps
            %% a slow but live transaction from being mistaken for a crash. Delete
            %% by the journaled partition as well as the locator, because an
            %% interrupted first insert may have lost/compensated its locator.
            Scope = maps:get(scope, Intent),
            ScopeId = maps:get(scope_id, Intent),
            MessageBucket = maps:get(message_bucket, Intent),
            case pw_message_store_scylla:hard_delete_at(Scope, ScopeId, MessageBucket, Id) of
                ok ->
                    case pw_message_store_scylla:complete_transactional_upsert(Token) of
                        ok ->
                            pw_storage_metrics:incr(write_intent_orphan_removed),
                            reconcile_intent_rows(Rest, Seen, Checked+1, Repaired+1, Errors0);
                        Error -> reconcile_intent_rows(Rest, Seen, Checked+1, Repaired, [{Id, printable(Error)}|Errors0])
                    end;
                Error -> reconcile_intent_rows(Rest, Seen, Checked+1, Repaired, [{Id, printable(Error)}|Errors0])
            end;
        Error -> reconcile_intent_rows(Rest, Seen, Checked+1, Repaired, [{Id, printable(Error)}|Errors0])
    end.

reconcile() -> reconcile(clamp(pw_util:env_int("PLAINWIRE_SCYLLA_RECONCILE_ROWS", 500), 1, 5000)).
reconcile(Limit) ->
    case ensure_ready() of
        ok ->
            case pw_db:storage_reconcile_page(Limit) of
                {ok, Rows} -> reconcile_rows(Rows, 0, 0, []);
                Error -> Error
            end;
        Error -> Error
    end.

reconcile_json() -> reconcile_json_result(reconcile()).
reconcile_json(Limit) -> reconcile_json_result(reconcile(Limit)).
reconcile_json_result({ok, Report=#{errors := Errors}}) ->
    jsx:encode(Report#{ok => Errors =:= []});
reconcile_json_result({ok, Report}) -> jsx:encode(Report#{ok => true});
reconcile_json_result({error, Reason}) -> jsx:encode(#{ok => false, error => printable(Reason)}).

reconcile_rows([], Checked, Repaired, Errors) ->
    pw_storage_metrics:set_gauge(reconcile_discrepancies, Repaired + length(Errors)),
    {ok, #{checked => Checked, repaired => Repaired, errors => lists:reverse(Errors)}};
reconcile_rows([Pg|Rest], Checked, Repaired, Errors) ->
    Id = maps:get(id, Pg),
    case pw_message_store_scylla:get(Id) of
        {ok, Scylla} ->
            case comparable(Pg) =:= comparable(Scylla) of
                true -> reconcile_rows(Rest, Checked+1, Repaired, Errors);
                false ->
                    case pw_message_store_scylla:insert(Pg) of
                        ok -> reconcile_rows(Rest, Checked+1, Repaired+1, Errors);
                        Error -> reconcile_rows(Rest, Checked+1, Repaired, [{Id, printable(Error)}|Errors])
                    end
            end;
        {error, not_found} ->
            case pw_message_store_scylla:insert(Pg) of
                ok -> reconcile_rows(Rest, Checked+1, Repaired+1, Errors);
                Error -> reconcile_rows(Rest, Checked+1, Repaired, [{Id, printable(Error)}|Errors])
            end;
        Error -> reconcile_rows(Rest, Checked+1, Repaired, [{Id, printable(Error)}|Errors])
    end.

verify_rows([], Mismatches, Checked, Started) ->
    Report = #{ok => (Mismatches =:= []), checked => Checked, mismatch_count => length(Mismatches),
               mismatches => lists:reverse(Mismatches), duration_ms => pw_util:now_ms() - Started},
    pw_storage_metrics:set_gauge(migration_verify_mismatches, length(Mismatches)),
    {ok, Report};
verify_rows([Pg|Rest], Mismatches, Checked, Started) ->
    Id = maps:get(id, Pg),
    M1 = case pw_message_store_scylla:get(Id) of
        {ok, Scylla} ->
            case comparable(Pg) =:= comparable(Scylla) of
                true -> Mismatches;
                false -> [mismatch(Id, Pg, Scylla) | Mismatches]
            end;
        {error, not_found} -> [#{id => Id, reason => <<"missing_in_scylla">>} | Mismatches];
        Error -> [#{id => Id, reason => printable(Error)} | Mismatches]
    end,
    verify_rows(Rest, M1, Checked+1, Started).

mismatch(Id, A, B) ->
    CA = comparable(A), CB = comparable(B),
    Fields = [K || K <- maps:keys(CA), maps:get(K, CA, undefined) =/= maps:get(K, CB, undefined)],
    #{id => Id, reason => <<"content_mismatch">>, fields => [atom_to_binary(K, utf8) || K <- Fields],
      pg_hash => hash(CA), scylla_hash => hash(CB)}.

comparable(M) ->
    maps:with([id, scope, scope_id, user_id, body, reply_to_id, created_at, edited_at, deleted_at, kind, forwarded_from_id], normalize(M)).

normalize(M) -> maps:map(fun(_K, undefined) -> undefined; (_K, null) -> undefined; (_K, 0) -> 0; (_K, V) -> V end, M).
hash(M) -> pw_util:sha256_hex(term_to_binary(M)).

parallel_upsert([], _Concurrency) -> ok;
parallel_upsert(Rows, Concurrency) -> parallel_chunks(Rows, Concurrency, []).
parallel_chunks([], _Concurrency, []) -> ok;
parallel_chunks([], _Concurrency, Errors) -> {error, lists:reverse(Errors)};
parallel_chunks(Rows, Concurrency, Errors0) ->
    {Chunk, Rest} = lists:split(erlang:min(length(Rows), Concurrency), Rows),
    Parent = self(),
    Pending = [begin
                   Token = make_ref(),
                   Id = maps:get(id, M),
                   {Pid, Mon} = spawn_monitor(fun() ->
                       Result = try pw_message_store_scylla:insert(M)
                                catch C:R -> {error, {worker_exception, C, printable(R)}} end,
                       Parent ! {backfill_result, Token, Id, Result}
                   end),
                   {Token, Mon, Pid, Id}
               end || M <- Chunk],
    OpTimeout = maps:get(operation_timeout_ms, pw_scylla_config:config(), 8000),
    %% Each worker performs one bounded Scylla operation. Respect the configured
    %% operation budget and add a small scheduler/DB margin instead of imposing
    %% an unrelated hard-coded timeout that can kill a valid slow migration.
    Deadline = erlang:monotonic_time(millisecond) + OpTimeout + 5000,
    Errors1 = collect_chunk(Pending, Errors0, Deadline),
    case Errors1 =:= Errors0 of
        true -> parallel_chunks(Rest, Concurrency, Errors1);
        false -> {error, lists:reverse(Errors1)}
    end.

collect_chunk([], Errors, _Deadline) -> Errors;
collect_chunk(Pending, Errors, Deadline) ->
    Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {backfill_result, Token, Id, Result} ->
            case take_pending_token(Token, Pending) of
                {ok, {_Token, Mon, _Pid, _ExpectedId}, Rest} ->
                    erlang:demonitor(Mon, [flush]),
                    Errors1 = case Result of
                        ok -> Errors;
                        Error -> [{Id, printable(Error)} | Errors]
                    end,
                    collect_chunk(Rest, Errors1, Deadline);
                error -> collect_chunk(Pending, Errors, Deadline)
            end;
        {'DOWN', Mon, process, _Pid, Reason} ->
            case take_pending_monitor(Mon, Pending) of
                {ok, {_Token, _Mon, _WorkerPid, Id}, Rest} ->
                    Error = case Reason of
                        normal -> <<"worker_exited_before_result">>;
                        _ -> printable({worker_crash, Reason})
                    end,
                    collect_chunk(Rest, [{Id, Error} | Errors], Deadline);
                error -> collect_chunk(Pending, Errors, Deadline)
            end
    after Remaining ->
        [begin catch exit(Pid, kill), erlang:demonitor(Mon, [flush]) end || {_T,Mon,Pid,_Id} <- Pending],
        [{Id, <<"backfill_worker_timeout">>} || {_T,_M,_P,Id} <- Pending] ++ Errors
    end.

take_pending_token(Token, Pending) ->
    take_pending(fun({T,_,_,_}) -> T =:= Token end, Pending, []).
take_pending_monitor(Mon, Pending) ->
    take_pending(fun({_,M,_,_}) -> M =:= Mon end, Pending, []).

take_pending(_Pred, [], _Acc) -> error;
take_pending(Pred, [H|T], Acc) ->
    case Pred(H) of
        true -> {ok, H, lists:reverse(Acc) ++ T};
        false -> take_pending(Pred, T, [H|Acc])
    end.

ensure_ready() ->
    case pw_scylla_config:enabled() of
        false -> {error, scylla_disabled};
        true -> case pw_scylla:ready() of true -> ok; false -> {error, scylla_unavailable} end
    end.

result(Status, Last, Done, ThisRun, Started, Errors) ->
    {ok, #{status => Status, last_id => Last, rows_done => Done, rows_this_run => ThisRun,
           duration_ms => pw_util:now_ms() - Started, errors => Errors}}.

printable(T) when is_binary(T) -> T;
printable(T) when is_atom(T) -> atom_to_binary(T, utf8);
printable(T) -> iolist_to_binary(io_lib:format("~0p", [T])).
clamp(V, Min, Max) when is_integer(V) -> erlang:min(Max, erlang:max(Min, V));
clamp(_, Min, _Max) -> Min.
