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

elm_bin="${ELM_BIN:-$(command -v elm || true)}"
if [ -z "${elm_bin}" ]; then
  if command -v guix >/dev/null 2>&1; then
    printf '%s\n' "Elm compiler not found on PATH; building with 'guix shell elm'."
    exec guix shell elm -- bash "${BASH_SOURCE[0]}"
  fi

  printf '%s\n' "Elm compiler not found. Install Elm 0.19.x or Guix, then rerun scripts/build-elm.sh." >&2
  exit 127
fi

resolved_elm="$(readlink -f "${elm_bin}" 2>/dev/null || printf '%s' "${elm_bin}")"
case "${resolved_elm}" in
  */node_modules/*)
    printf '%s\n' "Refusing npm-installed Elm wrapper. Set ELM_BIN to a native Elm compiler." >&2
    exit 127
    ;;
esac

cd priv/static/elm
exec "${resolved_elm}" make src/Main.elm --output=../app.js --optimize
