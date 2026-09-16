# Plainwire Relay

Plainwire is a chat app for communities, friends, and small groups.

It has servers, channels, DMs, group chats, forums, voice calls, screen sharing, file uploads, profiles, and live presence without trying to turn every feature into its own product.

Plainwire is built with Erlang/OTP, Cowboy, PostgreSQL, Elm, WebSocket, and WebRTC.

## Using Plainwire

The easiest way to use Plainwire is through a hosted instance.

Plainwire can also be self-hosted if you want full control over the server and database. Self-hosting is supported, but it is not the recommended setup for most people. A proper deployment requires PostgreSQL, HTTPS, TURN for reliable calls, persistent file storage, and some server administration.

If you just want to use Plainwire, you should not need to worry about any of that.

## Features

* Servers and channels with custom roles and per-server profiles
* Direct messages and group chats
* Forums and threads using f/ and t/ navigation
* Voice calls
* Screen sharing with optional shared audio and collapsible viewers
* File uploads
* Profiles, friends, blocking, presence, and realtime typing
* Message replies, Markdown, and emoji reactions with activity notifications
* Light, dark, and system themes
* Audio device selection and mic testing
* Mobile and desktop layouts
* PostgreSQL-backed persistence
* STUN and TURN support for calls
* Wires for sharing/joining servers, with legacy invite-link compatibility
* Optional server-proxied KLIPY GIF search
* A resumable, mobile-aware first-run Plainwire guide for new accounts
* Realtime state recovery and self-healing call audio designed to avoid routine page refreshes

Plainwire is not end-to-end encrypted. Messages may be encrypted at rest, but the server must still be able to read them while operating the service.

## Self-hosting

Plainwire is self-hostable, but expect a little setup.

You will need:

* Erlang/OTP 25+
* PostgreSQL 13+
* rebar3
* Node.js 22+
* npm
* GNU Make
* Python 3.9+

Elm is installed through the locked npm dependencies.

Optional native call-health tooling also requires a C compiler and `gfortran`.

Clone the repository, then build it:

```sh
make doctor
make build
```

Create a PostgreSQL database and copy the development environment file:

```sh
cp .env.development.example .env
./scripts/start.sh
```

Plainwire will be available at:

```text
http://localhost:8080
```

For the bundled development database helper:

```sh
guix shell postgresql -- ./scripts/dev-db.sh start
./scripts/start.sh --build
```

See [the deployment guide](deploy/README.md) before exposing an instance to the internet.

## Configuration

Most configuration is done through environment variables.

