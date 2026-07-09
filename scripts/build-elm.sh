#!/usr/bin/env bash
set -euo pipefail

clean_path=""
IFS=':' read -r -a path_parts <<< "${PATH}"
for path_part in "${path_parts[@]}"; do
  case "${path_part}" in
    */node_modules/.bin) ;;
    *)
      if [ -z "${clean_path}" ]; then
        clean_path="${path_part}"
      else
        clean_path="${clean_path}:${path_part}"
      fi
      ;;
  esac
done
export PATH="${clean_path}"

elm_bin="$(command -v elm || true)"
if [ -z "${elm_bin}" ]; then
  printf '%s\n' "Elm compiler not found. Install Elm 0.19.2 on the server PATH, then rerun npm run build:elm." >&2
  exit 127
fi

cd priv/static/elm
exec "${elm_bin}" make src/Main.elm --output=../app.js --optimize
