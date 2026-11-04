$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-tools.ps1')
$mediaRoot = Join-Path $PSScriptRoot '../app/src-tauri/binaries/media'
$archiveHash = '2eec333253518c6deb0a8b6dff6d615e03f254baa1b04f44356de2725e5fb60f'
$marker = Join-Path $mediaRoot 'archive.sha256'
$sourceNotice = @'
Binary archive: https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-21-13-06/ffmpeg-n8.1.3-20-gc8de997cb1-win64-lgpl-shared-8.1.zip
Corresponding FFmpeg source: https://github.com/FFmpeg/FFmpeg/archive/c8de997cb1.tar.gz
Build recipes / dependency source retrieval: https://github.com/BtbN/FFmpeg-Builds
License: LGPL-3.0 shared libraries. See LICENSE.txt and the bundled THIRD_PARTY.md.
'@
if ((Test-Path (Join-Path $mediaRoot 'ffmpeg.exe')) -and (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $archiveHash)) { $sourceNotice | Set-Content -LiteralPath (Join-Path $mediaRoot 'SOURCE.txt') -Encoding utf8; exit 0 }
$cacheRoot = Join-Path $PSScriptRoot '../app/src-tauri/target/media-pinned'
New-Item -ItemType Directory -Path $cacheRoot,$mediaRoot -Force | Out-Null
$archive = Join-Path $cacheRoot 'ffmpeg.zip'
$url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-21-13-06/ffmpeg-n8.1.3-20-gc8de997cb1-win64-lgpl-shared-8.1.zip'
& curl.exe --silent --show-error --fail --location --retry 3 --output $archive $url
if ($LASTEXITCODE -ne 0) { throw 'FFmpeg download failed' }
if ((Get-ArtifactHash $archive) -ne $archiveHash) { throw 'FFmpeg checksum mismatch' }
Expand-Artifact $archive $cacheRoot
$extracted = Join-Path $cacheRoot 'ffmpeg-n8.1.3-20-gc8de997cb1-win64-lgpl-shared-8.1'
Get-ChildItem -LiteralPath (Join-Path $extracted 'bin') -File | Where-Object { $_.Extension -eq '.dll' -or $_.Name -in @('ffmpeg.exe','ffprobe.exe') } | Copy-Item -Destination $mediaRoot
Copy-Item -LiteralPath (Join-Path $extracted 'LICENSE.txt') -Destination $mediaRoot
$sourceNotice | Set-Content -LiteralPath (Join-Path $mediaRoot 'SOURCE.txt') -Encoding utf8
$archiveHash | Set-Content -LiteralPath $marker -Encoding ascii
