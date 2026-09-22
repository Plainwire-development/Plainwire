# ScyllaDB storage

ScyllaDB is optional. Plainwire can split storage by workload instead of forcing every kind of state into one database. Leave it off (`PLAINWIRE_SCYLLA_ENABLED=false`, `PLAINWIRE_MESSAGE_BACKEND=postgres`) unless you are deliberately moving message history.

```text
Plainwire
├── PostgreSQL  relational authority
│   ├── accounts, servers, channels and memberships
│   ├── roles, permissions, bots and webhooks
│   └── message recovery mirror while migrating
├── Redis       optional ephemeral accelerator
│   ├── presence and rate gates
│   └── hot message cache
└── ScyllaDB    high-volume ordered history
    ├── canonical message timeline (when enabled as the backend)
    ├── message lifecycle events
    ├── server audit history
    └── webhook/delivery history
```

PostgreSQL remains mandatory. Redis and Scylla are independent optional components. Redis is never a durable authority. Small self-hosted instances can keep `PLAINWIRE_MESSAGE_BACKEND=postgres` indefinitely.

## Runtime modes

`PLAINWIRE_MESSAGE_BACKEND` has exactly three values:

- `postgres` — PostgreSQL owns message reads and writes. This is the default and rollback mode.
- `dual` — PostgreSQL remains read authority. New message state is committed to PostgreSQL and queued in the durable PostgreSQL storage outbox for idempotent delivery to Scylla. Shadow comparison and reconciliation can run safely in this mode.
- `scylla` — Scylla is the message timeline read authority. PostgreSQL remains relational authority and a recovery mirror during the confidence window.

Do not use `dual` as a permanent steady state. It exists to migrate and verify.

## Schema

Scylla schema changes are explicit; application startup never mutates Scylla schema.

```sh
PLAINWIRE_SCYLLA_LOCAL_DC=datacenter1 \
PLAINWIRE_SCYLLA_REPLICATION_FACTOR=1 \
./scripts/scylla-migrate
```

For production, set the actual local datacenter name and a replication factor appropriate for the cluster. A three-node single-DC cluster normally uses RF 3. Do not copy the single-node development RF into production blindly.

The migration command:

- validates the keyspace, DC and replication factor before constructing CQL;
- creates the keyspace with `NetworkTopologyStrategy`;
- maintains `plainwire_schema_migrations`;
- applies numbered CQL files once and in order;
- keeps credentials out of process arguments; and
- requires CA verification when TLS is enabled.

CQL schema lives in `priv/scylla/`.

## Development services

The repository `compose.yaml` keeps the heavy services optional:

```sh
# PostgreSQL only

docker compose up -d postgres

# Add Redis

docker compose --profile realtime up -d

# Add Redis and a single-node Scylla development instance

docker compose --profile realtime --profile scylla up -d
```

The Scylla profile is for local development, not a production cluster template.

## Configuration

Core settings:

```sh
PLAINWIRE_MESSAGE_BACKEND=postgres
PLAINWIRE_SCYLLA_ENABLED=false
PLAINWIRE_SCYLLA_CONTACT_POINTS=127.0.0.1
PLAINWIRE_SCYLLA_PORT=9042
PLAINWIRE_SCYLLA_KEYSPACE=plainwire
PLAINWIRE_SCYLLA_LOCAL_DC=datacenter1
PLAINWIRE_SCYLLA_CONSISTENCY=local_quorum
PLAINWIRE_SCYLLA_POOL_SIZE=2
PLAINWIRE_SCYLLA_IO_THREADS=2
PLAINWIRE_SCYLLA_REQUEST_TIMEOUT_MS=5000
PLAINWIRE_SCYLLA_OPERATION_TIMEOUT_MS=8000
PLAINWIRE_SCYLLA_BUCKET_POLICY=month
```

Authentication/TLS:

```sh
PLAINWIRE_SCYLLA_USERNAME=plainwire
PLAINWIRE_SCYLLA_PASSWORD=replace-me
PLAINWIRE_SCYLLA_TLS=true
PLAINWIRE_SCYLLA_CA_FILE=/etc/plainwire/scylla-ca.pem
# optional mTLS
PLAINWIRE_SCYLLA_CERT_FILE=/etc/plainwire/client.pem
PLAINWIRE_SCYLLA_KEY_FILE=/etc/plainwire/client-key.pem
```

Plainwire refuses TLS configuration without a CA file. Client certificate and key must be configured together. Secrets and message bodies are not written to normal Scylla health logs.

### Backpressure

Plainwire places a bounded OTP gate in front of Scylla. This prevents one hot partition from filling the BEAM with unlimited in-flight work while allowing unrelated partitions to progress.

```sh
PLAINWIRE_SCYLLA_MAX_INFLIGHT=256
PLAINWIRE_SCYLLA_MAX_PARTITION_INFLIGHT=8
PLAINWIRE_SCYLLA_MAX_QUEUE=4096
PLAINWIRE_SCYLLA_MAX_PARTITION_QUEUE=128
```

