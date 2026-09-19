# Plainwire Bot SDK for Go

The Go SDK uses only the standard library. It provides typed durable command claims and low-level JSON responses for the rest of Bot API v1.

Security defaults are strict: verified HTTPS, no redirects, bounded response bodies, connection timeouts and remote plaintext HTTP rejection. Loopback HTTP remains available for development.

```go
bot, err := plainwirebot.New("https://chat.example.com", os.Getenv("PLAINWIRE_BOT_TOKEN"))
claims, err := bot.ClaimCommands(context.Background(), 20)
```

Claim tokens are lease capabilities. Keep them in memory, never log them, and respond or fail before `lease_until`.
