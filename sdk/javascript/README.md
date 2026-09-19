# Plainwire Bot SDK for JavaScript

Zero-dependency ESM client for Node.js 20+ and runtimes with `fetch`. Remote instances require HTTPS and redirects are refused.

```js
import { PlainwireBot } from './plainwire-bot.mjs';
const bot = new PlainwireBot('https://chat.example.com', process.env.PLAINWIRE_BOT_TOKEN);
console.log((await bot.me()).json());
```
