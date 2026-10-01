# Plainwire 2.6.3 audit and fixes

Review date: 2026-09-30. This review covers the local source tree and fixes confirmed security, correctness, accessibility and build problems. Severity describes the observed impact; it is not a CVSS assessment or a claim that the application has no other vulnerabilities.

## Scope

Reviewed HTTP authentication and JSON parsing, password and recovery-token lifecycle, attachment authorization and reference creation, plugin execution and its parent bridge, delayed Elm API responses, composer drafts, bridge dialogs, frontend build dependencies and documentation consistency. Existing source contracts, backend tests and Chromium UI/RTC suites provided broader regression coverage. Validation used isolated local fixtures; production configuration and data were not changed.

## Findings fixed

| Finding | Impact | Change |
| --- | --- | --- |
| Upload IDs could create unauthorized sharing grants | High: an author who knew an unreadable upload ID could post it and create a readable reference | Posts, edits, forwards, threads and replies validate upload readiness and current read access before writing content or references. |
| Editing and forwarding bypassed attachment permissions | Medium: channel attachment and voice-note restrictions applied only to new posts | Edits and forwards now enforce the same permissions and error codes. |
| Plugin network guard relied on writable globals, and evaluation was blocked by page CSP | Medium; network escape risk when plugin evaluation was allowed | Plugins use a same-origin worker asset with its own enforced CSP: no connections, imported scripts or nested workers. Evaluation is allowed only in that worker. The parent checks normalized API paths and write grants. |
| Public JSON authentication accepted HTML form media types | Medium: cross-site form requests could trigger login with supplied credentials | Both normal and host-admin JSON handlers require `application/json`, including charset parameters. Other media types receive 415. |
| Final JSON body chunk bypassed the size limit | Medium: a complete body larger than the requested chunk size could be decoded | Enforce the remaining byte budget on every chunk, including Cowboy's final `ok` response. |
| Failed password reset could burn its token or partially update the account | Medium: weak passwords consumed the link, and later database errors left partial state | Validate the password first; token claim, password update and session deletion commit together. Failed writes roll back and leave the link usable. |
| Password/email changes left recovery credentials or admin sessions valid | High: a previous recovery link or authenticated admin session could survive a credential change | Reset and password change revoke admin sessions and other reset links. Email changes revoke old reset links. Reset locks the account and rechecks its verified address, active state and human-account eligibility. |
| Email verification/change/removal updated tokens separately from account state | Medium: a failure could consume a verification link or leave inconsistent recovery state | Use transactions and invalidate identity caches after successful commit. Removing an email revokes all account links. |
| Profile API responses overwrote the bridge's signed-in user ID | Medium: another person's profile could change local moderation, typing and RTC identity decisions | Only successful authentication responses update the bridge identity. A browser regression checks typing from the viewed person still appears. |
| Saved plugins started only during periodic reconciliation and restarted repeatedly | Medium: delayed startup, lost worker state and repeated startup actions | Start once after authentication, keep workers through reconciliation, and stop on logout. Theme compiler failures do not block plugins. |
| Delayed API responses replaced newer views | Medium: wrong server, thread, profile, forum list or command suggestions could appear | Apply route-specific responses only to the matching active route; cache server data separately. Closed member-profile dialogs stay closed. |
| Bot-command acknowledgements cleared newer drafts | Medium: a late response erased newly typed text or another channel's draft | Correlate acknowledgements with the submitted route and exact draft; clear only unchanged submitted text. Reject duplicate in-flight submissions of the same draft. |
| Bridge dialogs lacked names, focus trapping and reliable mount ownership | Medium: keyboard focus escaped dialogs and Elm could disturb bridge overlays | Label dialogs, trap keyboard focus, restore trigger focus, track nested dialogs, and mount overlays beside the Elm-owned body. |
| Incremental frontend builds missed nested Elm views; documentation had stale references | Low: view changes could leave stale UI output, and build guidance linked a missing report | Add `View/*.elm` dependencies, update the documentation version and link this audit. |

The attachment fix prevents new unauthorized grants. It does not erase historical references: existing legitimate forwards and older unauthorized grants cannot be reliably distinguished from reference rows alone. No production history was rewritten.

## Regression evidence

- Full frontend build: rich text, HAML, CSS and Elm compilation passed.
- `scripts/verify-source.sh`: all source/manifest checks and contract suites passed.
- Full EUnit with local PostgreSQL enabled: **218 tests, 0 failures**. This includes 33 audit regressions: 6 JSON-body tests, 7 real HTTP/CSP tests, 13 PostgreSQL account-recovery tests and 7 PostgreSQL attachment tests.
- Recovery regressions force database constraint failures after writes, verify rollback and cache preservation, exercise one-time token use, and check credential revocation and stale recovery addresses.
- Attachment regressions cover private, pending, missing and stale references, legitimate public sharing, and an actual thread edit that attempts to attach another user's private upload. The rejected edit leaves content and references unchanged.
- `npm run test:security-audit`: installed plugin reads and namespaced storage work; ungranted writes and encoded traversal fail; restored native fetch/importScripts and nested workers cannot make requests. Delayed server/thread/profile responses, signed-in identity, draft isolation and modal focus checks passed in Chromium.
- Existing browser UI suite passed, including markup rejection, desktop/mobile layouts, concurrent sends, draft preservation and sign-in.
- Settings responsiveness passed at seven viewport widths; admin moderation/action tests passed.
- Real browser WebRTC suite passed bidirectional RTP, reconnect, microphones, screen sharing, sound previews, mobile controls and cleanup. Call-health parser tests passed.
- `npm ci` completed and reported **0 npm vulnerabilities**. Erlang dependencies compiled. The optional Scylla native driver was unavailable; PostgreSQL operation and the backend suite succeeded without it.

Tests are wired into the existing Make/npm checks. PostgreSQL fixture configuration and reproducible commands are documented in [BUILDING.md](BUILDING.md). Cowboy's body `length` is best effort, which is why application byte counting remains necessary: [official read_body documentation](https://ninenines.eu/docs/en/cowboy/2.12/manual/cowboy_req.read_body/).

## Practical limits

Browser API/signaling fixtures and connection-local PostgreSQL TEMP tables do not certify a live deployment. This pass did not run production-schema migrations, construct or deploy an OTP release, test the optional native Fortran worker, or exercise live Redis, Scylla, Partisan or external TURN infrastructure. Production permissions, reverse-proxy header behavior and existing historical attachment grants still require deployment-specific review. The npm advisory result does not cover every Erlang/native dependency or the operating system.
