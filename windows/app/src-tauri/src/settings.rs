use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, path::Path};
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    pub language: String,
    pub transcription_engine: String,
    pub transcription_url: String,
    pub transcription_model: String,
    pub transcription_language: String,
    pub provider: String,
    pub base_url: String,
    pub model: String,
    pub auto_summary: bool,
    pub cleanup: bool,
    pub diarization: bool,
    pub live: bool,
    pub embedding_url: String,
    pub embedding_model: String,
    pub export_dir: String,
    pub embedding_source: String,
    pub ics_urls: Vec<String>,
    pub mcp_enabled: bool,
    pub mcp_port: u16,
    pub servers: Vec<Value>,
    pub llm_executable: String,
    pub gguf_path: String,
    pub call_detection: bool,
    pub update_endpoint: String,
    pub update_public_key: String,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            language: "ru".into(),
            transcription_engine: "local".into(),
            transcription_url: "https://api.openai.com/v1".into(),
            transcription_model: "whisper-1".into(),
            transcription_language: "ru".into(),
            provider: "compatible".into(),
            base_url: "http://localhost:11434/v1".into(),
            model: "qwen3:8b".into(),
            auto_summary: false,
            cleanup: false,
            diarization: true,
            live: false,
            embedding_url: "http://localhost:11434/v1".into(),
            embedding_model: String::new(),
            embedding_source: "local".into(),
            export_dir: String::new(),
            ics_urls: Vec::new(),
            mcp_enabled: false,
            mcp_port: 17382,
            servers: Vec::new(),
            llm_executable: String::new(),
            gguf_path: String::new(),
            call_detection: false,
            update_endpoint: option_env!("MEETNOTES_UPDATE_ENDPOINT")
                .unwrap_or("")
                .into(),
            update_public_key: option_env!("MEETNOTES_UPDATE_PUBLIC_KEY")
                .unwrap_or("")
                .into(),
        }
    }
}
pub fn load(dir: &Path) -> Result<Settings, String> {
    let path = dir.join("settings.json");
    if !path.exists() {
        return Ok(Settings::default());
    }
    serde_json::from_slice(&std::fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| format!("Invalid settings: {e}"))
}
pub fn save(dir: &Path, value: &Settings) -> Result<(), String> {
    if !["ru", "en"].contains(&value.language.as_str()) {
        return Err("Unsupported language".into());
    }
    if !["local", "openai", "groq", "deepgram", "custom"]
        .contains(&value.transcription_engine.as_str())
    {
        return Err("Unsupported transcription engine".into());
    }
    if !["compatible", "anthropic", "codex", "claude", "llama"].contains(&value.provider.as_str()) {
        return Err("Unsupported AI provider".into());
    }
    if !["local", "server", "off"].contains(&value.embedding_source.as_str()) {
        return Err("Unsupported embedding source".into());
    }
    for server in &value.servers {
        if !server.is_object() || !matches!(server["transport"].as_str(), Some("stdio" | "http")) {
            return Err("Each MCP server needs transport: stdio or http".into());
        }
    }
    let data = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    let temp = dir.join("settings.json.part");
    std::fs::write(&temp, data).map_err(|e| e.to_string())?;
    std::fs::rename(temp, dir.join("settings.json")).map_err(|e| e.to_string())
}
static SECRET_SERVICE: std::sync::OnceLock<String> = std::sync::OnceLock::new();
pub fn configure_secret_store(dir: &Path) {
    let default = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .map(|d| d.join("MeetNotes"));
    let service = if default.as_ref().is_some_and(|p| {
        p.to_string_lossy()
            .eq_ignore_ascii_case(&dir.to_string_lossy())
    }) {
        "MeetNotes".into()
    } else {
        credential_id(
            "MeetNotes.Library",
            "",
            &dir.to_string_lossy().to_lowercase(),
        )
    };
    let _ = SECRET_SERVICE.set(service);
}
fn entry(name: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(
        SECRET_SERVICE
            .get()
            .map(String::as_str)
            .unwrap_or("MeetNotes"),
        name,
    )
    .map_err(|e| e.to_string())
}
pub fn secret(name: &str) -> Result<String, String> {
    match entry(name)?.get_password() {
        Ok(s) => Ok(s),
        Err(keyring::Error::NoEntry) => Ok(String::new()),
        Err(e) => Err(e.to_string()),
    }
}
pub fn set_secret(name: &str, value: &str) -> Result<(), String> {
    let entry = entry(name)?;
    if value.is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    } else {
        entry.set_password(value).map_err(|e| e.to_string())
    }
}
pub fn server_secrets(id: &str) -> Result<BTreeMap<String, String>, String> {
    let text = secret(&format!("mcp.{id}"))?;
    if text.is_empty() {
        Ok(BTreeMap::new())
    } else {
        serde_json::from_str(&text).map_err(|e| e.to_string())
    }
}
pub fn credential_id(kind: &str, provider: &str, url: &str) -> String {
    use sha2::{Digest, Sha256};
    format!(
        "{kind}.{:x}",
        Sha256::digest(format!("{provider}:{}", url.trim_end_matches('/')).as_bytes())
    )
}
pub fn llm_key(s: &Settings) -> Result<String, String> {
    secret(&credential_id("llm", &s.provider, &s.base_url))
}
pub fn migrate_key(s: &Settings) -> Result<(), String> {
    let legacy = secret("llmAPIKey")?;
    if !legacy.is_empty() {
        let name = credential_id("llm", &s.provider, &s.base_url);
        if secret(&name)?.is_empty() {
            set_secret(&name, &legacy)?;
        }
        set_secret("llmAPIKey", "")?;
    }
    Ok(())
}
pub fn public(dir: &Path) -> Result<Value, String> {
    let s = load(dir)?;
    migrate_key(&s)?;
    Ok(
        json!({"settings":s,"hasKey":!llm_key(&s)?.is_empty(),"hasTranscriptionKey":!secret(&credential_id("asr",&s.transcription_engine,&s.transcription_url))?.is_empty(),"hasEmbeddingKey":!secret(&credential_id("embedding","server",&s.embedding_url))?.is_empty()}),
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn credentials_are_partitioned_by_service_and_endpoint() {
        assert_ne!(
            super::credential_id("llm", "compatible", "https://a.example/v1"),
            super::credential_id("llm", "compatible", "https://b.example/v1")
        );
        assert_ne!(
            super::credential_id("llm", "compatible", "https://a.example/v1"),
            super::credential_id("asr", "compatible", "https://a.example/v1")
        );
        assert_eq!(
            super::credential_id("llm", "compatible", "https://a.example/v1/"),
            super::credential_id("llm", "compatible", "https://a.example/v1")
        );
    }
    #[test]
    fn old_settings_receive_defaults() {
        let s: super::Settings = serde_json::from_str("{\"language\":\"en\"}").unwrap();
        assert_eq!(s.model, "qwen3:8b");
        assert!(!s.auto_summary);
    }
}
