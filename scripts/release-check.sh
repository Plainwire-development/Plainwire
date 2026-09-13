#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"

need() { command -v "$1" >/dev/null 2>&1 || { printf 'Missing required command: %s\n' "$1" >&2; exit 127; }; }
for command_name in node npm erl rebar3; do need "${command_name}"; done

./scripts/verify-source.sh
npm ci
npm run build
npm run test:browser
node --check priv/static/bootstrap.js
node --check priv/static/elm-bridge.js
grep -Fq 'Plainwire 1.6.0 workspace' priv/static/app.css
grep -Fq 'data-ui-version' priv/static/app.js
rebar3 compile
rebar3 eunit
rebar3 release

release_root=_build/default/rel/plainwire_relay
[[ -x "${release_root}/bin/plainwire_relay" ]] || { printf 'Release executable is missing.\n' >&2; exit 1; }
grep -Fq 'Plainwire 1.6.0 workspace' "${release_root}"/lib/plainwire_relay-*/priv/static/app.css
grep -Fq 'data-ui-version' "${release_root}"/lib/plainwire_relay-*/priv/static/app.js

printf 'Plainwire 1.6.0 release checks passed.\n'
