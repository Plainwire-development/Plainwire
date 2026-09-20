#include "plainwire_bot.h"

#include <curl/curl.h>
#include <ctype.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define PW_DEFAULT_TIMEOUT_MS 15000L
#define PW_DEFAULT_MAX_RESPONSE (2U * 1024U * 1024U)
#define PW_MAX_URL 8192U
#define PW_MAX_REQUEST 65536U

typedef struct {
    char *data;
    size_t len;
    size_t cap;
    size_t max;
    int overflow;
} pw_buffer;

static char *pw_strdup(const char *s) {
    size_t n;
    char *out;
    if (!s) return NULL;
    n = strlen(s);
    out = (char *)malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, s, n + 1);
    return out;
}

static int pw_is_loopback_host(const char *url) {
    const char *p = strstr(url, "://");
    const char *host;
    size_t n;
    if (!p) return 0;
    host = p + 3;
    n = strcspn(host, "/:#");
    if (n == 9 && strncmp(host, "localhost", 9) == 0) return 1;
    if (n == 9 && strncmp(host, "127.0.0.1", 9) == 0) return 1;
    if (n == 3 && strncmp(host, "::1", 3) == 0) return 1;
    if (host[0] == '[') {
        const char *end = strchr(host, ']');
        if (end && (size_t)(end - host + 1) == 5 && strncmp(host, "[::1]", 5) == 0) return 1;
    }
    return 0;
}

static int pw_valid_base(const char *url) {
    size_t n;
    if (!url) return 0;
    n = strlen(url);
    if (n < 8 || n > PW_MAX_URL) return 0;
    if (strchr(url, '\r') || strchr(url, '\n') || strchr(url, '#') || strchr(url, '?')) return 0;
    /* URL userinfo is never useful for Bot-token authentication and can make
       the actual destination visually ambiguous. Reject it consistently with
       the Go/Rust/Python/JavaScript clients. */
    {
        const char *authority = strstr(url, "://");
        const char *slash;
        if (!authority) return 0;
        authority += 3;
        slash = strchr(authority, '/');
        if (memchr(authority, '@', slash ? (size_t)(slash - authority) : strlen(authority)) != NULL) return 0;
    }
    if (strncmp(url, "https://", 8) == 0) return 1;
    return strncmp(url, "http://", 7) == 0 && pw_is_loopback_host(url);
}

static void pw_trim_trailing_slashes(char *url) {
    size_t n;
    if (!url) return;
    n = strlen(url);
    while (n > 0 && url[n - 1] == '/') url[--n] = '\0';
}

static size_t pw_write(void *ptr, size_t size, size_t nmemb, void *userdata) {
    pw_buffer *b = (pw_buffer *)userdata;
    size_t n;
    char *next;
    if (size != 0 && nmemb > SIZE_MAX / size) return 0;
    n = size * nmemb;
    if (n > b->max - b->len) {
        b->overflow = 1;
        return 0;
    }
    if (b->len + n + 1 > b->cap) {
        size_t wanted = b->cap ? b->cap : 4096;
        while (wanted < b->len + n + 1 && wanted < b->max + 1) {
            if (wanted > (b->max + 1) / 2) { wanted = b->max + 1; break; }
            wanted *= 2;
        }
        next = (char *)realloc(b->data, wanted);
        if (!next) return 0;
        b->data = next;
        b->cap = wanted;
    }
    memcpy(b->data + b->len, ptr, n);
    b->len += n;
    b->data[b->len] = '\0';
    return n;
}

static char *pw_json_escape(const char *s) {
    size_t i, n, cap, len = 0;
    char *out;
    if (!s) s = "";
    n = strlen(s);
    if (n > PW_MAX_REQUEST / 2) return NULL;
    cap = n * 6 + 1;
    out = (char *)malloc(cap);
    if (!out) return NULL;
    for (i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        const char *esc = NULL;
        char unicode[7];
        switch (c) {
            case '"': esc = "\\\""; break;
            case '\\': esc = "\\\\"; break;
            case '\b': esc = "\\b"; break;
            case '\f': esc = "\\f"; break;
            case '\n': esc = "\\n"; break;
            case '\r': esc = "\\r"; break;
            case '\t': esc = "\\t"; break;
            default:
                if (c < 0x20) {
                    snprintf(unicode, sizeof(unicode), "\\u%04x", (unsigned)c);
                    esc = unicode;
                }
        }
        if (esc) {
            size_t e = strlen(esc);
            memcpy(out + len, esc, e);
            len += e;
        } else {
            out[len++] = (char)c;
        }
    }
    out[len] = '\0';
    return out;
}

