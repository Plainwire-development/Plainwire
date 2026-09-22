# Scaling Plainwire

Plainwire 2.5.0 stays simple on a small self-hosted instance while keeping the hot paths bounded enough to grow. PostgreSQL is required. Redis and ScyllaDB remain optional. This document describes the architecture, what scales horizontally today, which limits are intentional, and how to test a host before raising them.

Capacity is workload- and hardware-dependent. The numbers in configuration are ceilings and starting points, not a promise that a particular host can sustain that many active users. Measure the real deployment with the load tools in `tools/load/` and watch the health/metrics surfaces while increasing load.

## Realtime architecture

`pw_hub` remains the authoritative control plane for connection ownership and call/room state, but ordinary high-frequency fanout is not serialized through its mailbox. `pw_realtime_registry` mirrors hot connection, subscription, presence-watch and RTC ownership indexes in concurrent ETS tables. User/topic delivery and RTC signaling use those indexes directly.

The split is intentional:

- control-plane state changes stay ordered in OTP processes;
- high-volume lookups and fanout use concurrent ETS;
- reverse indexes make disconnect cleanup proportional to the affected socket/room rather than all connected users;
- a registry restart can be rebuilt from the authoritative hub state;
- WebSocket processes are monitored so hard-killed sockets are cleaned up even when Cowboy termination does not run normally.

Plainwire 2.4.0 still supports exactly **one realtime/WebSocket owner** in the optional Partisan topology. Additional nodes may handle HTTP/API work and forward committed realtime events to that owner. Do not put `/ws` behind a round-robin pool of multiple owners in 2.4.0. The internal routing boundaries are structured so a future multi-owner gateway can be added without moving normal fanout back through `pw_hub`, but multi-owner session/call routing is not claimed by this release.

## Backpressure and overload behavior

Load must be rejected or degraded before it becomes unbounded memory use.

WebSocket delivery uses an atomic outstanding-delivery reservation per socket. At `PLAINWIRE_WS_SOFT_QUEUE`, disposable events such as typing/presence/activity may be shed. At `PLAINWIRE_WS_HARD_QUEUE`, a persistently slow consumer is disconnected. Durable data is still stored in its authoritative backend and can be reloaded after reconnect; ephemeral hints are intentionally best-effort.

Connection admission has separate limits for:

- the Ranch HTTP listener (`PLAINWIRE_HTTP_MAX_CONNECTIONS`);
- active Plainwire WebSockets (`PLAINWIRE_WS_MAX_CONNECTIONS`);
- per-IP WebSocket upgrade bursts (`PLAINWIRE_WS_UPGRADES_PER_IP_MIN`);
- global WebSocket upgrade bursts (`PLAINWIRE_WS_UPGRADES_GLOBAL_MIN`).

Ranch 2.2.1 is pinned because Plainwire uses Ranch 2.x connection-supervisor semantics. Ranch applies `max_connections` per connection supervisor, so Plainwire divides the configured listener-wide target across `PLAINWIRE_HTTP_CONNECTION_SUPERVISORS` internally instead of multiplying the operator's intended ceiling. The value remains a soft admission ceiling because accepts are concurrent.

Presence watches are capped by `PLAINWIRE_PRESENCE_WATCH_MAX` at both the WebSocket parser and realtime-registry boundary. This keeps a single connection from creating unbounded high-cardinality ETS relationships. Fixed-window rate state is separately capped by `PLAINWIRE_RATE_MAX_ENTRIES`; once that global ETS budget is full, novel rate-limit keys fail closed while existing keys continue to update until normal garbage collection frees space.

Background work that does not belong on a realtime process is routed through `pw_async_pool`, whose worker count and waiting queue are bounded by `PLAINWIRE_ASYNC_WORKERS` and `PLAINWIRE_ASYNC_MAX_QUEUE`.

## PostgreSQL

PostgreSQL remains the relational authority. The database pool uses one lightweight BEAM lane process per PostgreSQL connection. A lane owns and serializes its connection, which preserves transaction isolation without a global lock-manager hop on each query.

