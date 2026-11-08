$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-tools.ps1')
$runtimeDir = Join-Path $PSScriptRoot '../app/src-tauri/binaries/llama'
if (Test-Path (Join-Path $runtimeDir 'LICENSE')) { exit 0 }
$cache = Join-Path $PSScriptRoot '../app/src-tauri/target/llama-download'
New-Item -ItemType Directory -Force -Path $runtimeDir,$cache | Out-Null
$archive = Join-Path $cache 'llama.zip'
if (-not (Test-Path $archive)) {
    & curl.exe --silent --show-error --fail --location --retry 6 --retry-delay 15 --output $archive 'https://github.com/ggml-org/llama.cpp/releases/download/b11457/llama-b11457-bin-win-cpu-x64.zip'
    if ($LASTEXITCODE -ne 0) { throw 'llama.cpp download failed' }
}
if ((Get-ArtifactHash $archive) -ne 'ed20ed40e10c04d0853d8acf8700f0e6c1bb8212f0cc70c3a0da13dcbbc1b802') { throw 'llama.cpp checksum mismatch' }
Expand-Artifact $archive $runtimeDir
& curl.exe --silent --show-error --fail --location --retry 6 --retry-delay 15 --output (Join-Path $runtimeDir 'LICENSE') 'https://raw.githubusercontent.com/ggml-org/llama.cpp/b11457/LICENSE'
if ($LASTEXITCODE -ne 0) { throw 'llama.cpp license download failed' }
