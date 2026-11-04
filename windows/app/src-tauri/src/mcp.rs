use crate::{domain, llm, settings, AppState};
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    process::{Child, Stdio},
    sync::{atomic::Ordering, mpsc},
    time::Duration,
};
use tauri::{AppHandle, Manager};
type Res<T> = Result<T, String>;
const PROTOCOL: &str = "2024-11-05";
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
pub fn server(app: AppHandle) -> Res<()> {
    let dir = app.state::<AppState>().store.lock().unwrap().dir.clone();
    let config = settings::load(&dir)?;
    if !config.mcp_enabled {
        return Ok(());
    }
    let listener = tiny_http::Server::http(("127.0.0.1", config.mcp_port)).map_err(err)?;
    let mut token = settings::secret("mcpToken")?;
    if token.is_empty() {
        token = format!("{}{}", uuid::Uuid::new_v4(), uuid::Uuid::new_v4());
        settings::set_secret("mcpToken", &token)?;
    }
    std::thread::spawn(move || {
        while !app.state::<AppState>().shutdown.load(Ordering::Relaxed) {
            let mut request = match listener.recv_timeout(Duration::from_millis(500)) {
                Ok(Some(r)) => r,
                Ok(None) => continue,
                Err(_) => break,
            };
            let authorized = request.headers().iter().any(|h| {
                h.field.equiv("Authorization") && h.value.as_str() == format!("Bearer {token}")
            });
            if !authorized {
                let _ = request.respond(
                    tiny_http::Response::from_string("Unauthorized").with_status_code(401),
                );
                continue;
            }
            if request.url() != "/mcp" || request.method() != &tiny_http::Method::Post {
                let _ = request
                    .respond(tiny_http::Response::from_string("Not found").with_status_code(404));
                continue;
            }
            if request.headers().iter().any(|h| {
                h.field.equiv("Origin")
                    && !h.value.as_str().starts_with("http://localhost:")
                    && !h.value.as_str().starts_with("http://127.0.0.1:")
            }) {
                let _ = request.respond(tiny_http::Response::empty(403));
                continue;
            }
            let mut body = String::new();
            if request
                .as_reader()
                .take(1_048_577)
                .read_to_string(&mut body)
                .is_err()
                || body.len() > 1_048_576
            {
                let _ = request.respond(tiny_http::Response::empty(413));
                continue;
            }
            let message: Value = match serde_json::from_str(&body) {
                Ok(v) => v,
                Err(_) => {
                    let _ = request.respond(
                        tiny_http::Response::from_string("Invalid JSON").with_status_code(400),
                    );
                    continue;
                }
            };
            if message.get("id").is_none() {
                let _ = request.respond(tiny_http::Response::empty(202));
                continue;
            }
            let result = dispatch(&app, &message);
            let reply = match result {
                Ok(r) => json!({"jsonrpc":"2.0","id":message["id"],"result":r}),
                Err(e) => {
                    json!({"jsonrpc":"2.0","id":message["id"],"error":{"code":-32602,"message":e}})
                }
            };
            let mut response = tiny_http::Response::from_string(reply.to_string());
            response.add_header(
                tiny_http::Header::from_bytes("Content-Type", "application/json").unwrap(),
            );
            let _ = request.respond(response);
        }
    });
    Ok(())
}
fn dispatch(app: &AppHandle, m: &Value) -> Res<Value> {
    match m["method"].as_str().unwrap_or("") {
        "initialize" => Ok(
            json!({"protocolVersion":PROTOCOL,"capabilities":{"tools":{}},"serverInfo":{"name":"Keepword","version":env!("CARGO_PKG_VERSION")}}),
        ),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools":[
            {"name":"search_meetings","description":"Search recorded meeting transcripts","inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}},
            {"name":"get_meeting","description":"Read a meeting, transcript, notes and actions","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
            {"name":"list_meetings","description":"List recent meetings","inputSchema":{"type":"object","properties":{}}},
            {"name":"list_action_items","description":"Read action items","inputSchema":{"type":"object","properties":{}}}
        ]})),
        "tools/call" => {
            let state = app.state::<AppState>();
            let store = state.store.lock().unwrap();
            let value = match m["params"]["name"].as_str().unwrap_or("") {
                "search_meetings" => json!(domain::search_library(
                    &store,
                    m["params"]["arguments"]["query"].as_str().unwrap_or(""),
                    None
                )?),
                "get_meeting" => domain::view(
                    &store,
                    "document",
                    m["params"]["arguments"]["id"].as_str(),
                    "",
                )?,
                "list_meetings" => {
                    serde_json::to_value(store.meetings().map_err(err)?).map_err(err)?
                }
                "list_action_items" => domain::view(&store, "actions", None, "")?,
                _ => return Err("Unknown tool".into()),
            };
            Ok(
                json!({"content":[{"type":"text","text":serde_json::to_string(&value).map_err(err)?}]}),
            )
        }
        _ => Err("Unsupported method".into()),
    }
}
struct Process {
    child: Child,
    _job: crate::subprocess::Job,
}
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
enum Transport {
    Stdio {
        process: Process,
        input: std::process::ChildStdin,
        replies: mpsc::Receiver<Res<Value>>,
    },
    Http {
        url: String,
        headers: std::collections::BTreeMap<String, String>,
        session: Option<String>,
        oauth: Option<(String, String)>, // server id and name, for browser sign-in tokens
    },
}
pub struct Client {
    transport: Transport,
    next: i64,
}
impl Client {
    pub fn connect(config: &Value) -> Res<Self> {
        let secrets =
            settings::server_secrets(config["id"].as_str().ok_or("MCP server needs an id")?)?;
        let transport = if config["transport"] == "http" {
            let oauth = (config["auth"] == "oauth").then(|| {
                let id = config["id"].as_str().unwrap_or_default().to_string();
                (id.clone(), config["name"].as_str().unwrap_or(&id).to_string())
            });
            Transport::Http {
                url: config["url"].as_str().ok_or("MCP URL is missing")?.into(),
                headers: if oauth.is_some() { Default::default() } else { secrets },
                session: None,
                oauth,
            }
        } else {
            let executable = config["command"].as_str().ok_or("MCP command is missing")?;
            let mut command = llm::program(executable)?;
            command
                .args(
                    config["args"]
                        .as_array()
                        .unwrap_or(&Vec::new())
                        .iter()
                        .filter_map(Value::as_str),
                )
                .envs(secrets)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null());
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                command.creation_flags(0x08000000);
            }
            let mut child = command.spawn().map_err(err)?;
            let job = crate::subprocess::attach(&mut child)?;
            let input = child.stdin.take().ok_or("No MCP stdin")?;
            let stdout = child.stdout.take().ok_or("No MCP stdout")?;
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stdout);
                loop {
                    let mut line = String::new();
                    match reader.by_ref().take(4_194_305).read_line(&mut line) {
                        Ok(0) => break,
                        Ok(_) if line.len() > 4_194_304 => {
                            let _ = tx.send(Err("MCP message exceeds 4 MB".into()));
                            break;
                        }
                        Ok(_) => {
                            if line.trim().is_empty() {
                                continue;
                            }
                            let parsed = serde_json::from_str(&line).map_err(err);
                            if tx.send(parsed).is_err() {
                                break;
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(Err(e.to_string()));
                            break;
                        }
                    }
                }
            });
            Transport::Stdio {
                process: Process { child, _job: job },
                input,
                replies: rx,
            }
        };
        let mut client = Self { transport, next: 1 };
        client.request("initialize",json!({"protocolVersion":PROTOCOL,"capabilities":{},"clientInfo":{"name":"Keepword","version":"0.1.0"}}))?;
        client.notify("notifications/initialized", json!({}))?;
        Ok(client)
    }
    fn send(&mut self, message: &Value) -> Res<Option<Value>> {
        match &mut self.transport {
            Transport::Stdio {
                process,
                input,
                replies,
            } => {
                if process.child.try_wait().map_err(err)?.is_some() {
                    return Err("MCP process exited".into());
                }
                writeln!(input, "{message}").map_err(err)?;
                input.flush().map_err(err)?;
                if message.get("id").is_none() {
                    return Ok(None);
                }
                loop {
                    let reply = replies
                        .recv_timeout(Duration::from_secs(120))
                        .map_err(|_| "MCP server timed out or disconnected")??;
                    if reply["id"] == message["id"] {
                        return Ok(Some(reply));
                    }
                }
            }
            Transport::Http {
                url,
                headers,
                session,
                oauth,
            } => {
                let mut retried = false;
                let response = loop {
                    let mut request = reqwest::blocking::Client::builder()
                        .timeout(Duration::from_secs(120))
                        .build()
                        .map_err(err)?
                        .post(url.as_str())
                        .header("Accept", "application/json, text/event-stream")
                        .header("MCP-Protocol-Version", PROTOCOL)
                        .json(message);
                    for (k, v) in headers.iter() {
                        request = request.header(k, v);
                    }
                    if let Some(id) = session {
                        request = request.header("Mcp-Session-Id", id.as_str());
                    }
                    if let Some((id, name)) = oauth.as_ref() {
                        let token = crate::oauth::access_token(id, retried)?
                            .ok_or_else(|| crate::oauth::sign_in_required(name))?;
                        request = request.bearer_auth(token);
                    }
                    let response = request.send().map_err(err)?;
                    if response.status().as_u16() == 401 {
                        match oauth.as_ref() {
                            Some(_) if !retried => { retried = true; continue; } // expired early: refresh once
                            Some((_, name)) => return Err(crate::oauth::sign_in_required(name)),
                            None => return Err("MCP HTTP 401: the server rejected the token. Check the headers.".into()),
                        }
                    }
                    break response;
                };
                let status = response.status();
                if !status.is_success() {
                    return Err(format!("MCP HTTP {status}"));
                }
                if let Some(id) = response
                    .headers()
                    .get("mcp-session-id")
                    .and_then(|v| v.to_str().ok())
                {
                    *session = Some(id.into());
                }
                if message.get("id").is_none() {
                    return Ok(None);
                }
                let id = message["id"].as_i64().unwrap_or(0);
                if response
                    .headers()
                    .get("content-type")
                    .and_then(|v| v.to_str().ok())
                    .is_some_and(|v| v.contains("text/event-stream"))
                {
                    let mut reader = BufReader::new(response);
                    let mut event = String::new();
                    let mut total = 0;
                    loop {
                        let mut line = String::new();
                        let n = reader
                            .by_ref()
                            .take(4_194_305)
                            .read_line(&mut line)
                            .map_err(err)?;
                        total += n;
                        if total > 4_194_304 {
                            return Err("MCP response exceeds 4 MB".into());
                        }
                        if n == 0 {
                            return parse_response(&event, id).map(Some);
                        }
                        event.push_str(&line);
                        if line.trim().is_empty() {
                            if let Ok(reply) = parse_response(&event, id) {
                                return Ok(Some(reply));
                            }
                            event.clear();
                        }
                    }
                }
                let mut text = String::new();
                response
                    .take(4_194_305)
                    .read_to_string(&mut text)
                    .map_err(err)?;
                if text.len() > 4_194_304 {
                    return Err("MCP response exceeds 4 MB".into());
                }
                Ok(Some(parse_response(&text, id)?))
            }
        }
    }
    fn notify(&mut self, method: &str, params: Value) -> Res<()> {
        self.send(&json!({"jsonrpc":"2.0","method":method,"params":params}))?;
        Ok(())
    }
    pub fn request(&mut self, method: &str, params: Value) -> Res<Value> {
        let id = self.next;
        self.next += 1;
        let reply = self
            .send(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))?
            .ok_or("MCP response is empty")?;
        if let Some(error) = reply.get("error") {
            return Err(error.to_string());
        }
        reply
            .get("result")
            .cloned()
            .ok_or("MCP result is missing".into())
    }
    pub fn tools(&mut self) -> Res<Vec<Value>> {
        let mut tools = Vec::new();
        let mut cursor = None;
        loop {
            let r = self.request(
                "tools/list",
                cursor
                    .as_ref()
                    .map_or(json!({}), |c: &String| json!({"cursor":c})),
            )?;
            tools.extend(r["tools"].as_array().cloned().unwrap_or_default());
            cursor = r["nextCursor"].as_str().map(str::to_string);
            if cursor.is_none() {
                break;
            }
            if tools.len() > 5000 {
                return Err("Too many MCP tools".into());
            }
        }
        Ok(tools)
    }
    pub fn call(&mut self, name: &str, args: Value) -> Res<Value> {
        let r = self.request("tools/call", json!({"name":name,"arguments":args}))?;
        if r["isError"] == true {
            return Err(r.to_string());
        }
        Ok(r)
    }
}
fn parse_response(text: &str, id: i64) -> Res<Value> {
    if let Ok(v) = serde_json::from_str::<Value>(text) {
        if v["id"] != id {
            return Err("MCP response id does not match the request".into());
        }
        return Ok(v);
    }
    let normalized = text.replace("\r\n", "\n");
    for event in normalized.split("\n\n") {
        let data = event
            .lines()
            .filter_map(|l| l.strip_prefix("data:"))
            .collect::<Vec<_>>()
            .join("\n");
        if let Ok(v) = serde_json::from_str::<Value>(&data) {
            if v["id"] == id {
                return Ok(v);
            }
        }
    }
    Err("Invalid JSON/SSE MCP response".into())
}

