# Plainwire Relay

Plainwire Relay is a hosted chat and forum platform with real-time messaging, servers, direct messages, forums, profiles, notifications, and voice calls.

Plainwire is designed to run on our servers. Users are not expected to clone the project or run their own instance. The source can still be built locally for development, testing, or self-hosting, but the main use case is the hosted Plainwire service.

## Version

**Plainwire Relay 1.1.0**

This release removes generated demo content. There are no fake users, bots, seeded messages, or sample threads. On first boot, Plainwire only creates the default empty forum categories.

> Link to the old [Plainwire Forums Concept](https://github.com/RobertFlexx/Plainwire-Forum)

## Features

* Account registration and login
* Persistent user sessions
* User profiles with avatar, banner, bio, status, and theme field
* Friend requests, accept/remove/block
* Direct messages and group DMs
* Server creation
* Text and voice channels
* Server invite links with preview pages
* Member sidebars for servers and channels
* Forum categories, threads, and replies
* Notifications
* Message replies
* Message deletion
* Compact message grouping
* Link embeds using Open Graph metadata
* External image proxying
* Streamed picture and file attachments up to 250 MB
* Clipboard image paste, drag-and-drop uploads, inline image embeds, and file downloads
* WebSocket live updates
* Multi-tab WebSocket coordination
* Silent sync fallback
* WebRTC peer-to-peer voice signaling
* PostgreSQL persistence across restarts

## Security

Plainwire includes the core security protections needed for a hosted community app:

* PBKDF2 password hashing
* HttpOnly SameSite session cookies
* CSRF protection on write requests
* Per-route/IP rate limiting
* Optional AES-256-GCM message encryption at rest
* PostgreSQL-backed persistent storage
* Additive schema migrations through `schema_migrations`
* External image proxying so third-party image hosts do not receive each user’s direct IP address

Message encryption is encryption at rest, not end-to-end encryption. The server still handles message delivery, notifications, replies, moderation, and other platform features.

## Stack

* [Erlang/OTP](https://github.com/erlang/otp)
* [Cowboy](https://github.com/ninenines/cowboy)
* [PostgreSQL](https://github.com/postgres/postgres)
* [epgsql](https://github.com/epgsql/epgsql)
* [Elm](https://github.com/elm/compiler)
* [SCSS](https://github.com/sass/sass)
* WebSocket
* [WebRTC](https://github.com/webrtc)
* [rebar3](https://github.com/erlang/rebar3)

## Debug logging

The browser bridge logs API timing, WebSocket lifecycle and messages, microphone
tracks, voice activity, WebRTC signaling/state changes, Elm commands, network
changes, and uncaught errors. Sensitive fields and message bodies are redacted.

In the browser console, run `PlainwireDebug.snapshot()` for the current voice
and connection state. Logging is enabled by default; use
`PlainwireDebug.setEnabled(false)` (or `true`) to persist the setting and reload.
Voice activity transitions and room/connection lifecycle events are also printed
by the Erlang backend when the server is running. No audio is sent to the backend.

## Production capacity

The relay uses concurrent PostgreSQL connections, ETS-based rate limiting and
session caches, bounded/deduplicated media fetching, selective presence watches,
WebSocket slow-client backpressure, and Ranch connection tuning. See
`.env.example` for capacity controls. The health endpoint reports scheduler,
process, database-pool queue, and rate-limiter data.

Capacity is deployment-specific: benchmark with realistic message fan-out,
animated avatars, TLS termination, PostgreSQL latency, and WebRTC signaling.
Put `/api/media/*` behind a CDN, enforce OS file-descriptor limits, monitor BEAM
mailboxes/memory, and scale relay nodes horizontally before sustained saturation.

# Below is information on how to host (If you want to be a hosting candidate)

> Or you're a contributor and want to code, test, build, and push. either goes.

## Hosting model

Plainwire is hosted-first.

Normal users should use the official Plainwire instance. They do not need to install Erlang, PostgreSQL, Elm, or any build tools.

Running a local copy is mainly useful for:

* Development
* Testing
* Contributions
* Auditing
* Private deployments
* Experimentation

Self-hosting is supported, but it is not required for normal use.

## Requirements for local development

* Erlang/OTP 24+
* PostgreSQL 13+
* rebar3
* Elm 0.19.x
* Sass/SCSS compiler

## Database setup

```sh
createdb plainwire
psql plainwire -c "CREATE USER plainwire WITH PASSWORD 'plainwire';"
psql plainwire -c "GRANT ALL PRIVILEGES ON DATABASE plainwire TO plainwire;"
```

On PostgreSQL 15+, also grant schema privileges:

```sh
psql plainwire -c "GRANT ALL ON SCHEMA public TO plainwire;"
```

## Build frontend assets

Build Elm:

```sh
cd priv/static/elm
elm make src/Main.elm --output=../app.js --optimize
```

Build SCSS:

```sh
sass priv/static/style.scss priv/static/app.css --no-source-map
```

## Run locally

```sh
rebar3 get-deps
rebar3 compile
rebar3 shell --apps plainwire_relay
```

Then open:

```text
http://localhost:8080
```

## Configuration

| Variable                 |     Default | Purpose                                                       |
| ------------------------ | ----------: | ------------------------------------------------------------- |
| `PORT`                   |      `8080` | HTTP listen port                                              |
| `PLAINWIRE_DB_HOST`      | `localhost` | PostgreSQL host                                               |
| `PLAINWIRE_DB_PORT`      |      `5432` | PostgreSQL port                                               |
| `PLAINWIRE_DB_USER`      | `plainwire` | PostgreSQL user                                               |
| `PLAINWIRE_DB_PASS`      | `plainwire` | PostgreSQL password                                           |
| `PLAINWIRE_DB_NAME`      | `plainwire` | PostgreSQL database                                           |
| `PLAINWIRE_DB_SSL`       |     `false` | Enable SSL for PostgreSQL                                     |
| `PLAINWIRE_ENC_KEY`      |       unset | Base64-encoded 32-byte AES key for message encryption at rest |
| `PLAINWIRE_MEDIA_SIGNING_KEY` | ENC key | Optional separate base64 32-byte media-token signing key      |
| `PLAINWIRE_PBKDF2_ITERS` |    `160000` | Password hash iteration count                                 |
| `COOKIE_SECURE`          |     `false` | Set to `true` when running behind HTTPS                       |
| `PLAINWIRE_PUBLIC_URL`   |       unset | Canonical HTTPS origin; required in production                 |
| `PLAINWIRE_ALLOWED_ORIGINS` | public URL | Comma-separated WebSocket origins                           |
| `PLAINWIRE_TRUST_PROXY`    |     `false` | Trust the first `X-Forwarded-For` address for rate limiting    |
| `PLAINWIRE_MEDIA_ALLOWED_HOSTS` | unset | Trusted hosts allowed for remote images and embeds          |
| `PLAINWIRE_UPLOAD_DIR` | `data/uploads/` | Durable local or mounted volume for message attachments |
| `PLAINWIRE_UPLOAD_MAX_BYTES` | `262144000` | Maximum attachment size (250 MB hard ceiling) |
| `PLAINWIRE_UPLOAD_QUOTA_BYTES` | `1073741824` | Per-user upload allowance in each rolling three-hour window |
| `PLAINWIRE_UPLOAD_RETENTION_DAYS` | `90` | Attachment retention period before automatic cleanup |
| `PLAINWIRE_UPLOAD_CONCURRENCY` | `64` | Maximum simultaneous uploads across one relay node |
| `PLAINWIRE_UPLOAD_USER_CONCURRENCY` | `4` | Maximum simultaneous uploads from one user |
| `PLAINWIRE_ALLOW_ARBITRARY_MEDIA` | `false` | Explicitly allow unrestricted hosts (not recommended)   |
| `PLAINWIRE_STUN_URLS`    | Google STUN | Comma-separated STUN server URLs                              |
| `PLAINWIRE_TURN_URLS`    |       unset | Comma-separated TURN URLs (`turn:` or `turns:`)               |
| `PLAINWIRE_TURN_SECRET`  |       unset | Coturn REST shared secret (32+ random bytes recommended)       |
| `PLAINWIRE_TURN_USERNAME`| `plainwire` | Label used in temporary TURN usernames                        |
| `PLAINWIRE_TURN_TTL_SECONDS` |    `3600` | Temporary TURN credential lifetime (300–86400)             |
| `PLAINWIRE_REQUIRE_TURN` | prod: `true` | Fail startup when TURN is missing                             |
| `PLAINWIRE_ALLOW_STATIC_TURN_CREDENTIALS` | `false` | Permit long-lived TURN credentials in prod      |
| `PLAINWIRE_ICE_TRANSPORT_POLICY` | `all` | Set to `relay` to force all calls through TURN             |

Generate an encryption key:

```sh
python3 -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"
```

Example production-style configuration:

```sh
COOKIE_SECURE=true
PLAINWIRE_ENV=production
PLAINWIRE_PUBLIC_URL=https://chat.example.com
PLAINWIRE_ENC_KEY=your-base64-key-here
PLAINWIRE_DB_HOST=localhost
PLAINWIRE_DB_USER=plainwire
PLAINWIRE_DB_PASS=plainwire
PLAINWIRE_DB_NAME=plainwire
PLAINWIRE_DB_SSL=true
PLAINWIRE_MEDIA_ALLOWED_HOSTS=cdn.example.com,images.example.net
PLAINWIRE_TURN_URLS=turn:turn.example.com:3478,turns:turn.example.com:5349
PLAINWIRE_TURN_USERNAME=plainwire
PLAINWIRE_TURN_SECRET=replace-with-at-least-32-random-bytes
```

## Persistence and upgrades

Plainwire stores data in PostgreSQL. Data persists across application restarts and server reboots.

Schema changes are tracked in `schema_migrations`. Migrations are additive and run automatically on boot.

Back up the database before upgrading:

```sh
pg_dump plainwire > plainwire.backup.sql
```

## Production notes

For public hosting:

* Run Plainwire behind nginx, Caddy, or another reverse proxy
* Use HTTPS
* Set `COOKIE_SECURE=true`
* Keep PostgreSQL private
* Expose only the reverse proxy publicly; firewall the Erlang listener
* Set `PLAINWIRE_ENC_KEY`
* Back up PostgreSQL regularly
* Keep dependencies updated
* Mount `PLAINWIRE_UPLOAD_DIR` on durable storage, back it up, and monitor free space
* Allow request bodies of at least 250 MB on `/api/uploads` in the reverse proxy; keep smaller limits on other routes
* Restrict outbound traffic and keep `PLAINWIRE_MEDIA_ALLOWED_HOSTS` narrow
* Set `PLAINWIRE_TRUST_PROXY=true` only when the app port is reachable solely by your proxy

WebRTC voice uses STUN for direct peer-to-peer connections and automatically falls back to the
configured TURN server when a direct connection is blocked by NAT or a firewall. With
`PLAINWIRE_TURN_SECRET`, the authenticated RTC endpoint creates a user-scoped, short-lived HMAC-SHA1
credential compatible with coturn's `use-auth-secret`/`static-auth-secret` mechanism. The browser
refreshes configuration periodically. Configure the exact same secret in coturn, set its realm,
disable anonymous access, cap allocations/quotas, and expose UDP/TCP 3478 plus TLS 5349. Include
both `turn:` and `turns:` URLs so restrictive networks have a TLS fallback.

Production startup deliberately fails without HTTPS public-origin configuration, secure cookies,
database TLS, a non-default database password, encryption, an adequate password-hash cost, and TURN
(unless `PLAINWIRE_REQUIRE_TURN=false` is explicitly set). Remote media and embed fetching is denied
in production unless its host is allowlisted or unrestricted fetching is explicitly enabled. Keep
network-level egress rules as a second SSRF boundary even when using the allowlist.

## Development notes

Plainwire should stay focused and maintainable.

Current architecture rules:

* Keep the Erlang backend
* Keep PostgreSQL as the database
* Keep the Elm frontend
* Keep SCSS for styling
* Use REST for normal API actions
* Use WebSocket for live events
* Use WebRTC for voice
* Avoid generated demo content in public releases
* Avoid unnecessary rewrites

## License

AGPL 3

Plainwire Relay is licensed under the GNU Affero General Public License v3.0.

The AGPL is used because Plainwire is a hosted web application. It allows people to use, study, modify, and share the code, but if someone modifies Plainwire and runs it as a public network service, they must make their modified source code available to the users of that service.

This helps keep improvements open while still allowing others to run and contribute to the project.

The Plainwire name, logo, and branding are not included in this license unless stated otherwise.
