# Plainwire Bot SDK for Erlang

First-party OTP client for Plainwire Bot API v1. It uses Gun for bounded HTTP requests and a separate WebSocket connection for realtime events. Remote instances require verified HTTPS. Plain HTTP is accepted only on loopback.

```erlang
{ok, Bot} = plainwire_bot:start_link(#{
    base_url => <<"https://plainwire.example">>,
    token => os:getenv("PLAINWIRE_BOT_TOKEN")
}),

{ok, Me} = plainwire_bot:me(Bot),
{ok, Caps} = plainwire_bot:capabilities(Bot),
ok = plainwire_bot:subscribe(Bot, <<"channel:42">>),
{ok, Message} = plainwire_bot:send_message(Bot, 42, <<"hello from Erlang">>).
```

Commands are durable. Register a command once, then let one or more workers claim invocations. Each claim has a short-lived one-time token and lease. Responding completes the invocation; `fail_command/4` permanently rejects it.

```erlang
{ok, _} = plainwire_bot:sync_commands(Bot, [#{name => <<"hello">>, description => <<"Say hello">>}]),
{ok, Claims} = plainwire_bot:claim_commands(Bot, 10).
```

Use `defer_command/4` before a long-running handler and `members/2` with `#{after => Cursor, limit => 50}` to traverse large server rosters without loading them all at once.

Realtime events arrive at the owner process as `{plainwire_bot, BotPid, {event, EventMap}}`. The SDK reconnects with bounded backoff and restores subscriptions.