#[cfg(test)]
mod tests {
    #[test]
    fn connects_to_native_stdio_fixture_and_calls_tool() {
        let script = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/mock-mcp.mjs");
        let mut client=super::Client::connect(&serde_json::json!({"id":uuid::Uuid::new_v4().to_string(),"transport":"stdio","command":"node.exe","args":[script.display().to_string()]})).unwrap();
        assert_eq!(client.tools().unwrap()[0]["name"], "create_task");
        let result = client
            .call("create_task", serde_json::json!({"title":"Fixture task"}))
            .unwrap();
        assert!(result["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Fixture task"));
    }
    #[test]
    fn connects_to_streamable_http_fixture() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}/mcp", server.server_addr());
        let worker = std::thread::spawn(move || {
            for _ in 0..4 {
                let mut request = server.recv().unwrap();
                let message: serde_json::Value =
                    serde_json::from_reader(request.as_reader()).unwrap();
                if message.get("id").is_none() {
                    request.respond(tiny_http::Response::empty(202)).unwrap();
                    continue;
                }
                let result = match message["method"].as_str().unwrap() {
                    "initialize" => {
                        serde_json::json!({"protocolVersion":"2024-11-05","capabilities":{}})
                    }
                    "tools/list" => serde_json::json!({"tools":[{"name":"fixture"}]}),
                    _ => serde_json::json!({"content":[{"type":"text","text":"ok"}]}),
                };
                let reply = serde_json::json!({"jsonrpc":"2.0","id":message["id"],"result":result});
                request
                    .respond(
                        tiny_http::Response::from_string(format!(
                            "event: message\r\ndata: {reply}\r\n\r\n"
                        ))
                        .with_header(
                            tiny_http::Header::from_bytes("Content-Type", "text/event-stream")
                                .unwrap(),
                        ),
                    )
                    .unwrap();
            }
        });
        let mut client=super::Client::connect(&serde_json::json!({"id":uuid::Uuid::new_v4().to_string(),"transport":"http","url":url})).unwrap();
        assert_eq!(client.tools().unwrap()[0]["name"], "fixture");
        assert_eq!(
            client.call("fixture", serde_json::json!({})).unwrap()["content"][0]["text"],
            "ok"
        );
        worker.join().unwrap();
    }
    #[test]
    fn reads_sse_jsonrpc() {
        let r = super::parse_response(
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}\n\n",
            2,
        )
        .unwrap();
        assert_eq!(r["id"], 2);
        assert!(super::parse_response("not json", 1).is_err());
    }
}
