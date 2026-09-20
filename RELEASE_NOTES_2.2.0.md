# Plainwire 2.2.0

Plainwire 2.2.0 is a minor release centered on a more capable, scalable bot platform, with call-control and desktop-browser quality-of-life fixes.

## Bot platform

- Adds atomic command deployment through `PUT /api/bot/v1/commands`. A bot can sync up to 100 desired command definitions in one transaction; omitted commands are removed and a conflict rolls the whole change back.
- Adds renewable durable-command claims through the authenticated `defer` endpoint, with bounded 5–120 second extensions for long-running handlers.
- Adds stable cursor pagination for server rosters (`GET /api/bot/v1/members?after=...&limit=...`) with a hard 200-member page bound.
- Removes an unbounded roster load from ordinary bot startup: bot server/channel metadata now uses a dedicated query instead of constructing and discarding the complete member list.
- Expands capability discovery so bots can feature-detect command sync, renewable claims and paginated members together with effective limits.
- Keeps command arguments encrypted at rest, claim tokens hash-only and constant-time checked, claim-time authorization revalidation, bounded retry attempts and PostgreSQL `SKIP LOCKED` concurrency.

## SDKs and developer experience

- Brings C, C++, Go, Rust, Erlang, Python and JavaScript SDKs to 2.2.0 with APIs for command sync, lease renewal and paginated members.
- Adds bounded concurrent handler-map workers to Go, Python and JavaScript, including automatic lease extension and automatic reply/failure handling.
- Adds an in-product language picker after bot creation with copyable starters for every supported SDK, while keeping the one-time token separate from source code.
- Extends the language-neutral OpenAPI description to cover the broader bot surface: channels, messages, context, pins, roles, members, moderation, wires and durable commands.
- Refreshes the bot guide and per-language quick starts with deployment and worker examples.

## Calls and desktop quality of life

- Corrects call overlay control alignment and the optical centering of voice-channel icons.
- Requests window/system audio using current display-capture constraints while preserving fallback behavior when a browser or operating system does not expose shareable audio.
- Restores reliable paste behavior by preserving the browser's native editable-control context menu instead of attempting a permission-sensitive scripted clipboard read.

## Compatibility and upgrade

- Bot API v1 remains backward compatible. Existing one-at-a-time command registration, claim, response and failure routes are unchanged.
- No database migration or new runtime dependency is required.
- Remote bot clients still require verified HTTPS; exact loopback HTTP remains available for local development.
