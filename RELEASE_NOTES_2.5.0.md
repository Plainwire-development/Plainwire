# Plainwire 2.5.0

2.5.0 is an operator and reliability release. Existing installs apply database migration 53 on startup. PostgreSQL stays required. Redis and ScyllaDB stay optional.

## Host control plane

Owners and operators can do more from the existing user moderation action, `POST /api/users/:id/moderation`. There is no second admin API.

* **Disable** locks an account with a user-facing reason. A correct password does not turn it back on. That is separate from someone disabling their own account, which still reactivates on the next correct password.
* **Restore** clears a suspend, ban, or operator disable.
* **Sign out everywhere** deletes that account's Plainwire sessions and control-plane sessions without changing `account_state`. Connected clients reload. The cluster event is `sessions_revoked`.
* **Reset display name** sets the display name back to the username.
* **Remove email** clears the address and outstanding verification tokens. The panel still does not show the address.
* **Resend verification** queues a message only when mail is enabled on that host, and it is rate-limited. The token is not returned to the browser.

The user detail shows recent account state: updated time, disabled time, whether an email is on file, whether it is verified, and the active session count. Viewers still cannot mutate. Operators still cannot change their own account, another operator, or an owner. There is no password tool and no impersonation control.

## Calls and voice

A voice or call seat is registered before other participants are told someone joined, so an offer that races the roster is not dropped into a silent pair. Roster snapshots (`voice_state` and `call_state`) are no longer discarded when the realtime path is shedding load. The client plays cues for joining, leaving, and someone starting to watch a screen share. An outgoing call names the people still being waited on. It does not show the caller as the person being called.

## Notifications and unread

Ordinary channel messages no longer insert an inbox row for every member. Mentions still do. Opening a DM, channel, or thread deletes the matching notification URL instead of only marking it seen. Categorized channel rows show the same mention count as uncategorized rows. A direct-message transcript can show a “New messages” divider at the first unread entry.

## Self-hosting

Erlang/OTP 29 is supported. OTP 29 runs `erl -s init stop` before `-eval`, which used to abort the erlcass compile hook before any Plainwire beam existed. `scripts/compile-erlcass.sh` removes that flag. A missing Scylla native driver still does not block a PostgreSQL build. Install and run steps are in the README and `deploy/README.md`. The host control plane is documented in `docs/ADMIN.md`.

## Other corrections

* A well-formed encrypted value that fails authentication is not returned as plaintext.
* Outgoing mail strips CR/LF from headers and dot-stuffs body lines.
* A media `HEAD` does not download the origin on a cache miss.
* Another member's profile no longer includes their email address.
* A friend request cannot rewrite an accepted or blocked pair back to pending.
* A failed block lookup fails closed.
* Channel pin inserts lock the channel so two messages cannot both slip past the cap.
* A storage-outbox worker cannot mark a row delivered after another worker has reclaimed the lease.
* Scylla message writes, edits, deletes, and privacy erases carry timestamps so an older retry cannot beat a newer edit or an erase.
