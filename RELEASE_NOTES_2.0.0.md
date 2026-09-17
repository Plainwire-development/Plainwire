# Plainwire 2.0.0

2.0 turns the integration and customization work into first-class Plainwire systems without replacing the app people already know.

## Voice notes

Text channels can record and send voice notes using the normal upload and attachment access model. Voice notes have their own server role permission, so a server can allow ordinary messages without allowing recorded voice.

## Roles and server profiles

The server profile popup can edit a member's roles when the viewer has **Manage roles** and the target is below them in the role hierarchy. The expanded permission set now covers server management, channels, messages, roles, profiles, Wires, voice access, attachments, reactions, voice notes, screen sharing, webhooks and bots.

Permissions shown in the 2.0 UI are backend-enforced capabilities. Reserved permission bits that do not have a complete product feature are not exposed as decorative toggles.

## Server customization

Server settings have expanded identity and presentation controls while retaining existing layouts and responsive behavior. Server-specific profile identity continues to flow through messages, typing and voice without changing DM identity.

## Webhooks

Servers can create, update, test, rotate and remove outbound webhooks. Deliveries are durable in PostgreSQL, claimed safely by workers and sent with Gun. Requests are signed and outbound destinations pass the same SSRF-oriented URL checks used by the rest of Plainwire's outbound networking.

Webhook failure cannot roll back or stall the underlying chat action. Failed deliveries are retried from durable state.

## Bots

Servers can create real bot accounts with one-time `pwb_...` credentials. Tokens are stored hashed and can be rotated. Bots remain normal server members for authorization, so role assignments determine what they can read and change.

2.0 includes bot HTTP APIs for identity, server/channel discovery, message history, sending, deletion and reactions. Bot-authenticated WebSockets provide realtime subscriptions without granting access to browser-only voice/call/typing controls.

An Erlang SDK is included under `sdk/erlang`. It uses Gun for HTTP and WebSocket traffic, reconnects realtime sessions with bounded backoff and restores subscriptions after reconnect.

## Client themes and plugins

The extension manager can install whole-app Less themes and local client plugins. Themes compile with Less JavaScript disabled. Plugins execute in Web Workers with direct browser networking APIs removed and use a small Plainwire bridge instead of sharing the main Elm execution context.

## Storage architecture: PostgreSQL, Redis and ScyllaDB

PostgreSQL remains Plainwire's relational authority for accounts, servers, memberships, roles, permissions, integrations and other transactional metadata. Redis remains optional and ephemeral: it accelerates node-aware presence, distributed rate gates, hot latest-message reads and short-lived coordination, but Redis is never the only durable copy of important state. Redis failures degrade to local/durable paths instead of taking Plainwire offline.

2.0 also adds a first-class ScyllaDB message/event history backend for larger deployments. Message storage has three explicit modes:

- `postgres` keeps PostgreSQL as the complete message store and remains the simplest self-hosting mode;
- `dual` keeps PostgreSQL as read authority while a durable PostgreSQL outbox idempotently mirrors new history into Scylla during migration;
- `scylla` makes Scylla the canonical high-volume message timeline/read authority while PostgreSQL remains relational authority and a recovery mirror through the rollback window.

Scylla history uses bounded time buckets plus direct message locators rather than unbounded channel partitions. New message IDs are chronologically sortable, browser-safe 53-bit Snowflake-style IDs with PostgreSQL-backed node leases. Scylla-authoritative writes use durable write intents around the narrow PostgreSQL/Scylla commit window, and reconciliation either restores committed PostgreSQL state or removes a Scylla-only orphan after a crash.

Migration is intentionally phased rather than a flag-day switch: schema/health checks, dual write, resumable backfill, verification, shadow comparisons, backend parity checks, write-intent reconciliation, and finally Scylla read authority. Privacy hard-deletes and critical message upserts remain durable retry jobs and are surfaced separately in storage diagnostics instead of being silently abandoned.

The Scylla path includes bounded per-partition concurrency, active request deadlines, load shedding, prepared statements, TLS verification, health/latency/backlog telemetry, configurable event/delivery retention, explicit schema tooling, and a bounded storage benchmark. PostgreSQL-only operation remains fully supported. See `docs/SCYLLA.md` before enabling `dual` or `scylla`.

## Account lifecycle

Accounts can be disabled or permanently deleted from the client. Disabling invalidates active sessions and blocks normal use until the owner signs in again with the password.

Permanent deletion is a transactional database erase. Owned servers, conversations and forums are transferred when another member can own them or removed when they cannot; restrictive authored records are cleaned up; the `users` row is physically deleted. Plainwire does not keep a fake login-capable "deleted account" row.

## Performance and stability

2.0 keeps existing interaction behavior while reducing hot-path work. Realtime typing uses the shared limiter when Redis is enabled, latest-message reads can use the Redis generation cache, WebSocket authorization keeps bot restrictions separate from ordinary user rate limits, and presence is correct when the same account spans multiple Erlang nodes.

The existing RTC ownership, reconnect, screen-audio fallback, upload ACL, admin-plane isolation, UI and release contract suites remain part of the regression surface.
