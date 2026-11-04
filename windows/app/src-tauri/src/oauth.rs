//! OAuth 2.1 for remote MCP servers, as in macos/Sources/MeetNotes/Core/MCP/MCPOAuth.swift:
//! protected-resource and authorization-server discovery, dynamic client registration (or an app
//! registered by hand), PKCE, the resource parameter, a loopback redirect and token refresh.
#[cfg_attr(test, allow(unused_imports))]
use crate::settings;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
type Res<T> = Result<T, String>;

/// Prefix of the error the UI turns into a "Sign in" button.
pub const SIGN_IN_REQUIRED: &str = "sign-in-required";
/// Redirect port for apps registered by hand: their redirect URL has to be fixed.
pub const FIXED_PORT: u16 = 47821;

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Tokens {
    pub client_id: String,
    pub client_secret: Option<String>,
    pub client_auth: Option<String>,
    pub token_endpoint: String,
    pub resource: Option<String>,
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: Option<u64>,
}

static REFRESH: Mutex<()> = Mutex::new(());

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
fn key(id: &str) -> String {
    format!("mcp.oauth.{id}")
}
// Tests keep tokens in memory: off Windows the keyring crate has no persistent store.
#[cfg(test)]
static TEST_STORE: Mutex<std::collections::BTreeMap<String, String>> = Mutex::new(std::collections::BTreeMap::new());
fn load(name: &str) -> Res<String> {
    #[cfg(test)]
    return Ok(TEST_STORE.lock().unwrap().get(name).cloned().unwrap_or_default());
    #[cfg(not(test))]
    settings::secret(name)
}
fn save(name: &str, value: &str) -> Res<()> {
    #[cfg(test)]
    {
        let mut m = TEST_STORE.lock().unwrap();
        if value.is_empty() { m.remove(name); } else { m.insert(name.into(), value.into()); }
        return Ok(());
    }
    #[cfg(not(test))]
    settings::set_secret(name, value)
}
pub fn tokens(id: &str) -> Option<Tokens> {
    serde_json::from_str(&load(&key(id)).ok()?).ok()
}
pub fn set_tokens(id: &str, t: Option<&Tokens>) -> Res<()> {
    let text = t
        .map(|t| serde_json::to_string(t).unwrap_or_default())
        .unwrap_or_default();
    save(&key(id), &text)
}
pub fn signed_in(id: &str) -> bool {
    tokens(id).is_some()
}
pub fn sign_in_required(name: &str) -> String {
    format!("{SIGN_IN_REQUIRED}: Sign in to {name} to use it.")
}

/// The bearer token for a request, refreshed a minute before it expires. None: the user has to sign in.
pub fn access_token(id: &str, force_refresh: bool) -> Res<Option<String>> {
    // One refresh at a time: some servers rotate refresh tokens and revoke the grant when an old one is reused.
    let _guard = REFRESH.lock().unwrap_or_else(|e| e.into_inner());
    let Some(t) = tokens(id) else { return Ok(None) };
    let stale = t.expires_at.is_some_and(|at| at < now() + 60);
    if !force_refresh && !stale {
        return Ok(Some(t.access_token));
    }
    let Some(refresh) = t.refresh_token.clone() else {
        return Ok(if force_refresh { None } else { Some(t.access_token) });
    };
    let mut params = vec![
        ("grant_type", "refresh_token".to_string()),
        ("refresh_token", refresh.clone()),
    ];
    if let Some(r) = &t.resource {
        params.push(("resource", r.clone()));
    }
    match token_request(&t, &params) {
        Ok(mut fresh) => {
            if fresh.refresh_token.is_none() {
                fresh.refresh_token = Some(refresh);
            }
            set_tokens(id, Some(&fresh))?;
            Ok(Some(fresh.access_token))
        }
        Err(e) if e.starts_with("invalid_grant") => {
            set_tokens(id, None)?; // expired or revoked: sign in again
            Ok(None)
        }
        Err(e) => Err(e),
    }
}

pub struct Endpoints {
    pub authorize: String,
    pub token: String,
    pub registration: Option<String>,
    pub resource: Option<String>,
    pub scope: Option<String>,
}

