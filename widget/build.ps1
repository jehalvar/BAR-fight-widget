param(
    [string]$Version = '0.1.13',
    [string]$InnoCompiler = (Join-Path $PSScriptRoot '.build-tools\InnoSetup\ISCC.exe'),
    [string]$SigningConfig,
    [switch]$RequireAuthenticode,
    [switch]$PublishUpdate
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '\A(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\z' -or @($Version.Split('.') | Where-Object { [int]$_ -gt 65534 }).Count) { throw 'Use a canonical numeric three-part version with each part below 65535.' }
if ($RequireAuthenticode -and -not $SigningConfig) { throw 'Supply a verified publisher signing configuration before releasing a signed build.' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The .NET Framework C# compiler is required.' }
if (-not (Test-Path -LiteralPath $InnoCompiler)) { throw 'Install Inno Setup and pass its ISCC.exe path using -InnoCompiler.' }
$outputDirectory = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$bridge = Join-Path $outputDirectory 'BarFightBridge.exe'
$updater = Join-Path $outputDirectory 'BarFightUpdater.exe'
$versionSource = Join-Path $outputDirectory 'WidgetBuild.cs'
& (Join-Path $PSScriptRoot 'release\write-build-metadata.ps1') -Version $Version -OutputPath $versionSource
& $compiler /nologo /target:winexe /optimize+ /r:System.Web.Extensions.dll "/out:$bridge" (Join-Path $PSScriptRoot 'bridge\BarFightBridge.cs') $versionSource
if ($LASTEXITCODE -ne 0) { throw 'Bridge compilation failed.' }
$updaterSource = Join-Path $PSScriptRoot 'updater\BarFightUpdater.cs'
$trustSource = Join-Path $PSScriptRoot 'updater\UpdateTrust.cs'
& $compiler /nologo /target:winexe /optimize+ /r:System.Web.Extensions.dll "/out:$updater" $updaterSource $trustSource $versionSource
if ($LASTEXITCODE -ne 0) { throw 'Updater compilation failed.' }
$test = Start-Process -FilePath $bridge -ArgumentList '--self-test' -WindowStyle Hidden -Wait -PassThru
if ($test.ExitCode -ne 0) { throw 'Bridge self-test failed.' }
$innoArguments = @("/DAppVersion=$Version")
if ($SigningConfig) {
    $SigningConfig = (Get-Item -LiteralPath $SigningConfig).FullName
    $signScript = Join-Path $PSScriptRoot 'release\sign-binary.ps1'
    & $signScript -FilePath $bridge -ConfigPath $SigningConfig
    & $signScript -FilePath $updater -ConfigPath $SigningConfig
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $signCommand = '$q' + $powershell + '$q -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $q' + $signScript +
        '$q -ConfigPath $q' + $SigningConfig + '$q -FilePath $f'
    $innoArguments += @('/DSignBuild=1',('/SBARFight=' + $signCommand))
} else { Write-Output 'Windows publisher signing is not configured; this installer remains unsigned.' }
& $InnoCompiler @innoArguments (Join-Path $PSScriptRoot 'installer\BarFight.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
$installer = Join-Path $PSScriptRoot "dist\BAR-Fight-Setup-$Version.exe"
if ($SigningConfig -and (Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'Valid') { throw 'Installer publisher signature was not verified.' }
$digest = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$installer.sha256", "$digest  $([System.IO.Path]::GetFileName($installer))`n")
Get-Item -LiteralPath $installer | Select-Object FullName, Length
Write-Output "SHA256: $digest"
if ($PublishUpdate) { & (Join-Path $PSScriptRoot 'release\publish-update.ps1') -Version $Version }
