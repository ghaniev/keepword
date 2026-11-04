# Keepword for Windows: plan

Goal: the same app as `../macos` (Swift), built for Windows 10 2004+ / 11 x64.
The macOS app stays the reference: same features, prompts, DB schema and UI layout.

## Working rules
- Windows code lives in `windows/`, the macOS app in `macos/`; the Windows CI entry point is `.github/workflows/windows.yml`.
- Read the current macOS module before porting it (for example `macos/Sources/MeetNotes/Core/Processing/Pipeline.swift`).
- Code taken from [meetily](https://github.com/Zackriya-Solutions/meetily) (MIT) keeps its copyright header
  and is listed in `windows/THIRD_PARTY.md`.

## Stack
| Layer | Choice | Why |
|---|---|---|
| Shell | Tauri 2 | small installer, WebView2 ships with Windows 11; meetily proves the path |
| Backend | Rust | WASAPI, ONNX Runtime and SQLite all have mature crates |
| UI | React + TypeScript + Vite, plain CSS | closest way to rebuild the SwiftUI layout |
| DB | `rusqlite` (bundled, FTS5) | same schema as `Store.swift`, so a library file opens on both OSes |
| ASR | Parakeet TDT **v3** ONNX via `ort` | multilingual CPU implementation; DirectML remains a follow-up |
| Diarization | official `sherpa-onnx` bindings: pyannote segmentation + speaker embedding | meetily has none |
| Embeddings | `paraphrase-multilingual-MiniLM-L12-v2` ONNX via `ort` | same model family; Windows index has its own model id and is rebuilt |
| Audio | `cpal` WASAPI: mic input + output-device loopback | from meetily; per-process loopback later if needed |

## Mapping macOS → Windows
| macOS file | Windows module | Notes |
|---|---|---|
| `Store.swift` | `src-tauri/src/store.rs` | same tables and migrations; data in `%LOCALAPPDATA%\MeetNotes` |
| `Recorder.swift` | `recorder.rs` | mic and system as separate WAV tracks (needed for echo dedup) |
| `Pipeline.swift` | `pipeline.rs` | words → turns, echo dedup, speaker matching by cosine |
| FluidAudio (ASR) | `asr/parakeet.rs` | port of meetily `parakeet_engine/model.rs` |
| FluidAudio (diarization) | `diarize.rs` | voice embeddings differ from WeSpeaker on macOS: `embedding_model` column keeps them apart |
| `Core/Transcription/LiveTranscript.swift` | `live.rs` | sliding window per source, same as macOS |
| `LLM.swift`, `CLIProvider.swift`, `BuiltinTemplates.swift` | `llm.rs`, `store.rs` | HTTP providers; resolve Windows CLI executables without interpolating prompts into a shell |
| `LocalLLM.swift` | `local_llm.rs` | built-in llama.cpp / GGUF; CPU first, acceleration after measurement |
| `LocalEmbedder.swift` | `embed.rs` | ONNX MiniLM, ~30-word chunks, same as macOS |
| `Pipeline.swift` (search/chat), `ChatPane.swift`, `LiveQueries.swift` | `commands.rs`, `embed.rs`, `schedule.rs` | retrieval, persisted citations and scheduled queries; UI in React |
| `MCPServer.swift` | `mcp.rs` | `127.0.0.1` HTTP, token in Windows Credential Manager (`keyring`) |
| `MCPClient.swift`, `MCPOAuth.swift`, `MCPPresets.swift`, `TaskMapping.swift` | `mcp.rs`, `oauth.rs`, `presets.ts`, `TaskForm.tsx` | external stdio / HTTP servers, browser sign-in (OAuth), Jira / Linear / Notion / Asana / Miro presets, task forms and saved task links |
| `Core/Capture/ScreenCapture.swift` | `capture.rs`, `ScreenshotButton.tsx` | monitor capture and area selection; own windows excluded through Tauri content protection |
| Call detection (Core Audio) | `call_detect.rs` | apps holding the mic: `IAudioSessionManager2` capture sessions |
| EventKit (Calendar, Reminders) | `calendar.rs` | ICS URL first; Graph / Google and a replacement for Reminders need separate integrations |
| SwiftUI screens | `src/` (React) | Sidebar, Home, Document (Summary · Transcript · Chat), Chat, Calendar, Action Items, People, Tags, Settings, Overlay, Speaker wizard |

## Phases
Each phase ends with something that runs on Windows.

### Current status

All nine implementation phases are present in the Windows test release. Hardware/account acceptance and production publishing are separate gates, listed below; they are not claimed as passed.

Not yet ported from macOS: on-device Whisper (WhisperKit) and the speech model manager; Home's meeting brief and Needs Attention; plain-text action items; the in-person (microphone-only) start in the tray menu.

| Phase | Implemented | Remaining acceptance / gaps |
|---|---|---|
| 1. Shell and library | Tauri, tray, single instance, SQLite v1/v2/v3→v5 migrations/recovery; future-schema rejection; isolated libraries and credentials | A copy of the user's actual macOS library; CI execution on GitHub |
| 2. Recording | WASAPI mic + loopback, pause/mute/meters, resampling, common timeline, reconnect and WAV checkpoints; error reporting | Real calls, Bluetooth/USB switching, long recordings, power-loss behavior |
| 3. Transcription | Parakeet v3 CPU; OpenAI/Groq/Deepgram/custom ASR; verified resumable model downloads; retry/cancel; timestamps; FFmpeg/CAF import; silence cuts | Broad Russian/long-call quality and laptop resource measurements; authenticated cloud accounts |
| 4. AI | HTTP/Anthropic/CLI/local GGUF; scoped credentials; safe npm CLI resolution; hierarchical long-input reduction; schema-constrained local summary/cleanup; templates/tasks/tags/title with user-task preservation | Live hosted providers/CLI accounts; long real transcripts and model quality |
| 5. Speakers | Local diarization, stable solo-speech references, duplicate-fragment consolidation with overlap constraints, default/configurable maximum and exact counts; voice registry, rename/merge/assignment; guided identification; text-preserving speaker-only repair | Multi-speaker call quality and threshold calibration on the reported recording |
| 6. Search and chat | MiniLM + FTS, semantic related meetings, citations, @mentions, meeting/person/tag/folder/date/time filters; saved/scheduled scoped queries | Retrieval quality on the user's real library |
| 7. Live and calls | Live ASR with silence guard/system-first echo dedup; opt-in call prompt; overlay/bookmarks; monitor and area screenshots | Actual call detection/latency and hardware capture acceptance |
| 8. Organization/integrations | People/tags/tasks; folder hierarchy/context/template editing; autosaved notes/attachments/export/trash; hourly ICS calendar, overlap lanes and feed management; MCP HTTP/stdio/SSE/task links; RU/EN UI and built-in templates | Authenticated calendar feeds and real Jira / Linear / Notion / Asana accounts; OS-specific EventKit/Reminders remain separate integrations |
| 9. Shipping | Current x64 NSIS test installer, pinned runtimes and dependency notices; checks/package/smoke scripts; Windows CI workflow; optional signing/updater configuration | Authenticode certificate, updater keys/endpoint and publication; clean VM/Windows 10/offline WebView2 acceptance |

The current release includes the macOS-style interface and original icon from `macos/Resources/assets/meetnote_icn.webp`. It is an unsigned test build; model weights are downloaded separately.

Validation already performed:
- Production frontend build, 4 JavaScript tests and all 39 native tests pass in version 0.1.1, including real Parakeet, speaker, MiniLM and Qwen models, speaker over-splitting regressions and text-preserving repair. Native checks run outside the restricted sandbox to exercise Windows Credential Manager and loopback HTTP fixtures.
- Summary/cleanup use a strict JSON schema for local inference. A regression test verifies that an incomplete provider summary is retried before any database changes.
- An isolated release library processed a CAF speech file through transcription, diarization, AI cleanup, summary/action extraction, semantic indexing and Markdown export. Chat answered a question with a persisted citation.
- Home, document summary/transcript, Settings, hourly calendar, folder editing and chat filters were inspected in the running app; the original UI was also checked at 900 px width.
- The installer smoke test covers silent install, packaged runtime/license resources, app startup, reinstall, uninstall and preservation of isolated library data.

Production release requires the external signing/publishing inputs and the hardware/account checks above.

## Risks to check early
- Parakeet v3 speed on CPU-only laptops (live transcript is the tight case). Measure in phase 3 before building phase 7.
- Loopback captures the whole output device, so notification sounds land in the system track. Per-process loopback is optional and needs an OS-version check (Microsoft documents build 20348 minimum, above the baseline Windows 10 2004 target).
- From phase 3 on, work happens on the Windows PC. On the Mac only `cargo check --target x86_64-pc-windows-msvc` works (`windows/scripts/check.sh`).
- macOS `Pipeline.swift` looks for `mic.caf` / `system.caf`; Windows writes `mic.wav` / `system.wav`. To share a library with recordings, the macOS app must also accept `.wav`.
- The same embedding model name does not guarantee the same vectors: compare tokenizer ids, padding, 128-token truncation, pooling and normalization against macOS reference pairs before reusing its search index.
- CPU is the baseline for ASR; GPU acceleration is a measured follow-up, not a phase-3 requirement. Pinned artifacts and the v3 decoder have been exercised; broader recording quality and performance acceptance remain pending.

## Phase 3 implementation reference

Historical research below guided the implemented CPU port. Current acceptance and remaining work are listed above.

### Model: Parakeet TDT 0.6B v3, ONNX
- Repo `istupakov/parakeet-tdt-0.6b-v3-onnx`, pinned revision `8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce`.
  v3 is multilingual (25 European languages, Russian included). meetily ships v2, which is English only.
- URL: `https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/<revision>/<file>`.
- Use the int8 files, about 670 MB in total. SHA-256 values are the Hugging Face LFS ids:

| File | Bytes | SHA-256 |
|---|---|---|
| `encoder-model.int8.onnx` | 652183999 | `6139d2fa7e1b086097b277c7149725edbab89cc7c7ae64b23c741be4055aff09` |
| `decoder_joint-model.int8.onnx` | 18202004 | `eea7483ee3d1a30375daedc8ed83e3960c91b098812127a0d99d1c8977667a70` |
| `nemo128.onnx` (mel preprocessor) | 139764 | `a9fde1486ebfcc08f328d75ad4610c67835fea58c73ba57e3209a6f6cf019e9f` |
| `vocab.txt` | 93939 | not in LFS; pinned by the revision |

- Full precision (`encoder-model.onnx` + 2.4 GB `.data`) isn't needed.
- v3 uses this file layout. The Windows decoder has been verified with the downloaded v3 model and an English speech fixture.

### ONNX Runtime 1.22.0 (matches `ort = "2.0.0-rc.10"`)
The preparation script verifies the pinned archive and runtime hashes before packaging.

| File | Bytes | SHA-256 |
|---|---|---|
| `onnxruntime-win-x64-1.22.0.zip` ([release](https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-win-x64-1.22.0.zip)) | 72368545 | `174c616efc0271194488642a72f1a514e01487da4dfe84c49296d66e40ebe0da` |
| `lib/onnxruntime.dll` | 12418080 | `579b636403983254346a5c1d80bd28f1519cd1e284cd204f8d4ff41f8d711559` |
| `lib/onnxruntime_providers_shared.dll` | 22064 | `ba00ea1ef846c9b909c7854bc56c51051a20f9773b3e1153dda118d4b85d0b93` |
| `LICENSE` | 1094 | `c250d6278f0b47a6439fb7592b08b58a55eb9f535aa49a1db63211c3f982b674` |

This is the CPU build. DirectML needs a different build of the runtime (NuGet `Microsoft.ML.OnnxRuntime.DirectML`), so do it after the CPU speed is measured.

### How meetily does it (`frontend/src-tauri/` in their repo, MIT)
- **Cargo:** `ort = "2.0.0-rc.10"` with default features, plus `features = ["load-dynamic"]` on Windows only.
  Windows can have an older `onnxruntime.dll` in System32, so the DLL is loaded by explicit path. `ndarray = "0.16"`.
- **Bundling:** `build/onnxruntime.rs`, called from `build.rs` for the Windows target only, downloads the zip, checks size and SHA-256,
  and extracts both DLLs and the LICENSE into `src-tauri/binaries/onnxruntime/`.
  `tauri.windows.conf.json` adds `"bundle": {"resources": {"binaries/onnxruntime": "."}}`.
- **Startup:** `ort::init_from(<resource dir>/onnxruntime.dll).with_telemetry(false).commit()`, wrapped in `catch_unwind`.
  A failure is stored and reported on first use instead of crashing.
- **`parakeet_engine/model.rs`:** three sessions, CPU execution provider, `GraphOptimizationLevel::Level3`.
  - `nemo128`: `waveforms` [1, N] f32 16 kHz + `waveforms_lens` [1] i64 → `features`, `features_lens`.
  - `encoder-model`: `audio_signal` + `length` → `outputs` [1, 1024, T], permuted to [1, T, 1024], + `encoded_lengths`.
  - `decoder_joint-model`: `encoder_outputs` [1, 1024, 1], `targets` [1, 1] i32 (last token, or blank), `target_length` [1],
    `input_states_1` / `input_states_2` [2, 1, 640] → `outputs` (vocab logits followed by 5 duration logits),
    `output_states_1` / `output_states_2`.
- **Greedy TDT decoding:**
  - Take the argmax of the vocab logits and the argmax of the duration logits; the duration picks a skip of [0, 1, 2, 3, 4] frames.
  - The decoder state updates only when a token is emitted.
  - A skip of 0 is forced to 1 on blank, or after 3 tokens on the same frame.
- **Token time** = frame × 0.08 s (10 ms hop × subsampling 8).
  `vocab.txt` lines are `token id`; `▁` marks a word start; `<blk>` is the blank.

### Our port, step by step
1. **`asr/parakeet.rs`** from meetily `model.rs`, keeping their MIT header and listing it in `THIRD_PARTY.md`.
   Also keep each token's duration, so a word's end = last token frame + duration.
2. **ONNX Runtime bundling** as meetily does it: `build.rs`, resources, `init_from` at startup.
3. **Model download** into `%LOCALAPPDATA%\MeetNotes\Models\parakeet-tdt-0.6b-v3`.
   Download to `.part`, check SHA-256, then rename. Use `reqwest` blocking with native-tls (schannel), so there is no C build.
4. **Audio prep:** resample each WAV (device rate) to 16 kHz mono with `rubato`.
   Split into chunks of at most 30 s at the quietest 50 ms between 20 and 30 s, skip silent chunks, and offset times by the chunk start.
5. **Words → turns and echo dedup:** port `Pipeline.swift` `utterances`, `dropEchoes` and `tokens` 1:1, with unit tests.
   Until phase 5, mic words get speaker `me` and source `mic`; system words get no speaker (NULL) and source `system`.
6. **Worker thread** for `queued` and `recovered` meetings, also picked up on startup.
   Status goes `processing:transcribing` → `done`; delete and re-insert the segments, as `Pipeline.swift` does.
   Emit an event so the UI refreshes.
7. **Transcript view:** click a card to open the document; the Transcript tab shows `[mm:ss] Me / Speaker: text`.
8. **Measure** the real-time factor on a typical laptop and write it here.

Recognition logic can also be debugged on the Mac: `ort` downloads macOS binaries by itself.
For test audio, use `say -o test.aiff "..."`, then `afconvert -f WAVE -d LEI16@16000 test.aiff test.wav`.
