// TDT decoding adapted from meetily, Copyright (c) 2024 Zackriya Solutions (MIT).
// Full license and model attribution: windows/THIRD_PARTY.md.
use ndarray::{Array1, Array2, Array3, Axis, Ix3, IxDyn};
use ort::{
    session::{builder::GraphOptimizationLevel, Session},
    value::TensorRef,
};
use rubato::Resampler;
use serde::{Deserialize, Serialize};
use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        OnceLock,
    },
};

type Res<T> = Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
static RUNTIME: OnceLock<Res<()>> = OnceLock::new();
pub fn init(path: &Path) -> Res<()> {
    RUNTIME
        .get_or_init(|| {
            std::panic::catch_unwind(|| {
                ort::init_from(path.to_string_lossy())
                    .with_telemetry(false)
                    .commit()
                    .map(|_| ())
                    .map_err(err)
            })
            .unwrap_or_else(|_| {
                Err("ONNX Runtime could not be loaded. Reinstall Keepword.".into())
            })
        })
        .clone()
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Word {
    pub text: String,
    pub start: f64,
    pub end: f64,
}
pub struct Parakeet {
    pre: Session,
    encoder: Session,
    decoder: Session,
    vocab: Vec<String>,
    blank: usize,
}
impl Parakeet {
    pub fn load(dir: &Path) -> Res<Self> {
        let session = |name: &str| -> Res<Session> {
            Session::builder()
                .map_err(err)?
                .with_optimization_level(GraphOptimizationLevel::Level3)
                .map_err(err)?
                .with_intra_threads(
                    std::thread::available_parallelism().map_or(2, |n| n.get().min(6)),
                )
                .map_err(err)?
                .commit_from_file(dir.join(name))
                .map_err(err)
        };
        let mut vocab = Vec::new();
        let mut blank = None;
        for line in std::fs::read_to_string(dir.join("vocab.txt"))
            .map_err(err)?
            .lines()
        {
            let (token, id) = line.rsplit_once(' ').ok_or("Invalid vocabulary line")?;
            let id: usize = id.parse().map_err(err)?;
            if id > 100000 {
                return Err("Invalid vocabulary id".into());
            }
            vocab.resize(vocab.len().max(id + 1), String::new());
            vocab[id] = token.to_string();
            if token == "<blk>" {
                blank = Some(id);
            }
        }
        Ok(Self {
            pre: session("nemo128.onnx")?,
            encoder: session("encoder-model.int8.onnx")?,
            decoder: session("decoder_joint-model.int8.onnx")?,
            vocab,
            blank: blank.ok_or("Vocabulary has no blank token")?,
        })
    }
    pub fn recognize(&mut self, audio: &[f32], offset: f64, cancel: &AtomicBool) -> Res<Vec<Word>> {
        let wave = Array2::from_shape_vec((1, audio.len()), audio.to_vec()).map_err(err)?;
        let lens = Array1::from_vec(vec![audio.len() as i64]);
        let features=self.pre.run(ort::inputs!["waveforms"=>TensorRef::from_array_view(wave.view()).map_err(err)?,"waveforms_lens"=>TensorRef::from_array_view(lens.view()).map_err(err)?]).map_err(err)?;
        let x = features["features"]
            .try_extract_array::<f32>()
            .map_err(err)?;
        let n = features["features_lens"]
            .try_extract_array::<i64>()
            .map_err(err)?;
        let encoded=self.encoder.run(ort::inputs!["audio_signal"=>TensorRef::from_array_view(x).map_err(err)?,"length"=>TensorRef::from_array_view(n).map_err(err)?]).map_err(err)?;
        let enc = encoded["outputs"]
            .try_extract_array::<f32>()
            .map_err(err)?
            .permuted_axes(IxDyn(&[0, 2, 1]))
            .to_owned();
        let length = *encoded["encoded_lengths"]
            .try_extract_array::<i64>()
            .map_err(err)?
            .iter()
            .next()
            .ok_or("Empty encoder output")? as usize;
        let enc = enc.into_dimensionality::<Ix3>().map_err(err)?;
        let mut state1 = Array3::<f32>::zeros((2, 1, 640));
        let mut state2 = state1.clone();
        let (mut frame, mut emitted, mut previous) = (0usize, 0usize, self.blank as i32);
        let mut pieces = Vec::new();
        while frame < length.min(enc.shape()[1]) {
            if cancel.load(Ordering::Relaxed) {
                return Err("Processing cancelled".into());
            }
            let encoder = enc
                .index_axis(Axis(0), 0)
                .index_axis(Axis(0), frame)
                .to_owned()
                .insert_axis(Axis(0))
                .insert_axis(Axis(2));
            let target = Array2::from_shape_vec((1, 1), vec![previous]).map_err(err)?;
            let target_length = Array1::from_vec(vec![1i32]);
            let result = self
                .decoder
                .run(ort::inputs![
                    "encoder_outputs"=>TensorRef::from_array_view(encoder.view()).map_err(err)?,
                    "targets"=>TensorRef::from_array_view(target.view()).map_err(err)?,
                    "target_length"=>TensorRef::from_array_view(target_length.view()).map_err(err)?,
                    "input_states_1"=>TensorRef::from_array_view(state1.view()).map_err(err)?,
                    "input_states_2"=>TensorRef::from_array_view(state2.view()).map_err(err)?
                ])
                .map_err(err)?;
            let logits = result["outputs"].try_extract_array::<f32>().map_err(err)?;
            let flat = logits.as_slice().ok_or("Non-contiguous decoder output")?;
            if flat.len() != self.vocab.len() + 5 {
                return Err(format!("Unexpected decoder shape: {}", flat.len()));
            }
            let token = argmax(&flat[..self.vocab.len()]);
            let mut skip = argmax(&flat[self.vocab.len()..]);
            if token != self.blank {
                pieces.push((self.vocab[token].clone(), frame, skip));
                previous = token as i32;
                state1 = result["output_states_1"]
                    .try_extract_array::<f32>()
                    .map_err(err)?
                    .to_owned()
                    .into_dimensionality()
                    .map_err(err)?;
                state2 = result["output_states_2"]
                    .try_extract_array::<f32>()
                    .map_err(err)?
                    .to_owned()
                    .into_dimensionality()
                    .map_err(err)?;
                emitted += 1;
            }
            if skip == 0 && (token == self.blank || emitted >= 3) {
                skip = 1;
            }
            if skip > 0 {
                frame += skip;
                emitted = 0;
            }
        }
        Ok(words(pieces, offset, audio.len() as f64 / 16000.0))
    }
}
fn argmax(x: &[f32]) -> usize {
    x.iter()
        .enumerate()
        .max_by(|a, b| a.1.total_cmp(b.1))
        .map_or(0, |(i, _)| i)
}
fn words(pieces: Vec<(String, usize, usize)>, offset: f64, length: f64) -> Vec<Word> {
    let mut out: Vec<Word> = Vec::new();
    for (token, frame, duration) in pieces {
        let starts = token.starts_with('▁');
        let token = token.replace('▁', " ");
        if token.trim().is_empty() {
            continue;
        }
        let start = offset + (frame as f64 * 0.08).min(length);
        let end = offset + ((frame + duration.max(1)) as f64 * 0.08).min(length);
        if starts || out.is_empty() {
            out.push(Word {
                text: token.trim().to_string(),
                start,
                end,
            });
        } else {
            let last = out.last_mut().unwrap();
            last.text.push_str(&token);
            last.end = end;
        }
    }
    out
}

/// Decode device-rate PCM WAV and resample with a bandlimited FFT filter.
pub fn audio(path: &Path) -> Res<Vec<f32>> {
    decode_reader(hound::WavReader::open(path).map_err(err)?)
}
pub fn tail(path: &Path, seconds: f64) -> Res<(Vec<f32>, f64)> {
    let mut reader = hound::WavReader::open(path).map_err(err)?;
    let rate = reader.spec().sample_rate;
    let start = reader
        .duration()
        .saturating_sub((seconds * rate as f64) as u32);
    reader.seek(start).map_err(err)?;
    Ok((decode_reader(reader)?, start as f64 / rate as f64))
}
fn decode_reader(mut reader: hound::WavReader<std::io::BufReader<std::fs::File>>) -> Res<Vec<f32>> {
    let spec = reader.spec();
    if spec.channels == 0 || spec.sample_rate == 0 {
        return Err("Invalid WAV format".into());
    }
    let mut mono = Vec::new();
    let mut frame = 0.0f32;
    let mut channel = 0;
    let samples: Box<dyn Iterator<Item = Result<f32, hound::Error>> + '_> =
        if spec.sample_format == hound::SampleFormat::Float {
            Box::new(reader.samples::<f32>())
        } else {
            let scale = 2f32.powi(spec.bits_per_sample as i32 - 1);
            Box::new(
                reader
                    .samples::<i32>()
                    .map(move |s| s.map(|s| s as f32 / scale)),
            )
        };
    for sample in samples {
        frame += sample.map_err(err)?;
        channel += 1;
        if channel == spec.channels {
            mono.push(frame / spec.channels as f32);
            frame = 0.0;
            channel = 0;
        }
    }
    if spec.sample_rate == 16000 {
        return Ok(mono);
    }
    let mut filter = rubato::FftFixedInOut::<f32>::new(spec.sample_rate as usize, 16000, 1024, 1)
        .map_err(err)?;
    let block = filter.input_frames_next();
    let delay = filter.output_delay();
    let expected = (mono.len() as f64 * 16000.0 / spec.sample_rate as f64).round() as usize;
    let mut out = Vec::new();
    for chunk in mono.chunks(block) {
        let mut input = vec![0.0; block];
        input[..chunk.len()].copy_from_slice(chunk);
        out.extend(filter.process(&[input], None).map_err(err)?.remove(0));
    }
    while out.len() < expected + delay {
        out.extend(
            filter
                .process(&[vec![0.0; block]], None)
                .map_err(err)?
                .remove(0),
        );
    }
    Ok(out.into_iter().skip(delay).take(expected).collect())
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore = "Requires downloaded ONNX models and target/test-speech.wav; run explicitly"]
    fn recognizes_english_fixture() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        super::init(&root.join("binaries/onnxruntime/onnxruntime.dll")).unwrap();
        let mut model =
            super::Parakeet::load(&root.join("target/test-models/parakeet-tdt-0.6b-v3")).unwrap();
        let audio = super::audio(&root.join("target/test-speech.wav")).unwrap();
        let start = std::time::Instant::now();
        let words = model
            .recognize(&audio, 0.0, &std::sync::atomic::AtomicBool::new(false))
            .unwrap();
        let text = words
            .iter()
            .map(|w| w.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        eprintln!(
            "ASR: {text}; audio {:.2}s; inference {:.2}s",
            audio.len() as f64 / 16000.0,
            start.elapsed().as_secs_f64()
        );
        assert!(text.to_lowercase().contains("windows"));
        assert!(text.to_lowercase().contains("meeting"));
        assert!(words.windows(2).all(|w| w[0].start <= w[1].start));
    }
    #[test]
    fn tokens_become_timed_words() {
        let out = super::words(
            vec![
                ("▁При".into(), 0, 1),
                ("вет".into(), 1, 1),
                ("▁мир".into(), 3, 2),
            ],
            10.0,
            1.0,
        );
        assert_eq!(out[0].text, "Привет");
        assert_eq!(out[1].text, "мир");
        assert_eq!(out[0].start, 10.0);
        assert!((out[1].end - 10.4).abs() < 0.001);
    }
    #[test]
    fn resamples_stereo_without_changing_duration() {
        let path = std::env::temp_dir().join(format!("resample-{}.wav", uuid::Uuid::new_v4()));
        let spec = hound::WavSpec {
            channels: 2,
            sample_rate: 48000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut w = hound::WavWriter::create(&path, spec).unwrap();
        for _ in 0..48000 {
            w.write_sample(1000i16).unwrap();
            w.write_sample(1000i16).unwrap();
        }
        w.finalize().unwrap();
        let a = super::audio(&path).unwrap();
        assert_eq!(a.len(), 16000);
        assert!((a[8000] - 1000.0 / 32768.0).abs() < 0.001);
        std::fs::remove_file(path).unwrap();
    }
}
