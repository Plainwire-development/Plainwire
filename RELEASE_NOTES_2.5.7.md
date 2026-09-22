# Plainwire 2.5.7

2.5.7 fixes SMTP login for verification mail. It carries no database migration
and no new environment variables. Installs on 2.5.6 can upgrade directly.

## Login was rejected

After STARTTLS, the server answered AUTH with `535 authentication failed`.
Two client mistakes produce that response even when the token itself is right.

Environment files often store the token in quotes. Those quote characters were
sent as part of the password. A line break inside the value was sent as well,
which splits the AUTH command. Quotes around the username or password are now
removed, and CR/LF inside either value is removed, so the token is one line.

If the SMTP username is not an email address and `PLAINWIRE_SMTP_FROM` is, a
rejected login is tried once more as that mailbox. The same username and
password are not sent twice.

Proton still rejects a mailbox password. The username has to be the custom-domain
address the SMTP token was created for, and the password has to be that token.
