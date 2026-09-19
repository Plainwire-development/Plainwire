#include "plainwire_bot.hpp"
#include <cstdlib>
#include <iostream>

int main() {
    const char* token = std::getenv("PLAINWIRE_BOT_TOKEN");
    const char* base = std::getenv("PLAINWIRE_BASE_URL");
    if (!token) {
        std::cerr << "PLAINWIRE_BOT_TOKEN is required\n";
        return 2;
    }
    try {
        plainwire::bot_client bot(base ? base : "http://127.0.0.1:8080", token);
        auto me = bot.me();
        std::cout << me.body() << '\n';
        auto command = bot.register_command("echo", "Echo text back to the channel");
        std::cout << command.body() << '\n';
    } catch (const std::exception& e) {
        std::cerr << "Plainwire bot startup failed: " << e.what() << '\n';
        return 1;
    }
}
