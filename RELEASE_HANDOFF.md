# Public-release handoff

## Resume instructions

Preserve the dirty worktree: it contains the active production-hardening and
attachment implementation. Inspect diffs before changing overlapping code.

Run these first:

```sh
rebar3 eunit
ELM_BIN=/home/linuxbrew/.linuxbrew/Cellar/elm/0.19.2/bin/elm scripts/build-elm.sh
git diff --check
```

## Current status

- [x] Streamed uploads; 250 MB hard per-file ceiling.
- [x] Atomic PostgreSQL reservation for 1 GB/user/rolling three hours.
- [x] Clipboard paste, drag/drop, file picker, inline images and downloads.
- [x] SHA-256, temporary files, atomic rename, retention cleanup.
- [x] Authenticated downloads and production upload-directory validation.
- [x] Complete the final concurrency audit described below.
- [x] Re-run all verification commands and record results here.

## Final concurrency audit

Completed: whole routed operations are serialized per physical epgsql
connection, while the pool remains concurrent. ETS load counters drive pool
selection and overload shedding. Attachment metadata is cached for five minutes;
uploads have node-wide and per-user concurrency caps; downloads are rate-limited;
malformed capability IDs are rejected before database access. Upload storage is
checked for writability at startup and partial writes are cleaned on failure.

No synthetic capacity number is claimed: run a production-equivalent load test
against the intended PostgreSQL and upload volume before launch.

## Final verification (2026-07-11)

- `rebar3 eunit`: 17 tests, 0 failures.
- Optimized Elm build: success.
- `bash -n scripts/build-elm.sh`: success.
- `git diff --check`: success.
- Application-source unfinished-marker scan: no findings.

## Deployment requirements

Use a durable absolute `PLAINWIRE_UPLOAD_DIR`, configure the reverse proxy to
allow 250 MB only on `/api/uploads`, keep smaller limits elsewhere, and tune DB
pool size below PostgreSQL's connection limit. Load-test message fan-out and
uploads on production-equivalent storage before declaring a numeric capacity.
