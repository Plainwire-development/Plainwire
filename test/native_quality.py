"""Exercise the actual native executable, its wire format and numerical limits."""
import math
import struct
import subprocess
import time
import random
from pathlib import Path

worker = str(Path('priv/bin/pw-media-quality').resolve())
def packet(rows):
    body = struct.pack('>I', len(rows)) + b''.join(struct.pack('>9d', *r) for r in rows)
    return struct.pack('>I', len(body)) + body
def run(data):
    return subprocess.run([worker], input=data, capture_output=True, timeout=3)
def analyze(rows):
    p = run(packet(rows))
    assert p.returncode == 0, p.stderr
    assert len(p.stdout) == 156 and p.stdout[:4] == struct.pack('>I', 152)
    result = struct.unpack('>19d', p.stdout[4:])
    assert all(math.isfinite(x) for x in result)
    return result

good = [[t, 0, 5, 40, 0, 20, 24, 24, -1] for t in (0, 5, 10)]
assert analyze(good)[0] >= 95
assert analyze([[t, 10, 90, 500, 15, 150, 24, 24, 10] for t in (0, 5, 10)])[0] < 40
assert analyze([[t] + [-1] * 8 for t in (0, 5, 10)])[0] == -1
assert analyze(good[:1])[0] == -1
assert analyze([[t, 0, 30 - t, 40, 0, 20, 24, 24, -1] for t in (0, 5, 10)])[8] < 0
assert analyze([[t, 0, 5, 40, 0, 20, b, 24, -1] for t, b in [(0, 0), (5, 24), (10, 0)]])[0] >= 95
# A few isolated supported fields must not produce a confident quality score.
sparse = [[t] + [-1] * 8 for t in (0, 5, 10)]
sparse[0][1:6] = [0, 5, 40, 0, 20]
assert analyze(sparse)[0] == -1
assert math.isclose(analyze(sparse)[11], 100 / 3)
assert analyze(sparse)[18] < 12
assert analyze([[t, 0, 5, 40, 0, 20, 24, 24, -1] for t in (0, 1, 2)])[0] == -1
upstream = [r[:-1] + [10] for r in good]
assert analyze(upstream)[0] >= 95 and analyze(upstream)[14] == 50
spike = [[t, 0, 5 if t < 20 else 200, 40, 0, 20, 24, 24, -1] for t in (0, 5, 10, 15, 20)]
assert analyze(spike)[8] == 0, 'one outlier is not a sustained trend'
rising = [[t, 0, 5 + t, 40, 0, 20, 24, 24, -1] for t in (0, 4, 11, 17, 25)]
assert math.isclose(analyze(rising)[8], 10)
burst = [[t, loss, 5, 40, 0, 20, 24, 24, -1] for t, loss in [(0,0), (5,5), (10,5), (15,-1), (20,5), (25,0)]]
assert analyze(burst)[15:17] == (75, 10), 'unknown intervals break burst runs'
worsening = [[t, 0 if t < 35 else 10, 5, 40, 0 if t < 35 else 10, 20, 24, 24, -1] for t in range(0, 60, 5)]
assert analyze(worsening)[13] < analyze(worsening)[0] - 15
assert analyze(worsening)[18] == 100
assert analyze(good)[17] == 40
irregular = [[t, loss, 5, 40, 0, 20, 24, 24, -1] for t, loss in [(0, 0), (1, 20), (11, 0)]]
assert math.isclose(analyze(irregular)[2], 20 / 11), 'loss means are weighted by measured interval duration'
suspended = [[t, 0, 5, 40, 0, 20, 24, 24, -1] for t in (0, 100, 200)]
assert analyze(suspended)[0] == -1 and analyze(suspended)[18] == 0, 'long unobserved gaps cannot manufacture evidence'
partial_jitter = [[t, 0, jitter, 40, 0, 20, 24, 24, -1] for t, jitter in [(0,0), (5,1000), (10,-1)]]
assert analyze(partial_jitter)[1] == 100, 'ineligible jitter does not distort supported loss stability'
for val in [float('nan'), float('inf'), -0.5, 101]:
    bad = [r[:] for r in good]; bad[0][1] = val
    assert run(packet(bad)).returncode != 0
for data in [packet([]), packet(good)[:-8], struct.pack('>I', 0xFFFFFFFF), packet([good[0], good[0]]), packet(good * 9)]:
    assert run(data).returncode != 0
for end in range(1, len(packet(good))):
    assert run(packet(good)[:end]).returncode != 0, f'truncated frame at {end}'
# A caller that leaves a partial frame open cannot strand the worker forever.
with subprocess.Popen([worker], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as stalled:
    stalled.stdin.write(packet(good)[:8]); stalled.stdin.flush()
    assert stalled.wait(timeout=2) != 0
# Deterministic bounded random windows exercise numerical output limits.
rng = random.Random(1701)
limits = [100, 10000, 30000, 100, 30000, 100000, 100000, 100]
frames = []
for _ in range(200):
    rows = [[t * 5] + [rng.uniform(0, limit) if rng.random() > .2 else -1 for limit in limits] for t in range(rng.randint(1,24))]
    frames.append(packet(rows))
p = run(b''.join(frames))
assert p.returncode == 0 and len(p.stdout) == 156 * len(frames)
for offset in range(0, len(p.stdout), 156):
    values = struct.unpack('>19d', p.stdout[offset + 4:offset + 156])
    assert all(math.isfinite(v) for v in values)
    for index in [0,1,2,5,10,11,13,14,15,18]:
        assert values[index] == -1 or 0 <= values[index] <= 100
start = time.perf_counter()
p = run(packet(good) * 1000)
assert p.returncode == 0 and len(p.stdout) == 156000
print(f'PASS: native evidence, recent/upstream scores, robust trends, burst timing, silence, 200 random windows, all truncated frame boundaries and 1,000 sequential analyses ({time.perf_counter()-start:.3f}s).')
