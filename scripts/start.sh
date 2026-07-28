#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

usage() {
  cat <<'EOF'
Usage: scripts/start.sh [--build] [--help]

Start Plainwire Relay locally with rebar3 shell.

Options:
  --build   Build HAML, SCSS, and Elm assets before starting
  --help    Show this help

Environment variables can be set in .env (see .env.example).
Default URL: http://localhost:8080
EOF
}

load_env() {
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    printf 'Loaded .env\n'
  fi
}

build_assets() {
  npm run build
}

main() {
  local do_build=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --build)
        do_build=true
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  load_env

  if [ "${do_build}" = true ]; then
    build_assets
  elif [ ! -f priv/static/app.js ] || [ ! -f priv/static/app.css ] || [ ! -f priv/static/index.html ]; then
    printf 'Frontend assets missing; building...\n'
    build_assets
  fi

  command -v rebar3 >/dev/null \
    || { printf 'rebar3 not found. Install rebar3 and rerun scripts/start.sh.\n' >&2; exit 127; }

  rebar3 get-deps
  rebar3 compile

  PORT="${PORT:-8080}"
  printf '\nPlainwire Relay starting on http://localhost:%s\n\n' "${PORT}"
  exec rebar3 shell --apps plainwire_relay
}

main "$@"