Admission uses atomic per-lane queued+executing counters and power-of-two selection. `PLAINWIRE_DB_MAX_QUEUE` caps work admitted to each lane. A timed-out caller does not release its reservation while PostgreSQL is still executing the query, so overload accounting remains truthful. OTP process aliases prevent late replies from leaking into long-lived caller mailboxes after a timeout.

`PLAINWIRE_DB_STATEMENT_TIMEOUT_MS` should normally be below `PLAINWIRE_DB_CALL_TIMEOUT_MS`. Tune pool size against PostgreSQL's real `max_connections`, leaving room for migrations, maintenance and other services. More database connections are not automatically faster.

Migration 49 adds a partial index for the per-channel/per-author recent-message path used by slowmode enforcement. Avoid adding speculative indexes to the message table: every additional index also increases write cost.

## Redis

Redis is optional and non-authoritative. Plainwire uses a scheduler-aware pool of Redis I/O workers rather than one serialized socket. Same-key commands are routed to the same worker so mutation ordering is preserved. Presence refresh writes are pipelined and cache/presence async queues are bounded; under overload Plainwire may shed optional accelerator work rather than growing an unlimited mailbox.

Cross-node presence uses one expiring hash field per Plainwire node, so one node disconnecting cannot erase another node's online state. Multi-user presence reads use independent single-key operations and are safe with hash-slot partitioning.

The built-in RESP client does **not** implement Redis Cluster `MOVED`/`ASK` redirect discovery in 2.4.0. Point it at a normal single Redis endpoint (including a managed/HA endpoint or compatible proxy that hides topology) rather than directly at a native Redis Cluster shard endpoint. See `docs/REDIS.md`.

## Cluster event transport

API-node fanout uses a bounded ETS outbox. `PLAINWIRE_CLUSTER_OUTBOX_LIMIT` caps memory, `PLAINWIRE_CLUSTER_DRAIN_BATCH` caps work per drain turn, and `PLAINWIRE_CLUSTER_EVENT_MAX_AGE_MS` expires notifications that are no longer useful. The default event lifetime is 12 seconds and the hard configuration ceiling is 15 seconds, matching the authenticated cluster-wire replay window. A transient transport outage keeps the bounded outbox instead of immediately discarding every queued event. If the transport rejects a send, Plainwire keeps the ordered head event and retries it after `PLAINWIRE_CLUSTER_RETRY_MS` using the **same envelope identity**, so an ambiguous retry is harmless at the realtime owner. Partisan event sends also request acknowledgement/retransmission; heartbeats remain disposable. Duplicate-envelope tracking is bounded by `PLAINWIRE_CLUSTER_DEDUP_LIMIT`.

This is intentionally not a durable message queue. The durable database remains the recovery path. Reconnect/resync reloads committed state.

## Calls, screen sharing and Cloudflare TURN

TURN and an SFU solve different problems. Cloudflare TURN gives Plainwire a globally operated relay path when peers cannot connect directly, but it does not change Plainwire 2.4.0's full-mesh WebRTC topology.

For a room of `N` participants, a full mesh has `N * (N - 1) / 2` peer relationships and each sender may upload to `N - 1` peers. The default participant/share limits exist to protect client CPU/uplink and are not merely server limits. Large voice/video rooms or thousands of users simultaneously participating in large calls should move to an SFU architecture. `pw_media_topology` is the explicit boundary for that future implementation; 2.4.0 reports `mesh` and does not fake an SFU backend.

Cloudflare TURN removes the need to operate a large TURN fleet yourself, but load testing must still include client media CPU, uplink/downlink and relay bandwidth. The included Plainwire load harness exercises RTC **control-plane** signaling/activity/state. It does not synthesize encoded RTP/video/screen traffic.

## Host tuning

Before a large test, run:

```sh
make load-doctor USERS=10000
```

The preflight checks file-descriptor limits, CPU/RAM visibility, listen backlog, local ephemeral-port range, and the BEAM process limit when Erlang is installed. For large network tests, run the generator on a different machine so client-side ephemeral ports, CPU and file descriptors do not become the result you are measuring.

