# Security and privacy

Plainwire is designed so optional infrastructure improves performance and scale without becoming the only copy of security-critical state.

## Trust boundaries

PostgreSQL is the authority for accounts, authentication metadata, servers, memberships, roles, permissions, bot/app configuration, webhook configuration and host-admin state.

Redis is a realtime accelerator. Presence, rate limits, temporary coordination and caches may use Redis, but authentication and durable authorization must continue to function safely when Redis is unavailable.

ScyllaDB is an optional high-volume timeline store. Enabling it does not replace PostgreSQL authority for accounts, permissions or other relational metadata.

The host control plane is separate from per-server moderation and remains private-content blind.

## Message encryption at rest

`PLAINWIRE_ENC_KEY` is a base64-encoded 32-byte AES-256-GCM key. Production configuration validation requires a usable encryption key.

Generate a key with a cryptographically secure tool, for example:

```sh
openssl rand -base64 32
```

Do not commit the value to source control, bake it into an image, put it in client-visible configuration, or log it.

### Key rotation

Set the new primary key in `PLAINWIRE_ENC_KEY` and put the previous primary key in `PLAINWIRE_ENC_PREVIOUS_KEYS` while old rows still exist. Up to four previous keys are accepted.

Example shape only:

```text
PLAINWIRE_ENC_KEY=<new base64 key>
PLAINWIRE_ENC_PREVIOUS_KEYS=<old base64 key>,<older base64 key>
```

New values use the primary key. Reads try the primary key and then previous keys. Keep old keys backed up until all content that depends on them has been migrated or aged out.

Plainwire does not claim end-to-end encryption. The application server can decrypt messages while providing server-side features.

## Message search

Plainwire 2.2 uses a keyed blind index. It does not write normalized plaintext search words to PostgreSQL.

`PLAINWIRE_SEARCH_KEY` can be an independent base64 32-byte key. If it is absent, Plainwire derives a dedicated search key from the encryption key. A separate search key is preferable when operators want independent key rotation boundaries.

The blind index leaks equality/frequency relationships between identical normalized words within the same instance. It is designed to avoid a second plaintext message database, not to provide cryptographic searchable-encryption guarantees against a server operator who also controls application keys.

Every candidate search result passes current message ACL checks before Plainwire loads and returns the message body.

## Sessions and account restrictions

Instance suspension or banning deletes normal sessions and admin sessions for the affected account and invalidates runtime caches. The realtime hub is notified immediately so a connected client can show the restriction state without waiting for a refresh.

Host moderation follows the control-plane role hierarchy. A control-plane operator cannot use moderation to remove protection from a higher-privileged operator.

## Bots

Bot bearer tokens use the `pwb_` prefix and are stored as hashes. Treat the plaintext token like a password. Rotate it after accidental disclosure.

Bot command claim tokens are one-time lease credentials and are stored only as hashes. Durable command arguments are encrypted at rest.

Bots use the ordinary server role/permission system. Bot WebSockets cannot emit normal user voice, call or typing state.

First-party SDKs require HTTPS for remote Plainwire origins and refuse redirects so an Authorization header is not forwarded to another origin. Loopback HTTP is allowed for local development.

## Developer applications and AI connectors

Developer Applications are user-owned templates installed as server-scoped bot identities. Installation requires **Manage bots**, and non-owner installers can grant only permissions they are themselves allowed to grant; the administrator bit is not delegable by that path. Public directory responses omit connector secrets and owner-private metadata.

Durable command arguments are encrypted at rest. Authorization is checked when a command is invoked and checked again immediately before a worker receives the decrypted arguments. That second check covers the bot's channel access, the invoking user's current channel access, and the command's member/channel/role override rules so a permission revocation cannot race queued delivery.

Signed interaction and AI HTTP traffic uses a dedicated outbound policy: remote endpoints must be HTTPS; DNS is resolved once and the connection is made to the reviewed address to resist DNS rebinding; redirects are not followed; request/response sizes, timeouts, retries and worker concurrency are bounded. Plaintext HTTP is available only for exact loopback development when `PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP=true`.

