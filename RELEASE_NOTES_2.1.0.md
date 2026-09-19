# Plainwire 2.1.0

Plainwire 2.1.0 is a feature and hardening release focused on first-class bot development, privacy-preserving message search, host-level account moderation, server automation, message pinning and navigation, channel quality-of-life controls, bot identity UX, spoiler attachments, and safer encryption-key operations. Existing 2.0 bot endpoints and normal chat behavior remain supported.

## Bot API v1

Plainwire now exposes a stable, language-neutral bot API under `/api/bot/v1` while keeping the existing `/api/bot/*` routes compatible.

The v1 API includes:

- bot capability and rate-limit discovery;
- bot identity, server and channel discovery;
- message history, send, delete and reaction operations;
- durable command registration;
- server command discovery for clients;
- durable command invocation queues;
- bounded batch claiming with lease tokens;
- idempotent command responses;
- explicit permanent failure acknowledgement;
- bounded retry attempts for abandoned claims;
- Redis-coordinated rate limits when Redis is available;
- normal Plainwire roles and channel permissions for every bot operation.

Command claim tokens are stored only as hashes. Command arguments are encrypted before durable storage. A bot that disappears while processing a command does not lose the invocation. The lease expires and another worker can claim the job.

First-party SDKs are included for C, C++, Go, Rust, Erlang, Python and JavaScript. They all use the same HTTP API and security model. Remote plaintext HTTP is rejected by the new SDKs; loopback HTTP remains available for local development.

See `docs/BOTS.md` and the README in each directory under `sdk/`.

## Bot identity and commands in the client

Bot accounts are now represented consistently throughout the client with a compact `BOT` badge. The badge follows the existing Plainwire pill styling and appears next to bot identities in messages, member/profile surfaces and bot-related UI.

Server channels can expose registered commands directly in the composer. Typing `/` shows matching commands. Selecting a command inserts it into the composer. Sending a registered command creates a normal visible command message and enqueues a durable invocation for the owning bot. Unknown slash-prefixed text remains a normal message, preserving existing behavior.

Server-scoped bot users are excluded from the global people search so they are not presented as ordinary friendable accounts.


## Developer applications and hosted command handlers

2.1.0 also adds a first-class Developer Applications layer above server-scoped bot installations. Application owners can define reusable command templates, publish an application to the opt-in public directory, install it into servers where the installer has **Manage bots**, rotate installation credentials, and configure per-command channel/role/member restrictions. Public directory responses deliberately omit owner-private connector metadata and secrets.

Commands can use one of three handlers: the existing SDK queue, a signed HTTPS interaction endpoint, or an optional OpenAI-compatible AI connector. Signed interactions use HMAC-SHA256 over the timestamp and JSON payload, bounded request/response sizes, bounded retries and worker concurrency, and DNS-rebinding-resistant outbound connections. Remote application endpoints are HTTPS-only; plaintext application HTTP is available only for explicit loopback development with `PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP=true`. Redirects are not followed.

AI connector API keys and system prompts are encrypted at rest. Plainwire sends the invoked command and its arguments to the configured AI endpoint; it does not fetch channel history for hosted AI command execution. Per-application rate limits and global AI worker concurrency are bounded. Disabling or uninstalling a handler prevents new claims. Claim-time authorization rechecks both bot access and the invoking user's current channel/command permission before encrypted command arguments are decrypted for any SDK, interaction, or AI worker.

## Message pinning and reply navigation

Text channels now support first-class pinned messages. Members with **Manage messages** can pin or unpin up to 50 messages per channel. Pin state is durable, permission-checked on the server, reflected through realtime events, and available to outbound webhooks.

Clicking the compact replied-message preview now jumps to the referenced message and highlights it briefly. If the target is outside the currently loaded window, Plainwire fetches a bounded, authorized context around that exact message rather than loading an unbounded history. While historical context is open, new realtime messages do not yank the viewport back to the bottom; the client shows that newer messages are available and provides a **Latest** action to return to the live tail.

Deleted messages disappear from pin listings through database referential cleanup. Reply-context reads use the same channel or DM read authorization as normal history.

## Channel quality of life

Server channel settings now include editable channel name, topic and slowmode. Slowmode supports values from off through six hours. Ordinary members are serialized per user/channel with a PostgreSQL transaction advisory lock, so simultaneous sends through multiple Plainwire application nodes cannot race around the delay. Bots and members with **Manage messages** bypass slowmode for automation and moderation work.

Channel changes are broadcast through the existing server realtime stream and can be delivered as `channel.updated` outbound webhook events.

## Incoming and outgoing server webhooks

Plainwire now has two intentionally different server webhook models.

