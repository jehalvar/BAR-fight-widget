param([string]$Version = '0.1.10')
$ErrorActionPreference = 'Stop'
$setup = Join-Path $PSScriptRoot "dist\BAR-Fight-Setup-$Version.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw 'Build the installer first.' }
if (Test-Path 'HKCU:\Software\BARFight') { throw 'An existing BAR Fight install is present; use a clean Windows user for this test.' }
if (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7342C7DB-CFDE-41E2-A4C0-8C2DE321110A}_is1') { throw 'A registered BAR Fight uninstaller is present; use a clean Windows user for this test.' }
if (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name BARFightTraits -ErrorAction SilentlyContinue) { throw 'An existing BAR Fight startup preference is present; use a clean Windows user for this test.' }
$fixture = Join-Path $PSScriptRoot ('test-output\installer-' + [Guid]::NewGuid().ToString('N'))
$dataDir = Join-Path $fixture 'BAR\data'
$appDir = Join-Path $fixture 'app'
$widgets = Join-Path $dataDir 'LuaUI\Widgets'
$updateWork = Join-Path $appDir '.update'
$ownedUpdateNames = @('BarFightBridge.exe', 'BarFightUpdater.exe', 'gui_bar_fight_traits.lua', 'gui_bar_fight_player_list.lua', 'README.md')
$ownedUpdatePaths = @('runner.exe', 'pending.json', 'next-check', 'highest-version', 'journal.json')
foreach ($name in $ownedUpdateNames) { $ownedUpdatePaths += @("stage\$name", "backup\$name") }
$ownedUpdatePaths = @($ownedUpdatePaths | ForEach-Object { $_; "$_.tmp" })
function Seed-OwnedUpdateState {
    foreach ($relative in $ownedUpdatePaths) {
        $path = Join-Path $updateWork $relative
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
        [IO.File]::WriteAllText($path, ('stale automatic update: ' + $relative))
    }
    [IO.File]::WriteAllText((Join-Path $updateWork 'highest-version'), $Version)
}
function Assert-OwnedUpdateStateRemoved([bool]$PreserveFloor) {
    foreach ($relative in $ownedUpdatePaths) {
        $path = Join-Path $updateWork $relative
        if ($PreserveFloor -and $relative -eq 'highest-version') {
            if (-not (Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path) -ne $Version) { throw 'Upgrade did not preserve the committed downgrade floor.' }
        } elseif (Test-Path -LiteralPath $path) { throw "Owned update state remains: $relative" }
    }
}
function Assert-AutomaticUpdates([string]$Expected) {
    $ini = [IO.File]::ReadAllText((Join-Path $appDir 'bar-fight.ini'))
    if ($ini -notmatch ('(?ms)^\[Updates\]\s*\r?\n(?:(?!\[).)*?^Enabled=' + $Expected + '\s*$')) {
        throw "Automatic update preference was not saved as $Expected."
    }
}
New-Item -ItemType Directory -Path $widgets -Force | Out-Null
$unrelated = Join-Path $widgets 'unrelated_widget.lua'
[IO.File]::WriteAllText($unrelated, '-- leave this widget alone')
$arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /TASKS="startup" /NORUN=1 /DIR="' + $appDir + '" /BARDATADIR="' + (Split-Path $dataDir) + '" /LOG="' + (Join-Path $fixture 'install.log') + '"'
try {
    $install = Start-Process -FilePath $setup -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    if ($install.ExitCode -ne 0) { throw "Installation failed ($($install.ExitCode)); see $fixture" }
    if (-not (Test-Path -LiteralPath (Join-Path $appDir 'BarFightBridge.exe'))) { throw 'Helper missing.' }
    if (-not (Test-Path -LiteralPath (Join-Path $appDir 'BarFightUpdater.exe'))) { throw 'Updater missing.' }
    if (Test-Path -LiteralPath (Join-Path $appDir 'update-paused')) { throw 'Installer left updates paused.' }
    Assert-AutomaticUpdates '0'
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'gui_bar_fight_traits.lua')).Hash
    $installedHash = (Get-FileHash -LiteralPath (Join-Path $widgets 'gui_bar_fight_traits.lua')).Hash
    if ($sourceHash -ne $installedHash) { throw 'Installed widget does not match source.' }
    $adapterName = 'gui_bar_fight_player_list.lua'
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $adapterName)).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $widgets $adapterName)).Hash) { throw 'Native player-list adapter does not match source.' }
    if ((Get-ItemPropertyValue -Path 'HKCU:\Software\BARFight' -Name DataDir) -ne $dataDir) { throw 'Installer did not normalize BAR root to its data folder.' }
    $startup = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name BARFightTraits -ErrorAction SilentlyContinue
    if (-not $startup -or $startup.BARFightTraits -notlike ('*' + $dataDir + '*')) { throw 'Selected startup option did not record the installed data folder.' }
    $config = Join-Path $dataDir 'LuaUI\Config'
    New-Item -ItemType Directory -Path $config -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $config 'bar_fight_traits_request.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $config 'bar_fight_traits_response.json'), '{}')
    $helper = Start-Process -FilePath (Join-Path $appDir 'BarFightBridge.exe') -ArgumentList ('--data-dir "' + $dataDir + '"') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1000
    if ($helper.HasExited) { throw 'Installed helper failed to start.' }
    Seed-OwnedUpdateState
    $unrelatedUpdate = Join-Path $updateWork 'user-note.txt'
    [IO.File]::WriteAllText($unrelatedUpdate, 'keep this user note')
    $upgradeArgs = $arguments.Replace('/TASKS="startup"', '/TASKS="autoupdate"')
    $upgrade = Start-Process -FilePath $setup -ArgumentList $upgradeArgs -WindowStyle Hidden -Wait -PassThru
    if ($upgrade.ExitCode -ne 0) { throw 'Upgrade failed.' }
    if (-not $helper.WaitForExit(5000)) { throw 'Upgrade did not stop the old helper.' }
    if (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name BARFightTraits -ErrorAction SilentlyContinue) { throw 'Upgrade opt-out left startup enabled.' }
    Assert-AutomaticUpdates '1'
    Assert-OwnedUpdateStateRemoved $true
    foreach ($directory in @('stage', 'backup')) {
        if (Test-Path -LiteralPath (Join-Path $updateWork $directory)) { throw "Upgrade left empty update directory: $directory" }
    }
    if ([IO.File]::ReadAllText($unrelatedUpdate) -ne 'keep this user note') { throw 'Upgrade changed unrelated update-directory content.' }
    if (Test-Path -LiteralPath (Join-Path $appDir 'update-paused')) { throw 'Upgrade left updates paused.' }
    Seed-OwnedUpdateState
    $unrelatedStage = Join-Path $updateWork 'stage\user-stage-note.txt'
    [IO.File]::WriteAllText($unrelatedStage, 'keep this staging note')
    # Exercise helper shutdown without contacting the production update channel.
    # The installer maintenance marker prevents checks even with updates enabled.
    [IO.File]::WriteAllText((Join-Path $appDir 'update-paused'), '')
    # A removed registry preference must not prevent ordinary uninstall.
    Remove-ItemProperty -Path 'HKCU:\Software\BARFight' -Name DataDir
    $helper = Start-Process -FilePath (Join-Path $appDir 'BarFightBridge.exe') -ArgumentList ('--data-dir "' + $dataDir + '"') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1000
    if ($helper.HasExited) { throw 'Upgraded helper failed to start.' }
} finally {
    if (Test-Path -LiteralPath (Join-Path $appDir 'unins000.exe')) {
        $uninstall = Start-Process -FilePath (Join-Path $appDir 'unins000.exe') -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + (Join-Path $fixture 'uninstall.log') + '"') -WindowStyle Hidden -Wait -PassThru
        if ($uninstall.ExitCode -ne 0) { throw "Uninstall failed ($($uninstall.ExitCode)); see $fixture" }
    }
}
if ($helper -and -not $helper.WaitForExit(5000)) { throw 'Helper remained running after uninstall.' }
if (Test-Path -LiteralPath (Join-Path $widgets 'gui_bar_fight_traits.lua')) { throw 'Widget remains after uninstall.' }
if (Test-Path -LiteralPath (Join-Path $widgets 'gui_bar_fight_player_list.lua')) { throw 'Player-list adapter remains after uninstall.' }
foreach ($name in @('bar_fight_traits_request.json', 'bar_fight_traits_response.json')) {
    if (Test-Path -LiteralPath (Join-Path $config $name)) { throw "Owned file remains: $name" }
}
if (-not (Test-Path -LiteralPath $unrelated)) { throw 'Unrelated widget was removed.' }
Assert-OwnedUpdateStateRemoved $false
if (Test-Path -LiteralPath (Join-Path $updateWork 'backup')) { throw 'Uninstall left an empty update backup directory.' }
if (Test-Path -LiteralPath (Join-Path $appDir 'update-paused')) { throw 'Uninstall left the update maintenance marker.' }
if ([IO.File]::ReadAllText($unrelatedUpdate) -ne 'keep this user note') { throw 'Uninstall changed unrelated update-directory content.' }
if ([IO.File]::ReadAllText($unrelatedStage) -ne 'keep this staging note') { throw 'Uninstall changed unrelated staging content.' }
if (Test-Path 'HKCU:\Software\BARFight') { throw 'Install registry key remains.' }
Write-Output "Installer lifecycle passed. Isolated fixture and logs: $fixture"
