# Plainwire 1.8.0 build status

Plainwire 1.8.0 adds an optional service-host control plane on top of the stabilized 1.7.5-2 codebase. The control plane is for operators of the configured Plainwire deployment itself, not moderators inside an individual Plainwire server.

## Implemented control-plane behavior

- Separate Cowboy/Ranch listener; the ordinary Plainwire HTTP listener does not mount admin routes.
- Disabled by default and loopback-bound by default.
- Production remote binding requires explicit opt-in, an HTTPS admin public URL, and secure admin cookies.
- Host-local emergency recovery is rejected on any non-loopback admin bind.
- Responsive control-plane UI follows Plainwire's existing neutral charcoal visual language and works on desktop/mobile.
- Viewer/operator/owner RBAC is enforced in the API: viewers get aggregate host/overview health, operators get content-free account/server/operator/audit inspection, and owners additionally manage control-plane credentials/roles.
- Service-wide views for overview, all registered users (active or inactive), hosted servers, runtime/host health, operator access, and operator audit history.
- Host telemetry includes release/instance identity, OS/architecture/OTP, uptime, memory, schedulers/run queue, processes, ports, atoms, ETS table count, database pool health, realtime/voice/call counts, cluster/rate-limiter state, media cache/fetch pressure, upload pressure, TURN/native-call-health availability, and an allowlisted non-secret deployment configuration.

## Verification/access model

- No reusable administrator credential is present in source code.
- Each deployment creates a local 256-bit instance secret; operator keys are HMAC-bound to that secret.
- The public instance ID is derived from the secret hash and is not itself authentication material.
- First-owner bootstrap uses a runtime-generated one-time token plus a real Plainwire account password.
- Each operator receives a separate high-entropy verification key; plaintext keys are shown only at issuance/rotation.
- Owner-issued enrollment/recovery codes are account-bound, expiring, and redeemed under a PostgreSQL row lock.
- Admin sessions are separate from normal Plainwire sessions, use HttpOnly + SameSite=Strict cookies, expire independently, and require a separate CSRF token for mutations.
- Authentication endpoints have independent rate limits.
- Operator role changes/removal preserve a last-owner invariant and revoke affected admin sessions.
- Verification-key rotation revokes all current admin sessions for that operator.
- Emergency local recovery authenticates a real Plainwire account/password, emits a fresh instance-bound owner key, revokes all admin sessions, invalidates unused enrollment codes, and consumes its in-memory recovery token once.
- One-time secret dialogs cannot be dismissed until the operator explicitly acknowledges saving the value.

## Privacy boundary

The admin DB/API surface deliberately does not select or expose message bodies, DM text, attachment contents, message search, profile bio/banner/avatar contents, plaintext verification keys, database credentials, encryption keys, TURN secrets, or third-party API tokens.

The service console does expose operational metadata needed to run the host: account identity/timestamps/resource counts, server identity/ownership/member/channel counts, aggregate message/upload/reaction/session statistics, and content-free operator audit events.

IP addresses and user-agent strings used for control-plane session/audit correlation are stored only as instance-HMACed values, not raw strings.

## Realtime/QOL additions in Plainwire 1.8.0

- Reaction additions notify the message author through the existing persisted activity system and realtime/browser-notification path; self-reactions/removals are silent, recipient access is rechecked, and repeat notification abuse is rate-bounded.
- WebSocket heartbeat detects half-open paths and forces the established reconnect/reconciliation flow. Reconnect, browser-online, page-show, and foreground transitions all refresh state without requiring a full page reload.
- A three-minute visible-tab reconciliation safety net refreshes the global sync plus only the active route, covering rare missed realtime events without converting the client into an aggressive polling frontend.
- Active RTC rooms now receive a periodic remote-audio audit. Playback-element suspension is repaired before any transport work; missing or persistently stalled receivers use the existing roster/epoch-guarded peer rebuild budget. Mute/deafen remain non-destructive local media state.
- Mobile onboarding selects actually visible mobile controls, repositions the guide around bottom navigation/safe areas, and constrains long content so it remains usable on small viewports.
- DM navigation previews stay bounded/plain-text and collapse attachment floods instead of rendering rich media in the sidebar.

## Verified in this environment

- `bash scripts/verify-source.sh`
  - JavaScript syntax, including `priv/admin/admin.js`
  - all shell syntax
  - release/version/source-manifest consistency
  - contiguous database migration IDs
  - authored-source unfinished-marker scan, including admin UI source
  - RTC, UI, admin-control-plane, and release source contracts
- Admin-specific contract checks cover listener isolation, runtime-generated instance secrets, cross-instance key binding, bootstrap/recovery behavior, loopback-only emergency recovery, atomic one-time code redemption, last-owner safety, session revocation, privacy-blind SQL/API surfaces, CSRF/rate limits, safe host telemetry, and DOM-safe rendering.
- Manual/source-assisted Erlang structural audit: balanced delimiters across all new/touched admin modules and presence of every exported function head.
- `node --check priv/admin/admin.js`
- `git diff --check`
- strict native media-quality build and execution (`-Wall -Wextra -Werror`, Fortran bounds checking)
- native quality suite: 200 randomized windows, every truncated protocol boundary, and 1,000 sequential analyses
- call-health state/counter suite
- the source archive was extracted into a clean directory and the source verifier, JavaScript/shell syntax checks, native build/quality suite, and call-health suite all passed from that extracted copy
- final TAR and ZIP are built from the same authoritative source set; generated frontend bundles, build directories, runtime data, uploaded files, local instance secrets, host binaries, and dependency directories are excluded

The final source archive contains 189 authoritative files. The ZIP contains the same 189 files and is checked byte-for-byte against the TAR payload before release.

## Environment-blocked validation

This sandbox does not provide `erl`, `erlc`, `rebar3`, `elm`, `elm-format`, PostgreSQL tooling/server, Sass/Less CLIs, or installed Playwright dependencies. Therefore the following gates cannot honestly be represented as executed here:

- Erlang compilation and EUnit (`rebar3 eunit`)
- Elm compilation
- live PostgreSQL migration/auth/recovery integration execution
- dependency-backed Sass/Less frontend compilation
- Playwright browser/WebRTC end-to-end suites

Source contracts and structural audits are intentionally additional safeguards, not claims that they replace those compilers/runtimes.

## Deployment note

For remote service operators, use a dedicated HTTPS admin hostname behind a reverse proxy and keep the admin listener private to that proxy/loopback whenever possible. Back up the admin instance-secret file together with PostgreSQL. Source-code possession alone grants no access to an existing deployment; host-secret/configuration access is privileged by definition.
