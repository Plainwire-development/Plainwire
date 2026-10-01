# Plainwire 2.6.5 audit record

This pass reviewed profile and message reporting, evidence ownership and storage, report/reviewer permissions, private file serving and upload authentication, admin request lifecycles, call geometry and media lifecycles, and existing authentication, CSRF, media proxy, plugin, and rendering protections. Regression suites verify those boundaries; this is not a claim that every vulnerability has been ruled out.

## Findings corrected

| Finding | Impact | Correction and coverage |
| --- | --- | --- |
| Private attachments used a one-day immutable browser cache | A shared browser could reuse a previously permitted response after account switching or access revocation without contacting the authorization boundary | Private/no-cache/must-revalidate with Cookie variation; real Cowboy tests cover conditional/range/HEAD reads before and after ACL invalidation |
| Admin views and account/server detail loads lacked consistent generation checks | A delayed response could overwrite another view or restore dismissed moderation controls, increasing the chance of acting on the wrong account | Request generations checked before rendering; immediate loading dialogs, retry controls, and stale-response browser regressions |
| Admin expiry left private DOM content and dialogs behind | Sensitive account/case data could remain visible on the login screen | Forced dialog closure and content clearing on expiry; auth generations checked before and after JSON decoding; browser expiry regression |
| Call geometry observed a mount element replaced by Elm | The first pointer resize left large inline dimensions on the reused compact bar | Observe the live body; CSS consumes dimensions only in expanded mode; first-pointer test reproduces the old defect and covers minimize/restore/reset |
| Hidden screen viewers saved their collapsed title-bar height as the expanded size | Showing or reopening a share could shrink the viewer unexpectedly | Ignore hidden resize notifications and preserve expanded geometry when moving/reflowing the collapsed bar; hide/resize/show RTC regression |
| Shared-screen windows could cover call controls; call windows could cover dialogs/menus | Controls became unclickable when utility windows overlapped | Ordered utility, call, dialog, and menu layers; real RTC share-replacement and group invitation controls remain clickable |
| Mobile geometry reset erased the in-memory desktop position | Returning from a narrow viewport lost the user's saved desktop placement | Temporary mobile resets retain preferences; desktop/mobile/desktop RTC regression |
| Upload database outages returned HTTP 401 | Retrying users could be treated as logged out during a temporary database outage | HTTP 503 for unavailable authentication authority; real HTTP test |
| Reporting accepted oversized account IDs | Integer conversion/database exceptions produced avoidable server errors | Account IDs bounded to PostgreSQL integer range; unit validation preserves 64-bit message IDs |
| Invalid evidence selection discarded valid selections | Users lost carefully chosen evidence when adding an unsupported file | Atomic validation of additions, per-image removal, clipboard input, and browser coverage |

No new general attachment access is granted by profile reporting. Existing report evidence endpoints remain authenticated, case-scoped, private/no-store, and unavailable to viewer operators or reviewers with a conflict of interest. Only explicit message-sharing consent includes message contents.

## Validation and limits

`make check` is the release gate. PostgreSQL tests run with a live database rather than skipped fixtures. Added HTTP tests exercise the real file handler with cached identity/ACL fixtures. Browser tests use the built Elm application with fixture APIs; RTC tests use real peer connections and media. CI includes responsive settings and admin moderation tests alongside the existing load and source archive checks.

Revalidation prevents future cache reuse from bypassing access checks; it cannot erase a file already downloaded, an image already displayed, or an older response cached under the previous release's policy. Operators must continue to protect database backups, deploy the admin listener behind its documented boundary, keep encryption/TURN configuration current, and manage evidence retention. This pass does not constitute an external penetration test of a deployed instance or a full dependency provenance review.
