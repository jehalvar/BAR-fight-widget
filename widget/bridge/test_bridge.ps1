# Offline build, validation and process-lifecycle checks. Makes no HTTP requests.
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BARFightBridge-test-' + [guid]::NewGuid().ToString('N'))
$testData = Join-Path $testRoot 'BAR data'
$testConfig = Join-Path $testData 'LuaUI\Config'
$consoleExe = Join-Path $testRoot 'BarFightBridge.Console.exe'
$windowlessExe = Join-Path $testRoot 'BarFightBridge.exe'
$primary = $null
New-Item -ItemType Directory -Path $testConfig -Force | Out-Null
try {
    & $compiler /nologo /target:exe /optimize+ /reference:System.Web.Extensions.dll "/out:$consoleExe" (Join-Path $PSScriptRoot 'BarFightBridge.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Console build failed.' }
    & $consoleExe --self-test
    if ($LASTEXITCODE -ne 0) { throw 'Offline self-tests failed.' }
    & $compiler /nologo /target:winexe /optimize+ /reference:System.Web.Extensions.dll "/out:$windowlessExe" (Join-Path $PSScriptRoot 'BarFightBridge.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Windowless build failed.' }
    # Sentinel updater proves scheduling behavior without contacting any server.
    $updaterSource = Join-Path $testRoot 'UpdaterSentinel.cs'
    $updaterExe = Join-Path $testRoot 'BarFightUpdater.exe'
    $updateMarker = Join-Path $testRoot 'update-requested'
    $installIni = Join-Path $testRoot 'bar-fight.ini'
    [System.IO.File]::WriteAllText($updaterSource, 'using System; using System.IO; internal static class Sentinel { static void Main(string[] args) { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "update-requested"), String.Join(" ", args)); } }')
    & $compiler /nologo /target:winexe "/out:$updaterExe" $updaterSource
    if ($LASTEXITCODE -ne 0) { throw 'Updater sentinel build failed.' }
    [System.IO.File]::WriteAllText($installIni, "[BAR]`r`nDataDir=$testData`r`n[Updates]`r`nEnabled=0`r`n")

    foreach ($endpoint in @('http://bar-fight.com/api/widget/traits', 'https://example.com/api/widget/traits')) {
        $invalidArgs = @('--data-dir', ('"' + $testData + '"'), '--endpoint', $endpoint, '--once')
        $invalidRun = Start-Process -FilePath $consoleExe -ArgumentList $invalidArgs -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardError (Join-Path $testRoot 'invalid-endpoint.stderr') `
            -RedirectStandardOutput (Join-Path $testRoot 'invalid-endpoint.stdout')
        if ($invalidRun.ExitCode -eq 0) { throw 'An unapproved HTTP endpoint was accepted.' }
    }
    & $consoleExe --data-dir $testData --once
    if ($LASTEXITCODE -ne 0) { throw 'Empty --once failed.' }
    & $consoleExe --data-dir $testData --stop
    if ($LASTEXITCODE -ne 0) { throw '--stop without a running instance failed.' }

    $requestPath = Join-Path $testConfig 'bar_fight_traits_request.json'
    [System.IO.File]::WriteAllText($requestPath, '{"schema":1,"request_id":"expired","map":"Supreme Isthmus v2.1","accounts":["21705"]}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::SetLastWriteTimeUtc($requestPath, [DateTime]::UtcNow.AddMinutes(-6))
    & $consoleExe --data-dir $testData --once
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath (Join-Path $testConfig 'bar_fight_traits_response.json'))) {
        throw 'Expired request was processed.'
    }

    # A newly created/partially written request must not terminate the helper.
    [System.IO.File]::WriteAllText($requestPath, '{}', [System.Text.UTF8Encoding]::new($false))
    $processArgs = @('--data-dir', ('"' + $testData + '"'))
    $primary = Start-Process -FilePath $windowlessExe -ArgumentList $processArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1300
    $primary.Refresh()
    if ($primary.HasExited) { throw 'Malformed request terminated the companion.' }
    [System.IO.File]::WriteAllText($requestPath, '{"schema":', [System.Text.UTF8Encoding]::new($false))
    Start-Sleep -Milliseconds 1300
    $primary.Refresh()
    if ($primary.HasExited) { throw 'Partial request terminated the companion.' }
    $duplicate = Start-Process -FilePath $windowlessExe -ArgumentList $processArgs -WindowStyle Hidden -PassThru
    if (-not $duplicate.WaitForExit(3000) -or $duplicate.ExitCode -ne 0) { throw 'Single-instance check failed.' }
    $primary.Refresh()
    if ($primary.HasExited) { throw 'Duplicate launch stopped the original instance.' }
    & $consoleExe --data-dir (Join-Path $testRoot 'Different BAR data') --stop
    $primary.Refresh()
    if ($LASTEXITCODE -ne 0 -or $primary.HasExited) { throw '--stop affected a different data directory.' }
    & $consoleExe --data-dir $testData --stop
    if ($LASTEXITCODE -ne 0 -or -not $primary.WaitForExit(500) -or $primary.ExitCode -ne 0) { throw 'Clean stop did not await the instance shutdown.' }
    if (Test-Path -LiteralPath (Join-Path $testConfig 'bar_fight_traits_response.json')) { throw 'Malformed request produced a response.' }
    if (Test-Path -LiteralPath $updateMarker) { throw 'Disabled updater was launched.' }
    [System.IO.File]::WriteAllText($installIni, "[BAR]`r`nDataDir=$testData`r`n[Updates]`r`nEnabled=1`r`n")
    Remove-Item -LiteralPath $requestPath -Force
    & $consoleExe --data-dir $testData --once
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $updateMarker)) { throw '--once launched an updater.' }
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'update-paused'), 'installer maintenance')
    $primary.Dispose()
    $primary = Start-Process -FilePath $windowlessExe -ArgumentList $processArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1200
    & $consoleExe --data-dir $testData --stop
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $updateMarker)) { throw 'Installer maintenance did not suppress updater.' }
    Remove-Item -LiteralPath (Join-Path $testRoot 'update-paused') -Force
    $primary.Dispose()
    $primary = Start-Process -FilePath $windowlessExe -ArgumentList $processArgs -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1200
    & $consoleExe --data-dir $testData --stop
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $updateMarker)) { throw 'Enabled installed helper did not launch updater.' }
    if (-not ([System.IO.File]::ReadAllText($updateMarker).StartsWith('--check --app-dir '))) { throw 'Updater command contract mismatch.' }
    # Opting out of profile lookups produces an honest local status, independently
    # of the enabled updater sentinel. No profile HTTP request is needed.
    [System.IO.File]::WriteAllText($installIni, "[BAR]`r`nDataDir=$testData`r`n[Updates]`r`nEnabled=1`r`n[Privacy]`r`nFetchProfiles=0`r`n")
    [System.IO.File]::WriteAllText($requestPath, '{"schema":1,"request_id":"privacy-check","map":"Supreme Isthmus v2.1","accounts":["21705"]}', [System.Text.UTF8Encoding]::new($false))
    $privacyCheck = Start-Process -FilePath $consoleExe -ArgumentList @('--data-dir', ('"' + $testData + '"'), '--once') -WindowStyle Hidden -Wait -PassThru
    if ($privacyCheck.ExitCode -ne 2) { throw 'Profile opt-out did not report a disabled lookup.' }
    $privacyCheck.Dispose()
    $privacyResponse = Get-Content -LiteralPath (Join-Path $testConfig 'bar_fight_traits_response.json') -Raw | ConvertFrom-Json
    if ($privacyResponse.error_code -ne 'privacy-disabled' -or $privacyResponse.profiles) { throw 'Profile opt-out response is incorrect.' }
    Write-Output 'Build and offline lifecycle checks passed; no HTTP requests were made.'
}
finally {
    if ($null -ne $primary) {
        $primary.Refresh()
        if (-not $primary.HasExited) {
            & $consoleExe --data-dir $testData --stop
            $null = $primary.WaitForExit(3000)
        }
        $primary.Dispose()
    }
    # Delete only known test files and empty directories; never recurse over a computed path.
    foreach ($file in @($consoleExe, $windowlessExe, (Join-Path $testRoot 'UpdaterSentinel.cs'), (Join-Path $testRoot 'BarFightUpdater.exe'), (Join-Path $testRoot 'update-requested'), (Join-Path $testRoot 'bar-fight.ini'), (Join-Path $testRoot 'update-paused'), (Join-Path $testRoot 'invalid-endpoint.stderr'), (Join-Path $testRoot 'invalid-endpoint.stdout'), (Join-Path $testConfig 'bar_fight_traits_request.json'), (Join-Path $testConfig 'bar_fight_traits_response.json'))) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    foreach ($directory in @($testConfig, (Join-Path $testData 'LuaUI'), $testData, $testRoot)) {
        if (Test-Path -LiteralPath $directory) { [System.IO.Directory]::Delete($directory, $false) }
    }
}
