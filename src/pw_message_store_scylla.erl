-module(pw_message_store_scylla).
-export([insert/1, transactional_upsert/1, complete_transactional_upsert/1, pending_write_intents/1,
         get/1, get_recent/3, get_before/4, get_after/4, get_around/5, bulk_get/1,
         edit/3, delete/2, hard_delete/1, hard_delete_scoped/4, hard_delete_at/4, append_lifecycle/4]).
-ifdef(TEST).
-export([test_message_visible/1]).
-endif.

-define(DEFAULT_LIMIT, 80).
-define(MAX_LIMIT, 250).

%% Scylla-authoritative writes cross a PostgreSQL transaction boundary. The
%% intent row is a tiny crash-recovery journal: if the BEAM/host dies after the
%% Scylla write but before PostgreSQL COMMIT, reconciliation can restore the
%% canonical row from PostgreSQL (or remove an orphan) and then clear the intent.
transactional_upsert(Msg0) when is_map(Msg0) ->
    case normalize_message(Msg0) of
        {ok, Msg} -> transactional_upsert_valid(Msg);
        Error -> Error
    end;
transactional_upsert(_) -> {error, invalid_message}.

transactional_upsert_valid(Msg) ->
    Id = maps:get(id, Msg),
    Scope = maps:get(scope, Msg),
    ScopeId = maps:get(scope_id, Msg),
    MarkedAt = pw_util:now_ms(),
    MessageBucket = pw_message_bucket:for_timestamp(maps:get(created_at, Msg)),
    IntentBucket = intent_bucket(MarkedAt),
    Token = #{id => Id, bucket => IntentBucket},
    case pw_scylla:execute({write_intent_directory, IntentBucket}, pw_write_intent_bucket_touch,
                           [<<"all">>, IntentBucket]) of
        ok ->
            case pw_scylla:execute({write_intent, IntentBucket}, pw_write_intent_insert,
                                   [IntentBucket, Id, Scope, ScopeId, MessageBucket, MarkedAt]) of
                ok ->
                    case insert_valid(Msg) of
                        ok -> {ok, Token};
                        Error ->
                            %% A timeout can mean the database applied the write even
                            %% though the client did not receive success. Keep the intent
                            %% on every failure so reconciliation can prove/undo the
                            %% cross-store state after PostgreSQL rolls back.
                            Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

