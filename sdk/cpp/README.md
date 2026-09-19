# Plainwire Bot SDK for C++

The C++ SDK is a small RAII wrapper around the supported C transport. It keeps the same verified-TLS, no-redirect, bounded-response behavior while exposing `std::string` and exceptions for transport/configuration failures.

```cpp
plainwire::bot_client bot("https://chat.example.com", std::getenv("PLAINWIRE_BOT_TOKEN"));
auto result = bot.send_message(42, "hello from C++");
std::cout << result.body();
```

The response body is JSON. Use the JSON library already used by your bot application.
