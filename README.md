# MeetNotes

Meeting notes that stay on your computer. MeetNotes records calls without a bot (microphone and system audio as separate tracks), transcribes them and identifies speakers on-device, writes summaries with action items, and lets you search and chat across all your meetings. Cloud transcription and AI providers are optional.

| App | Folder | Stack |
|---|---|---|
| macOS 15+, Apple Silicon | [`macos/`](macos) | Swift, SwiftUI, FluidAudio (Parakeet), WhisperKit, llama.cpp, GRDB |
| Windows 10 2004+ / 11, x64 | [`windows/`](windows) | Tauri 2, Rust, React, ONNX Runtime (Parakeet), sherpa-onnx, llama.cpp |

Both apps use the same SQLite schema, prompts and templates. The macOS app is the reference; the Windows app is a port (see [`windows/PLAN.md`](windows/PLAN.md) for what is ported and what is still pending).

Build instructions: [`macos/README.md`](macos/README.md) and [`windows/README.md`](windows/README.md).

## License

MIT, see [LICENSE](LICENSE). Third-party components: [`macos/THIRD_PARTY.md`](macos/THIRD_PARTY.md) and [`windows/THIRD_PARTY.md`](windows/THIRD_PARTY.md). Speech, speaker and language models are downloaded on request and are covered by their own licenses.
