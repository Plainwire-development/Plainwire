# Plainwire Relay 1.0.0

Plainwire Relay is a self-hosted forum/chat platform with a Discord-like real-time workspace, Reddit/forum-style threads, persistent SQLite storage, and an Erlang/Cowboy backend.

This release removes all generated demo content. There are no bots, fake users, or seeded threads. Only the four empty forum categories are created on first boot.

## Features

- Real account registration and login
- PBKDF2 password hashing
- HttpOnly SameSite session cookies
- CSRF enforcement on write requests
- Per-route/IP rate limiting
- SQLite persistence across boots
- Additive schema migrations via `schema_migrations`
- Server creation
- Text and voice channels
- Server invite links/codes
- Forum categories, threads, and replies
- Direct messages and group DMs
- Conversation rename/avatar and member invites
- Friend requests, accept/remove/block
- Profile screen with avatar, banner, bio, status, and theme field
- Notifications
- WebSocket live updates
- Silent sync/polling fallback that avoids wiping message composers
- Discord-style compact message grouping
- WebRTC peer-to-peer voice signaling for server voice channels and DM calls
- No external frontend build step

## Run

```sh
rebar3 get-deps
rebar3 shell --apps plainwire_relay
```

Open:

```text
http://localhost:8080
```

LAN:

```text
http://YOUR-LAN-IP:8080
```

## Configuration

```sh
PORT=8080 PLAINWIRE_DB=data/plainwire.sqlite3 rebar3 shell --apps plainwire_relay
```

For HTTPS behind a reverse proxy:

```sh
COOKIE_SECURE=true PORT=8080 rebar3 shell --apps plainwire_relay
```

## Persistence and upgrades

The database lives at `data/plainwire.sqlite3` by default. Do not delete `data/` unless you want to wipe the instance.

Schema changes are tracked in `schema_migrations`. The migrations are additive and should not require re-registering users across future Plainwire versions.

Back up before upgrades:

```sh
cp data/plainwire.sqlite3 data/plainwire.sqlite3.bak
```

## Public hosting notes

For internet hosting, put Plainwire behind nginx/Caddy with HTTPS, set `COOKIE_SECURE=true`, and expose only the reverse proxy publicly. WebRTC peer-to-peer voice uses STUN; difficult NATs may require adding TURN support later.

## Security scope

This is a first release self-hosted app, not a hardened enterprise system. It includes core protections, but you should still run it behind TLS, keep Erlang/dependencies patched, back up the SQLite DB, and review the code before using it with sensitive communities.
