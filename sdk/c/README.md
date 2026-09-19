# Plainwire Bot SDK for C

The C SDK is a small libcurl transport for Plainwire Bot API v1. It performs verified HTTPS, rejects remote plaintext HTTP, never follows redirects, caps response bodies and uses bounded timeouts. It returns response JSON as owned UTF-8 bytes so applications can use the JSON library they already ship.

Build:

```sh
cmake -S . -B build
cmake --build build
```

Environment:

```sh
export PLAINWIRE_BASE_URL=https://chat.example.com
export PLAINWIRE_BOT_TOKEN=pwb_...
```

`http://127.0.0.1`, `http://[::1]` and `http://localhost` are accepted for local development only.

The durable command methods are `pw_bot_claim_commands`, `pw_bot_respond_command` and `pw_bot_fail_command`. A claim token is secret and valid only for its current lease. Do not persist or log it.
