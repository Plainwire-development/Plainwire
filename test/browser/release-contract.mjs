import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const [bridge, elm, api, db, ws, cluster, clusterWire, clusterLocal, klipy, config, mediaHdl, uploadGc, uploadHdl, makefile] = await Promise.all([
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
  readFile('src/pw_media_hdl.erl', 'utf8'),
  readFile('src/pw_upload_gc.erl', 'utf8'),
  readFile('src/pw_upload_hdl.erl', 'utf8'),
  readFile('Makefile', 'utf8')
]);

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
assert.match(bridge, /path === '\/logout'\) resetTypingState/, 'logout clears typing state immediately');
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

console.log('PASS: 1.7.5 onboarding, scoped identity, typing, moderation, forum, cluster-revocation, KLIPY, and route contracts.');
