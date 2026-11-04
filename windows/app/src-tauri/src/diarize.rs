use crate::{asr::Word, domain, pipeline::Turn, store::Store};
use rusqlite::params;
use sherpa_onnx::{
    OfflineSpeakerDiarization, OfflineSpeakerDiarizationConfig, OfflineSpeakerDiarizationSegment,
    SpeakerEmbeddingExtractor, SpeakerEmbeddingExtractorConfig,
};
use std::{
    collections::{HashMap, HashSet},
    path::Path,
};
pub const MODEL: &str = "sherpa:nemo-en-titanet-small:ad4a1802";
pub const DEFAULT_MAX_SPEAKERS: i32 = 20;
type Res<T> = Result<T, String>;
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() || a.is_empty() {
        return -1.0;
    }
    let dot = a.iter().zip(b).map(|(a, b)| a * b).sum::<f32>();
    let aa = a.iter().map(|a| a * a).sum::<f32>().sqrt();
    let bb = b.iter().map(|b| b * b).sum::<f32>().sqrt();
    if aa.is_finite() && bb.is_finite() && dot.is_finite() && aa * bb > 0.0 {
        (dot / (aa * bb)).clamp(-1.0, 1.0)
    } else {
        -1.0
    }
}
pub struct Labels {
    pub ranges: Vec<(f64, f64, i32)>,
    pub voices: HashMap<i32, Vec<f32>>,
}
pub fn analyze(dir: &Path, audio: &[f32], expected: Option<i32>, max: Option<i32>) -> Res<Labels> {
    for count in [expected, max].into_iter().flatten() {
        if !(1..=100).contains(&count) {
            return Err("Speaker count must be between 1 and 100".into());
        }
    }
    let mut config = OfflineSpeakerDiarizationConfig::default();
    config.segmentation.pyannote.model = Some(dir.join("model.int8.onnx").display().to_string());
    config.embedding.model = Some(dir.join("embedding.onnx").display().to_string());
    config.clustering.num_clusters = expected.unwrap_or(-1);
    config.clustering.threshold = 0.6;
    let diarizer =
        OfflineSpeakerDiarization::create(&config).ok_or("Could not load diarization models")?;
    let result = diarizer.process(audio).ok_or("Diarization failed")?;
    let extractor = SpeakerEmbeddingExtractor::create(&SpeakerEmbeddingExtractorConfig {
        model: config.embedding.model.clone(),
        ..Default::default()
    })
    .ok_or("Could not load voice model")?;
    let mut labels = extract_labels(result.sort_by_start_time(), audio, &extractor)?;
    if expected.is_none() {
        consolidate(&mut labels);
        // A maximum is an upper bound, not a request to invent that many people.
        let limit = max.unwrap_or(DEFAULT_MAX_SPEAKERS);
        if labels.voices.len() > limit as usize {
            config.clustering.num_clusters = limit;
            diarizer.set_config(&config);
            let result = diarizer.process(audio).ok_or("Diarization failed")?;
            labels = extract_labels(result.sort_by_start_time(), audio, &extractor)?;
            consolidate(&mut labels);
        }
    }
    Ok(labels)
}
fn extract_labels(
    segments: Vec<OfflineSpeakerDiarizationSegment>,
    audio: &[f32],
    extractor: &SpeakerEmbeddingExtractor,
) -> Res<Labels> {
    let mut ranges = Vec::new();
    for s in segments {
        let start = (s.start.max(0.0) * 16000.0) as usize;
        let end = (s.end.max(0.0) * 16000.0) as usize;
        if start >= end || end > audio.len() {
            continue;
        }
        ranges.push((s.start as f64, s.end as f64, s.speaker));
    }
    // Long, solo turns are more reliable voice references than the first short interjection.
    let mut clips: HashMap<i32, Vec<(f64, f64)>> = HashMap::new();
    for &(start, end, id) in &ranges {
        let mut solo = vec![(start, end)];
        for &(a, b, other) in &ranges {
            if other == id || a >= end || b <= start {
                continue;
            }
            solo = solo
                .into_iter()
                .flat_map(|(s, e)| {
                    if a >= e || b <= s {
                        vec![(s, e)]
                    } else {
                        [(s, a.min(e)), (b.max(s), e)]
                            .into_iter()
                            .filter(|(s, e)| e > s)
                            .collect()
                    }
                })
                .collect();
        }
        clips
            .entry(id)
            .or_default()
            .extend(solo.into_iter().filter(|(s, e)| e - s >= 1.0));
    }
    let mut voices = HashMap::new();
    for (id, mut clips) in clips {
        if clips.is_empty() {
            continue;
        }
        clips.sort_by(|a, b| {
            (b.1 - b.0)
                .total_cmp(&(a.1 - a.0))
                .then(a.0.total_cmp(&b.0))
        });
        let mut samples = Vec::new();
        for (start, end) in clips {
            let start = (start * 16000.0) as usize;
            let end = ((end * 16000.0) as usize)
                .min(start + 16000 * 15)
                .min(start + 16000 * 30 - samples.len());
            samples.extend_from_slice(&audio[start..end]);
            if samples.len() == 16000 * 30 {
                break;
            }
        }
        let stream = extractor.create_stream().ok_or("Voice stream failed")?;
        stream.accept_waveform(16000, &samples);
        stream.input_finished();
        if extractor.is_ready(&stream) {
            if let Some(v) = extractor.compute(&stream) {
                if v.iter().all(|x| x.is_finite()) && cosine(&v, &v) > 0.0 {
                    voices.insert(id, v);
                }
            }
        }
    }
    Ok(Labels { ranges, voices })
}
fn consolidate(labels: &mut Labels) {
    let mut ids: Vec<i32> = labels.voices.keys().copied().collect();
    ids.sort_unstable();
    let mut groups: Vec<Vec<i32>> = ids.iter().map(|&id| vec![id]).collect();
    let mut conflicts = HashSet::new();
    let mut ranges = labels.ranges.clone();
    ranges.sort_by(|a, b| a.0.total_cmp(&b.0));
    for (i, &(start, end, id)) in ranges.iter().enumerate() {
        for &(a, b, other) in &ranges[i + 1..] {
            if a >= end {
                break;
            }
            if other != id && end.min(b) - start.max(a) > 0.1 {
                conflicts.insert((id.min(other), id.max(other)));
            }
        }
    }
    loop {
        let mut best = None;
        let mut best_score = 0.7;
        for i in 0..groups.len() {
            for j in i + 1..groups.len() {
                let mut score = 1.0_f32;
                for &a in &groups[i] {
                    for &b in &groups[j] {
                        let similarity = if conflicts.contains(&(a.min(b), a.max(b))) {
                            -1.0
                        } else {
                            cosine(&labels.voices[&a], &labels.voices[&b])
                        };
                        score = score.min(similarity);
                    }
                }
                if score >= best_score && best.is_none_or(|_| score > best_score) {
                    best = Some((i, j));
                    best_score = score;
                }
            }
        }
        let Some((i, j)) = best else {
            break;
        };
        let other = groups.remove(j);
        groups[i].extend(other);
    }
    let mut mapping = HashMap::new();
    let mut voices = HashMap::new();
    for (index, group) in groups.into_iter().enumerate() {
        let id = index as i32;
        let mut voice = vec![0.0; labels.voices[&group[0]].len()];
        for member in group {
            mapping.insert(member, id);
            let v = &labels.voices[&member];
            let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            let duration = labels
                .ranges
                .iter()
                .filter(|r| r.2 == member)
                .map(|r| r.1 - r.0)
                .sum::<f64>() as f32;
            if norm > 0.0 {
                for (a, b) in voice.iter_mut().zip(v) {
                    *a += b / norm * duration;
                }
            }
        }
        voices.insert(id, voice);
    }
    for range in &mut labels.ranges {
        range.2 = mapping.get(&range.2).copied().unwrap_or(-1);
    }
    labels.voices = voices;
}
pub fn match_voices(store: &Store, labels: &Labels) -> Res<HashMap<i32, String>> {
    let known = domain::query(
        &store.db,
        "SELECT * FROM speakers WHERE embedding_model=?1",
        &[&MODEL],
    )?;
    let mut pairs = Vec::new();
    for (cluster, voice) in &labels.voices {
        for (i, k) in known.iter().enumerate() {
            let original: Vec<f32> =
                serde_json::from_str(k["embedding"].as_str().unwrap_or("[]")).unwrap_or_default();
            let mut samples: Vec<Vec<f32>> =
                serde_json::from_str(k["voice_samples"].as_str().unwrap_or("[]"))
                    .unwrap_or_default();
            samples.push(original);
            let score = samples
                .iter()
                .map(|v| cosine(v, voice))
                .fold(-1.0, f32::max);
            if score >= 0.7 {
                pairs.push((*cluster, i, score));
            }
        }
    }
    pairs.sort_by(|a, b| b.2.total_cmp(&a.2));
    let mut assigned = HashMap::new();
    let mut people = HashSet::new();
    for (cluster, index, score) in pairs {
        let k = &known[index];
        let id = k["id"].as_str().unwrap();
        let person = k["parent_id"].as_str().unwrap_or(id);
        if assigned.contains_key(&cluster) || !people.insert(person.to_string()) {
            continue;
        }
        assigned.insert(cluster, id.to_string());
        if score >= 0.8 {
            let mut samples: Vec<Vec<f32>> =
                serde_json::from_str(k["voice_samples"].as_str().unwrap_or("[]"))
                    .unwrap_or_default();
            if samples.len() < 5 {
                samples.push(labels.voices[&cluster].clone());
                store
                    .db
                    .execute(
                        "UPDATE speakers SET voice_samples=?2 WHERE id=?1",
                        params![
                            id,
                            serde_json::to_string(&samples).map_err(|e| e.to_string())?
                        ],
                    )
                    .map_err(|e| e.to_string())?;
            }
        }
    }
    // A sub-second/noisy fragment without a usable voice must not create a new person.
    let clusters: HashSet<i32> = labels.voices.keys().copied().collect();
    for cluster in clusters {
        if assigned.contains_key(&cluster) {
            continue;
        }
        let id = uuid::Uuid::new_v4().to_string();
        let embedding = labels.voices.get(&cluster).cloned().unwrap_or_default();
        store.db.execute("INSERT INTO speakers(id,name,embedding,embedding_model,created_at) VALUES(?1,?2,?3,?4,strftime('%Y-%m-%d %H:%M:%f','now'))",params![id,format!("Speaker {}",cluster+1),serde_json::to_string(&embedding).map_err(|e|e.to_string())?,MODEL]).map_err(|e|e.to_string())?;
        assigned.insert(cluster, id);
    }
    Ok(assigned)
}
pub fn turns(
    words: Vec<Word>,
    labels: &Labels,
    assigned: &HashMap<i32, String>,
) -> Vec<(Turn, bool)> {
    let mut out: Vec<(Turn, bool)> = Vec::new();
    let mut overlap_words = 0;
    for w in words {
        let mut coverage: HashMap<i32, f64> = HashMap::new();
        for &(start, end, speaker) in &labels.ranges {
            let n = (end.min(w.end) - start.max(w.start)).max(0.0);
            if n > 0.0 {
                *coverage.entry(speaker).or_default() += n;
            }
        }
        let speaker = coverage
            .iter()
            .max_by(|a, b| a.1.total_cmp(b.1))
            .map(|(id, _)| *id)
            .or_else(|| {
                labels
                    .ranges
                    .iter()
                    .min_by(|a, b| {
                        ((a.0 - w.start).abs().min((a.1 - w.start).abs()))
                            .total_cmp(&((b.0 - w.start).abs().min((b.1 - w.start).abs())))
                    })
                    .map(|r| r.2)
            })
            .and_then(|s| assigned.get(&s))
            .cloned();
        let overlap = coverage
            .values()
            .filter(|n| **n >= (w.end - w.start).max(0.05) / 2.0)
            .count()
            > 1;
        if let Some((last, flag)) = out.last_mut() {
            if last.speaker == speaker && w.start - last.end < 1.2 && w.end - last.start < 40.0 {
                last.text.push(' ');
                last.text.push_str(&w.text);
                last.end = w.end;
                overlap_words += usize::from(overlap);
                *flag = overlap_words >= 2;
                continue;
            }
        }
        overlap_words = usize::from(overlap);
        out.push((
            Turn {
                text: w.text,
                start: w.start,
                end: w.end,
                source: "system".into(),
                speaker,
                overlap: false,
            },
            false,
        ));
    }
    out
}
#[cfg(test)]
mod tests {
    #[test]
    fn consolidates_85_fragments_into_10_voices_without_new_people_on_retry() {
        let mut labels = super::Labels {
            ranges: Vec::new(),
            voices: std::collections::HashMap::new(),
        };
        for id in 0..85 {
            let mut voice = vec![0.0; 12];
            voice[(id % 10) as usize] = 1.0;
            voice[10 + (id % 2) as usize] = 0.05;
            labels
                .ranges
                .push((id as f64 * 3.0, id as f64 * 3.0 + 2.0, id));
            labels.voices.insert(id, voice);
        }
        super::consolidate(&mut labels);
        assert_eq!(labels.voices.len(), 10);
        for (i, r) in labels.ranges.iter().enumerate() {
            assert_eq!(r.2, i as i32 % 10);
        }
        let dir = std::env::temp_dir().join(format!("speaker-regression-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = crate::store::Store::open(&dir).unwrap();
        assert_eq!(super::match_voices(&store, &labels).unwrap().len(), 10);
        assert_eq!(super::match_voices(&store, &labels).unwrap().len(), 10);
        assert_eq!(
            store
                .db
                .query_row("SELECT count(*) FROM speakers WHERE id!='me'", [], |r| r
                    .get::<_, i32>(0))
                .unwrap(),
            10
        );
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn keeps_overlapping_and_different_voices_separate() {
        let mut labels = super::Labels {
            ranges: vec![(0.0, 5.0, 0), (2.0, 6.0, 1)],
            voices: std::collections::HashMap::from([(0, vec![1.0, 0.01]), (1, vec![1.0, -0.01])]),
        };
        super::consolidate(&mut labels);
        assert_eq!(labels.voices.len(), 2);
        let mut labels = super::Labels {
            ranges: vec![(0.0, 1.0, 0), (2.0, 3.0, 1), (4.0, 5.0, 2)],
            voices: (0..3)
                .map(|i| {
                    let a = i as f32 * 0.5;
                    (i, vec![a.cos(), a.sin()])
                })
                .collect(),
        };
        super::consolidate(&mut labels);
        assert_eq!(
            labels.voices.len(),
            2,
            "similarity chains must not merge dissimilar people"
        );
    }
    #[test]
    fn unreliable_fragments_do_not_create_people() {
        let dir = std::env::temp_dir().join(format!("speaker-short-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = crate::store::Store::open(&dir).unwrap();
        let labels = super::Labels {
            ranges: vec![(0.0, 0.2, 0)],
            voices: std::collections::HashMap::new(),
        };
        assert!(super::match_voices(&store, &labels).unwrap().is_empty());
        assert_eq!(
            store
                .db
                .query_row("SELECT count(*) FROM speakers", [], |r| r.get::<_, i32>(0))
                .unwrap(),
            1
        );
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn compact_numbers_do_not_assign_unreliable_fragments_to_another_person() {
        let mut labels = super::Labels {
            ranges: vec![(0.0, 2.0, 0), (3.0, 3.2, 1), (4.0, 6.0, 84)],
            voices: std::collections::HashMap::from([(0, vec![1.0, 0.0]), (84, vec![0.0, 1.0])]),
        };
        super::consolidate(&mut labels);
        assert_eq!(
            labels.ranges.iter().map(|r| r.2).collect::<Vec<_>>(),
            vec![0, -1, 1]
        );
        assert_eq!(labels.voices.len(), 2);
    }
    #[test]
    #[ignore = "Requires downloaded speaker models and test-speech.wav"]
    fn diarizes_real_fixture() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let dir = root.join("target/test-models/diarization");
        let audio = crate::asr::audio(&root.join("target/test-speech.wav")).unwrap();
        let labels = super::analyze(&dir, &audio, Some(1), None).unwrap();
        assert!(!labels.ranges.is_empty());
        assert_eq!(labels.voices.len(), 1);
        let library = std::env::temp_dir().join(format!("voice-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&library).unwrap();
        let store = crate::store::Store::open(&library).unwrap();
        let a = super::match_voices(&store, &labels).unwrap();
        let b = super::match_voices(&store, &labels).unwrap();
        assert_eq!(a, b);
        let repeated: Vec<f32> = (0..4)
            .flat_map(|_| audio.iter().copied().chain(std::iter::repeat_n(0.0, 16000)))
            .collect();
        let auto = super::analyze(&dir, &repeated, None, None).unwrap();
        assert_eq!(
            auto.voices.len(),
            1,
            "one voice returning in later windows must stay one speaker"
        );
        let limited = super::analyze(&dir, &repeated, None, Some(1)).unwrap();
        assert!(limited.voices.len() <= 1);
        drop(store);
        std::fs::remove_dir_all(library).unwrap();
    }
    #[test]
    fn rejects_incompatible_vector_spaces() {
        assert_eq!(super::cosine(&[1.0], &[1.0, 2.0]), -1.0);
        assert_eq!(super::cosine(&[f32::NAN], &[1.0]), -1.0);
        assert_eq!(super::cosine(&[f32::INFINITY], &[1.0]), -1.0);
        assert!((super::cosine(&[1.0, 0.0], &[1.0, 0.0]) - 1.0).abs() < 0.001);
    }
}
