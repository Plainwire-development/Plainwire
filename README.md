# Plainwire Relay 1.1.0

Plainwire Relay is a self-hosted forum/chat platform with a Discord-like real-time workspace, Reddit/forum-style threads, PostgreSQL persistence, and an Erlang/Cowboy backend.

This release removes all generated demo content. There are no bots, fake users, or seeded threads. Only the four empty forum categories are created on first boot.

## Features

- Real account registration and login
- PBKDF2 password hashing
- AES-256-GCM message encryption at rest (when `PLAINWIRE_ENC_KEY` is set)
- HttpOnly SameSite session cookies
- CSRF enforcement on write requests
- Per-route/IP rate limiting
- PostgreSQL persistence across boots
- Additive schema migrations via `schema_migrations`
- Server creation with icon URL support
- Text and voice channels
- Discord-style server invite links with preview page
- Member sidebar on servers and channels
- Link embeds (Open Graph metadata fetched server-side)
- Image URL proxy (external providers never see client IPs)
- Forum categories, threads, and replies
- Direct messages and group DMs
- Conversation rename/avatar and member invites
- Friend requests, accept/remove/block
- Profile screen with avatar, banner, bio, status, and theme field
- Notifications
- WebSocket live updates with multi-tab leader election
- Silent sync/polling fallback that avoids wiping message composers
- Discord-style compact message grouping
- WebRTC peer-to-peer voice signaling for server voice channels and DM calls
- No external frontend build step

## Requirements

- Erlang/OTP 24+
- PostgreSQL 13+
- rebar3

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

## Run

```sh
rebar3 get-deps
rebar3 compile
PLAINWIRE_DB_HOST=localhost PLAINWIRE_DB_USER=plainwire PLAINWIRE_DB_PASS=plainwire PLAINWIRE_DB_NAME=plainwire rebar3 shell --apps plainwire_relay
```

Open:

```text
http://localhost:8080
```

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `8080` | HTTP listen port |
| `PLAINWIRE_DB_HOST` | `localhost` | PostgreSQL host |
| `PLAINWIRE_DB_PORT` | `5432` | PostgreSQL port |
| `PLAINWIRE_DB_USER` | `plainwire` | PostgreSQL user |
| `PLAINWIRE_DB_PASS` | `plainwire` | PostgreSQL password |
| `PLAINWIRE_DB_NAME` | `plainwire` | PostgreSQL database |
| `PLAINWIRE_DB_SSL` | `false` | Enable SSL to PostgreSQL |
| `PLAINWIRE_ENC_KEY` | _(unset)_ | Base64-encoded 32-byte AES key for message encryption at rest |
| `PLAINWIRE_PBKDF2_ITERS` | `160000` | Password hash iteration count |
| `COOKIE_SECURE` | `false` | Set `true` behind HTTPS reverse proxy |

Generate an encryption key:

```sh
python3 -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"
```

For HTTPS behind a reverse proxy:

```sh
COOKIE_SECURE=true PLAINWIRE_ENC_KEY=your-key-here rebar3 shell --apps plainwire_relay
```

## Persistence and upgrades

Schema changes are tracked in `schema_migrations`. Migrations are additive and run automatically on boot.

Back up PostgreSQL before upgrades:

```sh
pg_dump plainwire > plainwire.backup.sql
```

## Public hosting notes

Put Plainwire behind nginx/Caddy with HTTPS, set `COOKIE_SECURE=true`, and expose only the reverse proxy publicly. WebRTC peer-to-peer voice uses STUN; difficult NATs may require adding TURN support later.

External image URLs in profiles and messages are proxied through `/api/media/...` so third-party hosts cannot log individual user IP addresses.

## Security scope

This is a self-hosted community app with core protections (CSRF, rate limits, PBKDF2, optional AES-GCM at rest, image proxy). Run it behind TLS, keep dependencies patched, back up PostgreSQL regularly, and set `PLAINWIRE_ENC_KEY` for encrypted message storage.
