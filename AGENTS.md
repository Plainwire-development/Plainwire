# AGENTS.md

This file provides guidance to AI Agents when working with code in this repository.

Plainwire Relay is a self-hostable chat server (servers/channels, DMs, forums, voice/screen-share calls, bots). The backend is Erlang/OTP + Cowboy on PostgreSQL. The frontend is an Elm SPA with a large JS bridge. Redis and ScyllaDB are optional.

## Commands

Use GNU Make 4.3+. Running `make` alone prints help.

```sh
make doctor                 # check toolchain (OTP 27+, node 20.19+, rebar3, python3)
make build                  # npm ci (only if lockfile changed) + frontend bundle + rebar3 compile
make build NATIVE=1         # also builds the Fortran/C call-health worker (priv/bin/pw-media-quality)
make browsers               # install Playwright Chromium (or set CHROMIUM_EXECUTABLE)
make check                  # verify-source + frontend + full test suite (what release requires)
./scripts/start.sh [--build] [--with-db]   # run locally via rebar3 shell on :8080 (needs PostgreSQL and .env)
```

For local dev, copy `.env.development.example` to `.env`. `guix shell postgresql -- ./scripts/dev-db.sh start` starts the bundled dev database.

Tests:

```sh
./scripts/verify-source.sh                 # fast source checks: JS syntax, all *-contract.mjs, version and manifest asserts
rebar3 eunit                               # all backend tests (test/*_tests.erl)
rebar3 eunit --module=pw_permissions_tests # a single EUnit module
npm run test:ui-contract                   # one source contract (see package.json for the rest)
npm run build && npm run test:browser      # Playwright UI suite against built priv/static, with mocked /api
npm run test:security-audit
npm run test:rtc                           # WebRTC regressions
./scripts/test-bot-sdks.sh                 # SDKs under sdk/ (c, cpp, erlang, go, javascript, python, rust)
make load USERS=250 DURATION=2 RATE=2000   # in-process realtime fanout smoke (CI runs this)
```

The browser tests serve `priv/static` from a throwaway Node server and fulfil `/api/**` with fixtures from `test/browser/fixtures.mjs`. They don't need PostgreSQL. Two EUnit modules (account recovery and upload authorization) run against a real database only when `PLAINWIRE_TEST_POSTGRES_PORT`/`_USER`/`_DB` are set; otherwise they're skipped.

CI (`.github/workflows/ci.yml`) runs these steps in order: verify-source, `npm run build`, `rebar3 compile && rebar3 eunit`, the load smoke, the live-load selftest, `gleam format --check`/`gleam check` in `tools/load/gleam`, then test:browser, test:security-audit, test:rtc, and the source archive build.

## Source contracts: read before refactoring

Most `test/browser/*-contract.mjs` files and `scripts/verify-source.sh` don't run code. They read source files as text and regex-assert that specific strings exist, for example `assert.match(markdown, /const EMBED_LIMIT = 5/)`, or exact Erlang clauses in `pw_db.erl`, `pw_cluster.erl` and `pw_sup.erl`. Renaming, moving or reformatting code can break them even when behaviour is unchanged. If you move code, update the contract that reads it. Some contracts concatenate several files (e.g. `pw_db.erl` + `pw_db_schema.erl`, or several Elm view modules), so code can move within that set without breaking anything.

`verify-source.sh` also enforces:
- No `TODO`/`FIXME`/`XXX`/`not implemented`/`placeholder implementation` markers in authored sources (`src/`, Elm, `web/`, bridge JS, admin, native, load tools).
- Every `PLAINWIRE_*` env var referenced in `src/*.erl` must appear in `.env.example`.
- PostgreSQL migration IDs in `pw_db_schema:migrations()` must be contiguous from 1. Add the next number; never edit or renumber an applied migration.
- No exact duplicate top-level function clauses, and no duplicate named-ETS `ets:new` in one module.
- No `__pycache__`/`.pyc` files anywhere in the tree.

## Version bumps

The version is pinned in several places, and verify-source checks they all match: `VERSION`, `src/plainwire_relay.app.src`, both `release` tuples in `rebar.config`, `attribute "data-ui-version"` in the Elm UI (currently `View/App.elm`), the fallback in `src/pw_client_config.erl`, `test/pw_client_config_tests.erl`, a new `RELEASE_NOTES_<ver>.md`, and the "Current release" line plus release-notes link in `README.md`. Also update `docs/README.md`. Some contracts also pin the release line (e.g. "2.6"). Commits for a release use the subject `Release X.Y.Z: <summary>`.

## Architecture

### Backend (`src/`, app `plainwire_relay`)

