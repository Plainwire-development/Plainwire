#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run this installer with sudo."

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_USER=${PLAINWIRE_APP_USER:-${SUDO_USER:-$(stat -c %U "${REPO}")}}
[[ ${APP_USER} != root ]] || die "Run with sudo from the account that owns the Plainwire repository, or set PLAINWIRE_APP_USER."
APP_GROUP=$(id -gn "${APP_USER}")
RELEASE="${REPO}/_build/default/rel/plainwire_relay/bin/plainwire_relay"
UPLOAD_DIR=/var/lib/plainwire/uploads
LOG_DIR=/var/log/plainwire
PG_SERVICE=${PLAINWIRE_POSTGRES_SERVICE:-}

for command_name in openssl psql createdb rebar3 elm node npm rc-service rc-update supervise-daemon cloudflared curl; do
    command -v "${command_name}" >/dev/null || die "Required command is missing: ${command_name}"
done

CLOUDFLARED_BIN=$(command -v cloudflared)
if [[ -z ${PG_SERVICE} ]]; then
    if [[ -x /etc/init.d/postgresql ]]; then
        PG_SERVICE=postgresql
    else
        pg_services=()
        for pg_service_path in /etc/init.d/postgresql*; do
            [[ -x ${pg_service_path} ]] || continue
            pg_services+=("${pg_service_path##*/}")
        done
        [[ ${#pg_services[@]} -gt 0 ]] || die "Could not find an OpenRC PostgreSQL service. Set PLAINWIRE_POSTGRES_SERVICE."
        PG_SERVICE=${pg_services[$((${#pg_services[@]} - 1))]}
    fi
fi
[[ -x /etc/init.d/${PG_SERVICE} ]] || die "PostgreSQL OpenRC service not found: ${PG_SERVICE}"

printf 'Public Plainwire hostname (example: chat.example.com): '
read -r PUBLIC_HOST
PUBLIC_HOST=${PUBLIC_HOST#https://}
PUBLIC_HOST=${PUBLIC_HOST#http://}
PUBLIC_HOST=${PUBLIC_HOST%/}
[[ ${PUBLIC_HOST} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "That is not a valid hostname."
[[ ${PUBLIC_HOST} != *.trycloudflare.com ]] \
    || die "trycloudflare.com is a temporary Quick Tunnel address and changes after restart. Use a hostname assigned to a named Cloudflare Tunnel for 24/7 hosting."

printf 'Paste the Cloudflare Tunnel token (input is hidden): '
read -rs TUNNEL_TOKEN
printf '\n'
[[ ${#TUNNEL_TOKEN} -ge 40 ]] || die "The tunnel token is missing or unexpectedly short."

TURN_URLS=${PLAINWIRE_TURN_URLS:-}
TURN_SECRET=${PLAINWIRE_TURN_SECRET:-}
if [[ -z ${TURN_URLS} ]]; then
    printf 'TURN URLs (comma-separated, example turn:turn.example.com:3478?transport=udp): '
    read -r TURN_URLS
fi
if [[ -z ${TURN_SECRET} ]]; then
    printf 'TURN shared secret (input is hidden, at least 32 characters): '
    read -rs TURN_SECRET
    printf '\n'
fi
[[ ${TURN_URLS} == *turn:* || ${TURN_URLS} == *turns:* ]] \
    || die "A public Plainwire deployment needs TURN. Configure coturn or another TURN service and rerun the installer."
[[ ${#TURN_SECRET} -ge 32 ]] \
    || die "PLAINWIRE_TURN_SECRET must contain at least 32 characters."
[[ ${TURN_URLS} != *"'"* && ${TURN_URLS} != *$'\n'* ]] || die "TURN URLs contain unsupported shell characters."
[[ ${TURN_SECRET} != *"'"* && ${TURN_SECRET} != *$'\n'* ]] || die "TURN secret contains unsupported shell characters."

DB_PASS=$(openssl rand -hex 32)
ENC_KEY=$(openssl rand -base64 32 | tr -d '\n')
MEDIA_KEY=$(openssl rand -base64 32 | tr -d '\n')

run_as_app() {
    su -s /bin/bash "${APP_USER}" -c "export PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin; $*"
}

info "Building frontend, Erlang, tests, and the release"
run_as_app "cd '${REPO}' && npm ci"
run_as_app "cd '${REPO}' && npm run build"
grep -Fq 'Plainwire 1.6.0 workspace' "${REPO}/priv/static/app.css" || die "New UI CSS fingerprint is missing."
grep -Fq 'data-ui-version' "${REPO}/priv/static/app.js" || die "New Elm UI fingerprint is missing."
run_as_app "cd '${REPO}' && rebar3 compile && rebar3 eunit && rebar3 release"
[[ -x ${RELEASE} ]] || die "Release executable was not created."

info "Securing PostgreSQL account"
rc-service "${PG_SERVICE}" status >/dev/null 2>&1 || rc-service "${PG_SERVICE}" start
if runuser -u postgres -- psql -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='plainwire'" | grep -qx 1; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres \
        -c "ALTER ROLE plainwire WITH LOGIN PASSWORD '${DB_PASS}'" >/dev/null
else
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres \
        -c "CREATE ROLE plainwire LOGIN PASSWORD '${DB_PASS}'" >/dev/null
fi
if ! runuser -u postgres -- psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='plainwire'" | grep -qx 1; then
    runuser -u postgres -- createdb -O plainwire plainwire
fi

info "Installing protected configuration and storage directories"
install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 0750 "${UPLOAD_DIR}" "${LOG_DIR}"
install -d -o root -g "${APP_GROUP}" -m 0750 /etc/cloudflared
umask 0077
printf '%s\n' "${TUNNEL_TOKEN}" > /etc/cloudflared/plainwire.token
chown root:"${APP_GROUP}" /etc/cloudflared/plainwire.token
chmod 0640 /etc/cloudflared/plainwire.token

cat > /etc/conf.d/plainwire <<EOF
# Generated by Plainwire's OpenRC installer. Keep this file secret.
export PLAINWIRE_ENV=production
export PORT=8080
export PLAINWIRE_PUBLIC_URL=https://${PUBLIC_HOST}
export PLAINWIRE_ALLOWED_ORIGINS=https://${PUBLIC_HOST}
export PLAINWIRE_TRUST_PROXY=true
export COOKIE_SECURE=true
export PLAINWIRE_ENC_KEY='${ENC_KEY}'
export PLAINWIRE_MEDIA_SIGNING_KEY='${MEDIA_KEY}'
export PLAINWIRE_DB_HOST=127.0.0.1
export PLAINWIRE_DB_PORT=5432
export PLAINWIRE_DB_USER=plainwire
export PLAINWIRE_DB_PASS='${DB_PASS}'
export PLAINWIRE_DB_NAME=plainwire
export PLAINWIRE_DB_SSL=false
export PLAINWIRE_ALLOW_INSECURE_DB=true
export PLAINWIRE_DB_POOL_SIZE=10
export PLAINWIRE_UPLOAD_DIR=${UPLOAD_DIR}
export PLAINWIRE_UPLOAD_MAX_BYTES=262144000
export PLAINWIRE_UPLOAD_MAX_FILES=10
export PLAINWIRE_PROFILE_IMAGE_MAX_BYTES=16777216
export PLAINWIRE_COMPRESS_OVERSIZE_UPLOADS=true
export PLAINWIRE_UPLOAD_IMAGE_MAX_DIMENSION=4096
export PLAINWIRE_UPLOAD_QUOTA_BYTES=1073741824
export PLAINWIRE_UPLOAD_RETENTION_DAYS=90
export PLAINWIRE_UPLOAD_CONCURRENCY=32
export PLAINWIRE_UPLOAD_USER_CONCURRENCY=4
export PLAINWIRE_UPLOAD_INFLIGHT_BYTES=1073741824
export PLAINWIRE_UPLOAD_USER_INFLIGHT_BYTES=536870912
export PLAINWIRE_MEDIA_ALLOWED_HOSTS=media.tenor.com,i.giphy.com,media.giphy.com
export PLAINWIRE_ALLOW_ARBITRARY_MEDIA=false
export PLAINWIRE_MEDIA_FETCH_CONCURRENCY=8
export PLAINWIRE_DEFAULT_THEME=system
export PLAINWIRE_SESSION_DAYS=30
export PLAINWIRE_MAX_SESSIONS_PER_USER=32
export PLAINWIRE_TURN_URLS='${TURN_URLS}'
export PLAINWIRE_TURN_SECRET='${TURN_SECRET}'
export PLAINWIRE_TURN_USERNAME=plainwire
export PLAINWIRE_TURN_TTL_SECONDS=3600
export PLAINWIRE_REQUIRE_TURN=true
EOF
chown root:"${APP_GROUP}" /etc/conf.d/plainwire
chmod 0640 /etc/conf.d/plainwire

cat > /etc/init.d/plainwire <<EOF
#!/sbin/openrc-run
name="Plainwire"
description="Plainwire chat server"
supervisor="supervise-daemon"
command="${RELEASE}"
command_args="foreground"
command_user="${APP_USER}:${APP_GROUP}"
directory="${REPO}"
respawn_delay=5
respawn_max=0
output_log="${LOG_DIR}/plainwire.log"
error_log="${LOG_DIR}/plainwire-error.log"
depend() {
    need net ${PG_SERVICE}
    after firewall
}
EOF
chmod 0755 /etc/init.d/plainwire

cat > /etc/init.d/cloudflared-plainwire <<EOF
#!/sbin/openrc-run
name="Cloudflare Tunnel for Plainwire"
description="Persistent outbound Cloudflare Tunnel"
supervisor="supervise-daemon"
command="${CLOUDFLARED_BIN}"
command_args="tunnel --no-autoupdate run --token-file /etc/cloudflared/plainwire.token"
command_user="${APP_USER}:${APP_GROUP}"
respawn_delay=5
respawn_max=0
output_log="${LOG_DIR}/cloudflared.log"
error_log="${LOG_DIR}/cloudflared-error.log"
depend() {
    need net
    after plainwire
}
EOF
chmod 0755 /etc/init.d/cloudflared-plainwire

info "Enabling and starting services"
rc-update add "${PG_SERVICE}" default >/dev/null 2>&1 || true
rc-update add plainwire default >/dev/null 2>&1 || true
rc-update add cloudflared-plainwire default >/dev/null 2>&1 || true
if rc-service plainwire status >/dev/null 2>&1; then
    rc-service plainwire restart
else
    rc-service plainwire start
fi

for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8080/ >/dev/null; then break; fi
    sleep 1
done
curl -fsS http://127.0.0.1:8080/ >/dev/null \
    || die "Plainwire did not answer on port 8080. Check ${LOG_DIR}/plainwire-error.log"
curl -fsS http://127.0.0.1:8080/api/version | grep -Fq '1.6.0' \
    || die "Plainwire answered, but the running release is not 1.6.0."
curl -fsS http://127.0.0.1:8080/assets/app.css | grep -Fq 'Plainwire 1.6.0 workspace' \
    || die "Plainwire answered, but the refreshed CSS is not being served."
curl -fsS http://127.0.0.1:8080/assets/app.js | grep -Fq 'data-ui-version' \
    || die "Plainwire answered, but the refreshed Elm frontend is not being served."

if rc-service cloudflared-plainwire status >/dev/null 2>&1; then
    rc-service cloudflared-plainwire restart
else
    rc-service cloudflared-plainwire start
fi

cat <<EOF

Plainwire is installed and running.

Local service:  http://127.0.0.1:8080
Public service: https://${PUBLIC_HOST}

In the Cloudflare dashboard, the tunnel's Published application must point
${PUBLIC_HOST} to http://127.0.0.1:8080. The tunnel token cannot change that
dashboard route by itself.

Useful commands:
  sudo rc-service plainwire status
  sudo rc-service cloudflared-plainwire status
  sudo tail -f ${LOG_DIR}/plainwire.log
  sudo tail -f ${LOG_DIR}/plainwire-error.log

The generated secrets are stored only in /etc/conf.d/plainwire.
Do not post or commit that file.
EOF
