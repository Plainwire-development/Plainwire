# Bots

Plainwire 2.0 has server-scoped bot accounts. A bot is a real server member with its own user id, role assignments and permission checks. Creating a bot does not grant administrator access.

Server members with **Manage bots** can create, rotate and delete bot credentials from the server integrations UI. The `pwb_...` token is shown when it is created or rotated. Plainwire stores only its hash, so a lost token must be rotated rather than recovered.

## Authentication

HTTP bot requests use:

```text
Authorization: Bot pwb_...
```

The same header authenticates `/ws`. Bot WebSockets are deliberately narrower than browser WebSockets: bots can ping and manage subscriptions, but cannot impersonate client voice, call or typing state.

## HTTP API

The server-scoped API includes:

```text
GET  /api/bot/me
GET  /api/bot/server
GET  /api/bot/channels
GET  /api/bot/channels/:channel_id/messages
POST /api/bot/channels/:channel_id/messages
POST /api/bot/messages/:message_id/delete
POST /api/bot/messages/:message_id/reaction
```

Message reads and mutations pass through the normal channel membership and role permission checks. Bot rate limits are shared across Plainwire nodes when Redis is enabled and remain locally rate-limited when Redis is not available.

## Erlang SDK

`sdk/erlang` contains the supported Erlang SDK. It uses Gun for API requests and a second Gun connection for realtime WebSocket events. The realtime connection reconnects with bounded exponential backoff and restores its subscriptions after reconnecting.

See `sdk/erlang/README.md` and `sdk/erlang/examples/echo_bot.erl`.

## Removing a bot

Deleting a bot revokes its token by deleting the bot record and bot user. Content authored through the current bot API is cleaned up rather than leaving a login-capable ghost account.
