# Plainwire 2.9.1

This release fixes first-send failures, message and navigation races, and blocked-user privacy gaps, and refines the conversation layout.

* A rejected stale CSRF token refreshes automatically and retries once after confirming the same signed-in account. Switching accounts never replays the previous account's draft. Message, account, encryption, workspace and upload requests share this recovery boundary; network errors and other failed writes are not automatically replayed.
* User message posts carry a sender-scoped client nonce. Concurrent retries return the existing message without duplicate storage, notifications, webhooks or AI dispatch. Reusing a nonce with different content, scope or reply fails; deleted messages cannot be resurrected. Encrypted retries preserve their ciphertext and authenticated identity.
* Older identical history no longer absorbs a newly pending message. Returning to a chat after visiting another route rejects responses from the earlier visit.
* Blocking a person revokes live access to shared DMs and calls. Group message and missed-call notifications exclude members whose history access is blocked. A blocked person cannot take ownership of the other person's block and remove it. Realtime subscription revocations apply before the hub processes room cleanup, and queued authorizations cannot reinstall revoked subscriptions.
* Scylla history hydration preserves current PostgreSQL metadata, including pins and message identities, instead of failing on an outdated row shape.
* Empty optional search and media signing keys use their documented defaults. Example configurations no longer fail startup, while malformed nonempty keys still fail validation.
* Unencrypted group DMs work when browser key storage is unavailable. Encryption storage opens have a bounded wait and close late connections; private-DM fingerprint checks continue to fail closed. Complete server responses determine encryption policy; intermediate DOM attribute updates cannot change it.
* UTF-8 byte counts match server message limits, including emoji and non-Latin text. Oversized sends and edits are caught before submission. DM formatting previews and pending messages render private links locally.
* Chat headers, author controls, reading spacing, reply rows and composer alignment are clearer. Empty composers stay compact, mobile tools remain reachable, formatting panels fit the viewport, and author profiles are keyboard accessible. Request errors use clearer recovery guidance.

Migration **60** adds the nullable message nonce and its sender-scoped unique index. Existing messages and older clients remain compatible. Apply the migration through normal startup and back up PostgreSQL before upgrading.

Validation covers PostgreSQL-backed concurrency, nonce binding, block ownership and notification authorization; first-send, route, account, encryption and responsive browser regressions; and the complete release checks. See the [security review](docs/SECURITY_AUDIT_2.9.1.md).

Opt-in end-to-end encryption continues to cover text in accepted two-person human DMs. Groups, calls, uploads and metadata remain outside that mode; read the [threat model](docs/END_TO_END_ENCRYPTION.md). This review does not establish that every vulnerability is absent.
