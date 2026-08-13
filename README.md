# plainwire relay

Plainwire Relay is a hosted chat/forum app with messages, servers, DMs, profiles,
notifications, and voice calls.

Most people should use the hosted service. The repo is still buildable for dev,
testing, poking around, or running your own copy.

## version

**Plainwire Relay 1.1.0**

No demo bots, fake users, or mystery sample posts. A fresh database starts fresh.

> Link to the old [Plainwire Forums Concept](https://github.com/RobertFlexx/Plainwire-Forum)

## features

* accounts, persistent sessions, profiles, friends, and blocking
* DMs, group chats, servers, text channels, and voice channels
* forums, threads, replies, notifications, and message replies/deletion
* server invites, banners, accent colors, categories, and member sidebars
* pasted or dragged uploads up to 250 MB, plus inline image/audio/video playback
* Open Graph embeds and same-origin image proxying
* live updates over WebSocket, including multi-tab coordination
* peer-to-peer WebRTC voice and screen sharing
* audio-device selection, mic testing, and optional Krisp processing
* PostgreSQL persistence, because losing the chat on restart would be awkward

## security

The important bits:

* PBKDF2 password hashing
* HttpOnly SameSite session cookies
* CSRF protection on write requests
* Per-route/IP rate limiting
* Optional AES-256-GCM message encryption at rest
* PostgreSQL-backed persistent storage
* Additive schema migrations through `schema_migrations`
* External image proxying so third-party image hosts do not receive each user’s direct IP address

Message encryption is at rest, not end-to-end. The server still sees message
content while doing server things.

## stack

* [Erlang/OTP](https://github.com/erlang/otp)
* [Cowboy](https://github.com/ninenines/cowboy)
* [PostgreSQL](https://github.com/postgres/postgres)
* [epgsql](https://github.com/epgsql/epgsql)
* [Elm](https://github.com/elm/compiler)
* [SCSS](https://github.com/sass/sass)
* WebSocket
* [WebRTC](https://github.com/webrtc)
* [rebar3](https://github.com/erlang/rebar3)

## debug logging

Browser tracing is off by default; realtime logs get loud fast. In the console,
use `PlainwireDebug.setEnabled(true)` and reload. Sensitive fields and message
bodies are redacted.

`PlainwireDebug.snapshot()` dumps the current connection/voice state.
`PlainwireDebug.setEnabled(false)` turns the firehose back off. The backend logs
room lifecycle events, not audio. that would be weird.

## capacity, roughly

Capacity knobs live in `.env.example`; health details are available to signed-in
users at `/api/health`.

There is no magic "users per server" number. Load-test the actual deployment,
watch database queues/BEAM memory/file descriptors, and add capacity before the
graphs become modern art.

## local dev and self-hosting

This part is for contributors, private deployments, and anyone who enjoys
owning their own database problems.

### requirements

* Erlang/OTP 24+
* PostgreSQL 13+
* rebar3
* Elm 0.19.x
* Sass/SCSS compiler

### database setup

Quickest route with Guix:

```sh
guix shell postgresql -- ./scripts/dev-db.sh start
./scripts/start.sh --build
```

If PostgreSQL is already in the shell:

```sh
./scripts/start.sh --with-db --build
```

Use `guix shell postgresql -- ./scripts/dev-db.sh stop` to stop the development
database. Its data is kept under `${XDG_DATA_HOME:-$HOME/.local/share}/plainwire`.

Manual setup still works too:

```sh
createdb plainwire
psql plainwire -c "CREATE USER plainwire WITH PASSWORD 'plainwire';"
psql plainwire -c "GRANT ALL PRIVILEGES ON DATABASE plainwire TO plainwire;"
```

On PostgreSQL 15+, also grant schema privileges:

```sh
psql plainwire -c "GRANT ALL ON SCHEMA public TO plainwire;"
```

### build frontend assets

Build Elm:

```sh
cd priv/static/elm
elm make src/Main.elm --output=../app.js --optimize
```

Build SCSS:

```sh
sass priv/static/style.scss priv/static/app.css --no-source-map
```

### run locally

```sh
rebar3 get-deps
rebar3 compile
rebar3 shell --apps plainwire_relay
```

then open:

```text
http://localhost:8080
```

## configuration

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
| `PLAINWIRE_UPLOAD_INFLIGHT_BYTES` | `1073741824` | Maximum bytes being uploaded concurrently per relay node |
| `PLAINWIRE_UPLOAD_USER_INFLIGHT_BYTES` | `536870912` | Maximum bytes being uploaded concurrently by one user |
| `PLAINWIRE_ALLOW_ARBITRARY_MEDIA` | `false` | Explicitly allow unrestricted hosts (not recommended)   |
| `PLAINWIRE_STUN_URLS`    | Google STUN | Comma-separated STUN server URLs                              |
| `PLAINWIRE_TURN_URLS`    |       unset | Comma-separated TURN URLs (`turn:` or `turns:`)               |
| `PLAINWIRE_TURN_SECRET`  |       unset | Coturn REST shared secret (32+ random bytes recommended)       |
| `PLAINWIRE_TURN_USERNAME`| `plainwire` | Label used in temporary TURN usernames                        |
| `PLAINWIRE_TURN_TTL_SECONDS` |    `3600` | Temporary TURN credential lifetime (300–86400)             |
| `PLAINWIRE_REQUIRE_TURN` | prod: `true` | Fail startup when TURN is missing                             |
| `PLAINWIRE_ALLOW_STATIC_TURN_CREDENTIALS` | `false` | Permit long-lived TURN credentials in prod      |
| `PLAINWIRE_ICE_TRANSPORT_POLICY` | `all` | Set to `relay` to force all calls through TURN             |
| `PLAINWIRE_VOICE_MAX_PARTICIPANTS` |   `8` | Maximum participants in a voice room (2–32)               |
| `PLAINWIRE_VOICE_MAX_SHARES` |   `2` | Maximum simultaneous screen shares per voice room (1–8)   |
| `PLAINWIRE_RTC_RECONNECT_GRACE_MS` | `15000` | Preserve call membership during a short refresh or reconnect |
| `PLAINWIRE_KRISP_ENABLED` | `false` | Offer licensed Krisp processing after its local SDK assets pass verification |

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

## persistence and upgrades

App data lives in PostgreSQL. Message attachments live in
`PLAINWIRE_UPLOAD_DIR`. Back up both, not just the one you remembered first.

Additive migrations run on boot and are tracked in `schema_migrations`.

Back up the database before upgrading:

```sh
pg_dump plainwire > plainwire.backup.sql
```

## production notes

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

Voice tries direct peer-to-peer connections with STUN, then TURN when the network
says no. Screen sharing uses `getDisplayMedia`; tracks are swapped with
`replaceTrack` so the call does not renegotiate for every share.

screen sharing support:

* Chrome/Edge desktop: full support
* Firefox desktop: full support
* Safari desktop: full support (no display audio)
* iOS Safari: not supported (no `getDisplayMedia`)
* Android Chrome: not supported (no `getDisplayMedia`)

With `PLAINWIRE_TURN_SECRET`, the RTC endpoint creates short-lived coturn
credentials. Use the same secret and a realm in coturn, disable anonymous
access, set quotas, and expose UDP/TCP 3478 plus TLS 5349. Include both `turn:`
and `turns:` URLs; some networks are deeply committed to being difficult.

Krisp is optional and separately licensed. Put its complete browser `dist`
bundle in `priv/static/krisp/`, set `PLAINWIRE_KRISP_ENABLED=true`, and restart.
If the SDK/module files are missing, Plainwire quietly sticks with native noise
cancellation instead of doing interpretive audio failure.

Production startup is picky: HTTPS origin, secure cookies, database
TLS/password, encryption, a sane password-hash cost, and usually TURN. Remote
media also needs an allowlist. Keep network egress rules as a second SSRF fence.

## development notes

boring architecture rules (boring is good here):

* Keep the Erlang backend
* Keep PostgreSQL as the database
* Keep the Elm frontend
* Keep SCSS for styling
* Use REST for normal API actions
* Use WebSocket for live events
* Use WebRTC for voice
* Avoid generated demo content in public releases
* Avoid unnecessary rewrites

## license

AGPL 3

Plainwire Relay uses the GNU Affero General Public License v3.0. If a modified
version is offered as a public network service, its source must be available to
that service's users.

The Plainwire name, logo, and branding are not included in this license unless stated otherwise.
