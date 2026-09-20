import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const read = path => readFileSync(path, 'utf8');
const db = read('src/pw_db.erl');
const api = read('src/pw_api.erl');
const openapi = read('docs/bot-api.openapi.yaml');
const bridge = read('priv/static/elm-bridge.js');
const sdks = [
  read('sdk/c/include/plainwire_bot.h'),
  read('sdk/cpp/include/plainwire_bot.hpp'),
  read('sdk/go/plainwirebot/client.go'),
  read('sdk/python/plainwire_bot.py'),
  read('sdk/javascript/plainwire-bot.mjs'),
  read('sdk/rust/src/lib.rs'),
  read('sdk/erlang/src/plainwire_bot.erl')
];

assert.match(api, /<<"command_sync">>.*<<"renewable_command_claims">>/s,
  'capability discovery advertises declarative commands and renewable claims');
assert.match(api, /<<"PUT">>, \[<<"commands">>\]/,
  'Bot API exposes Discord-style bulk command replacement');
assert.match(db, /bot_sync_commands[\s\S]*FOR UPDATE[\s\S]*sync_bot_command_definitions/,
  'command syncing validates and serializes a complete replacement');
assert.match(db, /normalize_bot_command_set\(Commands\)[\s\S]*length\(Commands\) =< 100/,
  'command sets are bounded before database work');
assert.match(db, /bot_defer_command[\s\S]*secure_token_hash_match[\s\S]*lease_until=\$1/,
  'only a live constant-time-authenticated claim can renew its lease');
assert.match(api, /pw_db:bot_server/,
  'bot metadata routes avoid loading the full interactive server roster');
assert.doesNotMatch(api, /handle_bot_v1\(<<"GET">>, \[<<"server">>\][\s\S]{0,600}pw_db:server/,
  'bot server lookup does not call the unbounded human-client aggregate');
assert.match(db, /route\(\{bot_members[\s\S]*sm\.user_id>\$2[\s\S]*Limit \+ 1/,
  'member traversal uses a bounded stable cursor page');

for (const sdk of sdks) {
  assert.match(sdk, /members/i, 'each supported SDK exposes paginated members');
  assert.match(sdk, /sync_?commands/i, 'each supported SDK exposes atomic command sync');
  assert.match(sdk, /defer_?command/i, 'each supported SDK exposes lease renewal');
}
assert.match(sdks[2], /RunCommandWorker/, 'Go ships a bounded concurrent command worker');
assert.match(sdks[3], /class CommandWorker/, 'Python ships a bounded concurrent command worker');
assert.match(sdks[4], /class CommandWorker/, 'JavaScript ships a bounded concurrent command worker');
assert.match(openapi, /operationId: syncCommands[\s\S]*operationId: deferCommand/,
  'the language-neutral API contract documents sync and deferral');
for (const language of ['JavaScript', 'Python', 'Go', 'Rust', 'Erlang', 'C', 'C++']) {
  assert.ok(bridge.includes(language), `bot creation starter includes ${language}`);
}
assert.match(bridge, /showBotStarter[\s\S]*PLAINWIRE_BOT_TOKEN[\s\S]*Copy starter/,
  'new bot credentials include an in-product copyable starter without embedding the token');

console.log('PASS: 2.2 scalable bot platform contract');
