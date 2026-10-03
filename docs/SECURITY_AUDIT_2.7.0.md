# Plainwire 2.7.0 review

The review focused on durable content encryption, direct-message write boundaries, browser message handling, WebRTC signaling, mobile composition, and first-party command workers. Existing authorization, account recovery, upload access, report privacy, plugin isolation, and realtime tests remain part of the release checks.

| Finding | Change |
| --- | --- |
| Bad runtime content-encryption key could silently store plaintext | Reject new writes with invalid configured keys and missing production keys. Malformed encrypted values fail closed. |
| Generated release VM arguments could expose native distribution with a default cookie | Ship VM arguments with distribution and EPMD disabled, and reject unsafe named runtimes in production. Use the OS service manager for lifecycle control. |
| Embedded release boot eagerly loaded a missing optional Scylla native driver | Use a release startup hook to load modules on demand; a PostgreSQL deployment can start without the optional driver. |
| At-rest encryption did not provide end-to-end privacy | Add explicitly enabled encrypted private DM text, with authenticated browser decryption and permanent server-side mode/membership enforcement. |
| Message truncation could corrupt long multibyte text or encrypted envelopes | Validate complete message bytes and reject over-limit bodies before mutation. |
| Async signaling could finish after a call room or peer was replaced | Capture room epoch at enqueue time, recheck after asynchronous negotiation, and hold candidates until the matching offer/answer is sent. |
| Duplicate-offer fallback could reuse an answer for different SDP | Resend an answer only for the same remote description. |
| Failed relay configuration fetch could use public STUN before the privacy policy was known | Start and expire to relay-only with no ICE servers; apply direct connectivity only from a successfully fetched server policy. |
| JavaScript response timeout ended before body consumption and body limit applied after buffering | Keep timeout through streaming reads; cancel oversized bodies and retain caller cancellation. |
| Inherited JavaScript command handler properties could be dispatched | Look up only own handler properties or explicit Map entries. |
| Worker claims could expire in a local backlog or during long handlers | Claim only available concurrency and renew active leases in JS, Python, and Go. |
| Exception strings could disclose bot secrets to users | Send generic worker failures; keep detailed errors in the local error hook. |
| Python HTTP responses were not closed on success/oversize/error | Always close the response in a finally block. |
| Narrow mobile composer actions and crowded reading layout | Give actions 44px touch targets, use 16px typing text, increase message spacing, and test narrow/short viewports. |

Encrypted previews are generic, encrypted text is excluded from the server search index, and message bodies and signaling payloads are omitted from browser debug logs. Browser decryption and key loading are cached with bounded plaintext/message caches, reducing repeated work during realtime updates. Encrypted notification generation skips mention-roster parsing that cannot reveal mentions.

The encrypted mode's scope and threat model are documented in [Encrypted private DMs](END_TO_END_ENCRYPTION.md). It is text-only, requires manual secure key exchange, has no forward secrecy, and has not received an independent cryptographic audit. Regression checks do not prove that all possible vulnerabilities have been removed.

The bot interaction API and bounded retry behavior were informed by [Discord's rate-limit documentation](https://github.com/discord/discord-api-docs/blob/main/developers/topics/rate-limits.mdx). Layout work also reviewed the [Stoat web client](https://github.com/stoatchat/for-web). These are design references; Plainwire does not implement Discord protocol compatibility.
