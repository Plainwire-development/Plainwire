-- Canonical messages are edited and soft-deleted in place. TWCS is intended
-- for time-series data and is a poor fit for rows that are overwritten: an
-- edit lands in a new time window while the original sits in an old one, and
-- TWCS never compacts across windows, so every read of an edited message has
-- to merge fragments that will never be brought back together.
--
-- Keep append-only event timelines on TWCS and move the mutable message table
-- to LeveledCompactionStrategy. LCS keeps a row's fragments converging and
-- bounds how many SSTables a point read touches, which is what the timeline
-- reads here do. It exists in both ScyllaDB open source and Enterprise —
-- IncrementalCompactionStrategy, the obvious alternative, is Enterprise-only
-- and makes this file unapplicable on an open-source cluster.
ALTER TABLE messages_by_scope_bucket
  WITH compaction = {'class': 'LeveledCompactionStrategy'};
