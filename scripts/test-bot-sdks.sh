#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_ROOT=${TMPDIR:-/tmp}/plainwire-sdk-check-$$
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required SDK tool: %s\n' "$1" >&2
    return 1
  }
}

printf '%s\n' '== Plainwire bot SDK validation =='

need cmake
need cc
cmake -S "$ROOT/sdk/c" -B "$TMP_ROOT/c" >/dev/null
cmake --build "$TMP_ROOT/c" -j2
ctest --test-dir "$TMP_ROOT/c" --output-on-failure

need c++
cmake -S "$ROOT/sdk/cpp" -B "$TMP_ROOT/cpp" >/dev/null
cmake --build "$TMP_ROOT/cpp" -j2

need go
(cd "$ROOT/sdk/go" && go test ./...)

need python
PYTHONPATH="$ROOT/sdk/python" python -m unittest discover -s "$ROOT/sdk/python/tests" -v

need node
node --test "$ROOT/sdk/javascript/tests/client.test.mjs"

need cargo
(cd "$ROOT/sdk/rust" && cargo test)

need rebar3
(cd "$ROOT/sdk/erlang" && rebar3 eunit)

printf '%s\n' 'PASS: all first-party Plainwire bot SDKs validated.'
