# Optional Partisan routing

The default backend is local OTP messaging. Partisan is downloaded only with the `cluster` build profile. It is an optional deployment candidate, not enabled by installing the source archive.

The supported topology is deliberately narrow: **one WebSocket/call owner plus additional HTTP API nodes**. All `/ws` traffic must go to the owner. API nodes reject WebSockets with 503. Presence, subscriptions, room membership, call signaling and session connection ownership remain in `pw_hub` on the owner. This release does not distribute media, split a voice room across nodes, automatically elect a replacement owner, or preserve calls when the owner fails.

After PostgreSQL operations, API nodes route eligible user/topic events through the Plainwire-owned `pw_cluster` interface. PostgreSQL remains authoritative for relational state such as sessions, memberships, permissions and invitations. Message history follows `PLAINWIRE_MESSAGE_BACKEND`: PostgreSQL in `postgres`/migration-read mode, and ScyllaDB after the documented storage cutover. Redis remains ephemeral. Cluster mode bypasses the per-node HTTP session cache so revocation is checked against the database. All nodes must share the same database, encryption/media keys, origin configuration, release and durable upload storage. Budget database pool sizes across nodes. Complete migrations on the first node before starting others.

## Build and configure

The pinned Partisan revision is `45474ceb710dafa91a4af2dc87b34512354f6ba8` (6.2.0). It requires OTP 27+ **with OTP sources installed**, because its build transforms OTP modules. The standard 2.0 dependency set also requires OTP 27+. The optional Partisan profile additionally requires installed OTP sources; exercise its two-node TLS topology in staging before enabling it in production.

```sh
npm ci
npm run build
rebar3 as cluster compile
rebar3 as cluster eunit
rebar3 as cluster release
```

Adapt `deploy/cluster.config.example` into the release's `sys.config` on each node. Load Partisan without starting it independently; Plainwire configures TLS before starting its listeners. The cluster release profile uses the `load` startup mode for that reason. Never put API keys or private certificates into the frontend.

Use explicit private/loopback addresses, a dedicated private CA, separate node certificates, and a firewall allowlist for the configured cluster ports. The server requires client certificates and the client verifies its peer's CA chain. All holders of certificates signed by this CA are trusted cluster operators; this is not a multi-tenant security boundary. Do not share that CA with untrusted workloads. No plaintext fallback is configured.

An unnamed Erlang VM works with the configured Partisan name. If the release starts a named VM, its `-name`/`-sname` identity must equal the configured name, and its VM arguments must contain `-dist_listen false`. Also set `-start_epmd false`. Do not expose EPMD or native distribution. Plainwire rejects a named runtime that could accidentally open a separate distribution listener.

## Delivery and failure behavior

The realtime channel carries leases; the events channel carries eligible fanout. Local delivery never waits for either. The local outbox caps at 256 events, payloads at 128 KiB, and event lifetime at 15 seconds. There is no durable queue or retry storm. Envelopes include a node name, boot nonce and sequence; the owner checks configured origins, sizes, term shape, event types, expiry and duplicates. The duplicate cache is bounded. Heartbeat gaps and node restarts request client resynchronization from PostgreSQL. In-flight live notifications can be lost during failure or overload; reloading/rejoining reloads durable state.

Use `pw_cluster:status()` to inspect readiness, membership, queue depth and sent/received/drop counters. It contains no credentials. A restart can reuse only the Partisan instance previously configured by Plainwire. Losing Partisan does not crash local chat or calls. Losing the call owner ends its live sessions; restart it and let clients reconnect.

Before enabling: verify private listeners and native-distribution shutdown; reject clients with no certificate and an unrelated CA; deliver a committed API-node message to an owner-connected browser; disconnect and restart each node; check duplicate/stale rejection, resync and queue limits; verify revoked sessions and unauthorized subscriptions stay rejected. Unit transport fixtures cover routing boundaries but do not substitute for this live staging check.

Reference: [Partisan API](https://partisan.hexdocs.pm/partisan.html), [configuration](https://partisan.hexdocs.pm/partisan_config.html).
