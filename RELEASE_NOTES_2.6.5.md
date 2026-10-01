# Plainwire 2.6.5

## Profile reporting and evidence controls

- Choose **Report user** on a full profile or server profile, including blocked accounts. Your own profile offers **My reports**.
- Paste PNG/JPEG screenshots into the report form, preview them, and remove individual screenshots before submitting. Invalid additions preserve the current selection.
- Reporting retains the existing backend permissions, evidence validation, case workflow, retry keys, and private review boundaries. No new database migration is needed beyond migration 54.

## Call window fixes

- Fixed mouse-first resizing followed by minimizing leaving a giant call bar. The observer now tracks the live Elm body, and expanded dimensions no longer apply to the reused compact element.
- Added **Reset window** beside audio tools. Keyboard resizing, saved dimensions, viewport bounds, and desktop position restoration remain available.
- Hiding and showing a shared screen preserves its expanded height, including viewport changes while hidden.
- Desktop call controls remain accessible over overlapping shared-screen windows; dialogs and context menus appear above call windows.
- Switching to a phone layout preserves desktop preferences. Position updates avoid mutation feedback loops, and drag click suppression expires immediately after the gesture.

## Security and moderation reliability

- Private attachments require revalidation before browser cache reuse and vary by session cookie. File authorization still runs before conditional, range, and HEAD responses. Previously downloaded or cached copies cannot be recalled.
- Admin authentication requests disable caching and have a timeout. Session changes reject late responses; expiry clears account/case content and dialogs.
- Delayed account/server details cannot reopen dismissed dialogs. Every admin view checks its request generation before rendering, preventing old lists or searches from overwriting the selected view. Admin modal backgrounds are inert.
- Upload authentication outages return retryable HTTP 503 instead of telling clients they are unauthenticated.
- Reported account IDs outside PostgreSQL's integer range are rejected before database work; 64-bit message IDs remain supported.

## Validation

Release validation runs `make check`, including the real PostgreSQL authorization/reporting tests, real HTTP private-download tests, browser/security/reporting/moderation regressions, responsive settings, and real WebRTC audio/video tests. CI also exercises the load harness and Gleam scalability model before source archive construction. The new mouse-first regression failed on the previous implementation.

See [the audit record](docs/SECURITY_AUDIT_2.6.5.md) for scope, fixes, and remaining limits.
