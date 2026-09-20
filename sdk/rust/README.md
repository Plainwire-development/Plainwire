# Plainwire Bot SDK for Rust

Blocking Rust client for Bot API v1 using rustls-backed `reqwest`. It verifies TLS, refuses redirects, caps responses and allows plaintext HTTP only on loopback.

```rust
let bot = plainwire_bot::Client::new("https://chat.example.com", "pwb_...")?;
println!("{}", bot.me()?);
```

Use `sync_commands` for atomic command deployment, `members` for bounded cursor pages, and `defer_command` to renew a long-running durable claim. These methods accept and return `serde_json::Value` so applications can layer their own strongly typed models without losing API coverage.