The example `ERL_FLAGS` includes a large process limit and scheduler/thread settings intended as a starting point for a busy host. Do not copy host/kernel tuning blindly; measure scheduler utilization, run queue, memory, socket counts and database/Redis latency on the actual machine.

## Load testing

There are two complementary harnesses.

### In-process BEAM stress

```sh
make load USERS=1000
make load USERS=10000 DURATION=120 RATE=40000
make load-25000 DURATION=300 RATE=75000
make load-soak USERS=10000
```

This runs tens of thousands of fake socket processes directly against Plainwire's realtime registry and delivery code without wasting most of the generator on browsers or TCP. The scenario includes server/channel subscriptions, direct and channel fanout, presence watches, RTC rooms/signaling/activity, deliberately slow consumers, and reconnect-sensitive indexes. It reports operations/sec, delivery/drop/eviction counters, mailbox percentiles, outstanding-delivery reservations and memory growth.

This test requires a compiled Erlang backend.

### Live HTTP/WebSocket stress

Create a JSONL session fixture containing test-only Plainwire sessions, then run:

```sh
python -m pip install -r tools/load/requirements.txt
make load-live USERS=1000 DURATION=120 RATE=4000 \
  LOAD_BASE_URL=http://127.0.0.1:8080 \
  LOAD_SESSIONS_FILE=/secure/path/load.sessions.jsonl
```

The live harness opens real authenticated WebSockets, subscribes, watches presence, joins configured voice rooms, emits activity/control traffic and can post durable channel messages. It measures WebSocket connection success/latency, HTTP latency/statuses and error rates. It refuses non-loopback targets unless `LOAD_ALLOW_REMOTE=1` or `--allow-remote` is explicitly supplied. Only use that override against infrastructure you own and have permission to stress.

Never commit the session fixture. Treat load-test cookies and CSRF tokens as production credentials.

### Typed Gleam model

`tools/load/gleam` models workload profiles, gateway/headroom planning, queue budgets, traffic classes, sharding plans and mesh-media cost with typed inputs. It is a planning/verification layer, not a new Plainwire runtime dependency.

```sh
make load-gleam-check
```

CI pins Gleam and checks/formats the model. The production server remains Erlang/OTP.

## What to watch during a ramp

Increase concurrency in steps rather than jumping directly to the intended ceiling. Watch at least:

- WebSocket connection count and upgrade rejection rate;
- realtime `delivered`, `dropped_ephemeral` and `slow_consumers_evicted` counters;
- BEAM memory, scheduler utilization, run queues and process count;
- PostgreSQL pool admission, slow-query logs, lock waits and statement timeouts;
- Redis latency, worker queue saturation and reconnects;
- cluster outbox depth/drop count if API nodes are enabled;
- upload inflight bytes/concurrency;
- call-room sizes, TURN use and client media quality;
- HTTP/WS p50/p95/p99 latency and 5xx rate.

A capacity test passes only when latency, memory and queue depth stabilize for the duration of the soak. A test that reaches the target user count while queues continually grow is a delayed outage, not a pass.

## Failure drills

Before raising a public instance's capacity target, test at load while deliberately:

- restarting Redis;
- blocking Redis temporarily;
- exhausting a bounded DB lane queue;
- restarting an API node;
- interrupting the optional Partisan transport;
- reconnecting a large percentage of WebSockets at once;
- introducing slow clients;
- making webhook/AI endpoints slow or unavailable;
- making TURN unavailable for test users;
- restarting the single realtime owner and verifying clients recover durable state.

The last operation necessarily ends current 2.4.0 realtime sessions/calls because automatic realtime-owner failover is not implemented. Document that limitation in production operations rather than pretending otherwise.

### Cluster recovery authorization sweep

When a previously known API peer restarts or returns after its heartbeat lease goes stale, the realtime owner emits `realtime_resync` and asks every connected socket to revalidate its session, subscriptions, and media-room access against PostgreSQL. `PLAINWIRE_CLUSTER_REVALIDATE_JITTER_MS` (default 10000, maximum 30000) spreads those checks across a bounded window so a large deployment does not create a synchronized database reconnect/revalidation storm. First discovery of a configured peer does not trigger the sweep.
