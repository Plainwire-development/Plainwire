import unittest
from unittest.mock import Mock
from plainwire_bot import Client, Response, PlainwireError, command_option, command_options

TOKEN = "pwb_" + "x" * 32

class PolicyTests(unittest.TestCase):
    def test_https_remote_allowed(self):
        Client("https://plainwire.example", TOKEN)

    def test_remote_http_rejected(self):
        with self.assertRaises(ValueError):
            Client("http://plainwire.example", TOKEN)

    def test_loopback_http_allowed(self):
        Client("http://127.0.0.1:8080", TOKEN)
        Client("http://[::1]:8080", TOKEN)
        Client("http://localhost:8080", TOKEN)

    def test_userinfo_query_fragment_rejected(self):
        for url in ["https://u:p@plainwire.example", "https://plainwire.example/?x=1", "https://plainwire.example/#x"]:
            with self.assertRaises(ValueError): Client(url, TOKEN)

    def test_token_header_injection_rejected(self):
        with self.assertRaises(ValueError): Client("https://plainwire.example", TOKEN + "\r\nx: y")

    def test_v22_helpers_use_bounded_routes(self):
        client = Client("https://plainwire.example", TOKEN)
        client.request = Mock(return_value=Response(200, b'{"ok":true,"data":{}}'))
        client.members(after=41, limit=500)
        client.sync_commands([{"name": "ping"}])
        client.defer_command(9, "pwc_claim", 999999)
        self.assertEqual(client.request.call_args_list[0].args[:2], ("GET", "/api/bot/v1/members?limit=200&after=41"))
        self.assertEqual(client.request.call_args_list[1].args[:2], ("PUT", "/api/bot/v1/commands"))
        self.assertEqual(client.request.call_args_list[2].args[2]["lease_ms"], 120000)

    def test_command_worker_replies(self):
        client = Client("https://plainwire.example", TOKEN)
        claim = {"id": 7, "command": "ping", "claim_token": "pwc_x", "args": {}}
        client.claim_commands = Mock(return_value=Response(200, ('{"ok":true,"data":' + __import__('json').dumps([claim]) + '}').encode()))
        client.defer_command = Mock(return_value=Response(200, b'{}'))
        client.respond_command = Mock(return_value=Response(200, b'{}'))
        client.fail_command = Mock(return_value=Response(200, b'{}'))
        self.assertEqual(client.command_worker({"ping": lambda _claim, _bot: "pong"}).run_once(), 1)
        client.defer_command.assert_called_once()
        client.respond_command.assert_called_once_with(7, "pwc_x", "pong")

    def test_command_options_ignore_raw_metadata(self):
        claim = {"args": {"raw": "hello there", "source": "chat", "text": "hello there"}, "options": {"text": "hello there"}}
        self.assertEqual(command_options(claim), {"text": "hello there"})
        self.assertEqual(command_option(claim, "text"), "hello there")
        self.assertEqual(command_option({"args": {"prompt": "hi"}}, "prompt"), "hi")
        self.assertEqual(command_option({"args": {}}, "missing", "fallback"), "fallback")

    def test_normalized_path_cannot_escape_bot_api(self):
        client = Client("https://plainwire.example", TOKEN)
        client._opener.open = Mock()
        for path in ["/me", "/api/bot/v1/../admin", "/api/bot/v1/%2e%2e/admin", "/api/bot/v1/%252e%252e/admin", "/api/bot/v1/%2fadmin", "/api/bot/v1/me#fragment"]:
            with self.assertRaises(ValueError): client.request("GET", path)
        client._opener.open.assert_not_called()

    def test_response_always_closed(self):
        client = Client("https://plainwire.example", TOKEN, max_response_bytes=1024)
        for body in [b"{}", b"x" * 1025]:
            fp = Mock(status=200)
            fp.read.return_value = body
            if len(body) > 1024:
                with self.assertRaises(PlainwireError): client._read(fp)
            else:
                self.assertEqual(client._read(fp).body, body)
            fp.close.assert_called_once()

    def test_worker_error_does_not_publish_secret_and_caps_claims(self):
        client = Client("https://plainwire.example", TOKEN)
        client.claim_commands = Mock(return_value=Response(200, b'{"data":[{"id":7,"command":"ping","claim_token":"pwc_x"}]}'))
        client.defer_command = Mock()
        client.fail_command = Mock()
        def fail(_claim, _bot): raise RuntimeError("secret-api-key")
        errors = []
        client.command_worker({"ping": fail}, batch_size=20, concurrency=2, on_error=lambda error, claim: errors.append(error)).run_once()
        client.claim_commands.assert_called_once_with(2)
        client.fail_command.assert_called_once_with(7, "pwc_x", "Command failed")
        self.assertEqual(str(errors[0]), "secret-api-key")

    def test_limits_reject_unbounded_values(self):
        for timeout in [float('nan'), float('inf'), 301]:
            with self.assertRaises(ValueError): Client("https://plainwire.example", TOKEN, timeout=timeout)

if __name__ == "__main__": unittest.main()
