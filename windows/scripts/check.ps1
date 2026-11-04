# Native Windows checks. Run with -Installer to also package the NSIS setup executable.
param([switch]$Installer,[switch]$Models)
$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '../app')
try {
    if (-not (Test-Path 'node_modules/.bin/tauri.cmd')) {
        & npm.cmd ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed' }
    }
    & npm.cmd run build
    if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed' }
    & npm.cmd test
    if ($LASTEXITCODE -ne 0) { throw 'Calendar tests failed' }
    Push-Location 'src-tauri'
    try {
        & cargo test --locked
        if ($LASTEXITCODE -ne 0) { throw 'Rust tests failed' }
        if ($Models) {
            & cargo test --locked -- --ignored --nocapture --test-threads=1
            if ($LASTEXITCODE -ne 0) { throw 'Model integration tests failed' }
        }
    } finally {
        Pop-Location
    }
    if ($Installer) {
        & npm.cmd run tauri -- build
        if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
    }
} finally {
    Pop-Location
}
