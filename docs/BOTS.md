# Bots

Plainwire 2.4 has server-scoped bot accounts, Discord-style slash commands, and a stable language-neutral Bot API v1. A bot is a real server member with its own user id, role assignments and permission checks. Creating a bot does not grant administrator access.

You can run a bot three ways:

1. **No code.** Create a Developer Application, paste an AI provider key, and turn on mention replies. Plainwire hosts the bot.
2. **A little code.** Register slash commands visually and handle them with a first-party SDK worker.
3. **Full control.** Use Bot API v1 over HTTPS, or receive signed interaction POSTs at your own endpoint.

Server members with **Manage bots** can create, rotate and delete bot credentials from the server integrations UI. The `pwb_...` token is shown only when it is created or rotated. Plainwire stores only its hash, so a lost token must be rotated rather than recovered.

Bot accounts receive the same role and channel permission checks as normal server members and are visibly marked with a `BOT` badge in supported client surfaces.

## Authentication

HTTP bot requests use:

```text
Authorization: Bot pwb_...
```

Remote bot clients should use HTTPS. The first-party C, C++, Go, Rust, Python and JavaScript SDKs reject remote plaintext HTTP. Loopback HTTP is permitted for development.

The same header authenticates `/ws`. Bot WebSockets are deliberately narrower than browser WebSockets: bots can ping and manage permitted subscriptions, but cannot impersonate client voice, call or typing state.

## API discovery

A bot can inspect the active Bot API contract:

```text
GET /api/bot/v1
```

The response identifies the API version, feature set, command lease policy and effective per-minute bot limits. Use this endpoint rather than assuming every self-hosted Plainwire instance has identical operator-tuned limits.

## Bot API v1

The canonical machine-readable API description is [`docs/bot-api.openapi.yaml`](bot-api.openapi.yaml). It is suitable for documentation tooling and client generation. Plainwire uses `Authorization: Bot ...`; generators that assume the standard `Bearer` prefix must override that prefix.


Core routes include:

```text
GET    /api/bot/v1
GET    /api/bot/v1/me
GET    /api/bot/v1/server
GET    /api/bot/v1/channels
POST   /api/bot/v1/channels
GET    /api/bot/v1/channels/:channel_id/messages
POST   /api/bot/v1/channels/:channel_id/messages
GET    /api/bot/v1/channels/:channel_id/pins
POST   /api/bot/v1/channels/:channel_id/settings
POST   /api/bot/v1/messages/:message_id/delete
POST   /api/bot/v1/messages/:message_id/reaction
POST   /api/bot/v1/messages/:message_id/edit
POST   /api/bot/v1/messages/:message_id/pin
GET    /api/bot/v1/messages/:message_id/context

GET    /api/bot/v1/members?after=0&limit=50
GET    /api/bot/v1/members/:user_id
POST   /api/bot/v1/members/:user_id/roles
POST   /api/bot/v1/members/:user_id/kick
POST   /api/bot/v1/members/:user_id/ban
POST   /api/bot/v1/members/:user_id/unban
GET    /api/bot/v1/roles
POST   /api/bot/v1/roles
POST   /api/bot/v1/roles/:role_id
DELETE /api/bot/v1/roles/:role_id
GET    /api/bot/v1/bans
GET    /api/bot/v1/wires
POST   /api/bot/v1/wires

GET    /api/bot/v1/commands
POST   /api/bot/v1/commands
PUT    /api/bot/v1/commands
DELETE /api/bot/v1/commands/:command_id
GET    /api/bot/v1/commands/claims?limit=10
POST   /api/bot/v1/commands/claims/:invocation_id/defer
POST   /api/bot/v1/commands/claims/:invocation_id/respond
POST   /api/bot/v1/commands/claims/:invocation_id/fail
```

The existing `/api/bot/*` message routes remain available for compatibility with 2.0 bots.

## Commands

Bots can register server commands. Command names are lowercase identifiers beginning with a letter and containing letters, digits, `_` or `-`. Users invoke them like Discord slash commands: type `/`, pick a command, and fill the shown options.