When limits are exceeded the request receives an overload error instead of creating an unbounded mailbox. Tune these from observed queue depth and latency, not from guesswork.

### Buckets and retention

Messages are partitioned by scope + scope ID + bounded time bucket. `month` is appropriate for ordinary rooms; `week` or `day` can reduce a known hot partition at the cost of more bucket traversal.

```sh
PLAINWIRE_SCYLLA_BUCKET_POLICY=month
PLAINWIRE_SCYLLA_HISTORY_BUCKETS=36
PLAINWIRE_SCYLLA_EVENT_RETENTION_DAYS=365
PLAINWIRE_SCYLLA_DELIVERY_RETENTION_DAYS=90
```

Changing bucket policy affects where new writes land. Do not change it casually on an existing Scylla-backed installation without planning a data migration.

## PostgreSQL to Scylla migration

Never flag-day an existing Plainwire instance.

### 0. Start from PostgreSQL authority

```sh
PLAINWIRE_MESSAGE_BACKEND=postgres
```

Take normal PostgreSQL/upload backups and confirm the instance is healthy.

### 1. Create Scylla schema and connect

Run `./scripts/scylla-migrate`, then set `PLAINWIRE_SCYLLA_ENABLED=true` while keeping the message backend PostgreSQL. Confirm the admin diagnostics report Scylla healthy.

### 2. Enable dual writes

```sh
PLAINWIRE_MESSAGE_BACKEND=dual
```

New message state remains committed to PostgreSQL first. The same PostgreSQL transaction records the Scylla work in `storage_outbox`; a supervised worker delivers it idempotently.

### 3. Backfill old history

Use the running release so the operation uses Plainwire's configured DB pools, Scylla pool, backpressure and metrics:

```sh
./scripts/storage-migrate status
./scripts/storage-migrate backfill 50000
```

The optional number limits rows for one run. Progress is checkpointed in PostgreSQL after a fully successful batch, so rerunning resumes from the last committed checkpoint. Writes use the message ID as their idempotency key.

### 4. Verify before switching reads

```sh
./scripts/storage-migrate verify 0 1000
./scripts/storage-migrate shadow 500
```

`verify` compares a deterministic range. `shadow` compares recent PostgreSQL-authoritative rows to Scylla without repairing them first. Compare IDs, ordering-critical fields, content hash, edit/delete state, author, references and timestamps. A zero process exit is not proof of migration success; inspect the returned report and mismatch count.

Reconciliation is a separate action:

```sh
./scripts/storage-migrate reconcile-intents 500
./scripts/storage-migrate reconcile 500
```

`reconcile-intents` drains the crash-recovery journal used by Scylla-authoritative writes. Intents are written before a canonical Scylla mutation and normally removed immediately after PostgreSQL commits. A surviving mature intent means a process/host may have died in the narrow cross-store commit window; Plainwire compares PostgreSQL and repairs the Scylla row or physically removes an orphan before clearing the intent. Intent rows deliberately have no TTL, so crash evidence cannot silently expire.

In `dual` mode the supervised reconciler also performs a read-only shadow sample before repair so a repair cannot hide the fact that divergence existed.

### 5. Switch reads to Scylla

Only after the backfill checkpoint is complete, the storage outbox is caught up, repeated verification is clean and Scylla latency is acceptable:

```sh
PLAINWIRE_MESSAGE_BACKEND=scylla
```

Keep PostgreSQL message rows during the confidence window. Plainwire can fall back to the PostgreSQL recovery mirror if a Scylla read/hydration fails, but degraded storage should still be investigated rather than treated as normal.

### 6. Roll back if necessary

Set:

```sh
PLAINWIRE_MESSAGE_BACKEND=postgres
```

and restart/reload the deployment normally. Do not delete PostgreSQL message rows during the migration or initial Scylla confidence period. Rollback is intentionally boring.

## Operator commands

`scripts/storage-migrate` talks to a running relx release through its `rpc` command. Set `PLAINWIRE_RELEASE_BIN` if the release is installed elsewhere.

```sh
./scripts/storage-migrate status
./scripts/storage-migrate backfill [max_rows]
./scripts/storage-migrate verify [after_id] [limit]
./scripts/storage-migrate shadow [limit]
./scripts/storage-migrate parity [sample_rows]
./scripts/storage-migrate reconcile-intents [limit]
./scripts/storage-migrate reconcile [limit]
./scripts/storage-migrate flush-outbox
```

The command exits non-zero when the requested storage operation itself reports a mismatch, incomplete backfill, reconciliation error, or failed outbox flush; a successful RPC transport alone is not treated as success. This makes the commands safe to use from deployment automation. The underlying Erlang functions return structured maps suitable for automation; `pw_storage_migration:verify_json/0` and `pw_storage_migration:parity_json/1` provide machine-readable JSON reports for callers already connected to the running node.

## Failure semantics

