import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const read = path => readFileSync(path, 'utf8');
const db = read('src/pw_db.erl')+'\n'+read('src/pw_db_schema.erl');
const api = read('src/pw_api.erl');
const ai = read('src/pw_ai_bot_dispatcher.erl');
const interaction = read('src/pw_app_interaction_dispatcher.erl');
const bridge = read('priv/static/elm-bridge.js');
const types = read('priv/static/elm/src/Types.elm');
const composer = read('priv/static/elm/src/View/Composer.elm');
const js = read('sdk/javascript/plainwire-bot.mjs');
const python = read('sdk/python/plainwire_bot.py');
const go = read('sdk/go/plainwirebot/client.go');
const openapi = read('docs/bot-api.openapi.yaml');
const env = read('.env.example');

assert.match(db, /\{51, \[[\s\S]*ai_chat_enabled[\s\S]*ai_provider_check/, '2.4 installs provider-aware AI chat settings');
assert.match(db, /ChatEnabled orelse maps:get\(\<<"enabled">>/, 'enabling mention chat also enables the AI connector');
assert.match(db, /maybe_enqueue_ai_chat[\s\S]*is_voice_note_body[\s\S]*ai_chat_enabled=true/, 'AI chat ignores bots and voice notes and is opt-in');
assert.match(db, /maybe_promote_raw_argument[\s\S]*primary_string_option/, 'slash-command text is promoted into a named option when possible');
assert.match(db, /options => command_options_from_args\(Args\)/, 'command claims expose Discord-style named options');
assert.match(db, /guild_id => Sid/, 'command claims include a Discord-style guild_id alias');
assert.match(api, /invoke_command_args\(M\)[\s\S]*<<"options">>/, 'command invoke accepts named options without a raw JSON blob');
assert.match(api, /<<"typed_command_options">>[\s\S]*<<"ai_commands">>/, 'Bot API discovery advertises typed options and hosted AI commands');
assert.match(ai, /A Plainwire member mentioned you or replied to you/, 'hosted AI chat prompts are conversation-shaped rather than JSON dumps');
assert.match(interaction, /data => #\{name => maps:get\(command, Job\), options => Options/, 'interaction webhooks include Discord-like data.options');
assert.match(bridge, /Add option[\s\S]*typed fields instead of writing JSON/, 'Developer Portal builds command options visually');
assert.match(bridge, /Answer mentions and replies[\s\S]*chat_trigger/, 'Developer Portal can turn an API key into a mention chatbot');
assert.match(types, /type alias BotCommandOption/, 'slash-command suggestions know option names');
assert.match(composer, /commandOptionHint/, 'composer shows Discord-style option hints');
assert.match(js, /export function commandOption/, 'JavaScript SDK reads named command options');
assert.match(js, /listen\(handlers, options = \{\}\) \{ return this\.commandWorker/, 'JavaScript SDK listen() runs the command worker');
assert.match(python, /def command_option\(/, 'Python SDK reads named command options');
assert.match(go, /func \(c CommandClaim\) Option\(/, 'Go SDK reads named command options');
assert.match(openapi, /guild_id:[\s\S]*options:/, 'OpenAPI documents guild_id and named options on claims');
assert.match(env, /PLAINWIRE_AI_CHAT_MENTIONS_PER_USER_PER_MINUTE=20/, 'mention chat has a documented per-user rate limit');

console.log('PASS: 2.4 no-code AI chatbot, typed command options, and Discord-like bot DX contract');
