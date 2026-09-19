#!/usr/bin/env python3
"""Plainwire authenticated live control-plane load/soak harness.

This intentionally exercises the real HTTP + WebSocket stack while keeping
credentials out of source control. It does not synthesize RTP/WebRTC media; use
browser/media tooling for codec/bandwidth testing.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import ipaddress
import statistics
import sys
import time
from collections import Counter, deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

try:
    import aiohttp
except ImportError as exc:  # pragma: no cover - friendly developer error
    raise SystemExit(
        "aiohttp is required for live load tests. Install tools/load/requirements.txt in a test environment."
    ) from exc


@dataclass(frozen=True)
class SessionSpec:
    cookie: str
    csrf: str | None
    user_id: int | None
    channel_id: int | None
    presence_user_ids: tuple[int, ...]
    voice_channel_id: int | None


class Stats:
    def __init__(self, sample_limit: int = 100_000) -> None:
        self.counts: Counter[str] = Counter()
        self.http_status: Counter[int] = Counter()
        self.http_ms: deque[float] = deque(maxlen=sample_limit)
        self.ws_connect_ms: deque[float] = deque(maxlen=sample_limit)
        self.errors: deque[str] = deque(maxlen=200)
        self._lock = asyncio.Lock()

    async def inc(self, key: str, n: int = 1) -> None:
        async with self._lock:
            self.counts[key] += n

    async def error(self, message: str) -> None:
        # Never include cookies/tokens in caller-supplied messages.
        async with self._lock:
            self.counts["errors"] += 1
            self.errors.append(message[:240])

    async def http(self, status: int, elapsed_ms: float) -> None:
        async with self._lock:
            self.counts["http_requests"] += 1
            self.http_status[status] += 1
            self.http_ms.append(elapsed_ms)

    async def connected(self, elapsed_ms: float) -> None:
        async with self._lock:
            self.counts["ws_connected"] += 1
            self.ws_connect_ms.append(elapsed_ms)


def percentile(values: deque[float], p: float) -> float:
    if not values:
        return 0.0
    rows = sorted(values)
    idx = max(0, min(len(rows) - 1, math.ceil(len(rows) * p / 100) - 1))
    return round(rows[idx], 2)


def loopback_host(host: str | None) -> bool:
    if not host:
        return False
    host = host.strip("[]").lower()
    if host == "localhost":
        return True
    # Do not resolve arbitrary DNS names here. The safety gate and aiohttp would
    # otherwise perform separate resolutions, creating an avoidable DNS-rebinding
    # window where a hostname passes as loopback and is later routed remotely.
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def load_sessions(path: Path) -> list[SessionSpec]:
    rows: list[SessionSpec] = []
    with path.open("r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"{path}:{lineno}: invalid JSON: {exc}") from exc
            cookie = obj.get("cookie")
            if not isinstance(cookie, str) or "pw_session=" not in cookie or len(cookie) > 4096:
                raise SystemExit(f"{path}:{lineno}: cookie must contain a bounded pw_session cookie")
            csrf = obj.get("csrf")
            if csrf is not None and (not isinstance(csrf, str) or len(csrf) > 512):
                raise SystemExit(f"{path}:{lineno}: invalid csrf value")
            rows.append(
                SessionSpec(
                    cookie=cookie,
                    csrf=csrf,
                    user_id=positive_int(obj.get("user_id")),
                    channel_id=positive_int(obj.get("channel_id")),
                    presence_user_ids=tuple(
                        x for x in (positive_int(v) for v in obj.get("presence_user_ids", [])) if x is not None
                    )[:2000],
                    voice_channel_id=positive_int(obj.get("voice_channel_id")),
                )
            )
    return rows


def positive_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        value = int(value)
    except (TypeError, ValueError):
        return None
    return value if value > 0 else None


def ws_url(base_url: str) -> str:
    p = urlparse(base_url)
    scheme = "wss" if p.scheme == "https" else "ws"
    return f"{scheme}://{p.netloc}/ws"


def origin_url(base_url: str) -> str:
    p = urlparse(base_url)
    return f"{p.scheme}://{p.netloc}"


async def ws_reader(ws: aiohttp.ClientWebSocketResponse, stats: Stats, stop: asyncio.Event) -> None:
    try:
        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                await stats.inc("ws_events_received")
            elif msg.type in {aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.CLOSE}:
                break
            elif msg.type == aiohttp.WSMsgType.ERROR:
                await stats.error("websocket reader error")
                break
            if stop.is_set():
                break
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        await stats.error(f"websocket reader: {type(exc).__name__}")


async def ws_sender(
    ws: aiohttp.ClientWebSocketResponse,
    spec: SessionSpec,
    index: int,
    interval: float,
    deadline: float,
    stats: Stats,
) -> None:
    if interval <= 0:
        return
    # Deterministic phase spreading prevents the harness itself from creating a
    # once-per-second synchronized spike unless the caller explicitly reconnects.
    await asyncio.sleep((index % 97) / 97 * min(interval, 1.0))
    seq = index
    while time.monotonic() < deadline and not ws.closed:
        seq += 1
        kind = seq % 10
        if kind == 0:
            payload = {"type": "ping"}
        elif kind == 1:
            payload = {"type": "presence_update", "status": "online" if seq % 20 else "away"}
        elif kind == 2 and spec.voice_channel_id:
            payload = {"type": "voice_activity", "active": bool(seq & 1)}
        elif spec.channel_id:
            payload = {
                "type": "typing",
                "scope": "channel",
                "scope_id": spec.channel_id,
                "active": bool(seq & 1),
            }
        else:
            payload = {"type": "ping"}
        try:
            await ws.send_json(payload)
            await stats.inc("ws_operations_sent")
        except Exception as exc:
            await stats.error(f"websocket send: {type(exc).__name__}")
            return
        await asyncio.sleep(interval)


async def connect_one(
    http: aiohttp.ClientSession,
    spec: SessionSpec,
    index: int,
    connect_sem: asyncio.Semaphore,
    interval: float,
    deadline: float,
    stats: Stats,
    stop: asyncio.Event,
    base_url: str,
) -> None:
    started = time.monotonic()
    try:
        async with connect_sem:
            ws = await http.ws_connect(
                ws_url(base_url),
                headers={"Cookie": spec.cookie},
                origin=origin_url(base_url),
                heartbeat=30.0,
                receive_timeout=None,
                max_msg_size=65536,
                compress=0,
            )
        await stats.connected((time.monotonic() - started) * 1000)
        try:
            hello = await asyncio.wait_for(ws.receive(), timeout=10)
            if hello.type != aiohttp.WSMsgType.TEXT:
                await stats.error("websocket did not return hello text frame")
                return
            await stats.inc("ws_events_received")
            if spec.channel_id:
                await ws.send_json({"type": "subscribe", "key": f"channel:{spec.channel_id}"})
            if spec.presence_user_ids:
                await ws.send_json({"type": "presence_watch", "user_ids": list(spec.presence_user_ids)})
            if spec.voice_channel_id:
                await ws.send_json({"type": "voice_join", "channel_id": spec.voice_channel_id})
            reader = asyncio.create_task(ws_reader(ws, stats, stop))
            sender = asyncio.create_task(ws_sender(ws, spec, index, interval, deadline, stats))
            remaining = max(0.0, deadline - time.monotonic())
            try:
                await asyncio.wait_for(stop.wait(), timeout=remaining)
            except asyncio.TimeoutError:
                pass
            sender.cancel()
            reader.cancel()
            await asyncio.gather(sender, reader, return_exceptions=True)
        finally:
            await ws.close(code=1000, message=b"load test complete")
            await stats.inc("ws_closed")
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        await stats.error(f"websocket connect/session: {type(exc).__name__}")


async def message_worker(
    http: aiohttp.ClientSession,
    base_url: str,
    queue: asyncio.Queue[SessionSpec | None],
    stats: Stats,
) -> None:
    while True:
        spec = await queue.get()
        try:
            if spec is None:
                return
            if not spec.channel_id or not spec.csrf:
                await stats.inc("http_skipped_missing_fixture")
                continue
            started = time.monotonic()
            try:
                async with http.post(
                    f"{base_url}/api/channels/{spec.channel_id}/messages",
                    headers={
                        "Cookie": spec.cookie,
                        "x-csrf-token": spec.csrf,
                        "content-type": "application/json",
                        "accept": "application/json",
                    },
                    json={"body": "Plainwire load probe", "reply_to_id": None},
                ) as response:
                    # Consume the bounded JSON response so the connection can reuse.
                    await response.read()
                    await stats.http(response.status, (time.monotonic() - started) * 1000)
            except Exception as exc:
                await stats.error(f"http message: {type(exc).__name__}")
        finally:
            queue.task_done()


async def message_producer(
    specs: list[SessionSpec],
    queue: asyncio.Queue[SessionSpec | None],
    messages_per_second: float,
    deadline: float,
    stats: Stats,
) -> None:
    eligible = [s for s in specs if s.channel_id and s.csrf]
    if not eligible or messages_per_second <= 0:
        return
    interval = 1.0 / messages_per_second
    seq = 0
    next_at = time.monotonic()
    while time.monotonic() < deadline:
        spec = eligible[seq % len(eligible)]
        seq += 1
        try:
            queue.put_nowait(spec)
            await stats.inc("http_enqueued")
        except asyncio.QueueFull:
            await stats.inc("http_queue_dropped")
        next_at += interval
        delay = next_at - time.monotonic()
        if delay > 0:
            await asyncio.sleep(delay)
        elif delay < -1.0:
            # Don't replay a giant burst if the load generator itself stalls.
            next_at = time.monotonic()


async def run(args: argparse.Namespace) -> int:
    base = args.base_url.rstrip("/")
    parsed = urlparse(base)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SystemExit("--base-url must be an absolute http(s) URL")
    allow_remote = args.allow_remote or os.getenv("LOAD_ALLOW_REMOTE") == "1"
    if not loopback_host(parsed.hostname) and not allow_remote:
        raise SystemExit(
            "Refusing to load-test a non-loopback host. Pass --allow-remote (or LOAD_ALLOW_REMOTE=1) only for an instance you own."
        )

    path = Path(args.sessions)
    if not path.is_file():
        raise SystemExit(f"session fixture not found: {path}")
    specs = load_sessions(path)
    if len(specs) < args.users:
        raise SystemExit(f"need {args.users} session rows; fixture only has {len(specs)}")
    specs = specs[: args.users]

    rate = args.rate or max(1000, args.users * 4)
    message_rate = rate * (args.message_percent / 100.0)
    ephemeral_rate = max(0.0, rate - message_rate)
    per_socket_rate = ephemeral_rate / args.users if args.users else 0.0
    interval = 1.0 / per_socket_rate if per_socket_rate > 0 else 0.0
    stats = Stats()
    stop = asyncio.Event()
    deadline = time.monotonic() + args.duration

    timeout = aiohttp.ClientTimeout(total=args.http_timeout, connect=min(10, args.http_timeout))
    connector = aiohttp.TCPConnector(limit=0, ttl_dns_cache=300, enable_cleanup_closed=True)
    async with aiohttp.ClientSession(timeout=timeout, connector=connector, cookie_jar=aiohttp.DummyCookieJar()) as http:
        queue: asyncio.Queue[SessionSpec | None] = asyncio.Queue(maxsize=max(1024, args.http_workers * 64))
        workers = [asyncio.create_task(message_worker(http, base, queue, stats)) for _ in range(args.http_workers)]
        producer = asyncio.create_task(message_producer(specs, queue, message_rate, deadline, stats))
        sem = asyncio.Semaphore(args.connect_concurrency)
        sockets = [
            asyncio.create_task(connect_one(http, spec, i, sem, interval, deadline, stats, stop, base))
            for i, spec in enumerate(specs)
        ]
        print(
            f"Plainwire live load: users={args.users} duration={args.duration}s target_ops/s={rate} "
            f"durable≈{message_rate:.1f}/s ws≈{ephemeral_rate:.1f}/s"
        )
        await asyncio.gather(*sockets, return_exceptions=True)
        stop.set()
        await producer
        await queue.join()
        for _ in workers:
            await queue.put(None)
        await asyncio.gather(*workers)

    connected = stats.counts["ws_connected"]
    connect_pct = connected * 100.0 / args.users
    requests = stats.counts["http_requests"]
    server_errors = sum(n for status, n in stats.http_status.items() if status >= 500)
    server_error_pct = server_errors * 100.0 / requests if requests else 0.0
    result = {
        "users_requested": args.users,
        "ws_connected": connected,
        "ws_connect_percent": round(connect_pct, 3),
        "duration_seconds": args.duration,
        "target_operations_per_second": rate,
        "counts": dict(stats.counts),
        "http_status": {str(k): v for k, v in sorted(stats.http_status.items())},
        "ws_connect_ms": {
            "p50": percentile(stats.ws_connect_ms, 50),
            "p95": percentile(stats.ws_connect_ms, 95),
            "p99": percentile(stats.ws_connect_ms, 99),
        },
        "http_ms": {
            "p50": percentile(stats.http_ms, 50),
            "p95": percentile(stats.http_ms, 95),
            "p99": percentile(stats.http_ms, 99),
        },
        "http_5xx_percent": round(server_error_pct, 3),
        "sampled_errors": list(stats.errors),
        "media_note": "RTC join/activity control traffic is exercised when fixtures provide voice_channel_id; RTP/audio/video/screen encoding is not synthesized.",
    }
    encoded = json.dumps(result, indent=2, sort_keys=True)
    print(encoded)
    if args.json_out:
        Path(args.json_out).write_text(encoded + "\n", encoding="utf-8")

    failed = False
    if connect_pct < args.min_connect_percent:
        print(f"FAIL: WebSocket connect rate {connect_pct:.2f}% < {args.min_connect_percent:.2f}%", file=sys.stderr)
        failed = True
    if server_error_pct > args.max_5xx_percent:
        print(f"FAIL: HTTP 5xx rate {server_error_pct:.2f}% > {args.max_5xx_percent:.2f}%", file=sys.stderr)
        failed = True
    return 1 if failed else 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Authenticated Plainwire HTTP/WebSocket live load harness")
    p.add_argument("--base-url", default=os.getenv("LOAD_BASE_URL", "http://127.0.0.1:8080"))
    p.add_argument("--sessions", default=os.getenv("LOAD_SESSIONS_FILE", "tools/load/plainwire.sessions.jsonl"))
    p.add_argument("--users", type=int, default=int(os.getenv("USERS", "1000")))
    p.add_argument("--duration", type=int, default=int(os.getenv("DURATION", "60")))
    p.add_argument("--rate", type=int, default=int(os.getenv("RATE", "0")), help="target total app operations/sec; 0=users*4, minimum 1000")
    p.add_argument("--message-percent", type=float, default=float(os.getenv("LOAD_MESSAGE_PERCENT", "10")))
    p.add_argument("--connect-concurrency", type=int, default=int(os.getenv("LOAD_CONNECT_CONCURRENCY", "200")))
    p.add_argument("--http-workers", type=int, default=int(os.getenv("LOAD_HTTP_WORKERS", str(min(128, max(8, (os.cpu_count() or 2) * 4))))))
    p.add_argument("--http-timeout", type=float, default=float(os.getenv("LOAD_HTTP_TIMEOUT", "15")))
    p.add_argument("--min-connect-percent", type=float, default=float(os.getenv("LOAD_MIN_CONNECT_PERCENT", "99")))
    p.add_argument("--max-5xx-percent", type=float, default=float(os.getenv("LOAD_MAX_5XX_PERCENT", "1")))
    p.add_argument("--json-out", default=os.getenv("LOAD_JSON_OUT"))
    p.add_argument("--allow-remote", action="store_true", help="allow a non-loopback target that you own/control")
    return p


def main() -> int:
    args = parser().parse_args()
    if args.users < 1 or args.duration < 1 or args.rate < 0:
        raise SystemExit("users/duration must be positive and rate non-negative")
    if not 0 <= args.message_percent <= 100:
        raise SystemExit("message-percent must be 0..100")
    if args.connect_concurrency < 1 or args.http_workers < 1:
        raise SystemExit("worker/concurrency values must be positive")
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
