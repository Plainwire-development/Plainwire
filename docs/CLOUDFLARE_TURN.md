# Cloudflare TURN

Set these on the server, then restart Plainwire:

```sh
PLAINWIRE_CF_TURN_KEY_ID=your-turn-key-id
PLAINWIRE_CF_TURN_API_TOKEN=your-turn-key-api-token
PLAINWIRE_TURN_TTL_SECONDS=3600
PLAINWIRE_REQUIRE_TURN=true
```

These are Realtime TURN credentials, not a Cloudflare Tunnel token. Both values must be present. Cloudflare takes priority over the existing coturn/static configuration; clearing both restores the legacy mode. The OpenRC installer accepts these environment variables, and its update script preserves the installed configuration.

`pw_cf_turn` uses the credential-generation API and GraphQL usage API from the supplied Erlang files, with separate background requests. TLS verifies the provider certificate and hostname, redirects are disabled, HTTP requests time out, and response bodies are never logged. Credential parsing accepts standard Cloudflare TURN endpoints, not arbitrary relay hosts or custom domains.

Credentials are cached separately for each authenticated user. Concurrent requests for the same user coalesce. At most four credential jobs run concurrently, each with bounded waiters and a five-second worker deadline. The cache holds at most 1,024 users; provider failures impose a 30-second retry delay. Tokens stay on the backend; `/api/rtc-config` returns temporary credentials with `Cache-Control: no-store`.

The browser refreshes configuration during calls, applies new credentials to existing peer connections and schedules controlled ICE recovery. Refresh work stops after leaving. Relay failures preserve direct connection attempts when policy is `all`. Explicit `relay` policy is preserved and cannot fall back to a direct connection.

## Optional usage guard

```sh
PLAINWIRE_CF_ACCOUNT_ID=your-account-id
PLAINWIRE_CF_ANALYTICS_API_TOKEN=token-with-account-analytics-access
PLAINWIRE_TURN_MONTHLY_LIMIT_BYTES=950000000000
PLAINWIRE_CF_USAGE_CHECK_INTERVAL_MS=300000
```

With an account ID, unknown usage, a failed first check, data older than 15 minutes, or an exceeded limit prevents credential issuance. Clearing the account ID disables usage checking. A separate analytics token is preferred; when empty the TURN token is used.

This is an issuance guard, **not a hard billing cap**. Analytics is delayed, other applications can share the account, and credentials already issued remain usable until expiry. Configure provider-side alerts and a margin appropriate to your traffic. The default byte threshold is a configurable budget, not a promise about Cloudflare pricing or a free allowance.

## Deployment check

Check Settings → Account → Connection diagnostics. Then call between two different networks, test both microphones, watch a shared screen, reconnect once, and keep a call open through a credential refresh. For a controlled relay-only test, set `PLAINWIRE_ICE_TRANSPORT_POLICY=relay`, restart, and verify a selected relay candidate in browser WebRTC diagnostics. Restore the intended policy afterward. No Cloudflare account credentials were available during packaging, so live issuance, analytics permissions and relay connectivity remain target-environment checks.

API references: [credential generation](https://developers.cloudflare.com/realtime/turn/generate-credentials/) and [TURN analytics](https://developers.cloudflare.com/realtime/turn/analytics/).