You do not need to hand-write JSON to define those options. The Developer Portal command builder and the SDKs both accept ordinary objects:

```js
{name: 'echo', description: 'Repeat text', options: [{name: 'text', type: 'string', required: true}]}
```

For deployment, prefer `PUT /api/bot/v1/commands` with `{ "commands": [...] }`. Like a bulk application-command update, it atomically upserts the desired definitions and removes stale commands. The list is capped at 100 and a conflict rolls back the whole sync, so a failed deploy cannot leave half of a command set active. `POST /commands` remains useful for interactive one-command updates.

A command definition can include up to 25 option descriptors. Supported option types are:

```text
string
integer
number
boolean
user
channel
```

When a user types `/echo hello`, Plainwire stores both the original text and, when the command has a single string option, that value under the option name (`text` in the example). Workers can read `claim.options.text` instead of parsing JSON or a raw argument string.

Plainwire currently accepts either a bounded raw argument string or a bounded structured argument object. Command arguments are encrypted before durable storage.

When a user invokes a registered command, Plainwire writes the visible `/command ...` message normally and places an invocation in the owning bot's durable queue.

### Claiming work

Workers request a batch:

```text
GET /api/bot/v1/commands/claims?limit=10
```

Each claim includes a one-time `claim_token` and lease expiry. Plainwire stores only the token hash. Several workers for the same bot can claim concurrently because PostgreSQL row locks and `SKIP LOCKED` prevent one live invocation from being handed to two workers at the same time.

If a worker disappears, the lease expires and the invocation can be reclaimed. The retry count is bounded so permanently broken work does not stay in the queue forever.

Long-running handlers can renew a live lease before it expires:

```text
POST /api/bot/v1/commands/claims/:id/defer
```

Send the `claim_token` and an optional `lease_ms` between 5,000 and 120,000. Renewal never changes the claim token and cannot revive an expired, completed or failed invocation.

### Completing a command

```text
POST /api/bot/v1/commands/claims/:id/respond
```

with:

```json
{
  "claim_token": "pwc_...",
  "body": "command response"
}
```

Plainwire posts the bot response as a normal reply to the original command message. Duplicate completion after a successful response is idempotent.

### Permanently rejecting work

```text
POST /api/bot/v1/commands/claims/:id/fail
```

with a claim token and bounded reason. This marks the invocation failed instead of repeatedly redelivering work that the bot knows it cannot process.

## Rate limits

Bot rate limits use Redis for cross-node coordination when Redis is available and fall back to the local limiter when Redis is unavailable. Operators can tune the limits through the documented `PLAINWIRE_BOT_*` environment variables.

Limits are split into reads, message sends, mutations and command claims so high-throughput command workers do not need an unlimited general-purpose API token.

## Realtime subscriptions

Bots may authenticate to `/ws` and subscribe only to scopes they are permitted to observe. Existing server/channel/direct/thread/forum subscription checks remain in force. Plainwire periodically revalidates bot authorization so removing a bot or permission does not leave a permanently privileged socket behind.


## Developer Applications

Plainwire 2.4 can package bot commands as a reusable Developer Application. An application can be installed into multiple servers, where each installation receives its own server-scoped bot identity and credential. Application owners may publish an app to the public directory, but connector secrets and private owner metadata are never part of public app responses.

A command handler can be `queue` (claimed through Bot API v1), `webhook` (delivered to an HMAC-signed HTTPS interaction endpoint), or `ai` (a hosted provider connector). Server managers can narrow individual commands by member, channel, or role. Plainwire rechecks those rules, the invoking member's channel access, and the bot's channel access again at claim time before command arguments are decrypted for delivery.

For signed interaction endpoints, verify `X-Plainwire-Interaction-Timestamp` and `X-Plainwire-Interaction-Signature`; the signature is `v1=` followed by the lowercase HMAC-SHA256 hex digest of `timestamp + "." + raw_json_body`. The JSON body includes the original `command`/`arguments` fields and a Discord-style `data.name` / `data.options` object. Use HTTPS in production. Plain HTTP application endpoints are accepted only for exact loopback development when the host explicitly enables `PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP=true`.

