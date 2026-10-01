# Reporting and moderation

Plainwire 2.6.4-1 adds an instance-wide reporting system. Users submit cases; service owners and operators review them through the separate host control panel. Per-server roles do not grant access to the host report queue.

## Submit and track

Right-click a person and choose **Report user**, or right-click their message and choose **Report message**. On touch screens, use the existing press-and-hold context menu. Select a category and add a reason, screenshots, or both. Categories cover harassment, hate, threats, spam, scams, privacy violations, impersonation, and other concerns.

Screenshots show a preview before submission. Review them for unrelated private information. From a message menu, an unchecked option lets you deliberately share a copy of that one message. The server verifies the reported author, current access, and that the message is text and has not been deleted. Nearby messages are never copied. A reporter who has blocked the person can still report the account from the user menu without linking a now-inaccessible message.

**My reports** is available in the Workspace menu, your own user menu, and the report form. It shows status, the submitted reason/screenshots, and any public reviewer response. Open and under-review cases can be withdrawn. Review notes, assignment, and other people's reports are not exposed.

## Review workflow

The admin **Reports** view identifies both the reporter and reported account. Reviewers can filter the queue, assign themselves, set priority, add private notes, resolve, dismiss, or reopen resolved/dismissed decisions. Threat reports start at high priority. Closing or reopening requires an internal note. A public response is optional and is shown only to the reporter. Withdrawn cases cannot be reopened.

Cases assigned to another reviewer are read-only to operators; owners can take them over. A reviewer cannot access a case they submitted or a case about their own account. Viewers have no report access. Every request rechecks durable roles and account eligibility; edits carry an expected revision, returning HTTP 409 when another action changed the case.

Assigned cases can invoke the existing instance-wide suspend, ban, or disable action. The account restriction, session revocation, action record, and case resolution commit together. Existing owner/operator/self protections still apply. The affected account sees a separately entered moderation reason; the reporter's identity and evidence are not automatically copied into it. No restriction happens just because a report was filed.

## Limits and evidence storage

- At least a reason or screenshot is required. Reasons and internal notes accept up to 4,000 Unicode characters; public responses accept up to 1,000.
- Up to three PNG or JPEG screenshots, 5 MiB each. Only ready uploads owned by the reporter are accepted. File signatures and image dimensions are checked; SVG/HTML, oversized images, corrupt upload hashes, duplicate references, and somebody else's uploads are denied. Dimensions are capped at 8,192 per side and 33,554,432 pixels.
- At most five new reports per account in a rolling 24 hours. A per-account PostgreSQL transaction lock protects that limit and idempotency across workers/nodes. The HTTP submission limiter also restricts bursts. Bot accounts cannot file reports; self-reports are denied.
- A `request_key` makes an unchanged retry return its original case. Reusing the key for a different payload returns HTTP 409. The UI retains successfully uploaded screenshot IDs on retry and keeps chat drafts untouched.
- Screenshot bytes are copied into PostgreSQL, so later deletion of the normal upload does not remove review evidence. Reports grant no additional access to general upload URLs. Evidence is delivered only from authenticated, case-scoped endpoints with private/no-store, MIME, and browser security headers.
- Reasons, message copies, notes, custom public responses, and screenshot copies honor the configured content encryption key and previous-key rotation. Metadata and content hashes remain metadata. Production requires an encryption key; development without one stores content as plaintext, as existing content storage does.
- Retained screenshot storage is capped at 32 MiB per reporter and 512 MiB instance-wide by default, counting stored bytes including encryption overhead. A failed reservation rolls back the whole submission. Text-only reports remain available when screenshot capacity is exhausted.

`PLAINWIRE_REPORT_EVIDENCE_BUDGET_BYTES` sets the instance budget, bounded between 5 MiB and 10 GiB. `PLAINWIRE_REPORT_EVIDENCE_RETENTION_DAYS` sets closed-case evidence retention, default 90 days and bounded between 7 and 365. A background sweep handles up to 100 eligible closed cases per minute. It deletes screenshot copies and submitted message snapshots, updates storage accounting and revisions, and preserves reasons, identity snapshots, decisions, and case history. Open cases retain evidence until closed; reopening after a purge does not restore expired evidence. Database backups may retain older copies under the operator's backup policy.

The feature adds PostgreSQL migration 54. Reporting stays in PostgreSQL even when message history uses ScyllaDB. Standard startup applies the migration. No new external service is required. The control panel must be enabled to review reports; users can submit and track cases while it is disabled.

## HTTP contracts

Normal authenticated API:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/reports/config` | Categories and submission/retention limits |
| GET | `/api/reports?before=&limit=` | Current user's reports; bounded ID cursor pagination |
| POST | `/api/reports` | Submit `user_id`, `category`, `reason`, `evidence_ids`, `request_key`, optional `message_id` and `include_message` |
| POST | `/api/reports/:id/withdraw` | Withdraw own active case with `expected_revision` |
| GET | `/api/reports/:id/evidence/:evidence_id` | Read own submitted screenshot |

Separate admin API, owner/operator only:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/reports` | Queue with `status`, `priority`, `assigned`, `q`, `before`, `limit` |
| GET | `/api/reports/:id` | Submitted content, screenshot metadata, latest 100 history entries |
| POST | `/api/reports/:id` | `action`, `expected_revision`, and action-specific `note`, `priority`, `resolution`, `public_response` |
| GET | `/api/reports/:id/evidence/:evidence_id` | Read the exact submitted screenshot |

Linked account restrictions use the existing `/api/users/:id/moderation` with `report_id` and `report_revision`. Only ban/suspend/disable can be linked. Mutations require the appropriate session and CSRF token. Case views, evidence reads, and case actions are recorded in the content-free operator audit; submitted text and private notes remain in the case store.
