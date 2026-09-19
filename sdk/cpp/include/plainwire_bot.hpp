#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>

extern "C" {
#include "plainwire_bot.h"
}

namespace plainwire {

class response {
public:
    response() = default;
    response(const response&) = delete;
    response& operator=(const response&) = delete;
    response(response&& other) noexcept : raw_(other.raw_) { other.raw_ = {}; }
    response& operator=(response&& other) noexcept {
        if (this != &other) {
            pw_bot_response_free(&raw_);
            raw_ = other.raw_;
            other.raw_ = {};
        }
        return *this;
    }
    ~response() { pw_bot_response_free(&raw_); }
    long status() const noexcept { return raw_.status; }
    std::string body() const { return raw_.body ? std::string(raw_.body, raw_.body_len) : std::string(); }
    pw_bot_response* out() noexcept { return &raw_; }
private:
    pw_bot_response raw_{};
};

class bot_client {
public:
    bot_client(std::string base_url, std::string token) {
        const int rc = pw_bot_client_init(&raw_, base_url.c_str(), token.c_str());
        if (rc != 0) throw std::invalid_argument("invalid Plainwire bot client configuration");
    }
    bot_client(const bot_client&) = delete;
    bot_client& operator=(const bot_client&) = delete;
    bot_client(bot_client&&) = delete;
    bot_client& operator=(bot_client&&) = delete;
    ~bot_client() { pw_bot_client_cleanup(&raw_); }

    response capabilities() { return request([](auto* c, auto* r){ return pw_bot_capabilities(c, r); }); }
    response me() { return request([](auto* c, auto* r){ return pw_bot_me(c, r); }); }
    response server() { return request([](auto* c, auto* r){ return pw_bot_server(c, r); }); }
    response channels() { return request([](auto* c, auto* r){ return pw_bot_channels(c, r); }); }
    response messages(std::int64_t channel_id, std::int64_t before = 0, std::int64_t after = 0) {
        return request([&](auto* c, auto* r){ return pw_bot_messages(c, channel_id, before, after, r); });
    }
    response send_message(std::int64_t channel_id, const std::string& body, std::int64_t reply_to_id = 0) {
        return request([&](auto* c, auto* r){ return pw_bot_send_message(c, channel_id, body.c_str(), reply_to_id, r); });
    }
    response delete_message(std::int64_t message_id) {
        return request([&](auto* c, auto* r){ return pw_bot_delete_message(c, message_id, r); });
    }
    response toggle_reaction(std::int64_t message_id, const std::string& emoji) {
        return request([&](auto* c, auto* r){ return pw_bot_toggle_reaction(c, message_id, emoji.c_str(), r); });
    }
    response edit_message(std::int64_t message_id, const std::string& body) { return request([&](auto* c, auto* r){ return pw_bot_edit_message(c, message_id, body.c_str(), r); }); }
    response pin_message(std::int64_t message_id, bool pinned = true) { return request([&](auto* c, auto* r){ return pw_bot_pin_message(c, message_id, pinned ? 1 : 0, r); }); }
    response pins(std::int64_t channel_id) { return request([&](auto* c, auto* r){ return pw_bot_channel_pins(c, channel_id, r); }); }
    response message_context(std::int64_t message_id) { return request([&](auto* c, auto* r){ return pw_bot_message_context(c, message_id, r); }); }
    response create_channel(const std::string& name, const std::string& kind = "text", std::int64_t category_id = 0) { return request([&](auto* c, auto* r){ return pw_bot_create_channel(c, name.c_str(), kind.c_str(), category_id, r); }); }
    response update_channel(std::int64_t channel_id, const std::string& settings_json) { return request([&](auto* c, auto* r){ return pw_bot_update_channel(c, channel_id, settings_json.c_str(), r); }); }
    response roles() { return request([](auto* c, auto* r){ return pw_bot_roles(c, r); }); }
    response create_role(const std::string& role_json) { return request([&](auto* c, auto* r){ return pw_bot_create_role(c, role_json.c_str(), r); }); }
    response update_role(std::int64_t role_id, const std::string& role_json) { return request([&](auto* c, auto* r){ return pw_bot_update_role(c, role_id, role_json.c_str(), r); }); }
    response delete_role(std::int64_t role_id) { return request([&](auto* c, auto* r){ return pw_bot_delete_role(c, role_id, r); }); }
    response member(std::int64_t user_id) { return request([&](auto* c, auto* r){ return pw_bot_member(c, user_id, r); }); }
    response set_member_roles(std::int64_t user_id, const std::string& role_ids_json) { return request([&](auto* c, auto* r){ return pw_bot_set_member_roles(c, user_id, role_ids_json.c_str(), r); }); }
    response kick_member(std::int64_t user_id) { return request([&](auto* c, auto* r){ return pw_bot_kick_member(c, user_id, r); }); }
    response ban_member(std::int64_t user_id, const std::string& reason = {}) { return request([&](auto* c, auto* r){ return pw_bot_ban_member(c, user_id, reason.c_str(), r); }); }
    response unban_member(std::int64_t user_id) { return request([&](auto* c, auto* r){ return pw_bot_unban_member(c, user_id, r); }); }
    response bans() { return request([](auto* c, auto* r){ return pw_bot_bans(c, r); }); }
    response wires() { return request([](auto* c, auto* r){ return pw_bot_wires(c, r); }); }
    response create_wire(std::int64_t channel_id, int max_uses = 0, int expires_in = 86400) { return request([&](auto* c, auto* r){ return pw_bot_create_wire(c, channel_id, max_uses, expires_in, r); }); }

    response register_command(const std::string& name, const std::string& description, const std::string& options_json = "[]") {
        return request([&](auto* c, auto* r){ return pw_bot_register_command(c, name.c_str(), description.c_str(), options_json.c_str(), r); });
    }
    response commands() { return request([](auto* c, auto* r){ return pw_bot_commands(c, r); }); }
    response delete_command(std::int64_t command_id) {
        return request([&](auto* c, auto* r){ return pw_bot_delete_command(c, command_id, r); });
    }
    response claim_commands(int limit = 10) {
        return request([&](auto* c, auto* r){ return pw_bot_claim_commands(c, limit, r); });
    }
    response respond_command(std::int64_t invocation_id, const std::string& claim_token, const std::string& body) {
        return request([&](auto* c, auto* r){ return pw_bot_respond_command(c, invocation_id, claim_token.c_str(), body.c_str(), r); });
    }
    response fail_command(std::int64_t invocation_id, const std::string& claim_token, const std::string& reason) {
        return request([&](auto* c, auto* r){ return pw_bot_fail_command(c, invocation_id, claim_token.c_str(), reason.c_str(), r); });
    }

private:
    template<class F>
    response request(F&& fn) {
        response r;
        const int rc = std::forward<F>(fn)(&raw_, r.out());
        if (rc < 0) throw std::runtime_error("Plainwire bot transport failed");
        return r;
    }
    pw_bot_client raw_{};
};

} // namespace plainwire
