-- Canonical messages are edited and soft-deleted in place. TWCS is intended
-- for time-series data and is a poor fit for rows that are overwritten. Keep
-- append-only event timelines on TWCS, but move the mutable message table to
-- IncrementalCompactionStrategy.
ALTER TABLE messages_by_scope_bucket
  WITH compaction = {'class': 'IncrementalCompactionStrategy'};
