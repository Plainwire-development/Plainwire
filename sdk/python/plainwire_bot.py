"""Plainwire Bot API v1 client.

No third-party dependencies are required. Remote Plainwire instances must use
HTTPS. Plain HTTP is accepted only for loopback development.
"""
from __future__ import annotations

import ipaddress
import json
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, Callable, Mapping, Sequence

API_PREFIX = "/api/bot/v1"
DEFAULT_TIMEOUT = 15.0
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_REQUEST_BYTES = 64 * 1024


class PlainwireError(Exception):
    pass


class PlainwireAPIError(PlainwireError):
    def __init__(self, status: int, body: bytes):
        super().__init__(f"Plainwire API returned HTTP {status}")
        self.status = status
        self.body = body


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@dataclass(frozen=True)
class Response:
    status: int
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


def _loopback(host: str) -> bool:
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class Client:
    def __init__(self, base_url: str, token: str, *, timeout: float = DEFAULT_TIMEOUT,
                 max_response_bytes: int = MAX_RESPONSE_BYTES):
        parsed = urllib.parse.urlsplit(base_url)
        if parsed.username or parsed.password or parsed.query or parsed.fragment or not parsed.hostname:
            raise ValueError("invalid Plainwire base URL")
        if parsed.scheme != "https" and not (parsed.scheme == "http" and _loopback(parsed.hostname)):
            raise ValueError("Plainwire bots require HTTPS except on loopback")
        if not token.startswith("pwb_") or not 16 <= len(token) <= 256 or "\r" in token or "\n" in token:
            raise ValueError("invalid Plainwire bot token")
        if timeout <= 0 or max_response_bytes < 1024:
            raise ValueError("invalid client limits")
        self._base = base_url.rstrip("/")
        self._token = token
        self.timeout = timeout
        self.max_response_bytes = max_response_bytes
        context = ssl.create_default_context()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context),
            urllib.request.HTTPHandler(),
            _NoRedirect(),
        )

    def request(self, method: str, path: str, payload: Any | None = None) -> Response:
        if not path.startswith("/") or "://" in path or "\r" in path or "\n" in path:
            raise ValueError("invalid Plainwire API path")
        data = None
        headers = {
            "Authorization": f"Bot {self._token}",
            "Accept": "application/json",
            "User-Agent": "plainwire-python-bot/2.4",
        }
        if payload is not None:
            data = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            if len(data) > MAX_REQUEST_BYTES:
                raise ValueError("request body too large")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self._base + path, data=data, headers=headers, method=method.upper())
        try:
            return self._read(self._opener.open(req, timeout=self.timeout))
        except urllib.error.HTTPError as exc:
            response = self._read(exc)
            raise PlainwireAPIError(response.status, response.body) from None

    def _read(self, fp) -> Response:
        status = int(getattr(fp, "status", getattr(fp, "code", 0)))
        body = fp.read(self.max_response_bytes + 1)
        if len(body) > self.max_response_bytes:
            raise PlainwireError("Plainwire response too large")
        return Response(status, body)

    def capabilities(self): return self.request("GET", API_PREFIX)
    def me(self): return self.request("GET", API_PREFIX + "/me")
    def server(self): return self.request("GET", API_PREFIX + "/server")
    def channels(self): return self.request("GET", API_PREFIX + "/channels")

    def messages(self, channel_id: int, *, before: int | None = None, after: int | None = None):
        query = {k: str(v) for k, v in (("before", before), ("after", after)) if v is not None and v > 0}
        suffix = ("?" + urllib.parse.urlencode(query)) if query else ""
        return self.request("GET", f"{API_PREFIX}/channels/{int(channel_id)}/messages{suffix}")

    def send_message(self, channel_id: int, body: str, *, reply_to_id: int | None = None):
        payload: dict[str, Any] = {"body": body}
        if reply_to_id is not None:
            payload["reply_to_id"] = int(reply_to_id)
        return self.request("POST", f"{API_PREFIX}/channels/{int(channel_id)}/messages", payload)

    def delete_message(self, message_id: int):
        return self.request("POST", f"{API_PREFIX}/messages/{int(message_id)}/delete", {})

    def toggle_reaction(self, message_id: int, emoji: str):
        return self.request("POST", f"{API_PREFIX}/messages/{int(message_id)}/reaction", {"emoji": emoji})

    def edit_message(self, message_id: int, body: str):
        return self.request("POST", f"{API_PREFIX}/messages/{int(message_id)}/edit", {"body": body})

    def pin_message(self, message_id: int, pinned: bool = True):
        return self.request("POST", f"{API_PREFIX}/messages/{int(message_id)}/pin", {"pinned": bool(pinned)})

    def pins(self, channel_id: int): return self.request("GET", f"{API_PREFIX}/channels/{int(channel_id)}/pins")
    def message_context(self, message_id: int): return self.request("GET", f"{API_PREFIX}/messages/{int(message_id)}/context")

    def create_channel(self, name: str, kind: str = "text", category_id: int | None = None):
        payload: dict[str, Any] = {"name": name, "kind": kind}
        if category_id is not None: payload["category_id"] = int(category_id)
        return self.request("POST", API_PREFIX + "/channels", payload)

    def update_channel(self, channel_id: int, **patch):
        return self.request("POST", f"{API_PREFIX}/channels/{int(channel_id)}/settings", patch)

    def roles(self): return self.request("GET", API_PREFIX + "/roles")
    def create_role(self, name: str, **patch): return self.request("POST", API_PREFIX + "/roles", {"name": name, **patch})
    def update_role(self, role_id: int, **patch): return self.request("POST", f"{API_PREFIX}/roles/{int(role_id)}", patch)
    def delete_role(self, role_id: int): return self.request("DELETE", f"{API_PREFIX}/roles/{int(role_id)}")
    def members(self, *, after: int | None = None, limit: int = 50):
        query = {"limit": str(max(1, min(200, int(limit))))}
        if after is not None and after > 0: query["after"] = str(int(after))
        return self.request("GET", API_PREFIX + "/members?" + urllib.parse.urlencode(query))
    def member(self, user_id: int): return self.request("GET", f"{API_PREFIX}/members/{int(user_id)}")
    def set_member_roles(self, user_id: int, role_ids: Sequence[int]): return self.request("POST", f"{API_PREFIX}/members/{int(user_id)}/roles", {"role_ids": [int(v) for v in role_ids]})
    def kick_member(self, user_id: int): return self.request("POST", f"{API_PREFIX}/members/{int(user_id)}/kick", {})
    def ban_member(self, user_id: int, reason: str = ""): return self.request("POST", f"{API_PREFIX}/members/{int(user_id)}/ban", {"reason": reason})
    def unban_member(self, user_id: int): return self.request("POST", f"{API_PREFIX}/members/{int(user_id)}/unban", {})
    def bans(self): return self.request("GET", API_PREFIX + "/bans")
    def wires(self): return self.request("GET", API_PREFIX + "/wires")
    def create_wire(self, channel_id: int, max_uses: int = 0, expires_in: int = 86400):
        return self.request("POST", API_PREFIX + "/wires", {"channel_id": int(channel_id), "max_uses": int(max_uses), "expires_in": int(expires_in)})

    def register_command(self, name: str, description: str = "", options: Sequence[Mapping[str, Any]] = ()):
        return self.request("POST", API_PREFIX + "/commands", {
            "name": name, "description": description, "options": list(options)
        })

    def sync_commands(self, commands: Sequence[Mapping[str, Any]]):
        return self.request("PUT", API_PREFIX + "/commands", {"commands": list(commands)})

    def commands(self): return self.request("GET", API_PREFIX + "/commands")
    def delete_command(self, command_id: int):
        return self.request("DELETE", f"{API_PREFIX}/commands/{int(command_id)}")

    def claim_commands(self, limit: int = 10):
        limit = max(1, min(50, int(limit)))
        return self.request("GET", f"{API_PREFIX}/commands/claims?limit={limit}")

    def defer_command(self, invocation_id: int, claim_token: str, lease_ms: int = 120_000):
        lease_ms = max(5_000, min(120_000, int(lease_ms)))
        return self.request("POST", f"{API_PREFIX}/commands/claims/{int(invocation_id)}/defer",
                            {"claim_token": claim_token, "lease_ms": lease_ms})

    def respond_command(self, invocation_id: int, claim_token: str, body: str):
        return self.request("POST", f"{API_PREFIX}/commands/claims/{int(invocation_id)}/respond",
                            {"claim_token": claim_token, "body": body})

    def fail_command(self, invocation_id: int, claim_token: str, reason: str):
        return self.request("POST", f"{API_PREFIX}/commands/claims/{int(invocation_id)}/fail",
                            {"claim_token": claim_token, "reason": reason})

    def command_worker(self, handlers: Mapping[str, Callable[[Mapping[str, Any], "Client"], Any]], **options):
        return CommandWorker(self, handlers, **options)

    def listen(self, handlers: Mapping[str, Callable[[Mapping[str, Any], "Client"], Any]], **options) -> None:
        self.command_worker(handlers, **options).run()

    @staticmethod
    def options(claim: Mapping[str, Any] | None) -> dict[str, Any]:
        return command_options(claim)

    @staticmethod
    def option(claim: Mapping[str, Any] | None, name: str, default: Any = None) -> Any:
        return command_option(claim, name, default)


