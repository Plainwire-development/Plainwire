import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';

// Execute the production configuration loader with controlled fetch/time.
const bridge = readFileSync('priv/static/elm-bridge.js', 'utf8');
const start = bridge.indexOf('  const loadRtcConfig = () =>');
const end = bridge.indexOf('  const startRtcRefresh = () =>', start);
assert(start >= 0 && end > start);
const defaults = bridge.match(/  const defaultRtcConfig = (.+);/)[1];
let now = 1000000, fetchCount = 0;
let response = {iceServers: [{urls: ['turn:relay.example:3478'], username: 'user', credential: 'secret'}], iceTransportPolicy: 'relay', turnStatus: 'ready', turnTtlSeconds: 60};
let failure = false;
const loader = runInNewContext(`
  const defaultRtcConfig = ${defaults};
  let rtcConfig = defaultRtcConfig, rtcConfigRequest = null, rtcConfigFetchedAt = 0;
  let rtcConfigNextRefresh = 0, rtcConfigValidUntil = 0;
  const peers = new Map(), room = null, debug = () => {};
  ${bridge.slice(start, end)}
  ({load: loadRtcConfig, config: () => rtcConfig, refresh: () => {rtcConfigNextRefresh = 0;}})
`, {
  window: {}, Date: {now: () => now}, AbortController, setTimeout, clearTimeout,
  fetch: async () => { fetchCount++; if (failure) throw Error('offline'); return {ok: true, json: async () => ({ok: true, data: response})}; }
});
const plain = value => JSON.parse(JSON.stringify(value));
assert.deepEqual(plain(loader.config()), {iceServers: [], iceTransportPolicy: 'relay', turnStatus: 'unavailable'}, 'unknown policy never exposes direct candidates');
assert.equal((await loader.load()).iceTransportPolicy, 'relay');
assert.equal(fetchCount, 1);
failure = true; now += 10000; loader.refresh();
assert.equal((await loader.load()).iceServers[0].urls[0], 'turn:relay.example:3478', 'valid credentials survive transient failure');
now += 60000; loader.refresh();
const expired = await loader.load();
assert.equal(expired.iceTransportPolicy, 'relay'); assert.deepEqual(plain(expired.iceServers), [], 'expired credentials do not fall back to public STUN');
failure = false; response = {iceServers: [], iceTransportPolicy: 'all'}; loader.refresh();
assert.equal((await loader.load()).iceTransportPolicy, 'all', 'direct connectivity requires a successfully loaded server policy');
console.log('PASS: unknown and expired RTC policy fail closed, valid relays survive transient errors, and direct connectivity follows fetched policy.');
