import { readFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

function read(path) {
  return readFileSync(path, 'utf8');
}

const [api, db, ws, redis, webhook, perms, bridge, sdk, redisDoc, util, uploadGc] = await Promise.all([
  readFile('src/pw_api.erl', 'utf8'),
  readFile('src/pw_db.erl', 'utf8').then(async (text) => text + '\n' + await readFile('src/pw_db_schema.erl', 'utf8')),
  readFile('src/pw_ws.erl', 'utf8'),
  readFile('src/pw_redis.erl', 'utf8'),
  readFile('src/pw_webhook_dispatcher.erl', 'utf8'),
  readFile('src/pw_permissions.erl', 'utf8'),
  readFile('priv/static/elm-bridge.js', 'utf8'),
  readFile('sdk/erlang/src/plainwire_bot.erl', 'utf8'),
  readFile('docs/REDIS.md', 'utf8'),
  readFile('src/pw_util.erl', 'utf8'),
  readFile('src/pw_upload_gc.erl', 'utf8')
]);

// Bot API: server-scoped credentials, HTTP operations and realtime auth.
assert.match(api, /\[<<"bot">>, <<"server">>\]/, 'bot API exposes scoped server metadata');
assert.match(api, /\[<<"bot">>, <<"channels">>, ChannelId, <<"messages">>\]/, 'bot API exposes channel message reads/writes');
assert.match(api, /\[<<"bot">>, <<"messages">>, MessageId, <<"reaction">>\]/, 'bot API exposes reaction mutation');
assert.match(db, /JOIN users u ON u\.id=b\.bot_user_id WHERE b\.token_hash=\$1 AND u\.account_state='active'/, 'bot auth resolves a durable active bot identity');
assert.match(ws, /bot_authorization\(Req\)/, 'websocket explicitly supports bot credentials');
assert.match(ws, /lists:member\(Type, \[<<"ping">>, <<"subscribe">>, <<"unsubscribe_all">>\]\)/, 'bot websocket input is restricted to realtime subscription control');
assert.match(ws, /case auth_message_allowed\(State, M\)[\s\S]*case message_allowed\(Uid, M\)[\s\S]*rate_limited/, 'bot authorization does not change normal websocket rate-limit behavior');

// SDK intentionally separates request and websocket transports and restores subscriptions.
assert.match(sdk, /http => undefined, ws => undefined/, 'SDK tracks independent HTTP and websocket Gun connections');
assert.match(sdk, /gun:ws_upgrade\(Conn, WsPath, Headers\)/, 'SDK uses Gun websocket upgrade');
assert.match(sdk, /ws_ref => Ref/, 'SDK tracks the websocket stream reference');
assert.match(sdk, /\{gun_response, Conn, Ref, _Fin, Status, _Headers\}/, 'SDK handles refused websocket upgrades');
assert.match(sdk, /\{gun_down, Conn, _Protocol, Reason, _Killed\}/, 'SDK matches Gun 2.x gun_down messages');
assert.doesNotMatch(sdk, /_Unprocessed/, 'SDK does not use the removed Gun 1.x gun_down element');
assert.match(sdk, /\{inform, _Status, _Headers\} -> await_final_response/, 'SDK tolerates HTTP informational responses');
assert.match(sdk, /lists:foreach\(fun\(Key\).*subscribe/s, 'SDK replays subscriptions after reconnect');
assert.match(sdk, /backoff => 1000/, 'SDK has bounded reconnect state');
assert.match(sdk, /verify_peer/, 'SDK verifies TLS peers');

// Redis is an accelerator, never the durable message acknowledgement path.
assert.match(redis, /presence_owner\(\)/, 'Redis presence is node-aware');
assert.match(redis, /HSET[\s\S]*owner[\s\S]*PEXPIRE/, 'Redis stores expiring per-node presence fields');
assert.match(redis, /safe_status\(away\).*?\<\<\"away\"\>\>/s, 'Redis preserves Plainwire away presence');
assert.match(redis, /safe_status\(busy\).*?\<\<\"busy\"\>\>/s, 'Redis preserves Plainwire busy presence');
assert.doesNotMatch(redis, /safe_status\(idle\)|safe_status\(dnd\)/, 'Redis does not translate presence into foreign status names');
assert.match(redis, /normalize_presence\(\<\<\"away\"\>\>\)\s*->\s*\<\<\"away\"\>\>/, 'Redis presence returns the hub binary status representation');
assert.match(redis, /normalize_presence\(_\)\s*->\s*\<\<\"online\"\>\>/, 'Redis presence default matches the hub binary status representation');
assert.match(redis, /cache_bump_version/, 'Redis cache has constant-time generation invalidation');
assert.match(redis, /PLAINWIRE_REDIS_USERNAME/, 'Redis supports Redis 6+ ACL usernames');
assert.match(redis, /\[<<\"AUTH\">>, unicode:characters_to_binary\(U\), unicode:characters_to_binary\(P\)\]/, 'Redis ACL auth sends username and password together');
// Assert the durability contract itself, not one exact sentence: the prose is
// reworded between releases, but Redis must never be described as durable and
// PostgreSQL must stay the relational source of truth.
assert.match(redisDoc, /Redis is never the durable authority/, 'Redis docs keep Redis out of the durable authority path');
assert.match(redisDoc, /PostgreSQL is still[^.\n]*source of truth/, 'Redis docs preserve PostgreSQL durability semantics');
assert.match(ws, /pw_rate:allow_shared\(\{ws_typing, Uid\}/, 'typing abuse gate can coordinate through the shared Redis limiter');

// Real integration permissions only: no UI-only permission switches.
for (const permission of ['attach_files', 'add_reactions', 'send_voice_notes', 'stream', 'manage_webhooks', 'manage_bots']) {
  assert.match(perms, new RegExp(`entry\\(<<"${permission}">>`), `${permission} is exposed in the role catalog`);
}
for (const unfinished of ['mute_members', 'deafen_members', 'move_members', 'manage_events', 'priority_speaker']) {
  assert.doesNotMatch(perms, new RegExp(`entry\\(<<"${unfinished}">>`), `${unfinished} is not exposed as a pretend permission`);
}
assert.match(db, /AttachmentAllowed[\s\S]*<<"attach_files">>/, 'server attachments enforce attach_files');
assert.match(db, /toggle_message_reaction[\s\S]*<<"add_reactions">>/, 'server reactions enforce add_reactions');
assert.match(ws, /pw_db:stream_access\(Uid, Cid\)/, 'server screen share enforces stream permission');

// Webhook SSRF/signature/retry plumbing and browser extension isolation remain present.
assert.match(webhook, /gun:/, 'webhook delivery uses Gun');
assert.match(webhook, /x-plainwire-signature/i, 'webhook delivery is signed');
assert.match(db, /webhook_claim_due[\s\S]*SKIP LOCKED/, 'webhook workers claim durable deliveries without duplicate workers');
assert.match(bridge, /javascriptEnabled:\s*false/, 'Less themes disable embedded JavaScript');
assert.match(bridge, /new Worker\(/, 'client plugins execute in workers');
assert.match(bridge, /importScripts\s*=|importScripts:/, 'plugin worker blocks importScripts');
assert.match(bridge, /permissions\.apiWrite/, 'plugin API mutations require an explicit capability grant');
assert.match(bridge, /read-only API access/, 'plugins default to read-only API access');
assert.match(util, /worker-src 'self' blob:/, 'plugin blob workers must be allowed by the normal CSP');
assert.match(util, /connect-src 'self';/, 'client CSP must not grant extensions arbitrary outbound WebSocket/network destinations');
assert.doesNotMatch(util, /connect-src 'self' ws: wss:/, 'client CSP must not use broad websocket scheme sources');

// Account deletion is physical deletion after ownership/content cleanup.
assert.match(db, /route\(\{delete_account[\s\S]*prepare_owned_servers_for_account_delete[\s\S]*DELETE FROM users WHERE id=\$1/, 'account deletion physically removes the users row');
assert.doesNotMatch(db, /UPDATE users SET .*deleted/i, 'account delete path does not replace users with a soft-deleted profile');

assert.match(webhook, /webhook_worker_timeout[\s\S]*webhook_worker_enforce_timeout[\s\S]*exit\(Pid, kill\)/, "webhook workers must have a hard deadline below the durable delivery lease");
assert.match(webhook, /TIMEOUT_GRACE_MS[\s\S]*send_after\(\?TIMEOUT_GRACE_MS/, "webhook timeout enforcement must allow a small completion grace to avoid result/timeout mailbox races");
assert.match(db, /CREATE TABLE IF NOT EXISTS upload_delete_queue/, 'account/file erasure has a durable filesystem deletion queue');
assert.match(db, /enqueue_upload_deletes_for_user[\s\S]*INSERT INTO upload_delete_queue/, 'account deletion queues uploaded bytes before relational ownership is erased');
assert.match(db, /upload_delete_claim[\s\S]*FOR UPDATE SKIP LOCKED/, 'upload deletion queue is safe across multiple Plainwire nodes');
assert.match(uploadGc, /drain_delete_queue[\s\S]*upload_delete_finish/, 'upload GC durably finalizes or retries physical file erasure');

assert.match(read('src/pw_http_fetch.erl'), /get_pinned\/4/, 'media HTTP client must expose pinned-address fetching');
assert.match(read('src/pw_media.erl'), /pw_http_fetch:get_pinned\(Url, Address/, 'media redirects must connect to the vetted address');
assert.match(read('src/pw_media.erl'), /lists:all\(fun pw_outbound_url:public_ip\/1, Addrs\)/, 'media DNS answers must share the webhook public-address policy');
assert.match(read('src/pw_db.erl'), /safe_log_msg\(Msg\) when is_tuple\(Msg\), tuple_size\(Msg\) > 0 ->[\s\S]*\{element\(1, Msg\), redacted\}/, 'unknown DB operations must redact arguments by default');
assert.doesNotMatch(read('src/pw_db.erl'), /safe_log_msg\(Msg\) -> Msg\./, 'DB exceptional logging must never fail open to raw operation tuples');

console.log('PASS: Plainwire 2.0 Redis, bot SDK, webhook, permission, extension, and account-lifecycle integration contracts.');
