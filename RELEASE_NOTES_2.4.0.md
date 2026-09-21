# Plainwire 2.4.0

Plainwire 2.4.0 is a bot-engine release: Discord-style slash commands, a no-code AI chatbot, and a less JSON-heavy developer experience.

## No-code AI chatbot

- Developer Applications can connect OpenAI, Anthropic, Gemini, OpenRouter, Groq, Mistral, Ollama, or any OpenAI-compatible endpoint without writing a worker.
- Paste a provider key to run AI slash commands, answer `@mentions`, and continue when members reply to the bot.
- Mention chat is opt-in, never triggered by other bots, and ignores voice notes.
- Recent channel context is off by default. When enabled, Plainwire sends a bounded window only after the same claim-time authorization used for commands.
- 4xx provider errors fail the invocation instead of retrying forever. Activity for every installation is visible in the Developer Portal.

## Discord-style commands without JSON

- The Developer Portal builds typed command options visually. Slash-command suggestions show those option names in chat.
- `/echo hello` promotes the typed text into the command's string option when there is one, so workers read `claim.options.text` instead of parsing a raw blob.
- Command claims include `options` and a `guild_id` alias. Interaction webhooks include `data.name` and `data.options` while keeping the previous `command`/`arguments` fields.
- JavaScript, Python, and Go SDKs expose `option()` / `Option()` helpers. `listen()` runs the existing command worker.

## Host control plane

- Ban, suspend, and restore account actions in the host admin panel submit again. Footer buttons such as **Ban account** are associated with the moderation form, so they send `POST /api/users/:id/moderation` instead of doing nothing.

## Compatibility and upgrade

- Existing Bot API v1 clients keep working. Queue workers, signed interaction endpoints, and 2.2/2.3 SDKs remain valid.
- Database migration 51 adds AI provider, chat-trigger, and context columns to developer applications.
- Hosted AI loopback destinations such as Ollama still require `PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP=true`.
- The release is validated by `make check`, including browser, responsive UI, WebRTC, SDK, and backend suites.
