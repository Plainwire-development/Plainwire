# Plainwire 1.8.1

Plainwire 1.8.1 is a control-plane and reliability patch release. It expands the hosted-instance operator console without changing Plainwire's private-content boundary, and fixes Erlang source issues found when compiling the 1.8.0 admin paths with a real Erlang compiler.

## Hosted-instance announcements

- Added persisted, service-wide announcement banners managed from **Service controls** in the Plainwire Control panel.
- Banners can be immediate, scheduled for a future time, temporary with an expiry, or permanent until an operator disables/deletes them.
- Operators can choose `info`, `success`, `warning`, or `critical`, an optional short title, optional safe link, and whether users may dismiss the banner.
- Pause/resume, edit, and delete operations are realtime. Connected authenticated clients receive an internal system invalidation event and refresh the authoritative banner list without reloading the page.
- The public read endpoint is deliberately narrow and bounded: it returns only enabled announcements whose start time has arrived and that have not expired, so future scheduled text is not disclosed before publication.
- Clients render at most three simultaneous visible banners. Expiry is handled locally, and a small visibility-aware 60-second banner refresh activates scheduled announcements without requiring a page reload; realtime invalidation remains the fast path for operator edits.
- Banner dismissal is keyed by banner ID plus update revision, so an operator materially editing an announcement makes the new revision visible again.
- Banner text is rendered with DOM text nodes; links are limited to same-origin paths or HTTPS destinations.

## Service controls

- Added a runtime registration override: `inherit` follows `PLAINWIRE_REGISTRATION_ENABLED`, while `enabled`/`disabled` override it through persisted instance settings. Registration authorization remains server-side.
- Added **Reconcile clients**, a lightweight realtime resynchronization request for connected clients. It does not reload the page, disconnect RTC rooms, or tear down calls.
- Control mutations are limited to `operator`/`owner`; viewers can inspect service/banner state without mutating it.
- Banner and control mutations are written to the existing privacy-safe operator audit log.

## Database and concurrency

- Migration 30 adds normalized `global_banners` and `instance_settings` tables plus indexes for active-window and recent-admin queries.
- Banner edits lock the target row before merging/updating state so concurrent operators cannot silently overwrite based on the same stale record.
- Banner IDs, schedule windows, severity values, body/title lengths, links, boolean types, and timestamp types are validated server-side. Invalid end times never silently become permanent announcements.
- Admin-mutating DB requests are classified as writes for reconnect/retry behavior rather than retryable pure reads.

## Erlang compiler fixes

The 1.8.0 admin work exposed Erlang single-assignment mistakes under `erlc`. 1.8.1 fixes them directly:

- enrollment creation uses `ExistingRoleValue` and `EffectiveRole` instead of reusing unsafe `Role` bindings;
- enrollment redemption marks the unused enrollment-role column as `_EnrollmentRole`;
- audit pagination uses independent `LimitI` and `BeforeI` bindings rather than reusing `I` across `case` expressions.

The source verifier and admin contract now contain explicit regression checks for those exact patterns so a source-only build cannot accidentally reintroduce the known compile failures.

## UI

- Service controls use the existing Plainwire charcoal/neutral control-plane style rather than a separate visual system.
- Banner management is responsive on narrow screens and keeps destructive actions explicit. Malformed date fields are rejected in-place rather than falling back to a permanent banner.
- Main-client banners reserve layout space instead of covering the app, account for mobile safe areas, and preserve existing navigation/call UI behavior.

## Privacy

The control plane remains communication-content blind. The new announcement `body` belongs to operator-authored service announcements; no new query or endpoint reads user message bodies, DM text, attachment contents, or message search data.
