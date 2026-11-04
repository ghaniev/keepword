# Checks

`npm test` runs 4 checks: iCalendar recurrence/exclusions/moved instances/folded Unicode titles and hourly-calendar overlap/midnight layout.
`cargo test --locked` (in `src-tauri`) checks upgrades/recovery/data preservation, resampling, echo removal, capture bounds, cloud ASR multipart/parsing, scoped retrieval, summary/task preservation and incomplete-summary repair, credential partitioning, resumable model downloads, HTTP/stdio/SSE MCP and scheduling.

Ignored model checks need local fixtures and run explicitly with:
```powershell
cargo test --locked -- --ignored --nocapture --test-threads=1
```
The complete suite including these model checks is:
```powershell
cargo test --locked -- --include-ignored --nocapture --test-threads=1
```
All 39 checks passed on 2026-10-22 for version 0.1.1. Run native integration checks in the normal Windows account: restricted sandboxes deny Credential Manager and may block local HTTP test fixtures. The Qwen check validates both structured summary and exact-length cleanup output from the real model.

Speaker regressions cover 85 fragments from 10 synthetic voices consolidating to 10 identities, stable identity reuse, overlap exclusion, similarity chains, invalid vectors, compact numbering and unreliable fragments. A real-model fixture repeats one voice across later windows. Speaker-only repair verifies that text/original text/manual edits/timestamps are unchanged, named people survive, abandoned automatic profiles are removed and cancellation rolls back the operation. The reported real 8–10-person call is not present in the local library and has not been measured here.

Fixture locations under `src-tauri/target/`:
- `test-speech.wav`: mono English speech including “Windows” and “meeting”.
- `test-models/parakeet-tdt-0.6b-v3/`: the four pinned Parakeet files from PLAN.md.
- `test-models/diarization/`: `model.int8.onnx`, `embedding.onnx` (pyannote / NeMo TitaNet).
- `test-embedding/Models/minilm/`: `model.onnx`, `tokenizer.json`.
- `test-local-llm/Qwen3.5-4B-Q4_K_M.gguf`: the pinned optional local AI model.

Fixtures stay out of Git. Model tests do not record the microphone or send meeting content to a provider.

Installer lifecycle checks use `windows/scripts/smoke-installer.ps1` and a dedicated `target/installer-smoke/` library. The script refuses to run while Keepword is open or another installation exists.
