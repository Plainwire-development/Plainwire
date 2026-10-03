import test from 'node:test';
import assert from 'node:assert/strict';
import {PlainwireBot, PlainwireAPIError, commandOption, commandOptions} from '../plainwire-bot.mjs';
const T = 'pwb_' + 'x'.repeat(32);
test('remote HTTP is refused', () => assert.throws(() => new PlainwireBot('http://chat.example', T)));
test('loopback HTTP is accepted', () => { new PlainwireBot('http://127.0.0.1:8080', T); new PlainwireBot('http://localhost:8080', T); });
test('remote HTTPS is accepted', () => new PlainwireBot('https://chat.example', T));
test('token CRLF is refused', () => assert.throws(() => new PlainwireBot('https://chat.example', T + '\r\nx:y')));
test('redirects are explicitly manual', async () => {
  let init;
  const fake = async (_url, opts) => { init = opts; return {status:200, ok:true, headers:{get:()=>null}, arrayBuffer:async()=>new TextEncoder().encode('{}').buffer}; };
  const bot = new PlainwireBot('https://chat.example', T, {fetchImpl:fake});
  await bot.me(); assert.equal(init.redirect, 'manual');
});

test('loopback-looking DNS names are refused', () => {
  assert.throws(() => new PlainwireBot('http://127.attacker.example', T), /HTTPS/);
});

test('numeric 127 slash 8 loopback is accepted', () => {
  assert.doesNotThrow(() => new PlainwireBot('http://127.0.0.2:8080', T));
});

test('2.2 member, command sync, and deferral routes are typed helpers', async () => {
  const calls = [];
  const fake = async (url, opts) => {
    calls.push({url, opts, body: opts.body && JSON.parse(opts.body)});
    return {status:200, ok:true, headers:{get:()=>null}, arrayBuffer:async()=>new TextEncoder().encode('{"ok":true,"data":{}}').buffer};
  };
  const bot = new PlainwireBot('https://chat.example', T, {fetchImpl:fake});
  await bot.members({after: 41, limit: 200});
  await bot.syncCommands([{name:'ping', description:'Replies pong'}]);
  await bot.deferCommand(9, 'pwc_claim', 120000);
  assert.match(calls[0].url, /\/members\?after=41&limit=200$/);
  assert.equal(calls[1].opts.method, 'PUT');
  assert.deepEqual(calls[1].body.commands, [{name:'ping', description:'Replies pong'}]);
  assert.match(calls[2].url, /\/commands\/claims\/9\/defer$/);
});

test('typed command options ignore raw/source metadata', () => {
  const claim = {args: {raw: 'hello there', source: 'chat', text: 'hello there'}, options: {text: 'hello there'}};
  assert.deepEqual(commandOptions(claim), {text: 'hello there'});
  assert.equal(commandOption(claim, 'text'), 'hello there');
  assert.equal(commandOption({args: {prompt: 'hi'}}, 'prompt'), 'hi');
  assert.equal(commandOption({args: {}}, 'missing', 'fallback'), 'fallback');
});

test('command worker dispatches a claimed command and replies', async () => {
  const bot = new PlainwireBot('https://chat.example', T, {fetchImpl: async () => { throw new Error('unused'); }});
  const calls = [];
  bot.claimCommands = async () => ({json: () => ({data:[{id:7, command:'ping', claim_token:'pwc_x', args:{}}]})});
  bot.deferCommand = async (...args) => calls.push(['defer', ...args]);
  bot.respondCommand = async (...args) => calls.push(['respond', ...args]);
  bot.failCommand = async (...args) => calls.push(['fail', ...args]);
  const count = await bot.commandWorker({ping: async () => 'pong'}, {concurrency: 2}).runOnce();
  assert.equal(count, 1);
  assert.equal(calls[0][0], 'defer');
  assert.deepEqual(calls[1], ['respond', 7, 'pwc_x', 'pong']);
});

test('response body remains covered by the request timeout', async () => {
  const bot = new PlainwireBot('https://chat.example', T, {timeoutMs: 20, fetchImpl: async (_url, {signal}) => {
    return new Response(new ReadableStream({start(controller) {
      signal.addEventListener('abort', () => controller.error(signal.reason), {once: true});
    }}));
  }});
  await assert.rejects(bot.me(), error => error.name === 'TimeoutError');
});

test('chunked responses are cancelled before unbounded buffering', async () => {
  let cancelled = false;
  const bot = new PlainwireBot('https://chat.example', T, {maxResponseBytes: 64, fetchImpl: async () =>
    new Response(new ReadableStream({pull(controller) { controller.enqueue(new Uint8Array(40)); }, cancel() { cancelled = true; }}))});
  await assert.rejects(bot.me(), /response too large/);
  assert(cancelled);
});

