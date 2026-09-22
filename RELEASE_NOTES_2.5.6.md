# Plainwire 2.5.6

2.5.6 fixes verification mail on the normal STARTTLS port. It carries no
database migration and no new environment variables. Installs on 2.5.5 can
upgrade directly.

## STARTTLS never submitted the message

Port 587 upgrades the plain connection with `ssl:connect`. That call defaults
to an active socket. The SMTP reader then calls a passive receive, which
returns `einval` before `MAIL FROM` is sent. The address was saved, and the
dialog reported that the mail server did not accept the message.

The upgraded socket is now passive and binary, which is what the reader
expects. Certificate verification is unchanged. A direct STARTTLS handshake to
the documented SMTP host completes the second `EHLO` with these options, and
fails with `einval` without them.

If delivery still fails, the dialog names a login rejection, a TLS failure, a
timeout, or an unreachable server instead of using one message for every cause.
