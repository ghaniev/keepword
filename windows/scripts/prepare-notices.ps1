$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-tools.ps1')
$appRoot = (Resolve-Path (Join-Path $PSScriptRoot '../app')).Path
$noticesRoot = Join-Path $appRoot 'src-tauri/binaries/notices'
New-Item -ItemType Directory -Force -Path $noticesRoot | Out-Null
$fingerprint = (Get-ArtifactHash (Join-Path $appRoot 'src-tauri/Cargo.lock')) + (Get-ArtifactHash (Join-Path $appRoot 'package-lock.json')) + (Get-ArtifactHash $PSCommandPath)
$markerPath = Join-Path $noticesRoot 'prepared.txt'
if ((Test-Path $markerPath) -and (Get-Content $markerPath -Raw).Trim() -eq $fingerprint) { exit 0 }
$packageNotices = [System.Collections.Generic.List[object]]::new()
function Copy-PackageNotices([string]$Name, [string]$Version, [string]$License, [string]$Source, [string]$Directory) {
    $noticeFolder = Join-Path $noticesRoot (($Name -replace '[^a-zA-Z0-9._-]', '_') + '-' + $Version)
    New-Item -ItemType Directory -Force -Path $noticeFolder | Out-Null
    $licenseFiles = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)' })
    foreach ($licenseFile in $licenseFiles) { Copy-Item -LiteralPath $licenseFile.FullName -Destination (Join-Path $noticeFolder $licenseFile.Name) -Force }
    $packageNotices.Add(@{ name=$Name; version=$Version; license=$License; source=$Source; files=@($licenseFiles | ForEach-Object { $_.Name }) })
}
Push-Location (Join-Path $appRoot 'src-tauri')
try {
    $metadataText = & cargo metadata --locked --offline --format-version 1
    if ($LASTEXITCODE -ne 0) { $metadataText = & cargo metadata --locked --format-version 1 }
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read dependency metadata' }
    $metadata = $metadataText | ConvertFrom-Json
    foreach ($package in $metadata.packages) {
        if ($package.name -eq 'meetnotes') { continue }
        Copy-PackageNotices $package.name $package.version $package.license $package.repository (Split-Path $package.manifest_path)
    }
} finally { Pop-Location }
$nodePackages = Get-ChildItem (Join-Path $appRoot 'node_modules') -Directory | ForEach-Object {
    if ($_.Name.StartsWith('@')) { Get-ChildItem $_.FullName -Directory } else { $_ }
}
foreach ($directory in $nodePackages) {
    $manifest = Join-Path $directory.FullName 'package.json'
    if (-not (Test-Path $manifest)) { continue }
    $package = Get-Content $manifest -Raw | ConvertFrom-Json
    Copy-PackageNotices $package.name $package.version ([string]$package.license) 'npm registry' $directory.FullName
}
$packageNotices | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $noticesRoot 'packages.json') -Encoding UTF8
$fingerprint | Set-Content $markerPath -Encoding ASCII
