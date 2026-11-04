#!/bin/sh
# Type-check the Windows app from macOS: cargo check --target x86_64-pc-windows-msvc.
# C dependencies can't be compiled for MSVC here, so SQLite is checked against a fake system lib.
set -e
cd "$(dirname "$0")/../app/src-tauri"
PATH="$(cd ../../scripts/stub-bin && pwd):$HOME/.cargo/bin:$PATH" SQLITE3_LIB_DIR=/nonexistent \
  cargo check --target x86_64-pc-windows-msvc --no-default-features "$@"