int pw_bot_client_init(pw_bot_client *client, const char *base_url, const char *token) {
    size_t token_len;
    if (!client || !pw_valid_base(base_url) || !token) return -1;
    token_len = strlen(token);
    if (token_len < 16 || token_len > 256 || strncmp(token, "pwb_", 4) != 0 || strchr(token, '\r') || strchr(token, '\n')) return -1;
    memset(client, 0, sizeof(*client));
    client->base_url = pw_strdup(base_url);
    client->token = pw_strdup(token);
    if (!client->base_url || !client->token) {
        pw_bot_client_cleanup(client);
        return -2;
    }
    pw_trim_trailing_slashes(client->base_url);
    client->timeout_ms = PW_DEFAULT_TIMEOUT_MS;
    client->max_response_bytes = PW_DEFAULT_MAX_RESPONSE;
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
        pw_bot_client_cleanup(client);
        return -3;
    }
    return 0;
}

void pw_bot_client_cleanup(pw_bot_client *client) {
    if (!client) return;
    free(client->base_url);
    free(client->token);
    memset(client, 0, sizeof(*client));
}

void pw_bot_response_free(pw_bot_response *response) {
    if (!response) return;
    free(response->body);
    memset(response, 0, sizeof(*response));
}

int pw_bot_request(pw_bot_client *client, const char *method, const char *path,
                   const char *json_body, pw_bot_response *response) {
    CURL *curl = NULL;
    CURLcode rc;
    struct curl_slist *headers = NULL;
    char *url = NULL, *auth = NULL;
    size_t url_len, auth_len;
    pw_buffer buffer = {0};
    long status = 0;
    int result = -1;

    if (!client || !client->base_url || !client->token || !method || !path || !response) return -1;
    if (path[0] != '/' || strstr(path, "\r") || strstr(path, "\n") || strstr(path, "://")) return -1;
    memset(response, 0, sizeof(*response));
    if (json_body && strlen(json_body) > PW_MAX_REQUEST) return -1;

    url_len = strlen(client->base_url) + strlen(path) + 1;
    if (url_len > PW_MAX_URL) return -1;
    url = (char *)malloc(url_len);
    if (!url) goto done;
    {
        size_t base_len = strlen(client->base_url);
        size_t path_len = strlen(path);
        memcpy(url, client->base_url, base_len);
        memcpy(url + base_len, path, path_len + 1);
    }

    auth_len = strlen(client->token) + 20;
    auth = (char *)malloc(auth_len);
    if (!auth) goto done;
    snprintf(auth, auth_len, "Authorization: Bot %s", client->token);

    curl = curl_easy_init();
    if (!curl) goto done;
    buffer.max = client->max_response_bytes ? client->max_response_bytes : PW_DEFAULT_MAX_RESPONSE;

    headers = curl_slist_append(headers, auth);
    headers = curl_slist_append(headers, "Accept: application/json");
    headers = curl_slist_append(headers, "User-Agent: plainwire-c-bot/2.2");
    if (json_body) headers = curl_slist_append(headers, "Content-Type: application/json");
    if (!headers) goto done;

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, client->timeout_ms > 0 ? client->timeout_ms : PW_DEFAULT_TIMEOUT_MS);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, 8000L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 0L);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "https");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, pw_write);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buffer);
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
    if (json_body) {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(json_body));
    }

    rc = curl_easy_perform(curl);
    if (rc != CURLE_OK) {
        result = buffer.overflow ? -5 : -4;
        goto done;
    }
    if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK) goto done;
    if (!buffer.data) {
        buffer.data = pw_strdup("");
        if (!buffer.data) goto done;
    }
    response->status = status;
    response->body = buffer.data;
    response->body_len = buffer.len;
    buffer.data = NULL;
    result = (status >= 200 && status < 300) ? 0 : 1;

done:
    free(buffer.data);
    if (curl) curl_easy_cleanup(curl);
    curl_slist_free_all(headers);
    if (auth) { memset(auth, 0, strlen(auth)); free(auth); }
    free(url);
    return result;
}

static int pw_simple(pw_bot_client *c, const char *method, const char *path, const char *body, pw_bot_response *r) {
    return pw_bot_request(c, method, path, body, r);
}

