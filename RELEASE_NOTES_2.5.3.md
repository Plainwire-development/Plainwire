# Plainwire 2.5.3

2.5.3 is a mail-delivery patch. It carries no database migration and no new
environment variables. Installs on 2.5.2 can upgrade or skip it freely. It only
affects instances that send mail, so deployments with mail disabled are unchanged.

## Verification mail was accepted by the client and dropped by the server

Verification and password-reset messages could fail after Plainwire had already
told the user to check their inbox.

The SMTP session closed the original TCP socket after STARTTLS. The live
connection is the TLS socket; closing the socket underneath it resets the
session, and some servers discard a message when that happens. The client now
closes the socket that actually carried the message.

A server that answers `AUTH PLAIN` with 334 is waiting for the SASL payload on
the next line. The client treated that as a refusal and sent `AUTH LOGIN` in
the middle of the exchange, so authentication never finished. A 334 now
continues the PLAIN exchange. A 535 still stops, and is still not retried as
LOGIN.

`Message-ID` was `<random@plainwire>`, which is not a real domain. Receivers
that require a valid message id drop or spam-folder those messages. The id now
uses the domain of the From address.

The body was always sent as 8bit, including to servers that never advertised
8BITMIME. ASCII messages are 7bit. Anything else is quoted-printable.

If `MAIL FROM` is rejected because it does not match the authenticated mailbox,
the client retries the envelope and the header with `PLAINWIRE_SMTP_USER`. No
new setting is required.

A dropped connection or a transient SMTP reply (421, 450, 451, 452) is retried
once. Authentication failures are not.

Reads wait for a chunk instead of one byte at a time, so a normal delivery is a
handful of socket reads rather than one per character.

## The API no longer claims a message was sent when it was not

Setting or resending an email waits until the SMTP server accepts the message.
The response `email_delivery` is true only then. Password reset stays
asynchronous and still answers the same way whether or not an account exists.
The email dialog and the operator resend action say so when the server refuses
the message, instead of asking someone to check an inbox that will stay empty.
