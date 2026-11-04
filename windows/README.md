# MeetNotes for Windows

Windows version of MeetNotes; the macOS app is in [`../macos`](../macos). Plan and status: [PLAN.md](PLAN.md).

## Build on Windows
One-time setup (Windows 10 2004+ / 11, x64):
1. Visual Studio Build Tools with "Desktop development with C++".
2. Rust: https://rustup.rs (default MSVC toolchain).
3. Node.js 20+.
4. WebView2 Runtime (already part of Windows 11).

Run in development:
```powershell
cd windows\app
npm ci
npm run tauri dev
```
Build the installer with its SHA-256 and build manifest (`src-tauri\target\release\bundle\nsis\*`):
```powershell
cd ..\..
.\windows\scripts\package-release.ps1
```
Data lives in `%LOCALAPPDATA%\MeetNotes\` (`meetnotes.sqlite`, `recordings\<id>\mic.wav`, `system.wav`).

Native checks from the repository root:
```powershell
.\windows\scripts\check.ps1
.\windows\scripts\check.ps1 -Models
.\windows\scripts\smoke-installer.ps1
```

For an isolated library, launch `meetnotes.exe --library-path C:\path\to\test-library`.
Closing the main window leaves the app in the tray; choose **Quit** there to exit and finalize recordings.
WAV headers are checkpointed every recorded second for recovery after a process crash. This does not guarantee recovery after power loss.

Current scope: recording, local/cloud transcription, speaker identification, AI notes, filtered hybrid search/chat, organization, hourly ICS calendar, MCP integrations, monitor/area capture and a macOS-style interface using the original app icon. See [PLAN.md](PLAN.md) for per-phase implementation and acceptance gates.

## Test releases

`package-release.ps1` writes the x64 installer with adjacent `.sha256` and `.json` files to `dist/`. The original build output is `app/src-tauri/target/release/bundle/nsis/`; the release executable is `app/src-tauri/target/release/meetnotes.exe`. The build manifest marks an uncommitted working tree explicitly.

Version 0.1.1 fixes excessive speaker splitting. Voice references come from longer solo speech, similar fragments are consolidated with overlap constraints, and unreliable fragments do not create people. Automatic mode has a default maximum of 20 (configurable up to 100). Under **Transcript**, leave the exact count on **Auto**, set **Maximum speakers** (for example 10), then use **Reidentify speakers** to repair an existing meeting without replacing its text. An exact count overrides the maximum. Unused automatic profiles from the repaired meeting are removed only if they have no other references, custom name or contact data. Named/merged people are preserved.

This installer is unsigned. Production Authenticode signing needs `MEETNOTES_CERT_THUMBPRINT` (and optionally `MEETNOTES_TIMESTAMP_URL`), then `package-release.ps1 -Signed`. Updater publication additionally needs `TAURI_SIGNING_PRIVATE_KEY`, `MEETNOTES_UPDATE_PUBLIC_KEY` and `MEETNOTES_UPDATE_ENDPOINT`. No update server or credentials are shipped in the test release.

Parakeet, diarization, MiniLM and optional Qwen weights are separate downloads under **Settings → Models**. The runtime binaries are included. A machine without WebView2 needs network access for the installer bootstrapper or a separately installed WebView2 runtime. After models are present, local processing does not require a hosted AI account; choose **Local GGUF** or a configured local compatible server for summaries/chat.

ASR has its own **Transcription** settings: local Parakeet, OpenAI, Groq, Deepgram or a compatible endpoint. API credentials are separated by feature/provider/endpoint in Windows Credential Manager. An isolated `--library-path` uses a separate credential namespace.

Signing, update publication and live hardware/account acceptance are still pending; see [PLAN.md](PLAN.md).

## On the Mac
- `scripts/check.sh` type-checks the Windows build (`cargo check --target x86_64-pc-windows-msvc`).
- `cd app/src-tauri && cargo test` runs the logic tests natively.
