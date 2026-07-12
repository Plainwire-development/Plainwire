#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

[[ ${EUID} -eq 0 ]] || { printf 'Run with sudo.\n' >&2; exit 1; }
APP_USER=${SUDO_USER:-robert}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

run_as_app() {
    su -s /bin/bash "${APP_USER}" -c "export PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin; $*"
}

run_as_app "cd '${REPO}/priv/static/elm' && elm make src/Main.elm --output=../app.js --optimize"
run_as_app "cd '${REPO}' && sass priv/static/style.scss priv/static/app.css --no-source-map"
run_as_app "cd '${REPO}' && rebar3 compile && rebar3 eunit && rebar3 release"
rc-service plainwire restart
rc-service plainwire status
