import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const [registry, delivery, hub, ws, clusterLocal, cluster, clusterPartisan, redis, rate, db, sup, makefile, load, liveLoad, env, rebar, lock] = await Promise.all([
  readFile('src/pw_realtime_registry.erl', 'utf8'),
  readFile('src/pw_realtime_delivery.erl', 'utf8'),
  readFile('src/pw_hub.erl', 'utf8'),
  readFile('src/pw_ws.erl', 'utf8'),
  readFile('src/pw_cluster_local.erl', 'utf8'),
  readFile('src/pw_cluster.erl', 'utf8'),
  readFile('src/pw_cluster_partisan.erl', 'utf8'),
  readFile('src/pw_redis.erl', 'utf8'),
  readFile('src/pw_rate.erl', 'utf8'),
  readFile('src/pw_db.erl', 'utf8'),
  readFile('src/pw_sup.erl', 'utf8'),
  readFile('Makefile', 'utf8'),
  readFile('tools/load/pw_load_sim.erl', 'utf8'),
  readFile('tools/load/live_load.py', 'utf8'),
  readFile('.env.example', 'utf8'),
  readFile('rebar.config', 'utf8'),
  readFile('rebar.lock', 'utf8'),
]);

assert.match(registry, /pw_rt_subscriptions/);
assert.match(registry, /pw_rt_pid_subscriptions/);
assert.match(registry, /\{write_concurrency, auto\}/);
assert.match(registry, /relay_signal\/6/);
assert.match(registry, /sync_room\/3/);
assert.match(registry, /pw_rt_room_index/);
assert.match(registry, /ets:lookup\(\?RTC_ROOM_TAB, \{Kind, Id\}\)/, 'RTC activity fans out by exact room key instead of scanning every RTC member');
assert.match(registry, /pw_rt_presence_watchers/);
assert.match(registry, /replace_presence_watch\/2/);
assert.match(registry, /erlang:monitor\(process, Pid\)/, 'registry independently monitors socket processes');

