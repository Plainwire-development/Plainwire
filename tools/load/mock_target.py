#!/usr/bin/env python3
"""Loopback-only fake Plainwire target used to validate live_load.py itself."""
from __future__ import annotations

import argparse
import asyncio
import json
from aiohttp import web


def require_loopback(request: web.Request) -> None:
    peer = request.transport.get_extra_info("peername") if request.transport else None
    host = peer[0] if isinstance(peer, tuple) and peer else ""
    if host not in {"127.0.0.1", "::1"}:
        raise web.HTTPForbidden()


async def websocket(request: web.Request) -> web.StreamResponse:
    require_loopback(request)
    if "pw_session=" not in request.headers.get("Cookie", ""):
        raise web.HTTPUnauthorized()
    ws = web.WebSocketResponse(compress=False, max_msg_size=65536)
    await ws.prepare(request)
    await ws.send_json({"type": "hello", "load_test": True})
    async for msg in ws:
        if msg.type == web.WSMsgType.TEXT:
            try:
                payload = json.loads(msg.data)
            except json.JSONDecodeError:
                continue
            # Echo a small acknowledgement for ping only. Other frames are
            # intentionally consumed without growing server-side state.
            if payload.get("type") == "ping":
                await ws.send_json({"type": "pong"})
        elif msg.type in {web.WSMsgType.CLOSE, web.WSMsgType.CLOSED, web.WSMsgType.ERROR}:
            break
    return ws


async def post_message(request: web.Request) -> web.Response:
    require_loopback(request)
    if "pw_session=" not in request.headers.get("Cookie", ""):
        raise web.HTTPUnauthorized()
    if not request.headers.get("x-csrf-token"):
        raise web.HTTPForbidden()
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest()
    if not isinstance(body, dict) or not isinstance(body.get("body"), str):
        raise web.HTTPBadRequest()
    return web.json_response({"id": 1, "channel_id": int(request.match_info["channel_id"])}, status=201)


async def health(request: web.Request) -> web.Response:
    require_loopback(request)
    return web.json_response({"ok": True})


def app() -> web.Application:
    result = web.Application(client_max_size=64 * 1024)
    result.router.add_get("/health", health)
    result.router.add_get("/ws", websocket)
    result.router.add_post("/api/channels/{channel_id:\\d+}/messages", post_message)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    web.run_app(app(), host="127.0.0.1", port=args.port, print=None, access_log=None)


if __name__ == "__main__":
    main()
