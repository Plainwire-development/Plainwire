-- Sparse bucket directories for append-heavy timelines. These partitions grow
-- by time bucket, not by event count, and let readers skip empty calendar ranges.
CREATE TABLE IF NOT EXISTS event_buckets_by_scope (
    scope text,
    scope_id bigint,
    bucket_start bigint,
    PRIMARY KEY ((scope, scope_id), bucket_start)
) WITH CLUSTERING ORDER BY (bucket_start DESC);

CREATE TABLE IF NOT EXISTS audit_buckets_by_server (
    server_id bigint,
    bucket_start bigint,
    PRIMARY KEY ((server_id), bucket_start)
) WITH CLUSTERING ORDER BY (bucket_start DESC);

CREATE TABLE IF NOT EXISTS delivery_buckets_by_server (
    server_id bigint,
    bucket_start bigint,
    PRIMARY KEY ((server_id), bucket_start)
) WITH CLUSTERING ORDER BY (bucket_start DESC);