assert.match(clusterLocal, /pw_realtime_registry:send_user/);
assert.match(clusterLocal, /pw_realtime_registry:broadcast/);
assert.match(clusterLocal, /unavailable -> gen_server:cast\(pw_hub/, 'registry restart has a legacy delivery fallback');

const degradedDeliveryStart = delivery.indexOf('\ndegraded_send_text(Pid, Payload, Type) ->');
const degradedDeliveryEnd = delivery.indexOf('\ndegraded_deliver(Pid, Payload, Type) ->');

assert.notEqual(
  degradedDeliveryStart,
  -1,
  'degraded delivery fallback must remain explicit'
);
assert.notEqual(
  degradedDeliveryEnd,
  -1,
  'degraded delivery fallback must have an explicit boundary'
);
assert.ok(
  degradedDeliveryEnd > degradedDeliveryStart,
  'degraded delivery fallback boundaries must be ordered'
);

const hotDeliveryBeforeFallback = delivery.slice(0, degradedDeliveryStart);
const degradedDelivery = delivery.slice(degradedDeliveryStart, degradedDeliveryEnd);
const hotDeliveryAfterFallback = delivery.slice(degradedDeliveryEnd);

assert.doesNotMatch(
  hotDeliveryBeforeFallback,
  /process_info\(Pid, message_queue_len\)/,
  'hot fanout must not call process_info per recipient'
);
assert.doesNotMatch(
  hotDeliveryAfterFallback,
  /process_info\(Pid, message_queue_len\)/,
  'normal delivery helpers must not call process_info per recipient'
);
assert.match(
  degradedDelivery,
  /process_info\(Pid, message_queue_len\)/,
  'registry-outage fallback may sample mailbox depth'
);
assert.equal(
  (delivery.match(/process_info\(Pid, message_queue_len\)/g) || []).length,
  1,
  'mailbox process_info sampling must remain confined to the degraded fallback'
);
assert.match(registry, /pw_rt_delivery_pending/);
assert.match(registry, /reserve_delivery\/1/);
assert.match(registry, /ack_delivery\/1/);
assert.match(delivery, /pw_realtime_registry:reserve_delivery\(Pid\)/);
assert.match(ws, /pw_realtime_registry:ack_delivery\(self\(\)\)/);
assert.match(delivery, /slow_consumers_evicted/);
assert.match(delivery, /dropped_ephemeral/);
assert.match(delivery, /exit\(Pid, \{shutdown, slow_consumer\}\)/);
assert.match(delivery, /droppable\(typing\)/);
assert.doesNotMatch(ws, /process_info\(self\(\), message_queue_len\)/, 'receiver must not repeat mailbox introspection for each delivered frame');
assert.match(ws, /PLAINWIRE_WS_MAX_CONNECTIONS/);
assert.match(ws, /ws_upgrade, global/);
assert.match(ws, /ws_upgrade, ip/);

assert.match(hub, /pw_realtime_registry:relay_signal\(voice/);
assert.match(hub, /pw_realtime_registry:relay_signal\(call/);
assert.match(hub, /pw_realtime_registry:relay_activity/);
assert.match(hub, /pw_async_pool:submit\(Tag, fun\(\) ->\s*\{pw_redis:presence_get\(Uids\), pw_redis:presence_platform_get\(Uids\)\}/);
assert.match(hub, /presence_set_many/);
assert.doesNotMatch(hub, /watchers = #\{\}/, 'presence reverse indexes must not be copied through the hub state map');
assert.match(hub, /realtime_registry_ready[\s\S]{0,350}realtime_resync/, 'registry restart asks clients to rebuild non-authoritative presence indexes');
assert.doesNotMatch(hub, /persist_missed_call\([\s\S]{0,180}\bspawn\(/, 'missed-call persistence must be bounded');

assert.match(redis, /PLAINWIRE_REDIS_POOL_SIZE/);
assert.match(redis, /redis_worker_loop/);
assert.match(redis, /command_route_key/);
assert.match(redis, /redis_pipeline/);
assert.match(redis, /presence_set_many/);
assert.match(redis, /PLAINWIRE_REDIS_SYNC_QUEUE/);
assert.match(redis, /pipeline_commands/);
assert.match(redis, /HDEL',KEYS\[1\],ARGV\[1\]/, 'presence disconnect removes only this node ownership field');
assert.doesNotMatch(redis, /EVAL[\s\S]{0,300}integer_to_binary\(length\(Keys\)\)/, 'presence reads must not issue cross-slot multi-key Lua');
assert.match(redis, /Hash commands by their Redis key/, 'async mutations must retain per-key ordering');

assert.match(cluster, /PLAINWIRE_CLUSTER_OUTBOX_LIMIT/);
assert.match(cluster, /PLAINWIRE_CLUSTER_DRAIN_BATCH/);
assert.match(cluster, /pw_cluster_seen/);
assert.match(cluster, /drain_batch/);
assert.match(cluster, /drain_scheduled/);
assert.match(cluster, /Persist the exact envelope before the first send/, 'cluster retries persist a stable envelope id');
assert.match(cluster, /case send_envelope\(events, Envelope, S1\)[\s\S]{0,900}\{error, S2\}[\s\S]{0,500}\{blocked, S2\}/, 'transport send failure keeps the head event queued');
assert.match(cluster, /PLAINWIRE_CLUSTER_RETRY_MS/, 'cluster retries are delayed rather than hot-looped');
assert.match(cluster, /send_failures/, 'transport rejection is observable separately from stale drops');
assert.match(clusterPartisan, /ack => Reliable[\s\S]{0,120}retransmission => Reliable/, 'Partisan event transport requests acknowledgement and retransmission');
assert.match(cluster, /known_peers/, 'cluster tracks prior peer boots so first discovery does not create a recovery stampede');
assert.match(cluster, /NeedsResync/, 'restarted or stale returning peers trigger authorization recovery');
assert.match(hub, /cluster_revalidate_access/, 'cluster recovery asks sockets to revalidate durable authorization');
assert.match(ws, /cluster_revalidate_access_now/, 'socket recovery performs forced authorization revalidation');
assert.match(ws, /force_revalidate_session/, 'cluster recovery bypasses the normal 60-second auth throttle');
assert.match(ws, /PLAINWIRE_CLUSTER_REVALIDATE_JITTER_MS/, 'cluster recovery spreads authorization checks instead of stampeding PostgreSQL');

assert.match(registry, /PLAINWIRE_PRESENCE_WATCH_MAX/);
assert.match(rate, /PLAINWIRE_RATE_MAX_ENTRIES/, 'high-cardinality rate state has a global bound');
assert.match(rate, /counter_admitted\(CounterKey\)/, 'novel rate keys fail closed at the cardinality ceiling');
assert.match(ws, /#\{available := true\} -> ok;[\s\S]{0,80}_ -> \{error, overloaded\}/, 'new websocket upgrades fail closed while realtime registry is unavailable');
assert.equal((registry.match(/ets:new\(\?RTC_PID_TAB,/g) || []).length, 1, 'RTC PID reverse table is created exactly once');
assert.match(cluster, /handle_info\(drain, S = #\{ready := false\}\)/, 'bounded cluster outbox is retained during a transient transport outage');

assert.match(db, /db_lane_loop\(Idx, Conn\)/);
assert.match(db, /erlang:alias\(\[reply\]\)/);
assert.match(db, /PLAINWIRE_DB_CALL_TIMEOUT_MS/);
assert.doesNotMatch(db.slice(0, 12000), /process_info\([^)]*message_queue_len/, 'DB admission uses atomic lane load rather than mailbox sampling');

for (const knob of ['PLAINWIRE_REDIS_POOL_SIZE', 'PLAINWIRE_ASYNC_MAX_QUEUE', 'PLAINWIRE_CLUSTER_OUTBOX_LIMIT', 'PLAINWIRE_HTTP_CONNECTION_SUPERVISORS', 'PLAINWIRE_WS_MAX_CONNECTIONS', 'PLAINWIRE_PRESENCE_WATCH_MAX', 'PLAINWIRE_RATE_MAX_ENTRIES', 'PLAINWIRE_CLUSTER_RETRY_MS', 'PLAINWIRE_CLUSTER_REVALIDATE_JITTER_MS']) {
  assert.match(env, new RegExp(`^${knob}=`, 'm'), `${knob} must be documented in .env.example`);
}

assert.match(sup, /pw_realtime_registry/);
assert.match(sup, /pw_async_pool/);
assert.match(rebar, /70ae2ff5d5f5740a60b3d68a5898be3edf4e4802/, 'Ranch 2.2.1 is pinned for Ranch 2.x listener semantics');
assert.match(lock, /70ae2ff5d5f5740a60b3d68a5898be3edf4e4802/, 'Ranch 2.2.1 lock matches rebar config');
assert.match(sup, /num_conns_sups => ConnSups/);
assert.match(sup, /per_connection_supervisor_limit\(MaxConnections, ConnSups\)/);
assert.match(makefile, /load:/);
assert.match(makefile, /USERS \?=/);
assert.match(load, /synthetic load/i);
assert.match(load, /slow_consumers_evicted/);
assert.match(load, /relay_signal/);
assert.match(load, /relay_activity/);
assert.match(load, /presence_watchers/);
assert.match(load, /channel_message/);
assert.match(liveLoad, /ipaddress\.ip_address\(host\)\.is_loopback/, 'live load remote-target safety uses literal IP classification');
assert.doesNotMatch(liveLoad, /gethostbyname/, 'live load safety gate must not create a DNS-rebinding window');
assert.match(liveLoad, /Refusing to load-test a non-loopback host/, 'live load refuses remote targets by default');

console.log('PASS: scalable realtime indexes, bounded backpressure, Redis pooling/pipelining, cluster burst handling, admission control, and synthetic load contracts.');
