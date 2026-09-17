import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const root = path.resolve(new URL('../..', import.meta.url).pathname);
const must = (cond, msg) => { if (!cond) throw new Error(msg); };
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'plainwire-storage-tools-'));
try {
  const bin = path.join(tmp, 'bin');
  fs.mkdirSync(bin);
  const log = path.join(tmp, 'cqlsh.args');
  const fake = path.join(bin, 'cqlsh');
  fs.writeFileSync(fake, `#!/usr/bin/env bash\nset -eu\nprintf '%s\\n' "$*" >> "$PLAINWIRE_TEST_CQLSH_LOG"\n# SELECT migration-name probes deliberately return no rows so every migration is exercised.\nexit 0\n`);
  fs.chmodSync(fake, 0o755);

  const baseEnv = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    PLAINWIRE_TEST_CQLSH_LOG: log,
    PLAINWIRE_SCYLLA_USERNAME: 'plainwire_test',
    PLAINWIRE_SCYLLA_PASSWORD: 'normal-password-%-with-spaces',
    PLAINWIRE_SCYLLA_TLS: 'no',
  };
  const good = spawnSync('bash', ['scripts/scylla-migrate'], { cwd: root, env: baseEnv, encoding: 'utf8' });
  must(good.status === 0, `scylla-migrate normal config failed: ${good.stderr}`);
  must(good.stdout.includes('Plainwire Scylla schema is current'), 'schema tool did not complete all migrations');
  const args = fs.readFileSync(log, 'utf8');
  must(!args.includes(baseEnv.PLAINWIRE_SCYLLA_PASSWORD), 'Scylla password leaked into cqlsh process arguments');
  const rcMatches = [...args.matchAll(/--cqlshrc\s+(\S+)/g)];
  must(rcMatches.length > 0, 'schema tool did not use a private cqlshrc');
  for (const match of rcMatches) must(!fs.existsSync(match[1]), 'temporary cqlshrc was not removed');

  const tls = spawnSync('bash', ['scripts/scylla-migrate'], {
    cwd: root,
    env: { ...baseEnv, PLAINWIRE_SCYLLA_TLS: 'yes', PLAINWIRE_SCYLLA_CA_FILE: path.join(tmp, 'missing-ca.pem') },
    encoding: 'utf8',
  });
  must(tls.status !== 0 && tls.stderr.includes('TLS requires readable PLAINWIRE_SCYLLA_CA_FILE'),
    'schema tool boolean parsing must treat yes/on/1 as TLS enabled');

  const incompleteAuth = spawnSync('bash', ['scripts/scylla-migrate'], {
    cwd: root,
    env: { ...baseEnv, PLAINWIRE_SCYLLA_PASSWORD: '' },
    encoding: 'utf8',
  });
  must(incompleteAuth.status === 2 && incompleteAuth.stderr.includes('requires both PLAINWIRE_SCYLLA_USERNAME and PLAINWIRE_SCYLLA_PASSWORD'),
    'schema tool must reject incomplete Scylla credentials');

  const newline = spawnSync('bash', ['scripts/scylla-migrate'], {
    cwd: root,
    env: { ...baseEnv, PLAINWIRE_SCYLLA_PASSWORD: 'bad\npassword' },
    encoding: 'utf8',
  });
  must(newline.status === 2 && newline.stderr.includes('must not contain newline characters'),
    'schema tool must reject cqlshrc newline injection');

  const badRf = spawnSync('bash', ['scripts/scylla-migrate'], {
    cwd: root,
    env: { ...baseEnv, PLAINWIRE_SCYLLA_REPLICATION_FACTOR: '0' },
    encoding: 'utf8',
  });
  must(badRf.status === 2 && badRf.stderr.includes('replication factor must be 1..16'),
    'schema tool must reject invalid replication factors');

  console.log('PASS: Scylla schema tool handles booleans, credentials, cleanup, injection guards, and replication validation.');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
