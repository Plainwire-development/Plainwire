# Deploy Plainwire

Plainwire needs a Linux host, PostgreSQL, an HTTPS reverse proxy, and durable space for uploads. Calls between different networks also need a TURN server. The supplied service file is for systemd; existing OpenRC deployments can continue using the OpenRC scripts.

## Build and install

Build on the same OS and architecture as the server:

```sh
npm ci
npm run build
rebar3 compile
rebar3 eunit
rebar3 release
```

Copy `_build/default/rel/plainwire_relay` to a versioned directory such as `/opt/plainwire/releases/1.6.0`. Make `/opt/plainwire/current` a symlink to that directory. Create a dedicated `plainwire` service account with no login shell. The release should be readable and executable by that account, but owned by the administrator.

Copy `.env.example` to `/etc/plainwire/plainwire.env`, replace the example values, and restrict the file to root. Set the public URL, database credentials, encryption key, and TURN credentials. Keep this environment file, the database, and uploads when upgrading. Losing or changing the encryption key makes previously encrypted messages unreadable.

Install `plainwire.service` in `/etc/systemd/system/`, then run:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now plainwire
sudo journalctl -u plainwire -n 50 --no-pager
curl --fail http://127.0.0.1:8080/api/health
```

Systemd creates `/var/lib/plainwire` for uploads. PostgreSQL should have its own database and role for Plainwire. Use database TLS for remote databases. The explicit `PLAINWIRE_ALLOW_INSECURE_DB=true` exception is only appropriate for a database isolated on the same trusted host or network; do not expose PostgreSQL publicly.

## HTTPS and networking

The Caddyfile is a starting configuration. Set `PLAINWIRE_HOST` in the Caddy service environment, point the domain at the server, validate with `caddy validate`, and reload Caddy. It supports WebSocket upgrades through the normal reverse proxy. Keep port 8080 private using the host firewall; allow public traffic on ports 80 and 443. Match the upload request limit to `PLAINWIRE_UPLOAD_MAX_BYTES` if you change it.

Set `PLAINWIRE_TRUST_PROXY=true` only when clients must pass through your trusted reverse proxy. Public access to the backend would let clients supply their own forwarded IP headers and weaken IP rate limits.

## Verify before opening registration

1. Check `/api/health` and `/api/version` through the public HTTPS origin.
2. Create two test accounts and verify messages, replies, failed-send retry, uploads and downloads.
3. Test calls and screen sharing from two different networks with your configured TURN service.
4. Refresh while in a call, reconnect after a network interruption, and confirm sessions can be revoked.
5. Check a phone with its keyboard open in both light and dark mode.

Browser regression tests use deterministic API fixtures. They verify frontend behavior, not your PostgreSQL or TURN deployment. Run them with `npx playwright install chromium` followed by `npm run test:browser`.

## Updates and recovery

Back up PostgreSQL, the upload directory, and the environment file before upgrading. Build the new release in a separate directory, stop the service, point `current` at the new release, and start it. Keep the previous release until the health check and account smoke tests pass. If startup fails, stop the service before restoring the previous symlink. Review database migration compatibility before rolling back code; a symlink change does not roll back the database.

Keep backups off the server and periodically restore one into a separate environment. Do not use a copy of the live PostgreSQL data directory as your only backup.
