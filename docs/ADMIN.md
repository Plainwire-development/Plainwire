# Host control plane

The control plane administers one Plainwire instance. Operational views cannot browse messages, private conversations, arbitrary attachments, or email addresses. The Reports view exposes only reasons and evidence explicitly submitted for moderation, including opt-in copies of individual messages.

It is off until you enable it. The listener is separate from the public Cowboy listener and defaults to loopback.

```sh
PLAINWIRE_ADMIN_ENABLED=true
PLAINWIRE_ADMIN_BIND=127.0.0.1
PLAINWIRE_ADMIN_PORT=8090
```

Open `http://127.0.0.1:8090`. The first owner uses the one-time bootstrap token printed at startup plus their normal Plainwire password. After that, each operator has an instance-bound verification key. Cloning the source tree does not copy a working key: each deployment creates its own instance secret.

## Roles

| Role | What it can do |
| --- | --- |
| viewer | Overview and host health only |
| operator | Inspect accounts, servers, operators, and audit. Review submitted reports. Change account access and service controls |
| owner | Everything an operator can do, plus operator enrollment, role changes, and removal |

Viewers cannot open the account, server, operator, audit, or report views. Mutating requests need the operator session cookie and the `x-csrf-token` header. Operators cannot change their own account, another operator, or an owner. An owner cannot disable another owner.

## Account actions

Open Users, search by username or display name, and select the row. The detail shows recent account state: created, updated, last seen, disabled time, whether an email is on file, whether that email is verified, session count, and moderation history. It does not show the email address.

These buttons call `POST /api/users/:id/moderation`. They are recorded in the operator audit and in that account's action history.

* **Suspend** and **Ban** require a user-facing reason. They set `account_state` to `suspended` or `banned`, revoke Plainwire sessions and control-plane sessions, and tell connected clients. A correct password does not clear them. An optional expiry restores the account on the next login after that time.
* **Disable** is the operator form of a lock. It also requires a reason, sets `account_state` to `disabled`, and does not clear when the person types their password. That is different from the account setting where someone disables their own account: a self-disable has no operator reason and the next correct password turns it back on.
* **Restore access** sets the account back to `active` and clears the operator reason.
* **Sign out everywhere** deletes Plainwire sessions and control-plane sessions for that account. The account state stays as it was. Confirm it before sending.
* **Reset display name** sets `display_name` to the username. It does not change the password or the username.
* **Remove email** clears the address and outstanding verification tokens. The panel never displays the address.
* **Resend verification** queues a verification message only when mail is enabled on this host (`PLAINWIRE_MAIL_ENABLED` and SMTP, or the official `plainwi.re` host with SMTP). It is rate-limited. The one-time token is not returned to the browser.

There is no control that shows or sets a password, and no control that signs the operator in as another user.

## Report review

Open **Reports** to see who reported an account, the reported identity, category, status, priority, and assignment. Filter by status, priority, assignment, or either username. The visible queue checks for new reports every five seconds, including while a case or filter input is in use. Background updates preserve open notes and unapplied filter text; **Refresh reports** checks immediately. New submissions are saved before the submission request succeeds. Filters and older-page cursors may hide new cases. Pagination is bounded to 30 cases in the UI and at most 50 through the API.

Assign the case to yourself, inspect submitted screenshots and any deliberately shared message copy, and add internal review notes. Owners can take over another reviewer's assignment. Operators cannot modify a case assigned to somebody else. Reporters see their own status and an optional public response, never internal notes or reviewer identity. Your own submissions appear as read-only cases without internal notes, assignment, priority, resolution codes, or message context; another owner or operator must review them. They are shown only with **All** priority and assignment filters to prevent those filters revealing hidden review metadata. Cases about your own account stay hidden.

Resolve or dismiss with an outcome and a required internal decision note. Closed decisions can be reopened with a note; withdrawn cases stay withdrawn. From an assigned case, **Suspend account**, **Ban account**, and **Disable account** use the existing account restrictions and resolve the case in the same transaction. A failure rolls back both. Enter a separate reason for the affected user without identifying the reporter. Existing protections for owners, operators, and self-moderation apply. Reports do not automatically establish a violation or change account access.

Case actions, case access, and screenshot access enter the operator audit without copying submitted content into that audit. See [REPORTING.md](REPORTING.md) for limits, storage, privacy, and endpoint contracts.

## Service controls

Operators can publish, pause, and delete global banners, force registration open or closed without a restart, and ask connected clients to reconcile server state. Reconciliation does not drop calls. Banners are capped in the client and only allow same-origin or HTTPS links.

## Remote access and recovery

Prefer a private admin hostname behind HTTPS. A production bind that is not loopback requires `PLAINWIRE_ADMIN_ALLOW_REMOTE=true`, an `https://` `PLAINWIRE_ADMIN_PUBLIC_URL`, and secure admin cookies. Do not enable `PLAINWIRE_ADMIN_LOCAL_RECOVERY` on a non-loopback bind; Plainwire refuses to start. Local recovery is a one-time host-console token, and it revokes existing admin sessions.

Back up `admin-instance.key` with PostgreSQL. Losing the last owner key can only be recovered by someone who can restart that host.
