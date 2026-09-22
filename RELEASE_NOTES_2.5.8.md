# Plainwire 2.5.8

2.5.8 retries an SMTP login as the From mailbox. It carries no database
migration and no new environment variables. Installs on 2.5.7 can upgrade
directly.

## Login was still rejected

Proton accepts the SMTP token only for the custom-domain address it was
created for. A username at proton.me, protonmail.com, or pm.me is refused
even when the password is that token. If `PLAINWIRE_SMTP_FROM` is a different
mailbox, the rejected login is tried once as that mailbox. The same username
and password are not sent twice.

A username written as `Name <box@domain>` is sent as `box@domain`. Quotes,
line breaks, and invisible characters copied with the token are removed
before the login.

When every configured address is a Proton consumer address, the dialog says
so. That login cannot succeed until the username is the custom-domain address
the token was created for.
