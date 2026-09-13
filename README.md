# Plainwire Relay

Plainwire Relay is a self-hostable chat app with servers, DMs, forums, voice calls, screen sharing, uploads, profiles, and live updates.

It uses Erlang/OTP, Cowboy, PostgreSQL, Elm, SCSS, WebSocket, and WebRTC.

Version **1.7.2-1** adds neutral charcoal surfaces, roomier server navigation, a working Home mark, searchable click-to-select group members, live member refresh, server identity previews, and mobile dialogs with persistent action buttons. See [the patch notes](RELEASE_NOTES_1.7.2-1.md).

The preceding 1.7.2 build includes a [broader interface and worker refresh](docs/UI_REFRESH.md): quick navigation, adjustable sidebar, improved settings and chat, fewer repeated DOM scans, and stronger call-health evidence.

Version 1.7.2 adds a larger screen viewer, responsive and resizable call panels, capture quality presets, and screen switching with recovery. See [screen sharing and HDR limitations](docs/SCREEN_SHARING.md). It retains the 1.7.1 improvements, which fix formatting controls and channel icons, add live input/per-person volume, strengthen call-health analysis, and introduce a Makefile. It includes the 1.7.0 additions: Cloudflare TURN, Markdown with syntax highlighting, explicit screen viewing, expiring/revocable invites, server welcome messages, and searchable settings. It retains the microphone, sound, and mobile fixes from 1.6.1.

Optional backend additions: [Partisan routing](docs/CLUSTERING.md) and [Fortran call health](docs/CALL_HEALTH.md). Both can be left off. See [Cloudflare setup](docs/CLOUDFLARE_TURN.md) before using the relay service. The source archive includes built frontend assets; Erlang releases and the native helper are built on your target host.

## Quick start

Requirements:

- Erlang/OTP 25+ (OTP 27+ and the installed OTP source tree for the optional cluster profile)
- PostgreSQL 13+
- rebar3
- Node.js 22+ and npm
- GNU Make 4.3+ and Python 3.9+ (use `gmake` on FreeBSD)
- Optional: C compiler and gfortran for native call-health analysis
- Elm 0.19.1 (installed by npm ci)

Install frontend dependencies and build everything:

```sh
make doctor
make build NATIVE=1
```

For the full build interface, run `make help` or read [the build guide](docs/BUILDING.md). Omit `NATIVE=1` if you do not want to build the optional Fortran worker.

For a quick source audit, run `./scripts/verify-source.sh`. Before publishing a release, run `./scripts/release-check.sh`; it is deliberately strict and requires Erlang, rebar3, Node.js, npm, and an installed Playwright Chromium browser so a source-only check cannot be mistaken for a release build. Sass and Elm are installed from the locked npm dependencies. Install the test browser with `npx playwright install chromium`. Run `npm run test:rtc` for real browser audio and screen-sharing regressions with fixture signaling and synthesized input devices.

Create a PostgreSQL database, then run:

```sh
cp .env.development.example .env
./scripts/start.sh
```

Open `http://localhost:8080`.

For the bundled development database helper:

```sh
guix shell postgresql -- ./scripts/dev-db.sh start
./scripts/start.sh --build
```

For a production host, follow [the deployment guide](deploy/README.md). It includes systemd and Caddy configuration, updates, verification, and rollback guidance. See [the 1.7.2 changes](RELEASE_NOTES_1.7.2.md) and [verified build status](BUILD_STATUS.md).

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
