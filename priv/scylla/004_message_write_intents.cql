-- Crash-recovery journal for Scylla-authoritative message mutations.
-- Rows normally live only for the duration of one PostgreSQL transaction.
-- They intentionally have no TTL: an interrupted cross-store write must remain
-- discoverable until reconciliation proves PostgreSQL state and clears it.

CREATE TABLE IF NOT EXISTS message_write_intent_buckets (
    directory text,
    bucket_start bigint,
    PRIMARY KEY ((directory), bucket_start)
) WITH CLUSTERING ORDER BY (bucket_start DESC);

CREATE TABLE IF NOT EXISTS message_write_intents_by_bucket (
    bucket_start bigint,
    message_id bigint,
    scope text,
    scope_id bigint,
    message_bucket bigint,
    marked_at bigint,
    PRIMARY KEY ((bucket_start), message_id)
) WITH CLUSTERING ORDER BY (message_id ASC);
