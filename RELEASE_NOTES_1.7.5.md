# Plainwire 1.7.5

## September 15 sync/auth hotfix

* Initial `/api/sync` is no longer all-or-nothing: notifications, conversations, servers and friends are isolated so one permanent legacy-row/schema/query failure cannot blank the entire application. Transient database failures still propagate into the normal reconnect/retry path rather than being hidden.
* Degraded syncs return the normal lists plus `sync_degraded`/`sync_warnings`, emit a precise `sync_component_failed` server log, and surface one non-blocking client diagnostic toast.
* HTTP and WebSocket session lookup now distinguish a genuinely missing/expired session from backend/database/internal lookup failure. WebSocket handshakes use 401 only for real authentication failure and 503 for a temporarily unavailable session service.
* Plainwire-owned Erlang warnings from deprecated `catch`, unused moderation arguments, an unused request timestamp and dead notification wrapper arities were cleaned up. The third-party epgsql deprecation warning remains upstream-owned.
* The release archive again includes its required `RELEASE_NOTES_1.7.5.md`; source verification now guards the sync/auth recovery contract.

Plainwire 1.7.5 is a large integration and reliability release. It adds a real first-run guide, realtime typing, richer server roles and server-scoped profiles, Wires, stronger forum/thread moderation, optional KLIPY GIF search, and another WebRTC hardening pass. The focus is not adding decorative controls: permissions and moderation remain backend-authoritative, realtime revocation is enforced across cluster nodes, and the UI is kept aligned with what the server actually permits.

## First-run Plainwire guide

* Fresh accounts start with a persisted onboarding state while existing migrated accounts remain completed by default.
* The Plainwire P entry uses live typing/message cadence, chimes, route-aware spotlights and page transitions instead of a prewritten fake transcript.
* Progress, completion, dismissal and replay are persisted. The guide can move into a floating presentation outside the DM view and cleanly tears down stale spotlights and synthetic typing.
* Reduced-motion preferences, sound settings, keyboard Escape handling and small-screen layouts are respected.
* The configured source repository is exposed through sanitized public client config and linked at guide completion.

## Realtime chat and identity

* DMs, server channels and forum threads now have ephemeral typing indicators with server-side membership checks, inactivity expiry and multi-tab coordination.
* Typing state is never queued for reconnect or persisted. Logout, access revocation and websocket epoch changes clear stale indicators.
* Server nicknames and server avatars are now used consistently for channel message identity, reply previews, channel typing and server voice presence, while account-global identity remains the source outside that server.
* Message editing is server-authoritative. Forwarded messages retain an immutable content snapshot so later source edits cannot leak across scopes.

## Servers, roles and Wires

* Custom server roles have persisted colors, ordering and permission bitmasks alongside owner/admin/member compatibility.
* Role assignment, role editing, kicking, message moderation and member-profile management enforce hierarchy on the server. The UI mirrors those limits but is not trusted as the permission boundary.
* Members can have per-server nickname, avatar and bio profiles.
* Wires are the user-facing server join/share system. New UI and output use Wire terminology while legacy incoming invite URLs remain accepted for compatibility.
* Server/group removal immediately revokes live subscriptions and active RTC seats. Revocation is propagated through the realtime cluster control plane rather than waiting for reconnect.

## Forums and threads

* Canonical forum and thread routes are `f/` and `t/`; legacy inbound routes remain accepted where needed.
* Authors can edit their own threads and replies while they remain forum members. Forum owners retain moderation authority, including pin/lock and deletion controls.
* Locked-thread reply errors now use the same `thread_locked` contract expected by the client.
* Departed forum authors can no longer keep mutating old threads or replies merely because they still own the historical post.
* Direct thread loads return viewer-specific edit/delete/moderation state instead of relying on previously loaded forum state.

## Calls and screen sharing

* Incoming-call Accept remains distinct from joining/rejoining an already active call, stale rooms cannot be resurrected, and duplicate tabs use explicit RTC ownership.
* Reconnect restores room membership before fresh signaling and avoids replaying stale signaling from a previous socket epoch.
* Screen sharing has sender-replacement rollback and peer re-snapshot handling so peers joining during a chooser/transition are not stranded.
* System/share audio prefers browser-provided display audio, can use explicit or detected PipeWire/Pulse monitor/loopback sources, and distinguishes a merely attached audio track from actually measured audio.
* Saved loopback source IDs are discarded when the OS audio graph changes and the device disappears.

## GIF search and privacy

* Optional KLIPY search is proxied through the backend; the provider API key never enters public client config.
* Search requests are cancellable/debounced, late results cannot overwrite a newer picker state, provider response sizes are bounded and media URLs are validated.
* Disabled/no-key, malformed-response and provider-rate-limit paths fail without exposing provider credentials.

## Verification and release hygiene

* 1.7.5 adds a source-contract suite covering onboarding, scoped identity, typing cleanup, moderation hierarchy, forum membership, cluster revocation, KLIPY privacy/failure paths and canonical routing.
* The contract suite is part of ordinary source/release verification alongside RTC and UI contracts.
* Version metadata remains cross-checked across the OTP app, relx configuration, client-config fallback, Elm UI marker and release notes.


### Final release audit fixes

* Fixed three Elm channel-management views that referenced an out-of-scope `canManage` name instead of the actual `canManageChannels` capability.
* Channel posting, forwarding, typing, moderation and notifications now share backend-authoritative visibility/send rules so hidden channels cannot be used as API or notification side doors.
* Attachment authorization cache invalidation now covers server kicks, role/default-permission changes, group removal, joins/member grants and unblock transitions. Negative ACL decisions are not cached, and clustered API nodes bypass the node-local positive ACL cache.
* Forum thread/reply attachments now receive real `thread` upload ACL references; migration 24 backfills existing `/api/files/...` links. Thread/forum deletion removes those scope references.
* Upload storage setup, chunk writes and lost finalization reservations return controlled errors instead of crashing or silently orphaning definitive failures.
* Category reorder/update/delete input handling is bounded, validated and transactional; malformed JSON elements can no longer reach map operations as crashable values.
* Role creation/assignment hierarchy checks reject impossible or nonexistent targets instead of reporting misleading success.
* Authenticated media proxy responses are read-only/private, representation-ETagged and resilient to binary/iolist OTP HTTP headers.
* KLIPY provider records are treated as untrusted input: malformed individual results are skipped and pagination/media fields are bounded and validated.
* The frontend dependency graph was refreshed to Less 4.9.1 / `probe-image-size` 7.4.0, removing the old vulnerable `image-size` path. Reviewed native install scripts are pinned through npm `allowScripts`, and the Elm wrapper is pinned exactly for reproducibility.
* Source verification now checks dependency/security invariants, contiguous migrations and accidental duplicate Erlang result expressions in addition to the RTC/UI/1.7.5 contracts.
* Derived upload ACL references are now reconciled when profile/server/member/group images or message/thread content changes; migrations 25–26 rebuild stale refs and backfill private server-member/group avatars without making unrelated uploads public.
* Channel/category creation and movement now serialize on server/channel rows so duplicate-name and `max(position)+1` races cannot split state across API nodes. Brand-new one-to-one DM creation is likewise serialized on the user pair to prevent duplicate conversations.
* Multi-row content and membership mutations commit before websocket/push side effects; notification failures can no longer make a committed message/request look failed and invite duplicate retries.
* Database migrations are serialized with a PostgreSQL advisory lock and each version is applied transactionally, preventing clustered startup races and half-applied schemas.
