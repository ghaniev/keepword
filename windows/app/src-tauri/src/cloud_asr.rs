//! Same finished-track contract as the macOS TranscriptionEngine: local speaker processing stays separate.
use crate::{
    asr::Word,
    settings::{self, Settings},
};
use serde_json::Value;
use std::{
    io::Cursor,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
type Res<T> = Result<T, String>;

pub fn has_sound(samples: &[f32]) -> bool {
    samples
        .chunks(1600)
        .any(|c| c.iter().map(|s| s * s).sum::<f32>() / c.len().max(1) as f32 > 0.002f32.powi(2))
}
fn wav(samples: &[f32]) -> Res<Vec<u8>> {
    let mut bytes = Cursor::new(Vec::new());
    {
        let mut writer = hound::WavWriter::new(
            &mut bytes,
            hound::WavSpec {
                channels: 1,
                sample_rate: 16000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .map_err(|e| e.to_string())?;
        for s in samples {
            writer
                .write_sample((s.clamp(-1.0, 1.0) * 32767.0) as i16)
                .map_err(|e| e.to_string())?;
        }
        writer.finalize().map_err(|e| e.to_string())?;
    }
    Ok(bytes.into_inner())
}
pub fn cut(samples: &[f32], max: usize) -> usize {
    if samples.len() <= max {
        return samples.len();
    }
    ((max * 4 / 5)..max.saturating_sub(4800))
        .step_by(1600)
        .min_by(|&a, &b| {
            let energy = |i| samples[i..i + 4800].iter().map(|s| s * s).sum::<f32>();
            energy(a).total_cmp(&energy(b))
        })
        .map(|i| i + 2400)
        .unwrap_or(max)
}
fn spread(text: &str, start: f64, end: f64) -> Vec<Word> {
    let tokens: Vec<_> = text.split_whitespace().collect();
    let total = tokens
        .iter()
        .map(|s| s.chars().count() + 1)
        .sum::<usize>()
        .max(1) as f64;
    let mut at = start;
    tokens
        .into_iter()
        .map(|s| {
            let duration = (end - start) * (s.chars().count() + 1) as f64 / total;
            let w = Word {
                text: s.into(),
                start: at,
                end: at + duration * 0.9,
            };
            at += duration;
            w
        })
        .collect()
}
pub fn parse(value: &Value, samples: &[f32], offset: f64, deepgram: bool) -> Res<Vec<Word>> {
    let alternative = if deepgram {
        &value["results"]["channels"][0]["alternatives"][0]
    } else {
        value
    };
    let duration = samples.len() as f64 / 16000.0;
    let mut words = Vec::new();
    if let Some(rows) = alternative["words"].as_array() {
        for row in rows {
            let text = row["punctuated_word"]
                .as_str()
                .or(row["word"].as_str())
                .unwrap_or("");
            if let (Some(start), Some(end)) = (row["start"].as_f64(), row["end"].as_f64()) {
                if !text.trim().is_empty() && start.is_finite() && end.is_finite() && end >= start {
                    words.push(Word {
                        text: text.into(),
                        start: offset + start.clamp(0.0, duration),
                        end: offset + end.clamp(0.0, duration),
                    });
                }
            }
        }
    }
    let text = alternative[if deepgram { "transcript" } else { "text" }]
        .as_str()
        .unwrap_or("");
    if !words.is_empty() {
        let tokens: Vec<_> = text.split_whitespace().collect();
        let normalize = |s: &str| {
            s.chars()
                .filter(|c| c.is_alphanumeric())
                .flat_map(char::to_lowercase)
                .collect::<String>()
        };
        let mut next = 0;
        for w in &mut words {
            if let Some(i) = (next..(next + 4).min(tokens.len()))
                .find(|&i| normalize(tokens[i]) == normalize(&w.text))
            {
                w.text = tokens[i].into();
                next = i + 1;
            }
        }
    } else if let Some(segments) = alternative["segments"].as_array() {
        for s in segments {
            words.extend(spread(
                s["text"].as_str().unwrap_or(""),
                offset + s["start"].as_f64().unwrap_or(0.0).clamp(0.0, duration),
                offset + s["end"].as_f64().unwrap_or(duration).clamp(0.0, duration),
            ));
        }
    } else if !text.is_empty() {
        let loud = samples
            .chunks(1600)
            .enumerate()
            .filter(|(_, c)| has_sound(c))
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        if let (Some(first), Some(last)) = (loud.first(), loud.last()) {
            words = spread(
                text,
                offset + *first as f64 / 10.0,
                offset + ((*last + 1) as f64 / 10.0).min(duration),
            );
        }
    } else {
        return Err("Transcription provider returned no text or word timestamps".into());
    }
    words.sort_by(|a, b| a.start.total_cmp(&b.start));
    Ok(words)
}
pub fn recognize(
    config: &Settings,
    samples: &[f32],
    offset: f64,
    cancel: &AtomicBool,
) -> Res<Vec<Word>> {
    if cancel.load(Ordering::Relaxed) {
        return Err("Processing cancelled".into());
    }
    if !has_sound(samples) {
        return Ok(Vec::new());
    }
    let key = settings::secret(&settings::credential_id(
        "asr",
        &config.transcription_engine,
        &config.transcription_url,
    ))?;
    if config.transcription_engine != "custom" && key.is_empty() {
        return Err("Enter the transcription API key in Settings → Transcription".into());
    }
    let base = reqwest::Url::parse(&config.transcription_url).map_err(|e| e.to_string())?;
    if !["http", "https"].contains(&base.scheme()) {
        return Err("Use an HTTP(S) transcription URL".into());
    }
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|e| e.to_string())?;
    let data = wav(samples)?;
    let deepgram = config.transcription_engine == "deepgram";
    for attempt in 0..3 {
        if cancel.load(Ordering::Relaxed) {
            return Err("Processing cancelled".into());
        }
        let request = if deepgram {
            let mut url =
                reqwest::Url::parse(&format!("{}/listen", base.as_str().trim_end_matches('/')))
                    .map_err(|e| e.to_string())?;
            url.query_pairs_mut()
                .append_pair("model", &config.transcription_model)
                .append_pair("punctuate", "true")
                .append_pair("smart_format", "true");
            url.query_pairs_mut().append_pair(
                if config.transcription_language.is_empty() {
                    "detect_language"
                } else {
                    "language"
                },
                if config.transcription_language.is_empty() {
                    "true"
                } else {
                    &config.transcription_language
                },
            );
            client
                .post(url)
                .header("Authorization", format!("Token {key}"))
                .header("Content-Type", "audio/wav")
                .body(data.clone())
        } else {
            let timed = !config.transcription_model.to_lowercase().contains("gpt");
            let file = reqwest::blocking::multipart::Part::bytes(data.clone())
                .file_name("part.wav")
                .mime_str("audio/wav")
                .map_err(|e| e.to_string())?;
            let mut form = reqwest::blocking::multipart::Form::new()
                .text("model", config.transcription_model.clone())
                .text(
                    "response_format",
                    if timed { "verbose_json" } else { "json" },
                )
                .part("file", file);
            if timed {
                form = form.text("timestamp_granularities[]", "word");
            }
            if !config.transcription_language.is_empty() {
                form = form.text("language", config.transcription_language.clone());
            }
            let request = client
                .post(format!(
                    "{}/audio/transcriptions",
                    base.as_str().trim_end_matches('/')
                ))
                .multipart(form);
            if key.is_empty() {
                request
            } else {
                request.bearer_auth(&key)
            }
        };
        let response = request
            .send()
            .map_err(|e| format!("Transcription connection failed: {e}"))?;
        let status = response.status();
        if status.as_u16() == 413 && samples.len() > 16000 * 5 {
            let middle = cut(samples, samples.len() / 2);
            let mut words = recognize(config, &samples[..middle], offset, cancel)?;
            words.extend(recognize(
                config,
                &samples[middle..],
                offset + middle as f64 / 16000.0,
                cancel,
            )?);
            return Ok(words);
        }
        if attempt < 2 && (status.as_u16() == 429 || status.is_server_error()) {
            let seconds = response
                .headers()
                .get("retry-after")
                .and_then(|s| s.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or((attempt + 1) * 3)
                .min(30);
            for _ in 0..seconds * 10 {
                if cancel.load(Ordering::Relaxed) {
                    return Err("Processing cancelled".into());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            continue;
        }
        let value: Value = response
            .json()
            .map_err(|e| format!("Invalid transcription response ({status}): {e}"))?;
        if !status.is_success() {
            return Err(format!(
                "Transcription {status}: {}",
                value["error"]["message"]
                    .as_str()
                    .or(value["err_msg"].as_str())
                    .unwrap_or("Check the API key, model, URL and quota")
            ));
        }
        if cancel.load(Ordering::Relaxed) {
            return Err("Processing cancelled".into());
        }
        return parse(&value, samples, offset, deepgram);
    }
    Err("Transcription retries exhausted".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn sends_multipart_to_compatible_fixture() {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let mut config = Settings::default();
        config.transcription_engine = "custom".into();
        config.transcription_url = format!("http://{}/v1", server.server_addr());
        let worker = std::thread::spawn(move || {
            let mut request = server.recv().unwrap();
            assert_eq!(request.url(), "/v1/audio/transcriptions");
            let mut body = Vec::new();
            std::io::Read::read_to_end(request.as_reader(), &mut body).unwrap();
            assert!(String::from_utf8_lossy(&body).contains("timestamp_granularities[]"));
            request
                .respond(
                    tiny_http::Response::from_string(
                        r#"{"text":"Hello!","words":[{"word":"hello","start":0.0,"end":1.0}]}"#,
                    )
                    .with_header(
                        tiny_http::Header::from_bytes("Content-Type", "application/json").unwrap(),
                    ),
                )
                .unwrap();
        });
        let words = recognize(&config, &vec![0.1; 32000], 10.0, &AtomicBool::new(false)).unwrap();
        assert_eq!(words[0].text, "Hello!");
        assert_eq!(words[0].start, 10.0);
        worker.join().unwrap();
    }
    #[test]
    fn handles_provider_words_and_plain_text() {
        let samples = vec![0.1; 32000];
        let w=parse(&json!({"text":"Hello, world!","words":[{"word":"hello","start":0.0,"end":0.5},{"word":"world","start":0.5,"end":1.0}]}),&samples,30.0,false).unwrap();
        assert_eq!(w[0].text, "Hello,");
        assert_eq!(w[1].end, 31.0);
        let w=parse(&json!({"results":{"channels":[{"alternatives":[{"words":[{"word":"hello","punctuated_word":"Hello!","start":0.0,"end":1.0}]}]}]}}),&samples,0.0,true).unwrap();
        assert_eq!(w[0].text, "Hello!");
        let w = parse(&json!({"text":"Привет мир"}), &samples, 5.0, false).unwrap();
        assert_eq!(w.len(), 2);
        assert!(w[1].end <= 7.0);
        assert!(!has_sound(&vec![0.0; 16000]));
        let a = vec![0.1; 640000];
        let cut = cut(&a, 480000);
        assert!((384000..480000).contains(&cut));
    }
}
