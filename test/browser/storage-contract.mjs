import fs from 'node:fs';

const read = (p) => fs.readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');
const must = (cond, msg) => { if (!cond) throw new Error(msg); };

const rebar = read('rebar.config');
const rebarLock = read('rebar.lock');
const sup = read('src/pw_sup.erl');
const app = read('src/pw_app.erl');
const selector = read('src/pw_message_store.erl');
const scyllaStore = read('src/pw_message_store_scylla.erl');
const pgStore = read('src/pw_message_store_pg.erl');
const db = read('src/pw_db.erl');
must(db.includes('a successful Scylla read is authoritative') && db.includes('{ok, []};'),
  'successful empty Scylla history must remain authoritative and must not resurrect PostgreSQL mirror rows');
const outbox = read('src/pw_storage_outbox.erl');
const migration = read('src/pw_storage_migration.erl');
const sanitizer = read('src/pw_storage_sanitize.erl');
const health = read('src/pw_storage_health.erl');
const scylla = read('src/pw_scylla.erl');
const statements = read('src/pw_scylla_statements.erl');
const coreSchema = read('priv/scylla/001_core.cql');
const bucketSchema = read('priv/scylla/002_message_bucket_directory.cql');
const eventBuckets = read('priv/scylla/003_event_bucket_directories.cql');
const writeIntents = read('priv/scylla/004_message_write_intents.cql');
const mutableCompaction = read('priv/scylla/005_mutable_message_compaction.cql');
const compose = read('compose.yaml');
const docs = read('docs/SCYLLA.md');
const storageMigrate = read('scripts/storage-migrate');
const eventStore = read('src/pw_event_store.erl');
const auditStore = read('src/pw_audit_store.erl');
const deliveryStore = read('src/pw_delivery_store.erl');

const pinnedGitDeps = {
  cowboy: '79e3fb02b31d47af6e69e8f3ba18fba291a3072a',
  cowlib: 'c768a804565ff5b8178ed968a5921e469d6bd7b2',
  ranch: '10b51304b26062e0dbfd5e74824324e9a911e269',
  gun: '9d40b0ff2de1546e5c613205c4f25aaefffc2569',
  erlcass: 'a3f752e1a9de007b806f160a6798fb1945dc075b',
};
for (const [dep, ref] of Object.entries(pinnedGitDeps)) {
  must(rebar.includes(`{${dep}, {git,`) && rebar.includes(`{ref, "${ref}"}`), `${dep} must pin its audited release commit in rebar.config`);
  must(rebarLock.includes(`<<"${dep}">>`) && rebarLock.includes(`{ref,"${ref}"}`), `${dep} lock entry must match rebar.config`);
}
must(rebar.includes('Cowboy 2.19.0 and Gun 2.6.0 both require Cowlib 2.20.0'), 'Nine Nines dependency compatibility rationale must remain documented');
for (const mod of ['pw_storage_metrics','pw_scylla_gate','pw_scylla','pw_message_id','pw_storage_outbox','pw_storage_reconciler']) {
  must(sup.includes(`id => ${mod}`), `supervisor missing ${mod}`);
}
must(app.includes('pw_scylla_config:validate()'), 'startup must validate Scylla configuration');

must(selector.includes('postgres -> pw_message_store_pg') && selector.includes('scylla -> pw_message_store_scylla'),
  'message store selector must keep explicit PostgreSQL and Scylla backends');
must(selector.includes('dual -> pw_message_store_pg'), 'dual mode must keep PostgreSQL read authority');
for (const fn of ['get_recent','get_before','get_after','get_around','bulk_get','edit','delete']) {
  must(pgStore.includes(`${fn}(`), `PostgreSQL store missing ${fn}`);
  must(scyllaStore.includes(`${fn}(`), `Scylla store missing ${fn}`);
}
must(scyllaStore.includes('Cassandra UPDATE is an upsert') && scyllaStore.includes('{error, not_found}'),
  'Scylla edits/deletes must not resurrect missing/deleted rows');
must(scyllaStore.includes('page_scan_row_limit()'), 'Scylla history must bound raw-row scans');
must(scyllaStore.includes('{error, history_scan_limit}'), 'Scylla history must fail explicitly at scan budget');
must(scyllaStore.includes('pw_msg_bucket_touch') && scyllaStore.includes('pw_msg_buckets_recent'),
  'Scylla history must use sparse bucket directory');
must(scyllaStore.includes('transactional_upsert') && scyllaStore.includes('pending_write_intents') && scyllaStore.includes('hard_delete_at'),
  'Scylla-authoritative writes must have enumerable crash-recovery intents and direct orphan cleanup');
must(db.includes('register_tx_after_commit') && db.includes('complete_transactional_upsert'),
  'PostgreSQL transaction commit must clear Scylla write intents only after commit');
