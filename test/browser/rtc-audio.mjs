import assert from 'node:assert/strict';

// getStats() may cache reports. Measure recorded media time, not a fixed sleep:
// https://www.w3.org/TR/webrtc-stats/#dom-rtcinboundrtpstreamstats-totalaudioenergy
export async function measureAudioPower(readAudio, {
  label = 'remote audio', settleSeconds = .75, sampleSeconds = .5,
  timeoutMs = 10000, pollMs = 100,
  now = () => performance.now(), wait = ms => new Promise(resolve => setTimeout(resolve, ms))
} = {}) {
  const deadline = now() + timeoutMs;
  const first = await readAudio();
  const validate = report => {
    assert(report?.id, `${label}: missing inbound audio report`);
    for (const key of ['energy', 'duration']) {
      assert(Number.isFinite(report[key]) && report[key] >= 0, `${label}: invalid ${key} counter`);
    }
  };
  validate(first);
  let previous = first;
  let baseline = settleSeconds === 0 ? first : null;
  while (now() < deadline) {
    await wait(pollMs);
    const current = await readAudio();
    validate(current);
    assert.equal(current.id, first.id, `${label}: inbound audio stream changed`);
    assert(current.duration >= previous.duration && current.energy >= previous.energy,
      `${label}: inbound audio counters reset`);
    previous = current;
    if (!baseline) {
      // Discard the gain ramp, queued audio, and any cached report covering them.
      if (current.duration - first.duration >= settleSeconds) baseline = current;
      continue;
    }
    const duration = current.duration - baseline.duration;
    if (duration >= sampleSeconds) {
      const energy = current.energy - baseline.energy;
      return { power: energy / duration, energy, duration };
    }
  }
  assert.fail(`${label}: audio samples did not advance within ${timeoutMs} ms (${JSON.stringify({ first, previous, baseline })})`);
}
