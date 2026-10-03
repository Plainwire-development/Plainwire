# Plainwire 2.7.0

## Encrypted private text

- Add explicitly enabled end-to-end encrypted text for accepted two-person human DMs. Keys are generated/imported on the browser and exchanged through a trusted external channel. The relay receives ciphertext and a fingerprint, never the raw key.
- Lock encrypted DMs against plaintext posts/edits/forwards, key replacement, and added members. Missing keys and authentication failures show unavailable text. Links remain literal text, encrypted messages cannot be forwarded, and uploads/GIFs/voice notes are disabled for this mode.
- Add migration 55 for the locked DM fingerprint. Existing conversations, server channels, bots, group DMs, forums, and calls retain their features.
- Read [setup and limitations](docs/END_TO_END_ENCRYPTION.md) before enabling: this mode covers new text only, uses manual shared-key exchange, and has no forward secrecy or independent cryptographic audit. Earlier messages, files, calls, and metadata are outside it.

## Security and correctness

- Fail new at-rest writes when a configured encryption key is invalid or a production key is missing. Malformed encrypted content is never passed through as plaintext.
- Disable native Erlang distribution and EPMD in shipped VM arguments and reject unsafe named production runtimes. Manage release lifecycle through systemd/OpenRC; remote Erlang RPC commands are disabled.
- Include the required load-tool sources in portable source archives and exclude generated build trees. Pin Rust SDK and Gleam load-model dependency resolutions.
- Load optional native drivers on demand so a PostgreSQL release starts even when the Scylla driver was not built.
- Validate full UTF-8 message sizes and preserve encrypted envelope integrity. Keep ciphertext out of navigation previews/search tokens and private content out of browser API/signaling debug logs.
- Guard call signaling across room/peer replacement, queue local candidates until matching descriptions are sent, and resend duplicate answers only for matching SDP.
- When relay configuration is unavailable or expired, fail closed instead of contacting a public STUN service or exposing direct candidates before the server's privacy policy is known.

## Mobile and bot SDKs

- Increase mobile message spacing, make composer actions 44px touch targets, and keep typing at 16px to avoid automatic zoom. Improve the encrypted key dialog on narrow screens.
- Add Discord-style JavaScript command interactions with typed options, explicit defer/reply/fail, and one final reply. Keep existing returned-string handlers compatible.
- Bound response streaming and request timeouts, respect `Retry-After` for explicit JavaScript rate-limit rejections, refuse normalized API-path escapes and inherited handlers, cap claimed work to concurrency, and renew active JS/Python/Go leases.
- Keep worker exception details in local error hooks and close Python responses reliably. Server bot rate-limit responses now include `Retry-After`.

See the [review record](docs/SECURITY_AUDIT_2.7.0.md) and SDK READMEs for details.

## Validation

`make package` passed with 285 backend tests against PostgreSQL and the full browser, security, encrypted DM, responsive settings, reporting/admin, real WebRTC media, audio, and call-health suites. The seven-language SDK checks and Go race detector passed. The 250-user realtime smoke, live HTTP/WebSocket load-harness self-test, and CI-pinned Gleam model checks passed. npm's current advisory audit reported zero known vulnerabilities in the locked application dependencies. The extracted source archive passed source verification. The final packaged server passed a real PostgreSQL/HTTP startup and encrypted-DM enforcement smoke test. Source and Linux x86_64 OTP runtime archives include SHA-256 checksums; the runtime was built without the optional native call-health worker and Scylla native driver.
