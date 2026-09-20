# Plainwire Bot SDK for JavaScript

Zero-dependency ESM client for Node.js 20+ and runtimes with `fetch`. Remote instances require HTTPS and redirects are refused.

```js
import { PlainwireBot } from './plainwire-bot.mjs';
const bot = new PlainwireBot('https://chat.example.com', process.env.PLAINWIRE_BOT_TOKEN);
console.log((await bot.me()).json());
```

Deploy the desired command set and run bounded concurrent handlers:

```js
await bot.syncCommands([{name: 'ping', description: 'Replies pong'}]);
await bot.commandWorker({ping: async () => 'pong'}).run();
```

The worker renews each claim before dispatch, replies when a handler returns a string or `{body}`, and fails thrown handlers without poisoning the durable queue. Pass an `AbortSignal` to `run({signal})` for graceful shutdown.
