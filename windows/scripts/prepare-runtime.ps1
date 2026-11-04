$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-tools.ps1')
$runtimeDir = Join-Path $PSScriptRoot '../app/src-tauri/binaries/onnxruntime'
$dllPath = Join-Path $runtimeDir 'onnxruntime.dll'
$dllHash = '579b636403983254346a5c1d80bd28f1519cd1e284cd204f8d4ff41f8d711559'
if ((Test-Path $dllPath) -and ((Get-ArtifactHash $dllPath) -eq $dllHash) -and (Test-Path (Join-Path $runtimeDir 'onnxruntime_providers_shared.dll')) -and (Test-Path (Join-Path $runtimeDir 'ThirdPartyNotices.txt'))) { exit 0 }
$downloadDir = Join-Path $PSScriptRoot '../app/src-tauri/target/runtime-download'
New-Item -ItemType Directory -Force -Path $downloadDir, $runtimeDir | Out-Null
$archivePath = Join-Path $downloadDir 'onnxruntime-win-x64-1.22.0.zip'
if (-not (Test-Path $archivePath) -or (Get-ArtifactHash $archivePath) -ne '174c616efc0271194488642a72f1a514e01487da4dfe84c49296d66e40ebe0da') {
    & curl.exe --silent --show-error --fail --location --retry 3 --output $archivePath 'https://github.com/microsoft/onnxruntime/releases/download/v1.22.0/onnxruntime-win-x64-1.22.0.zip'
    if ($LASTEXITCODE -ne 0) { throw 'ONNX Runtime download failed' }
}
if ((Get-ArtifactHash $archivePath) -ne '174c616efc0271194488642a72f1a514e01487da4dfe84c49296d66e40ebe0da') { throw 'ONNX Runtime archive checksum mismatch' }
Expand-Artifact $archivePath $downloadDir
$extracted = Join-Path $downloadDir 'onnxruntime-win-x64-1.22.0'
Copy-Item -LiteralPath (Join-Path $extracted 'lib/onnxruntime.dll') -Destination $runtimeDir
Copy-Item -LiteralPath (Join-Path $extracted 'lib/onnxruntime_providers_shared.dll') -Destination $runtimeDir
Copy-Item -LiteralPath (Join-Path $extracted 'LICENSE') -Destination $runtimeDir
Copy-Item -LiteralPath (Join-Path $extracted 'ThirdPartyNotices.txt') -Destination $runtimeDir
if ((Get-ArtifactHash $dllPath) -ne $dllHash) { throw 'ONNX Runtime DLL checksum mismatch' }
