# Plainwire load tools

These tools test different layers; none should be treated as a magic user-count certification.

## `make load`

`pw_load_sim.erl` is an in-process BEAM stress harness for the hot realtime path. It creates fake socket processes and drives subscriptions, user/channel fanout, presence watches, RTC signaling/activity and deliberately slow consumers. It avoids PostgreSQL and TCP so large process/fanout tests spend CPU on the code under test.

```sh
make load USERS=1000 DURATION=60 RATE=0
make load-10000 DURATION=120 RATE=40000
```

`RATE=0` chooses a workload from the user count.

## `make load-live`

`live_load.py` uses real authenticated HTTP and WebSockets. Install its isolated test dependency with:

```sh
python -m pip install -r tools/load/requirements.txt
```

Supply a JSONL fixture. One object per test user:

```json
{"cookie":"pw_session=...","csrf":"...","user_id":123,"channel_id":456,"presence_user_ids":[124,125],"voice_channel_id":789}
```

Only `cookie` is required. Durable message posts require `csrf` and `channel_id`. Presence/voice fields activate those parts of the scenario.

The harness refuses a non-loopback target unless you explicitly pass `--allow-remote` or `LOAD_ALLOW_REMOTE=1`. Do not use it against infrastructure you do not own or have permission to test. Never commit fixtures containing session cookies.

The live harness exercises RTC join/activity control traffic but does not generate RTP/audio/video/screen media. The in-process BEAM harness also exercises RTC signaling fanout.

## `make load-doctor`

Checks obvious host ceilings before a large run: file descriptors, backlog, ephemeral ports, CPU/RAM visibility and BEAM process limit.

## Gleam model

`gleam/` contains the typed reference model for workload/capacity/backpressure/media math. It is deliberately not a production dependency.

```sh
make load-gleam-check
```
