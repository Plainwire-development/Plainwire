#include "plainwire_bot.h"
#include <assert.h>
#include <stdio.h>

static const char *TOKEN = "pwb_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";

int main(void) {
    pw_bot_client c;
    assert(pw_bot_client_init(&c, "http://chat.example", TOKEN) != 0);
    assert(pw_bot_client_init(&c, "http://127.0.0.1:8080", TOKEN) == 0);
    pw_bot_client_cleanup(&c);
    assert(pw_bot_client_init(&c, "https://chat.example", TOKEN) == 0);
    pw_bot_client_cleanup(&c);
    assert(pw_bot_client_init(&c, "https://user@chat.example", TOKEN) != 0);
    assert(pw_bot_client_init(&c, "https://chat.example?x=1", TOKEN) != 0);
    assert(pw_bot_client_init(&c, "https://chat.example", "pwb_bad\r\ntokenxxxxxxxx") != 0);
    puts("PASS: C SDK transport/token policy");
    return 0;
}
