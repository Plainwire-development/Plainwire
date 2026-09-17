-- Plainwire ScyllaDB schema v1.
-- Create/select the keyspace before applying this file. See docs/SCYLLA.md.

CREATE TABLE IF NOT EXISTS messages_by_scope_bucket (
    scope text,
    scope_id bigint,
    bucket_start bigint,
    message_id bigint,
    user_id bigint,
    body text,
    reply_to_id bigint,
    created_at bigint,
    edited_at bigint,
    deleted_at bigint,
    kind text,
    forwarded_from_id bigint,
    PRIMARY KEY ((scope, scope_id, bucket_start), message_id)
) WITH CLUSTERING ORDER BY (message_id DESC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy'};

CREATE TABLE IF NOT EXISTS message_locator_by_id (
    message_id bigint PRIMARY KEY,
    scope text,
    scope_id bigint,
    bucket_start bigint,
    created_at bigint
);

CREATE TABLE IF NOT EXISTS message_events_by_scope_bucket (
    scope text,
    scope_id bigint,
    bucket_start bigint,
    event_id bigint,
    event_type text,
    actor_id bigint,
    entity_id bigint,
    ts bigint,
    payload text,
    PRIMARY KEY ((scope, scope_id, bucket_start), event_id)
) WITH CLUSTERING ORDER BY (event_id DESC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy'};

CREATE TABLE IF NOT EXISTS audit_events_by_server_bucket (
    server_id bigint,
    bucket_start bigint,
    event_id bigint,
    actor_id bigint,
    event_type text,
    entity_id text,
    ts bigint,
    payload text,
    PRIMARY KEY ((server_id, bucket_start), event_id)
) WITH CLUSTERING ORDER BY (event_id DESC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy'};

CREATE TABLE IF NOT EXISTS delivery_events_by_server_bucket (
    server_id bigint,
    bucket_start bigint,
    event_id bigint,
    target_type text,
    target_id bigint,
    status text,
    http_status int,
    attempt int,
    latency_ms int,
    ts bigint,
    error_code text,
    PRIMARY KEY ((server_id, bucket_start), event_id)
) WITH CLUSTERING ORDER BY (event_id DESC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy'};
