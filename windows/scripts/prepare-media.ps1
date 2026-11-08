$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-tools.ps1')
$mediaRoot = Join-Path $PSScriptRoot '../app/src-tauri/binaries/media'
$archiveHash = '1ae156959395f0f0b3ad97674de02dc21fb3bbee01142a0d8f744467b5cd5886'
$archiveName = 'ffmpeg-n8.1.3-34-ga35157abb9-win64-lgpl-shared-8.1'
$marker = Join-Path $mediaRoot 'archive.sha256'
$sourceNotice = @'
Binary archive: https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-11-07-12-47/ffmpeg-n8.1.3-34-ga35157abb9-win64-lgpl-shared-8.1.zip
Corresponding FFmpeg source: https://github.com/FFmpeg/FFmpeg/archive/a35157abb9.tar.gz
Build recipes / dependency source retrieval: https://github.com/BtbN/FFmpeg-Builds
License: LGPL-3.0 shared libraries. See LICENSE.txt and the bundled THIRD_PARTY.md.
'@
if ((Test-Path (Join-Path $mediaRoot 'ffmpeg.exe')) -and (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $archiveHash)) { $sourceNotice | Set-Content -LiteralPath (Join-Path $mediaRoot 'SOURCE.txt') -Encoding utf8; exit 0 }
$cacheRoot = Join-Path $PSScriptRoot '../app/src-tauri/target/media-pinned'
New-Item -ItemType Directory -Path $cacheRoot,$mediaRoot -Force | Out-Null
$archive = Join-Path $cacheRoot 'ffmpeg.zip'
# BtbN removes automatic builds after about two weeks, so a copy of the same archive in this repository's
# releases is tried first; the hash check below makes both sources equivalent.
$urls = @(
    "https://github.com/ghaniev/keepword/releases/download/deps-ffmpeg-8.1.3-34/$archiveName.zip",
    "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-11-07-12-47/$archiveName.zip"
)
$downloaded = $false
foreach ($url in $urls) {
    & curl.exe --silent --show-error --fail --location --retry 3 --output $archive $url
    if ($LASTEXITCODE -eq 0) { $downloaded = $true; break }
}
if (-not $downloaded) { throw "FFmpeg download failed. Tried: $($urls -join ', ')" }
if ((Get-ArtifactHash $archive) -ne $archiveHash) { throw 'FFmpeg checksum mismatch' }
Expand-Artifact $archive $cacheRoot
$extracted = Join-Path $cacheRoot $archiveName
Get-ChildItem -LiteralPath (Join-Path $extracted 'bin') -File | Where-Object { $_.Extension -eq '.dll' -or $_.Name -in @('ffmpeg.exe','ffprobe.exe') } | Copy-Item -Destination $mediaRoot
Copy-Item -LiteralPath (Join-Path $extracted 'LICENSE.txt') -Destination $mediaRoot
$sourceNotice | Set-Content -LiteralPath (Join-Path $mediaRoot 'SOURCE.txt') -Encoding utf8
$archiveHash | Set-Content -LiteralPath $marker -Encoding ascii
