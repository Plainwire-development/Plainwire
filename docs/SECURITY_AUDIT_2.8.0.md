# Plainwire 2.8.0 review

This release reviews encryption policy changes, individual lock transitions, stale clients, message replay through the API, device key state, and private media rendering. The existing backend authorization, browser security, mobile, account recovery, upload, reporting, call, and SDK checks remain required for release.

| Finding or requested behavior | Change |
| --- | --- |
| Encryption activation was permanent, with no individual message locks | Separate immutable key identity from the DM-wide policy; support individual locks and two-person consent to disable the policy. |
| Turning encryption off could disclose history or let an ordinary edit remove a lock | Keep stored history encrypted; require an owner-only explicit unlock action, exact prior ciphertext, and current policy revision. |
| A stale client/tab could compose under a different policy | Serialize policy changes and writes using the conversation row; require current revisions on keyed DM posts/edits; pin and ignore stale policy metadata in browsers. |
| Valid ciphertext could be posted on another row within the same account/DM context | Authenticate a random v2 message nonce and reserve it transactionally to one row. Preserve old bindings after unlock/relock and soft deletion. |
| A key/decryption operation could finish after account or device state changed | Check session generations and device epochs around storage and cryptographic operations; clear caches and synchronize device locks between tabs. |
| Unlocking stored keys required retyping the original secret | Add explicit saved-key unlocking and persistent device locking without exporting stored keys. |
| Encrypted links were literal text and GIF selection was disabled | Render sanitized Markdown and local URL cards after successful decryption; add deliberate direct media loading and encrypted GIF text from the picker. |
| Ordinary URL unfurling would disclose decrypted links to the relay | Private rendering never calls the unfurl/media-proxy services and avoids automatic thumbnails, first-party Markdown images, mentions, and voice-note upgrades. |
| The CSP would prevent direct private media from working | Allow HTTPS image/media destinations; retain same-origin scripts/connect policy and restricted player-frame origins. Raw HTML stays disabled. |
| The send acknowledgement could populate sidebar previews with decrypted text | Keep client navigation previews generic for encrypted messages. |
| An unfinished upload backfill overflowed its 32-bit cursor and crashed a database client; unexpected client deaths left pool lanes using dead connections | Widen the cursor in migration 57 and reconnect whenever the client process is dead. Retry eligible reads only; do not replay failed writes. |

The v2 nonce registry prevents reuse through the honest relay API; it is not a peer identity signature, a ratchet, or protection against a malicious relay's delivery behavior. Existing v1 history has no v2 nonce reservation. Either person holding the shared key can generate valid ciphertext. A compromised endpoint or modified same-origin client can read text/use keys. Device locking protects the history display, not unsent drafts or a browser profile from its signed-in user. Private media loads contact third parties after reader action, and deliberate GIF searches remain visible to the relay/provider.

See [encrypted private DMs](END_TO_END_ENCRYPTION.md) for the complete format, workflow, and threat model. Regression checks do not prove the absence of every vulnerability, and this release has no independent cryptographic audit.
