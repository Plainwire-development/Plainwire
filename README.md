# Plainwire Relay

Plainwire Relay is a hosted chat and forum platform with real-time messaging, servers, direct messages, forums, profiles, notifications, and voice calls.

Plainwire is designed to run on our servers. Users are not expected to clone the project or run their own instance. The source can still be built locally for development, testing, or self-hosting, but the main use case is the hosted Plainwire service.

## Version

**Plainwire Relay 1.1.0**

This release removes generated demo content. There are no fake users, bots, seeded messages, or sample threads. On first boot, Plainwire only creates the default empty forum categories.

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

* Erlang/OTP
* Cowboy
* PostgreSQL
* epgsql
* Elm
* SCSS
* WebSocket
* WebRTC
* rebar3

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
elm make src/Main.elm --output=../../app.js --optimize
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
| `PLAINWIRE_PBKDF2_ITERS` |    `160000` | Password hash iteration count                                 |
| `COOKIE_SECURE`          |     `false` | Set to `true` when running behind HTTPS                       |

Generate an encryption key:

```sh
python3 -c "import os,base64; print(base64.b64encode(os.urandom(32)).decode())"
```

Example production-style configuration:

```sh
COOKIE_SECURE=true
PLAINWIRE_ENC_KEY=your-base64-key-here
PLAINWIRE_DB_HOST=localhost
PLAINWIRE_DB_USER=plainwire
PLAINWIRE_DB_PASS=plainwire
PLAINWIRE_DB_NAME=plainwire
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
* Expose only the reverse proxy publicly
* Set `PLAINWIRE_ENC_KEY`
* Back up PostgreSQL regularly
* Keep dependencies updated

WebRTC voice uses STUN for peer-to-peer connections. Some networks may require TURN support later.

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

