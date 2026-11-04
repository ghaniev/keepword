use crate::{
    asr::{self, Parakeet, Word},
    domain, llm, models, settings, AppState,
};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path, sync::atomic::Ordering};
use tauri::{AppHandle, Emitter, Manager};
type Res<T> = Result<T, String>;
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Turn {
    pub text: String,
    pub start: f64,
    pub end: f64,
    pub source: String,
    pub speaker: Option<String>,
    pub overlap: bool,
}
pub fn utterances(words: Vec<Word>, source: &str) -> Vec<Turn> {
    let mut out: Vec<Turn> = Vec::new();
    for w in words {
        if let Some(last) = out.last_mut() {
            if w.start - last.end < 1.2
                && w.end - last.start < 40.0
                && !(w.end - last.start > 20.0 && last.text.ends_with(['.', '?', '!']))
            {
                last.text.push(' ');
                last.text.push_str(&w.text);
                last.end = w.end;
                continue;
            }
        }
        out.push(Turn {
            text: w.text,
            start: w.start,
            end: w.end,
            source: source.into(),
            speaker: if source == "mic" {
                Some("me".into())
            } else {
                None
            },
            overlap: false,
        });
    }
    out
}
fn tokens(text: &str) -> HashSet<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| s.chars().count() > 1)
        .map(str::to_string)
        .collect()
}
pub fn dedup(mic: Vec<Turn>, system: &[Turn]) -> Vec<Turn> {
    let sets: Vec<_> = system.iter().map(|s| (s, tokens(&s.text))).collect();
    mic.into_iter()
        .filter(|m| {
            let t = tokens(&m.text);
            t.is_empty()
                || !sets.iter().any(|(s, st)| {
                    s.start < m.end + 3.0
                        && m.start < s.end + 3.0
                        && t.intersection(st).count() as f64 / t.union(st).count().max(1) as f64
                            >= 0.5
                })
        })
        .collect()
}
fn status(app: &AppHandle, id: &str, value: &str) -> Res<()> {
    app.state::<AppState>()
        .store
        .lock()
        .unwrap()
        .set_status(id, value)
        .map_err(|e| e.to_string())?;
    let _ = app.emit("library-changed", id);
    Ok(())
}
pub fn decoded(path: &Path) -> Res<Vec<f32>> {
    if path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("wav"))
    {
        return asr::audio(path);
    }
    let converted = path.with_extension("decoded.wav");
    let local = Path::new(env!("CARGO_MANIFEST_DIR")).join("binaries/media/ffmpeg.exe");
    let installed = std::env::current_exe()
        .map_err(|e| e.to_string())?
        .parent()
        .ok_or("Invalid executable path")?
        .join("media/ffmpeg.exe");
    let mut command =
        std::process::Command::new(if installed.exists() { installed } else { local });
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let output = command
        .args(["-nostdin", "-y", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"])
        .arg(&converted)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("This format needs ffmpeg on PATH: {e}"))?;
    let mut child = output;
    let _job = crate::subprocess::attach(&mut child)?;
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "Audio import failed: {}",
            String::from_utf8_lossy(&output.stderr)
                .chars()
                .take(600)
                .collect::<String>()
        ));
    }
    asr::audio(&converted)
}
fn audio_paths(dir: &Path) -> Res<Vec<std::path::PathBuf>> {
    let mut paths = Vec::new();
    for entry in std::fs::read_dir(dir).map_err(|e| e.to_string())? {
        let p = entry.map_err(|e| e.to_string())?.path();
        let name = p.file_name().unwrap_or_default().to_string_lossy();
        if name == "mic.wav"
            || name == "system.wav"
            || name == "mic.caf"
            || name == "system.caf"
            || (name.starts_with("import.") && !name.ends_with("decoded.wav"))
        {
            if name.ends_with(".caf") && p.with_extension("wav").is_file() {
                continue;
            }
            paths.push(p);
        }
    }
    paths.sort();
    Ok(paths)
}
fn speaker_labels(
    app: &AppHandle,
    id: &str,
    samples: &[f32],
) -> Res<(
    crate::diarize::Labels,
    std::collections::HashMap<i32, String>,
)> {
    let state = app.state::<AppState>();
    let (library, expected, max) = {
        let store = state.store.lock().unwrap();
        let counts: (Option<i32>, Option<i32>) = store
            .db
            .query_row(
                "SELECT expected_speakers,max_speakers FROM meetings WHERE id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(|e| e.to_string())?;
        (store.dir.clone(), counts.0, counts.1)
    };
    if !models::speakers_ready(&library) {
        return Err(
            "Speaker models are missing. Download models in Settings, or turn diarization off."
                .into(),
        );
    }
    status(app, id, "processing:diarizing")?;
    let labels =
        crate::diarize::analyze(&library.join("Models/diarization"), samples, expected, max)?;
    if state.cancelled.load(Ordering::Relaxed) {
        return Err("Processing cancelled".into());
    }
    let assigned = crate::diarize::match_voices(&state.store.lock().unwrap(), &labels)?;
    Ok((labels, assigned))
}
fn reidentify_speakers(app: &AppHandle, id: &str) -> Res<()> {
    let state = app.state::<AppState>();
    let dir = domain::meeting_path(&state.store.lock().unwrap(), id)?;
    let paths: Vec<_> = audio_paths(&dir)?
        .into_iter()
        .filter(|p| {
            !p.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .starts_with("mic.")
        })
        .collect();
    if paths.len() != 1 {
        return Err("Speaker identification needs one system or imported audio track".into());
    }
    let samples = decoded(&paths[0])?;
    let (labels, assigned) = speaker_labels(app, id, &samples)?;
    let store = state.store.lock().unwrap();
    relabel_segments(&store, id, &labels, &assigned, &state.cancelled)
}
fn relabel_segments(
    store: &crate::store::Store,
    id: &str,
    labels: &crate::diarize::Labels,
    assigned: &std::collections::HashMap<i32, String>,
    cancel: &std::sync::atomic::AtomicBool,
) -> Res<()> {
    let rows=domain::query(&store.db,"SELECT id,start,end,text,speaker_id FROM segments WHERE meeting_id=?1 AND source='system' ORDER BY start,id",&[&id])?;
    let tx = store
        .db
        .unchecked_transaction()
        .map_err(|e| e.to_string())?;
    let old_voices: HashSet<_> = rows
        .iter()
        .filter_map(|r| r["speaker_id"].as_str().map(str::to_string))
        .collect();
    for row in rows {
        if cancel.load(Ordering::Relaxed) {
            return Err("Processing cancelled".into());
        }
        let word = Word {
            text: row["text"].as_str().unwrap_or("").into(),
            start: row["start"].as_f64().unwrap_or(0.0),
            end: row["end"].as_f64().unwrap_or(0.0),
        };
        let speaker = crate::diarize::turns(vec![word], labels, assigned)
            .into_iter()
            .next()
            .and_then(|(t, _)| t.speaker);
        tx.execute(
            "UPDATE segments SET speaker_id=?2 WHERE id=?1",
            params![row["id"].as_i64(), speaker],
        )
        .map_err(|e| e.to_string())?;
    }
    // Remove only this meeting's abandoned automatic profiles; keep named/linked people and other meetings.
    for old in old_voices {
        tx.execute("DELETE FROM speakers WHERE id=?1 AND embedding_model=?2 AND parent_id IS NULL AND name GLOB 'Speaker [0-9]*' AND substr(name,9) NOT GLOB '*[^0-9]*' AND COALESCE(email,'')='' AND COALESCE(company,'')='' AND COALESCE(position,'')='' AND COALESCE(notes,'')='' AND NOT EXISTS(SELECT 1 FROM segments WHERE speaker_id=?1) AND NOT EXISTS(SELECT 1 FROM speakers child WHERE child.parent_id=?1)",params![old,crate::diarize::MODEL]).map_err(|e|e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())
}
fn transcribe(app: &AppHandle, id: &str, mut model: Option<&mut Parakeet>) -> Res<()> {
    let state = app.state::<AppState>();
    let dir = domain::meeting_path(&state.store.lock().unwrap(), id)?;
    let paths = audio_paths(&dir)?;
    let config = settings::load(&state.store.lock().unwrap().dir)?;
    let mut mic = Vec::new();
    let mut system = Vec::new();
    let mut duration = 0.0f64;
    for path in paths {
        if state.cancelled.load(Ordering::Relaxed) {
            return Err("Processing cancelled".into());
        }
        let source = if path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .starts_with("mic.")
        {
            "mic"
        } else {
            "system"
        };
        let samples = decoded(&path)?;
        duration = duration.max(samples.len() as f64 / 16000.0);
        let mut words = Vec::new();
        let mut start = 0;
        while start < samples.len() {
            let max = if config.transcription_engine == "local"
                || config.transcription_model.to_lowercase().contains("gpt")
            {
                480000
            } else {
                9600000
            };
            let end = start + crate::cloud_asr::cut(&samples[start..], max);
            let chunk = &samples[start..end];
            let rms = (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len().max(1) as f32).sqrt();
            if rms > 0.0001 {
                words.extend(if config.transcription_engine == "local" {
                    model
                        .as_deref_mut()
                        .ok_or("Local model is not loaded")?
                        .recognize(chunk, start as f64 / 16000.0, &state.cancelled)?
                } else {
                    crate::cloud_asr::recognize(
                        &config,
                        chunk,
                        start as f64 / 16000.0,
                        &state.cancelled,
                    )?
                });
            }
            start = end;
            status(
                app,
                id,
                &format!(
                    "processing:transcribing {}%",
                    start * 100 / samples.len().max(1)
                ),
            )?;
        }
        let config = settings::load(&state.store.lock().unwrap().dir)?;
        let turns = if source == "system" && config.diarization {
            let (labels, assigned) = speaker_labels(app, id, &samples)?;
            crate::diarize::turns(words, &labels, &assigned)
                .into_iter()
                .map(|(mut t, overlap)| {
                    t.overlap = overlap;
                    t
                })
                .collect()
        } else {
            utterances(words, source)
        };
        if source == "mic" {
            mic.extend(turns);
        } else {
            system.extend(turns);
        }
    }
    let mut turns = dedup(mic, &system);
    turns.extend(system);
    turns.sort_by(|a, b| a.start.total_cmp(&b.start));
    if turns.is_empty() {
        return Err("No speech detected".into());
    }
    if state.cancelled.load(Ordering::Relaxed) {
        return Err("Processing cancelled".into());
    }
    let store = state.store.lock().unwrap();
    let tx = store
        .db
        .unchecked_transaction()
        .map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM segments WHERE meeting_id=?1", [id])
        .map_err(|e| e.to_string())?;
    for t in turns {
        tx.execute("INSERT INTO segments(meeting_id,speaker_id,source,start,end,text,overlap) VALUES(?1,?2,?3,?4,?5,?6,?7)",params![id,t.speaker,t.source,t.start,t.end,t.text,t.overlap]).map_err(|e|e.to_string())?;
    }
    tx.execute(
        "UPDATE meetings SET duration=?2 WHERE id=?1",
        params![id, duration],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}
pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        let mut model: Option<Parakeet> = None;
        let mut live_at = std::time::Instant::now();
        let mut live_cursor = std::collections::HashMap::new();
        loop {
            let state = app.state::<AppState>();
            if state.shutdown.load(Ordering::Relaxed) {
                break;
            }
            let job = {
                let mut active = state.processing.lock().unwrap();
                let store = state.store.lock().unwrap();
                let job=domain::query(&store.db,"SELECT id,status FROM meetings WHERE status IN ('queued','recovered','queued:summary','queued:index','queued:speakers') AND deleted_at IS NULL ORDER BY created_at LIMIT 1",&[]).ok().and_then(|mut rows|rows.pop());
                if let Some(row) = &job {
                    if let Some(id) = row["id"].as_str() {
                        state.cancelled.store(false, Ordering::Relaxed);
                        *active = Some(id.into());
                        let _ = store.set_status(id, "processing:starting");
                    }
                }
                job
            };
            let Some(job) = job else {
                if live_at.elapsed().as_secs() >= 3 {
                    live_at = std::time::Instant::now();
                    if let Err(e) = live(&app, &mut model, &mut live_cursor) {
                        let _ = app.emit("live-error", e);
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(500));
                continue;
            };
            let id = job["id"].as_str().unwrap_or("").to_string();
            let summary_only = job["status"] == "queued:summary";
            let index_only = job["status"] == "queued:index";
            let speakers_only = job["status"] == "queued:speakers";
            let result = (|| -> Res<()> {
                let library = state.store.lock().unwrap().dir.clone();
                let config = settings::load(&library)?;
                if speakers_only {
                    model = None;
                    reidentify_speakers(&app, &id)?;
                } else if !summary_only && !index_only {
                    if config.transcription_engine == "local" && !models::ready(&library) {
                        status(&app, &id, "awaiting:models")?;
                        return Ok(());
                    }
                    status(&app, &id, "processing:loading-model")?;
                    if config.transcription_engine == "local" && model.is_none() {
                        let runtime = app
                            .path()
                            .resource_dir()
                            .map_err(|e| e.to_string())?
                            .join("onnxruntime/onnxruntime.dll");
                        let runtime = if runtime.exists() {
                            runtime
                        } else {
                            Path::new(env!("CARGO_MANIFEST_DIR"))
                                .join("binaries/onnxruntime/onnxruntime.dll")
                        };
                        asr::init(&runtime)?;
                        model = Some(Parakeet::load(&models::directory(&library))?);
                    }
                    transcribe(&app, &id, model.as_mut())?;
                }
                if !index_only && !speakers_only && config.cleanup {
                    cleanup(&app, &id, &config)?;
                }
                if !index_only && !speakers_only && (summary_only || config.auto_summary) {
                    if config.provider == "llama" {
                        model = None;
                    }
                    status(&app, &id, "processing:summarizing")?;
                    let (system, input) = {
                        let store = state.store.lock().unwrap();
                        llm::summary_input(&store, &id)?
                    };
                    let summary = llm::summarize(&config, &system, &input)?;
                    if state.cancelled.load(Ordering::Relaxed) {
                        return Err("Processing cancelled".into());
                    }
                    llm::save_summary(&mut state.store.lock().unwrap(), &id, &summary)?;
                }
                status(&app, &id, "processing:indexing")?;
                crate::embed::index(&app, &id)?;
                status(&app, &id, "done")?;
                if !config.export_dir.is_empty() {
                    let path = Path::new(&config.export_dir).join(format!("{id}.md"));
                    domain::export_to(&state.store.lock().unwrap(), &id, &path)?;
                }
                Ok(())
            })();
            if let Err(e) = result {
                let _ = status(&app, &id, &format!("error:{e}"));
            }
            *state.processing.lock().unwrap() = None;
            let _ = app.emit("library-changed", &id);
        }
    });
}

fn live(
    app: &AppHandle,
    model: &mut Option<Parakeet>,
    cursor: &mut std::collections::HashMap<(String, String), f64>,
) -> Res<()> {
    let state = app.state::<AppState>();
    let recording = state
        .recording
        .lock()
        .unwrap()
        .as_ref()
        .filter(|(_, r)| !r.flags.paused.load(Ordering::Relaxed))
        .map(|(id, _)| id.clone());
    let Some(id) = recording else { return Ok(()) };
    let library = state.store.lock().unwrap().dir.clone();
    if !settings::load(&library)?.live || !models::ready(&library) {
        return Ok(());
    }
    if model.is_none() {
        let installed = app
            .path()
            .resource_dir()
            .map_err(|e| e.to_string())?
            .join("onnxruntime/onnxruntime.dll");
        let local =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("binaries/onnxruntime/onnxruntime.dll");
        asr::init(if installed.exists() {
            &installed
        } else {
            &local
        })?;
        *model = Some(Parakeet::load(&models::directory(&library))?);
    }
    for source in ["system", "mic"] {
        let path = library
            .join("recordings")
            .join(&id)
            .join(format!("{source}.wav"));
        if !path.exists() {
            continue;
        }
        let (audio, offset) = asr::tail(&path, 10.0)?;
        let end = offset + audio.len() as f64 / 16000.0;
        if !crate::cloud_asr::has_sound(&audio) {
            cursor.insert((id.clone(), source.into()), end);
            continue;
        }
        let key = (id.clone(), source.into());
        let last = *cursor.get(&key).unwrap_or(&0.0);
        if end - last < 2.0 || audio.is_empty() {
            continue;
        }
        let words = model
            .as_mut()
            .unwrap()
            .recognize(&audio, offset, &state.shutdown)?;
        let words = words
            .into_iter()
            .filter(|w| w.start >= last - 0.02 && w.end < end - 0.7)
            .collect::<Vec<_>>();
        let turns = utterances(words, source);
        let turns = if source == "mic" {
            let existing = {
                let store = state.store.lock().unwrap();
                domain::query(&store.db,"SELECT start,end,text FROM segments WHERE meeting_id=?1 AND source='system' AND end>?2",&[&id,&offset])?
            };
            let system = existing
                .into_iter()
                .map(|r| Turn {
                    start: r["start"].as_f64().unwrap_or(0.0),
                    end: r["end"].as_f64().unwrap_or(0.0),
                    text: r["text"].as_str().unwrap_or("").into(),
                    source: "system".into(),
                    speaker: None,
                    overlap: false,
                })
                .collect::<Vec<_>>();
            dedup(turns, &system)
        } else {
            turns
        };
        let store = state.store.lock().unwrap();
        for t in turns {
            if !store
                .db
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM meetings WHERE id=?1 AND status='recording')",
                    [&id],
                    |r| r.get::<_, bool>(0),
                )
                .map_err(|e| e.to_string())?
            {
                break;
            }
            store.db.execute("INSERT INTO segments(meeting_id,speaker_id,source,start,end,text) VALUES(?1,?2,?3,?4,?5,?6)",params![id,t.speaker,t.source,t.start,t.end,t.text]).map_err(|e|e.to_string())?;
            cursor.insert(key.clone(), t.end);
        }
    }
    let _ = app.emit("library-changed", &id);
    Ok(())
}
fn cleanup(app: &AppHandle, id: &str, config: &settings::Settings) -> Res<()> {
    status(app, id, "processing:cleanup")?;
    let state = app.state::<AppState>();
    let rows = {
        let store = state.store.lock().unwrap();
        domain::query(
            &store.db,
            "SELECT id,text FROM segments WHERE meeting_id=?1 AND user_edited=0 ORDER BY start,id",
            &[&id],
        )?
    };
    for batch in rows.chunks(25) {
        if state.cancelled.load(Ordering::Relaxed) {
            return Err("Processing cancelled".into());
        }
        let input = serde_json::to_string(
            &batch
                .iter()
                .map(|r| r["text"].as_str().unwrap_or(""))
                .collect::<Vec<_>>(),
        )
        .map_err(|e| e.to_string())?;
        let schema = serde_json::json!({"type":"array","minItems":batch.len(),"maxItems":batch.len(),"items":{"type":"object","additionalProperties":false,"required":["text","irrelevant"],"properties":{"text":{"type":"string"},"irrelevant":{"type":"boolean"}}}});
        let reply=llm::ask_json(config,"Fix speech-to-text output. Remove filler words, false starts and stutters; fix punctuation. Never change meaning, translate, merge or split lines. Mark irrelevant only a line with no content. Return JSON array in the same order: [{\"text\":\"...\",\"irrelevant\":false}].",&input,&schema)?;
        let values = reply
            .as_array()
            .filter(|v| v.len() == batch.len())
            .ok_or("AI cleanup returned a different number of lines")?;
        if values
            .iter()
            .any(|v| v["text"].as_str().is_none() || v["irrelevant"].as_bool().is_none())
        {
            return Err("Invalid AI cleanup response".into());
        }
        let store = state.store.lock().unwrap();
        let tx = store
            .db
            .unchecked_transaction()
            .map_err(|e| e.to_string())?;
        for (row, value) in batch.iter().zip(values) {
            tx.execute("UPDATE segments SET original_text=COALESCE(original_text,text),text=?2,irrelevant=?3 WHERE id=?1 AND user_edited=0",params![row["id"].as_i64(),value["text"].as_str(),value["irrelevant"].as_bool()]).map_err(|e|e.to_string())?;
        }
        tx.commit().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn speaker_repair_preserves_text_edits_and_named_people() {
        let dir = std::env::temp_dir().join(format!("speaker-repair-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = crate::store::Store::open(&dir).unwrap();
        let id = store.new_meeting("Title to keep").unwrap();
        for (sid, name) in [
            ("old", "Speaker 85"),
            ("named", "Alice"),
            ("new", "Speaker 1"),
        ] {
            store.db.execute("INSERT INTO speakers(id,name,embedding,embedding_model,created_at) VALUES(?1,?2,'[]',?3,'now')",rusqlite::params![sid,name,crate::diarize::MODEL]).unwrap();
        }
        store.db.execute("INSERT INTO segments(meeting_id,speaker_id,source,start,end,text,original_text,user_edited) VALUES(?1,'old','system',0,2,'Edited sentence','Original sentence',1),(?1,'named','system',2,4,'Other sentence',NULL,0),(?1,'me','mic',4,5,'My sentence',NULL,0)",[&id]).unwrap();
        let before=crate::domain::query(&store.db,"SELECT id,text,original_text,user_edited,start,end FROM segments WHERE meeting_id=?1 ORDER BY id",&[&id]).unwrap();
        let labels = crate::diarize::Labels {
            ranges: vec![(0.0, 4.0, 0)],
            voices: std::collections::HashMap::new(),
        };
        let assigned = std::collections::HashMap::from([(0, "new".to_string())]);
        super::relabel_segments(&store, &id, &labels, &assigned, &false.into()).unwrap();
        assert_eq!(before,crate::domain::query(&store.db,"SELECT id,text,original_text,user_edited,start,end FROM segments WHERE meeting_id=?1 ORDER BY id",&[&id]).unwrap());
        assert_eq!(
            store
                .db
                .query_row(
                    "SELECT count(*) FROM segments WHERE speaker_id='new'",
                    [],
                    |r| r.get::<_, i32>(0)
                )
                .unwrap(),
            2
        );
        assert_eq!(
            store
                .db
                .query_row("SELECT count(*) FROM speakers WHERE id='old'", [], |r| r
                    .get::<_, i32>(0))
                .unwrap(),
            0
        );
        assert_eq!(
            store
                .db
                .query_row(
                    "SELECT count(*) FROM speakers WHERE id IN ('named','me')",
                    [],
                    |r| r.get::<_, i32>(0)
                )
                .unwrap(),
            2
        );
        let changed = std::collections::HashMap::from([(0, "named".to_string())]);
        assert!(super::relabel_segments(&store, &id, &labels, &changed, &true.into()).is_err());
        assert_eq!(
            store
                .db
                .query_row(
                    "SELECT count(*) FROM segments WHERE speaker_id='new'",
                    [],
                    |r| r.get::<_, i32>(0)
                )
                .unwrap(),
            2
        );
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn drops_echo_only_near_matching_system_speech() {
        let w = |text: &str, start: f64| super::Turn {
            text: text.into(),
            start,
            end: start + 2.0,
            source: "mic".into(),
            speaker: None,
            overlap: false,
        };
        let mic = vec![
            w("hello world today", 1.0),
            w("different sentence", 2.0),
            w("hello world today", 30.0),
        ];
        let out = super::dedup(mic, &[w("Hello, world today!", 1.0)]);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].text, "different sentence");
    }
}
