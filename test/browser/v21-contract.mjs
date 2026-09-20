import assert from 'node:assert/strict';
import {readFileSync, existsSync} from 'node:fs';
const read=p=>readFileSync(p,'utf8');
const db=read('src/pw_db.erl');
const api=read('src/pw_api.erl');
const crypto=read('src/pw_crypto.erl');
const search=read('src/pw_search_index.erl');
const admin=read('src/pw_admin_api.erl');
const ws=read('src/pw_ws.erl');
const adminJs=read('priv/admin/admin.js');
const bridge=read('priv/static/elm-bridge.js');
const main=read('priv/static/elm/src/Main.elm');
const types=read('priv/static/elm/src/Types.elm');
const composer=read('priv/static/elm/src/View/Composer.elm');
const markdown=read('priv/static/elm/src/View/Markdown.elm');
const components=read('priv/static/_components.scss');
const version=read('VERSION').trim();

assert.match(version,/^2\.2\.\d+$/,'the 2.1 feature contracts remain supported by the 2.2 release series');
assert.match(crypto,/aes_256_gcm[\s\S]*PLAINWIRE_ENC_PREVIOUS_KEYS/,'message encryption remains AES-256-GCM and supports rotation');
assert.match(crypto,/PLAINWIRE_SEARCH_KEY[\s\S]*crypto:mac\(hmac, sha256/,'message search uses an independent or derived keyed HMAC');
assert.match(crypto,/MAX_SEARCH_TOKENS/,'search indexing is bounded');
assert.doesNotMatch(db,/CREATE TABLE[^\n]*message_search[^\n]*(?:body|plaintext)/i,'search schema does not create a plaintext body column');
assert.match(db,/\{40, \[[\s\S]*message_search_tokens[\s\S]*message_search_state/,'migration 40 installs the blind message index');
assert.match(db,/search_authorized_batches[\s\S]*can_read_messages/,'message search revalidates access and scans bounded batches');
assert.ok(db.includes('not disclose instance-wide indexing cursors'), 'public message search does not expose global index cursors or key fingerprints');
assert.match(api,/\[<<"search">>, <<"messages">>\]/,'public API exposes authenticated message search');
assert.match(search,/PLAINWIRE_SEARCH_BACKFILL_BATCH[\s\S]*PLAINWIRE_SEARCH_BACKFILL_INTERVAL_MS/,'search reconciliation is bounded and configurable');

assert.match(api,/\[<<"bot">>, <<"v1">> \| Rest\]/,'Bot API v1 has a versioned entry point');
for (const route of ['commands','claims','respond','fail']) assert.ok(api.includes(route),`bot v1 supports ${route}`);
assert.match(db,/\{41, \[[\s\S]*bot_commands[\s\S]*bot_command_invocations/,'migration 41 installs durable bot commands');
assert.match(db,/FOR UPDATE OF i SKIP LOCKED/,'parallel command workers use SKIP LOCKED');
assert.ok(db.includes('bot_command_channel_access(Conn, ChannelId, R)'), 'command discovery hides commands whose bot cannot access the active channel');
assert.match(db,/invoke_bot_command[\s\S]*channel_message_access\(Conn, BotUid, ChannelId\)[\s\S]*command_unavailable/,'command invocation rechecks the bot channel ACL before durable arguments are queued');
assert.match(db,/claim_authorized_bot_invocations[\s\S]*command_claim_authorization\(Conn, UserId, Sid, Cid, CommandId, BotUid\)/,'durable command claims use centralized claim-time authorization');
assert.match(db,/command_claim_authorization[\s\S]*channel_message_access\(Conn, BotUid, Cid\)[\s\S]*channel_message_access\(Conn, UserId, Cid\)[\s\S]*bot_command_permission_allowed/,'claim-time authorization rechecks bot ACL, invoking-user ACL, and per-command permissions before arguments are disclosed');
assert.match(db,/encode_command_args\(Args\) -> pw_crypto:encrypt/,'command arguments are encrypted at rest');
assert.ok(db.includes('validate_command_argument_schema(Clean, Options)'), 'structured command arguments are validated against registered option schemas');
assert.match(db,/claim_token_hash[\s\S]*pw_util:sha256_hex/,'claim tokens are stored as hashes');
assert.match(db,/secure_token_hash_match[\s\S]*pw_util:constant_time/,'claim tokens are compared in constant time');
assert.doesNotMatch(db,/WHERE[^\n]*status='claimed'[^\n]*claim_token_hash=\$[0-9]/,'claim-token authentication is not delegated to a normal SQL equality predicate');
for (const setting of ['PLAINWIRE_BOT_READ_PER_MINUTE','PLAINWIRE_BOT_MESSAGE_PER_MINUTE','PLAINWIRE_BOT_MUTATION_PER_MINUTE','PLAINWIRE_BOT_COMMAND_CLAIM_PER_MINUTE']) assert.ok(api.includes(setting), `bot throughput setting exists: ${setting}`);

assert.match(types,/isBot\s*:/,'client user model carries bot identity');
assert.match(main,/bot-badge/,'bot badge is rendered in the application UI');
assert.match(components,/\.bot-badge/,'bot badge follows the application style layer');
assert.match(composer,/ToggleLastAttachmentSpoiler/,'composer can mark attachments as spoilers');
assert.match(markdown,/details[\s\S]*summary/,'spoiler attachments render with accessible native disclosure controls');
assert.match(main,/matchingCommand/,'registered slash commands integrate with the existing composer');
assert.ok(main.includes('Keep the draft until the server acknowledges the invocation'), 'command invocation keeps the draft until server acknowledgement');

assert.match(db,/\{42, \[[\s\S]*instance_account_actions[\s\S]*suspended[\s\S]*banned/,'migration 42 adds instance moderation with an audit trail');
assert.match(admin,/moderation/,'host-admin API exposes account moderation');
assert.match(db,/DELETE FROM sessions WHERE user_id=\$1[\s\S]*DELETE FROM admin_sessions WHERE user_id=\$1/,'instance restriction revokes ordinary and control-plane sessions');
assert.match(admin,/content_access => false/,'control plane remains explicitly private-content blind');
assert.doesNotMatch(admin,/search_messages|message_search_tokens/,'host-admin API does not gain private message search');
assert.match(bridge,/account_restricted/,'connected clients receive instance restriction state');
assert.match(ws,/type := account_restricted[\s\S]*close_restricted_session[\s\S]*\{stop, State\}/,'restricted accounts have live user websockets closed immediately after the restriction UI event');
assert.match(adminJs,/suspend[\s\S]*ban[\s\S]*restore/i,'host admin UI exposes suspend, ban and restore actions');

const sdkFiles=[
  'sdk/c/include/plainwire_bot.h','sdk/cpp/include/plainwire_bot.hpp','sdk/go/plainwirebot/client.go',
  'sdk/python/plainwire_bot.py','sdk/javascript/plainwire-bot.mjs','sdk/rust/src/lib.rs','sdk/erlang/src/plainwire_bot.erl'
];
for (const file of sdkFiles) assert.ok(existsSync(file),`first-party bot SDK exists: ${file}`);
const go=read('sdk/go/plainwirebot/client.go');
const py=read('sdk/python/plainwire_bot.py');
const js=read('sdk/javascript/plainwire-bot.mjs');
const rust=read('sdk/rust/src/lib.rs');
const erl=read('sdk/erlang/src/plainwire_bot.erl');
assert.match(go,/CheckRedirect[\s\S]*ErrUseLastResponse/,'Go SDK refuses redirects');
assert.match(py,/_NoRedirect/,'Python SDK refuses redirects');
assert.match(js,/redirect:\s*'manual'/,'JavaScript SDK refuses redirects');
assert.match(js,/parts\.length !== 4[\s\S]*octets\[0\] === 127/,'JavaScript SDK only treats numeric 127/8 hosts as IPv4 loopback');
assert.match(rust,/Policy::none/,'Rust SDK refuses redirects');
assert.match(erl,/plaintext_remote_not_allowed/,'Erlang SDK refuses remote plaintext HTTP');
assert.doesNotMatch(erl,/gun:await_body\(/,'Erlang SDK must not materialize unbounded HTTP bodies before enforcing its response cap');
assert.match(erl,/await_bounded_body[\s\S]*MAX_RESPONSE[\s\S]*gun:cancel/,'Erlang SDK incrementally bounds and cancels oversized HTTP responses');
for (const source of [go,py,js,rust,erl]) assert.match(source,/api\/bot\/v1/i,'every high-level SDK targets Bot API v1');


const archive = read('scripts/archive.py');
assert.ok(archive.includes("'sdk'"), 'SDK source tree must be included in portable archives');
assert.ok(archive.includes("SOURCE_GENERATED"), 'portable source archive must continue excluding generated frontend assets');

// Elm model/decoder regressions that are easy to miss in source-only environments.
assert(types.includes('Message 0 "" 0 0 "" "" "" "" "text" Nothing Nothing 0 Nothing Nothing Nothing "" False False []'), 'defaultMsg must include the 2.1 bot and pinned fields');
assert(main.includes('availableCommands =\n                    case active of'), 'route changes must clear stale bot command suggestions');


// 2.1 server QoL contracts.
assert.match(db,/\{43, \[[\s\S]*message_pins/,'migration 43 installs message pinning');
assert.match(db,/set_message_pin[\s\S]*manage_messages[\s\S]*Count >= 50/,'pinning is permissioned and bounded to 50 messages per channel');
assert.match(api,/\[<<"message">>, MsgId, <<"context">>\]/,'reply jumps have an authorized bounded context endpoint');
assert.match(bridge,/jump_to_message[\s\S]*scrollIntoView[\s\S]*message-jump-highlight/,'reply jump scrolls to and temporarily highlights the target');
assert.match(main,/messageContextMode[\s\S]*ReturnToLatestMessages/,'historical reply jumps expose a path back to the live timeline');
assert.match(db,/\{44, \[[\s\S]*slowmode_seconds/,'migration 44 adds per-channel slowmode');
assert.match(db,/enforce_channel_slowmode[\s\S]*pg_advisory_xact_lock/,'slowmode is concurrency-safe across app nodes');
assert.match(api,/\[<<"channel">>, ChannelId, <<"settings">>\]/,'channel settings API exposes slowmode/topic updates');
assert.match(db,/\{45, \[[\s\S]*incoming_webhooks/,'migration 45 installs incoming channel webhooks');
assert.match(db,/execute_incoming_webhook[\s\S]*secure_token_hash_match/,'incoming webhook credentials are hash-verified in constant time');
assert.match(api,/\[<<"webhooks">>, WebhookId, Token\]/,'incoming webhooks have a language-neutral public POST route');
assert.match(db,/store_message\(Payload\)/,'outbound webhook payloads are encrypted at rest');
assert.match(db,/INSERT INTO server_webhooks[\s\S]*store_message\(Secret\)/,'new outbound webhook signing secrets are encrypted at rest');
assert.match(db,/secret => load_message\(Secret\)/,'outbound webhook secret reads remain backward-compatible while decrypting encrypted secrets');
assert.match(db,/Incoming webhooks are write-only credentials[\s\S]*message_id => maps:get\(id,Msg\)/,'incoming webhook responses do not expose channel message or reply contents');
assert.match(db,/server_webhook_deliveries[\s\S]*last_error/,'outbound delivery history exposes metadata without payload bodies');
assert.match(db,/retry_server_webhook_delivery[\s\S]*status='pending'/,'failed outbound deliveries can be explicitly retried');
assert.match(db,/delete_server[\s\S]*DELETE FROM incoming_webhooks[\s\S]*DELETE FROM server_bots[\s\S]*DELETE FROM users/,'server deletion cleans up server-owned automation identities');
assert.ok(archive.includes("'compose.yaml'"),'portable archive includes compose.yaml');
console.log('PASS: Plainwire 2.1 bot API/commands, blind-index message search, bot/spoiler UI, instance moderation, crypto rotation, and first-party SDK security contracts.');
