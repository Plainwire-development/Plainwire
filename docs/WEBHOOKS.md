# Server webhooks

Plainwire 2.0 server webhooks deliver selected server events to HTTPS endpoints. They are managed by the **Manage webhooks** role permission.

Webhook configuration and delivery attempts are durable in PostgreSQL. The dispatcher claims pending deliveries with row locking, sends them with Gun and records success or retry state. Multiple workers cannot claim the same delivery at the same time.

Outbound URLs are checked by Plainwire's outbound URL policy before they are accepted. Delivery follows the same policy rather than treating a saved URL as permanently trusted.

## Signing

Every delivery includes a per-webhook secret and a Plainwire signature header. Rotate the secret if it is exposed; rotation does not require recreating the webhook.

Useful delivery headers include the event name, delivery id and signature. Consumers should verify the signature over the raw request payload before processing it.

## Reliability

A webhook is not part of the message commit path. Plainwire records the webhook delivery after the underlying durable action and dispatches it separately. A slow or unavailable webhook therefore cannot make chat sending wait on a third-party server.

Failures are retried from durable delivery state. A dispatcher crash can leave a short lease behind; expired leases are re-queued instead of becoming stuck forever.