int pw_bot_capabilities(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c, "GET", "/api/bot/v1", NULL, r); }
int pw_bot_me(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c, "GET", "/api/bot/v1/me", NULL, r); }
int pw_bot_server(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c, "GET", "/api/bot/v1/server", NULL, r); }
int pw_bot_channels(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c, "GET", "/api/bot/v1/channels", NULL, r); }

int pw_bot_messages(pw_bot_client *c, long long channel_id, long long before, long long after, pw_bot_response *r) {
    char path[256];
    snprintf(path, sizeof(path), "/api/bot/v1/channels/%lld/messages?before=%lld&after=%lld", channel_id, before, after);
    return pw_simple(c, "GET", path, NULL, r);
}

int pw_bot_send_message(pw_bot_client *c, long long channel_id, const char *body, long long reply_to_id, pw_bot_response *r) {
    char path[192], *escaped = pw_json_escape(body), *json;
    size_t n;
    int rc;
    if (!escaped) return -2;
    snprintf(path, sizeof(path), "/api/bot/v1/channels/%lld/messages", channel_id);
    n = strlen(escaped) + 96;
    json = (char *)malloc(n);
    if (!json) { free(escaped); return -2; }
    if (reply_to_id > 0) snprintf(json, n, "{\"body\":\"%s\",\"reply_to_id\":%lld}", escaped, reply_to_id);
    else snprintf(json, n, "{\"body\":\"%s\"}", escaped);
    rc = pw_simple(c, "POST", path, json, r);
    free(json); free(escaped); return rc;
}

int pw_bot_delete_message(pw_bot_client *c, long long message_id, pw_bot_response *r) {
    char path[192]; snprintf(path, sizeof(path), "/api/bot/v1/messages/%lld/delete", message_id);
    return pw_simple(c, "POST", path, "{}", r);
}

int pw_bot_toggle_reaction(pw_bot_client *c, long long message_id, const char *emoji, pw_bot_response *r) {
    char path[192], *escaped = pw_json_escape(emoji), *json; size_t n; int rc;
    if (!escaped) return -2;
    snprintf(path, sizeof(path), "/api/bot/v1/messages/%lld/reaction", message_id);
    n = strlen(escaped) + 32; json = (char *)malloc(n); if (!json) { free(escaped); return -2; }
    snprintf(json, n, "{\"emoji\":\"%s\"}", escaped);
    rc = pw_simple(c, "POST", path, json, r); free(json); free(escaped); return rc;
}

