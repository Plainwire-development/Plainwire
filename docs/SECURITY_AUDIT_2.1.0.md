# Plainwire 2.1.0 security review

Review date: 2026-09-18

This report records the source-first security review performed on the 2.1.0 handoff candidate. It does not claim that software is vulnerability-free. Runtime/toolchain gates that could not be executed in the supplied environment are listed explicitly.

## Trust boundaries reviewed

- unauthenticated and authenticated HTTP API routing, CSRF and rate-limit boundaries;
- user/server/role/channel authorization for bot and Developer Application operations;
- durable bot-command queue and claim/lease transitions;
- public Developer Application directory versus owner-private connector state;
- signed application interactions and hosted AI outbound HTTP;
- token/API-key/signing-secret storage and logging;
- outbound SSRF/DNS-rebinding/redirect boundaries;
- Developer Portal DOM writes;
- webhook/bot identity lifecycle and deletion behavior;
- release/source packaging and obvious credential leakage;
- dependency pins against selected current published advisories.

## Confirmed findings fixed during this pass

### Claim-time permission revocation race

Queued command arguments could pass invocation-time authorization, then still be delivered after the invoking user's channel access or per-command permission was revoked. The SDK claim path rechecked bot access but did not recheck the invoking user and command rule; internal webhook/AI claims had the same disclosure window.

All claim paths now call one `command_claim_authorization/6` gate before decrypting command arguments. The gate rechecks bot channel access, invoking-user channel access, and the current member/channel/role command rule. Unauthorized jobs are terminal-failed without disclosing decrypted arguments.

### Developer-app plaintext egress policy coupling

Developer interaction and AI requests inherited the legacy `PLAINWIRE_WEBHOOK_ALLOW_HTTP` switch. Enabling plaintext HTTP for legacy webhooks could therefore also permit remote plaintext application/AI traffic, including AI bearer tokens.

Developer app egress now uses a separate policy. Remote destinations require HTTPS. Plain HTTP is available only when `PLAINWIRE_APP_ALLOW_LOOPBACK_HTTP=true` and the host is exactly `localhost`, `127.0.0.1`, or `::1`. The app HTTP client connects to the already-reviewed resolved address and does not follow redirects.

### Unbounded app request body configuration

The application HTTP client already streamed and capped responses, but did not have an independent request-body ceiling. It now enforces `PLAINWIRE_APP_REQUEST_MAX_BYTES` (default 64 KiB, hard-clamped to 1 MiB). The response limit remains independently bounded and oversized streams are cancelled.

### Internal application queue scan growth

The existing command claim index was bot-prefixed, while internal webhook/AI workers claim globally across installed bots. As completed history grew, the worker could scan increasingly irrelevant rows. Migration 48 adds a partial active-invocation index containing only `pending`/`claimed` rows.

## Controls verified in source/contracts

- Developer management is owner-scoped; public directory queries require `public=true` and strip connector/owner-private metadata.
- Server app installation requires **Manage bots** and non-owner installers cannot grant permissions they do not hold; the administrator permission is stripped from delegated grants.
- Bot/install tokens are stored as hashes; AI keys, AI system prompts, durable command arguments, and new interaction signing secrets are encrypted at rest.
- DB operation failure logging fails closed to a redacted operation name for unreviewed tuples.
- Hosted AI execution builds context from the invoked command and submitted arguments only; it does not fetch channel history.
- AI and interaction workers have bounded concurrency, timeouts, retries, request sizes, and response sizes.
- Outbound application HTTP resolves once, rejects non-public remote destinations, connects to the reviewed address, verifies TLS for DNS hosts, and does not follow redirects.
- Developer Portal code uses DOM nodes/text content rather than HTML-string injection for app/operator-controlled values.
- Uninstall/delete paths remove installation/command state and disable detached bot identities while preserving historical authorship.
- Source archive generation rejects symlinks, local secrets, build output, runtime data, private-key file types, and generated bundles that could be stale.

## Dependency review

The lock/configuration currently pins `markdown-it 15.0.2`, `esbuild 0.28.2`, `playwright 1.62.1`, Cowboy 2.19.0, Cowlib 2.20.0, and Gun 2.6.0. Selected current advisories reviewed during this pass show the relevant fixes below those pinned versions (including markdown-it >=14.2.0, esbuild >=0.28.1, Playwright >=1.56.0 for the reviewed installer issue, and Cowboy >=2.15.0 for the reviewed multipart parsing DoS). The npm audit endpoint was unreachable in this runner, so this is not a complete registry advisory scan.

## Validation executed

- `./scripts/verify-source.sh`: PASS after fixes.
- Developer Application security/contract test: PASS.
- JavaScript SDK policy tests: PASS (7).
- Python SDK policy tests: PASS (5).
- Go SDK tests: PASS.
- C SDK build + policy test: PASS.
- C++ SDK build: PASS.
- authored-source unfinished-marker scan: PASS through the source verifier; the only Python `pass` found is the intentional empty custom exception class.
- obvious private-key/cloud/token-pattern scan: no real committed credential found; test-only dummy `pwb_x...` values were identified.

## Environment-blocked release gates

The supplied runner does not provide Erlang/OTP + rebar3, Rust/Cargo, Elm, PostgreSQL, Redis, ScyllaDB, or TURN. The extracted project also has no `node_modules`, and npm package/advisory endpoints are not resolvable from this environment. Therefore the following remain mandatory production-tag gates rather than claimed passes:

- `rebar3 compile`, EUnit, and OTP release construction;
- Rust SDK compile/tests;
- fresh npm install followed by full frontend/Elm compilation;
- Playwright/browser/WebRTC end-to-end regressions;
- live PostgreSQL migration from the prior production schema through migration 48;
- live Redis/Scylla/TURN integration/failure drills;
- registry-backed `npm audit` or equivalent full dependency advisory scan.

The repository CI workflows are intended to run the compiler/browser gates on a normal runner. A production tag should not be cut unless those jobs and deployment-environment smoke tests are green.
