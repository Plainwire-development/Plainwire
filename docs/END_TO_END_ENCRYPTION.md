# Encrypted private DM text

Plainwire 2.7.0 offers optional end-to-end encryption for new text in an accepted, two-person DM between human accounts. Enable it from **Enable encrypted text** above the composer. HTTPS is required, except for localhost development.

## Set up both devices

1. Open an accepted private DM and choose **Enable encrypted text**.
2. Generate a new key. Save the full `pwkey1_…` secret in a password manager or another secure backup. It is a random 256-bit key, not a password you choose.
3. Exchange it with your contact in person or through a separate trusted encrypted channel. Never send the key in a Plainwire message, report, bot command, or public channel.
4. Confirm the backup and fingerprint verification notice, then enable the mode. Activation is permanent for that DM.
5. Your contact opens **Encrypted text · unlock / verify key**, enters the shared key, and compares the fingerprint with you through the trusted channel.

Each additional browser/device must import the same saved key. A browser stores a non-extractable Web Crypto key in IndexedDB under the signed-in account and DM. The raw key is not saved to localStorage, sent to the server, or included in debug logging. Signing out clears the in-memory key and plaintext caches; the saved key remains available when that same account signs in on that browser. Use a private browser session on shared computers. Clearing site data destroys saved device keys. Password resets cannot restore them, and the key cannot be exported again from this device's non-extractable key storage: preserve the original secret backup.

## What the mode covers

| Content or feature | Behavior |
| --- | --- |
| New DM text and edits | Browser encrypts before HTTP/WS delivery; recipient browser decrypts locally. Older clients' plaintext posts/edits are rejected. |
| Key identity | A SHA-256 fingerprint is locked on the server and pinned on each importing browser. The server receives only that fingerprint. |
| Replies | Conversation, sender, and reply context are authenticated. Missing keys or altered ciphertext display an unavailable message. |
| Links and Markdown | Displayed as literal text; no embeds, remote images, or link preview requests from encrypted text. |
| Search | Ciphertext has no blind-index tokens. Server search cannot search the encrypted text. Global search queries are still sent to the server; do not enter private text there. |
| Forwarding | Encrypted messages cannot be forwarded by the server, and plaintext cannot be forwarded into an encrypted DM. Deliberately copying text elsewhere discloses it to that destination. |
| Attachments, GIFs, voice notes | Composer disables these in this mode. Existing files and earlier messages retain their original behavior and access rules. |
| Calls and metadata | Existing WebRTC calls keep their existing transport security. This text mode does not cover call signaling, participant IDs, timestamps, read receipts, typing, reactions, or message sizes. |
| Servers, group DMs, bots, forums | Existing features remain available with their existing authorization and at-rest protections. Group DMs and bot DMs cannot activate this mode. |
| Membership and rollback | Cannot add members, replace the key fingerprint, or return the DM to plaintext. Create a new DM for a fresh key. |
| Reports | Reports remain available. The server cannot decrypt a message copy. A reason or screenshot that you deliberately submit can disclose private content to moderators. Never include the DM key. |

Earlier plaintext messages are not retroactively encrypted. Editing earlier text after activation encrypts the updated content, but cannot erase old copies, backups, or screenshots.

## Cryptography and limits

The browser uses the [Web Crypto AES-GCM API](https://www.w3.org/TR/webcrypto/#aes-gcm) with a random 32-byte key, a fresh random 12-byte IV for every send/edit, and a 128-bit authentication tag. Associated data is the UTF-8 string `plainwire-dm-v1\n<conversation-id>\n<sender-id>\n<key-fingerprint>`. The payload is byte `1`, an unsigned 64-bit big-endian reply ID (`0` for none), followed by the UTF-8 text. Text is limited to 5,000 UTF-8 bytes. The envelope is `pw-e2ee-v1:<64-lowercase-hex-fingerprint>:<base64url-IV>:<base64url-ciphertext-and-tag>`, without base64 padding. Its fingerprint is SHA-256 over UTF-8 `plainwire-dm-key-v1\0` followed by the raw key.

This is an initial, manually exchanged shared-key mode. It has no automatic identity-key exchange, multi-device key sync, key rotation, double ratchet, forward secrecy, post-compromise security, or protection against replay of an entire valid message within the same sender/conversation/reply context. Anyone with the shared key can read its history and create valid ciphertext. The authenticated relay account controls posting identity; the shared key does not cryptographically distinguish the two people.

Protect both endpoint devices and the key backup. A compromised browser, same-origin script, account session, or maliciously modified web client can read displayed text or use the key. A server that serves the web client must still be trusted to deliver the reviewed code. Non-extractable keys reduce accidental raw-key export; they do not protect against malicious code running on the same origin. This mode has regression tests, but has not received an independent cryptographic audit. It does not make a blanket guarantee that every feature or deployment is private or vulnerability-free.
