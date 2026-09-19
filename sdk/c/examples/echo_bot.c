#include "plainwire_bot.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int main(void) {
    const char *base = getenv("PLAINWIRE_BASE_URL");
    const char *token = getenv("PLAINWIRE_BOT_TOKEN");
    pw_bot_client bot;
    pw_bot_response response;
    if (!base) base = "http://127.0.0.1:8080";
    if (pw_bot_client_init(&bot, base, token) != 0) {
        fputs("Set PLAINWIRE_BOT_TOKEN and a valid HTTPS PLAINWIRE_BASE_URL.\n", stderr);
        return 2;
    }
    if (pw_bot_register_command(&bot, "echo", "Echo text back to the channel", "[]", &response) == 0) {
        pw_bot_response_free(&response);
    }
    puts("echo bot ready; polling durable command claims");
    for (;;) {
        int rc = pw_bot_claim_commands(&bot, 10, &response);
        if (rc == 0 && response.body_len > 0) {
            /* This intentionally leaves JSON parsing to the host application. The C
             * SDK owns transport/security; production bots commonly use yyjson,
             * jansson or cJSON for domain models. */
            fwrite(response.body, 1, response.body_len, stdout);
            fputc('\n', stdout);
        }
        pw_bot_response_free(&response);
        { struct timespec ts = {1, 0}; nanosleep(&ts, NULL); }
    }
    pw_bot_client_cleanup(&bot);
    return 0;
}
