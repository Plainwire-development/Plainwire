# Plainwire Bot SDK for JavaScript

Zero-dependency ESM client for Node.js 20+ and runtimes with `fetch`. Remote instances require HTTPS and redirects are refused.

```js
import { PlainwireBot } from './plainwire-bot.mjs';
const bot = new PlainwireBot('https://chat.example.com', process.env.PLAINWIRE_BOT_TOKEN);
console.log((await bot.me()).json());
```

Deploy the desired command set and run bounded concurrent handlers:

```js
await bot.syncCommands([
  {name: 'echo', description: 'Repeat text', options: [{name: 'text', type: 'string', required: true}]}
]);
await bot.listen({
  echo: async interaction => {
    const text = interaction.getString('text', true);
    await interaction.reply({content: text});
  }
});
```

`listen()` is `commandWorker(...).run()`. Handlers receive a `CommandInteraction` with the original claim fields, `commandName`, `channelId`, `guildId`, typed `getString/getInteger/getBoolean` options, and `deferReply/reply/fail`. Each interaction permits one final reply or failure. `reply()` accepts a string or `{content}`/`{body}`. Returning a string or `{body}` still works with existing `(claim, client)` handlers. Named options remain available as `commandOption(claim, 'text')`.

The worker defers before dispatch and renews active leases, claims only as much work as it can start, and fails missing replies. Handler exceptions produce a generic user-visible error; details go to `onError`. Do not log claim tokens or provider secrets in that hook. Pass an `AbortSignal` to `run({signal})` for graceful shutdown: active handlers finish before exit.

HTTP requests retain their timeout while streaming bounded bodies. `request(method, path, body, {signal})` supports cancellation. Only explicit HTTP 429 responses are retried (up to `maxRateLimitRetries`, default 2), respecting `Retry-After` waits up to 60 seconds. Longer limits are surfaced as `PlainwireAPIError.retryAfterMs`. Transport errors and HTTP 5xx mutations are surfaced without automatic replay because the server may already have committed them. Request paths must stay inside `/api/bot/v1`.

The interaction names follow familiar Discord conventions; this SDK uses Plainwire's durable claims and does not provide Discord gateway compatibility or ephemeral replies.

Typed getters take `(name, required = false)`: missing optional values return `null`, missing required values throw, and present values must match their type. Low-level `commandOption` retains its separate fallback-value argument.

A no-code AI chatbot does not need this SDK. Create a Developer Application, paste a provider key, and enable mention replies in the app.
