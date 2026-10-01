# Plainwire 2.6.4

2.6.4 adds targeted ringing for active group calls and strengthens invitation lifecycle and media regressions. It adds no database migrations or production environment variables. Installs on 2.6.3 can upgrade directly.

## Group call invitations

- While connected to a group call, right-click an absent member in the People list and choose **Ring to call**. Touch screens support pressing and holding the member row. Self, blocked users and members already in the call have no ring action.
- The invited member sees who rang them and the group name, with Accept and Decline controls. Their microphone stays off until they accept. The sender sees a pending ringing badge and cannot repeatedly click the action while it is pending.
- Accepting adds the member to the existing call. Declining, expiration, disconnecting, losing group access, or the caller leaving clears only the invitation and preserves the ongoing call.
- The backend checks both accounts and accepted group membership, blocks in either direction, caller socket ownership, recipient availability and room capacity. Database failures deny invitations. Bot accounts cannot ring or be rung.
- Invitations use recipient-bound, expiring random tokens. Duplicate requests preserve the original token and deadline. Stale accepts, declines and timers cannot affect a newer invitation. Accepting in one tab dismisses the popup in the other tabs without joining them.
- A caller can ring a given member once per 30 seconds, and a member can receive at most three new targeted invitations per minute across callers. Existing call timeout and participant-capacity settings apply. Offline or busy members are not queued for later ringing.

## Validation

New executable backend regressions cover authorization against PostgreSQL, malformed and forged tokens, socket handoffs, disconnect and access revocation, capacity changes during ringing, duplicate tabs, stale timers and shared recipient rate limits.

The real WebRTC browser suite now exercises three-person group calls, desktop and mobile member menus, microphone privacy before acceptance, decline and timeout isolation, stale notification handling, and bidirectional audio on every peer connection. The original connection and microphone remain live when another member accepts. RTC audio-volume checks continue to measure actual media duration to tolerate cached browser statistics.

Validation passed `make check` with 250 backend tests, including the PostgreSQL regressions, frontend and backend compilation, source contracts, browser UI/security tests, responsive settings, admin actions and the complete real WebRTC suite. GitHub CI and the portable source archive are checked before publication. Source downloads include SHA-256 checksums. No additional deployment configuration is required. See [group call invitations](docs/GROUP_CALL_INVITATIONS.md) for behavior and protocol details.
