# Plainwire Bot SDK for Python

Dependency-free Python 3 client for the Plainwire Bot API v1. Remote instances require HTTPS. Redirects are refused so a bot token cannot be forwarded to another origin.

Install from this source tree with `python -m pip install ./sdk/python`. For development, `python -m pip install -e ./sdk/python` keeps edits live.

```python
from plainwire_bot import Client

bot = Client("https://chat.example.com", "pwb_...")
print(bot.me().json())
bot.send_message(42, "hello from Python")
```

Commands can be deployed and handled without writing a polling loop:

```python
bot.sync_commands([{"name": "ping", "description": "Replies pong"}])
bot.command_worker({"ping": lambda claim, client: "pong"}).run()
```

The worker has bounded batch and concurrency settings, renews live claims, and reports handler failures through `on_error`.

Run the transport-policy tests after an editable install with `python -m unittest discover -s sdk/python/tests -v` from the Plainwire repository root.
