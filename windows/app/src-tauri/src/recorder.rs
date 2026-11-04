//! WASAPI input and device loopback, with a shared pause-aware clock and persistent 16 kHz tracks.
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rubato::Resampler;
use serde::{Deserialize, Serialize};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering::Relaxed},
        mpsc, Arc, Mutex,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};
type Res<T> = Result<T, String>;
const RATE: u32 = 16000;
#[derive(Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Both,
    MicOnly,
    SystemOnly,
}
#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    Level { rms: f32, mic: bool },
    MicBlocked,
    Error { message: String },
    Notice { message: String },
}
pub type Sink = Arc<dyn Fn(Event) + Send + Sync>;
#[derive(Default)]
pub struct Flags {
    pub paused: AtomicBool,
    pub mic_muted: AtomicBool,
    error: Mutex<Option<String>>,
    clock: Mutex<Clock>,
}
struct Clock {
    started: Instant,
    paused_at: Option<Instant>,
    paused_total: Duration,
}
impl Default for Clock {
    fn default() -> Self {
        Self {
            started: Instant::now(),
            paused_at: None,
            paused_total: Duration::ZERO,
        }
    }
}
impl Flags {
    pub fn set_paused(&self, paused: bool) {
        let mut c = self.clock.lock().unwrap();
        let previous = self.paused.swap(paused, Relaxed);
        if paused && !previous {
            c.paused_at = Some(Instant::now())
        } else if !paused && previous {
            if let Some(start) = c.paused_at.take() {
                c.paused_total += start.elapsed()
            }
        }
    }
    pub fn elapsed(&self) -> f64 {
        let c = self.clock.lock().unwrap();
        c.paused_at
            .unwrap_or_else(Instant::now)
            .duration_since(c.started)
            .saturating_sub(c.paused_total)
            .as_secs_f64()
    }
    fn fail(&self, message: String, sink: &Sink) {
        let mut e = self.error.lock().unwrap();
        if e.is_none() {
            *e = Some(message.clone());
            drop(e);
            sink(Event::Error { message })
        }
    }
}
type Wav = hound::WavWriter<std::io::BufWriter<std::fs::File>>;
struct Track {
    writer: Option<Wav>,
    filter: Option<rubato::FftFixedInOut<f32>>,
    pending: Vec<f32>,
    rate: u32,
    delay: usize,
    input_count: usize,
    output_count: usize,
    checkpoint: u32,
}
impl Track {
    fn new(path: &Path) -> Res<Self> {
        let writer = hound::WavWriter::create(
            path,
            hound::WavSpec {
                channels: 1,
                sample_rate: RATE,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .map_err(|e| e.to_string())?;
        Ok(Self {
            writer: Some(writer),
            filter: None,
            pending: Vec::new(),
            rate: RATE,
            delay: 0,
            input_count: 0,
            output_count: 0,
            checkpoint: 0,
        })
    }
    fn prepare(&mut self, rate: u32) -> Res<()> {
        self.flush_pending()?;
        self.rate = rate;
        self.filter = if rate == RATE {
            None
        } else {
            Some(
                rubato::FftFixedInOut::new(rate as usize, RATE as usize, 1024, 1)
                    .map_err(|e| e.to_string())?,
            )
        };
        self.delay = self.filter.as_ref().map_or(0, Resampler::output_delay);
        self.input_count = 0;
        self.output_count = 0;
        self.pending.clear();
        Ok(())
    }
    fn write(&mut self, samples: &[f32]) -> Res<()> {
        let Some(w) = self.writer.as_mut() else {
            return Err("Track is closed".into());
        };
        for &s in samples {
            w.write_sample((s.clamp(-1.0, 1.0) * 32767.0) as i16)
                .map_err(|e| e.to_string())?;
        }
        self.checkpoint += samples.len() as u32;
        if self.checkpoint >= RATE {
            w.flush().map_err(|e| e.to_string())?;
            self.checkpoint = 0;
        }
        Ok(())
    }
    fn output(&mut self, samples: Vec<f32>) -> Res<()> {
        let skip = self.delay.min(samples.len());
        self.delay -= skip;
        let wanted = (self.input_count as f64 * RATE as f64 / self.rate as f64).round() as usize;
        let n = (samples.len() - skip).min(wanted.saturating_sub(self.output_count));
        self.write(&samples[skip..skip + n])?;
        self.output_count += n;
        Ok(())
    }
    fn push(&mut self, samples: Vec<f32>) -> Res<()> {
        self.input_count += samples.len();
        if self.filter.is_none() {
            self.output_count += samples.len();
            return self.write(&samples);
        }
        self.pending.extend(samples);
        let block = self.filter.as_ref().unwrap().input_frames_next();
        while self.pending.len() >= block {
            let input = self.pending.drain(..block).collect::<Vec<_>>();
            let out = self
                .filter
                .as_mut()
                .unwrap()
                .process(&[input], None)
                .map_err(|e| e.to_string())?
                .remove(0);
            self.output(out)?;
        }
        Ok(())
    }
    fn flush_pending(&mut self) -> Res<()> {
        if self.filter.is_none() {
            return Ok(());
        }
        let wanted = (self.input_count as f64 * RATE as f64 / self.rate as f64).round() as usize;
        while self.output_count < wanted {
            let block = self.filter.as_ref().unwrap().input_frames_next();
            let mut input = vec![0.0; block];
            let n = self.pending.len().min(block);
            input[..n].copy_from_slice(&self.pending[..n]);
            self.pending.drain(..n);
            let out = self
                .filter
                .as_mut()
                .unwrap()
                .process(&[input], None)
                .map_err(|e| e.to_string())?
                .remove(0);
            self.output(out)?;
        }
        Ok(())
    }
    fn frames(&self) -> u32 {
        self.writer.as_ref().map_or(0, Wav::duration)
    }
    fn pad_to(&mut self, seconds: f64) -> Res<()> {
        let target = (seconds.max(0.0) * RATE as f64).round() as u32;
        let mut missing = target.saturating_sub(self.frames());
        let zeros = [0.0f32; 16000];
        while missing > 0 {
            let n = missing.min(RATE);
            self.write(&zeros[..n as usize])?;
            missing -= n;
        }
        Ok(())
    }
    fn finish(&mut self, seconds: f64) -> Res<f64> {
        self.flush_pending()?;
        self.pad_to(seconds)?;
        let w = self.writer.take().ok_or("Track is already closed")?;
        let duration = w.duration() as f64 / RATE as f64;
        w.finalize().map_err(|e| e.to_string())?;
        Ok(duration)
    }
}
struct Source {
    mic: bool,
    track: Arc<Mutex<Track>>,
    streams: Vec<cpal::Stream>,
    device: Option<String>,
    retry: Arc<AtomicBool>,
    missing_reported: bool,
}
impl Source {
    fn new(dir: &Path, mic: bool) -> Res<Self> {
        Ok(Self {
            mic,
            track: Arc::new(Mutex::new(Track::new(&dir.join(if mic {
                "mic.wav"
            } else {
                "system.wav"
            }))?)),
            streams: Vec::new(),
            device: None,
            retry: Arc::new(AtomicBool::new(false)),
            missing_reported: false,
        })
    }
    fn connect(&mut self, device: cpal::Device, flags: &Arc<Flags>, sink: &Sink) -> Res<()> {
        self.streams.clear();
        let config = if self.mic {
            device.default_input_config()
        } else {
            device.default_output_config()
        }
        .map_err(|e| e.to_string())?;
        let rate = config.sample_rate().0;
        let channels = config.channels() as usize;
        if rate == 0 || channels == 0 {
            return Err("Invalid audio format".into());
        }
        self.track.lock().unwrap().prepare(rate)?;
        let (track, flags, sink, retry) = (
            self.track.clone(),
            flags.clone(),
            sink.clone(),
            self.retry.clone(),
        );
        let mic = self.mic;
        let (mut sum, mut count, mut zero, mut first) = (0f32, 0u32, 0u32, true);
        let mut handle = move |data: &[f32]| {
            if flags.paused.load(Relaxed) || flags.error.lock().unwrap().is_some() {
                return;
            }
            let muted = mic && flags.mic_muted.load(Relaxed);
            let samples: Vec<f32> = data
                .chunks_exact(channels)
                .map(|frame| {
                    if muted {
                        0.0
                    } else {
                        frame.iter().sum::<f32>() / channels as f32
                    }
                })
                .collect();
            let silent = samples.iter().all(|s| *s == 0.0);
            for &s in &samples {
                sum += s * s;
                count += 1;
            }
            let mut writer = track.lock().unwrap();
            let start = (flags.elapsed() - samples.len() as f64 / rate as f64).max(0.0);
            if first || start - writer.frames() as f64 / RATE as f64 > 0.2 {
                first = false;
                if let Err(e) = writer.flush_pending().and_then(|_| writer.pad_to(start)) {
                    flags.fail(e, &sink);
                    return;
                }
            }
            if let Err(e) = writer.push(samples.clone()) {
                flags.fail(format!("Audio write failed: {e}"), &sink);
                return;
            }
            drop(writer);
            if count >= rate / 10 {
                sink(Event::Level {
                    rms: ((sum / count as f32).sqrt() * 4.0).min(1.0),
                    mic,
                });
                sum = 0.0;
                count = 0;
            }
            if mic && !muted {
                let n = samples.len() as u32;
                zero = if silent { zero.saturating_add(n) } else { 0 };
                if zero >= rate * 4 && zero - n < rate * 4 {
                    sink(Event::MicBlocked)
                }
            }
        };
        let on_error = move |_: cpal::StreamError| retry.store(true, Relaxed);
        let stream_config: cpal::StreamConfig = config.clone().into();
        let capture = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                &stream_config,
                move |d: &[f32], _: &_| handle(d),
                on_error,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                &stream_config,
                move |d: &[i16], _: &_| {
                    handle(&d.iter().map(|s| *s as f32 / 32768.0).collect::<Vec<_>>())
                },
                on_error,
                None,
            ),
            cpal::SampleFormat::I32 => device.build_input_stream(
                &stream_config,
                move |d: &[i32], _: &_| {
                    handle(
                        &d.iter()
                            .map(|s| *s as f32 / 2147483648.0)
                            .collect::<Vec<_>>(),
                    )
                },
                on_error,
                None,
            ),
            cpal::SampleFormat::U16 => device.build_input_stream(
                &stream_config,
                move |d: &[u16], _: &_| {
                    handle(
                        &d.iter()
                            .map(|s| (*s as f32 - 32768.0) / 32768.0)
                            .collect::<Vec<_>>(),
                    )
                },
                on_error,
                None,
            ),
            format => return Err(format!("Unsupported audio format: {format}")),
        }
        .map_err(|e| e.to_string())?;
        capture.play().map_err(|e| e.to_string())?;
        self.streams.push(capture);
        self.device = device.name().ok();
        self.retry.store(false, Relaxed);
        self.missing_reported = false;
        Ok(())
    }
}
pub fn input_devices() -> Vec<String> {
    cpal::default_host()
        .input_devices()
        .map(|d| d.filter_map(|d| d.name().ok()).collect())
        .unwrap_or_default()
}
fn device(host: &cpal::Host, mic: bool, preferred: &Option<String>) -> Option<cpal::Device> {
    if mic {
        preferred
            .as_ref()
            .and_then(|name| {
                host.input_devices()
                    .ok()?
                    .find(|d| d.name().ok().as_ref() == Some(name))
            })
            .or_else(|| host.default_input_device())
    } else {
        host.default_output_device()
    }
}
pub struct Recorder {
    pub flags: Arc<Flags>,
    stop: mpsc::Sender<()>,
    thread: JoinHandle<Res<f64>>,
}
impl Recorder {
    pub fn start(
        dir: &Path,
        mode: Mode,
        mic: Option<String>,
        sink: Sink,
    ) -> Res<(Self, Option<String>)> {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let flags = Arc::new(Flags::default());
        let f = flags.clone();
        let dir: PathBuf = dir.into();
        let (stop, stop_rx) = mpsc::channel();
        let (ready, ready_rx) = mpsc::channel();
        let thread = std::thread::spawn(move || {
            let host = cpal::default_host();
            let mut sources = Vec::new();
            let mut warning = None;
            for is_mic in [true, false] {
                if (is_mic && mode == Mode::SystemOnly) || (!is_mic && mode == Mode::MicOnly) {
                    continue;
                }
                let mut source = match Source::new(&dir, is_mic) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = ready.send(Err(e));
                        return Ok(0.0);
                    }
                };
                let opened = device(&host, is_mic, &mic)
                    .ok_or_else(|| "No audio device found".to_string())
                    .and_then(|d| source.connect(d, &f, &sink));
                if let Err(e) = opened {
                    if !is_mic && mode == Mode::Both {
                        warning = Some(format!(
                            "System audio unavailable; waiting for the output device: {e}"
                        ));
                    } else {
                        let _ = ready.send(Err(e));
                        return Ok(0.0);
                    }
                }
                sources.push(source);
            }
            let _ = ready.send(Ok(warning));
            loop {
                match stop_rx.recv_timeout(Duration::from_millis(750)) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                }
                for source in &mut sources {
                    let desired = device(&host, source.mic, &mic);
                    let name = desired.as_ref().and_then(|d| d.name().ok());
                    if !source.streams.is_empty()
                        && !source.retry.load(Relaxed)
                        && name == source.device
                    {
                        continue;
                    }
                    source.streams.clear();
                    if let Err(e) = source.track.lock().unwrap().flush_pending() {
                        f.fail(e.clone(), &sink);
                        return Err(e);
                    }
                    let result = desired
                        .ok_or_else(|| "Device disconnected".to_string())
                        .and_then(|d| source.connect(d, &f, &sink));
                    match result {
                        Ok(()) => sink(Event::Notice {
                            message: format!(
                                "{} reconnected: {}",
                                if source.mic {
                                    "Microphone"
                                } else {
                                    "System audio"
                                },
                                source.device.as_deref().unwrap_or("default")
                            ),
                        }),
                        Err(e) => {
                            if !source.missing_reported {
                                sink(Event::Notice {
                                    message: format!(
                                        "{} unavailable; retrying: {e}",
                                        if source.mic {
                                            "Microphone"
                                        } else {
                                            "System audio"
                                        }
                                    ),
                                });
                                source.missing_reported = true;
                            }
                        }
                    }
                }
            }
            for source in &mut sources {
                source.streams.clear();
            }
            let end = sources
                .iter()
                .map(|s| s.track.lock().unwrap().frames() as f64 / RATE as f64)
                .fold(f.elapsed(), f64::max);
            let mut error = f.error.lock().unwrap().clone();
            let mut duration = 0.0f64;
            for source in sources {
                match source.track.lock().unwrap().finish(end) {
                    Ok(t) => duration = duration.max(t),
                    Err(e) => {
                        error.get_or_insert(e);
                    }
                }
            }
            error.map_or(Ok(duration), Err)
        });
        match ready_rx.recv_timeout(Duration::from_secs(8)) {
            Ok(Ok(warning)) => Ok((
                Self {
                    flags,
                    stop,
                    thread,
                },
                warning,
            )),
            Ok(Err(e)) => {
                let _ = thread.join();
                Err(e)
            }
            Err(_) => {
                let _ = stop.send(());
                Err("Audio device did not respond within 8 seconds. Check microphone permissions and the selected device.".into())
            }
        }
    }
    pub fn stop(self) -> Res<f64> {
        let _ = self.stop.send(());
        self.thread
            .join()
            .map_err(|_| "Recorder thread crashed".to_string())?
    }
}
#[cfg(test)]
mod tests {
    #[test]
    fn reports_first_recording_error_once() {
        let f = super::Flags::default();
        let events = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let r = events.clone();
        let sink: super::Sink = std::sync::Arc::new(move |e| r.lock().unwrap().push(e));
        f.fail("disk full".into(), &sink);
        f.fail("device lost".into(), &sink);
        assert_eq!(events.lock().unwrap().len(), 1);
    }
    #[test]
    fn reconnect_resamples_and_preserves_previous_audio() {
        let path = std::env::temp_dir().join(format!("track-{}.wav", uuid::Uuid::new_v4()));
        let mut t = super::Track::new(&path).unwrap();
        t.prepare(48000).unwrap();
        t.push(vec![0.25; 48000]).unwrap();
        t.flush_pending().unwrap();
        assert_eq!(t.frames(), 16000);
        t.pad_to(2.0).unwrap();
        t.prepare(8000).unwrap();
        t.push(vec![0.5; 8000]).unwrap();
        t.finish(3.0).unwrap();
        let mut r = hound::WavReader::open(&path).unwrap();
        assert_eq!(r.duration(), 48000);
        let samples: Vec<_> = r.samples::<i16>().map(Result::unwrap).collect();
        assert!((samples[8000] as f32 / 32768.0 - 0.25).abs() < 0.01);
        assert_eq!(samples[24000], 0);
        assert!((samples[40000] as f32 / 32768.0 - 0.5).abs() < 0.01);
        drop(r);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn checkpoint_is_readable_before_finalization() {
        let path = std::env::temp_dir().join(format!("checkpoint-{}.wav", uuid::Uuid::new_v4()));
        let mut t = super::Track::new(&path).unwrap();
        t.push(vec![0.2; 16000]).unwrap();
        let r = hound::WavReader::open(&path).unwrap();
        assert_eq!(r.duration(), 16000);
        drop(r);
        t.finish(1.0).unwrap();
        drop(t);
        std::fs::remove_file(path).unwrap();
    }
}
