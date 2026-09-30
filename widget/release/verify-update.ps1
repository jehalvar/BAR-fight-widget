param([switch]$Published)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Run this verifier with Windows PowerShell (powershell.exe), which supplies .NET Framework.' }
$widgetRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$assembly = [Reflection.Assembly]::LoadFile((Join-Path $widgetRoot 'build\BarFightUpdater.exe'))
$updater = $assembly.GetType('BarFightUpdater')
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$pin = $assembly.GetType('UpdateTrust').GetField('PublicKeyXml', [Reflection.BindingFlags]'Static,Public').GetRawConstantValue()
if ($Published) {
    $manifest = $updater.GetMethod('Download', $flags).Invoke($null, [object[]]@('https://bar-fight.com/updates/widget/stable.json', 131072))
} else {
    $manifest = [IO.File]::ReadAllBytes((Join-Path $widgetRoot 'dist\updates\widget\stable.json'))
}
$release = $updater.GetMethod('Verify', $flags).Invoke($null, [object[]]@($manifest, $pin, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
$version = $release.GetType().GetField('Version').GetValue($release)
foreach ($file in $release.GetType().GetField('Files').GetValue($release)) {
    $name = $file.GetType().GetField('Name').GetValue($file)
    if ($Published) {
        $url = $file.GetType().GetField('Url').GetValue($file)
        $size = [int]$file.GetType().GetField('Size').GetValue($file)
        $bytes = $updater.GetMethod('Download', $flags).Invoke($null, [object[]]@($url, $size))
    } else {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $widgetRoot ('dist\updates\widget\' + $version + '\' + $name)))
    }
    $updater.GetMethod('VerifyFile', $flags).Invoke($null, [object[]]@($bytes, $file))
}
Write-Output ('Production updater verified release ' + $version + ' and all five file hashes. Published=' + $Published)
