# Optional Partisan routing

The default backend is local OTP messaging. Partisan is downloaded only with the `cluster` build profile. It is an optional deployment candidate, not enabled merely by installing the source archive.

The supported 2.5.0 topology is deliberately narrow: **one realtime/WebSocket/call owner plus optional HTTP API nodes**. All `/ws` traffic must go to the realtime owner. API nodes reject WebSockets with 503. This release does not distribute a live voice room across owners, automatically elect a replacement realtime owner, or preserve active calls when that owner fails.

On the realtime owner, `pw_hub` remains the ordered control plane while `pw_realtime_registry` mirrors hot connection, subscription, presence-watch, RTC and call-audience indexes in concurrent ETS. Ordinary fanout and RTC routing use those indexes instead of serializing every delivery through the hub mailbox. This is a performance boundary inside the owner; it is **not** a claim that 2.5.0 supports multiple realtime owners.

After committed durable operations, API nodes route eligible user/topic events through Plainwire's `pw_cluster` interface. PostgreSQL remains authoritative for relational state. Message history follows `PLAINWIRE_MESSAGE_BACKEND`; Redis remains ephemeral. Cluster mode bypasses the per-node HTTP session cache so revocation is checked against the database. All nodes must share the same database, encryption/media keys, origin configuration, release and durable upload storage. Budget database pool sizes across all nodes. Complete migrations on the first node before starting others.

## Build and configure

The pinned Partisan revision is `45474ceb710dafa91a4af2dc87b34512354f6ba8` (6.2.0). It requires OTP 27+ with OTP sources installed because its build transforms OTP modules. The standard dependency set also requires OTP 27+. Exercise the two-node TLS topology in staging before enabling it in production.

```sh
npm ci
npm run build
rebar3 as cluster compile
rebar3 as cluster eunit
rebar3 as cluster release
```

Adapt `deploy/cluster.config.example` into the release's `sys.config` on each node. Load Partisan without starting it independently; Plainwire configures TLS before starting its listeners. The cluster release profile uses the `load` startup mode for that reason. Never put API keys or private certificates into the frontend.

Use explicit private/loopback addresses, a dedicated private CA, separate node certificates and a firewall allowlist for cluster ports. The server requires client certificates and the client verifies its peer CA chain. Holders of certificates signed by this CA are trusted cluster operators; this is not a multi-tenant security boundary. Do not share that CA with untrusted workloads. No plaintext fallback is configured.

An unnamed Erlang VM works with the configured Partisan name. If the release starts a named VM, its `-name`/`-sname` identity must equal the configured name and its VM arguments must contain `-dist_listen false`. Also set `-start_epmd false`. Do not expose EPMD or native distribution. Plainwire rejects a named runtime that could accidentally open a separate distribution listener.

## Delivery and failure behavior

The realtime channel carries leases; the events channel carries eligible fanout. Local delivery never waits for either. The cluster outbox is an ETS-backed bounded buffer:

- `PLAINWIRE_CLUSTER_OUTBOX_LIMIT` (default 8192) caps retained events;
- `PLAINWIRE_CLUSTER_DRAIN_BATCH` (default 128) bounds work per drain turn;
- `PLAINWIRE_CLUSTER_EVENT_MAX_AGE_MS` (default 30000) expires stale notifications;
- `PLAINWIRE_CLUSTER_DEDUP_LIMIT` (default 262144) bounds duplicate-envelope tracking.

A temporary transport outage retains the bounded outbox and periodically retries draining. A rejected send keeps the ordered head row and reuses its exact signed envelope identity on retry; the realtime owner therefore deduplicates an ambiguous duplicate. Event-channel Partisan sends request acknowledgement/retransmission, while heartbeats remain best-effort. `PLAINWIRE_CLUSTER_RETRY_MS` bounds retry cadence. The event lifetime defaults to 12 seconds and is hard-capped at 15 seconds to stay inside the cluster-wire replay window. If the bounded outbox fills, overload is surfaced/dropped rather than consuming arbitrary memory. Durable state remains the recovery path: reconnect/resync reloads committed state, including after outages longer than the realtime event window.

Envelopes include node identity, boot nonce and sequence. The realtime owner checks configured origins, sizes, term shape, event types, expiry and duplicates. Heartbeat gaps and node restarts request client resynchronization from durable state. In-flight live notifications can still be lost during failure or overload; that is an intentional property of this non-durable fanout layer.

Use `pw_cluster:status()` to inspect readiness, membership, queue depth and sent/received/drop counters. It contains no credentials. Losing Partisan does not crash local chat/calls. Losing the single realtime owner ends its current realtime sessions/calls; clients must reconnect. Automatic owner failover is not implemented in 2.4.0.

Before enabling: verify private listeners and native-distribution shutdown; reject clients with no certificate and an unrelated CA; deliver a committed API-node message to an owner-connected browser; disconnect/restart each node; check duplicate/stale rejection, bounded outage behavior and resync; verify revoked sessions and unauthorized subscriptions remain rejected. Unit fixtures do not substitute for that live staging check.

See `docs/SCALING.md` for load/backpressure architecture.

Reference: [Partisan API](https://partisan.hexdocs.pm/partisan.html), [configuration](https://partisan.hexdocs.pm/partisan_config.html).

## Recovery authorization revalidation

A cluster outbox is intentionally bounded and signed envelopes have a bounded replay lifetime. If a previously known API peer restarts or returns after going stale, the realtime owner therefore performs a second safety step: connected sockets revalidate their current durable authorization state. The checks are jittered over `PLAINWIRE_CLUSTER_REVALIDATE_JITTER_MS` (default 10 seconds) to protect PostgreSQL from a thundering herd. This closes the gap for access revocations that legitimately aged out during a longer partition without forcing every WebSocket to reconnect at once.