int pw_bot_edit_message(pw_bot_client *c, long long message_id, const char *body, pw_bot_response *r) {
    char path[192], *escaped = pw_json_escape(body), *json; size_t n; int rc;
    if (!escaped) return -2;
    snprintf(path, sizeof(path), "/api/bot/v1/messages/%lld/edit", message_id);
    n = strlen(escaped) + 32; json = (char *)malloc(n); if (!json) { free(escaped); return -2; }
    snprintf(json, n, "{\"body\":\"%s\"}", escaped); rc = pw_simple(c, "POST", path, json, r); free(json); free(escaped); return rc;
}
int pw_bot_pin_message(pw_bot_client *c, long long message_id, int pinned, pw_bot_response *r) {
    char path[192]; snprintf(path, sizeof(path), "/api/bot/v1/messages/%lld/pin", message_id);
    return pw_simple(c, "POST", path, pinned ? "{\"pinned\":true}" : "{\"pinned\":false}", r);
}
int pw_bot_channel_pins(pw_bot_client *c, long long channel_id, pw_bot_response *r) {
    char path[192]; snprintf(path, sizeof(path), "/api/bot/v1/channels/%lld/pins", channel_id); return pw_simple(c, "GET", path, NULL, r);
}
int pw_bot_message_context(pw_bot_client *c, long long message_id, pw_bot_response *r) {
    char path[192]; snprintf(path, sizeof(path), "/api/bot/v1/messages/%lld/context", message_id); return pw_simple(c, "GET", path, NULL, r);
}
int pw_bot_create_channel(pw_bot_client *c, const char *name, const char *kind, long long category_id, pw_bot_response *r) {
    char *n1 = pw_json_escape(name), *k1 = pw_json_escape(kind ? kind : "text"), *json; size_t n; int rc;
    if (!n1 || !k1) { free(n1); free(k1); return -2; } n = strlen(n1) + strlen(k1) + 96; json = (char *)malloc(n); if (!json) { free(n1); free(k1); return -2; }
    if (category_id > 0) snprintf(json, n, "{\"name\":\"%s\",\"kind\":\"%s\",\"category_id\":%lld}", n1, k1, category_id);
    else snprintf(json, n, "{\"name\":\"%s\",\"kind\":\"%s\"}", n1, k1);
    rc = pw_simple(c, "POST", "/api/bot/v1/channels", json, r); free(json); free(n1); free(k1); return rc;
}
int pw_bot_update_channel(pw_bot_client *c, long long channel_id, const char *settings_json, pw_bot_response *r) {
    char path[192]; snprintf(path, sizeof(path), "/api/bot/v1/channels/%lld/settings", channel_id); return pw_simple(c, "POST", path, settings_json ? settings_json : "{}", r);
}
int pw_bot_roles(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c, "GET", "/api/bot/v1/roles", NULL, r); }
int pw_bot_create_role(pw_bot_client *c, const char *role_json, pw_bot_response *r) { return pw_simple(c, "POST", "/api/bot/v1/roles", role_json ? role_json : "{}", r); }
int pw_bot_update_role(pw_bot_client *c, long long role_id, const char *role_json, pw_bot_response *r) { char path[192]; snprintf(path,sizeof(path),"/api/bot/v1/roles/%lld",role_id); return pw_simple(c,"POST",path,role_json?role_json:"{}",r); }
int pw_bot_delete_role(pw_bot_client *c, long long role_id, pw_bot_response *r) { char path[192]; snprintf(path,sizeof(path),"/api/bot/v1/roles/%lld",role_id); return pw_simple(c,"DELETE",path,NULL,r); }
int pw_bot_members(pw_bot_client *c, long long after, int limit, pw_bot_response *r) {
    char path[192]; if (after < 0) after = 0; if (limit < 1) limit = 1; if (limit > 200) limit = 200;
    snprintf(path,sizeof(path),"/api/bot/v1/members?after=%lld&limit=%d",after,limit); return pw_simple(c,"GET",path,NULL,r);
}
int pw_bot_member(pw_bot_client *c, long long user_id, pw_bot_response *r) { char path[192]; snprintf(path,sizeof(path),"/api/bot/v1/members/%lld",user_id); return pw_simple(c,"GET",path,NULL,r); }
int pw_bot_set_member_roles(pw_bot_client *c, long long user_id, const char *role_ids_json, pw_bot_response *r) {
    char path[192], *json; size_t n; int rc; const char *ids = role_ids_json ? role_ids_json : "[]";
    if (strlen(ids) > 32768) return -1;
    snprintf(path, sizeof(path), "/api/bot/v1/members/%lld/roles", user_id);
    n = strlen(ids) + 32; json = (char *)malloc(n); if (!json) return -2;
    snprintf(json, n, "{\"role_ids\":%s}", ids);
    rc = pw_simple(c, "POST", path, json, r); free(json); return rc;
}
int pw_bot_kick_member(pw_bot_client *c, long long user_id, pw_bot_response *r) { char path[192]; snprintf(path,sizeof(path),"/api/bot/v1/members/%lld/kick",user_id); return pw_simple(c,"POST",path,"{}",r); }
int pw_bot_ban_member(pw_bot_client *c, long long user_id, const char *reason, pw_bot_response *r) {
    char path[192], *escaped=pw_json_escape(reason), *json; size_t n; int rc; if(!escaped)return -2; snprintf(path,sizeof(path),"/api/bot/v1/members/%lld/ban",user_id); n=strlen(escaped)+32; json=(char*)malloc(n); if(!json){free(escaped);return -2;} snprintf(json,n,"{\"reason\":\"%s\"}",escaped); rc=pw_simple(c,"POST",path,json,r); free(json); free(escaped); return rc;
}
int pw_bot_unban_member(pw_bot_client *c, long long user_id, pw_bot_response *r) { char path[192]; snprintf(path,sizeof(path),"/api/bot/v1/members/%lld/unban",user_id); return pw_simple(c,"POST",path,"{}",r); }
int pw_bot_bans(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c,"GET","/api/bot/v1/bans",NULL,r); }
int pw_bot_wires(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c,"GET","/api/bot/v1/wires",NULL,r); }
int pw_bot_create_wire(pw_bot_client *c, long long channel_id, int max_uses, int expires_in, pw_bot_response *r) {
    char json[192]; snprintf(json,sizeof(json),"{\"channel_id\":%lld,\"max_uses\":%d,\"expires_in\":%d}",channel_id,max_uses,expires_in); return pw_simple(c,"POST","/api/bot/v1/wires",json,r);
}

