import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read=p=>readFileSync(p,'utf8');
const db=read('src/pw_db.erl');
const api=read('src/pw_api.erl');
const http=read('src/pw_app_http.erl');
const outbound=read('src/pw_outbound_url.erl');
const interaction=read('src/pw_app_interaction_dispatcher.erl');
const ai=read('src/pw_ai_bot_dispatcher.erl');
const bridge=read('priv/static/elm-bridge.js');
const env=read('.env.example');

assert.match(db,/\{46, \[[\s\S]*developer_applications[\s\S]*developer_app_installations[\s\S]*developer_app_commands/,'migration 46 installs developer applications, installations, and command templates');
assert.match(db,/\{47, \[[\s\S]*bot_command_permissions/,'migration 47 installs per-command permission rules');
assert.match(db,/\{48, \[[\s\S]*idx_bot_command_invocations_active[\s\S]*status IN \('pending','claimed'\)/,'migration 48 keeps internal application claims on the active queue');
assert.match(db,/developer_app_owned_row\(Conn, Uid, AppId/,'developer management is owner-scoped');
assert.match(db,/WHERE a\.public=true/,'public directory only returns explicitly public applications');
assert.match(db,/maps:without\(\[interaction, ai, avatar_source, owner_user_id\], App\)/,'public application detail strips owner and connector-private metadata');
const publicListRoute=db.slice(db.indexOf('route({public_developer_apps'), db.indexOf('route({public_developer_app,'));
assert.doesNotMatch(publicListRoute,/(?:interaction_secret|ai_api_key|token_hash)/,'public app listing query does not expose secrets');
assert.match(db,/install_developer_app_internal[\s\S]*has_server_permission\(Conn, Uid, Sid, <<"manage_bots">>\)/,'application installation requires manage-bots permission');
assert.match(db,/grantable_role_permissions\(Conn, Uid, Sid, Requested\)/,'requested app permissions are bounded by installer-grantable permissions');
assert.match(db,/rotate_developer_app_installation[\s\S]*token_hash/,'installation token rotation replaces the stored token hash');
assert.match(db,/uninstall_developer_app_internal[\s\S]*account_state='disabled'/,'uninstall disables the detached bot identity while preserving historical authorship');
assert.match(db,/sync_developer_commands_to_installation/,'developer command templates synchronize into installed bots');
assert.match(db,/bot_command_permission_allowed[\s\S]*subject_type='user'[\s\S]*subject_type='channel'[\s\S]*subject_type='role'/,'command permission precedence checks user, then channel, then roles');

assert.ok(interaction.includes('crypto:mac(hmac, sha256, Secret, <<Timestamp/binary, ".", Payload/binary>>)'), 'interaction payloads are HMAC-SHA256 signed over timestamp and body');
assert.match(interaction,/worker_timeout[\s\S]*interaction_timeout/,'interaction workers are bounded by a timeout');
assert.ok(db.includes('Attempts >= MaxAttempts') && db.includes('internal_app_retry_delay_ms(Attempts)'), 'internal application deliveries have bounded retries and terminal failure');
assert.match(http,/PLAINWIRE_APP_REQUEST_MAX_BYTES/,'developer app HTTP requests have a hard size cap');
assert.match(http,/PLAINWIRE_APP_RESPONSE_MAX_BYTES/,'developer app HTTP responses have a hard size cap');
assert.match(http,/gun:cancel[\s\S]*response_too_large/,'oversized responses are cancelled while streaming');
assert.match(outbound,/resolve_app_allowed[\s\S]*<<"https">>[\s\S]*resolve_app_loopback/,'developer app egress uses an app-specific HTTPS/loopback policy');
assert.match(outbound,/PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP[\s\S]*<<"localhost">>[\s\S]*<<"127\.0\.0\.1">>[\s\S]*<<"::1">>/,'plaintext app HTTP is limited to an explicit exact-loopback development policy');
assert.match(http,/gun:open\(Address, Port/,'HTTP connects to the policy-resolved address rather than resolving the hostname again');
assert.doesNotMatch(http,/location/i,'app HTTP helper does not inspect Location headers or follow redirects');

assert.match(db,/command_claim_authorization[\s\S]*channel_message_access\(Conn, UserId, Cid\)[\s\S]*bot_command_permission_allowed/,'claim-time delivery rechecks the invoking user and command permission before decrypting arguments');
assert.ok(db.indexOf('command_claim_authorization(Conn, UserId, Sid, Cid, CommandId, BotUid)') < db.indexOf('Args = decode_command_args(ArgsCipher)'), 'internal app delivery authorizes before decrypting command arguments');
assert.ok(db.includes('pw_crypto:encrypt(NewKey0)') && db.includes('ai_api_key=$5'), 'AI API keys are encrypted before durable storage');
assert.ok(db.includes('pw_crypto:encrypt(SystemPrompt)') && db.includes('ai_system_prompt=$6'), 'AI system prompts are encrypted before durable storage');
assert.doesNotMatch(ai,/FROM messages |ai_context_messages/,'hosted AI dispatcher does not query message history itself');
assert.match(db,/ai_context_messages\(Conn, Cid, RequestMid, AiIncludeHistory, AiHistoryMessages\)/,'opt-in AI context is assembled at claim time after authorization');
assert.ok(db.indexOf('command_claim_authorization(Conn, UserId, Sid, Cid, CommandId, BotUid)') < db.indexOf('ai_context_messages(Conn, Cid, RequestMid'), 'channel history is not loaded until claim-time authorization succeeds');
assert.match(ai,/PLAINWIRE_AI_COMMANDS_PER_APP_PER_MINUTE[\s\S]*allow_shared/,'AI commands have a shared per-application rate limit');
assert.match(ai,/PLAINWIRE_AI_COMMAND_CONCURRENCY/,'AI command concurrency is bounded');
assert.match(db,/bot_command_handler_available[\s\S]*ai_enabled/,'disabled AI handlers become unavailable dynamically');
assert.match(db,/bot_command_handler_available[\s\S]*interaction_url/,'disabled interaction handlers become unavailable dynamically');
assert.match(env,/PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP=false/,'unsafe loopback plaintext app HTTP is opt-in');

// DOM safety: the Developer Portal builder uses DOM nodes/textContent, not HTML string injection.
const portalStart=bridge.indexOf('class PlainwireDeveloperPortal');
const portalEnd=bridge.indexOf("customElements.define('pw-developer-portal'", portalStart);
const portal=bridge.slice(portalStart, portalEnd > portalStart ? portalEnd : portalStart + 60000);
assert.ok(portal.length > 1000, 'Developer Portal source is present');
assert.doesNotMatch(portal,/innerHTML\s*=|insertAdjacentHTML|document\.write/,'Developer Portal does not inject app/operator strings as HTML');
assert.match(portal,/textContent/,'Developer Portal writes text through DOM textContent');
assert.match(api,/\[<<"developer">>, <<"apps">>/,'developer application API is authenticated under the developer route family');

assert.match(db,/\{51, \[[\s\S]*ai_chat_enabled[\s\S]*ai_provider/,'migration 51 installs provider-aware AI chat settings');
assert.match(db,/maybe_enqueue_ai_chat[\s\S]*ai_chat_enabled=true/,'mention/reply chat is opt-in per application');
assert.match(db,/resolve_app_allowed\(Url\)/,'developer and AI endpoints use the app HTTPS/loopback policy');
assert.match(bridge,/Answer mentions and replies/,'Developer Portal can enable a no-code AI chatbot');
assert.match(bridge,/Command options/,'Developer Portal builds typed command options without JSON');

console.log('PASS: Plainwire 2.1 Developer Applications, interaction egress, AI connector, claim-time authorization, secret handling, and DOM-safety contracts.');