A basic production setup looks like this:

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
```

See `.env.example` for the full list.

### First-run guide and source link

Fresh accounts receive Plainwire's interactive first-run guide. Existing accounts are not forced back through onboarding after an upgrade. Set the repository URL shown by Help/onboarding with:

```sh
PLAINWIRE_SOURCE_REPOSITORY=https://github.com/Plainwire-development/Plainwire
```

Only an HTTPS repository URL is exposed to the browser; private server credentials are not part of client config.

### GIF search

KLIPY integration is optional. Configure the provider key only on the server:

```sh
PLAINWIRE_KLIPY_API_KEY=replace-with-your-server-side-key
PLAINWIRE_KLIPY_CONTENT_FILTER=medium
PLAINWIRE_KLIPY_COUNTRY=US
PLAINWIRE_KLIPY_LOCALE=en_US
```

The API key is used by the backend proxy and is never sent to the browser. Plainwire still works normally when KLIPY is disabled.

### Roles, server profiles, and Wires

Server owners can define custom roles and permission sets, and members can use server-specific nickname/avatar/bio details. Moderation and hierarchy checks are enforced by the backend even when a client is modified. Server share/join links are called **Wires**; older inbound invite URLs remain accepted for compatibility.

### Voice calls

For reliable calls outside a local network, configure a TURN server.

Plainwire supports coturn and external TURN services.

Example:

```sh
PLAINWIRE_TURN_URLS=turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp,turns:turn.example.com:5349?transport=tcp
PLAINWIRE_TURN_SECRET=replace-with-a-long-random-secret
PLAINWIRE_REQUIRE_TURN=true
```

See [the TURN documentation](docs/CLOUDFLARE_TURN.md) for more information.

## Development

Useful commands:

```sh
make help
make doctor
make build
```

Run the source checks with:

```sh
./scripts/verify-source.sh
```

Run the stricter release checks with:

```sh
./scripts/release-check.sh
```

Browser RTC tests are available with:

```sh
npm run test:rtc
```

More detailed build information is in [docs/BUILDING.md](docs/BUILDING.md).

Portable source archives intentionally omit generated `app.js`, `app.css`, `index.html`, and rich-text bundles. `make build` recreates them from the locked npm dependencies and the current `VERSION`, which prevents a source archive from carrying stale frontend output.

## Optional components

Plainwire has a few optional backend components that are not required for a normal installation.

* [Partisan clustering](docs/CLUSTERING.md)
* [Native call-health analysis](docs/CALL_HEALTH.md)

The native call-health worker uses Fortran and can be enabled with:

```sh
make build NATIVE=1
```

Without it:

```sh
make build
```

## Production

For a public instance:

* use HTTPS
* keep PostgreSQL private
* use a strong encryption key
* configure TURN
* keep uploads on persistent storage
* back up PostgreSQL and uploaded files
* restrict remote media hosts
* keep the server and dependencies updated

Caddy, nginx, and similar reverse proxies work well in front of Plainwire.

### Service control plane

Plainwire 1.8.1 includes an optional host-level operator console. It administers the configured Plainwire service instance itself; it is not a per-server moderation panel. The control plane is disabled by default and runs on a separate Cowboy listener when enabled.

The console is intentionally private-content blind. It can inspect service health, runtime/build information, database and realtime health, aggregate message/upload/call statistics, registered accounts, hosted server metadata, resource usage, operators, and operator audit history. It has no message-body, DM-text, attachment-content, message-search, or verification-secret endpoint.

Operator access is instance-bound:

* no administrator password or reusable key is stored in the source tree;
* each deployment creates a local 256-bit instance secret (production default: `/var/lib/plainwire/admin-instance.key`, mode `0600`);
* the first service owner uses a one-time bootstrap token printed by that running instance plus their normal Plainwire account password;
* every operator then receives their own high-entropy verification key, stored only as an HMAC bound to that instance secret;
* cloning Plainwire creates a different instance secret, so keys created by the clone cannot authenticate to another deployment;
* `viewer` accounts see aggregate overview/host health only, `operator` accounts can inspect content-free user/server/operator/audit metadata, and `owner` accounts additionally manage service-operator access;
* one-time owner-issued enrollment/recovery codes are account-bound and consumed atomically;
* losing the last usable owner key can be recovered only by somebody who controls that host: temporarily enable `PLAINWIRE_ADMIN_LOCAL_RECOVERY=true`, keep the admin listener on loopback, restart, use the one-time recovery token printed locally, then disable local recovery before the next restart.

For a local deployment, enable the control plane and leave its bind address on loopback:

```sh
PLAINWIRE_ADMIN_ENABLED=true
PLAINWIRE_ADMIN_BIND=127.0.0.1
PLAINWIRE_ADMIN_PORT=8090
```

For remote operator access, the recommended deployment is a **separate admin hostname** (for example `control.example.com`) terminated by an HTTPS reverse proxy. Keep the Plainwire admin listener private to the proxy where possible. If you intentionally bind it remotely in production, Plainwire requires `PLAINWIRE_ADMIN_ALLOW_REMOTE=true`, an `https://` `PLAINWIRE_ADMIN_PUBLIC_URL`, and secure admin cookies. Do not expose the emergency local-recovery mode remotely; Plainwire refuses to start with local recovery enabled on a non-loopback admin bind.

Back up the admin instance-secret file together with PostgreSQL. Treat it like other host credentials: source access alone is harmless, but host-secret access is privileged.

Plainwire 1.8.1 also adds **Service controls** to the host console. Operators can publish scheduled or permanent global announcements, pause/resume or retire them in realtime, override whether new account registration is open without restarting the service, and request a lightweight client-state reconciliation without disconnecting active calls. Global announcements use the normal Plainwire visual language, are capped on-screen to prevent banner flooding, support safe same-origin or HTTPS links, and may be dismissible or persistent.

Deployment and update instructions are kept in [deploy/README.md](deploy/README.md).

## Version

Current release: **1.8.1**

Release-specific changes are kept in the release notes rather than this README. Older changes remain available in Git history.

* [1.8.1 release notes](RELEASE_NOTES_1.8.1.md)

## License

Licensed under AGPL-3, and PlainSimple License 1.
Choose what license you want to abide by.

See the repository license file.

## Notice

**This partially uses AI.** but it is ***not*** vibecoded.
