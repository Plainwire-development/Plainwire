# Plainwire 2.5.4

2.5.4 is a release-check patch. It carries no database migration, no new
environment variables, and no mail or API behavior change from 2.5.3. Installs
on 2.5.3 can upgrade or skip it freely.

## Source check

The 2.5.3 admin contract still required operator verification mail to call
`pw_mail:send/1` and report success immediately. That path now waits until the
SMTP server accepts the message and sets `email_delivery` from the result.
`make check` failed on the 2.5.3 tag because of that stale expectation. The
contract matches the awaited send, so a source check of this release passes.
