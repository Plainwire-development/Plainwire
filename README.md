# Plainwire Relay

Plainwire Relay is a self-hostable chat app with servers, DMs, forums, voice calls, screen sharing, uploads, profiles, and live updates.

It uses Erlang/OTP, Cowboy, PostgreSQL, Elm, SCSS, WebSocket, and WebRTC.

## Quick start

Requirements:

- Erlang/OTP 24+
- PostgreSQL 13+
- rebar3
- Node.js and npm
- Elm 0.19.x

Install frontend dependencies and build everything:

```sh
npm ci
npm run build
rebar3 get-deps
rebar3 compile
```

For a quick source audit, run `./scripts/verify-source.sh`. Before publishing a release, run `./scripts/release-check.sh`; it is deliberately strict and requires the native Elm compiler, Erlang, rebar3, Node.js, and npm so a source-only check cannot be mistaken for a release build. Sass is installed from the locked npm dependencies.

Create a PostgreSQL database, then run:

```sh
cp .env.example .env
./scripts/start.sh
```

Open `http://localhost:8080`.

For the bundled development database helper:

```sh
guix shell postgresql -- ./scripts/dev-db.sh start
./scripts/start.sh --build
```

## Main features

- Accounts, profiles, password rotation, session management, friends, blocking, presence, and notifications
- Servers, text channels, voice channels, DMs, and group chats
- Forums, threads, replies, message replies, and deletion
- WebRTC voice calls with STUN and TURN support
- Draggable and resizable screen share windows
- Audio input and output selection, mic testing, mute, and deafen
- Streamed file uploads with configurable limits
- Browser-side compression offers for oversized files when practical
- Inline image, audio, and video playback
- Safe link previews and same-origin proxied preview images
- Runtime client configuration from environment variables
- Light, dark, and system themes plus local interface, chat, privacy, and accessibility customization
- PostgreSQL persistence and additive schema migrations

## Configuration

Start with `.env.example`. The most important settings are:

```sh
PLAINWIRE_ENV=production
PLAINWIRE_PUBLIC_URL=https://chat.example.com
COOKIE_SECURE=true
PLAINWIRE_TRUST_PROXY=true

PLAINWIRE_DB_HOST=localhost
PLAINWIRE_DB_PORT=5432
PLAINWIRE_DB_USER=plainwire
PLAINWIRE_DB_PASS=change-me
PLAINWIRE_DB_NAME=plainwire

PLAINWIRE_APP_NAME=Plainwire
PLAINWIRE_DEFAULT_THEME=system
PLAINWIRE_REGISTRATION_ENABLED=true
PLAINWIRE_INSTANCE_DESCRIPTION="A fast, self-hosted place to talk."
PLAINWIRE_UPLOAD_MAX_BYTES=262144000
PLAINWIRE_UPLOAD_MAX_FILES=10
PLAINWIRE_PROFILE_IMAGE_MAX_BYTES=16777216
PLAINWIRE_COMPRESS_OVERSIZE_UPLOADS=true
PLAINWIRE_UPLOAD_IMAGE_MAX_DIMENSION=4096
PLAINWIRE_IDLE_TIMEOUT_MS=600000
PLAINWIRE_SESSION_DAYS=30
PLAINWIRE_MAX_SESSIONS_PER_USER=32
```

For production voice calls, configure coturn:

```sh
PLAINWIRE_TURN_URLS=turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp,turns:turn.example.com:5349?transport=tcp
PLAINWIRE_TURN_SECRET=replace-with-a-long-random-secret
PLAINWIRE_REQUIRE_TURN=true
```

External preview and proxy hosts can be restricted with:

```sh
PLAINWIRE_MEDIA_ALLOWED_HOSTS=cdn.example.com,images.example.net
```

Keep this list narrow on public deployments.

## Release and deployment

The default theme is `system`, so a new account follows the operating system light or dark preference until the user chooses an explicit theme.

After updating a checked-out production install, use the release updater rather than restarting an old release directory:

```sh
sudo ./scripts/update-openrc-release.sh
```

The updater rebuilds HAML, SCSS, and Elm, runs the Erlang tests, packages the release, restarts the service, and verifies both the running backend version and refreshed frontend fingerprint. You can also check a deployment directly:

```sh
curl -fsS https://chat.example.com/api/version
```

Frontend assets are versioned from the server release so browsers do not stay pinned to an old `app.js` or `app.css` after an upgrade.

To produce both a tested Erlang release archive and a source archive that includes the freshly compiled frontend, run:

```sh
./scripts/package-release.sh
```

It runs the strict release gate first and writes SHA-256 files beside both archives in `dist/`.

## Account security

Plainwire exposes active-session management and password rotation from User Settings. Password changes verify the current password and invalidate every other session. Session tokens remain hashed in PostgreSQL and are never returned by the session-management API. Session lifetime and the per-account session cap can be tuned with `PLAINWIRE_SESSION_DAYS` and `PLAINWIRE_MAX_SESSIONS_PER_USER`.

For public instances, set `PLAINWIRE_REGISTRATION_ENABLED=false` after creating the accounts you need if you do not want open sign-ups.

## Production checklist

- Put Plainwire behind Caddy, nginx, or another HTTPS reverse proxy.
- Set `COOKIE_SECURE=true`.
- Set `PLAINWIRE_PUBLIC_URL` to the public HTTPS origin.
- Keep PostgreSQL private.
- Set a strong `PLAINWIRE_ENC_KEY`.
- Use TURN for reliable calls across restrictive networks.
- Keep `PLAINWIRE_UPLOAD_DIR` on durable storage.
- Back up both PostgreSQL and the upload directory.
- Configure your proxy request-body limit to match `PLAINWIRE_UPLOAD_MAX_BYTES` for `/api/uploads`.
- Keep remote media hosts restricted and outbound networking filtered.
- Load test your own deployment before increasing connection or upload limits.

Message encryption is encryption at rest, not end-to-end encryption. The server can still read message content while serving the application.

## Debugging

Browser tracing is off by default. Enable it in the browser console when needed:

```js
PlainwireDebug.setEnabled(true)
PlainwireDebug.snapshot()
```

Turn it back off with:

```js
PlainwireDebug.setEnabled(false)
```

## License

See the repository license file.
