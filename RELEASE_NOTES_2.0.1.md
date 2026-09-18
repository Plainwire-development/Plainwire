# Plainwire 2.0.1

2.0.1 is a bug-fix release for 2.0.0. It has no new features, no schema changes and no new configuration. It can be deployed over 2.0.0 as-is.

## Service control plane can be claimed again

On a fresh 2.0.0 instance the host-level operator console could never be claimed. The first-run bootstrap token was never generated, `/api/status` reported `bootstrap_available: false` with no operators configured, and a claim attempt answered `bootstrap_unavailable`.

2.0.1 generates the one-time bootstrap token on startup while there are no operators, as documented. Instances that already have operators are unaffected.

## No more periodic "database busy" errors

After 2.0.0 started issuing 64-bit message ids, a completed upload-reference backfill kept restarting every 30 seconds. Each run crashed a database connection, which restarted the whole connection pool. During each restart, requests failed with `database_busy`. Users saw this as a brief "database busy" error (for example when reacting to a message), sometimes with a dropped realtime connection that reconnected on its own.

The backfill now recognizes that it has finished and stays idle, so the pool is no longer restarted.

Both fixes come from the same cause. Database queries without parameters return their columns as text, and two code paths compared those results to numbers and booleans. See [#8](https://github.com/Plainwire-development/Plainwire/pull/8).

## Known issues

- An instance whose upload-reference backfill had **not** finished before messages with 64-bit ids were created can still hit the same overflow, because the backfill's cursor column is still a 32-bit integer. Instances whose backfill already completed are not affected.
- The service control plane's overview shows some totals as strings rather than numbers. This is cosmetic.
