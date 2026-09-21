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
  echo: async (claim, client) => client.option(claim, 'text', '')
});
```

`listen()` is `commandWorker(...).run()`. Named options are also available as `commandOption(claim, 'text')`. The worker renews each claim before dispatch, replies when a handler returns a string or `{body}`, and fails thrown handlers without poisoning the durable queue. Pass an `AbortSignal` to `run({signal})` for graceful shutdown.

A no-code AI chatbot does not need this SDK. Create a Developer Application, paste a provider key, and enable mention replies in the app.