**Incoming channel webhooks** are revocable, write-only URLs bound to one text channel. Each webhook uses a dedicated server-scoped bot identity and receives the normal bot badge. The credential is generated once, stored only as a hash, and can be rotated without recreating the webhook. Incoming hooks cannot reuse another user's existing upload references, cannot read channel history, and a successful post returns only the new message id, destination channel id and timestamp. Both per-webhook and per-webhook/source-IP shared rate limits are enforced.

**Outbound webhooks** now cover message pinning, channel changes and bot lifecycle events in addition to the existing message/member/server event set. The Integrations UI can inspect recent delivery metadata and explicitly retry failed deliveries when the retained payload is still available. Delivery payloads retained for retry are AES-GCM encrypted at rest, successful payloads are erased, and new or rotated signing secrets are encrypted at rest. Existing 2.0 plaintext signing-secret rows remain readable for a seamless upgrade and are converted when rotated.

See `docs/WEBHOOKS.md` for the full event catalog, signing rules, retry behavior and incoming webhook API.

## Privacy-preserving message search

Plainwire now supports message search without creating a plaintext search copy of message bodies.

- message bodies remain encrypted at rest with AES-256-GCM;
- search terms are represented by keyed HMAC blind-index tokens;
- the search index stores only opaque keyed tokens and message ids;
- every candidate is checked against the caller's current channel or DM permissions before the message body is loaded;
- deleted messages lose their search-index entries;
- search work is bounded to prevent common terms from causing unbounded database scans;
- a background reconciler safely backfills existing messages;
- changing the search key fingerprint automatically invalidates and rebuilds the index.

Search is intentionally exact-token based rather than a plaintext ranking index. The host control plane does not receive a private-message search endpoint.

## Encryption key rotation

`PLAINWIRE_ENC_PREVIOUS_KEYS` can contain a bounded comma-separated list of previous 32-byte base64 encryption keys. New durable content is encrypted with `PLAINWIRE_ENC_KEY`; decrypt operations try the primary key first and then the configured previous keys.

`PLAINWIRE_SEARCH_KEY` may be configured independently for blind-index search. When it is omitted, Plainwire derives a dedicated search key from the primary encryption key. `PLAINWIRE_MEDIA_SIGNING_KEY` may likewise be set independently for proxied-media signatures.

Invalid configured keys fail validation rather than silently falling back to an unrelated key.

Plainwire messages are encrypted at rest, but Plainwire 2.1.0 is not end-to-end encrypted. The server must be able to decrypt messages to provide normal server-side behavior such as moderation, delivery and search.

## Calls and realtime security

Plainwire continues to use browser WebRTC DTLS-SRTP for encrypted call media. Production TURN requirements, short-lived TURN credentials, TLS verification, relay-only privacy policy and authenticated realtime signaling remain intact.

Bot WebSocket sessions remain deliberately narrower than user sessions. Bots can manage their subscriptions and receive permitted realtime events but cannot impersonate normal client typing, voice or call-state operations.

## Spoiler attachments

The composer can mark the latest attachment as a spoiler without changing the attachment upload format. Spoiler attachment markup renders as an accessible native disclosure control and can be revealed by keyboard or pointer input. Ordinary attachments continue to render exactly as before.

## Host-level account moderation

The service control plane can now suspend, ban and restore Plainwire accounts across the hosted instance.

Moderation actions support:

- a custom user-facing title;
- a required bounded reason;
- `info`, `warning` or `critical` presentation severity;
- optional expiration;
- immediate normal-session revocation;
- immediate admin-session revocation;
- realtime disconnect/restriction notification;
- presence cleanup;
- content-free moderation history and host audit records.

Restricted users receive a dedicated account-state screen during an active session and on later login attempts. Expired restrictions are restored automatically when authentication is attempted.

The privilege hierarchy is enforced by the backend. Operators cannot moderate control-plane operators, owners cannot moderate another owner, and nobody can use the moderation endpoint against their own operator account. Restricted accounts cannot authenticate into the control plane or redeem operator enrollment while restricted.

The host control plane remains content-blind. These moderation features do not add message-body, DM-text, attachment-content or private-message-search access.

## Scalability and overload hardening

The 2.1.0 release candidate received a dedicated high-concurrency architecture pass so normal growth does not require routing every realtime event through one giant mailbox or allowing dependent-service stalls to grow unbounded work. The goal is bounded, observable degradation under pressure rather than a synthetic concurrency number.

