#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

[[ ${EUID} -eq 0 ]] || { printf 'Run with sudo.\n' >&2; exit 1; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_USER=${PLAINWIRE_APP_USER:-${SUDO_USER:-$(stat -c %U "${REPO}")}}
[[ ${APP_USER} != root ]] || { printf 'Set PLAINWIRE_APP_USER to the account that owns the repository.\n' >&2; exit 1; }

run_as_app() {
    su -s /bin/bash "${APP_USER}" -c "export PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin; $*"
}

run_as_app "cd '${REPO}' && npm ci"
run_as_app "cd '${REPO}' && npm run build"
grep -Fq 'Plainwire 1.6.0 workspace' "${REPO}/priv/static/app.css" || { printf 'New UI CSS fingerprint is missing.\n' >&2; exit 1; }
grep -Fq 'data-ui-version' "${REPO}/priv/static/app.js" || { printf 'New Elm UI fingerprint is missing.\n' >&2; exit 1; }
run_as_app "cd '${REPO}' && rebar3 compile && rebar3 eunit && rebar3 release"
rc-service plainwire restart
rc-service plainwire status
curl -fsS http://127.0.0.1:8080/api/version | grep -Fq '1.6.0' || { printf 'Running backend version check failed.\n' >&2; exit 1; }
curl -fsS http://127.0.0.1:8080/assets/app.css | grep -Fq 'Plainwire 1.6.0 workspace' \
    || { printf 'Running frontend CSS check failed.\n' >&2; exit 1; }
curl -fsS http://127.0.0.1:8080/assets/app.js | grep -Fq 'data-ui-version' \
    || { printf 'Running frontend JavaScript check failed.\n' >&2; exit 1; }
printf 'Plainwire 1.6.0 is running with the refreshed frontend.\n'
