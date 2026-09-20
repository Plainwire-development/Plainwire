import test from 'node:test';
import assert from 'node:assert/strict';
import {PlainwireBot} from '../plainwire-bot.mjs';
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
