# Plainwire 2.6.2

2.6.2 repairs the message search backfill. It carries no database migration
and no new environment variables. Installs on 2.6.1 can upgrade directly.

## The search index never finished building

The background job that indexes existing messages failed on every run. It
read its own progress record as text, treated the text `f` as a boolean, and
raised an error before indexing anything. The job retried every three
seconds, so the relay logged `DB route failed error:{badarg,<<"f">>}` for
`search_index_reconcile` continuously.

Messages were still indexed when they were posted or edited. Messages that
predate the search index were never backfilled and could not be found by
search.

The job now reads its progress record correctly and runs to completion.

## What to expect after upgrading

The first successful run records the search key fingerprint for the first
time. As with any fingerprint change, the index is cleared and rebuilt from
the message table. The rebuild proceeds in batches of
`PLAINWIRE_SEARCH_BACKFILL_BATCH` messages (default 100) every
`PLAINWIRE_SEARCH_BACKFILL_INTERVAL_MS` milliseconds (default 1500). Search
results are incomplete until it finishes. After that the job checks in every
30 seconds and does no further work.

Installs without an encryption or search key have search disabled and are
unaffected.

## Search responses

The `index.complete` field of a message search response is now a JSON
boolean. It was previously the string `"t"` or `"f"`.
