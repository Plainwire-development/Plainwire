# Plainwire documentation

These notes match the 2.8.0 tree. PostgreSQL is required. Redis and ScyllaDB are optional.

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
* [Reporting and moderation](REPORTING.md) — submitted evidence, review workflows, privacy, and retention
* [Group call invitations](GROUP_CALL_INVITATIONS.md)
* [Call health](CALL_HEALTH.md)
* [Cloudflare TURN](CLOUDFLARE_TURN.md)
* [Client themes and plugins](CLIENT_EXTENSIONS.md)
* [Security](SECURITY.md)
* [Encrypted private DMs](END_TO_END_ENCRYPTION.md) — DM-wide and individual locks, private embeds, key exchange, and device access
* [2.8.0 security review](SECURITY_AUDIT_2.8.0.md)
* [2.7.0 security review](SECURITY_AUDIT_2.7.0.md)
* [2.6.3 audit and fixes](SECURITY_AUDIT_2.6.3.md)

Older release notes live next to the README (`RELEASE_NOTES_*.md`). They describe the release they were written for; they are not a second copy of this index.

The [2.6.5 audit record](SECURITY_AUDIT_2.6.5.md) documents the latest permission, admin lifecycle, and call-window fixes.

The [2.8.0 release notes](../RELEASE_NOTES_2.8.0.md) cover reversible DM encryption, individual locks, authenticated message identities, device controls, and encrypted link/GIF previews. The [2.7.0 release notes](../RELEASE_NOTES_2.7.0.md) cover the preceding call, mobile, and bot SDK improvements.
