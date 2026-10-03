# Encrypted private DMs

Plainwire 2.8.0 supports optional end-to-end encrypted text in accepted, two-person DMs between human accounts. You can encrypt all new text or lock individual text messages. HTTPS is required, except for localhost development.

## Set up the shared key

1. Choose **Enable encrypted text** above the composer to encrypt the DM, or **Lock this message** to set up individual locks with DM-wide encryption off.
2. Generate a key and save the full `pwkey1_…` secret in a password manager or another secure backup. This is a random 256-bit key, not a password you choose.
3. Exchange the key with your contact in person or through another trusted encrypted channel. Never send it in this chat, a report, a bot command, or a public channel.
4. Confirm that you saved the key and will verify its fingerprint, then complete setup.
5. Your contact opens **DM encryption: On/Off**, chooses **Unlock on this device**, imports the shared key, and compares the fingerprint with you through the trusted channel.

Each additional browser or device needs the original key. The browser stores a non-extractable Web Crypto key in IndexedDB under the signed-in account and DM. The raw key is not saved to localStorage, submitted to the relay, or included in debug logs. Signing out clears memory caches; that account's saved browser key remains. Clearing site data destroys it. A password reset cannot restore the key, and the saved non-extractable key cannot be exported: preserve the original backup.

## DM settings and individual locks

**DM encryption: On** encrypts every new text message and edit. The server rejects plaintext writes and forwarding into the DM while it is on. To turn it off, choose **Request turning off**. Your contact must choose **Approve turning off**. Either person can cancel with **Keep encryption on**. A pending request leaves encryption on. Once both people agree, either can turn it on again with the same key.

Turning DM-wide encryption off changes how **new** text is sent. Existing encrypted history stays encrypted. The shared key and fingerprint remain, and membership cannot expand beyond the original two people.

With DM encryption off, **Lock this message / Message lock: On** above the composer lets you encrypt selected outgoing text. The choice stays on until you toggle it off. You can also choose **Lock message** on one of your existing plain text messages. Locking cannot erase plaintext copies already held by other devices, backups, logs, or screenshots. File uploads and voice notes cannot be converted into encrypted text attachments.

Only the sender can choose **Remove lock** on a message. DM-wide encryption must first be off. A separate confirmation explains that removal publishes that message's text to the relay, making it available to search, previews, and moderation. Ordinary edits cannot remove a lock. Relocking generates a new encrypted message identity; earlier identities remain reserved to prevent reuse on another stored message.

**Lock this device** hides decrypted history and clears key/plaintext memory caches for this DM, including other tabs for this account in the same browser profile. The saved key remains. **Unlock saved key** restores access without retyping it. This is a convenience control, not a password-protected vault: a person with access to your signed-in browser can unlock the saved key. Unsent drafts, copied text, screenshots, and data outside encrypted history are outside this control. Use a private browser session on shared computers.

## Links, GIFs, and other previews

Unlocked encrypted text supports Markdown, clickable links, and embedded cards while DM-wide encryption is active. Private link cards are built locally from their URLs; decrypted links are never submitted to `/api/embed` or the server's media proxy. Cards show the destination rather than server-fetched Open Graph titles or descriptions.

Direct HTTPS image and GIF links, Markdown images, audio/video file links, and YouTube/Vimeo links can display media beneath the encrypted text. Choose **Load GIF**, **Load image**, **Load video**, **Load audio**, or the video play button to contact that host. Opening/decrypting a message does not automatically load remote thumbnails or media. The host can see your network address and which resource you view. Image requests omit the referrer; the page's same-origin referrer policy applies to remote media. YouTube requires the page origin for its player. Local/private address literals, credentials in media URLs, and non-HTTPS direct media are not embedded.

