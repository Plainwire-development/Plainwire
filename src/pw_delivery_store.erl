-module(pw_delivery_store).
-export([append/1, recent/3]).


append(Event0) when is_map(Event0) ->
    Event = maps:without([payload, body], pw_storage_sanitize:without_secrets(Event0)),
    Sid = maps:get(server_id, Event, 0),
    EventIdentity = resolve_event_identity(Event),
    TargetType = pw_util:clean_text(maps:get(target_type, Event, <<"webhook">>), 32),
    TargetId = integer(maps:get(target_id, Event, 0)),
    Status = pw_util:clean_text(maps:get(status, Event, <<"unknown">>), 32),
    Http = clamp_int(maps:get(http_status, Event, 0), 0, 999),
    Attempt = clamp_int(maps:get(attempt, Event, 0), 0, 1000000),
    Latency = clamp_int(maps:get(latency_ms, Event, 0), 0, 3600000),
    ErrorCode = pw_util:clean_text(maps:get(error_code, Event, <<>>), 96),
    Ttl = retention_seconds(delivery_retention_days),
    case {Sid, EventIdentity} of
        {S, {ok, EventId, T, Bucket}} when is_integer(S), S > 0 ->
            case pw_scylla:execute({delivery_index, S}, pw_delivery_bucket_touch, [S, Bucket]) of
                ok -> pw_scylla:execute({delivery, S, Bucket}, pw_delivery_insert,
                                        [S, Bucket, EventId, TargetType, TargetId, Status, Http, Attempt, Latency, T, ErrorCode, Ttl]);
                Error -> Error
            end;
        {S, _} when not is_integer(S); S =< 0 -> {error, invalid_server};
        {_, Error} -> Error
    end;
append(_) -> {error, bad_request}.

recent(ServerId, BeforeId0, Limit0) when is_integer(ServerId), ServerId > 0 ->
    BeforeId = before_id(BeforeId0),
    Limit = limit(Limit0),
    case delivery_buckets(ServerId, BeforeId) of
        {ok, Buckets} -> recent_buckets(ServerId, Buckets, BeforeId, Limit, []);
        Error -> Error
    end;
recent(_, _, _) -> {error, bad_request}.

recent_buckets(_Sid, [], _Before, _Limit, Acc) -> {ok, Acc};
recent_buckets(_Sid, _Buckets, _Before, Limit, Acc) when length(Acc) >= Limit -> {ok, lists:sublist(Acc, Limit)};
recent_buckets(Sid, [Bucket|Rest], Before, Limit, Acc0) ->
    Need = Limit - length(Acc0),
    Cursor = case Before of undefined -> pw_message_id:max_id(); _ -> Before end,
    case pw_scylla:execute({delivery, Sid, Bucket}, pw_delivery_range, [Sid, Bucket, Cursor, Need]) of
        {ok, _Cols, Rows} ->
            case decode_delivery_rows(Rows) of
                {ok, Mapped} -> recent_buckets(Sid, Rest, undefined, Limit, Acc0 ++ Mapped);
                Error -> Error
            end;
        Error -> Error
    end.

delivery_buckets(Sid, undefined) ->
    bucket_rows(pw_scylla:execute({delivery_index, Sid}, pw_delivery_buckets_recent, [Sid, bucket_scan_limit(delivery_retention_days)]));
delivery_buckets(Sid, BeforeId) ->
    case pw_message_id:decode_timestamp(BeforeId) of
        Ts when is_integer(Ts) ->
            Bucket = pw_message_bucket:for_timestamp(Ts),
            bucket_rows(pw_scylla:execute({delivery_index, Sid}, pw_delivery_buckets_before,
                                          [Sid, Bucket, bucket_scan_limit(delivery_retention_days)]));
        _ -> {error, invalid_cursor}
    end.

decode_delivery_rows(Rows) ->
    Mapped = [#{event_id => Id, target_type => TargetType, target_id => TargetId, status => Status,
                http_status => Http, attempt => Attempt, latency_ms => Latency,
                timestamp => Ts, error_code => ErrorCode}
              || [Id,TargetType,TargetId,Status,Http,Attempt,Latency,Ts,ErrorCode] <- Rows,
                 is_integer(Id), Id > 0, is_binary(TargetType), is_integer(TargetId),
                 is_binary(Status), is_integer(Http), is_integer(Attempt), is_integer(Latency),
                 is_integer(Ts), Ts >= 0, is_binary(ErrorCode)],
    checked_rows(Rows, Mapped, scylla_malformed_delivery_row).

bucket_rows({ok, _Cols, Rows}) ->
    Buckets = [B || [B] <- Rows, is_integer(B), B >= 0],
    checked_rows(Rows, Buckets, scylla_malformed_delivery_bucket);
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
before_id(undefined) -> undefined;
before_id(null) -> undefined;
before_id(Id) when is_integer(Id), Id > 0, Id =< 9007199254740991 -> Id;
before_id(_) -> invalid.
limit(N) when is_integer(N) -> erlang:min(200, erlang:max(1, N));
limit(_) -> 80.
integer(I) when is_integer(I) -> I;
integer(_) -> 0.
clamp_int(I, Min, Max) when is_integer(I) -> erlang:min(Max, erlang:max(Min, I));
clamp_int(_, Min, _Max) -> Min.

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
