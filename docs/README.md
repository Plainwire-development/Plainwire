# Plainwire documentation

These notes match the 2.5.0 tree. PostgreSQL is required. Redis and ScyllaDB are optional.

## Run it

* [README](../README.md) — what Plainwire is, local install, and the environment variables most people set
* [Building](BUILDING.md) — Make, OTP 27–29, frontend toolchain, checks
* [Deploy](../deploy/README.md) — systemd, HTTPS, backups, and what is optional in production
* [Admin](ADMIN.md) — host control plane, roles, and account actions

## Optional backends

* [Redis](REDIS.md) — ephemeral acceleration. Off by default
* [ScyllaDB](SCYLLA.md) — optional message history. PostgreSQL stays mandatory
* [Clustering](CLUSTERING.md) — optional Partisan profile, one WebSocket owner
* [Scaling](SCALING.md) — pool limits and load checks

## Product behavior that has its own page

* [Bots](BOTS.md) — Bot API v1, slash commands, and the no-code assistant limits the server actually enforces
* [Webhooks](WEBHOOKS.md)
* [Screen sharing](SCREEN_SHARING.md)
* [Call health](CALL_HEALTH.md)
* [Cloudflare TURN](CLOUDFLARE_TURN.md)
* [Client themes and plugins](CLIENT_EXTENSIONS.md)
* [Security](SECURITY.md)

Older release notes live next to the README (`RELEASE_NOTES_*.md`). They describe the release they were written for; they are not a second copy of this index.
