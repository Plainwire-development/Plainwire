# Redis in Plainwire

Plainwire 2.0 can use Redis as an optional real-time accelerator. Redis is never a durable authority. PostgreSQL is still the source of truth for accounts, relationships, memberships, permissions, uploads and other relational state; message-history durability follows `PLAINWIRE_MESSAGE_BACKEND` (`postgres`/`dual` use PostgreSQL authority during migration, while `scylla` uses ScyllaDB for the canonical high-volume timeline).

Redis is used for three jobs that benefit from shared in-memory state without risking durable data:

- cross-node authentication and operator-login rate-limit gates;
- short-lived presence snapshots, refreshed while a websocket session is online;
- the hot latest-message window for active DMs and server text channels.

The existing ETS limiter remains the first gate on every node. Redis is a second distributed gate on sensitive authentication paths. If Redis is unavailable, the local limiter still applies and Plainwire continues operating.

Presence is stored as one expiring hash field per Plainwire node under each user key. This matters when the same account has live sessions on two nodes: one node disconnecting removes only its own field and cannot make the other session look offline. Readers prune expired node fields atomically and combine the remaining statuses. Local hub state always wins over a Redis snapshot. Set `PLAINWIRE_NODE_ID` to a stable unique id per runtime when operating multiple nodes; otherwise Plainwire derives one from the Erlang node name and OS process id.

## Why messages are not written Redis-first

A sent message is acknowledged only after PostgreSQL commits it. Redis must never become the only copy of a message that the client believes was saved. This avoids message loss after Redis restart, eviction or failover.

The latest 80-message window is cached only after PostgreSQL has successfully returned it. The cache is per viewer because reaction metadata contains viewer-specific state. Pagination and older history continue to read PostgreSQL directly.

Message cache invalidation uses a per-conversation generation counter. Successful sends, forwards, edits, deletes, reaction changes, and missed-call records bump that generation after the durable mutation commits. Cached payload keys include the generation, so old entries become unreachable in O(1) without `KEYS`, wildcard scans, or synchronous deletion of every viewer cache entry. Payloads have a short TTL and the generation key outlives them, preventing an expired generation from reviving stale generation-zero data. A second generation check after a database read prevents an overlapping mutation from populating the new generation with an older view.

`pw_redis` also exposes a small generic cache primitive for other read-through caches. Durable callers must always commit PostgreSQL first and treat Redis failures as cache misses.

## Configuration

Set `PLAINWIRE_REDIS_ENABLED=true`, then configure host, port, optional Redis ACL username/password, and optional TLS variables from `.env.example`. For a multi-node deployment, also set a distinct `PLAINWIRE_NODE_ID` for each running Plainwire node.

Redis is deliberately optional. A healthy Plainwire deployment must still boot when Redis is down or not configured.
