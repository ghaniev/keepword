use crate::{
    diarize::cosine,
    domain,
    settings::{self, Settings},
    store::Store,
};
use ndarray::Array2;
use ort::{session::Session, value::TensorRef};
use rusqlite::params;
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{Mutex, OnceLock},
};
type Res<T> = Result<T, String>;
const ID: &str = "minilm:e8f8c211:mean:128:pad1:chunks30:v1";
struct Model {
    session: Session,
    tokenizer: tokenizers::Tokenizer,
}
static MODEL: OnceLock<Mutex<Option<Model>>> = OnceLock::new();
pub fn ready(library: &Path) -> bool {
    library.join("Models/minilm/model.onnx").is_file()
        && library.join("Models/minilm/tokenizer.json").is_file()
}
pub fn vector(library: &Path, config: &Settings, text: &str) -> Res<Option<Vec<f32>>> {
    if config.embedding_source == "off" {
        return Ok(None);
    }
    if config.embedding_source == "server" {
        if config.embedding_model.is_empty() {
            return Ok(None);
        }
        let response = crate::llm::client()?
            .post(format!(
                "{}/embeddings",
                config.embedding_url.trim_end_matches('/')
            ))
            .bearer_auth(settings::secret(&settings::credential_id(
                "embedding",
                "server",
                &config.embedding_url,
            ))?)
            .json(&json!({"model":config.embedding_model,"input":text}))
            .send()
            .and_then(|r| r.error_for_status())
            .map_err(|e| e.to_string())?
            .json::<Value>()
            .map_err(|e| e.to_string())?;
        return serde_json::from_value(response["data"][0]["embedding"].clone())
            .map(Some)
            .map_err(|e| e.to_string());
    }
    if !ready(library) {
        return Ok(None);
    }
    let mut guard = MODEL.get_or_init(|| Mutex::new(None)).lock().unwrap();
    if guard.is_none() {
        let runtime =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("binaries/onnxruntime/onnxruntime.dll");
        let installed = std::env::current_exe()
            .map_err(|e| e.to_string())?
            .parent()
            .ok_or("Invalid executable")?
            .join("onnxruntime/onnxruntime.dll");
        crate::asr::init(if installed.exists() {
            &installed
        } else {
            &runtime
        })?;
        let mut tokenizer =
            tokenizers::Tokenizer::from_file(library.join("Models/minilm/tokenizer.json"))
                .map_err(|e| e.to_string())?;
        tokenizer
            .with_truncation(Some(tokenizers::TruncationParams {
                max_length: 128,
                ..Default::default()
            }))
            .map_err(|e| e.to_string())?;
        tokenizer.with_padding(None);
        let session = Session::builder()
            .map_err(|e| e.to_string())?
            .with_intra_threads(4)
            .map_err(|e| e.to_string())?
            .commit_from_file(library.join("Models/minilm/model.onnx"))
            .map_err(|e| e.to_string())?;
        *guard = Some(Model { session, tokenizer });
    }
    let model = guard.as_mut().unwrap();
    let encoding = model
        .tokenizer
        .encode(text, true)
        .map_err(|e| e.to_string())?;
    let len = encoding.get_ids().len();
    let ids = Array2::from_shape_vec(
        (1, len),
        encoding.get_ids().iter().map(|x| *x as i64).collect(),
    )
    .map_err(|e| e.to_string())?;
    let mask = Array2::from_shape_vec(
        (1, len),
        encoding
            .get_attention_mask()
            .iter()
            .map(|x| *x as i64)
            .collect(),
    )
    .map_err(|e| e.to_string())?;
    let types = Array2::<i64>::zeros((1, len));
    let mut inputs = vec![
        (
            "input_ids",
            TensorRef::from_array_view(ids.view())
                .map_err(|e| e.to_string())?
                .into_dyn(),
        ),
        (
            "attention_mask",
            TensorRef::from_array_view(mask.view())
                .map_err(|e| e.to_string())?
                .into_dyn(),
        ),
    ];
    if model
        .session
        .inputs
        .iter()
        .any(|i| i.name == "token_type_ids")
    {
        inputs.push((
            "token_type_ids",
            TensorRef::from_array_view(types.view())
                .map_err(|e| e.to_string())?
                .into_dyn(),
        ));
    }
    let output = model.session.run(inputs).map_err(|e| e.to_string())?;
    let hidden = output[0]
        .try_extract_array::<f32>()
        .map_err(|e| e.to_string())?;
    let shape = hidden.shape();
    if shape.len() != 3 || shape[1] != len {
        return Err("Unexpected embedding model output".into());
    }
    let dim = shape[2];
    let mut vector = vec![0.0; dim];
    let mut count = 0.0f32;
    for i in 0..len {
        if mask[[0, i]] == 0 {
            continue;
        }
        count += 1.0;
        for d in 0..dim {
            vector[d] += hidden[[0, i, d]];
        }
    }
    for value in &mut vector {
        *value /= count.max(1.0f32);
    }
    Ok(Some(vector))
}
pub fn index(app: &tauri::AppHandle, id: &str) -> Res<()> {
    use tauri::Manager;
    let state = app.state::<crate::AppState>();
    let (dir, config, segments) = {
        let store = state.store.lock().unwrap();
        (store.dir.clone(),settings::load(&store.dir)?,domain::query(&store.db,"SELECT start,end,text FROM segments WHERE meeting_id=?1 AND irrelevant=0 ORDER BY start",&[&id])?)
    };
    let mut chunks = Vec::new();
    for s in segments {
        let text = s["text"].as_str().unwrap_or("");
        let words = text.split_whitespace().collect::<Vec<_>>();
        for part in words.chunks(30) {
            let text = part.join(" ");
            let vector = vector(&dir, &config, &text)?;
            chunks.push((
                s["start"].as_f64().unwrap_or(0.0),
                s["end"].as_f64().unwrap_or(0.0),
                text,
                vector,
            ));
        }
    }
    let store = state.store.lock().unwrap();
    let tx = store
        .db
        .unchecked_transaction()
        .map_err(|e| e.to_string())?;
    tx.execute("DELETE FROM chunks WHERE meeting_id=?1", [id])
        .map_err(|e| e.to_string())?;
    for (start, end, text, vector) in chunks {
        tx.execute(
            "INSERT INTO chunks(meeting_id,start,end,text,embedding) VALUES(?1,?2,?3,?4,?5)",
            params![
                id,
                start,
                end,
                text,
                vector
                    .map(|v| serde_json::to_string(&v))
                    .transpose()
                    .map_err(|e| e.to_string())?
            ],
        )
        .map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    std::fs::write(dir.join("embedding-model.txt"), model_id(&config))
        .map_err(|e| e.to_string())?;
    Ok(())
}
fn model_id(c: &Settings) -> String {
    if c.embedding_source == "server" {
        format!(
            "server:{}:{}:chunks30:v1",
            c.embedding_url, c.embedding_model
        )
    } else {
        ID.into()
    }
}
pub fn hybrid(
    store: &Store,
    question: &str,
    meeting: Option<&str>,
    query: Option<&[f32]>,
) -> Res<Vec<Value>> {
    hybrid_scoped(store, question, meeting, query, &json!({}))
}
pub fn hybrid_scoped(
    store: &Store,
    question: &str,
    meeting: Option<&str>,
    query: Option<&[f32]>,
    scope: &Value,
) -> Res<Vec<Value>> {
    let mut lexical = domain::search_scoped(store, question, meeting, scope)?;
    let config = settings::load(&store.dir)?;
    let compatible = std::fs::read_to_string(store.dir.join("embedding-model.txt"))
        .ok()
        .as_deref()
        == Some(model_id(&config).as_str());
    let mut scores: std::collections::HashMap<(String, u64), (f64, Value)> =
        std::collections::HashMap::new();
    for (rank, row) in lexical.drain(..).enumerate() {
        let key = (
            row["meeting_id"].as_str().unwrap_or("").into(),
            row["start"].as_f64().unwrap_or(0.0).to_bits(),
        );
        scores.insert(key, (1.0 / (60.0 + rank as f64), row));
    }
    if let Some(query) = query.filter(|_| compatible) {
        let scope = scope.to_string();
        let filter = domain::scope_filter("c");
        let rows=domain::query(&store.db,&format!("SELECT c.*,m.title,COALESCE((SELECT COALESCE(root.name,p.name) FROM segments s LEFT JOIN speakers p ON p.id=s.speaker_id LEFT JOIN speakers root ON root.id=p.parent_id WHERE s.meeting_id=c.meeting_id AND s.start<=c.end AND s.end>=c.start LIMIT 1),'Speaker') AS speaker_name FROM chunks c JOIN meetings m ON m.id=c.meeting_id WHERE c.embedding IS NOT NULL AND {filter} AND ?1=''"),&[&"",&meeting,&scope])?;
        let mut similar = Vec::new();
        for row in rows {
            let vector: Vec<f32> =
                serde_json::from_str(row["embedding"].as_str().unwrap_or("[]")).unwrap_or_default();
            let score = cosine(query, &vector);
            if score > 0.15 {
                similar.push((score, row));
            }
        }
        similar.sort_by(|a, b| b.0.total_cmp(&a.0));
        for (rank, (_, row)) in similar.into_iter().take(60).enumerate() {
            let key = (
                row["meeting_id"].as_str().unwrap_or("").into(),
                row["start"].as_f64().unwrap_or(0.0).to_bits(),
            );
            let entry = scores.entry(key).or_insert((0.0, row));
            entry.0 += 1.0 / (60.0 + rank as f64);
        }
    }
    let mut ranked = scores.into_values().collect::<Vec<_>>();
    ranked.sort_by(|a, b| b.0.total_cmp(&a.0));
    Ok(ranked
        .into_iter()
        .take(60)
        .map(|(score, mut row)| {
            row["hybrid_score"] = json!(score);
            row
        })
        .collect())
}
pub fn related(store: &Store, id: &str) -> Res<Vec<Value>> {
    let config = settings::load(&store.dir)?;
    let compatible = std::fs::read_to_string(store.dir.join("embedding-model.txt"))
        .ok()
        .as_deref()
        == Some(model_id(&config).as_str());
    if !compatible {
        return domain::view(store, "related", Some(id), "")
            .and_then(|v| serde_json::from_value(v).map_err(|e| e.to_string()));
    }
    let rows = domain::query(
        &store.db,
        "SELECT meeting_id,embedding FROM chunks WHERE embedding IS NOT NULL",
        &[],
    )?;
    let vectors = rows
        .iter()
        .filter_map(|r| {
            serde_json::from_str::<Vec<f32>>(r["embedding"].as_str()?)
                .ok()
                .map(|v| (r["meeting_id"].as_str().unwrap_or(""), v))
        })
        .collect::<Vec<_>>();
    let own = vectors
        .iter()
        .filter(|(meeting, _)| *meeting == id)
        .collect::<Vec<_>>();
    if own.is_empty() {
        return domain::view(store, "related", Some(id), "")
            .and_then(|v| serde_json::from_value(v).map_err(|e| e.to_string()));
    }
    let mut centroid = vec![0.0; own[0].1.len()];
    for (_, vector) in &own {
        if vector.len() == centroid.len() {
            for (mean, value) in centroid.iter_mut().zip(vector) {
                *mean += value;
            }
        }
    }
    let mut scores = std::collections::HashMap::<String, f32>::new();
    for (meeting, v) in &vectors {
        if *meeting == id {
            continue;
        }
        let score = cosine(&centroid, v);
        scores
            .entry(meeting.to_string())
            .and_modify(|s| *s = s.max(score))
            .or_insert(score);
    }
    let mut rows = domain::query(
        &store.db,
        "SELECT * FROM meetings WHERE id<>?1 AND deleted_at IS NULL",
        &[&id],
    )?;
    rows.retain(|r| {
        scores
            .get(r["id"].as_str().unwrap_or(""))
            .is_some_and(|s| *s > 0.2)
    });
    for row in &mut rows {
        row["similarity"] = json!(scores[row["id"].as_str().unwrap()]);
    }
    rows.sort_by(|a, b| {
        b["similarity"]
            .as_f64()
            .unwrap_or(0.0)
            .total_cmp(&a["similarity"].as_f64().unwrap_or(0.0))
    });
    rows.truncate(8);
    Ok(rows)
}
#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "Requires downloaded MiniLM files in target/test-embedding"]
    fn embeds_multilingual_reference() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("target/test-embedding");
        let config = crate::settings::Settings::default();
        let a = super::vector(&root, &config, "The meeting starts tomorrow")
            .unwrap()
            .unwrap();
        let b = super::vector(&root, &config, "Встреча начнётся завтра")
            .unwrap()
            .unwrap();
        let c = super::vector(&root, &config, "A cat is sleeping on the sofa")
            .unwrap()
            .unwrap();
        assert_eq!(a.len(), 384);
        assert!(crate::diarize::cosine(&a, &b) > crate::diarize::cosine(&a, &c));
    }
}