- **PostgreSQL unavailable:** relational/authenticated operations fail. Plainwire does not pretend Scylla can replace relational authority.
- **Redis unavailable:** Redis acceleration is bypassed; durable correctness is unchanged.
- **Scylla unavailable in `postgres`:** ordinary messaging remains on PostgreSQL.
- **Scylla unavailable in `dual`:** PostgreSQL commits continue and durable outbox work waits/retries. Backlog health must be monitored.
- **Scylla unavailable in `scylla`:** durable message creation is not acknowledged before the configured Scylla authority accepts it. Reads may use the PostgreSQL recovery mirror and are marked degraded through metrics/health.
- **Overloaded Scylla partition:** bounded requests are shed/time out; queues do not grow without limit.
- **Duplicate delivery/retry:** stable message/event IDs make writes idempotent. Critical message upserts and privacy hard-deletes are never converted into terminal failed outbox records; they retry with bounded backoff until delivered.
- **Interrupted Scylla-authoritative write:** a durable bucketed write intent survives the process/host crash window. After the configured grace period reconciliation restores the committed PostgreSQL state or deletes the orphan and then clears the intent.
- **Clock rollback:** the message-ID generator tolerates only the configured small rollback window and refuses unsafe generation after larger rollback.

Plainwire deliberately does not attempt a distributed PostgreSQL/Scylla transaction. Relational cross-store events use a durable PostgreSQL outbox. Native Scylla-authoritative message writes use stable IDs plus reconciliation/recovery semantics.

## Health and telemetry

Storage diagnostics distinguish PostgreSQL, Redis and Scylla. Scylla health includes connection state and bounded-gate state. Storage metrics include request outcome/latency buckets, queue depth/load shedding, Redis cache hits/misses, migration progress, shadow mismatches and reconciliation discrepancies.

Useful environment controls:

```sh
PLAINWIRE_SCYLLA_RECONCILE_INTERVAL_MS=300000
PLAINWIRE_SCYLLA_RECONCILE_ROWS=500
PLAINWIRE_SCYLLA_WRITE_INTENT_GRACE_MS=300000
PLAINWIRE_SCYLLA_WRITE_INTENT_RECONCILE_ROWS=500
PLAINWIRE_SCYLLA_WRITE_INTENT_BUCKETS=512
PLAINWIRE_SCYLLA_SHADOW_SAMPLE_ROWS=200
PLAINWIRE_STORAGE_OUTBOX_INTERVAL_MS=250
PLAINWIRE_STORAGE_OUTBOX_BATCH=25
PLAINWIRE_STORAGE_OUTBOX_CONCURRENCY=8
PLAINWIRE_STORAGE_OUTBOX_RETENTION_DAYS=7
PLAINWIRE_STORAGE_OUTBOX_FAILED_RETENTION_DAYS=30
```

Outbox delivery uses bounded monitored workers (default concurrency 8) behind the Scylla partition gate, so a slow request does not serialize an entire claimed batch. Worker failures/timeouts are converted into retryable job results rather than crashing the outbox supervisor.

Failed outbox items are retained longer than delivered work for diagnosis. Neither outbox nor delivery history stores webhook secrets, bot tokens or authorization headers.

## Security

- Keep CQL native transport private to application/database networks. Do not expose port 9042 publicly.
- Use TLS with certificate verification across untrusted networks.
- Give the Plainwire runtime account only the permissions needed on the configured keyspace; do not run the app as a Scylla superuser.
- Use the migration account separately if your organization requires schema permissions to be isolated from runtime permissions.
- Plainwire uses prepared statements for runtime values. User-controlled values are not concatenated into CQL.
- Message/page limits, payload sizes and queue depth are bounded in the application before database work.
- Keep PostgreSQL, Redis and Scylla credentials in environment/secret storage and out of repository files and command-line arguments.

A typical runtime role needs `SELECT`, `MODIFY` on the Plainwire keyspace and no cluster administration privileges. The schema-migration identity additionally needs the ability to create/alter the Plainwire keyspace/tables according to your Scylla deployment policy.

## Backups

Scylla does not remove the need to back up PostgreSQL. PostgreSQL still owns accounts, memberships, permissions and integration configuration. Back up uploaded files separately as before. For Scylla, use your cluster's supported snapshot/backup procedure and test restores against the Plainwire schema and message locator table together.

## Storage benchmark harness

Benchmark the configured Scylla path against an isolated synthetic scope ID:

```sh
./scripts/storage-bench channel 9000000000000 1000 16
```

Arguments are `scope`, `scope_id`, `iterations`, and `concurrency`. The harness reports attempted/success/error counts, p50/p95/p99/max latency, elapsed time and successful throughput for inserts, recent reads, pagination, bulk lookup, event append and audit append. Insert benchmark messages are hard-deleted immediately after the timed write. Event, audit, and delivery benchmark rows use the same configured retention policy as their production tables so the benchmark does not violate TWCS single-TTL assumptions; always use a scope ID reserved for benchmarking and do not point the harness at a real room. The harness is bounded to 10,000 iterations and 64 concurrent workers.
