# Server webhooks

Plainwire 2.2 supports two server-scoped webhook models. Both are managed with the **Manage webhooks** role permission.

- **Outbound webhooks** send signed Plainwire events to your HTTPS service.
- **Incoming webhooks** give an external service a revocable URL that can post messages into one selected text channel.

Bots are still the better choice for interactive applications that need to read messages, react, register commands or maintain realtime subscriptions. Incoming webhooks are intentionally write-only.

## Outbound webhooks

Webhook configuration and delivery attempts are durable in PostgreSQL. The dispatcher claims pending deliveries with row locking, sends them with Gun and records success or retry state. Multiple workers cannot claim the same delivery at the same time.

Outbound URLs are checked by Plainwire's SSRF-aware outbound URL policy both when saved and when delivered. Redirect targets are revalidated. Saved hostnames are not treated as permanently trusted after DNS changes.

### Events

2.1 can deliver these server events:

- `message.created`
- `message.updated`
- `message.deleted`
- `message.reaction`
- `message.pinned`
- `message.unpinned`
- `member.joined`
- `member.removed`
- `member.banned`
- `member.unbanned`
- `channel.created`
- `channel.updated`
- `bot.added`
- `bot.removed`
- `server.updated`

`webhook.test` is generated only by the Test action and does not need to be selected in the event list.

### Signing

Every delivery includes a per-webhook secret and an HMAC-SHA256 signature over the exact raw JSON body. Useful headers include:

```text
x-plainwire-event
x-plainwire-delivery
x-plainwire-signature
```

Verify the signature before decoding or acting on a delivery. Compare signatures in constant time. Rotate the signing secret if it is exposed.

New and rotated signing secrets are encrypted at rest with Plainwire's AES-256-GCM instance encryption key. Existing plaintext 2.0 secrets remain readable during an upgrade and become encrypted the next time they are rotated.

### Reliability and delivery history

A webhook is not part of the message commit path. Plainwire records the delivery after the durable action and dispatches it separately. A slow or unavailable receiver cannot make chat sending wait on a third party.

Failures use bounded exponential retry. The Integrations panel shows recent delivery metadata including status, attempts, HTTP status and sanitized error information. It never exposes the request payload or signing secret.

2.1 keeps failed delivery payloads encrypted until the failed-delivery retention period expires. This permits an operator to explicitly retry a permanently failed delivery without keeping private message payloads in plaintext. Successful payloads are erased after delivery. Account privacy deletion removes queued deliveries associated with the deleted account.

Legacy failed deliveries whose payload had already been erased cannot be retried. Plainwire reports this as `retry_payload_unavailable` instead of inventing a payload.

## Incoming channel webhooks

Create an incoming webhook under **Server settings -> Integrations** and choose a text channel. Plainwire shows the credential-bearing URL once:

```text
https://plainwire.example/api/webhooks/123/pwi_your_secret_token
```

Treat the complete URL like a password. Plainwire stores only a SHA-256 hash of the token and compares the presented credential against the stored hash in constant time.

Post JSON to the URL:

```json
{
  "content": "Build 418 passed"
}
```

A reply can optionally be targeted by message id:

```json
{
  "content": "The deployment for this build is complete.",
  "reply_to_id": 992817331840
}
```

Incoming webhooks deliberately do not accept existing Plainwire upload references. Upload authorization belongs to signed-in users and bot applications, not a bearer URL.

The credential is write-only. A successful request returns only the newly created message id, destination channel id and timestamp. It does not return channel history or the body of a replied-to message.

Incoming webhook messages use a dedicated server-scoped bot identity, so they receive the normal bot badge in chat. Rotating the URL invalidates the previous token immediately. Deleting the webhook disables and removes its automation identity from the server while preserving historical messages.

### Rate limits

Plainwire applies both a shared per-webhook limit and a per-webhook/per-source-IP limit. This prevents one source from flooding a hook and prevents distributed callers from multiplying the limit simply by changing IP addresses.

## Retention and secrets

Do not place bot tokens, webhook URL credentials, authorization headers or signing secrets inside webhook payloads or application logs.

Relevant retention settings include:

```text
PLAINWIRE_WEBHOOK_DELIVERED_RETENTION_DAYS
PLAINWIRE_WEBHOOK_FAILED_RETENTION_DAYS
PLAINWIRE_WEBHOOK_TIMEOUT_MS
PLAINWIRE_WEBHOOK_WORKER_TIMEOUT_MS
PLAINWIRE_WEBHOOK_CONCURRENCY
```

Delivered payloads are erased immediately after success. Failed payloads are encrypted at rest and are removed by retention pruning.
