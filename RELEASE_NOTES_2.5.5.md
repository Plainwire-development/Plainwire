# Plainwire 2.5.5

2.5.5 is a release-check patch. It carries no database migration, no new
environment variables, and no mail or API behavior change from 2.5.4. Installs
on 2.5.4 can upgrade or skip it freely.

## Browser check

Operator resend now says "Verification email sent" after the mail server
accepts the message. The admin browser check still waited for "Verification
email queued", so `make check` failed on the 2.5.4 tag. The check matches the
toast the control plane shows.