complete_transactional_upsert(#{id := Id, bucket := Bucket})
  when is_integer(Id), Id > 0, is_integer(Bucket), Bucket >= 0 ->
    pw_scylla:execute({write_intent, Bucket}, pw_write_intent_delete, [Bucket, Id]);
complete_transactional_upsert(_) -> {error, invalid_write_intent}.

pending_write_intents(Limit0) ->
    Limit = erlang:min(5000, erlang:max(1, case Limit0 of N when is_integer(N) -> N; _ -> 500 end)),
    case pw_scylla:execute(write_intent_directory, pw_write_intent_buckets_recent,
                           [<<"all">>, intent_bucket_scan_limit()]) of
        {ok, _Cols, Rows} ->
            Buckets = [B || [B] <- Rows, is_integer(B), B >= 0],
            collect_intents(Buckets, Limit, []);
        Error -> Error
    end.

insert(Msg0) when is_map(Msg0) ->
    case normalize_message(Msg0) of
        {ok, Msg} -> insert_valid(Msg);
        Error -> Error
    end;
insert(_) -> {error, invalid_message}.

insert_valid(Msg) ->
    Id = maps:get(id, Msg),
    Scope = maps:get(scope, Msg),
    ScopeId = maps:get(scope_id, Msg),
    Created = maps:get(created_at, Msg),
    Bucket = pw_message_bucket:for_timestamp(Created),
    case locator(Id) of
        {ok, #{scope := Scope, scope_id := ScopeId, bucket := Bucket}} ->
            %% Idempotent retry/update: never rewrite or compensate an already
            %% established locator. If the body write fails, the prior row stays
            %% addressable and a later retry/reconciler can repair it.
            insert_existing(Msg, Scope, ScopeId, Bucket);
        {ok, _Other} ->
            {error, message_id_collision};
        {error, not_found} ->
            insert_new(Msg, Scope, ScopeId, Bucket);
        Error -> Error
    end.

insert_existing(Msg, Scope, ScopeId, Bucket) ->
    case pw_scylla:execute({bucket_index, Scope, ScopeId}, pw_msg_bucket_touch,
                           [Scope, ScopeId, Bucket]) of
        ok -> write_message_row(Msg, Scope, ScopeId, Bucket);
        Error -> Error
    end.

insert_new(Msg, Scope, ScopeId, Bucket) ->
    Id = maps:get(id, Msg),
    Created = maps:get(created_at, Msg),
    case pw_scylla:execute({bucket_index, Scope, ScopeId}, pw_msg_bucket_touch,
                           [Scope, ScopeId, Bucket]) of
        ok ->
            case pw_scylla:execute({locator, Id}, pw_msg_locator_insert,
                                   [Id, Scope, ScopeId, Bucket, Created]) of
                ok ->
                    case write_message_row(Msg, Scope, ScopeId, Bucket) of
                        ok -> ok;
                        Error ->
                            _ = cleanup_locator(Id),
                            Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

write_message_row(Msg, Scope, ScopeId, Bucket) ->
    Id = maps:get(id, Msg),
    Created = maps:get(created_at, Msg),
    Params = [Scope, ScopeId, Bucket, Id, maps:get(user_id, Msg), maps:get(body, Msg),
              nz(maps:get(reply_to_id, Msg, 0)), Created, nz(maps:get(edited_at, Msg, 0)),
              nz(maps:get(deleted_at, Msg, 0)), maps:get(kind, Msg, <<"text">>),
              nz(maps:get(forwarded_from_id, Msg, 0))],
    pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_insert, Params).

get(Id) when is_integer(Id), Id > 0 ->
    case locator(Id) of
        {ok, #{scope := Scope, scope_id := ScopeId, bucket := Bucket}} ->
            case pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_get, [Scope, ScopeId, Bucket, Id]) of
                {ok, _Cols, [Row]} -> decode_message_row(Scope, ScopeId, Bucket, Row);
                {ok, _Cols, []} -> {error, not_found};
                Error -> Error
            end;
        Error -> Error
    end;
get(_) -> {error, not_found}.

get_recent(Scope, ScopeId, Limit0) ->
    Limit = limit(Limit0, ?DEFAULT_LIMIT),
    case message_buckets(Scope, ScopeId, recent, undefined) of
        {ok, Buckets} -> collect_desc(Scope, ScopeId, Buckets, undefined, Limit, []);
        Error -> Error
    end.

get_before(Scope, ScopeId, BeforeId, Limit0) ->
    Limit = limit(Limit0, ?DEFAULT_LIMIT),
    case locator(BeforeId) of
        {ok, #{scope := Scope, scope_id := ScopeId, bucket := Bucket}} ->
            case message_buckets(Scope, ScopeId, before, Bucket) of
                {ok, Buckets} -> collect_desc(Scope, ScopeId, Buckets, BeforeId, Limit, []);
                Error -> Error
            end;
        {ok, _} -> {error, cursor_scope_mismatch};
        {error, not_found} -> {ok, []};
        Error -> Error
    end.

get_after(Scope, ScopeId, AfterId, Limit0) ->
    Limit = limit(Limit0, ?MAX_LIMIT),
    case locator(AfterId) of
        {ok, #{scope := Scope, scope_id := ScopeId, bucket := Bucket}} ->
            case message_buckets(Scope, ScopeId, after, Bucket) of
                {ok, Buckets} -> collect_asc(Scope, ScopeId, Buckets, AfterId, Limit, []);
                Error -> Error
            end;
        {ok, _} -> {error, cursor_scope_mismatch};
        {error, not_found} -> {ok, []};
        Error -> Error
    end.

get_around(Scope, ScopeId, Id, Before, After) ->
    case {get_before(Scope, ScopeId, Id, Before), get(Id), get_after(Scope, ScopeId, Id, After)} of
        {{ok, Older}, {ok, Mid}, {ok, Newer}} -> {ok, lists:reverse(Older) ++ [Mid] ++ Newer};
        {_, {error, not_found}, _} -> {error, not_found};
        {Error = {error, _}, _, _} -> Error;
        {_, Error = {error, _}, _} -> Error;
        {_, _, Error = {error, _}} -> Error
    end.

bulk_get(Ids0) when is_list(Ids0) ->
    Ids = lists:sublist(lists:usort([I || I <- Ids0, is_integer(I), I > 0]), 250),
    lists:foldl(fun(Id, {ok, Acc}) ->
                        case get(Id) of
                            {ok, Msg} -> {ok, maps:put(Id, Msg, Acc)};
                            {error, not_found} -> {ok, Acc};
                            Error -> Error
                        end;
                   (_, Error) -> Error
                end, {ok, #{}}, Ids).

edit(Id, Body, EditedAt) when is_integer(Id), Id > 0, is_binary(Body), is_integer(EditedAt), EditedAt > 0 ->
    %% Cassandra UPDATE is an upsert. Check the canonical row first so an edit
    %% cannot recreate a missing/tombstoned message and so PostgreSQL/Scylla
    %% mutation semantics remain identical.
    case get(Id) of
        {ok, #{deleted_at := Deleted}} when Deleted =/= undefined, Deleted =/= 0 -> {error, not_found};
        {ok, #{scope := Scope, scope_id := ScopeId, bucket := Bucket}} ->
            pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_edit,
                              [Body, EditedAt, Scope, ScopeId, Bucket, Id]);
        Error -> Error
    end;
edit(_, _, _) -> {error, bad_request}.

delete(Id, ActorId) when is_integer(Id), Id > 0 ->
    case get(Id) of
        {ok, #{deleted_at := Deleted}} when Deleted =/= undefined, Deleted =/= 0 -> {error, not_found};
        {ok, #{scope := Scope, scope_id := ScopeId, bucket := Bucket}} ->
            Now = pw_util:now_ms(),
            _ = ActorId,
            pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_delete,
                              [Now, Scope, ScopeId, Bucket, Id]);
        Error -> Error
    end;
delete(_, _) -> {error, bad_request}.

hard_delete(Id) when is_integer(Id), Id > 0 ->
    case locator(Id) of
        {ok, #{scope := Scope, scope_id := ScopeId, bucket := Bucket}} ->
            case pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_hard_delete,
                                   [Scope, ScopeId, Bucket, Id]) of
                ok -> pw_scylla:execute({locator, Id}, pw_msg_locator_delete, [Id]);
                Error -> Error
            end;
        {error, not_found} -> ok;
        Error -> Error
    end.

%% Privacy erasure cannot rely solely on the locator. A backfill request may
%% have timed out after Scylla applied the message row and then successfully
%% compensated the locator. PostgreSQL still knows the immutable message scope
%% and creation time when it queues the erase, so probe the only three bucket
%% policies Plainwire supports (day/week/month) as well as any live locator.
%% This is bounded, idempotent, and also survives a later bucket-policy change.
hard_delete_scoped(Id, Scope, ScopeId, CreatedAt)
  when is_integer(Id), Id > 0, is_binary(Scope), is_integer(ScopeId), ScopeId > 0,
       is_integer(CreatedAt), CreatedAt >= 0 ->
    case valid_scope(Scope) of
        false -> {error, bad_request};
        true ->
            PolicyTargets = [{Scope, ScopeId, pw_message_bucket:for_timestamp(CreatedAt, Policy)}
                             || Policy <- [day, week, month]],
            case locator(Id) of
                {ok, #{scope := LS, scope_id := LId, bucket := LB}} ->
                    hard_delete_known_targets(lists:usort([{LS, LId, LB} | PolicyTargets]), Id);
                {error, not_found} ->
                    hard_delete_known_targets(lists:usort(PolicyTargets), Id);
                {error, malformed_row} ->
                    %% We cannot trust the locator's routing columns, but the
                    %% PostgreSQL routing metadata still identifies every bucket
                    %% policy Plainwire can have used for this message.
                    hard_delete_known_targets(lists:usort(PolicyTargets), Id);
                Error -> Error
            end
    end;
hard_delete_scoped(_, _, _, _) -> {error, bad_request}.

hard_delete_known_targets(Targets, Id) ->
    case hard_delete_targets(Targets, Id) of
        ok -> pw_scylla:execute({locator, Id}, pw_msg_locator_delete, [Id]);
        Error -> Error
    end.

hard_delete_targets([], _Id) -> ok;
hard_delete_targets([{Scope, ScopeId, Bucket} | Rest], Id) ->
    case pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_hard_delete,
                           [Scope, ScopeId, Bucket, Id]) of
        ok -> hard_delete_targets(Rest, Id);
        Error -> Error
    end.

hard_delete_at(Scope, ScopeId, Bucket, Id)
  when is_binary(Scope), is_integer(ScopeId), ScopeId > 0, is_integer(Bucket), Bucket >= 0,
       is_integer(Id), Id > 0 ->
    case pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_hard_delete,
                           [Scope, ScopeId, Bucket, Id]) of
        ok -> pw_scylla:execute({locator, Id}, pw_msg_locator_delete, [Id]);
        Error -> Error
    end;
hard_delete_at(_, _, _, _) -> {error, bad_request}.

append_lifecycle(Type, MessageId, Ts, Extra) ->
    case get_scope_from_extra_or_locator(MessageId, Extra) of
        {ok, Scope, ScopeId} ->
            case lifecycle_event_id(Extra) of
                {ok, EventId} ->
                    pw_event_store:append(maps:merge(
                        maps:without([event_id, type, timestamp, scope, scope_id, entity_id], Extra),
                        #{event_id => EventId, type => Type, timestamp => Ts,
                          scope => Scope, scope_id => ScopeId, entity_id => MessageId}));
                Error -> Error
            end;
        Error -> Error
    end.

message_buckets(Scope, ScopeId, recent, _Bucket) ->
    bucket_rows(pw_scylla:execute({bucket_index, Scope, ScopeId}, pw_msg_buckets_recent,
                                  [Scope, ScopeId, bucket_scan_limit()]));
message_buckets(Scope, ScopeId, before, Bucket) ->
    bucket_rows(pw_scylla:execute({bucket_index, Scope, ScopeId}, pw_msg_buckets_before,
                                  [Scope, ScopeId, Bucket, bucket_scan_limit()]));
message_buckets(Scope, ScopeId, after, Bucket) ->
    bucket_rows(pw_scylla:execute({bucket_index, Scope, ScopeId}, pw_msg_buckets_after,
                                  [Scope, ScopeId, Bucket, bucket_scan_limit()])).

bucket_rows({ok, _Cols, Rows}) ->
    {ok, [B || [B] <- Rows, is_integer(B), B >= 0]};
bucket_rows(Error) -> Error.

cleanup_locator(Id) ->
    case pw_scylla:execute({locator, Id}, pw_msg_locator_delete, [Id]) of
        ok -> ok;
        Error ->
            pw_storage_metrics:incr(scylla_insert_compensation_failed),
            logger:error("[plainwire:scylla] failed to compensate locator after message insert failure id=~p reason=~p",
                         [Id, Error]),
            Error
    end.

locator(Id) ->
    case pw_scylla:execute({locator, Id}, pw_msg_locator_get, [Id]) of
        {ok, _Cols, [[Scope, ScopeId, Bucket, Created]]}
          when is_binary(Scope), is_integer(ScopeId), ScopeId > 0,
               is_integer(Bucket), Bucket >= 0, is_integer(Created), Created >= 0 ->
            case valid_scope(Scope) of
                true -> {ok, #{scope => Scope, scope_id => ScopeId, bucket => Bucket, created_at => Created}};
                false -> malformed_locator()
            end;
        {ok, _Cols, []} -> {error, not_found};
        {ok, _Cols, _Malformed} -> malformed_locator();
        Error -> Error
    end.

malformed_locator() ->
    pw_storage_metrics:incr(scylla_malformed_message_locator),
    {error, malformed_row}.

collect_desc(Scope, ScopeId, Buckets, Cursor, Limit, Acc) ->
    collect_desc(Scope, ScopeId, Buckets, Cursor, Limit, Acc, page_scan_row_limit()).

collect_desc(_Scope, _ScopeId, [], _Cursor, _Limit, Acc, _Budget) -> {ok, Acc};
collect_desc(_Scope, _ScopeId, _Buckets, _Cursor, Limit, Acc, _Budget) when length(Acc) >= Limit ->
    {ok, lists:sublist(Acc, Limit)};
collect_desc(_Scope, _ScopeId, _Buckets, _Cursor, _Limit, _Acc, Budget) when Budget =< 0 ->
    pw_storage_metrics:incr(scylla_history_scan_limit),
    {error, history_scan_limit};
collect_desc(Scope, ScopeId, [Bucket | Rest], Cursor, Limit, Acc0, Budget0) ->
    Need = Limit - length(Acc0),
    case scan_desc_bucket(Scope, ScopeId, Bucket, Cursor, Need, Budget0, []) of
        {ok, Visible, Budget1} ->
            %% Cursor only constrains the first bucket. Older buckets are inherently before it.
            collect_desc(Scope, ScopeId, Rest, undefined, Limit, Acc0 ++ Visible, Budget1);
        Error -> Error
    end.

scan_desc_bucket(_Scope, _ScopeId, _Bucket, _Cursor, Need, Budget, Acc)
  when Need =< 0 -> {ok, Acc, Budget};
scan_desc_bucket(_Scope, _ScopeId, _Bucket, _Cursor, _Need, Budget, _Acc)
  when Budget =< 0 ->
    pw_storage_metrics:incr(scylla_history_scan_limit),
    {error, history_scan_limit};
scan_desc_bucket(Scope, ScopeId, Bucket, Cursor, Need, Budget0, Acc0) ->
    Fetch = erlang:min(?MAX_LIMIT, Budget0),
    Result = case Cursor of
        undefined -> pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_recent,
                                       [Scope, ScopeId, Bucket, Fetch]);
        _ -> pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_before,
                               [Scope, ScopeId, Bucket, Cursor, Fetch])
    end,
    case Result of
        {ok, _Cols, Rows} ->
            Consumed = length(Rows),
            Budget1 = Budget0 - Consumed,
            case decode_message_rows(Scope, ScopeId, Bucket, Rows) of
                {ok, Decoded} ->
                    Visible0 = [M || M <- Decoded, message_visible(M)],
                    Visible = lists:sublist(Visible0, Need),
                    Acc1 = Acc0 ++ Visible,
                    Remaining = Need - length(Visible),
                    case {Remaining =< 0, Consumed < Fetch, Rows} of
                        {true, _, _} -> {ok, Acc1, Budget1};
                        {false, true, _} -> {ok, Acc1, Budget1};
                        {false, false, []} -> {ok, Acc1, Budget1};
                        {false, false, _} ->
                            NextCursor = row_id(lists:last(Rows)),
                            scan_desc_bucket(Scope, ScopeId, Bucket, NextCursor,
                                             Remaining, Budget1, Acc1)
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

collect_asc(Scope, ScopeId, Buckets, Cursor, Limit, Acc) ->
    collect_asc(Scope, ScopeId, Buckets, Cursor, Limit, Acc, page_scan_row_limit()).

collect_asc(_Scope, _ScopeId, [], _Cursor, _Limit, Acc, _Budget) -> {ok, Acc};
collect_asc(_Scope, _ScopeId, _Buckets, _Cursor, Limit, Acc, _Budget) when length(Acc) >= Limit ->
    {ok, lists:sublist(Acc, Limit)};
collect_asc(_Scope, _ScopeId, _Buckets, _Cursor, _Limit, _Acc, Budget) when Budget =< 0 ->
    pw_storage_metrics:incr(scylla_history_scan_limit),
    {error, history_scan_limit};
collect_asc(Scope, ScopeId, [Bucket | Rest], Cursor, Limit, Acc0, Budget0) ->
    Need = Limit - length(Acc0),
    case scan_asc_bucket(Scope, ScopeId, Bucket, Cursor, Need, Budget0, []) of
        {ok, Visible, Budget1} ->
            collect_asc(Scope, ScopeId, Rest, undefined, Limit, Acc0 ++ Visible, Budget1);
        Error -> Error
    end.

scan_asc_bucket(_Scope, _ScopeId, _Bucket, _Cursor, Need, Budget, Acc)
  when Need =< 0 -> {ok, Acc, Budget};
scan_asc_bucket(_Scope, _ScopeId, _Bucket, _Cursor, _Need, Budget, _Acc)
  when Budget =< 0 ->
    pw_storage_metrics:incr(scylla_history_scan_limit),
    {error, history_scan_limit};
scan_asc_bucket(Scope, ScopeId, Bucket, Cursor, Need, Budget0, Acc0) ->
    Fetch = erlang:min(?MAX_LIMIT, Budget0),
    QueryCursor = case Cursor of undefined -> 0; _ -> Cursor end,
    Result = pw_scylla:execute({Scope, ScopeId, Bucket}, pw_msg_after,
                               [Scope, ScopeId, Bucket, QueryCursor, Fetch]),
    case Result of
        {ok, _Cols, Rows} ->
            Consumed = length(Rows),
            Budget1 = Budget0 - Consumed,
            case decode_message_rows(Scope, ScopeId, Bucket, Rows) of
                {ok, Decoded} ->
                    Visible0 = [M || M <- Decoded, message_visible(M)],
                    Visible = lists:sublist(Visible0, Need),
                    Acc1 = Acc0 ++ Visible,
                    Remaining = Need - length(Visible),
                    case {Remaining =< 0, Consumed < Fetch, Rows} of
                        {true, _, _} -> {ok, Acc1, Budget1};
                        {false, true, _} -> {ok, Acc1, Budget1};
                        {false, false, []} -> {ok, Acc1, Budget1};
                        {false, false, _} ->
                            NextCursor = row_id(lists:last(Rows)),
                            scan_asc_bucket(Scope, ScopeId, Bucket, NextCursor,
                                            Remaining, Budget1, Acc1)
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

row_id([Id | _]) when is_integer(Id), Id > 0 -> Id.

%% Never let corrupt/mismatched CQL data crash a message worker. Returning an
%% explicit storage error keeps callers in the existing degraded/fallback path
%% and gives operators a metric instead of a supervisor restart loop.
decode_message_row(Scope, ScopeId, Bucket, Row) ->
    case row_to_message(Scope, ScopeId, Bucket, Row) of
        {ok, Msg} -> {ok, Msg};
        {error, malformed_row} = Error ->
            pw_storage_metrics:incr(scylla_malformed_message_row),
            Error
    end.

decode_message_rows(Scope, ScopeId, Bucket, Rows) ->
    decode_message_rows(Scope, ScopeId, Bucket, Rows, []).

decode_message_rows(_Scope, _ScopeId, _Bucket, [], Acc) -> {ok, lists:reverse(Acc)};
decode_message_rows(Scope, ScopeId, Bucket, [Row | Rest], Acc) ->
    case row_to_message(Scope, ScopeId, Bucket, Row) of
        {ok, Msg} -> decode_message_rows(Scope, ScopeId, Bucket, Rest, [Msg | Acc]);
        {error, malformed_row} = Error ->
            pw_storage_metrics:incr(scylla_malformed_message_row),
            Error
    end.

row_to_message(Scope, ScopeId, Bucket,
               [Id, UserId, Body, Reply, Created, Edited, Deleted, Kind, Forwarded])
  when is_integer(Id), Id > 0,
       is_integer(UserId), UserId > 0,
       is_binary(Body),
       is_integer(Created), Created >= 0,
       is_binary(Kind) ->
    case valid_optional_id(Reply) andalso valid_optional_timestamp(Edited) andalso
         valid_optional_timestamp(Deleted) andalso valid_optional_id(Forwarded) of
        true ->
            {ok, #{id => Id, scope => Scope, scope_id => ScopeId, bucket => Bucket,
                   user_id => UserId, body => Body, reply_to_id => unz(Reply),
                   created_at => Created, edited_at => unz(Edited), deleted_at => unz(Deleted),
                   kind => Kind, forwarded_from_id => unz(Forwarded)}};
        false -> {error, malformed_row}
    end;
row_to_message(_, _, _, _) -> {error, malformed_row}.

normalize_message(Msg) ->
    Id = maps:get(id, Msg, undefined),
    Scope = maps:get(scope, Msg, undefined),
    ScopeId = maps:get(scope_id, Msg, undefined),
    UserId = maps:get(user_id, Msg, undefined),
    Body = maps:get(body, Msg, undefined),
    Created = maps:get(created_at, Msg, undefined),
    Kind = maps:get(kind, Msg, <<"text">>),
    Reply = maps:get(reply_to_id, Msg, undefined),
    Edited = maps:get(edited_at, Msg, undefined),
    Deleted = maps:get(deleted_at, Msg, undefined),
    Forwarded = maps:get(forwarded_from_id, Msg, undefined),
    Valid = is_integer(Id) andalso Id > 0 andalso Id =< pw_message_id:max_id() andalso
            valid_scope(Scope) andalso is_integer(ScopeId) andalso ScopeId > 0 andalso
            is_integer(UserId) andalso UserId > 0 andalso is_binary(Body) andalso
            is_integer(Created) andalso Created >= 0 andalso is_binary(Kind) andalso
            byte_size(Kind) =< 64 andalso valid_optional_id(Reply) andalso
            valid_optional_timestamp(Edited) andalso valid_optional_timestamp(Deleted) andalso
            valid_optional_id(Forwarded),
    case Valid of
        true -> {ok, Msg};
        false ->
            pw_storage_metrics:incr(scylla_invalid_message),
            {error, invalid_message}
    end.

valid_scope(<<"channel">>) -> true;
valid_scope(<<"direct">>) -> true;
valid_scope(_) -> false.

valid_optional_id(undefined) -> true;
valid_optional_id(null) -> true;
valid_optional_id(0) -> true;
valid_optional_id(V) when is_integer(V), V > 0, V =< 9007199254740991 -> true;
valid_optional_id(_) -> false.

valid_optional_timestamp(undefined) -> true;
valid_optional_timestamp(null) -> true;
valid_optional_timestamp(0) -> true;
valid_optional_timestamp(V) when is_integer(V), V > 0 -> true;
valid_optional_timestamp(_) -> false.

get_scope_from_extra_or_locator(Id, #{scope := Scope, scope_id := ScopeId}) -> {ok, Scope, ScopeId};
get_scope_from_extra_or_locator(Id, _Extra) ->
    case locator(Id) of
        {ok, #{scope := Scope, scope_id := ScopeId}} -> {ok, Scope, ScopeId};
        Error -> Error
    end.

lifecycle_event_id(Extra) ->
    case maps:find(event_id, Extra) of
        {ok, Id} when is_integer(Id), Id > 0 -> {ok, Id};
        {ok, _} -> {error, invalid_event_id};
        error ->
            case pw_message_id:next() of
                {ok, Id} -> {ok, Id};
                {error, Reason} -> {error, {event_id_unavailable, Reason}}
            end
    end.

collect_intents(_Buckets, Limit, Acc) when length(Acc) >= Limit ->
    {ok, lists:sublist(Acc, Limit)};
collect_intents([], _Limit, Acc) -> {ok, Acc};
collect_intents([Bucket | Rest], Limit, Acc0) ->
    Need = Limit - length(Acc0),
    case collect_intent_bucket(Bucket, 0, Need, []) of
        {ok, Found} -> collect_intents(Rest, Limit, Acc0 ++ Found);
        Error -> Error
    end.

collect_intent_bucket(_Bucket, _Cursor, Need, Acc) when Need =< 0 -> {ok, Acc};
collect_intent_bucket(Bucket, Cursor, Need, Acc0) ->
    Fetch = erlang:min(?MAX_LIMIT, Need),
    Result = case Cursor of
        0 -> pw_scylla:execute({write_intent, Bucket}, pw_write_intents_first, [Bucket, Fetch]);
        _ -> pw_scylla:execute({write_intent, Bucket}, pw_write_intents_after, [Bucket, Cursor, Fetch])
    end,
    case Result of
        {ok, _Cols, Rows} ->
            Found = [#{id => Id, bucket => Bucket, scope => Scope, scope_id => ScopeId,
                       message_bucket => MessageBucket, marked_at => MarkedAt}
                     || [Id, Scope, ScopeId, MessageBucket, MarkedAt] <- Rows,
                        is_integer(Id), Id > 0, is_integer(MessageBucket), MessageBucket >= 0,
                        is_integer(MarkedAt), MarkedAt >= 0],
            Acc1 = Acc0 ++ Found,
            case {length(Rows) < Fetch, Rows, length(Acc1) >= Need} of
                {true, _, _} -> {ok, Acc1};
                {_, [], _} -> {ok, Acc1};
                {_, _, true} -> {ok, Acc1};
                _ ->
                    Next = case lists:last(Rows) of [LastId | _] -> LastId end,
                    collect_intent_bucket(Bucket, Next, Need, Acc1)
            end;
        Error -> Error
    end.

intent_bucket(Ts) when is_integer(Ts), Ts >= 0 -> (Ts div 86400000) * 86400000.
intent_bucket_scan_limit() ->
    erlang:min(4096, erlang:max(32, pw_util:env_int("PLAINWIRE_SCYLLA_WRITE_INTENT_BUCKETS", 512))).

bucket_scan_limit() ->
    erlang:min(4096, erlang:max(64, pw_util:env_int("PLAINWIRE_SCYLLA_HISTORY_BUCKETS", 512))).

page_scan_row_limit() ->
    %% Soft-deleted rows are intentionally skipped in history. Keep scanning the
    %% same bucket so deletion-heavy channels do not silently lose visible
    %% messages, but impose a hard raw-row budget so one request can never turn
    %% into an unbounded partition scan. Callers can fall back to PostgreSQL when
    %% migration/recovery mode is available.
    erlang:min(50000, erlang:max(?MAX_LIMIT,
        pw_util:env_int("PLAINWIRE_SCYLLA_MAX_PAGE_SCAN_ROWS", 4096))).
limit(undefined, Default) -> Default;
limit(N, _Default) when is_integer(N) -> erlang:min(?MAX_LIMIT, erlang:max(1, N));
limit(_, Default) -> Default.
message_visible(Msg) when is_map(Msg) ->
    case maps:get(deleted_at, Msg, undefined) of
        undefined -> true;
        null -> true;
        0 -> true;
        _ -> false
    end;
message_visible(_) -> false.

-ifdef(TEST).
test_message_visible(Msg) -> message_visible(Msg).
-endif.

nz(null) -> 0;
nz(undefined) -> 0;
nz(V) when is_integer(V) -> V;
nz(_) -> 0.
unz(0) -> undefined;
unz(null) -> undefined;
unz(V) -> V.
