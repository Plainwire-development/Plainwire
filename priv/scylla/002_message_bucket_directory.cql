-- Track only buckets that have contained message history. This keeps timeline
-- traversal bounded by real data instead of by wall-clock distance.
CREATE TABLE IF NOT EXISTS message_buckets_by_scope (
    scope text,
    scope_id bigint,
    bucket_start bigint,
    PRIMARY KEY ((scope, scope_id), bucket_start)
) WITH CLUSTERING ORDER BY (bucket_start DESC);
