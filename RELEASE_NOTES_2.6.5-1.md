# Plainwire 2.6.5-1

## Report queue visibility

- Fixed reports appearing to be missing when the reporting user and signed-in admin are the same account. Owners and operators now see their own submissions as clearly marked, read-only cases.
- Own cases expose submitted reasons and screenshots, status, and public responses. Internal notes, reviewer assignment, priority, resolution codes, and message context remain private. Priority and assignment filters exclude own cases to prevent inference of hidden review metadata.
- Another owner or operator must review the case. Backend guards still reject all own-case review edits and linked account restrictions. Reports about the signed-in reviewer remain hidden, and viewers cannot open reports.

## Queue refresh

- The visible Reports view now checks for updates every five seconds, including while a case or filter field is open. Updates preserve draft notes, open dialogs, and unapplied filter text.
- Added **Refresh reports** for an immediate check. Temporary refresh failures retain the current queue, display a retry message, and retry automatically. Filters and older-page cursors still apply.
- Submission already saves the report before returning success; this patch fixes visibility and queue refresh. It does not require another database migration beyond migration 54.

## Validation

`make check` passed, including 269 backend tests with real PostgreSQL and the full browser, security, responsive-layout, admin moderation, and WebRTC suites. Reporting regressions cover own-submission visibility, private-field isolation, filter inference prevention, own-case mutation and linked-action rejection, subject exclusion, reviewer access, and screenshot authorization. Browser regressions cover new submissions arriving with focused filters and open note drafts, refresh failure recovery, same-account read-only cases, reviewer workflows, and viewer isolation, alongside the existing full release suite.
