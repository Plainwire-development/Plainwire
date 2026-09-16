import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const [bridge, elm, api, db, ws, cluster, clusterWire, clusterLocal, klipy, config, media, mediaHdl, util, uploadGc, uploadHdl, makefile] = await Promise.all([
  readFile('priv/static/elm-bridge.js', 'utf8'),
  readFile('priv/static/elm/src/Main.elm', 'utf8'),
  readFile('src/pw_api.erl', 'utf8'),
  readFile('src/pw_db.erl', 'utf8'),
  readFile('src/pw_ws.erl', 'utf8'),
  readFile('src/pw_cluster.erl', 'utf8'),
  readFile('src/pw_cluster_wire.erl', 'utf8'),
  readFile('src/pw_cluster_local.erl', 'utf8'),
  readFile('src/pw_klipy.erl', 'utf8'),
  readFile('src/pw_client_config.erl', 'utf8'),
  readFile('src/pw_media.erl', 'utf8'),
  readFile('src/pw_media_hdl.erl', 'utf8'),
  readFile('src/pw_util.erl', 'utf8'),
  readFile('src/pw_upload_gc.erl', 'utf8'),
  readFile('src/pw_upload_hdl.erl', 'utf8'),
  readFile('Makefile', 'utf8')
]);

const between = (text, start, end) => {
  const a = text.indexOf(start);
  assert(a >= 0, `missing ${start}`);
  const b = text.indexOf(end, a + start.length);
  assert(b > a, `missing ${end} after ${start}`);
  return text.slice(a, b);
};