- **`pw_sup`** is a flat `one_for_one` tree of singleton workers. The HTTP listener (and the optional admin listener on :8090) starts last, after the DB and hub are up. The Cowboy routes are defined in `pw_sup:http_listener_spec/0`: `/ws` → `pw_ws`, `/api/uploads|files|media|client-config` → dedicated handlers, `/api/[...]` → `pw_api`, `/assets/[...]` → `priv/static`, and everything else → `pw_page`.
- **`pw_api`** is one large `handle(Method, PathSegments, Req, State)` function-clause router. It rate-limits per route bucket through `pw_rate`, and most clauses call into `pw_db`.
- **`pw_db`** (~10k lines) holds nearly all domain logic and authorization, not just SQL. Each public function wraps a message (`login(U,P) -> call({login,U,P})`). `call/1` reserves a slot on a pool of *lanes*, where each lane is a process owning one epgsql connection, and the work runs in the matching `route({...}, Conn)` clause. Add a feature as an export, a `call` wrapper and a `route` clause. The schema and migrations live in `pw_db_schema.erl`.
- **Message storage:** `pw_message_store` is the read/edit/delete boundary. Its backend is `postgres`, `scylla` or `dual`, chosen by `pw_scylla_config`; in `dual`, PostgreSQL stays the read authority. Writes always go through `pw_db` so that PG transactions, Scylla write intents and the durable `pw_storage_outbox` can't be bypassed. `pw_storage_reconciler`/`pw_storage_migration` handle backfill. PostgreSQL is always required.
- **Realtime:** `pw_ws` is the per-connection Cowboy WebSocket handler for users and bots. `pw_hub` is the control-plane gen_server for presence, subscriptions and the call/voice state machine. Hot-path fanout skips the hub mailbox: it goes through concurrent ETS in `pw_realtime_registry`, and `pw_realtime_delivery` sends the JSON frames. Calls are mesh WebRTC (`pw_media_topology`), with TURN config from `pw_rtc_config`/`pw_cf_turn`.
- **Optional subsystems** are gated by env vars and degrade to no-ops when disabled: `pw_redis` (`PLAINWIRE_REDIS_ENABLED`), Scylla (`pw_scylla*`), clustering (`pw_cluster*`; the Partisan transport exists only in the `PROFILE=cluster` rebar profile), the admin control plane (`pw_admin_*`, separate listener, "private-content blind" by design), the native media-quality worker (`pw_media_quality`), mail, KLIPY and the GitHub proxy.
- **Background dispatchers** (webhooks, app interactions, AI bots, upload GC, search index) poll claim/finish functions in `pw_db`.
- Configuration comes from env vars read at runtime (`pw_util:env_int/2` etc.), not from `sys.config`.

### Frontend

- `priv/static/elm/src/`: `Main.elm` (update), `Types.elm` (model/routes) and `View/*.elm`. Elm talks to the outside world only through the ports in `Ports.elm` (`apiSend/apiReceive`, `wsSend/wsReceive`, `bridgeSend/bridgeReceive`, …).
- `priv/static/elm-bridge.js` (~9.6k lines, hand-written, not generated) implements those ports: HTTP/CSRF, the WebSocket, WebRTC calls and screen share, audio, notifications and plugins. `bootstrap.js` loads the versioned assets.
- `web/markdown.js` (which imports `interface.js` → `source-hub.js`) and `web/highlight-all.js` are bundled with esbuild into `priv/static/markdown.js`/`highlight-all.js`. Edit the `web/` sources, not the bundles.
- Styles: `style.scss` (Sass partials `_*.scss`) and `style.less` (Less partials `_*.less`) are compiled and concatenated into `app.css` by `scripts/build-css.mjs`. `index.haml` → `index.html`, with `__PLAINWIRE_VERSION__` substituted.
- Generated and gitignored: `priv/static/{app.js,app.css,index.html}`. Rebuild with `npm run build` (or `make frontend`) before browser tests.
- `priv/admin/` is the separate, plain-JS host control-plane UI.

### Other trees

- `sdk/`: bot SDKs in seven languages for the bot API (`docs/bot-api.openapi.yaml`).
- `tools/load/`: the BEAM load simulator, the live HTTP/WS load harness (Python) and a Gleam capacity model. Gleam is used only in CI and is not a runtime dependency.
- `native/media_quality/`: the optional C + Fortran call-health worker.
- `docs/`: operator docs (SCALING, SCYLLA, REDIS, CLUSTERING, ADMIN, BOTS, WEBHOOKS, SECURITY).

## Conventions

- `rebar.config` compiles with `warn_unused_vars, warn_shadow_vars, warn_export_all`. Test-only exports go inside `-ifdef(TEST).` blocks.
- Dependencies are pinned to exact git refs or versions (Ranch 2.2.1 is deliberate). npm install scripts are allow-listed through `allowScripts` in `package.json`, and verify-source asserts that list, so don't loosen it.
