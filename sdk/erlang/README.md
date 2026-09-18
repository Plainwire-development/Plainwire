# Plainwire Bot SDK for Erlang

A small Erlang SDK for Plainwire 2.0 bots. It uses Gun for the HTTP API and a separate Gun WebSocket connection for realtime events.

Bots authenticate with the one-time `pwb_...` token shown when a server bot is created. Keep it outside source control.

```erlang
{ok, Bot} = plainwire_bot:start_link(#{
    base_url => <<"https://plainwire.example">>,
    token => os:getenv("PLAINWIRE_BOT_TOKEN")
}),

{ok, Me} = plainwire_bot:me(Bot),
ok = plainwire_bot:subscribe(Bot, <<"channel:42">>),
{ok, Message} = plainwire_bot:send_message(Bot, 42, <<"hello from Erlang">>).
```

Realtime events are delivered to the owner process as:

```erlang
{plainwire_bot, BotPid, {event, EventMap}}
```

The SDK reconnects the realtime socket with bounded backoff and restores subscriptions. HTTP and WebSocket traffic intentionally use separate Gun connections because an upgraded HTTP/1.1 connection is dedicated to WebSocket traffic.
