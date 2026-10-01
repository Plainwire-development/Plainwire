# Plainwire 2.6.3

2.6.3 fixes attachment authorization, authentication and account recovery, client plugin isolation, and UI state bugs found during the security audit. It adds no database migrations or production environment variables. Installs on 2.6.2 can upgrade directly.

## Security and account recovery

- Posting a known upload ID can no longer grant access to an unreadable file. Posts, edits, forwards, threads and replies check that every referenced upload is ready and currently readable by the author. Channel edits and forwards also enforce attachment and voice-note permissions.
- Both normal and host-admin JSON APIs require `Content-Type: application/json`, including optional charset parameters. Requests with a missing or different media type receive HTTP 415. This closes form-based login CSRF; custom API clients must send the JSON content type.
- JSON request limits count every received byte, including the final body chunk, preventing oversized complete requests from bypassing the configured limit.
- Password reset validates the new password before claiming the link, and commits the token claim, password change and session revocation together. A database failure leaves the link usable for a retry.
- Password changes revoke outstanding reset links and host-admin sessions. Reset revokes all ordinary and host-admin sessions. Changing or removing a recovery email revokes old links, and reset rechecks the current verified address and account eligibility.
- Email verification, replacement and removal update account and token state in one transaction, with cache invalidation after commit.

## Plugins and UI

- Client plugins use a worker with its own enforced Content Security Policy. Direct networking, script imports and nested workers remain blocked even if a plugin restores browser globals. API writes still require an explicit grant, and encoded path traversal is rejected.
- Saved plugins start after authentication, preserve worker state during periodic reconciliation, and stop on logout. A theme compiler failure does not block plugins.
- Loading another person's profile no longer overwrites the bridge's signed-in identity used by moderation, typing and calls.
- Delayed server, thread, profile, forum-list and bot-command responses cannot replace another active view. Closing a member-profile dialog keeps it closed when its response arrives.
- Late bot-command acknowledgements clear only the submitted draft. New text and drafts in another channel are preserved, and duplicate in-flight submissions are suppressed.
- Bridge dialogs have accessible names, keyboard focus trapping, Escape dismissal and focus restoration. Their overlays stay outside Elm's managed body children.
- Incremental frontend builds now track nested Elm view modules. Documentation and current-version references are consistent.

## Validation and upgrade notes

The audit passed 218 backend tests, including PostgreSQL recovery and attachment regressions, plus frontend/backend builds, browser security and UI tests, responsive settings, admin actions, and real WebRTC/RTP tests. The browser security suite now runs in GitHub CI.

Existing attachment references are preserved. The fix prevents new unauthorized sharing grants; historical grants need deployment-specific review. Optional live Redis, Scylla, Partisan, external TURN and native Fortran integration were not exercised during this audit.

See the [audit report](docs/SECURITY_AUDIT_2.6.3.md) for findings, regression evidence and testing limits. Published source archives contain authoritative inputs; run the documented build on the deployment host to generate frontend assets and the runtime release.
