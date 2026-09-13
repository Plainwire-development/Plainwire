"""Exercise the actual native executable, its wire format and numerical limits."""
import math
import struct
import subprocess
import time
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
    assert len(p.stdout) == 108 and p.stdout[:4] == struct.pack('>I', 104)
    result = struct.unpack('>13d', p.stdout[4:])
    assert all(math.isfinite(x) for x in result)
    return result

good = [[t, 0, 5, 40, 0, 20, 24, 24, -1] for t in (0, 5, 10)]
assert analyze(good)[0] >= 95
assert analyze([[t, 10, 90, 500, 15, 150, 24, 24, 10] for t in (0, 5, 10)])[0] < 40
assert analyze([[t] + [-1] * 8 for t in (0, 5, 10)])[0] == -1
assert analyze(good[:1])[0] == -1
assert analyze([[t, 0, 30 - t, 40, 0, 20, 24, 24, -1] for t in (0, 5, 10)])[8] < 0
assert analyze([[t, 0, 5, 40, 0, 20, b, 24, -1] for t, b in [(0, 0), (5, 24), (10, 0)]])[0] >= 95
for val in [float('nan'), float('inf'), -0.5, 101]:
    bad = [r[:] for r in good]; bad[0][1] = val
    assert run(packet(bad)).returncode != 0
for data in [packet([]), packet(good)[:-8], struct.pack('>I', 0xFFFFFFFF), packet([good[0], good[0]]), packet(good * 9)]:
    assert run(data).returncode != 0
start = time.perf_counter()
p = run(packet(good) * 1000)
assert p.returncode == 0 and len(p.stdout) == 108000
print(f'PASS: native numerical fixtures, missing data, improving trend, silence, malformed frames and 1,000 sequential analyses ({time.perf_counter()-start:.3f}s).')
