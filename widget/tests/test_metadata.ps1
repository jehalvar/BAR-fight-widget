# Verifies release metadata on actual compiled helper/updater binaries in a temporary directory.
param([string]$Version = '0.1.9')
$ErrorActionPreference = 'Stop'
$widgetRoot = Split-Path $PSScriptRoot
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('BARFight-metadata-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $metadata = Join-Path $fixture 'WidgetBuild.cs'
    & (Join-Path $widgetRoot 'release\write-build-metadata.ps1') -Version $Version -OutputPath $metadata
    $bridge = Join-Path $fixture 'BarFightBridge.exe'
    $updater = Join-Path $fixture 'BarFightUpdater.exe'
    & $compiler /nologo /target:winexe /optimize+ /r:System.Web.Extensions.dll "/out:$bridge" (Join-Path $widgetRoot 'bridge\BarFightBridge.cs') $metadata
    if ($LASTEXITCODE -ne 0) { throw 'Helper metadata build failed.' }
    & $compiler /nologo /target:winexe /optimize+ /r:System.Web.Extensions.dll "/out:$updater" (Join-Path $widgetRoot 'updater\BarFightUpdater.cs') (Join-Path $widgetRoot 'updater\UpdateTrust.cs') $metadata
    if ($LASTEXITCODE -ne 0) { throw 'Updater metadata build failed.' }
    foreach ($binary in @($bridge, $updater)) {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($binary)
        if ($info.ProductName -cne 'BAR Fight') { throw ('Wrong ProductName: ' + $binary) }
        if ($info.ProductVersion -cne $Version) { throw ('Wrong ProductVersion: ' + $binary) }
        if ($info.FileVersion -cne ($Version + '.0')) { throw ('Wrong FileVersion: ' + $binary) }
        $assembly = [Reflection.AssemblyName]::GetAssemblyName($binary)
        if ($assembly.Version.ToString() -cne ($Version + '.0')) { throw ('Wrong assembly version: ' + $binary) }
        Write-Output ([IO.Path]::GetFileName($binary) + ': ProductName=' + $info.ProductName + '; ProductVersion=' + $info.ProductVersion + '; FileVersion=' + $info.FileVersion)
    }
    $selfTest = Start-Process -FilePath $bridge -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
    if ($selfTest.ExitCode -ne 0) { throw 'Metadata-bearing helper self-test failed.' }
    Write-Output 'Both executables have consistent release metadata; helper self-tests passed. No HTTP requests or installation were performed.'
}
finally {
    foreach ($name in @('WidgetBuild.cs','BarFightBridge.exe','BarFightUpdater.exe')) {
        $file = Join-Path $fixture $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    [IO.Directory]::Delete($fixture, $false)
}
