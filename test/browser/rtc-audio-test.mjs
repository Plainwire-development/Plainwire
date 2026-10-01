import assert from 'node:assert/strict';
import { measureAudioPower } from './rtc-audio.mjs';

function cachedAudio({ intervalMs = 100, power = .01, transitionPower = power, frozen = false } = {}) {
  let time = 0;
  return {
    read: async () => {
      const duration = frozen ? 0 : Math.floor(time / intervalMs) * intervalMs / 1000;
      return { id: 'audio', duration, energy: Math.min(duration, .5) * transitionPower + Math.max(0, duration - .5) * power };
    },
    options: { now: () => time, wait: async ms => { time += ms; } }
  };
}

for (const intervalMs of [100, 1000, 2000]) {
  const loud = cachedAudio({ intervalMs });
  const measured = await measureAudioPower(loud.read, loud.options);
  assert(Math.abs(measured.power - .01) < 1e-12, 'power is independent of statistics refresh cadence');
  assert(measured.duration >= .5, 'measure actual samples before comparing power');
  const quiet = cachedAudio({ intervalMs, power: 0, transitionPower: .01 });
  assert.equal((await measureAudioPower(quiet.read, quiet.options)).power, 0, 'discard old loud audio when measuring silence');
  const restored = cachedAudio({ intervalMs, power: .01, transitionPower: 0 });
  assert(Math.abs((await measureAudioPower(restored.read, restored.options)).power - .01) < 1e-12, 'discard old silence when measuring restored audio');
}
const frozen = cachedAudio({ frozen: true });
await assert.rejects(measureAudioPower(frozen.read, { ...frozen.options, timeoutMs: 500 }), /audio samples did not advance/);
for (const change of [{ id: 'replacement' }, { energy: 0 }, { duration: 0 }, { energy: undefined }, { duration: NaN }]) {
  let calls = 0;
  await assert.rejects(measureAudioPower(async () => ({ id: 'audio', duration: 1, energy: .01, ...(calls++ ? change : {}) }),
    { wait: async () => {} }), /stream changed|counters reset|invalid .* counter/);
}
await assert.rejects(measureAudioPower(async () => undefined), /missing inbound audio report/);
console.log('PASS: RTC audio measurements tolerate cached statistics, discard transition audio, normalize by media duration, and reject stalled or invalid counters.');
