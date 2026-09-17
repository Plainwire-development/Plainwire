-module(pw_event_store).
-export([append/1, recent/4]).


append(Event0) when is_map(Event0) ->
    Event = pw_storage_sanitize:without_secrets(Event0),
    Type = pw_util:clean_text(maps:get(type, Event, <<"event">>), 80),
    Scope = pw_util:clean_text(maps:get(scope, Event, <<"server">>), 24),
    ScopeId = maps:get(scope_id, Event, maps:get(server_id, Event, 0)),
    Actor = integer(maps:get(actor_id, Event, 0)),
    Entity = integer(maps:get(entity_id, Event, 0)),
    case {valid_scope(Scope, ScopeId), resolve_event_identity(Event)} of
        {true, {ok, EventId, Ts, Bucket}} ->
            Ttl = retention_seconds(event_retention_days),
            Payload = pw_storage_sanitize:encode_payload(
                        maps:without([event_id, type, timestamp, scope, scope_id, server_id, actor_id, entity_id], Event)),
            case pw_scylla:execute({event_index, Scope, ScopeId}, pw_event_bucket_touch,
                                   [Scope, ScopeId, Bucket]) of
                ok -> pw_scylla:execute({event, Scope, ScopeId, Bucket}, pw_event_insert,
                                        [Scope, ScopeId, Bucket, EventId, Type, Actor, Entity, Ts, Payload, Ttl]);
                Error -> Error
            end;
        {false, _} -> {error, invalid_scope};
        {_, Error} -> Error
    end;
append(_) -> {error, bad_request}.

recent(Scope0, ScopeId, BeforeId0, Limit0) ->
    Scope = pw_util:clean_text(Scope0, 24),
    Limit = limit(Limit0),
    BeforeId = before_id(BeforeId0),
    case valid_scope(Scope, ScopeId) of
        false -> {error, bad_request};
        true ->
            case event_buckets(Scope, ScopeId, BeforeId) of
                {ok, Buckets} -> recent_buckets(Scope, ScopeId, Buckets, BeforeId, Limit, []);
                Error -> Error
            end
    end.

recent_buckets(_Scope, _ScopeId, [], _Before, _Limit, Acc) -> {ok, Acc};
recent_buckets(_Scope, _ScopeId, _Buckets, _Before, Limit, Acc) when length(Acc) >= Limit ->
    {ok, lists:sublist(Acc, Limit)};
recent_buckets(Scope, ScopeId, [Bucket | Rest], Before, Limit, Acc0) ->
    Need = Limit - length(Acc0),
    Cursor = case Before of undefined -> pw_message_id:max_id(); _ -> Before end,
    case pw_scylla:execute({event, Scope, ScopeId, Bucket}, pw_event_range,
                           [Scope, ScopeId, Bucket, Cursor, Need]) of
        {ok, _Cols, Rows} ->
            case decode_event_rows(Rows) of
                {ok, Mapped} -> recent_buckets(Scope, ScopeId, Rest, undefined, Limit, Acc0 ++ Mapped);
                Error -> Error
            end;
        Error -> Error
    end.

event_buckets(Scope, ScopeId, undefined) ->
    bucket_rows(pw_scylla:execute({event_index, Scope, ScopeId}, pw_event_buckets_recent,
                                  [Scope, ScopeId, bucket_scan_limit(event_retention_days)]));
event_buckets(Scope, ScopeId, BeforeId) ->
    case pw_message_id:decode_timestamp(BeforeId) of
        Ts when is_integer(Ts) ->
            Bucket = pw_message_bucket:for_timestamp(Ts),
            bucket_rows(pw_scylla:execute({event_index, Scope, ScopeId}, pw_event_buckets_before,
                                          [Scope, ScopeId, Bucket, bucket_scan_limit(event_retention_days)]));
        _ -> {error, invalid_cursor}
    end.

decode_event_rows(Rows) ->
    Mapped = [#{event_id => Id, type => Type, actor_id => Actor, entity_id => Entity,
                timestamp => Ts, payload => decode_payload(Payload)}
              || [Id,Type,Actor,Entity,Ts,Payload] <- Rows,
                 is_integer(Id), Id > 0, is_binary(Type), is_integer(Actor),
                 is_integer(Entity), is_integer(Ts), Ts >= 0, is_binary(Payload)],
    checked_rows(Rows, Mapped, scylla_malformed_event_row).

bucket_rows({ok, _Cols, Rows}) ->
    Buckets = [B || [B] <- Rows, is_integer(B), B >= 0],
    checked_rows(Rows, Buckets, scylla_malformed_event_bucket);
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

valid_scope(Scope, ScopeId) -> is_binary(Scope) andalso byte_size(Scope) > 0 andalso is_integer(ScopeId) andalso ScopeId > 0.
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
