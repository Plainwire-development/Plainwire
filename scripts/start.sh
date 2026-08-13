#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

usage() {
  cat <<'EOF'
Usage: scripts/start.sh [--build] [--with-db] [--help]

Start Plainwire Relay locally with rebar3 shell.

Options:
  --build   Build HAML, SCSS, and Elm assets before starting
  --with-db Start or initialize the local development PostgreSQL database
  --help    Show this help

Environment variables can be set in .env (see .env.example).
Default URL: http://localhost:8080
EOF
}

validate_port() {
  local port="$1"

  if [[ ! "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    printf 'Invalid PORT: %s (expected 1-65535).\n' "${port}" >&2
    exit 2
  fi
}

port_is_listening() {
  local port="$1"
  (exec 9<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

plainwire_is_healthy() {
  local port="$1"
  local response

  command -v curl >/dev/null 2>&1 || return 1
  response="$(curl --silent --show-error --max-time 2 "http://127.0.0.1:${port}/api/health" 2>/dev/null || true)"
  [[ "${response}" == *'"app":"ok"'* ]]
}

ensure_port_available() {
  local port="$1"

  port_is_listening "${port}" || return 0

  if plainwire_is_healthy "${port}"; then
    printf '\nPlainwire Relay is already running on http://localhost:%s\n' "${port}"
    printf 'Nothing else was started. Stop the existing server with Ctrl-C before restarting it.\n'
    exit 0
  fi

  printf '\nPort %s is already used by another process.\n' "${port}" >&2
  printf 'Stop that process or choose another port, for example:\n' >&2
  printf '  PORT=%s ./scripts/start.sh\n' "$((port + 1))" >&2
  exit 98
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
  local with_db=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --build)
        do_build=true
        ;;
      --with-db)
        with_db=true
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

  PORT="${PORT:-8080}"
  export PORT
  validate_port "${PORT}"

  if [ "${with_db}" = true ]; then
    "${ROOT}/scripts/dev-db.sh" start
  fi

  if [ "${do_build}" = true ]; then
    build_assets
  elif [ ! -f priv/static/app.js ] || [ ! -f priv/static/app.css ] || [ ! -f priv/static/index.html ]; then
    printf 'Frontend assets missing; building...\n'
    build_assets
  fi

  ensure_port_available "${PORT}"

  command -v rebar3 >/dev/null \
    || { printf 'rebar3 not found. Install rebar3 and rerun scripts/start.sh.\n' >&2; exit 127; }

  rebar3 get-deps
  rebar3 compile

  printf '\nPlainwire Relay starting on http://localhost:%s\n\n' "${PORT}"
  exec rebar3 shell --apps plainwire_relay
}

main "$@"
