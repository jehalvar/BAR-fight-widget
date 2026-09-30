# Offline updater security and crash-recovery tests. Never uses a production signing key or HTTP.
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('BARFightUpdater-build-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $fixture = Join-Path $testRoot 'BuildFixture.cs'
    $rsa = [Security.Cryptography.RSACryptoServiceProvider]::new(3072)
    $rsa.PersistKeyInCsp = $false
    try {
        $fixtureSource = '[assembly: System.Reflection.AssemblyFileVersion("0.1.6.0")] internal static class WidgetBuild { public const string Version = "0.1.6"; } internal static class UpdateTrust { public const string PublicKeyXml = "' + $rsa.ToXmlString($false) + '"; } internal static class FixtureTrust { public const string PrivateKeyXml = "' + $rsa.ToXmlString($true) + '"; }'
        [System.IO.File]::WriteAllText($fixture, $fixtureSource)
    } finally { $rsa.Dispose() }
    $exe = Join-Path $testRoot 'UpdaterTests.exe'
    & $compiler /nologo /target:exe /optimize+ /define:UPDATE_TEST /r:System.Web.Extensions.dll /main:UpdaterTests "/out:$exe" $fixture (Join-Path $PSScriptRoot 'BarFightUpdater.cs') (Join-Path $PSScriptRoot 'UpdaterTests.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Updater test build failed.' }
    & $exe
    if ($LASTEXITCODE -ne 0) { throw 'Updater offline tests failed.' }
}
finally {
    foreach ($name in @('BuildFixture.cs', 'UpdaterTests.exe')) {
        $path = Join-Path $testRoot $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    [System.IO.Directory]::Delete($testRoot, $false)
}
