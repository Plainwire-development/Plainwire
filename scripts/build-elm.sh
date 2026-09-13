#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"
elm_bin=${ELM_BIN:-}
if [[ -z ${elm_bin} ]]; then
  if [[ -x node_modules/.bin/elm ]]; then
    elm_bin="${ROOT}/node_modules/.bin/elm"
  else
    elm_bin=$(command -v elm || true)
  fi
fi
if [[ -z ${elm_bin} ]]; then
  printf 'Elm compiler not found. Run npm ci or set ELM_BIN.\n' >&2
  exit 127
fi
cd priv/static/elm
exec "${elm_bin}" make src/Main.elm --output=../app.js --optimize
