# Contributing to Keepword

Thanks for helping. Bug reports, fixes, translations and new features are all welcome.

## Layout

- `macos/` — the macOS app (Swift, SwiftUI). It is the reference: features land here first.
- `windows/` — the Windows app (Tauri 2, Rust, React). It follows the macOS app; [`windows/PLAN.md`](windows/PLAN.md) maps each macOS module to its Windows counterpart.

Both apps read the same SQLite library, so **a schema change needs both sides**: add the migration to `macos/Sources/MeetNotes/Core/Database/Store.swift` and to `windows/app/src-tauri/src/store.rs` in the same pull request. The Windows app refuses a library with migrations it does not know.

## macOS

Requirements: macOS 15+ on Apple Silicon, Xcode 26 (Swift 6.2).

```bash
cd macos
./build_app.sh && open Keepword.app
```

Before opening a pull request:

```bash
cd macos
swift build
DYLD_FALLBACK_LIBRARY_PATH=/usr/lib/swift .build/debug/Keepword --selftest
```

`--selftest` runs the logic and database checks in `Sources/MeetNotes/Dev/SelfTest.swift` against a temporary library. Add a check there for new logic that does not need the UI or a model download. [`macos/README.md`](macos/README.md) lists the other developer modes (`--summary-test`, `--mcp-test`, demo data).

## Windows

See [`windows/README.md`](windows/README.md): `windows\scripts\check.ps1` runs the frontend build, the JavaScript tests and the native tests.

## Pull requests

- One topic per pull request, with a short description of what changed and how you checked it.
- Match the style of the surrounding code; keep comments for the *why*.
- User-visible strings are English in code and translated in `macos/Resources/ru.lproj/Localizable.strings` (and the Windows UI strings). Add the Russian line if you can; otherwise say so in the pull request.
- Nothing may send recordings, transcripts or notes off the machine unless the user picked a cloud provider for that feature.
- CI builds and self-tests both apps on every pull request that touches them.

## Reporting bugs

Open an issue with the app version, OS version, what you did and what happened. Leave out meeting content and API keys. For security problems, see [SECURITY.md](SECURITY.md).
