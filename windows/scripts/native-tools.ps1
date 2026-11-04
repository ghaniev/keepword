function Get-ArtifactHash([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Expand-Artifact([string]$Path, [string]$Destination) {
    & tar.exe -xf $Path -C $Destination
    if ($LASTEXITCODE -ne 0) { throw 'Archive extraction failed' }
}
