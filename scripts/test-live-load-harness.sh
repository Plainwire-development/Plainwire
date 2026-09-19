#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON_BIN="${PYTHON:-python3}"
PORT="${PLAINWIRE_LOAD_SELFTEST_PORT:-18765}"
TMP="$(mktemp -d)"
TARGET_PID=""
cleanup() {
  if [[ -n "$TARGET_PID" ]]; then
    kill "$TARGET_PID" 2>/dev/null || true
    wait "$TARGET_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

"$PYTHON_BIN" - <<'PY' >"$TMP/sessions.jsonl"
import json
for i in range(25):
    print(json.dumps({
        "cookie": f"pw_session=selftest-{i}",
        "csrf": f"csrf-{i}",
        "user_id": i + 1,
        "channel_id": 1,
        "presence_user_ids": [((i + 1) % 25) + 1],
        "voice_channel_id": 2,
    }, separators=(",", ":")))
PY

"$PYTHON_BIN" tools/load/mock_target.py --port "$PORT" >"$TMP/target.log" 2>&1 &
TARGET_PID=$!
for _ in {1..100}; do
  if "$PYTHON_BIN" - "$PORT" <<'PY' >/dev/null 2>&1
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=.1):
    pass
PY
  then break; fi
  if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    cat "$TMP/target.log" >&2
    exit 1
  fi
  sleep .05
done

"$PYTHON_BIN" tools/load/live_load.py \
  --base-url "http://127.0.0.1:$PORT" \
  --sessions "$TMP/sessions.jsonl" \
  --users 25 --duration 2 --rate 250 \
  --message-percent 20 --connect-concurrency 25 \
  --min-connect-percent 100 --max-5xx-percent 0 \
  --json-out "$TMP/result.json"

"$PYTHON_BIN" - "$TMP/result.json" <<'PY'
import json, sys
r=json.load(open(sys.argv[1], encoding="utf-8"))
assert r["ws_connected"] == 25, r
assert r["http_5xx_percent"] == 0, r
assert r["counts"].get("errors", 0) == 0, r
assert r["counts"].get("ws_operations_sent", 0) > 0, r
assert r["counts"].get("http_requests", 0) > 0, r
print("Live load harness self-test passed")
PY
