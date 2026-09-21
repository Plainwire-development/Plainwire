import unittest
from unittest.mock import Mock
from plainwire_bot import Client, Response, command_option, command_options

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

if __name__ == "__main__": unittest.main()
