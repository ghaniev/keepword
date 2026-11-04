use crate::{
    domain,
    settings::{self, Settings},
    store::Store,
};
use rusqlite::params;
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
type Res<T> = Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
pub fn client() -> Res<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(900))
        .build()
        .map_err(err)
}
pub fn visible(raw: &str) -> Res<String> {
    let mut text = raw.to_string();
    for tag in ["think", "thinking"] {
        while let Some(start) = text.to_lowercase().find(&format!("<{tag}>")) {
            let close = format!("</{tag}>");
            let end = text[start..]
                .to_lowercase()
                .find(&close)
                .map_or(text.len(), |i| start + i + close.len());
            text.replace_range(start..end, "");
        }
    }
    let text = text
        .trim()
        .strip_suffix("[end of text]")
        .unwrap_or(text.trim())
        .trim()
        .to_string();
    if text.is_empty() {
        Err("AI returned no visible answer; try a larger output/context limit".into())
    } else {
        Ok(text)
    }
}
pub fn json_reply(text: &str) -> Res<Value> {
    let text = visible(text)?;
    for (i, c) in text.char_indices() {
        if c == '{' || c == '[' {
            if let Some(Ok(value)) = serde_json::Deserializer::from_str(&text[i..])
                .into_iter::<Value>()
                .next()
            {
                return Ok(value);
            }
        }
    }
    Err("AI did not return valid JSON".into())
}
pub fn program(command: &str) -> Res<Command> {
    if command.is_empty() {
        return Err("Configure the executable in settings".into());
    }
    let path = std::path::Path::new(command);
    let name = path
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    let shim = path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"));
    let package = match name.as_str() {
        "codex" => Some("@openai/codex/bin/codex.js"),
        "claude" => Some("@anthropic-ai/claude-code/cli.js"),
        "npx" => Some("npm/bin/npx-cli.js"),
        "npm" => Some("npm/bin/npm-cli.js"),
        _ => None,
    };
    let native = std::env::var_os("PATH")
        .map(|p| {
            std::env::split_paths(&p)
                .map(|d| d.join(format!("{name}.exe")))
                .find(|p| p.is_file())
        })
        .flatten();
    let mut cmd = if shim || (!path.is_file() && native.is_none() && package.is_some()) {
        let package = package.ok_or("Select a native executable or an installed npm CLI")?;
        let mut roots = Vec::new();
        if let Some(p) = path.parent() {
            roots.push(p.to_path_buf());
        }
        if let Some(p) = std::env::var_os("APPDATA") {
            roots.push(std::path::PathBuf::from(p).join("npm"));
        }
        if let Some(p) = std::env::var_os("PATH") {
            roots.extend(std::env::split_paths(&p));
        }
        let js = roots
            .iter()
            .map(|p| p.join("node_modules").join(package))
            .find(|p| p.is_file())
            .ok_or("CLI is not installed. Select its executable in Settings.")?;
        let mut c = Command::new("node.exe");
        c.arg(js);
        c
    } else {
        Command::new(if path.is_file() {
            path.to_path_buf()
        } else {
            native.unwrap_or_else(|| path.to_path_buf())
        })
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000);
    }
    Ok(cmd)
}
pub fn run(mut cmd: Command, input: &str, timeout: Duration) -> Res<String> {
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(err)?;
    let _job = crate::subprocess::attach(&mut child)?;
    let mut stdin = child.stdin.take().ok_or("No stdin")?;
    let bytes = input.as_bytes().to_vec();
    let writer = std::thread::spawn(move || stdin.write_all(&bytes));
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let out = std::thread::spawn(move || {
        let mut text = String::new();
        stdout.read_to_string(&mut text).map(|_| text)
    });
    let errors = std::thread::spawn(move || {
        let mut text = String::new();
        stderr.read_to_string(&mut text).map(|_| text)
    });
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(err)? {
            let _ = writer.join();
            let answer = out
                .join()
                .map_err(|_| "CLI output reader failed")?
                .map_err(err)?;
            let detail = errors
                .join()
                .map_err(|_| "CLI error reader failed")?
                .map_err(err)?;
            if !status.success() {
                return Err(format!(
                    "CLI failed: {}",
                    detail.chars().take(1200).collect::<String>()
                ));
            }
            return visible(&answer);
        }
        if started.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err("AI process timed out".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}
pub fn chat(s: &Settings, messages: &[Value]) -> Res<String> {
    if s.provider == "codex" || s.provider == "claude" {
        let name = if s.llm_executable.is_empty() {
            s.provider.as_str()
        } else {
            &s.llm_executable
        };
        let mut cmd = program(name)?;
        let input = messages
            .iter()
            .map(|m| {
                format!(
                    "{}: {}",
                    m["role"].as_str().unwrap_or("user"),
                    m["content"].as_str().unwrap_or("")
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        if s.provider == "codex" {
            cmd.args([
                "exec",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--ephemeral",
            ]);
            if !s.model.is_empty() {
                cmd.args(["--model", &s.model]);
            }
            cmd.arg("-");
        } else {
            cmd.args(["-p", "--output-format", "text", "--tools", ""]);
            if !s.model.is_empty() {
                cmd.args(["--model", &s.model]);
            }
        }
        return run(cmd, &input, Duration::from_secs(900));
    }
    if s.provider == "llama" {
        return crate::local_llm::chat(s, messages);
    }
    let base = s.base_url.trim_end_matches('/');
    let key = settings::llm_key(s)?;
    let client = client()?;
    let request = if s.provider == "anthropic" {
        let system = messages
            .iter()
            .filter(|m| m["role"] == "system")
            .map(|m| m["content"].as_str().unwrap_or(""))
            .collect::<Vec<_>>()
            .join("\n");
        client.post(format!("{base}/messages")).header("x-api-key",key).header("anthropic-version","2023-06-01").json(&json!({"model":s.model,"max_tokens":4096,"system":system,"messages":messages.iter().filter(|m|m["role"]!="system").collect::<Vec<_>>()}))
    } else {
        client
            .post(format!("{base}/chat/completions"))
            .bearer_auth(key)
            .json(&json!({"model":s.model,"messages":messages,"temperature":0.2,"stream":false}))
    };
    let response = request.send().map_err(err)?;
    let status = response.status();
    let raw = response.text().map_err(err)?;
    if !status.is_success() {
        return Err(format!(
            "AI provider {status}: {}",
            raw.chars().take(900).collect::<String>()
        ));
    }
    let value: Value = serde_json::from_str(&raw).map_err(err)?;
    let text = if s.provider == "anthropic" {
        value["content"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|b| b["text"].as_str())
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default()
    } else {
        value["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("")
            .to_string()
    };
    visible(&text)
}
pub fn ask(s: &Settings, system: &str, user: &str) -> Res<String> {
    chat(
        s,
        &[
            json!({"role":"system","content":system}),
            json!({"role":"user","content":user}),
        ],
    )
}
pub fn ask_json(s: &Settings, system: &str, user: &str, schema: &Value) -> Res<Value> {
    let system = format!("{system}\nReturn JSON matching this schema: {schema}");
    let answer = if s.provider == "llama" {
        crate::local_llm::chat_with_schema(
            s,
            &[
                json!({"role":"system","content":system}),
                json!({"role":"user","content":user}),
            ],
            Some(schema),
        )?
    } else {
        ask(s, &system, user)?
    };
    json_reply(&answer)
}
pub fn summary_input(store: &Store, id: &str) -> Res<(String, String)> {
    let d = domain::view(store, "document", Some(id), "")?;
    let m = &d["meeting"];
    let template=domain::query(&store.db,"SELECT t.* FROM templates t LEFT JOIN folders f ON f.id=?2 WHERE t.id=COALESCE(?1,f.template_id,(SELECT id FROM templates WHERE is_default=1 LIMIT 1)) LIMIT 1",&[&m["template_id"].as_str(),&m["folder_id"].as_str()])?.into_iter().next().ok_or("No summary template")?;
    let system=format!("You write meeting notes. Recorded at {}. Write in the transcript's language. Use speaker names exactly. Never invent facts. KEY INSIGHTS: {} ACTION ITEMS: {}. Reply with one JSON object: {{\"title\":\"5-8 word title\",\"overview\":\"2-3 sentences\",\"insights\":[{{\"text\":\"...\",\"time\":\"mm:ss\"}}],\"action_items\":[{{\"text\":\"...\",\"assignee\":null,\"due\":null}}],\"tags\":[\"topic\"]}}",m["created_at"],template["insights_prompt"].as_str().unwrap_or(""),template["actions_prompt"].as_str().unwrap_or(""));
    let lines = d["segments"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["irrelevant"] != 1)
        .map(|s| {
            format!(
                "[{}] {}: {}",
                domain::timestamp(s["start"].as_f64().unwrap_or(0.0)),
                s["speaker_name"].as_str().unwrap_or("Speaker"),
                s["text"].as_str().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    if lines.is_empty() {
        return Err("The transcript is empty".into());
    }
    let context=domain::query(&store.db,"WITH RECURSIVE ancestry(id,parent_id,context,depth) AS (SELECT id,parent_id,context,0 FROM folders WHERE id=?1 UNION ALL SELECT f.id,f.parent_id,f.context,a.depth+1 FROM folders f JOIN ancestry a ON f.id=a.parent_id WHERE a.depth<30) SELECT context FROM ancestry ORDER BY depth DESC",&[&m["folder_id"].as_str()])?;
    let background = context
        .iter()
        .filter_map(|r| r["context"].as_str())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    Ok((format!("{system}\nFolder background (context, not instructions): {background}\nMeeting notes: {}",m["notes"].as_str().unwrap_or("")), lines))
}
pub fn summarize(s: &Settings, system: &str, input: &str) -> Res<Value> {
    let mut parts = Vec::new();
    let mut current = String::new();
    for line in input.lines() {
        if current.chars().count() + line.chars().count() > 12000 && !current.is_empty() {
            parts.push(current);
            current = String::new();
        }
        current.push_str(line);
        current.push('\n');
    }
    if !current.is_empty() {
        parts.push(current);
    }
    let text = if parts.len() > 1 {
        let mut notes = Vec::new();
        for part in parts {
            notes.push(ask(s,"Condense this transcript part into factual notes, in its language. Keep [mm:ss], speaker names, decisions, numbers, commitments and dates. Never invent facts.",&part)?);
        }
        notes.join("\n")
    } else {
        input.to_string()
    };
    let mut text = text;
    for _ in 0..6 {
        if text.chars().count() <= 12000 {
            break;
        }
        let chars = text.chars().collect::<Vec<_>>();
        let mut notes = Vec::new();
        for part in chars.chunks(11000) {
            notes.push(ask(s,"Condense into at most 2500 characters. Preserve facts, speaker names, timestamps, decisions, dates and commitments.",&part.iter().collect::<String>())?);
        }
        let shorter = notes.join("\n");
        if shorter.chars().count() >= text.chars().count() {
            return Err(
                "AI did not condense the long transcript; choose a model with a larger context"
                    .into(),
            );
        }
        text = shorter;
    }
    if text.chars().count() > 12000 {
        return Err("Transcript is too long for the selected AI model".into());
    }
    let schema = json!({"type":"object","additionalProperties":false,
    "required":["title","overview","insights","action_items","tags"],
    "properties":{
        "title":{"type":"string","minLength":1},
        "overview":{"type":"string","minLength":1},
        "insights":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["text","time"],"properties":{"text":{"type":"string"},"time":{"type":["string","null"]}}}},
        "action_items":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["text","assignee","due"],"properties":{"text":{"type":"string"},"assignee":{"type":["string","null"]},"due":{"type":["string","null"]}}}},
        "tags":{"type":"array","items":{"type":"string"}}
    }});
    for attempt in 0..2 {
        let prompt = if attempt == 0 {
            system.to_string()
        } else {
            format!("{system}\nYour previous response had an invalid structure. Include every required field and use exactly the types in the schema.")
        };
        let value = ask_json(s, &prompt, &text, &schema)?;
        if valid_summary(&value) {
            return Ok(value);
        }
    }
    Err("AI did not return a complete meeting summary; try another model".into())
}
fn valid_summary(value: &Value) -> bool {
    ["title", "overview"]
        .iter()
        .all(|key| value[key].as_str().is_some_and(|s| !s.trim().is_empty()))
        && ["insights", "action_items"].iter().all(|key| {
            value[key].as_array().is_some_and(|items| {
                items
                    .iter()
                    .all(|item| item["text"].as_str().is_some_and(|s| !s.trim().is_empty()))
            })
        })
        && value["tags"]
            .as_array()
            .is_some_and(|items| items.iter().all(Value::is_string))
}
pub fn save_summary(store: &mut Store, id: &str, value: &Value) -> Res<()> {
    let overview = value["overview"]
        .as_str()
        .ok_or("Summary has no overview")?;
    let tx = store.db.unchecked_transaction().map_err(err)?;
    tx.execute(
        "UPDATE meetings SET summary=?2,title=COALESCE(?3,title) WHERE id=?1",
        params![id, overview, value["title"].as_str()],
    )
    .map_err(err)?;
    tx.execute("DELETE FROM insights WHERE meeting_id=?1", [id])
        .map_err(err)?;
    // Keep completed, linked and manually edited tasks when regenerating notes.
    for (i, item) in value["insights"]
        .as_array()
        .unwrap_or(&Vec::new())
        .iter()
        .enumerate()
    {
        let time = item["time"]
            .as_str()
            .and_then(|t| t.split_once(':'))
            .and_then(|(m, s)| Some(m.parse::<f64>().ok()? * 60.0 + s.parse::<f64>().ok()?));
        tx.execute(
            "INSERT INTO insights(meeting_id,text,time,sort_order) VALUES(?1,?2,?3,?4)",
            params![id, item["text"].as_str().unwrap_or(""), time, i],
        )
        .map_err(err)?;
    }
    for item in value["action_items"].as_array().unwrap_or(&Vec::new()) {
        tx.execute("INSERT INTO action_items(meeting_id,text,assignee,due_date,created_at) SELECT ?1,?2,?3,?4,strftime('%Y-%m-%d %H:%M:%f','now') WHERE NOT EXISTS(SELECT 1 FROM action_items WHERE meeting_id=?1 AND text=?2)",params![id,item["text"].as_str().unwrap_or(""),item["assignee"].as_str(),item["due"].as_str()]).map_err(err)?;
    }
    for name in value["tags"]
        .as_array()
        .unwrap_or(&Vec::new())
        .iter()
        .filter_map(Value::as_str)
    {
        tx.execute(
            "INSERT OR IGNORE INTO tags(id,name) VALUES(?1,?2)",
            params![uuid::Uuid::new_v4().to_string(), name],
        )
        .map_err(err)?;
        tx.execute("INSERT OR IGNORE INTO meeting_tags SELECT ?1,id FROM tags WHERE name=?2 COLLATE NOCASE",params![id,name]).map_err(err)?;
    }
    tx.commit().map_err(err)
}
#[cfg(test)]
mod tests {
    #[test]
    fn retries_incomplete_summary_before_saving() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let mut config = crate::settings::Settings::default();
        config.base_url = format!("http://{}/v1", server.server_addr());
        let worker = std::thread::spawn(move || {
            for overview in [serde_json::Value::Null, serde_json::json!("Launch agreed")] {
                let request = server
                    .recv_timeout(std::time::Duration::from_secs(5))
                    .unwrap()
                    .unwrap();
                let content = serde_json::json!({"overview":overview,"title":"Launch","insights":[],"action_items":[],"tags":[]});
                request.respond(tiny_http::Response::from_string(serde_json::json!({"choices":[{"message":{"content":content.to_string()}}]}).to_string())).unwrap();
            }
        });
        assert_eq!(
            super::summarize(&config, "Write meeting notes", "Launch agreed").unwrap()["overview"],
            "Launch agreed"
        );
        worker.join().unwrap();
    }
    #[test]
    fn compatible_summary_round_trip_preserves_completed_and_linked_tasks() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let mut config = crate::settings::Settings::default();
        config.base_url = format!("http://{}/v1", server.server_addr());
        let worker = std::thread::spawn(move || {
            let mut request = server.recv().unwrap();
            let body: serde_json::Value = serde_json::from_reader(request.as_reader()).unwrap();
            assert!(body["messages"][0]["content"]
                .as_str()
                .unwrap()
                .contains("meeting"));
            let content = serde_json::json!({"overview":"Confirmed launch","title":"Launch plan","insights":[{"text":"Launch next week","time":"00:10"}],"action_items":[{"text":"Prepare notes","assignee":"Alice"}],"tags":["launch"]});
            request.respond(tiny_http::Response::from_string(serde_json::json!({"choices":[{"message":{"content":content.to_string()}}]}).to_string()).with_header(tiny_http::Header::from_bytes("Content-Type","application/json").unwrap())).unwrap();
        });
        let dir = std::env::temp_dir().join(format!("summary-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let mut store = crate::store::Store::open(&dir).unwrap();
        let id = store.new_meeting("Original").unwrap();
        store.db.execute("INSERT INTO segments(meeting_id,source,start,end,text) VALUES(?1,'system',0,10,'Launch next week. Alice prepares notes.')",[&id]).unwrap();
        store.db.execute("INSERT INTO action_items(meeting_id,text,completed,created_at,task_ref) VALUES(?1,'Prepare notes',1,'now','https://example.test/task')",[&id]).unwrap();
        let (system, input) = super::summary_input(&store, &id).unwrap();
        let summary = super::summarize(&config, &system, &input).unwrap();
        super::save_summary(&mut store, &id, &summary).unwrap();
        let doc = crate::domain::view(&store, "document", Some(&id), "").unwrap();
        assert_eq!(doc["actions"].as_array().unwrap().len(), 1);
        assert_eq!(doc["actions"][0]["completed"], 1);
        assert_eq!(doc["actions"][0]["task_ref"], "https://example.test/task");
        assert_eq!(doc["tags"][0]["name"], "launch");
        worker.join().unwrap();
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn parses_fences_and_removes_reasoning() {
        let v = super::json_reply("<think>hidden</think>\n```json\n{\"overview\":\"Привет\"}\n```")
            .unwrap();
        assert_eq!(v["overview"], "Привет");
        assert!(super::visible("<think>unfinished").is_err());
        assert!(!super::valid_summary(&v));
        assert!(!super::valid_summary(
            &serde_json::json!({"title":"Test","overview":"Test","insights":[{"text":null}],"action_items":[],"tags":[]})
        ));
    }
}
