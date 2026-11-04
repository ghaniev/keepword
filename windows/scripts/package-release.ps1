param([switch]$Signed)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-tools.ps1')
$appRoot = (Resolve-Path (Join-Path $PSScriptRoot '../app')).Path
$releaseConfig = @{ bundle = @{ createUpdaterArtifacts = $false } }
if ($Signed) {
    if (-not $env:MEETNOTES_CERT_THUMBPRINT) { throw 'MEETNOTES_CERT_THUMBPRINT is required for a signed release' }
    $releaseConfig.bundle.windows = @{ certificateThumbprint=$env:MEETNOTES_CERT_THUMBPRINT; digestAlgorithm='sha256' }
    if ($env:MEETNOTES_TIMESTAMP_URL) { $releaseConfig.bundle.windows.timestampUrl=$env:MEETNOTES_TIMESTAMP_URL; $releaseConfig.bundle.windows.tsp=$true }
}
if ($env:TAURI_SIGNING_PRIVATE_KEY) {
    if (-not $env:MEETNOTES_UPDATE_PUBLIC_KEY -or -not $env:MEETNOTES_UPDATE_ENDPOINT) { throw 'Updater public key and endpoint are required with TAURI_SIGNING_PRIVATE_KEY' }
    $releaseConfig.bundle.createUpdaterArtifacts=$true
}
$configPath = Join-Path $appRoot 'src-tauri/target/release-config.json'
New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null
$releaseConfig | ConvertTo-Json -Depth 6 | Set-Content $configPath -Encoding UTF8
Push-Location $appRoot
try {
    & npm.cmd run tauri -- build --config $configPath
    if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
    $installer = Get-ChildItem 'src-tauri/target/release/bundle/nsis/*-setup.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $installer) { throw 'Installer was not produced' }
    if ($Signed -and (Get-AuthenticodeSignature -LiteralPath $installer.FullName).Status -ne 'Valid') { throw 'Installer Authenticode signature is not valid' }
    $hash = Get-ArtifactHash $installer.FullName
    "$hash  $($installer.Name)" | Set-Content ($installer.FullName + '.sha256') -Encoding ASCII
    @{ file=$installer.Name; sha256=$hash; bytes=$installer.Length; signed=[bool]$Signed; updater=[bool]$releaseConfig.bundle.createUpdaterArtifacts; commit=(& git rev-parse HEAD); workingTreeDirty=[bool](& git status --porcelain); builtAt=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content ($installer.FullName + '.json') -Encoding UTF8
    $deliveryRoot = Join-Path $appRoot '../dist'
    New-Item -ItemType Directory -Force -Path $deliveryRoot | Out-Null
    foreach ($suffix in @('', '.sha256', '.json')) {
        Copy-Item -LiteralPath ($installer.FullName + $suffix) -Destination (Join-Path $deliveryRoot ($installer.Name + $suffix)) -Force
    }
    Write-Output ([IO.Path]::GetFullPath((Join-Path $deliveryRoot $installer.Name)))
} finally { Pop-Location }
