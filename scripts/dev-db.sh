#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${PLAINWIRE_DEV_DB_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/plainwire/postgres}"
SOCKET_DIR="${PLAINWIRE_DEV_DB_SOCKET_DIR:-$(dirname "${DATA_DIR}")}"
LOG_FILE="${PLAINWIRE_DEV_DB_LOG:-${SOCKET_DIR}/postgres.log}"
DB_PORT="${PLAINWIRE_DB_PORT:-5432}"
DB_USER="${PLAINWIRE_DB_USER:-plainwire}"
DB_NAME="${PLAINWIRE_DB_NAME:-plainwire}"

usage() {
  printf 'Usage: scripts/dev-db.sh {start|stop|restart|status|log}\n'
}

require_postgres() {
  for command_name in initdb pg_ctl createdb psql; do
    command -v "${command_name}" >/dev/null || {
      printf '%s not found. On Guix run: guix shell postgresql -- ./scripts/dev-db.sh %s\n' "${command_name}" "${1:-start}" >&2
      exit 127
    }
  done
}

validate_config() {
  [[ "${DB_PORT}" =~ ^[0-9]+$ ]] || { printf 'Invalid PostgreSQL port.\n' >&2; exit 2; }
  [[ "${DB_USER}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'Invalid PostgreSQL user.\n' >&2; exit 2; }
  [[ "${DB_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'Invalid PostgreSQL database name.\n' >&2; exit 2; }
}

initialize() {
  mkdir -p "${DATA_DIR}" "${SOCKET_DIR}"
  if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
    printf 'Initializing local PostgreSQL cluster in %s\n' "${DATA_DIR}"
    initdb -D "${DATA_DIR}" --username="${DB_USER}" --auth=trust
  fi
}

is_running() {
  pg_ctl -D "${DATA_DIR}" status >/dev/null 2>&1
}

start_db() {
  initialize
  if is_running; then
    printf 'Plainwire PostgreSQL is already running on port %s.\n' "${DB_PORT}"
  else
    printf 'Starting Plainwire PostgreSQL on port %s...\n' "${DB_PORT}"
    pg_ctl -D "${DATA_DIR}" -l "${LOG_FILE}" -o "-k ${SOCKET_DIR} -p ${DB_PORT}" -w start
  fi

  if [ "$(psql -h "${SOCKET_DIR}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" != "1" ]; then
    createdb -h "${SOCKET_DIR}" -p "${DB_PORT}" -U "${DB_USER}" "${DB_NAME}"
    printf 'Created database %s.\n' "${DB_NAME}"
  fi
  printf 'Database ready. Start Plainwire with: ./scripts/start.sh --build\n'
}

stop_db() {
  if [ ! -f "${DATA_DIR}/PG_VERSION" ] || ! is_running; then
    printf 'Plainwire PostgreSQL is not running.\n'
  else
    pg_ctl -D "${DATA_DIR}" -w stop
  fi
}

main() {
  local action="${1:-start}"
  require_postgres "${action}"
  validate_config
  case "${action}" in
    start) start_db ;;
    stop) stop_db ;;
    restart) stop_db; start_db ;;
    status)
      if is_running; then printf 'Plainwire PostgreSQL is running.\n'; else printf 'Plainwire PostgreSQL is stopped.\n'; exit 1; fi
      ;;
    log) tail -n 80 "${LOG_FILE}" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
