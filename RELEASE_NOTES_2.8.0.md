# Plainwire 2.8.0

## DM encryption and individual locks

- Add a separate DM-wide encryption setting and individual message locks. Set up the shared key with DM-wide encryption off, lock selected outgoing text, or lock your existing text messages.
- Require both people to approve turning DM-wide encryption off. Keep existing history encrypted and retain the shared key/fingerprint. Either participant can turn encryption on again.
- Let only the sender explicitly remove a selected message's lock after DM encryption is off. Confirm the resulting disclosure to the relay. Ordinary edits cannot reveal encrypted text, and stale changes are rejected.
- Add persistent device locking, saved-key unlocking without retyping, and synchronization between tabs for the same account/browser profile. Clear memory caches across account changes and guard asynchronous crypto work against device/account changes.

## Encryption engine and private embeds

- Send v2 AES-256-GCM envelopes with a fresh authenticated message nonce and IV. Preserve identity during edits and reserve each nonce to a single stored message, including after unlock/relock and soft deletion. Existing 2.7.0 encrypted history remains readable.
- Require the current encryption policy revision on DM text posts/edits once a key is registered. Ignore stale policy events and pin observed revisions/fingerprints on devices.
- Render Markdown and local link cards under decrypted text, including actively encrypted DMs. Direct GIF/image/audio/video links and YouTube/Vimeo players load only when the reader chooses; private URLs do not go through the preview API or media proxy.
- Enable the GIF picker in encrypted chats. Explain that GIF searches contact the relay/provider; selected GIF URLs are encrypted when sent. Permit direct HTTPS media in the page CSP while keeping scripts and general networking restricted to the same origin.
- Keep encrypted text out of navigation previews and avoid automatic media/voice-note enhancement of private links. Add lock actions to message menus and keyboard-accessible message toolbars; preserve mobile touch targets and short-viewport composer layout.

Migration 56 adds encryption policy revisions, disable requests, and the nonce registry. It preserves active 2.7.0 encrypted DMs. Migration 57 widens the upload backfill cursor to accept 64-bit message IDs; the database pool also replaces dead connections after unexpected client failures without automatically replaying writes. Upgrade backend and frontend together; older clients must refresh before writing to DMs that have an encryption key.

This remains manually exchanged shared-key text encryption, with no forward secrecy or independent cryptographic audit. Uploaded files, calls, metadata, and remote media bytes are outside this mode. Device locking is not a password-protected vault. Read [setup and limitations](docs/END_TO_END_ENCRYPTION.md) and the [review record](docs/SECURITY_AUDIT_2.8.0.md).

## Validation

`make package` passed with 290 backend tests against PostgreSQL and the full browser, security, encrypted DM, responsive settings, reporting/admin, real WebRTC media, audio, and call-health suites. The seven-language SDK checks and Go race detector passed. The 250-user realtime smoke, live HTTP/WebSocket load-harness self-test, and pinned Gleam model checks passed. npm's advisory audit reported zero known vulnerabilities in the locked application dependencies. The extracted source archive passed source verification. The extracted runtime archive passed a real PostgreSQL/HTTP test covering startup, migrations, AES-GCM messages, stale revisions, disable consent, sender-only lock removal, preserved history, nonce reuse rejection, and healthy database connections after the backfill interval.

Source and Linux x86_64 OTP runtime archives include SHA-256 checksums. The runtime was built without the optional native call-health worker and Scylla native driver; those features require their documented native builds.