must(db.includes('commit_tx(Conn)') && db.includes('storage_commit_uncertain') && db.includes('preserving Scylla write intents'),
  'uncertain PostgreSQL COMMIT outcomes must preserve durable Scylla write intents for reconciliation');
const uncertainCommitBranch = db.slice(db.indexOf('{error, C, R, S} ->'), db.indexOf('{returned, Other} ->'));
must(uncertainCommitBranch.length > 0 && !uncertainCommitBranch.includes('run_tx_compensations()') && !uncertainCommitBranch.includes('\"ROLLBACK\"'),
  'uncertain COMMIT branch must not rollback or compensate Scylla when PostgreSQL outcome is unknowable');
must(db.includes('NeverAbandon') && db.includes('message.hard_delete') && db.includes('message.upsert'),
  'critical message upserts and privacy hard-deletes must never become terminal outbox failures');
must(db.includes('critical_outbox') && db.includes('storage_privacy_delete_pending'),
  'operator/admin diagnostics must expose critical upsert and privacy-delete backlog');
must(db.includes('MAX_MESSAGE_CACHE_DECODED_BYTES') && db.includes('external_term_decoded_size(Bin)'),
  'Redis message cache must bound compressed ETF expansion before decoding');
must(db.includes('mark_scylla_seen') && db.includes('scylla_may_have_data') && db.includes("name='scylla_seen'"),
  'privacy deletion must remember that Scylla may still contain data across a PostgreSQL rollback/temporary Scylla disable');
must(!read('src/pw_message_id.erl').includes('message_id_release_node(NodeId, Owner)'),
  'message-id shutdown must retain the short fencing lease so restarts cannot immediately reuse an ID slot after clock rollback');
const messageId = read('src/pw_message_id.erl');
must(messageId.includes('PostgreSQL is the wall-clock authority') && messageId.includes('clock_anchor_ms') && messageId.includes('erlang:monotonic_time(millisecond)'),
  'message-id runtime must anchor leased Snowflake timestamps to the PostgreSQL clock plus monotonic elapsed time');
must(db.includes('extract(epoch from clock_timestamp())') && db.includes('RETURNING node_id,lease_until,(SELECT now_ms FROM clock)'),
  'message-id node leases must return the PostgreSQL clock sample used for distributed fencing');

must(db.includes('storage_outbox') && db.includes('storage_migration_checkpoints'), 'PostgreSQL migration/outbox tables missing');
must(outbox.includes('FOR UPDATE SKIP LOCKED') || db.includes('SKIP LOCKED'), 'outbox must use bounded concurrent claiming');
must(outbox.includes('message.hard_delete'), 'outbox must support privacy hard-delete jobs');
must(outbox.includes('hard_delete_scoped') && db.includes('entity_scope') && db.includes('entity_created_at'),
  'privacy hard-deletes must retain PostgreSQL routing metadata and erase locator-less Scylla orphans');
must(scyllaStore.includes('for_timestamp(CreatedAt, Policy)') && scyllaStore.includes('[day, week, month]'),
  'locator-less privacy erase must cover every supported historical message bucket policy without an unbounded scan');
must(outbox.includes('MAX_OUTBOX_DECODED_BYTES') && outbox.includes('external_term_decoded_size'), 'outbox must bound compressed ETF expansion before decoding');
must(migration.includes('spawn_monitor'), 'backfill workers must be monitored');
must(migration.includes('operation_timeout_ms') && migration.includes('OpTimeout + 5000'),
  'backfill worker deadline must follow the configured Scylla operation timeout');
must(migration.includes('parity_scope'), 'migration must include backend behavioral parity');
must(migration.includes('shadow_sample'), 'migration must include shadow comparison');
must(migration.includes('reconcile'), 'migration must include reconciliation');
for (const [name, store] of [['event', eventStore], ['audit', auditStore], ['delivery', deliveryStore]]) {
  must(store.includes('resolve_event_identity') && store.includes('event_id_timestamp_bucket_mismatch'),
    `${name} timeline must enforce event-id/timestamp bucket alignment so cursor pagination cannot orphan rows`);
  must(store.includes('pw_message_id:decode_timestamp(EventId)'),
    `${name} timeline must derive generated event time from sortable event IDs when timestamp is omitted`);
}

must(sanitizer.includes('sensitive_key') && sanitizer.includes('sha256'), 'event payload sanitization must redact secrets and hash oversized payloads');
must(health.includes('postgresql => Pg') && health.includes('redis => Redis') && health.includes('scylla => Scylla'),
  'storage health must expose each storage system independently');
must(scylla.includes('erlcass:get_metrics()'), 'Scylla health must expose bounded driver metrics');
must(scylla.includes('handle_call(ready') && scylla.includes('gen_server:call(?MODULE, ready'),
  'Scylla hot-path readiness must not collect full driver metrics per query');