AI API keys and optional system prompts are encrypted using the instance content-encryption envelope. Hosted AI command execution sends the command and supplied arguments only and does not load channel history. Operators should still treat a configured third-party AI endpoint as a data recipient for the command text users deliberately submit to it.

## Server webhooks

Incoming channel webhooks are deliberately write-only bearer credentials. Plainwire stores only a hash of the incoming token, binds the credential to one text channel, applies both shared per-webhook and per-source limits, and returns only message id/channel id/timestamp after a successful post. It does not echo serialized reply metadata or channel history. Incoming hooks cannot reference another user's existing upload ids.

Outbound webhook signing secrets created or rotated by 2.1 are encrypted at rest with the instance content-encryption envelope. Delivery payloads retained for an explicit failed-delivery retry are also encrypted at rest. Successful delivery payloads are erased. Existing 2.0 plaintext signing-secret rows remain readable for compatibility and should be rotated when practical to convert them to encrypted storage.

Outbound URL delivery continues to pass through Plainwire's SSRF-aware URL policy, including redirect revalidation and DNS/IP safety checks.

## Message pins and historical context

Pin/unpin operations require the ordinary **Manage messages** permission and are capped per channel. Reading pins or fetching a reply target's historical context requires the same current channel or DM access as normal message history. Historical-context fetches are deliberately bounded instead of being an unbounded history primitive.

## WebRTC calls

Browser WebRTC encrypts media with DTLS-SRTP. Plainwire signaling should be served over HTTPS/WSS in production.

TURN credentials should be short-lived. Keep TURN shared secrets out of source control. For deployments where host-IP privacy is more important than direct-peer efficiency, use the relay-only ICE policy documented by the deployment configuration.

Do not expose TURN administration interfaces publicly. Restrict firewall rules to the ports and relay ranges actually required by the TURN deployment.

## Media proxy signing

`PLAINWIRE_MEDIA_SIGNING_KEY` may be configured as a separate base64 32-byte key. If omitted, the encryption key is used. Production operators who want independent rotation should set a dedicated value.

## Host-admin privacy boundary

The service control plane exposes service health and account/server operational metadata needed to run the instance. It intentionally does not expose:

- private message or DM bodies;
- attachment contents;
- private-message search;
- plaintext bot tokens;
- plaintext host-admin verification material;
- encryption or TURN secrets.

Host access is still privileged. Somebody who controls the machine, database and encryption keys can access more than the web control plane intentionally exposes.

## Deployment basics

For public deployments:

- terminate HTTPS with a maintained reverse proxy;
- use secure cookies and the documented trusted-proxy settings;
- bind the host-admin listener to loopback/private networking whenever practical;
- keep PostgreSQL, Redis and Scylla off the public Internet;
- use database credentials unique to Plainwire;
- back up PostgreSQL and the Plainwire instance/encryption secrets together;
- test restores instead of assuming a backup is usable;
- apply security updates to OTP, OpenSSL, PostgreSQL, Redis, Scylla, TURN and the host OS;
- monitor authentication failures, rate-limit pressure, queue failures and database health without logging private message bodies or credentials.


## Availability and overload boundaries

Availability failures can become security failures when untrusted clients are allowed to create unbounded work. Plainwire therefore treats queue and cardinality limits as security boundaries as well as performance controls. WebSocket delivery reservations, upgrade admission, presence-watch cardinality, asynchronous worker queues, Redis queues, database-lane admission and the cluster outbox are bounded. Ephemeral typing/presence/activity events may be shed before durable traffic, and persistently slow WebSocket consumers are disconnected rather than allowed to grow arbitrary process mailboxes.

Do not remove these bounds to make a synthetic benchmark look better. Tune them only while measuring queue depth, memory, scheduler utilization and dependent-service latency. Rate limits and queue limits are defense-in-depth; they do not replace upstream connection limits, reverse-proxy protections, host resource limits or capacity testing. See `docs/SCALING.md`.

## Rate-limit state bounds

`PLAINWIRE_RATE_MAX_ENTRIES` caps local fixed-window ETS cardinality. Novel keys fail closed at the ceiling until expired counters are collected.
