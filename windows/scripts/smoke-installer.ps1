$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-tools.ps1')
$tauriRoot = (Resolve-Path (Join-Path $PSScriptRoot '../app/src-tauri')).Path
$testRoot = [IO.Path]::GetFullPath((Join-Path $tauriRoot 'target/installer-smoke'))
$targetRoot = [IO.Path]::GetFullPath((Join-Path $tauriRoot 'target')) + [IO.Path]::DirectorySeparatorChar
if (-not $testRoot.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Smoke target is outside the build workspace' }
$installation = Join-Path $testRoot 'installation'
$library = Join-Path $testRoot 'library'
$installer = Get-ChildItem (Join-Path $tauriRoot 'target/release/bundle/nsis/*-setup.exe') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $installer) { throw 'Build the installer first' }
if (Get-Process meetnotes -ErrorAction SilentlyContinue) { throw 'Close Keepword before the installer smoke test; existing sessions are never stopped by this script' }
$existing = Get-ChildItem HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -like 'Keepword*' }
if ($existing | Where-Object { $_.InstallLocation -and $_.InstallLocation.TrimEnd('\') -ne $installation.TrimEnd('\') }) { throw 'An existing Keepword installation must be tested in a clean Windows account or VM' }
New-Item -ItemType Directory -Force -Path $testRoot,$library | Out-Null
'Keep this library during upgrades and uninstall.' | Set-Content (Join-Path $library 'keep.txt') -Encoding UTF8
function Install-TestBuild {
    $process = Start-Process -FilePath $installer.FullName -ArgumentList @('/S', ('/D=' + $installation)) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(60000)) { throw 'Installer did not finish within 60 seconds' }
    if ($process.ExitCode -ne 0) { throw "Installer returned $($process.ExitCode)" }
}
Install-TestBuild
foreach ($file in @('meetnotes.exe','onnxruntime/onnxruntime.dll','onnxruntime/ThirdPartyNotices.txt','media/ffmpeg.exe','media/SOURCE.txt','llama/llama-completion.exe','notices/packages.json','THIRD_PARTY.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $installation $file))) { throw "Installed resource missing: $file" }
}
$appPath = Join-Path $installation 'meetnotes.exe'
$appProcess = Start-Process -FilePath $appPath -ArgumentList @('--library-path', ('"' + $library + '"')) -WorkingDirectory $installation -WindowStyle Hidden -PassThru
# A cold first launch on a CI runner (Defender scan, WebView2 setup) can take well over 5 seconds.
$database = Join-Path $library 'meetnotes.sqlite'
for ($attempt = 0; $attempt -lt 60 -and -not $appProcess.HasExited -and -not (Test-Path -LiteralPath $database); $attempt++) { Start-Sleep -Seconds 1 }
if ($appProcess.HasExited) { throw "Installed app exited on startup: $($appProcess.ExitCode)" }
if (-not (Test-Path -LiteralPath $database)) {
    Get-ChildItem -Force -Recurse -LiteralPath $library | ForEach-Object { Write-Output "library: $($_.FullName)" }
    Stop-Process -Id $appProcess.Id
    throw 'Installed app did not initialize its isolated library within 60 seconds'
}
# This process was created by this test with an empty library; no microphone is started.
Stop-Process -Id $appProcess.Id
Install-TestBuild
if (-not (Test-Path (Join-Path $library 'meetnotes.sqlite'))) { throw 'Upgrade removed the library' }
$uninstaller = Join-Path $installation 'uninstall.exe'
if (-not (Test-Path $uninstaller)) { throw 'Uninstaller is missing' }
$uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList '/S' -WindowStyle Hidden -PassThru
if (-not $uninstallProcess.WaitForExit(60000)) { throw 'Uninstaller timed out' }
for ($attempt=0; $attempt -lt 10 -and (Test-Path $appPath); $attempt++) { Start-Sleep -Seconds 1 }
if (Test-Path $appPath) { throw 'Uninstall did not remove the application' }
if (-not (Test-Path (Join-Path $library 'meetnotes.sqlite')) -or -not (Test-Path (Join-Path $library 'keep.txt'))) { throw 'Uninstall removed isolated user data' }
@{ installed=$true; startup=$true; resources=$true; upgrade=$true; uninstall=$true; dataPreserved=$true; installer=$installer.Name; sha256=(Get-ArtifactHash $installer.FullName); checkedAt=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $testRoot 'result.json') -Encoding UTF8
Write-Output 'Install, startup, packaged resources, reinstall and uninstall checks passed; isolated library preserved.'
