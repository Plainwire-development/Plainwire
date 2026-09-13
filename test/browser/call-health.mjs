import assert from 'node:assert/strict';
import '../../priv/static/call-health.js';
const { parseStats } = globalThis.PlainwireCallHealth;
const reports = (timestamp, overrides = {}) => new Map([
  ['in', { id: 'in', type: 'inbound-rtp', kind: 'audio', transportId: 'transport', timestamp, packetsReceived: 100, packetsLost: 0, jitter: .02, bytesReceived: 10000, concealedSamples: 100, totalSamplesReceived: 1000, jitterBufferDelay: 2, jitterBufferEmittedCount: 100, ...overrides }],
  ['out', { id: 'out', type: 'outbound-rtp', kind: 'audio', timestamp, bytesSent: timestamp * 3 }],
  ['remote', { id: 'remote', type: 'remote-inbound-rtp', localId: 'out', timestamp, roundTripTime: .1, fractionLost: .03 }]
]);
const first = parseStats(reports(1000));
assert.equal(first.sample.loss, null, 'no rate invented without a baseline');
assert.equal(first.sample.rtt, 100);
const next = parseStats(reports(6000, { packetsReceived: 198, packetsLost: 2, bytesReceived: 25000, concealedSamples: 120, totalSamplesReceived: 2000, jitterBufferDelay: 7, jitterBufferEmittedCount: 200 }), first.previous);
assert.equal(next.sample.loss, 2);
assert.equal(next.sample.concealment, 2);
assert.equal(next.sample.buffer, 50);
assert.equal(next.sample.rxBitrate, 24);
assert.equal(next.sample.txBitrate, 24);
assert.equal(next.sample.upstreamLoss, 3);
assert.equal(next.sample.jitter, 20);
const reset = parseStats(reports(7000, { packetsReceived: 1, bytesReceived: 40 }), next.previous);
assert.equal(reset.sample.loss, null);
assert.equal(reset.sample.rxBitrate, null);
const missing = parseStats(new Map([['x', { id: 'x', type: 'inbound-rtp', kind: 'audio', timestamp: 1000 }]]));
assert(Object.values(missing.sample).every(v => v === null));
const stale = parseStats(reports(30000), first.previous);
assert.equal(stale.sample.loss, null);
const pair = new Map([['in', { id: 'in', type: 'inbound-rtp', kind: 'audio', transportId: 't' }], ['t', { id: 't', type: 'transport', selectedCandidatePairId: 'p' }], ['p', { id: 'p', type: 'candidate-pair', state: 'succeeded', currentRoundTripTime: .07 }]]);
assert.equal(parseStats(pair).sample.rtt, 70);
assert.equal(parseStats(new Map()).sample, null);
const signed = parseStats(reports(1000, { packetsLost: -5 }));
assert.equal(parseStats(reports(6000, { packetsLost: -3, packetsReceived: 198 }), signed.previous).sample.loss, 2);
const repeated = reports(11000);
repeated.get('remote').timestamp = 6000;
assert.equal(parseStats(repeated, next.previous).sample.upstreamLoss, null, 'do not count repeated RTCP feedback');
assert.equal(parseStats(repeated, next.previous).sample.rtt, null, 'do not present stale remote RTT');
pair.delete('p');
pair.set('old', { id: 'old', type: 'candidate-pair', state: 'succeeded', nominated: true, currentRoundTripTime: .9 });
pair.set('p', { id: 'p', type: 'candidate-pair', state: 'succeeded', currentRoundTripTime: .07 });
assert.equal(parseStats(pair).sample.rtt, 70, 'selected pair wins over earlier nominated pair');
console.log('PASS: stats counter deltas, reset handling, units, missing metrics, stale intervals, upstream feedback and selected ICE RTT.');