int pw_bot_register_command(pw_bot_client *c, const char *name, const char *description, const char *options_json, pw_bot_response *r) {
    char *n1 = pw_json_escape(name), *d1 = pw_json_escape(description), *json; size_t n; int rc;
    if (!n1 || !d1) { free(n1); free(d1); return -2; }
    if (!options_json || strlen(options_json) > 32768) options_json = "[]";
    n = strlen(n1) + strlen(d1) + strlen(options_json) + 64; json = (char *)malloc(n);
    if (!json) { free(n1); free(d1); return -2; }
    snprintf(json, n, "{\"name\":\"%s\",\"description\":\"%s\",\"options\":%s}", n1, d1, options_json);
    rc = pw_simple(c, "POST", "/api/bot/v1/commands", json, r);
    free(json); free(n1); free(d1); return rc;
}
int pw_bot_sync_commands(pw_bot_client *c, const char *commands_json, pw_bot_response *r) {
    char *json; size_t n; int rc;
    if (!commands_json) commands_json = "[]";
    if (strlen(commands_json) > PW_MAX_REQUEST - 32) return -1;
    n = strlen(commands_json) + 32; json = (char *)malloc(n); if (!json) return -2;
    snprintf(json, n, "{\"commands\":%s}", commands_json);
    rc = pw_simple(c, "PUT", "/api/bot/v1/commands", json, r); free(json); return rc;
}
int pw_bot_commands(pw_bot_client *c, pw_bot_response *r) { return pw_simple(c, "GET", "/api/bot/v1/commands", NULL, r); }
int pw_bot_delete_command(pw_bot_client *c, long long command_id, pw_bot_response *r) {
    char path[160]; snprintf(path, sizeof(path), "/api/bot/v1/commands/%lld", command_id); return pw_simple(c, "DELETE", path, NULL, r);
}
int pw_bot_claim_commands(pw_bot_client *c, int limit, pw_bot_response *r) {
    char path[160]; if (limit < 1) limit = 1; if (limit > 50) limit = 50;
    snprintf(path, sizeof(path), "/api/bot/v1/commands/claims?limit=%d", limit); return pw_simple(c, "GET", path, NULL, r);
}
int pw_bot_defer_command(pw_bot_client *c, long long id, const char *token, int lease_ms, pw_bot_response *r) {
    char path[224], *escaped = pw_json_escape(token), *json; size_t n; int rc;
    if (!escaped) return -2;
    if (lease_ms < 5000) lease_ms = 5000;
    if (lease_ms > 120000) lease_ms = 120000;
    snprintf(path, sizeof(path), "/api/bot/v1/commands/claims/%lld/defer", id);
    n = strlen(escaped) + 80; json = (char *)malloc(n); if (!json) { free(escaped); return -2; }
    snprintf(json, n, "{\"claim_token\":\"%s\",\"lease_ms\":%d}", escaped, lease_ms);
    rc = pw_simple(c, "POST", path, json, r); free(json); free(escaped); return rc;
}

static int pw_claim_action(pw_bot_client *c, long long id, const char *token, const char *field, const char *value, const char *action, pw_bot_response *r) {
    char path[224], *t = pw_json_escape(token), *v = pw_json_escape(value), *json; size_t n; int rc;
    if (!t || !v) { free(t); free(v); return -2; }
    snprintf(path, sizeof(path), "/api/bot/v1/commands/claims/%lld/%s", id, action);
    n = strlen(t) + strlen(v) + strlen(field) + 64; json = (char *)malloc(n); if (!json) { free(t); free(v); return -2; }
    snprintf(json, n, "{\"claim_token\":\"%s\",\"%s\":\"%s\"}", t, field, v);
    rc = pw_simple(c, "POST", path, json, r); free(json); free(t); free(v); return rc;
}
int pw_bot_respond_command(pw_bot_client *c, long long id, const char *token, const char *body, pw_bot_response *r) {
    return pw_claim_action(c, id, token, "body", body, "respond", r);
}
int pw_bot_fail_command(pw_bot_client *c, long long id, const char *token, const char *reason, pw_bot_response *r) {
    return pw_claim_action(c, id, token, "reason", reason, "fail", r);
}
