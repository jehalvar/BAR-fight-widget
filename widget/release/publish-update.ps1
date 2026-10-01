param(
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$KeyPath = (Join-Path $env:LOCALAPPDATA 'BARFightRelease\update-key.dpapi'),
    [string]$OutputDirectory,
    [int]$ValidDays = 30
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '\A(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\z') { throw 'Use a canonical numeric three-part version.' }
if ($ValidDays -lt 1 -or $ValidDays -gt 30) { throw 'Update manifests are valid for 1 to 30 days.' }
Add-Type -AssemblyName System.Security
$widgetRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $widgetRoot 'dist\updates\widget' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$sources = [ordered]@{
    'BarFightBridge.exe' = (Join-Path $widgetRoot 'build\BarFightBridge.exe')
    'BarFightUpdater.exe' = (Join-Path $widgetRoot 'build\BarFightUpdater.exe')
    'gui_bar_fight_traits.lua' = (Join-Path $widgetRoot 'gui_bar_fight_traits.lua')
    'gui_bar_fight_player_list.lua' = (Join-Path $widgetRoot 'gui_bar_fight_player_list.lua')
    'README.md' = (Join-Path $widgetRoot 'README.md')
}
$releasePath = Join-Path $OutputDirectory $Version
New-Item -ItemType Directory -Path $releasePath -Force | Out-Null
$files = @()
$totalSize = 0L
foreach ($entry in $sources.GetEnumerator()) {
    $item = Get-Item -LiteralPath $entry.Value
    if ($item.Length -gt 8MB -or $item.Length -le 0) { throw ('Invalid release file size: ' + $entry.Key) }
    $totalSize += $item.Length
    if ($totalSize -gt 20MB) { throw 'Update files exceed the client total size limit.' }
    if ($entry.Key -eq 'BarFightUpdater.exe') {
        $binaryVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName).FileVersion
        if ($binaryVersion -ne $Version -and $binaryVersion -ne ($Version + '.0')) { throw 'Build version does not match the update version.' }
    }
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $destination = Join-Path $releasePath $entry.Key
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Versioned update files are immutable. Increase the version for changed files.' }
    } else { Copy-Item -LiteralPath $item.FullName -Destination $destination }
    $files += [ordered]@{name=$entry.Key;url=('https://bar-fight.com/updates/widget/' + $Version + '/' + $entry.Key);sha256=$hash;size=$item.Length}
}
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$payload = [ordered]@{schema=1;product='bar-fight-widget';channel='stable';version=$Version;published_at=$now;expires_at=($now + $ValidDays * 86400);files=$files}
$payloadBytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))
$rsa = [Security.Cryptography.RSACryptoServiceProvider]::new()
$rsa.PersistKeyInCsp = $false
try {
    $privateBytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($KeyPath), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($privateBytes)) }
    finally { [Array]::Clear($privateBytes, 0, $privateBytes.Length) }
    $publicSource = [IO.File]::ReadAllText((Join-Path $widgetRoot 'updater\UpdateTrust.cs'))
    if (-not $publicSource.Contains($rsa.ToXmlString($false))) { throw 'Release key does not match the key trusted by this build.' }
    $signature = $rsa.SignData($payloadBytes, 'SHA256')
    if (-not $rsa.VerifyData($payloadBytes, 'SHA256', $signature)) { throw 'Update signature self-check failed.' }
    $envelope = [ordered]@{payload=[Convert]::ToBase64String($payloadBytes);signature=[Convert]::ToBase64String($signature)}
    $json = $envelope | ConvertTo-Json -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768) { throw 'Update manifest exceeds the client limit.' }
    $manifestPath = Join-Path $OutputDirectory 'stable.json'
    $temporaryPath = $manifestPath + '.tmp'
    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($manifestBytes, 0, $manifestBytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    # Windows PowerShell converts $null to an empty path for a string parameter.
    if (Test-Path -LiteralPath $manifestPath) { [IO.File]::Replace($temporaryPath, $manifestPath, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temporaryPath, $manifestPath) }
    Write-Output ('Prepared authenticated update ' + $Version + ' in ' + $OutputDirectory)
} finally { $rsa.Dispose() }