- high-volume user/topic fanout and RTC routing use concurrent ETS indexes instead of serializing ordinary delivery through `pw_hub`;
- reverse RTC/subscription indexes make disconnect cleanup proportional to the affected socket/rooms;
- WebSocket delivery uses atomic outstanding reservations, sheds disposable typing/presence/activity work at a soft limit, and evicts persistently slow consumers at a hard limit;
- WebSocket admission has listener, active-socket, global-upgrade and per-source limits;
- presence-watch cardinality is bounded at both parser and registry boundaries;
- Redis uses a bounded worker pool with same-key ordering and pipelined single-key presence refreshes rather than one synchronous I/O bottleneck;
- the Partisan event outbox is bounded, batched, deduplicated and expiry-aware and retains a bounded backlog through transient transport loss;
- PostgreSQL connections are owned by dedicated lane processes with bounded atomic admission and transaction serialization, avoiding a global lock-manager hop per normal query;
- caller timeouts do not release DB capacity while PostgreSQL work is still executing, and OTP process aliases prevent late replies from accumulating in caller mailboxes;
- non-realtime background work uses a bounded asynchronous worker pool;
- Ranch connection-supervisor configuration now treats the operator connection limit as an approximate listener-wide target rather than unintentionally multiplying it per supervisor;
- Ranch is pinned to 2.2.1 so those connection-supervisor semantics and `num_conns_sups` are actually provided by the locked dependency;
- fixed-window rate-limit ETS state has a configurable global cardinality cap so attacker-controlled key diversity cannot grow the limiter without bound;
- clustered event retries preserve a stable envelope identity, remain ordered, retry with bounded cadence and stay inside the signed replay window instead of discarding transport-level failures;
- the media layer has an explicit topology boundary. 2.1.0 remains full-mesh WebRTC and does not claim an SFU implementation; Cloudflare TURN remains compatible but is not presented as an SFU;
- `make load`, `make load-live`, `make load-doctor` and the typed Gleam capacity model provide repeatable stress/capacity tooling for future releases.

Plainwire 2.1.0 still intentionally supports one realtime/WebSocket owner in the optional clustered topology. This hardening removes internal hot-path bottlenecks and creates routing boundaries for future multi-owner work; it does not enable unsafe pseudo-horizontal WebSocket ownership before session/call routing is coherent. See `docs/SCALING.md`.

## Database migrations

2.1.0 adds migrations 40 through 49:

- migration 40: blind-index message-search state and token tables;
- migration 41: bot command definitions and durable command invocation queue;
- migration 42: account moderation fields and instance moderation history;
- migration 43: durable per-channel message pins;
- migration 44: bounded per-channel slowmode configuration;
- migration 45: incoming channel webhook identities and hashed credentials;
- migration 46: developer applications, installations, reusable command templates, and handler metadata;
- migration 47: per-command channel/role/member permission overrides;
- migration 48: a partial active-invocation index so internal webhook/AI claims remain bounded as completed history grows;
- migration 49: a partial `(scope_id, user_id, created_at DESC)` channel-message index for bounded slowmode recent-message checks without adding a broad write-heavy message index.

Migrations remain sequential and idempotent under the existing migration runner. PostgreSQL remains the relational authority. Redis remains non-authoritative realtime state. Scylla remains optional high-volume timeline storage and is not enabled automatically by this release.

## Compatibility

- Existing `/api/bot/*` integrations remain available.
- PostgreSQL remains the default message backend.
- Redis and Scylla enablement defaults are unchanged.
- Normal messages beginning with `/` continue to send normally when no registered command matches.
- Ordinary attachments remain ordinary attachments unless explicitly marked as spoilers.
- Existing encrypted message rows remain readable when the old key is kept in `PLAINWIRE_ENC_PREVIOUS_KEYS` during rotation.
- Existing outbound webhook definitions continue to work; old plaintext signing-secret rows remain readable and are encrypted when rotated.
- Message history remains bounded during reply jumps; the normal live-tail history path is unchanged.
- Incoming webhooks are opt-in and do not grant read access to their destination channel.

## Operator notes

Before production deployment:

1. Back up PostgreSQL and the instance encryption/admin secrets.
2. Run the normal Plainwire database migrations.
3. Keep the current encryption key available during any key rotation.
4. Allow the search reconciler to backfill the blind index after deployment.
5. Verify Redis/TURN/Scylla configuration using the existing deployment health checks.
6. Rotate bot or incoming-webhook tokens if there is any reason to believe a credential was exposed.
7. Verify outbound webhook receivers still validate signatures after any signing-secret rotation.

See `.env.example`, `docs/BOTS.md`, `docs/SECURITY.md`, `docs/CALL_HEALTH.md`, `docs/CLOUDFLARE_TURN.md`, `docs/REDIS.md` and `docs/SCYLLA.md`.
