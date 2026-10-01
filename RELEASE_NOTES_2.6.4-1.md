# Plainwire 2.6.4-1

2.6.4-1 adds user reports with screenshot evidence and an admin moderation case workflow. It includes PostgreSQL migration 54, applied automatically at startup. Installs on 2.6.4 can upgrade directly; no additional service is required.

## Reporting

- Report a person or message from its context menu, including touch press-and-hold. Select a category and provide a reason, up to three PNG/JPEG screenshots, or both. Screenshots show previews and are limited to 5 MiB each.
- Sharing a message is an explicit, unchecked option. The backend verifies access and the reported author and copies only that message. Normal conversations remain unavailable to admin operational views.
- My reports tracks case status and public reviewer responses and allows withdrawing active cases. Uploads stay out of the chat composer and preserve drafts. Retry keys prevent duplicate cases after ambiguous network failures.

## Moderation cases

- Owners and operators get a report queue with both identities, status/priority/assignment filters, username search, bounded pagination, screenshots, optional message context, and case history. Viewers cannot access reports.
- Reviewers can assign cases, set priority, write internal notes, resolve, dismiss, and reopen decisions. Internal notes and reviewer assignments remain private. Conflicts of interest exclude cases filed by or about the current reviewer; revision checks reject stale edits.
- Linked suspend, ban, and disable actions resolve the case atomically with the account restriction and session revocation. Existing account protections remain enforced. Reports do not automatically restrict accounts.
- Reasons, message snapshots, review notes, custom reporter responses, and screenshot copies honor the configured content encryption key. Evidence copies survive deletion of the original upload and are accessible only from case-scoped authenticated endpoints.
- Submission limits and transactional storage budgets bound abuse. Closed-case screenshots and message snapshots expire after 90 days by default, with configurable retention and a bounded background sweep. Case reasons and review history remain. Default screenshot storage is 32 MiB per reporter and 512 MiB instance-wide, including encryption overhead.

## Validation

Validation passed `make check` with 267 backend tests, including executable PostgreSQL authorization, rollback, encryption, retention, pagination, and quota regressions. Reporting browser workflows and existing UI, security, responsive admin/settings, and real WebRTC tests all passed. GitHub CI now runs the PostgreSQL-backed tests as well as reporting browser regressions. The portable source archive and its SHA-256 checksum are verified before publication.

See [reporting and moderation](docs/REPORTING.md) and [admin operations](docs/ADMIN.md) for workflows, privacy boundaries, retention, configuration, and API details.