### No-code AI chatbot

The AI handler can run slash commands and, separately, answer ordinary chat:

1. Open **Developer Portal**, create an application, and open **AI assistant**.
2. Pick OpenAI, Anthropic, Gemini, OpenRouter, Groq, Mistral, Ollama, or a custom OpenAI-compatible endpoint.
3. Paste an API key. Keys and instructions are encrypted at rest and never shown again.
4. Enable **AI commands** for `/command` handlers, and/or **Answer mentions and replies** to make the installed bot a chatbot.

Mention chat creates a `/chat` command automatically. The bot replies only when mentioned, or when a member replies to one of its messages. Bot messages never trigger another AI bot. Recent channel context is off by default and, when enabled, is a bounded window assembled only after the same claim-time authorization used for commands.

Hosted AI rate limits, response sizes, timeouts, retries, and worker concurrency are bounded by the server. Ollama and other loopback HTTP endpoints require `PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP=true`.

The optional AI handler stores its API key and system prompt encrypted at rest. Command-only mode sends the invoked command and arguments. Chat mode sends the triggering message, your instructions, and the optional bounded history.

## First-party SDKs

The repository includes first-party clients for:

- `sdk/c`
- `sdk/cpp`
- `sdk/go`
- `sdk/rust`
- `sdk/erlang`
- `sdk/python`
- `sdk/javascript`

Every SDK exposes messages, channels, roles, moderation, wires, cursor-paginated members, atomic command sync and renewable durable command claims. The Go, Python and JavaScript packages also include bounded concurrent command workers with handler maps and automatic lease extension. The API remains ordinary HTTPS/JSON, so any other language can integrate without a proprietary runtime.

Each SDK README contains a small command or transport example and language-specific build instructions.

## Minimal JavaScript command bot

```js
import { PlainwireBot } from './sdk/javascript/plainwire-bot.mjs';

const bot = new PlainwireBot(process.env.PLAINWIRE_BASE_URL, process.env.PLAINWIRE_BOT_TOKEN);
await bot.syncCommands([
  {name: 'ping', description: 'Replies with pong'}
]);
await bot.commandWorker({
  ping: async claim => `pong (attempt ${claim.attempt})`,
  echo: async (claim, client) => client.option(claim, 'text', '')
}).run();
```

`run()` keeps claiming until its optional `AbortSignal` is cancelled. Return a string to reply automatically, return `{ body: "..." }`, or return nothing after responding manually through the client.

## Minimal Python command bot

```python
import os
from plainwire_bot import Client

bot = Client(os.environ["PLAINWIRE_BASE_URL"], os.environ["PLAINWIRE_BOT_TOKEN"])
bot.sync_commands([{"name": "ping", "description": "Replies with pong"}])
bot.command_worker({"ping": lambda claim, client: "pong"}).run()
```

## C example

```c
pw_bot_client client;
if (pw_bot_client_init(&client, "https://chat.example.com", getenv("PLAINWIRE_BOT_TOKEN")) != 0) {
    return 1;
}
```

See `sdk/c/README.md` for request and command helpers.

## Go example

```go
bot, err := plainwirebot.New("https://chat.example.com", os.Getenv("PLAINWIRE_BOT_TOKEN"))
if err != nil {
    log.Fatal(err)
}
me, err := bot.Me(ctx)
```

## Python example

```python
from plainwire_bot import Client

bot = Client("https://chat.example.com", "pwb_...")
print(bot.me().json())
bot.send_message(42, "hello from Python")
```

## Erlang example

```erlang
{ok, Bot} = plainwire_bot:start_link(#{
    base_url => <<"https://chat.example.com">>,
    token => os:getenv("PLAINWIRE_BOT_TOKEN")
}),
{ok, Me} = plainwire_bot:me(Bot).
```

## Removing a bot

Deleting a bot removes its bot identity and revokes its token. Durable command definitions and invocations are removed through foreign-key cascades. Content cleanup follows the existing Plainwire bot-account deletion behavior rather than leaving a login-capable ghost account.
