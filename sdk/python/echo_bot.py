import os, time
from plainwire_bot import Client, PlainwireError

bot = Client(os.environ["PLAINWIRE_URL"], os.environ["PLAINWIRE_BOT_TOKEN"])
while True:
    try:
        data = bot.claim_commands(10).json().get("data", [])
        for claim in data:
            bot.respond_command(claim["id"], claim["claim_token"], "hello from Python")
    except PlainwireError as exc:
        print(f"Plainwire bot error: {exc}")
    time.sleep(1)
