#ifndef PLAINWIRE_BOT_H
#define PLAINWIRE_BOT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char *base_url;
    char *token;
    long timeout_ms;
    size_t max_response_bytes;
} pw_bot_client;

typedef struct {
    long status;
    char *body;
    size_t body_len;
} pw_bot_response;

/* Returns 0 on success. Remote plaintext HTTP is rejected; http:// is accepted
 * only for loopback development targets. */
int pw_bot_client_init(pw_bot_client *client, const char *base_url, const char *token);
void pw_bot_client_cleanup(pw_bot_client *client);
void pw_bot_response_free(pw_bot_response *response);

int pw_bot_request(pw_bot_client *client, const char *method, const char *path,
                   const char *json_body, pw_bot_response *response);

int pw_bot_capabilities(pw_bot_client *client, pw_bot_response *response);
int pw_bot_me(pw_bot_client *client, pw_bot_response *response);
int pw_bot_server(pw_bot_client *client, pw_bot_response *response);
int pw_bot_channels(pw_bot_client *client, pw_bot_response *response);
int pw_bot_messages(pw_bot_client *client, long long channel_id,
                    long long before, long long after, pw_bot_response *response);
int pw_bot_send_message(pw_bot_client *client, long long channel_id,
                        const char *body, long long reply_to_id, pw_bot_response *response);
int pw_bot_delete_message(pw_bot_client *client, long long message_id, pw_bot_response *response);
int pw_bot_toggle_reaction(pw_bot_client *client, long long message_id,
                           const char *emoji, pw_bot_response *response);
int pw_bot_edit_message(pw_bot_client *client, long long message_id, const char *body, pw_bot_response *response);
int pw_bot_pin_message(pw_bot_client *client, long long message_id, int pinned, pw_bot_response *response);
int pw_bot_channel_pins(pw_bot_client *client, long long channel_id, pw_bot_response *response);
int pw_bot_message_context(pw_bot_client *client, long long message_id, pw_bot_response *response);
int pw_bot_create_channel(pw_bot_client *client, const char *name, const char *kind, long long category_id, pw_bot_response *response);
int pw_bot_update_channel(pw_bot_client *client, long long channel_id, const char *settings_json, pw_bot_response *response);
int pw_bot_roles(pw_bot_client *client, pw_bot_response *response);
int pw_bot_create_role(pw_bot_client *client, const char *role_json, pw_bot_response *response);
int pw_bot_update_role(pw_bot_client *client, long long role_id, const char *role_json, pw_bot_response *response);
int pw_bot_delete_role(pw_bot_client *client, long long role_id, pw_bot_response *response);
int pw_bot_members(pw_bot_client *client, long long after, int limit, pw_bot_response *response);
int pw_bot_member(pw_bot_client *client, long long user_id, pw_bot_response *response);
int pw_bot_set_member_roles(pw_bot_client *client, long long user_id, const char *role_ids_json, pw_bot_response *response);
int pw_bot_kick_member(pw_bot_client *client, long long user_id, pw_bot_response *response);
int pw_bot_ban_member(pw_bot_client *client, long long user_id, const char *reason, pw_bot_response *response);
int pw_bot_unban_member(pw_bot_client *client, long long user_id, pw_bot_response *response);
int pw_bot_bans(pw_bot_client *client, pw_bot_response *response);
int pw_bot_wires(pw_bot_client *client, pw_bot_response *response);
int pw_bot_create_wire(pw_bot_client *client, long long channel_id, int max_uses, int expires_in, pw_bot_response *response);
int pw_bot_register_command(pw_bot_client *client, const char *name,
                            const char *description, const char *options_json,
                            pw_bot_response *response);
int pw_bot_sync_commands(pw_bot_client *client, const char *commands_json,
                         pw_bot_response *response);
int pw_bot_commands(pw_bot_client *client, pw_bot_response *response);
int pw_bot_delete_command(pw_bot_client *client, long long command_id, pw_bot_response *response);
int pw_bot_claim_commands(pw_bot_client *client, int limit, pw_bot_response *response);
int pw_bot_defer_command(pw_bot_client *client, long long invocation_id,
                         const char *claim_token, int lease_ms,
                         pw_bot_response *response);
int pw_bot_respond_command(pw_bot_client *client, long long invocation_id,
                           const char *claim_token, const char *body,
                           pw_bot_response *response);
int pw_bot_fail_command(pw_bot_client *client, long long invocation_id,
                        const char *claim_token, const char *reason,
                        pw_bot_response *response);

#ifdef __cplusplus
}
#endif
#endif
