# Plainwire 1.7.5-2

Plainwire 1.7.5-2 is a reliability and interaction release focused on server identity, message reactions, server lifecycle safety, compact-window polish, and call recovery.

## Server identity and roles

- Server members now have a dedicated server-profile view with their server nickname, server avatar/bio, and assigned roles.
- Member rows, channel-message usernames, right-click menus, and touch long-press gestures expose the server profile while keeping the full account profile available as a separate action.
- Server member and channel-message names inherit the color of the member's strongest permission-bearing custom role. This is presentation-only; moderation hierarchy remains position-based and backend-authoritative.
- Server profiles use a targeted member endpoint instead of re-downloading the full server member/role state.

## Message reactions

- Messages support realtime emoji reactions in channels and DMs.
- Quick reactions live in the message menu, with the existing emoji picker available for the full supported reaction set.
- Reaction state is normalized in PostgreSQL, batched when loading message pages, rate-limited independently, and validated server-side.
- Reacting requires current send-capable access to the message scope.
- Soft-deleting a message also removes its reaction rows; hard message deletion cascades reaction cleanup.

## Server deletion

- Server owners can delete a server from its context menu or settings danger zone after typing the server name exactly.
- Deletion is owner-authorized again on the backend and runs in one database transaction.
- Server-owned FK data is removed by cascade while polymorphic channel messages, channel notifications, and upload ACL references are explicitly purged first.
- Channel message creation/forwarding and channel movement use compatible server-first row-locking rules so deletion cannot race a new message into an orphan or create a lock-order inversion.
- Former members receive realtime access revocation and clients immediately evict revoked server state before the follow-up sync.

## Calls and voice

- Mute and deafen are strictly media-state operations; they do not tear down or renegotiate peer connections.
- Existing ICE restart remains the first recovery path for transport failures.
- A dead/missing remote audio receiver can now trigger a bounded rebuild of only the affected peer connection, guarded by the current room epoch and authoritative roster.
- Automatic peer rebuilds are rate-bounded to prevent reconnect storms on bad networks and are cleared when leaving the room.
- Connection notifications are deduplicated and successful automatic recovery reports that audio reconnected.
- Incoming/outgoing call popups have clearer hierarchy and call-state copy while preserving Accept, Decline, and Cancel behavior.

## Interface and quality

- The GIF composer action no longer duplicates its visible label, preventing overlap in narrow windows while retaining its accessible label and touch target.
- Reaction pickers, server danger controls, server profiles, and call surfaces extend the existing Plainwire visual language rather than replacing it.
- Touch long-press context gestures avoid interactive descendants, cancel on movement/scroll, suppress the synthetic follow-up click, and release retained DOM targets afterward.
- Realtime server revocation now clears navigation/cache/profile state immediately instead of waiting for a network refresh.
- Direct-message navigation previews are plain-text, single-line summaries; attachment floods collapse to a compact count instead of rendering media in the sidebar. The server also caps last-message preview payloads before sync.

## Data and security hardening

- New mutation endpoints remain behind Plainwire's authenticated CSRF gate.
- Server deletion uses parameterized SQL, exact owner/name validation, transactional cleanup, and post-commit realtime revocation.
- Reaction emoji values are allowlisted server-side and independently rate limited.
- Server-profile reads require current server membership.
- The reaction table includes message and user lookup indexes and foreign-key cascades.

See `BUILD_STATUS.md` in release archives for the exact verification performed for this source build and any environment-only validation gates.
