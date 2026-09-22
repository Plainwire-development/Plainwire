# Plainwire 2.5.2

2.5.2 is a mail-delivery patch. It carries no database migration and no API or
protocol change; installs on 2.5.1 can upgrade or skip it freely. It only
affects instances that send mail — password reset and email verification — so
self-hosted deployments with mail disabled are unchanged.

## SMTP authentication

Two faults in the SMTP client shared one root cause. `command/3` reported an
unexpected reply as `{smtp, Code}`, while `expect/2` and `ehlo/1` reported
`{smtp, Code, Lines}`. The clauses in `smtp_auth/3` were written against the
three-element form, so none of them could ever match and every outcome fell
through to a catch-all that retried `AUTH LOGIN`.

**A rejected credential was retried instead of abandoned.** When a provider
answered `AUTH PLAIN` with 535, the intended stop was unreachable, so the
client immediately tried `AUTH LOGIN` with the same secret. One misconfigured
password therefore spent two failed authentication attempts per message, for
every message in the queue — up to four deliveries in flight plus a 64-deep
backlog. Providers that count failures toward a lockout saw twice the traffic
they should have. The client now stops on 535 and reports the rejection.

**A dropped connection was reported as an authentication failure.** Transport
errors reached the same catch-all, were wrapped as `{smtp_auth, Reason}`, and
were then flattened to `smtp_auth_failed` by the log redactor. A network fault
during the authentication exchange was indistinguishable in the log from a bad
password, which pointed operators at their credentials instead of the network.
Transport errors now propagate unchanged and name the real fault.

Fallback to `AUTH LOGIN` still happens for the case it was meant for: a server
that refuses `AUTH PLAIN` because it does not offer it (504, 534, and other
SMTP-level refusals). The rejection text for a 535 stays out of the log, as the
redactor already did for the wrapped form.

## Release verification

The SMTP session had no test coverage below `compose/1`: the suite checked
configuration gating and message composition, and nothing exercised the wire
protocol, which is where both faults lived. `pw_mail_tests` now runs a fake
SMTP server on loopback and drives `smtp_send/1` against it, covering the
successful transcript end to end (EHLO, AUTH PLAIN, MAIL/RCPT/DATA, dot
stuffing of a lone `.` in the body, QUIT), the 535 stop, the `AUTH LOGIN`
fallback, the refusal to authenticate when TLS is required but never offered,
and the transport-error path. Both faults fail these tests before the fix.
