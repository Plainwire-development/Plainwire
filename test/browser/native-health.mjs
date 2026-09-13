// Test transport only. Numerical results come from the real C/Fortran binary.
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';

export function nativeHealth(rows) {
  return new Promise((resolveResult, reject) => {
    const input = Buffer.alloc(8 + rows.length * 72);
    input.writeUInt32BE(input.length - 4); input.writeUInt32BE(rows.length, 4);
    rows.flat().forEach((value, index) => input.writeDoubleBE(value, 8 + index * 8));
    const worker = spawn(resolve('priv/bin/pw-media-quality'), [], { stdio: ['pipe', 'pipe', 'pipe'] });
    const chunks = [];
    const timeout = setTimeout(() => { worker.kill('SIGKILL'); reject(Error('Native test worker timed out')); }, 2000);
    worker.on('error', error => { clearTimeout(timeout); reject(error); });
    worker.stdout.on('data', bytes => chunks.push(bytes));
    worker.on('close', code => {
      clearTimeout(timeout);
      const output = Buffer.concat(chunks);
      if (code !== 0 || output.length !== 156 || output.readUInt32BE(0) !== 152) return reject(Error('Invalid native test response'));
      const keys = ['score', 'stability', 'loss_pct', 'jitter_p95_ms', 'rtt_ms', 'concealment_pct', 'buffer_ms', 'bitrate_variation_pct', 'jitter_trend', 'loss_trend', 'upstream_loss_pct', 'coverage_pct', 'sample_count', 'recent_score', 'upstream_score', 'loss_burst_pct', 'loss_burst_seconds', 'rtt_p95_ms', 'confidence_pct'];
      const result = Object.fromEntries(keys.map((key, index) => { const value = output.readDoubleBE(4 + index * 8); return [key, value === -1 || value === -1e9 ? null : value]; }));
      // Recommendation policy itself is covered by Erlang EUnit; this fixture
      // verifies real browser samples and returned native values reach the UI.
      result.recommendation = result.score === null ? 'insufficient_data' : 'healthy';
      resolveResult(result);
    });
    worker.stdin.on('error', reject);
    worker.stdin.end(input);
  });
}