fn http() -> Res<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())
}
fn get_json(url: &str) -> Option<Value> {
    let r = http().ok()?.get(url).send().ok()?;
    if r.status().as_u16() != 200 {
        return None;
    }
    r.json::<Value>().ok().filter(Value::is_object)
}
fn origin_and_path(url: &reqwest::Url) -> (String, String) {
    let origin = url.origin().ascii_serialization();
    let path = if url.path() == "/" { String::new() } else { url.path().to_string() };
    (origin, path)
}

/// `Bearer realm="x", resource_metadata="https://…", scope="a b"` → its parameters.
pub fn parse_challenge(header: &str) -> std::collections::BTreeMap<String, String> {
    let mut out = std::collections::BTreeMap::new();
    let mut rest = header;
    while let Some(eq) = rest.find("=\"") {
        let name = rest[..eq]
            .rsplit(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .next()
            .unwrap_or("")
            .to_string();
        let value_start = eq + 2;
        let Some(len) = rest[value_start..].find('"') else { break };
        out.insert(name, rest[value_start..value_start + len].to_string());
        rest = &rest[value_start + len + 1..];
    }
    out
}

/// Where to sign in: protected-resource metadata (from the 401 challenge or the well-known URL), then the
/// authorization server's metadata. Servers from before that spec get /authorize, /token and /register.
pub fn discover(server_url: &str) -> Res<Endpoints> {
    let url = reqwest::Url::parse(server_url).map_err(|e| e.to_string())?;
    let (origin, path) = origin_and_path(&url);
    let probe = http()?
        .post(url.as_str())
        .header("Accept", "application/json, text/event-stream")
        .json(&json!({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Keepword","version":"0.1.0"}}}))
        .send()
        .ok();
    let challenge = probe
        .as_ref()
        .and_then(|r| r.headers().get("www-authenticate"))
        .and_then(|v| v.to_str().ok())
        .map(parse_challenge)
        .unwrap_or_default();
    let mut candidates: Vec<String> = challenge.get("resource_metadata").cloned().into_iter().collect();
    candidates.push(format!("{origin}/.well-known/oauth-protected-resource{path}"));
    candidates.push(format!("{origin}/.well-known/oauth-protected-resource"));
    let prm = candidates.iter().find_map(|c| get_json(c));
    let issuer = prm
        .as_ref()
        .and_then(|p| p["authorization_servers"][0].as_str())
        .unwrap_or(&origin)
        .to_string();
    let issuer_url = reqwest::Url::parse(&issuer).map_err(|e| e.to_string())?;
    let (io, ip) = origin_and_path(&issuer_url);
    let meta_candidates = if ip.is_empty() {
        vec![
            format!("{io}/.well-known/oauth-authorization-server"),
            format!("{io}/.well-known/openid-configuration"),
        ]
    } else {
        vec![
            format!("{io}/.well-known/oauth-authorization-server{ip}"),
            format!("{io}/.well-known/openid-configuration{ip}"),
            format!("{io}{ip}/.well-known/openid-configuration"),
        ]
    };
    let meta = meta_candidates.iter().find_map(|c| get_json(c));
    let mut canonical = url.clone();
    canonical.set_query(None);
    canonical.set_fragment(None);
    let scope = challenge.get("scope").cloned().or_else(|| {
        prm.as_ref()
            .and_then(|p| p["scopes_supported"].as_array())
            .map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "))
    });
    Ok(Endpoints {
        authorize: meta
            .as_ref()
            .and_then(|m| m["authorization_endpoint"].as_str())
            .map_or(format!("{io}/authorize"), str::to_string),
        token: meta
            .as_ref()
            .and_then(|m| m["token_endpoint"].as_str())
            .map_or(format!("{io}/token"), str::to_string),
        registration: match &meta {
            None => Some(format!("{io}/register")),
            Some(m) => m["registration_endpoint"].as_str().map(str::to_string),
        },
        resource: Some(
            prm.as_ref()
                .and_then(|p| p["resource"].as_str())
                .map_or(canonical.to_string(), str::to_string),
        ),
        scope,
    })
}

fn random() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    URL_SAFE_NO_PAD.encode(bytes)
}

fn token_request(client: &Tokens, params: &[(&str, String)]) -> Res<Tokens> {
    let mut form: Vec<(&str, String)> = params.to_vec();
    let mut request = http()?
        .post(&client.token_endpoint)
        .header("Accept", "application/json");
    match (&client.client_secret, client.client_auth.as_deref()) {
        (Some(secret), Some("client_secret_basic")) => {
            request = request.basic_auth(&client.client_id, Some(secret));
        }
        (secret, _) => {
            form.push(("client_id", client.client_id.clone()));
            if let Some(s) = secret {
                form.push(("client_secret", s.clone()));
            }
        }
    }
    let response = request.form(&form).send().map_err(|e| e.to_string())?;
    let status = response.status().as_u16();
    let body: Value = response.json().unwrap_or(Value::Null);
    let Some(access) = body["access_token"].as_str().filter(|_| status == 200) else {
        let code = body["error"].as_str().map_or(format!("http_{status}"), str::to_string);
        let detail = body["error_description"].as_str().unwrap_or(&code).to_string();
        return Err(format!("{code}: Sign-in failed: {detail}"));
    };
    let mut t = client.clone();
    t.access_token = access.into();
    t.refresh_token = body["refresh_token"].as_str().map(str::to_string);
    t.expires_at = body["expires_in"]
        .as_u64()
        .or_else(|| body["expires_in"].as_str().and_then(|s| s.parse().ok()))
        .map(|s| now() + s);
    Ok(t)
}

/// Runs the browser sign-in for a server config and stores the tokens.
/// `open` shows the authorization page; `scope` "" sends none, None uses what the server asks for.
pub fn sign_in(config: &Value, open: impl FnOnce(&str) -> Res<()>) -> Res<()> {
    let id = config["id"].as_str().ok_or("MCP server needs an id")?;
    let name = config["name"].as_str().unwrap_or("MCP server");
    let url = config["url"].as_str().ok_or("MCP URL is missing")?;
    let found = discover(url)?;
    let client_id = config["clientId"].as_str().unwrap_or("").trim().to_string();
    let manual = !client_id.is_empty();
    if !manual && found.registration.is_none() {
        return Err(format!("{name} doesn't register apps automatically. Create an OAuth app in its developer settings with the redirect URL http://localhost:{FIXED_PORT}/callback and enter its client ID and secret."));
    }
    let server = tiny_http::Server::http(("127.0.0.1", if manual { FIXED_PORT } else { 0 }))
        .map_err(|_| format!("Port {FIXED_PORT} for the sign-in redirect is busy. Close the app that uses it and try again."))?;
    let port = server.server_addr().to_ip().map(|a| a.port()).ok_or("No loopback port")?;
    let redirect = format!("http://localhost:{port}/callback");

    let secret = load(&format!("mcp.client.{id}"))?;
    let mut client = Tokens {
        client_id,
        client_secret: (!secret.is_empty()).then_some(secret),
        token_endpoint: found.token.clone(),
        resource: found.resource.clone(),
        ..Default::default()
    };
    if !manual {
        let registration = found.registration.as_deref().unwrap_or_default();
        let response = http()?
            .post(registration)
            .json(&json!({"client_name":"Keepword","redirect_uris":[redirect],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none"}))
            .send()
            .map_err(|e| e.to_string())?;
        let ok = response.status().is_success();
        let body: Value = response.json().unwrap_or(Value::Null);
        let Some(cid) = body["client_id"].as_str().filter(|_| ok) else {
            return Err(format!("{name}: client registration failed: {}", body["error_description"].as_str().or(body["error"].as_str()).unwrap_or("no client_id")));
        };
        client.client_id = cid.into();
        client.client_secret = body["client_secret"].as_str().map(str::to_string);
        client.client_auth = body["token_endpoint_auth_method"].as_str().map(str::to_string);
    }

    let verifier = random();
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let state = random();
    let mut auth = reqwest::Url::parse(&found.authorize).map_err(|e| e.to_string())?;
    {
        let mut q = auth.query_pairs_mut();
        q.append_pair("response_type", "code")
            .append_pair("client_id", &client.client_id)
            .append_pair("redirect_uri", &redirect)
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("state", &state);
        if let Some(r) = &found.resource {
            q.append_pair("resource", r);
        }
        let scope = config["scope"].as_str().map(str::to_string).or(found.scope.clone());
        if let Some(s) = scope.filter(|s| !s.is_empty()) {
            q.append_pair("scope", &s);
        }
    }
    open(auth.as_str())?;

    let deadline = std::time::Instant::now() + Duration::from_secs(300);
    let reply = loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            return Err("Sign-in timed out.".into());
        }
        let Some(request) = server.recv_timeout(left).map_err(|e| e.to_string())? else { continue };
        let query: std::collections::BTreeMap<String, String> = reqwest::Url::parse(&format!("http://x{}", request.url()))
            .map(|u| u.query_pairs().into_owned().collect())
            .unwrap_or_default();
        if !request.url().starts_with("/callback") || (!query.contains_key("state") && !query.contains_key("error")) {
            let _ = request.respond(tiny_http::Response::empty(404));
            continue;
        }
        let ok = query.contains_key("code");
        let page = format!("<!doctype html><meta charset=utf-8><title>Keepword</title><body style=\"font:16px Segoe UI,sans-serif;margin:3em\">{}</body>",
            if ok { "Signed in. You can close this tab and return to Keepword." } else { "Sign-in failed. Return to Keepword for details." });
        let _ = request.respond(tiny_http::Response::from_string(page).with_header(
            tiny_http::Header::from_bytes("Content-Type", "text/html; charset=utf-8").unwrap(),
        ));
        break query;
    };
    if let Some(e) = reply.get("error") {
        return Err(format!("{name}: {}", reply.get("error_description").unwrap_or(e)));
    }
    let code = match (reply.get("state"), reply.get("code")) {
        (Some(s), Some(c)) if *s == state => c.clone(),
        _ => return Err(format!("{name}: the sign-in reply didn't match the request")),
    };
    let mut params = vec![
        ("grant_type", "authorization_code".to_string()),
        ("code", code),
        ("redirect_uri", redirect),
        ("code_verifier", verifier),
    ];
    if let Some(r) = &found.resource {
        params.push(("resource", r.clone()));
    }
    let tokens = token_request(&client, &params).map_err(|e| e.split_once(": ").map_or(e.clone(), |(_, m)| m.to_string()))?;
    set_tokens(id, Some(&tokens))
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};
    use std::sync::{Arc, Mutex};

    #[test]
    fn parses_challenges() {
        let p = super::parse_challenge(r#"Bearer realm="OAuth", resource_metadata="https://x/.well-known/oauth-protected-resource/mcp", scope="read write""#);
        assert_eq!(p["resource_metadata"], "https://x/.well-known/oauth-protected-resource/mcp");
        assert_eq!(p["scope"], "read write");
        assert_eq!(p["realm"], "OAuth");
    }

    /// The whole flow against a mock authorization + MCP server: 401 challenge, discovery, dynamic registration,
    /// PKCE, resource, code exchange, refresh of an expiring token and a tool call through the MCP client.
    #[test]
    fn signs_in_refreshes_and_calls_a_tool() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let base = format!("http://localhost:{}", server.server_addr().to_ip().unwrap().port());
        let seen = Arc::new(Mutex::new(json!({})));
        let (b, s) = (base.clone(), seen.clone());
        std::thread::spawn(move || {
            for mut request in server.incoming_requests() {
                let url = request.url().to_string();
                let route = url.split('?').next().unwrap_or("").to_string();
                let query: std::collections::BTreeMap<String, String> = reqwest::Url::parse(&format!("http://x{url}")).unwrap().query_pairs().into_owned().collect();
                let mut body = String::new();
                let _ = request.as_reader().read_to_string(&mut body);
                let json_reply = |v: Value, code: u16| tiny_http::Response::from_string(v.to_string()).with_status_code(code)
                    .with_header(tiny_http::Header::from_bytes("Content-Type", "application/json").unwrap());
                let auth = request.headers().iter().find(|h| h.field.equiv("Authorization")).map(|h| h.value.to_string());
                let response = match (request.method().as_str(), route.as_str()) {
                    ("POST", "/mcp") if auth.as_deref() != Some("Bearer access-2") => tiny_http::Response::from_string("").with_status_code(401)
                        .with_header(tiny_http::Header::from_bytes("WWW-Authenticate", format!(r#"Bearer resource_metadata="{b}/.well-known/oauth-protected-resource/mcp", scope="tasks""#)).unwrap()),
                    ("POST", "/mcp") => {
                        let msg: Value = serde_json::from_str(&body).unwrap();
                        if msg.get("id").is_none() { tiny_http::Response::from_string("").with_status_code(202) } else {
                            let result = match msg["method"].as_str().unwrap() {
                                "tools/list" => json!({"tools":[{"name":"create_issue"}]}),
                                "tools/call" => json!({"content":[{"type":"text","text":"Created https://tracker.test/1"}]}),
                                _ => json!({"protocolVersion":"2025-06-18","capabilities":{}}),
                            };
                            json_reply(json!({"jsonrpc":"2.0","id":msg["id"],"result":result}), 200)
                        }
                    }
                    ("GET", "/.well-known/oauth-protected-resource/mcp") => json_reply(json!({"resource":format!("{b}/mcp"),"authorization_servers":[format!("{b}/auth")]}), 200),
                    ("GET", "/.well-known/oauth-authorization-server/auth") => json_reply(json!({"authorization_endpoint":format!("{b}/auth/authorize"),"token_endpoint":format!("{b}/auth/token"),"registration_endpoint":format!("{b}/auth/register")}), 200),
                    ("POST", "/auth/register") => {
                        let v: Value = serde_json::from_str(&body).unwrap();
                        s.lock().unwrap()["redirect"] = v["redirect_uris"][0].clone();
                        json_reply(json!({"client_id":"client-1"}), 201)
                    }
                    ("GET", "/auth/authorize") => {
                        let mut seen = s.lock().unwrap();
                        assert_eq!(seen["redirect"].as_str(), query.get("redirect_uri").map(String::as_str));
                        assert_eq!(query["client_id"], "client-1");
                        assert_eq!(query["code_challenge_method"], "S256");
                        seen["challenge"] = json!(query["code_challenge"]);
                        seen["scope"] = json!(query["scope"]);
                        seen["resource"] = json!(query["resource"]);
                        let location = format!("{}?code=code-1&state={}", query["redirect_uri"], query["state"]);
                        tiny_http::Response::from_string("").with_status_code(302).with_header(tiny_http::Header::from_bytes("Location", location).unwrap())
                    }
                    ("POST", "/auth/token") => {
                        let form: std::collections::BTreeMap<String, String> = reqwest::Url::parse(&format!("http://x/?{body}")).unwrap().query_pairs().into_owned().collect();
                        if form["grant_type"] == "authorization_code" {
                            use base64::Engine;
                            use sha2::Digest;
                            let hashed = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(form["code_verifier"].as_bytes()));
                            assert_eq!(s.lock().unwrap()["challenge"], json!(hashed));
                            assert_eq!(form["resource"], format!("{b}/mcp"));
                            json_reply(json!({"access_token":"access-1","refresh_token":"refresh-1","expires_in":5}), 200)
                        } else {
                            assert_eq!(form["refresh_token"], "refresh-1");
                            s.lock().unwrap()["refreshed"] = json!(true);
                            json_reply(json!({"access_token":"access-2","expires_in":3600}), 200)
                        }
                    }
                    _ => tiny_http::Response::from_string("").with_status_code(404),
                };
                let _ = request.respond(response);
            }
        });
        let id = uuid::Uuid::new_v4().to_string();
        let config = json!({"id":id,"name":"Mock","transport":"http","url":format!("{base}/mcp"),"auth":"oauth"});
        let before = crate::mcp::Client::connect(&config).err().unwrap_or_default();
        assert!(before.starts_with(super::SIGN_IN_REQUIRED), "{before}");
        // The "browser": follow the authorization redirect to the loopback callback.
        super::sign_in(&config, |url| {
            let url = url.to_string();
            std::thread::spawn(move || reqwest::blocking::get(url).map(|_| ()).unwrap());
            Ok(())
        })
        .unwrap();
        let mut client = crate::mcp::Client::connect(&config).unwrap();
        assert_eq!(client.tools().unwrap()[0]["name"], "create_issue");
        assert!(client.call("create_issue", json!({"title":"x"})).unwrap().to_string().contains("tracker.test"));
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen["scope"], "tasks");
        assert_eq!(seen["resource"], json!(format!("{base}/mcp")));
        assert_eq!(seen["refreshed"], true);
        assert_eq!(super::tokens(&id).unwrap().access_token, "access-2");
        super::set_tokens(&id, None).unwrap();
    }
}
