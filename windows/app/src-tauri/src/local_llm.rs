use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
    time::Duration,
};
type Res<T> = Result<T, String>;
pub fn model_path(library: &Path) -> PathBuf {
    library.join("Models/LLM/Qwen3.5-4B-Q4_K_M.gguf")
}
pub fn download(library: &Path, app: &tauri::AppHandle, cancel: &AtomicBool) -> Res<PathBuf> {
    let path = model_path(library);
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    crate::models::artifact("https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf",&path,2740937888,"00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",app,cancel)?;
    Ok(path)
}
struct PromptFile(PathBuf);
impl Drop for PromptFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
pub fn chat(s: &crate::settings::Settings, messages: &[Value]) -> Res<String> {
    chat_with_schema(s, messages, None)
}
pub fn chat_with_schema(
    s: &crate::settings::Settings,
    messages: &[Value],
    schema: Option<&Value>,
) -> Res<String> {
    let model = Path::new(&s.gguf_path);
    let bytes = std::fs::metadata(model)
        .map_err(|_| "Choose or download a GGUF model in Settings")?
        .len();
    #[cfg(windows)]
    unsafe {
        use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        let mut memory = MEMORYSTATUSEX {
            dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
            ..Default::default()
        };
        if GlobalMemoryStatusEx(&mut memory).is_ok()
            && memory.ullAvailPhys < bytes + 512 * 1024 * 1024
        {
            return Err("Not enough available memory for this GGUF model. Close other apps, choose a smaller model, or use another AI provider.".into());
        }
    }
    let local = Path::new(env!("CARGO_MANIFEST_DIR")).join("binaries/llama/llama-completion.exe");
    let installed = std::env::current_exe()
        .map_err(|e| e.to_string())?
        .parent()
        .ok_or("Invalid executable path")?
        .join("llama/llama-completion.exe");
    let executable = if !s.llm_executable.is_empty() {
        PathBuf::from(&s.llm_executable)
    } else if installed.exists() {
        installed
    } else {
        local
    };
    let prompt = messages
        .iter()
        .map(|m| {
            format!(
                "<|im_start|>{}\n{}<|im_end|>",
                m["role"].as_str().unwrap_or("user"),
                m["content"].as_str().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n<|im_start|>assistant\n<think>\n</think>\n";
    let file = PromptFile(
        std::env::temp_dir().join(format!("meetnotes-prompt-{}.txt", uuid::Uuid::new_v4())),
    );
    std::fs::write(&file.0, prompt).map_err(|e| e.to_string())?;
    let mut command = std::process::Command::new(executable);
    command
        .arg("-m")
        .arg(model)
        .args([
            "-n",
            "3000",
            "-c",
            "16384",
            "--no-display-prompt",
            "--no-conversation",
            "--simple-io",
            "--no-escape",
            "-f",
        ])
        .arg(&file.0);
    if let Some(schema) = schema {
        command.args([
            "--json-schema",
            &schema.to_string(),
            "--seed",
            "42",
            "--temp",
            "0",
        ]);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    crate::llm::run(command, "", Duration::from_secs(900))
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "Requires downloaded Qwen GGUF"]
    fn produces_structured_meeting_summary() {
        let mut settings = crate::settings::Settings::default();
        settings.provider = "llama".into();
        settings.gguf_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target/test-local-llm/Qwen3.5-4B-Q4_K_M.gguf")
            .display()
            .to_string();
        let result=crate::llm::summarize(&settings,"Write meeting notes. Return JSON with title, overview, insights (array of text/time), action_items (array of text/assignee/due) and tags. No extra prose.","[00:01] Alice: We will release the Windows app next week. I will prepare the installer tomorrow.\n[00:05] Bob: Agreed. The budget is five thousand dollars.").unwrap();
        eprintln!("Structured local summary: {result}");
        assert!(result["overview"].as_str().is_some_and(|s| !s.is_empty()));
        assert!(result["action_items"]
            .as_array()
            .is_some_and(|v| !v.is_empty()));
        let schema = serde_json::json!({"type":"array","minItems":2,"maxItems":2,"items":{"type":"object","additionalProperties":false,"required":["text","irrelevant"],"properties":{"text":{"type":"string"},"irrelevant":{"type":"boolean"}}}});
        let cleanup = crate::llm::ask_json(&settings, "Fix speech punctuation without changing meaning. Preserve the number and order of lines.", r#"["Alice will prepare notes tomorrow", "Bob agreed to release next week"]"#, &schema).unwrap();
        eprintln!("Structured local cleanup: {cleanup}");
        let lines = cleanup.as_array().unwrap();
        assert_eq!(lines.len(), 2);
        assert!(lines
            .iter()
            .all(|v| v["text"].is_string() && v["irrelevant"].is_boolean()));
    }
    #[test]
    #[ignore = "Requires downloaded Qwen GGUF in target/test-local-llm"]
    fn generates_local_answer() {
        let mut settings = crate::settings::Settings::default();
        settings.provider = "llama".into();
        settings.gguf_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target/test-local-llm/Qwen3.5-4B-Q4_K_M.gguf")
            .display()
            .to_string();
        let reply=super::chat(&settings,&[serde_json::json!({"role":"user","content":"Reply with exactly the word READY and no explanation."})]).unwrap();
        eprintln!("Local AI: {reply}");
        assert!(reply.contains("READY"));
    }
}
