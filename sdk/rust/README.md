# Plainwire Bot SDK for Rust

Blocking Rust client for Bot API v1 using rustls-backed `reqwest`. It verifies TLS, refuses redirects, caps responses and allows plaintext HTTP only on loopback.

```rust
let bot = plainwire_bot::Client::new("https://chat.example.com", "pwb_...")?;
println!("{}", bot.me()?);
```
