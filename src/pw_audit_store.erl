-module(pw_audit_store).
-export([append/1, recent/3]).


append(Event0) when is_map(Event0) ->
    Event = pw_storage_sanitize:without_secrets(Event0),
    Sid = maps:get(server_id, Event, 0),
    EventIdentity = resolve_event_identity(Event),
    Actor = integer(maps:get(actor_id, Event, 0)),
    Type = pw_util:clean_text(maps:get(type, Event, <<"audit">>), 80),
    Entity = text(maps:get(entity_id, Event, <<>>), 128),
    Payload = pw_storage_sanitize:encode_payload(
                maps:without([server_id, timestamp, event_id, actor_id, type, entity_id], Event)),
    Ttl = retention_seconds(event_retention_days),
    case {Sid, EventIdentity} of
        {S, {ok, EventId, T, Bucket}} when is_integer(S), S > 0 ->
            case pw_scylla:execute({audit_index, S}, pw_audit_bucket_touch, [S, Bucket]) of
                ok -> pw_scylla:execute({audit, S, Bucket}, pw_audit_insert,
                                        [S, Bucket, EventId, Actor, Type, Entity, T, Payload, Ttl]);
                Error -> Error
            end;
        {S, _} when not is_integer(S); S =< 0 -> {error, invalid_server};
        {_, Error} -> Error
    end;
append(_) -> {error, bad_request}.

recent(ServerId, BeforeId0, Limit0) when is_integer(ServerId), ServerId > 0 ->
    BeforeId = before_id(BeforeId0),
    Limit = limit(Limit0),
    case audit_buckets(ServerId, BeforeId) of
        {ok, Buckets} -> recent_buckets(ServerId, Buckets, BeforeId, Limit, []);
        Error -> Error
    end;
recent(_, _, _) -> {error, bad_request}.

recent_buckets(_Sid, [], _Before, _Limit, Acc) -> {ok, Acc};
recent_buckets(_Sid, _Buckets, _Before, Limit, Acc) when length(Acc) >= Limit -> {ok, lists:sublist(Acc, Limit)};
recent_buckets(Sid, [Bucket|Rest], Before, Limit, Acc0) ->
    Need = Limit - length(Acc0),
    Cursor = case Before of undefined -> pw_message_id:max_id(); _ -> Before end,
    case pw_scylla:execute({audit, Sid, Bucket}, pw_audit_range, [Sid, Bucket, Cursor, Need]) of
        {ok, _Cols, Rows} ->
            case decode_audit_rows(Rows) of
                {ok, Mapped} -> recent_buckets(Sid, Rest, undefined, Limit, Acc0 ++ Mapped);
                Error -> Error
            end;
        Error -> Error
    end.

audit_buckets(Sid, undefined) ->
    bucket_rows(pw_scylla:execute({audit_index, Sid}, pw_audit_buckets_recent, [Sid, bucket_scan_limit(event_retention_days)]));
audit_buckets(Sid, BeforeId) ->
    case pw_message_id:decode_timestamp(BeforeId) of
        Ts when is_integer(Ts) ->
            Bucket = pw_message_bucket:for_timestamp(Ts),
            bucket_rows(pw_scylla:execute({audit_index, Sid}, pw_audit_buckets_before,
                                          [Sid, Bucket, bucket_scan_limit(event_retention_days)]));
        _ -> {error, invalid_cursor}
    end.

decode_audit_rows(Rows) ->
    Mapped = [#{event_id => Id, actor_id => Actor, type => Type, entity_id => Entity,
                timestamp => Ts, payload => decode(Payload)}
              || [Id,Actor,Type,Entity,Ts,Payload] <- Rows,
                 is_integer(Id), Id > 0, is_integer(Actor), is_binary(Type), is_binary(Entity),
                 is_integer(Ts), Ts >= 0, is_binary(Payload)],
    checked_rows(Rows, Mapped, scylla_malformed_audit_row).

bucket_rows({ok, _Cols, Rows}) ->
    Buckets = [B || [B] <- Rows, is_integer(B), B >= 0],
    checked_rows(Rows, Buckets, scylla_malformed_audit_bucket);
bucket_rows(Error) -> Error.

checked_rows(Rows, Decoded, Metric) ->
    case length(Rows) =:= length(Decoded) of
        true -> {ok, Decoded};
        false -> pw_storage_metrics:incr(Metric), {error, malformed_row}
    end.

resolve_event_identity(Event) ->
    case resolve_event_id(Event) of
        {ok, EventId} ->
            IdTs = pw_message_id:decode_timestamp(EventId),
            case maps:find(timestamp, Event) of
                error when is_integer(IdTs) ->
                    {ok, EventId, IdTs, pw_message_bucket:for_timestamp(IdTs)};
                {ok, Ts} when is_integer(Ts), Ts >= 0, is_integer(IdTs) ->
                    IdBucket = pw_message_bucket:for_timestamp(IdTs),
                    case pw_message_bucket:for_timestamp(Ts) =:= IdBucket of
                        true -> {ok, EventId, Ts, IdBucket};
                        false -> {error, event_id_timestamp_bucket_mismatch}
                    end;
                {ok, _} -> {error, invalid_timestamp};
                _ -> {error, invalid_event_id}
            end;
        Error -> Error
    end.

resolve_event_id(Event) ->
    case maps:find(event_id, Event) of
        {ok, Id} when is_integer(Id), Id > 0, Id =< 9007199254740991 -> {ok, Id};
        {ok, _} -> {error, invalid_event_id};
        error ->
            case pw_message_id:next() of
                {ok, Id} -> {ok, Id};
                {error, Reason} -> {error, {event_id_unavailable, Reason}}
            end
    end.
text(V, Max) -> pw_util:clean_text(V, Max).
decode(B) when is_binary(B) -> try jsx:decode(B, [return_maps]) catch _:_ -> #{} end;
decode(_) -> #{}.
before_id(undefined) -> undefined;
before_id(null) -> undefined;
before_id(Id) when is_integer(Id), Id > 0, Id =< 9007199254740991 -> Id;
before_id(_) -> invalid.
limit(N) when is_integer(N) -> erlang:min(200, erlang:max(1, N));
limit(_) -> 80.
integer(I) when is_integer(I) -> I;
integer(_) -> 0.

retention_seconds(ConfigKey) ->
    %% Keep one retention value per timeline table. TWCS is most efficient when
    %% rows in the same table share a TTL policy; accepting per-event TTLs would
    %% let short-lived rows keep SSTables around behind longer-lived neighbors.
    maps:get(ConfigKey, pw_scylla_config:config()) * 86400.

bucket_scan_limit(ConfigKey) ->
    Days = maps:get(ConfigKey, pw_scylla_config:config()),
    Needed = case pw_message_bucket:policy() of
        day -> Days + 2;
        week -> ((Days + 6) div 7) + 2;
        month -> ((Days + 27) div 28) + 2
    end,
    erlang:min(4096, erlang:max(64, Needed)).
