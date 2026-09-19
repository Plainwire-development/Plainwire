# Building Plainwire

Use GNU Make 4.3 or newer (`gmake` on FreeBSD). Node.js 20.19+ (22+ recommended), npm, Python 3.9+, Erlang/OTP 27+ and rebar3 are required for the standard build. Native call health additionally needs a C11 compiler, gfortran and the matching libgfortran runtime on the deployment host. The optional cluster profile requires OTP 27+ and installed OTP sources.

```sh
make help
make doctor NATIVE=1
make build NATIVE=1
make browsers
make check NATIVE=1
make package NATIVE=1
```

`make` alone prints help. Dependencies install through `npm ci` only when the lockfile changes or the dependency stamp is absent. The project explicitly approves only the pinned install scripts required by Elm, esbuild and Parcel watcher through npm `allowScripts`; do not replace that policy with a blanket install-script bypass. Grouped frontend outputs rebuild together when source changes or an output is removed, including under `make -j`. The native target tracks both source files and its build script. Rebar manages Erlang compilation incrementally. After changing compiler selection, run `make -B native FC=gfortran CC=cc` to force a native rebuild.

`make check` runs syntax and manifest checks, browser UI and real RTP regressions, call-health parser tests and EUnit. `NATIVE=1` additionally runs the real Fortran numerical/protocol tests and the native EUnit integration. Install Chromium explicitly with `make browsers`, or set `CHROMIUM_EXECUTABLE` to an existing compatible Chromium binary. Test signaling and APIs are fixtures; these tests do not provision PostgreSQL or Cloudflare.

`make release` requires those checks before assembling the runtime release. With `NATIVE=0` (the default), the assembled runtime excludes a previously built native helper. With `NATIVE=1`, it checks that the helper is included. `make package` writes runtime and source archives plus SHA-256 files into `dist/`. `make source` verifies the tree, compiles both frontend and Erlang backend, and writes only the portable source archive; it does not certify the full runtime release. Native executables are always omitted from source packages.

`PROFILE=cluster` selects the optional rebar profile. For a small single-server installation, use the default profile. `NODE`, `NPM`, `PYTHON`, `REBAR3`, `CC` and `FC` can select tool executables. `SOURCE_DATE_EPOCH` sets archive timestamps; otherwise they are zero for deterministic source archives. Identical inputs produce identical source archives. Reproducibility of an entire Erlang runtime also depends on its build environment.

`make clean` removes Erlang output, Elm compiler caches, test screenshots and the compiled native helper. It preserves PostgreSQL data, uploads, configuration, secrets, source, npm dependencies and generated frontend assets. Run cleanup separately from other targets. Nothing in the Makefile installs services, restarts a running instance, downloads a browser without an explicit request, or edits a production database.

For an existing deployment, back up its database, uploads and configuration before replacing the release. Follow deploy/README.md for switching releases and rollback. The checks still needed against real services are listed in BUILD_STATUS.md.


## Scalability and load tests

Before raising connection limits, run the host preflight:

```sh
make load-doctor USERS=10000
```

The in-process BEAM stress harness exercises the actual realtime registry/delivery paths without paying for thousands of browser processes:

```sh
make load USERS=1000
make load USERS=10000 DURATION=120 RATE=40000
make load-soak USERS=10000
```

For end-to-end HTTP/WebSocket pressure, install the load-only Python dependency and provide a JSONL fixture of test accounts:

```sh
python -m pip install -r tools/load/requirements.txt
make load-live USERS=1000 DURATION=120 RATE=4000 \
  LOAD_BASE_URL=http://127.0.0.1:8080 \
  LOAD_SESSIONS_FILE=/secure/path/load.sessions.jsonl
```

`load-live` refuses a non-loopback target unless the operator explicitly supplies `LOAD_ALLOW_REMOTE=1`. Never aim it at infrastructure you do not own or have permission to stress. The live harness tests the realtime/control plane; it does not generate encoded RTP/video/screen media.

The typed capacity/backpressure/media model in `tools/load/gleam/` is checked with:

```sh
make load-gleam-check
```

Gleam is a load-model/test dependency only and is not required by the Plainwire production runtime. CI pins its compiler so model drift fails before release. See `docs/SCALING.md` and `tools/load/README.md`.
