# Plainwire 2.6.0

2.6.0 adds live Mac app presence metadata for native clients. It carries no
database migration and no new environment variables. Installs on 2.5.8 can
upgrade directly.

## Mac app presence

Authenticated WebSocket connections from Plainwire for Mac identify their
platform. Presence snapshots now include a `platforms` map, and online/status
events include `client_platform` when a visible Mac app session exists. The
platform clears when that session disconnects or becomes invisible, even if
the same account remains online in a browser.

Presence remains scoped to visible sessions. Redis-backed multi-node installs
share the Mac indicator with the same expiry behavior as presence status.
Browser and bot sessions are unmarked, and existing clients can ignore the
new fields.