// Fresh-account onboarding is durable, but guide content stays live and ephemeral.
assert.match(db, /INSERT INTO users[\s\S]*<<"pending">>, 0, Now/, 'new registrations begin with pending onboarding');
assert.match(db, /ADD COLUMN IF NOT EXISTS onboarding_state text NOT NULL DEFAULT 'complete'/, 'existing migrated users do not get forced into onboarding');
assert.match(api, /\[<<"onboarding">>, <<"progress">>\]/, 'onboarding progress has a persisted API action');
assert.match(bridge, /const onboardingSteps = \[/, 'the onboarding tour is a real client-side state machine');
assert.match(bridge, /onboardingBotSay[\s\S]*setSyntheticTyping/, 'welcome messages are delivered live with the shared typing renderer');
assert.match(bridge, /waitForTourTarget/, 'tour navigation waits for real DOM targets');
assert.match(bridge, /if \(!target\?\.isConnected\) \{ removeTourSpotlight\(\); return; \}/, 'stale tour spotlights tear down when their target leaves the DOM');
assert.match(bridge, /closeOnboardingGuide[\s\S]*setSyntheticTyping\(ONBOARDING_SCOPE, ONBOARDING_ACTOR, false\)/, 'pausing/closing the guide clears synthetic typing immediately');
assert.match(bridge, /prefers-reduced-motion: reduce/, 'reduced-motion preference is consulted by onboarding timing');
assert.match(config, /source_repository => source_repository\(\)/, 'the public source repository is exposed through sanitized client config');

// Typing is ephemeral and socket-epoch scoped.
assert.match(ws, /<<"typing">>[\s\S]*can_type_in/, 'server validates typing scope membership before broadcast');
assert.match(bridge, /BroadcastChannel\('plainwire-typing-v1'\)/, 'same-account tabs coordinate typing claims');
assert.match(bridge, /if \(value\.type === 'ping' \|\| value\.type === 'typing'\) return;/, 'typing packets are never replayed from the websocket queue');
assert.match(bridge, /resetTypingState\(\{ skipNetwork: true \}\);[\s\S]*wsReconnectAttempt/, 'websocket epoch changes clear stale typing state before reconnect');
assert.match(bridge, /path === '\/logout'[\s\S]*clearAllSyncRecovery\(\);[\s\S]*resetTypingState/, 'logout clears sync recovery and typing state immediately');
assert.match(bridge, /access_revoked[\s\S]*clearRemoteTyping/, 'access revocation clears typing indicators for the revoked scope');
assert.match(db, /channel_message_identity\(Uid, ChannelId\)/, 'send-capable channel realtime identity has a dedicated backend read');
assert.match(db, /COALESCE\(NULLIF\(sm\.nickname,''\),u\.display_name\)/, 'channel messages prefer the server nickname without changing direct-message identity');
assert.match(db, /COALESCE\(NULLIF\(sm\.avatar_url,''\),u\.avatar_url\)/, 'channel messages prefer the server avatar without changing direct-message identity');
assert.match(ws, /typing_profile\(Uid, \{channel, Id\}[\s\S]*pw_db:channel_message_identity/, 'channel typing requires send access and uses server-scoped identity');
assert.match(ws, /pw_hub:voice_join\(Cid, Uid, self\(\), VoiceProfile\)/, 'server voice presence uses server-scoped identity');
assert.match(db, /channel_message_access\(Conn, Uid, Cid\)[\s\S]*channel_text_server_member[\s\S]*<<"view_channels">>[\s\S]*<<"send_messages">>/, 'channel posting requires a text channel plus view and send permission');
assert.match(db, /route\(\{post_channel_message[\s\S]*channel_message_access\(Conn, Uid, Cid\)/, 'channel message creation uses the shared send-access guard');
assert.match(db, /<<"channel">>\s*->\s*channel_message_access\(Conn, Uid, TargetId\)/, 'channel forwarding uses the shared send-access guard');
assert.match(elm, /List\.map \(managedChannelRow canManageChannels data\.categories\) channels/, 'server channel manager uses the in-scope capability variable');

// Roles/moderation remain backend-authoritative and hierarchy-aware.
assert.match(db, /has_server_permission\(Conn, Uid, Sid, <<"manage_roles">>\) andalso can_moderate_server_member/, 'role assignment requires both permission and hierarchy');
assert.match(db, /has_server_permission\(Conn, Uid, Sid, <<"kick_members">>\) andalso can_moderate_server_member/, 'server kicks require both permission and hierarchy');
assert.match(bridge, /const canActOnMember = \(member\)/, 'server admin UI mirrors member hierarchy decisions');
assert.match(bridge, /cb\.disabled=!canAssignRole\(role\)/, 'unassignable roles are disabled in the UI');
assert.match(db, /case Owner orelse ActorRank > 1 of[\s\S]*\{error, role_hierarchy\}/, 'non-owner role creation cannot manufacture an equal-or-higher role');
assert.match(db, /SELECT user_id FROM server_members WHERE server_id = \$1 AND user_id = \$2 FOR UPDATE[\s\S]*_ -> \{error, not_found\}/, 'role assignment rejects nonexistent target members');
assert.match(db, /can_delete_message\(Conn, Uid, AuthorId, <<\"channel\">>, ScopeId\)[\s\S]*<<\"view_channels\">>[\s\S]*<<\"manage_messages\">>/, 'channel moderation cannot bypass channel visibility');
assert.match(db, /notify_channel_members\(Conn, Sid, Sender, Cid, Msg, Now, SuppressMentions\)[\s\S]*Rows = \[R \|\| R <- MemberRows,[\s\S]*<<\"view_channels\">>/, 'channel notifications only target members who can view the channel');

// Forum membership is consistently required for author mutations; owner moderation remains possible.
assert.match(db, /can_delete => \(Uid =:= AuthorId andalso Joined\) orelse CanModerate/, 'thread delete control requires current membership for ordinary authors');
assert.match(db, /can_delete => \(Uid =:= ReplyAuthor andalso Joined\) orelse CanModerate/, 'reply delete control requires current membership for ordinary authors');
assert.match(db, /false when Uid =:= AuthorId -> \{error, forum_membership_required\}/, 'departed thread authors are rejected by the backend');
assert.match(db, /false when Uid =:= Author -> \{error, forum_membership_required\}/, 'departed reply authors are rejected by the backend');
assert.match(db, /\{ok, \[true, _ForumId, _Joined\]\} -> \{error, thread_locked\}/, 'locked-thread errors use the client contract code');
assert.match(elm, /String\.startsWith "f\/" s/, 'canonical forum route is f/');
assert.match(elm, /String\.startsWith "t\/" s/, 'canonical thread route is t/');
assert.match(elm, /String\.startsWith "thread\/" s/, 'legacy thread URLs remain accepted inbound');

// Access revocation is a cluster control-plane event, not just a local notification.
assert.match(cluster, /revoke_server_access[\s\S]*publish\(\{control, revoke_server_access\}/, 'server revocation is published through the cluster control plane');
assert.match(clusterWire, /allowed\(\{control, revoke_server_access\}/, 'cluster wire explicitly allowlists server revocation');
assert.match(clusterLocal, /deliver\(\{control, revoke_server_access\}[\s\S]*revoke_server_access/, 'realtime nodes apply server revocation to their hub state');
assert.match(db, /pw_cluster:revoke_server_access\(Target, Sid, ChannelIds\)/, 'server kick propagates realtime revocation after commit');
assert.match(db, /pw_cluster:revoke_conversation_access\(Target, Cid\)/, 'group removal propagates realtime revocation after commit');

// KLIPY credentials stay server-side and provider failures are bounded/sanitized.
assert.match(klipy, /KLIPY stays server-side: the browser never receives the integration key/, 'KLIPY key ownership is explicitly server-side');
assert.match(klipy, /MAX_RESPONSE, 2097152/, 'provider response size is bounded');
assert.match(klipy, /provider_rate_limited/, 'provider rate limits have a distinct failure path');
assert.match(klipy, /valid_klipy_url/, 'provider media URLs are validated before reaching clients');
assert.doesNotMatch(config, /KLIPY_API_KEY/, 'public client config does not expose the KLIPY key');
assert.match(bridge, /gifSearchAbort\?\.abort\(\)/, 'stale GIF searches are actively cancelled');
assert.match(bridge, /serial !== requestSerial \|\| gifPickerNode !== backdrop/, 'late GIF results cannot overwrite a newer picker state');


// Attachment ACLs and upload lifecycle agree with every composer that exposes Attach.
assert.match(db, /CHECK\(scope IN \('channel','direct','profile','server','thread','server_member'\)\)/, 'upload ACL migration includes forums and private server-member avatars');
assert.match(db, /route\(\{create_thread[\s\S]*insert_upload_refs\(Conn, Body, <<"thread">>, Tid, Now\)/, 'new thread attachments become readable through the thread scope');
assert.match(db, /route\(\{reply_thread[\s\S]*insert_upload_refs\(Conn, Body, <<"thread">>, ThreadId, Now\)/, 'thread reply attachments use the same ACL scope');
assert.match(db, /upload_ref_grants\(Conn, _Uid, _Id, \[<<"thread">>, ThreadId\]\)/, 'thread attachment authorization mirrors authenticated forum readability');
assert.match(db, /membership_created := true[\s\S]*pw_upload_gc:invalidate_user\(Uid\)/, 'joining a server clears stale attachment authorization decisions');
assert.match(db, /GrantedUsers[\s\S]*invalidate_upload_authz_users\(GrantedUsers\)/, 'adding group members clears stale attachment authorization decisions');
assert.match(uploadGc, /\{error, forbidden\} ->[\s\S]*Denials are deliberately not cached/, 'negative attachment ACL answers are not cached across later permission grants');
assert.match(db, /upload_readable\(Conn, Uid, Id, _OwnerId\)[\s\S]*SELECT scope, scope_id FROM upload_refs/, 'attachment ACL backfill fails closed instead of temporarily exposing private uploads');
assert.match(db, /\{25, \[[\s\S]*DELETE FROM upload_refs WHERE scope IN \('channel','direct','profile','server','thread'\)[\s\S]*UPDATE upload_ref_backfill SET cursor = 0, done = false/, 'upgrade migration rebuilds stale derived upload references');
assert.match(db, /\{26, \[[\s\S]*'server_member'[\s\S]*server_members sm[\s\S]*direct_threads dt/, 'upgrade migration backfills server-member and group-DM avatar ACLs');
assert.match(db, /upload_ref_grants\(Conn, Uid, _Id, \[<<"server_member">>, ServerId\]\)[\s\S]*is_member/, 'server-member avatar files are private to current server members');
assert.match(db, /sync_message_scope_upload_refs\(Conn, Scope, ScopeId, Now\)[\s\S]*<<"direct">>[\s\S]*SELECT avatar_url FROM direct_threads/, 'direct-scope reconciliation preserves the current group avatar');
assert.match(db, /replace_upload_refs\(Conn, Scope, ScopeId[\s\S]*pw_upload_gc:invalidate_upload/, 'removed attachment references revoke cached authorization immediately');
assert.match(uploadGc, /invalidate_upload\(Id\)[\s\S]*match_delete\(pw_upload_authz_cache/, 'upload-specific ACL cache revocation is implemented');
assert.match(uploadHdl, /upload_storage_unavailable/, 'upload directory failures return a controlled API error');
assert.match(uploadHdl, /content_length_required/, 'missing upload length is reported as a client precondition error');
assert.match(uploadHdl, /upload_size_mismatch/, 'upload body length mismatches are rejected as malformed client input');
assert.match(uploadHdl, /case file:write\(Io, Data\) of[\s\S]*\{error, _\} -> \{error, storage, Req1\}/, 'disk write failures do not crash the upload handler');
assert.match(bridge, /const uploadFromModal = !!uploadComposer\?\.closest\?\.\('\.modal'\)/, 'uploads remember whether they originated from a transient modal');
assert.match(bridge, /Never leak an attachment into[\s\S]*thread editor was closed/, 'a finished modal upload cannot fall into an unrelated background composer');

// Authenticated media is read-only and safe for private caches.
assert.match(mediaHdl, /<<"GET">> -> authenticate_and_serve/, 'media proxy explicitly accepts GET');
assert.match(mediaHdl, /<<"HEAD">> -> authenticate_and_serve/, 'media proxy explicitly supports HEAD without opening arbitrary verbs');
assert.match(mediaHdl, /cowboy_req:reply\(405/, 'media proxy rejects unsupported HTTP methods');
assert.match(mediaHdl, /sha256_hex\(Body\)/, 'media ETags track representation bytes rather than stable URL tokens');
assert.match(mediaHdl, /private, max-age=3600/, 'authenticated media is not marked public/immutable');
assert.match(media, /fetch_operation_budget_ms\(\)[\s\S]*FETCH_SLOT_WAIT_MS[\s\S]*media_http_timeout_ms\(\)[\s\S]*FETCH_BUDGET_GRACE_MS/, 'media coalescing waiters share the configured owner fetch budget');
assert.doesNotMatch(media, /await_fetch\(Key, Url, Now \+ 17000\)|Now - Started < 20000/, 'media coalescing no longer uses stale hard-coded deadlines shorter than supported fetch timeouts');
assert.match(media, /true -> \{error, overloaded\}/, 'media saturation returns a bounded result instead of crashing the coalescing owner');
assert.match(media, /MAX_FETCH_RESULTS, 4096[\s\S]*trim_fetch_results\(\)[\s\S]*ets:info\(\?RESULTS, size\)/, 'short-lived media coalescing results have a hard memory-cardinality bound');
assert.match(media, /fetch_result\(Key, Now\)[\s\S]*ets:delete\(\?RESULTS, Key\)/, 'expired per-URL coalescing results are removed on lookup');
assert.match(media, /cache_negative\(Key, Reason0, Now, TtlMs\)[\s\S]*cacheable_error_reason\(Reason0\)[\s\S]*prune_cache\(Now\)/, 'negative media cache entries are normalized and share the successful-cache size and memory bounds');
assert.match(media, /<<"error">>, Reason, Expires[\s\S]*is_atom\(Reason\)[\s\S]*\{error, Reason\}/, 'cached media failures preserve their original failure reason');
assert.match(media, /cacheable_error_reason\(timeout\) -> timeout;[\s\S]*cacheable_error_reason\(_\) -> upstream_error/, 'arbitrary httpc failure terms cannot be mistaken for cached media content types');
assert.match(mediaHdl, /\{error, overloaded\}[\s\S]*503[\s\S]*media_overloaded/, 'media saturation is surfaced as temporary unavailability rather than a generic upstream error');
assert.match(media, /case safe_data_url_parse\(Rest\)[\s\S]*error ->[\s\S]*<<>>/, 'malformed data-image avatars fail closed');
assert.match(util, /<<"data:", _\/binary>> -> pw_media:cache_data_url\(Url\)/, 'profile image mapping routes data URLs through validated media caching');
assert.match(makefile, /^source: verify frontend backend$/m, 'source archives are compile-gated on both frontend and backend');


// Persistence transitions are atomic and do not couple committed writes to realtime/notification success.
assert.match(db, /SELECT pg_advisory_lock\(\$1\)[\s\S]*lists:foreach\(fun\(\{V, Sqls\}\) -> migrate_to/, 'cluster startup serializes schema migrations');
assert.match(db, /migrate_to\(Conn, Version, Sqls\)[\s\S]*with_tx\(Conn, fun\(\)[\s\S]*safe_exec\(Conn, Sql\)/, 'each schema migration is transactional');
assert.match(db, /route\(\{accept_message_request[\s\S]*FOR UPDATE[\s\S]*changed => true[\s\S]*best_effort_direct_notifications/, 'message-request acceptance is locked/idempotent and notifications are post-commit');
assert.match(db, /route\(\{deny_message_request[\s\S]*remove_scope_upload_refs[\s\S]*DELETE FROM direct_threads[\s\S]*revoke_conversation_access/, 'message-request denial atomically removes data and revokes every former member after commit');
assert.match(db, /create_conversation0\(Conn[\s\S]*with_tx\(Conn[\s\S]*best_effort_direct_notifications/, 'conversation creation commits membership before notification delivery');
assert.match(db, /create_one_to_one0\(Conn[\s\S]*pg_advisory_xact_lock\(\$1, \$2\)[\s\S]*existing_one_to_one/, 'concurrent 1:1 creation is serialized on the user pair');
assert.match(db, /route\(\{create_channel[\s\S]*with_tx\(Conn[\s\S]*SELECT id FROM servers WHERE id = \$1 FOR UPDATE[\s\S]*channel_created/, 'channel creation serializes duplicate-name and position allocation before broadcasting');
assert.match(db, /route\(\{create_category[\s\S]*with_tx\(Conn[\s\S]*SELECT id FROM servers WHERE id = \$1 FOR UPDATE[\s\S]*category_created/, 'category position allocation is serialized across API nodes');
assert.match(db, /best_effort_user_notification\(Conn[\s\S]*catch C:R:S/, 'single-recipient notification failures cannot masquerade as failed committed mutations');


// Bootstrap/runtime failures are isolated instead of blanking the whole app or
// being misreported as an authentication failure.
assert.match(db, /sync_component\(notifications[\s\S]*sync_component\(conversations[\s\S]*sync_component\(servers[\s\S]*sync_component\(friends/, 'full sync isolates independent data components');
assert.match(db, /sync_degraded => \(Warnings =\/= \[\]\), sync_warnings => Warnings/, 'sync reports degraded components without changing the success envelope');
assert.match(db, /sync_component\(Name, Default, Fun\)[\s\S]*db_error\(Reason\)[\s\S]*erlang:raise/, 'transient DB failures still escape to the reconnect/retry path');
assert.match(api, /\{error, internal_error\} -> pw_util:err_json\(Req0, 500, <<"internal_error">>\)/, 'auth backend failures are not mislabeled as 401');
assert.match(ws, /\{error, no_session\}[\s\S]*reply\(401[\s\S]*\{error, Reason\}[\s\S]*reply\(503/, 'websocket distinguishes invalid sessions from backend lookup failures');
assert.match(db, /route\(\{session, Token\}[\s\S]*\{ok, undefined\} ->[\s\S]*\{error, no_session\};[\s\S]*\{error, Reason\} ->[\s\S]*erlang:error\(\{sql_error, Reason\}\)/, 'session lookup preserves SQL failures instead of disguising them as expired authentication');
assert.match(bridge, /const syncRecoveryPaths = \{[\s\S]*friends: '\/friends'[\s\S]*servers: '\/servers'/, 'degraded bootstrap has component-scoped recovery endpoints');
assert.match(bridge, /const succeeded = res\.ok && json\.ok === true;[\s\S]*return succeeded \? json\.data : null;/, 'HTTP status and API envelope share one success definition for recovery and Elm delivery');
assert.ok(!bridge.includes("if (json.ok && method === 'POST'"), 'post-processing uses the unified HTTP/API success definition');
assert.match(bridge, /scheduleSyncRecovery[\s\S]*performApi\(\{ method: 'GET', path, silent: true \}\)/, 'component recovery retries quietly without replacing good UI state with error responses');
assert.match(bridge, /inFlight: false/, 'component recovery tracks in-flight work so repeated sync warnings cannot duplicate requests');
assert.match(bridge, /let syncRecoveryNoticeShown = false/, 'degraded component recovery coalesces its user-facing reconnect status');
assert.match(bridge, /current\.attempts >= 3 && !syncRecoveryNoticeShown[\s\S]*syncRecoveryNoticeShown = true/, 'friends and servers cannot each emit the same recovery toast');
assert.match(bridge, /syncRecovery\.get\(component\) !== current/, 'stale in-flight component requests cannot resurrect recovery after newer healthy state');
assert.match(bridge, /syncRecoveryComponentsByPath/, 'successful direct component refreshes clear stale recovery state');
assert.match(bridge, /!succeeded && recoveredComponent && !silent && !authReloadScheduled[\s\S]*scheduleSyncRecovery\(recoveredComponent, 500\)/, 'failed direct component refreshes start isolated recovery');
assert.match(bridge, /catch \(error\)[\s\S]*recoveryComponent = method === 'GET'[\s\S]*scheduleSyncRecovery\(recoveryComponent, 500\)/, 'network failures on direct component refreshes start isolated recovery');
assert.match(bridge, /scheduleAuthReload[\s\S]*clearAllSyncRecovery/, 'expired sessions stop component retry loops and reload once');
assert.match(elm, /method == "GET" && List\.member tag \[ "\/friends", "\/servers", "\/notifications", "\/conversations" \]/, 'component refresh failures preserve the current view without duplicate error toasts');
assert.match(elm, /err == "not_authenticated"[\s\S]*booting = False, authBusy = False/, 'session expiry is quiet while the bridge performs its one-shot reload');
assert.match(bridge, /failed = new Set\(warnings\)[\s\S]*sync_degraded[\s\S]*scheduleSyncRecovery/, 'full sync schedules retries only for degraded components');
assert.doesNotMatch(bridge, /Check the server log for sync_component_failed/, 'internal sync diagnostics are not leaked into user-facing recovery copy');
assert.match(elm, /failed "friends"[\s\S]*model\.friends[\s\S]*data\.friends/, 'degraded friend sync preserves last-known-good friend state');
assert.match(elm, /failed "servers"[\s\S]*model\.servers[\s\S]*data\.servers/, 'degraded server sync preserves last-known-good server state');
assert.match(elm, /Friends ->[\s\S]*ApiGet "\/friends"/, 'opening Friends independently refreshes the friend list');
assert.match(elm, /Just "online"[\s\S]*Just "away"[\s\S]*Just "busy"/, 'Friends Online filter recognizes only active presence states');
assert.match(elm, /BridgeEvent "unblock_user"/, 'Friends uses the ownership-checked unblock action');
assert.match(db, /fr\.status <> 'blocked' OR fr\.requester_id = \$1/, 'blocked list exposes only blocks created by the current user');
assert.match(db, /map_rows_resilient\(friends[\s\S]*map_rows_resilient\(servers/, 'one malformed friend/server row cannot collapse an entire sync component');
assert.match(db, /\{27, \[[\s\S]*ALTER TABLE users ADD COLUMN IF NOT EXISTS created_at[\s\S]*CREATE TABLE IF NOT EXISTS channel_categories/, 'compatibility migration repairs legacy user and server schema used by bootstrap');
assert.match(db, /ALTER TABLE friendships ADD COLUMN IF NOT EXISTS updated_at bigint NOT NULL DEFAULT 0/, 'compatibility migration repairs friend timestamps required by list ordering');
assert.match(db, /ALTER TABLE server_member_roles ADD COLUMN IF NOT EXISTS assigned_by/, 'compatibility migration repairs role assignment ownership metadata');
assert.match(db, /ALTER TABLE server_member_roles ADD COLUMN IF NOT EXISTS assigned_at bigint NOT NULL DEFAULT 0/, 'compatibility migration repairs role assignment timestamps');
assert.match(elm, /attribute "data-avatar-fallback" name[\s\S]*attribute "data-avatar-fallback" s\.name/, 'avatar elements preserve the full accessible identity while deriving local fallback initials');
assert.match(bridge, /avatarFallback[\s\S]*fallbackApplied/, 'avatar failures resolve to a local fallback instead of retry storms');
assert.doesNotMatch(bridge, /avatarTries|avatar-retrying|replaceWith\(/, 'obsolete avatar retry/DOM replacement machinery is gone');
assert.match(elm, /attribute "loading" "lazy"[\s\S]*attribute "fetchpriority" "low"/, 'list icons use browser-managed lazy loading instead of eager request stampedes');


// Server deletion and reactions are backend-authoritative, transaction-safe, and bounded.
assert.match(db, /route\(\{delete_server[\s\S]*SELECT owner_id,name FROM servers WHERE id = \$1 FOR UPDATE/, 'server deletion locks the owner row and remains owner-authoritative');
assert.match(db, /ConfirmName =:= ServerName[\s\S]*confirmation_mismatch/, 'server deletion independently enforces exact-name confirmation server-side');
assert.match(db, /SELECT id FROM channels WHERE server_id = \$1 ORDER BY id ASC FOR UPDATE[\s\S]*DELETE FROM notifications[\s\S]*DELETE FROM upload_refs[\s\S]*DELETE FROM messages[\s\S]*DELETE FROM servers/, 'server deletion purges polymorphic traces before FK cascades remove owned rows');
assert.match(db, /pw_cluster:revoke_server_access\(MemberId, Sid, ChannelIds\)/, 'server deletion revokes live access for every former member after commit');
assert.match(db, /route\(\{post_channel_message[\s\S]*SELECT id FROM servers WHERE id=\$1 FOR KEY SHARE/, 'channel posting holds a parent server lock that conflicts with concurrent deletion');
assert.match(db, /route\(\{forward_message[\s\S]*SELECT id FROM servers WHERE id=\$1 FOR KEY SHARE/, 'channel forwarding also serializes against concurrent server deletion');
const moveChannel = between(db, 'route({move_channel, Uid, ChannelId0, CatId0, Position0}, Conn) ->', 'route({create_invite,');
assert.ok(moveChannel.indexOf('SELECT id FROM servers WHERE id = $1 FOR UPDATE') < moveChannel.indexOf('SELECT id FROM channels WHERE id=$1 AND server_id=$2 FOR UPDATE'), 'channel moves use server-before-channel lock order');
assert.match(db, /\{28, \[[\s\S]*CREATE TABLE IF NOT EXISTS message_reactions[\s\S]*PRIMARY KEY\(message_id,user_id,emoji\)[\s\S]*idx_message_reactions_user/, 'reactions use a normalized, cascade-safe table with message and user lookup indexes');
assert.match(db, /route\(\{toggle_message_reaction[\s\S]*channel_message_access\(Conn, Uid, ScopeId\)[\s\S]*conversation_can_send/, 'reaction writes require current send-capable scope access');
assert.match(db, /route\(\{delete_message[\s\S]*DELETE FROM message_reactions WHERE message_id=\$1/, 'soft-deleting a message removes otherwise invisible reaction records');
assert.match(db, /batch_message_reactions[\s\S]*bool_or\(mr\.user_id=\$5\)/, 'message pages batch reaction aggregation and viewer state instead of N+1 fetching');
assert.match(db, /server_member_profile[\s\S]*server_permissions0\(Conn, Uid, Sid\)[\s\S]*mr\.user_id=\$2/, 'targeted server profiles require server membership and fetch one member');
assert.match(db, /\(r\.permissions & 1073741824\) DESC[\s\S]*\(r\.permissions & 16\) DESC[\s\S]*r\.position DESC/, 'presentation role color prioritizes actual privilege strength before display position');

console.log('PASS: 1.7.5-2 stabilization, onboarding, scoped identity, typing, moderation, forum, cluster-revocation, KLIPY, and route contracts.');
