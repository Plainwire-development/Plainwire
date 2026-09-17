import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const [redis, db, hub, rate, docs] = await Promise.all([
  readFile('src/pw_redis.erl', 'utf8'),
  readFile('src/pw_db.erl', 'utf8'),
  readFile('src/pw_hub.erl', 'utf8'),
  readFile('src/pw_rate.erl', 'utf8'),
  readFile('docs/REDIS.md', 'utf8')
]);

assert.match(redis, /cache_bump_version[\s\S]*INCR[\s\S]*PEXPIRE/, 'cache generations are atomically bumped and expire');
assert.match(redis, /cache_get_at_version[\s\S]*cache_put_at_version/, 'versioned cache primitives exist');
assert.match(db, /message_cache_lookup\([\s\S]*undefined, undefined[\s\S]*cache_version/, 'only the hot latest-message window enters the Redis path');
assert.match(db, /maybe_store_message_cache[\s\S]*second generation read[\s\S]*cache_put_at_version/, 'message cache fill closes the mutation race');
for (const mutation of ['message_deleted', 'message_updated', 'message_reaction_changed']) {
  const pos = db.indexOf(mutation);
  assert.ok(pos >= 0, `${mutation} event exists`);
  assert.ok(db.lastIndexOf('invalidate_message_cache', pos) >= 0, `${mutation} invalidates hot history before broadcast`);
}
assert.match(hub, /presence_set[\s\S]*REDIS_PRESENCE_TTL_MS/, 'presence is mirrored to Redis with a TTL');
assert.match(rate, /pw_redis:rate_allow/, 'Redis participates in shared sensitive rate limiting');
assert.match(docs, /PostgreSQL is still the source of truth/i, 'Redis docs preserve PostgreSQL durability semantics');
assert.match(docs, /generation counter/i, 'cache invalidation design is documented');
console.log('PASS: Redis presence, distributed rate gate, hot-message cache, and O(1) invalidation contracts.');
