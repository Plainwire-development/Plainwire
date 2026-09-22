# Plainwire 2.5.1

2.5.1 is a release-tooling patch. It carries no database migration and no API
or protocol change; installs on 2.5.0 can upgrade or skip it freely. Its one
user-visible effect is that the client now reports its own version correctly.

2.5.0 was tagged but never promoted: it failed `make check`, so the pipeline
held production on 2.4.1. This release contains that fix.

## Client version reporting

The Elm UI stamps a `data-ui-version` attribute on the app shell. The 2.5.0 UI
refactor moved that markup into a new module, and the check that kept it in
step with `VERSION` was still looking at the old file, so 2.5.0 would have
served a UI labelled `2.4.1`. The attribute now reports the release it belongs
to.

Operators who script against this attribute — the OpenRC install and update
scripts use it to confirm a new UI is actually live — get an accurate value
again. Nothing else about the client changed.

## Release verification

Three guards had gone stale and were repaired:

* The Redis documentation check asserted one exact English sentence, so
  rewording `docs/REDIS.md` broke it. It now asserts the durability contract
  itself: Redis is never the durable authority, and PostgreSQL remains the
  relational source of truth.
* The 2.1 feature contract gate still named the 2.4 release series.
* The UI fingerprint check now searches the whole Elm source tree instead of a
  single file it can silently stop covering.

The database migration check was reading `src/pw_db.erl`, which no longer holds
the migration list after the 2.5.0 schema split, and it only recognised one of
the two ways a migration entry is written. It now reads both modules and both
forms, which brings 23 previously unchecked migrations under the contiguity and
duplicate check. No gaps or duplicates were found: migrations 1 through 53 are
intact.
