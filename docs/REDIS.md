# Redis in Plainwire

Redis is optional. Plainwire 2.5.0 can use it as a realtime accelerator. Redis is never the durable authority. PostgreSQL is still required and remains the source of truth for accounts, relationships, memberships, permissions, uploads and other relational state; message-history durability follows `PLAINWIRE_MESSAGE_BACKEND`. Leave `PLAINWIRE_REDIS_ENABLED=false` on a normal single-node install.

Redis is used for work that benefits from shared short-lived state:

- distributed authentication/operator rate-limit gates;
- expiring presence snapshots;
- hot message/read-through caches;
- other explicitly best-effort coordination and acceleration.

The local ETS limiter remains the first gate on each node. If Redis is disabled or temporarily unavailable, Plainwire keeps the durable path available and local limits continue to apply. Redis failure must degrade acceleration, not authorization correctness.

## Worker pool and overload behavior

`pw_redis` separates its control process from dedicated Redis I/O workers. `PLAINWIRE_REDIS_POOL_SIZE` controls the worker count. Keys are routed deterministically so commands affecting the same key retain ordering while unrelated keys can execute concurrently.

Synchronous and asynchronous Redis requests have independent bounded admission queues (`PLAINWIRE_REDIS_SYNC_QUEUE` and `PLAINWIRE_REDIS_ASYNC_QUEUE`). Optional cache/presence writes may be shed when the asynchronous queue is full rather than allowing Redis latency to grow the BEAM mailbox without bound. Durable mutations must commit to their authoritative store before optional Redis acceleration is updated.

Presence refreshes are pipelined as independent single-key commands. This reduces round trips without using one multi-key Lua script that would require all user keys to share a Redis Cluster hash slot.

## Presence

Presence is stored as one expiring hash field per Plainwire node under each user key. This matters when the same account has live sessions on two nodes: one node disconnecting removes only its own field and cannot make the other session look offline. Readers prune expired node fields and combine the remaining statuses. Local realtime state wins over a Redis snapshot.

Set `PLAINWIRE_NODE_ID` to a stable unique id per runtime when operating multiple nodes; otherwise Plainwire derives one from the Erlang node name and OS process id.

## Message cache durability

A sent message is acknowledged only after its durable backend commits it. Redis must never become the only copy of a message the client believes was saved. This avoids message loss after Redis restart, eviction or failover.

The latest message window may be cached after an authoritative read. Pagination and older history continue to use the durable backend. Cache invalidation uses per-conversation generation counters so successful sends, forwards, edits, deletes, reaction changes and missed-call records make older payload keys unreachable without wildcard scans. Payloads have bounded TTLs, and a second generation check prevents an overlapping mutation from repopulating a newer generation with an older view.

## Redis Cluster note

Plainwire 2.4.0's built-in RESP client deliberately uses hash-slot-safe single-key operations, but it does **not** implement native Redis Cluster `MOVED`/`ASK` redirect discovery. Do not point it directly at an arbitrary native Redis Cluster shard endpoint. Use a normal Redis endpoint, a managed HA endpoint, or a compatible proxy/service endpoint that hides the shard topology.

This distinction matters: hash-slot-safe commands make a future cluster-aware transport possible, but they do not by themselves make the current raw RESP client a Redis Cluster client.

## Configuration

Set `PLAINWIRE_REDIS_ENABLED=true`, then configure host, port, optional ACL username/password and optional TLS variables from `.env.example`. For multiple Plainwire nodes, configure a distinct `PLAINWIRE_NODE_ID` for every runtime.

The important load controls are:

```text
PLAINWIRE_REDIS_POOL_SIZE
PLAINWIRE_REDIS_SYNC_QUEUE
PLAINWIRE_REDIS_ASYNC_QUEUE
```

Do not blindly increase them. Watch Redis latency, worker queue depth, BEAM scheduler utilization and host memory while load testing. More workers can increase Redis and network pressure without improving throughput once Redis itself is saturated.

See `docs/SCALING.md` for the larger realtime/backpressure model.