test('429 respects retry-after; an ambiguous mutation failure is not retried', async () => {
  let calls = 0;
  const bot = new PlainwireBot('https://chat.example', T, {fetchImpl: async () => ++calls === 1
    ? new Response('{"error":"rate_limited"}', {status: 429, headers: {'Retry-After': '0.025'}})
    : new Response('{"ok":true}')});
  assert.equal((await bot.me()).json().ok, true);
  assert.equal(calls, 2);
  calls = 0;
  bot.fetch = async () => { calls++; return new Response('{"error":"internal_error"}', {status: 500}); };
  await assert.rejects(bot.sendMessage(1, 'hello'), error => error instanceof PlainwireAPIError && error.code === 'internal_error');
  assert.equal(calls, 1);
});

test('bot credentials cannot escape the bot API through normalized paths', async () => {
  const bot = new PlainwireBot('https://chat.example', T, {fetchImpl: async () => assert.fail('must not fetch')});
  for (const path of ['/api/bot/v1/../../me', '/api/bot/v1/%2e%2e/%2e%2e/me', '/api/bot/v1/%252e%252e/me', '/api/bot/v1/me#secret', '/api/bot/v1/me\\..\\me']) {
    await assert.rejects(bot.request('GET', path), /invalid API path/);
  }
});

test('cancelled requests do not send credentials', async () => {
  const bot = new PlainwireBot('https://chat.example', T, {fetchImpl: async () => assert.fail('must not fetch')});
  const controller = new AbortController(); controller.abort();
  await assert.rejects(bot.request('GET', '/api/bot/v1/me', undefined, {signal: controller.signal}));
});

test('command workers refuse inherited handlers', async () => {
  const bot = new PlainwireBot('https://chat.example', T);
  const failures = [];
  bot.failCommand = async (...args) => failures.push(args);
  let executed = false;
  await bot.commandWorker(Object.create({danger: () => { executed = true; }})).handle({id: 1, command: 'danger', claim_token: 'claim'});
  assert.equal(executed, false);
  assert.equal(failures.length, 1);
});

test('Discord-style interactions support typed options and a single explicit reply', async () => {
  const bot = new PlainwireBot('https://chat.example', T);
  const replies = [];
  bot.deferCommand = async () => {};
  bot.respondCommand = async (...args) => replies.push(args);
  bot.failCommand = async () => assert.fail('must not fail');
  await bot.commandWorker({ping: async interaction => {
    assert.equal(interaction.commandName, 'ping');
    assert.equal(interaction.getInteger('count'), 2);
    assert.equal(interaction.getBoolean('loud'), false);
    assert.throws(() => interaction.getString('count'), /must be a string/);
    await interaction.reply({content: 'pong'});
    await assert.rejects(interaction.reply('again'), /already completed/);
    return 'ignored after explicit reply';
  }}).handle({id: 1, command: 'ping', claim_token: 'claim', options: {count: 2, loud: false}});
  assert.deepEqual(replies, [[1, 'claim', 'pong']]);
});

test('handler exceptions never publish their secret-bearing message', async () => {
  const bot = new PlainwireBot('https://chat.example', T);
  let reason, observed;
  bot.deferCommand = async () => {};
  bot.failCommand = async (_id, _token, message) => { reason = message; };
  await bot.commandWorker({broken: () => { throw new Error('secret-api-key'); }}, {onError: error => { observed = error; }}).handle({id: 1, command: 'broken', claim_token: 'claim'});
  assert.equal(reason, 'Command failed');
  assert.equal(observed.message, 'secret-api-key');
});

test('workers claim only immediately executable work', async () => {
  const bot = new PlainwireBot('https://chat.example', T);
  bot.claimCommands = async limit => { assert.equal(limit, 2); return {json: () => ({data: []})}; };
  assert.equal(await bot.commandWorker({}, {batchSize: 50, concurrency: 2}).runOnce(), 0);
});

test('typed interaction options follow Discord required/optional behavior', async () => {
  const {CommandInteraction} = await import('../plainwire-bot.mjs');
  const interaction = new CommandInteraction({}, {id:1, options:{enabled:false,count:0,text:'hello'},guild_id:10,request_message_id:99});
  assert.equal(interaction.getString('missing'), null);
  assert.throws(() => interaction.getString('missing', true), /required/);
  assert.equal(interaction.getBoolean('enabled', true), false);
  assert.equal(interaction.getInteger('count', true), 0);
  assert.throws(() => interaction.getInteger('text'), /integer/);
  assert.equal(interaction.guildId, 10); assert.equal(interaction.request_message_id, 99);
});
