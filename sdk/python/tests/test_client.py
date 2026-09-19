import unittest
from plainwire_bot import Client

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

if __name__ == "__main__": unittest.main()
