use reqwest::blocking::{Client as HttpClient, Response};
use reqwest::redirect::Policy;
use serde::Serialize;
use serde_json::{json, Value};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::time::Duration;
use url::Url;

const API: &str = "/api/bot/v1";
const MAX_RESPONSE: u64 = 2 * 1024 * 1024;
const MAX_REQUEST: usize = 64 * 1024;

#[derive(Debug)]
pub enum Error {
    InvalidBaseUrl,
    InvalidToken,
    InvalidPath,
    RequestTooLarge,
    ResponseTooLarge,
    Http(reqwest::Error),
    Api { status: u16, body: String },
    Json(serde_json::Error),
    Io(std::io::Error),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Api { status, .. } => write!(f, "Plainwire API returned HTTP {status}"),
            x => write!(f, "{x:?}"),
        }
    }
}
impl std::error::Error for Error {}
impl From<reqwest::Error> for Error {
    fn from(e: reqwest::Error) -> Self {
        Self::Http(e)
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e)
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

#[derive(Clone)]
pub struct Client {
    base: Url,
    token: String,
    http: HttpClient,
    max_response: u64,
}

fn is_loopback(host: &str) -> bool {
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    host.parse::<IpAddr>()
        .map(|ip| ip.is_loopback())
        .unwrap_or(false)
        || host == Ipv4Addr::LOCALHOST.to_string()
        || host == Ipv6Addr::LOCALHOST.to_string()
}

impl Client {
    pub fn new(base_url: &str, token: &str) -> Result<Self, Error> {
        let mut base = Url::parse(base_url).map_err(|_| Error::InvalidBaseUrl)?;
        if base.host_str().is_none()
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
        {
            return Err(Error::InvalidBaseUrl);
        }
        if base.scheme() != "https"
            && !(base.scheme() == "http" && is_loopback(base.host_str().unwrap_or("")))
        {
            return Err(Error::InvalidBaseUrl);
        }
        if !token.starts_with("pwb_")
            || token.len() < 16
            || token.len() > 256
            || token.contains('\r')
            || token.contains('\n')
        {
            return Err(Error::InvalidToken);
        }
        let normalized_path = base.path().trim_end_matches('/').to_owned();
        base.set_path(&normalized_path);
        base.set_query(None);
        base.set_fragment(None);
        let http = HttpClient::builder()
            .timeout(Duration::from_secs(15))
            .connect_timeout(Duration::from_secs(8))
            .redirect(Policy::none())
            .user_agent("plainwire-rust-bot/2.2")
            .build()?;
        Ok(Self {
            base,
            token: token.into(),
            http,
            max_response: MAX_RESPONSE,
        })
    }
    fn url(&self, path: &str) -> Result<Url, Error> {
        if !path.starts_with('/')
            || path.contains("://")
            || path.contains('\r')
            || path.contains('\n')
        {
            return Err(Error::InvalidPath);
        }
        let (p, q) = path
            .split_once('?')
            .map_or((path, None), |(p, q)| (p, Some(q)));
        let mut u = self.base.clone();
        u.set_path(&format!("{}{}", self.base.path().trim_end_matches('/'), p));
        u.set_query(q);
        Ok(u)
    }
    pub fn request<T: Serialize + ?Sized>(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<&T>,
    ) -> Result<Value, Error> {
        let mut req = self
            .http
            .request(method, self.url(path)?)
            .header("Authorization", format!("Bot {}", self.token))
            .header("Accept", "application/json");
        if let Some(v) = body {
            let bytes = serde_json::to_vec(v)?;
            if bytes.len() > MAX_REQUEST {
                return Err(Error::RequestTooLarge);
            }
            req = req.header("Content-Type", "application/json").body(bytes);
        }
        let mut res = req.send()?;
        self.decode(&mut res)
    }
    fn decode(&self, res: &mut Response) -> Result<Value, Error> {
        let status = res.status();
        if res.content_length().is_some_and(|n| n > self.max_response) {
            return Err(Error::ResponseTooLarge);
        }
        use std::io::Read;
        let mut buf = Vec::new();
        res.take(self.max_response + 1).read_to_end(&mut buf)?;
        if buf.len() as u64 > self.max_response {
            return Err(Error::ResponseTooLarge);
        }
        let text = String::from_utf8_lossy(&buf).into_owned();
        if !status.is_success() {
            return Err(Error::Api {
                status: status.as_u16(),
                body: text,
            });
        }
        Ok(serde_json::from_slice(&buf)?)
    }
    pub fn capabilities(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, API, None)
    }
    pub fn me(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, &format!("{API}/me"), None)
    }
    pub fn server(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, &format!("{API}/server"), None)
    }
    pub fn channels(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, &format!("{API}/channels"), None)
    }
    pub fn messages(
        &self,
        channel_id: i64,
        before: Option<i64>,
        after: Option<i64>,
    ) -> Result<Value, Error> {
        let mut query = Vec::new();
        if let Some(v) = before {
            query.push(format!("before={v}"));
        }
        if let Some(v) = after {
            query.push(format!("after={v}"));
        }
        let suffix = if query.is_empty() {
            String::new()
        } else {
            format!("?{}", query.join("&"))
        };
        self.request::<Value>(
            reqwest::Method::GET,
            &format!("{API}/channels/{channel_id}/messages{suffix}"),
            None,
        )
    }
    pub fn send_message(
        &self,
        channel_id: i64,
        body: &str,
        reply_to: Option<i64>,
    ) -> Result<Value, Error> {
        let mut p = json!({"body":body});
        if let Some(id) = reply_to {
            p["reply_to_id"] = json!(id)
        }
        self.request(
            reqwest::Method::POST,
            &format!("{API}/channels/{channel_id}/messages"),
            Some(&p),
        )
    }
    pub fn delete_message(&self, message_id: i64) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/messages/{message_id}/delete"),
            Some(&json!({})),
        )
    }
    pub fn toggle_reaction(&self, message_id: i64, emoji: &str) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/messages/{message_id}/reaction"),
            Some(&json!({"emoji":emoji})),
        )
    }
    pub fn edit_message(&self, message_id: i64, body: &str) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/messages/{message_id}/edit"),
            Some(&json!({"body":body})),
        )
    }
    pub fn pin_message(&self, message_id: i64, pinned: bool) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/messages/{message_id}/pin"),
            Some(&json!({"pinned":pinned})),
        )
    }
    pub fn pins(&self, channel_id: i64) -> Result<Value, Error> {
        self.request::<Value>(
            reqwest::Method::GET,
            &format!("{API}/channels/{channel_id}/pins"),
            None,
        )
    }
    pub fn message_context(&self, message_id: i64) -> Result<Value, Error> {
        self.request::<Value>(
            reqwest::Method::GET,
            &format!("{API}/messages/{message_id}/context"),
            None,
        )
    }
    pub fn create_channel(
        &self,
        name: &str,
        kind: &str,
        category_id: Option<i64>,
    ) -> Result<Value, Error> {
        let mut p = json!({"name":name,"kind":kind});
        if let Some(id) = category_id {
            p["category_id"] = json!(id)
        }
        self.request(reqwest::Method::POST, &format!("{API}/channels"), Some(&p))
    }
    pub fn update_channel(&self, channel_id: i64, patch: Value) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/channels/{channel_id}/settings"),
            Some(&patch),
        )
    }
    pub fn roles(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, &format!("{API}/roles"), None)
    }
    pub fn create_role(&self, name: &str, patch: Value) -> Result<Value, Error> {
        let mut p = match patch {
            Value::Object(m) => Value::Object(m),
            _ => json!({}),
        };
        p["name"] = json!(name);
        self.request(reqwest::Method::POST, &format!("{API}/roles"), Some(&p))
    }
    pub fn update_role(&self, role_id: i64, patch: Value) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/roles/{role_id}"),
            Some(&patch),
        )
    }
    pub fn delete_role(&self, role_id: i64) -> Result<Value, Error> {
        self.request::<Value>(
            reqwest::Method::DELETE,
            &format!("{API}/roles/{role_id}"),
            None,
        )
    }
    pub fn members(&self, after: Option<i64>, limit: u16) -> Result<Value, Error> {
        let suffix = after
            .filter(|v| *v > 0)
            .map(|v| format!("&after={v}"))
            .unwrap_or_default();
        self.request::<Value>(
            reqwest::Method::GET,
            &format!("{API}/members?limit={}{}", limit.clamp(1, 200), suffix),
            None,
        )
    }
    pub fn member(&self, user_id: i64) -> Result<Value, Error> {
        self.request::<Value>(
            reqwest::Method::GET,
            &format!("{API}/members/{user_id}"),
            None,
        )
    }
    pub fn set_member_roles(&self, user_id: i64, role_ids: &[i64]) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/members/{user_id}/roles"),
            Some(&json!({"role_ids":role_ids})),
        )
    }
    pub fn kick_member(&self, user_id: i64) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/members/{user_id}/kick"),
            Some(&json!({})),
        )
    }
    pub fn ban_member(&self, user_id: i64, reason: &str) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/members/{user_id}/ban"),
            Some(&json!({"reason":reason})),
        )
    }
    pub fn unban_member(&self, user_id: i64) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/members/{user_id}/unban"),
            Some(&json!({})),
        )
    }
    pub fn bans(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, &format!("{API}/bans"), None)
    }
    pub fn wires(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, &format!("{API}/wires"), None)
    }
    pub fn create_wire(
        &self,
        channel_id: i64,
        max_uses: i64,
        expires_in: i64,
    ) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/wires"),
            Some(&json!({"channel_id":channel_id,"max_uses":max_uses,"expires_in":expires_in})),
        )
    }
    pub fn register_command(
        &self,
        name: &str,
        description: &str,
        options: Value,
    ) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/commands"),
            Some(&json!({"name":name,"description":description,"options":options})),
        )
    }
    pub fn sync_commands(&self, commands: Value) -> Result<Value, Error> {
        self.request(
            reqwest::Method::PUT,
            &format!("{API}/commands"),
            Some(&json!({"commands":commands})),
        )
    }
    pub fn commands(&self) -> Result<Value, Error> {
        self.request::<Value>(reqwest::Method::GET, &format!("{API}/commands"), None)
    }
    pub fn delete_command(&self, command_id: i64) -> Result<Value, Error> {
        self.request::<Value>(
            reqwest::Method::DELETE,
            &format!("{API}/commands/{command_id}"),
            None,
        )
    }
    pub fn claim_commands(&self, limit: u8) -> Result<Value, Error> {
        self.request::<Value>(
            reqwest::Method::GET,
            &format!("{API}/commands/claims?limit={}", limit.clamp(1, 50)),
            None,
        )
    }
    pub fn defer_command(&self, id: i64, claim_token: &str, lease_ms: u64) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/commands/claims/{id}/defer"),
            Some(&json!({"claim_token":claim_token,"lease_ms":lease_ms.clamp(5000,120000)})),
        )
    }
    pub fn respond_command(&self, id: i64, claim_token: &str, body: &str) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/commands/claims/{id}/respond"),
            Some(&json!({"claim_token":claim_token,"body":body})),
        )
    }
    pub fn fail_command(&self, id: i64, claim_token: &str, reason: &str) -> Result<Value, Error> {
        self.request(
            reqwest::Method::POST,
            &format!("{API}/commands/claims/{id}/fail"),
            Some(&json!({"claim_token":claim_token,"reason":reason})),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const T: &str = "pwb_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    #[test]
    fn remote_http_refused() {
        assert!(Client::new("http://chat.example", T).is_err())
    }
    #[test]
    fn loopback_http_ok() {
        assert!(Client::new("http://127.0.0.1:8080", T).is_ok())
    }
    #[test]
    fn https_ok() {
        assert!(Client::new("https://chat.example", T).is_ok())
    }
}