The GIF picker also works in encrypted chats. Searching deliberately sends the query to the relay and KLIPY and loads provider thumbnails; the picker explains this. The selected GIF URL is encrypted as part of the text when sent. The GIF bytes themselves remain public/provider-hosted media. Page links to other media sites receive local destination cards; they do not use a private-URL unfurling service. Chat's link-preview preference applies here too. Locked or unauthenticated messages do not render links or embeds.

## Other features

| Content or feature | Behavior |
| --- | --- |
| New encrypted text and edits | Browser encrypts before HTTP delivery; recipient browser decrypts locally. Old or stale clients cannot silently downgrade writes. |
| Key identity | The relay stores an immutable SHA-256 fingerprint. Importing browsers pin the fingerprint and observed policy revision. The raw key never reaches the relay. |
| Replies and message identity | Conversation, posting account, nonce, and reply context are authenticated. Missing keys or altered ciphertext display unavailable text. |
| Search | Ciphertext has no server search tokens. Global search queries still go to the relay; do not enter private text there. Explicitly removing a lock allows the revealed text to be indexed. |
| Forwarding | Encrypted text cannot be forwarded by the server. Copying or publishing text elsewhere deliberately discloses it. |
| Uploads and voice notes | Disabled while composing encrypted text. Existing files retain their original access rules and are outside this mode. GIF/image links are text; their remote media is outside encryption. |
| Calls and metadata | Existing WebRTC transport security remains. This mode does not encrypt signaling, participant IDs, timestamps, read receipts, typing, reactions, or message sizes. |
| Servers, group DMs, bots, forums | Existing features and authorization remain. Group DMs and bot DMs cannot enable this mode. |
| Reports | A server message copy remains ciphertext. Reasons or screenshots deliberately submitted by a reporter may reveal private content to moderators. Never include the DM key. |

## Cryptography and limits

The browser uses the [Web Crypto AES-GCM API](https://www.w3.org/TR/webcrypto/#aes-gcm) with a random 32-byte key, a fresh random 12-byte IV per send/edit, and a 128-bit authentication tag. New messages use a separate random 16-byte nonce. Associated data is UTF-8 `plainwire-dm-v2\n<conversation-id>\n<sender-id>\n<key-fingerprint>\n<nonce>`. The payload is byte `2`, an unsigned 64-bit big-endian reply ID (`0` for none), and UTF-8 text, limited to 5,000 bytes. The envelope is `pw-e2ee-v2:<64-lowercase-hex-fingerprint>:<base64url-nonce>:<base64url-IV>:<base64url-ciphertext-and-tag>`, with canonical, unpadded base64url. The fingerprint is SHA-256 over UTF-8 `plainwire-dm-key-v1\0` followed by the raw key.

The original 2.7.0 `pw-e2ee-v1` history remains readable using its original associated data and payload format. New sends and edits require v2. An edit of a v2 message retains its nonce while using a fresh IV. The relay atomically reserves each v2 nonce to one message row, preventing ordinary API reuse on another row, including after an explicit unlock or soft deletion. The relay cannot validate the authentication tag because it has no key. [Authenticated encryption](https://www.rfc-editor.org/rfc/rfc5116) protects the encoded context; server storage rules supply the API replay checks.

This manually exchanged shared-key mode has no automatic identity-key exchange, multi-device key sync, key rotation, double ratchet, forward secrecy, or post-compromise security. Existing v1 messages lack the new nonce binding. The nonce registry does not prevent a malicious relay from replaying old versions or manipulating delivery. Anyone with the shared key can read history and generate valid ciphertext. The authenticated relay account controls posting identity; the shared key does not cryptographically distinguish the two people.

Protect both endpoint devices and the key backup. A compromised browser, same-origin script, account session, or maliciously modified web client can read displayed text or use the key. The server must still be trusted to deliver reviewed client code. Non-extractable keys reduce accidental export; they do not protect against malicious same-origin code. This mode has regression tests but no independent cryptographic audit, and does not guarantee that every feature or deployment is private or vulnerability-free.