must(scylla.includes('{retry_policy, {default, false}}'), 'driver retries must remain conservative; app layer owns idempotent retries');
const gate = read('src/pw_scylla_gate.erl');
must(gate.includes('{worker_timeout, Ref}') && gate.includes('scylla_active_timeout') && gate.includes('exit(Pid, kill)'),
  'Scylla gate must actively terminate timed-out workers so in-flight capacity cannot leak');

for (const stmt of ['pw_msg_insert','pw_msg_locator_get','pw_event_insert','pw_audit_insert','pw_delivery_insert']) {
  must(statements.includes(`{${stmt},`), `prepared statement missing ${stmt}`);
}
must(coreSchema.includes('messages_by_scope_bucket') && coreSchema.includes('message_locator_by_id'), 'core Scylla message schema incomplete');
must(coreSchema.includes('TimeWindowCompactionStrategy'), 'append-oriented timeline tables must use time-window compaction');
must(mutableCompaction.includes('IncrementalCompactionStrategy') && mutableCompaction.includes('messages_by_scope_bucket'),
  'mutable canonical messages must not remain on TWCS');
must(bucketSchema.includes('message_buckets_by_scope'), 'message bucket directory schema missing');
must(eventBuckets.includes('event_buckets_by_scope') && eventBuckets.includes('audit_buckets_by_server') && eventBuckets.includes('delivery_buckets_by_server'),
  'event/audit/delivery bucket directories missing');
must(writeIntents.includes('message_write_intent_buckets') && writeIntents.includes('message_write_intents_by_bucket') && !writeIntents.includes('default_time_to_live'),
  'write-intent crash journal must be enumerable and must not silently expire');
must(migration.includes('reconcile_write_intents') && migration.includes('hard_delete_at'),
  'migration reconciler must repair committed writes and remove Scylla-only orphans');
must(compose.includes('profiles: ["scylla"]') && compose.includes('healthcheck:'), 'Scylla dev service must remain optional and health-checked');
must(docs.includes('PLAINWIRE_MESSAGE_BACKEND=dual') && docs.includes('Rollback'), 'Scylla migration/rollback documentation incomplete');

for (const failure of [
  'storage_backfill_failed',
  'storage_verify_failed',
  'storage_shadow_failed',
  'storage_parity_failed',
  'storage_intent_reconcile_failed',
  'storage_reconcile_failed',
  'storage_outbox_flush_failed'
]) {
  must(storageMigrate.includes(failure), `operator migration CLI must fail closed for ${failure}`);
}
must(outbox.includes('delivery_failures') && outbox.includes('outbox_finalize_failed'),
  'operator outbox flush must surface delivery/finalization failures');
must(outbox.includes('PLAINWIRE_STORAGE_OUTBOX_CONCURRENCY') && outbox.includes('spawn_monitor') && outbox.includes('delivery_worker_timeout'),
  'outbox must use bounded monitored parallel delivery and convert worker failure into retryable results');
must(outbox.includes('MAX_CQL_OPS_PER_DELIVERY') && outbox.includes('delivery_worker_timeout(OpTimeout)'),
  'outbox worker timeout must budget the bounded multi-operation privacy erase path');
must(outbox.includes('ClaimLimit = erlang:min(Remaining, Concurrency)') && outbox.includes('storage_outbox_claim(ClaimLimit)') && outbox.includes('drain_claims('),
  'outbox must claim only an executable concurrency wave so leases do not age before work starts');
must(db.includes("older.kind IN ('message.upsert','message.hard_delete')") && db.includes("older.entity_id=o.entity_id") && db.includes("older.status IN ('pending','running')"),
  'critical message-state outbox jobs must preserve per-message ordering so stale upserts cannot race deletes/edits');
must(db.includes('MAX_STORAGE_OUTBOX_CQL_OPS') && db.includes('?MAX_STORAGE_OUTBOX_CQL_OPS * ScyllaTimeout + 30000'),
  'PostgreSQL outbox lease must cover the bounded multi-operation privacy erase');
must(scyllaStore.includes('scylla_invalid_message') && scyllaStore.includes('scylla_malformed_message_row') && scyllaStore.includes('{error, malformed_row}'),
  'Scylla message boundary must reject malformed payloads/rows without crashing workers');
must(storageMigrate.includes('erlang:error'), 'operator migration CLI must return non-zero on logical storage failures');
const scyllaMigrate = read('scripts/scylla-migrate');
must(scyllaMigrate.includes('parse_bool') && scyllaMigrate.includes('reject_config_newlines') && !scyllaMigrate.includes("*$'\\0'*"),
  'Scylla schema tool must parse booleans consistently and must not use Bash NUL patterns that reject all values');

must(scylla.includes("{load_balance_dc_aware, {Dc, 0, false}}") && !scylla.includes('binary_to_list(Dc)'), "Scylla local DC must stay binary for erlcass 4.1.4");
console.log('PASS: storage abstraction, Scylla durability/migration, bounded pagination, health, security, and schema contracts.');