def command_options(claim: Mapping[str, Any] | None) -> dict[str, Any]:
    payload = claim or {}
    options = payload.get("options")
    if isinstance(options, Mapping) and not isinstance(options, (str, bytes)):
        return dict(options)
    args = payload.get("args") if isinstance(payload.get("args"), Mapping) else {}
    return {key: value for key, value in dict(args).items() if key not in {"raw", "source"}}


def command_option(claim: Mapping[str, Any] | None, name: str, default: Any = None) -> Any:
    options = command_options(claim)
    return options[name] if name in options else default


class CommandWorker:
    """Bounded durable-command worker with automatic lease renewal and replies."""

    def __init__(self, client: Client, handlers: Mapping[str, Callable[[Mapping[str, Any], Client], Any]],
                 *, batch_size: int = 20, concurrency: int = 4, idle_seconds: float = 0.5,
                 lease_ms: int = 120_000, on_error: Callable[[Exception, Mapping[str, Any] | None], None] | None = None):
        self.client = client
        self.handlers = dict(handlers)
        self.batch_size = max(1, min(50, int(batch_size)))
        self.concurrency = max(1, min(32, int(concurrency)))
        self.idle_seconds = max(0.025, float(idle_seconds))
        self.lease_ms = max(5_000, min(120_000, int(lease_ms)))
        self.on_error = on_error or (lambda _error, _claim=None: None)

    def _handle(self, claim: Mapping[str, Any]) -> None:
        invocation_id, token = int(claim["id"]), str(claim["claim_token"])
        handler = self.handlers.get(str(claim.get("command", "")))
        if handler is None:
            self.client.fail_command(invocation_id, token, f"No handler registered for /{claim.get('command', '')}")
            return
        try:
            self.client.defer_command(invocation_id, token, self.lease_ms)
            result = handler(claim, self.client)
            body = result if isinstance(result, str) else result.get("body") if isinstance(result, Mapping) else None
            if isinstance(body, str) and body.strip():
                self.client.respond_command(invocation_id, token, body)
        except Exception as error:
            self.on_error(error, claim)
            try:
                self.client.fail_command(invocation_id, token, str(error or "command failed")[:240])
            except Exception as failure:
                self.on_error(failure, claim)

    def run_once(self) -> int:
        claims = self.client.claim_commands(self.batch_size).json().get("data", [])
        if not isinstance(claims, list):
            raise PlainwireError("Plainwire returned an invalid command envelope")
        with ThreadPoolExecutor(max_workers=min(self.concurrency, max(1, len(claims)))) as pool:
            list(pool.map(self._handle, claims))
        return len(claims)

    def run(self, stop: Callable[[], bool] | None = None) -> None:
        should_stop = stop or (lambda: False)
        while not should_stop():
            try:
                count = self.run_once()
            except Exception as error:
                self.on_error(error, None)
                count = 0
            if not count and not should_stop():
                time.sleep(self.idle_seconds)
