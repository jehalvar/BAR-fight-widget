param(
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '\A(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\z' -or @($Version.Split('.') | Where-Object { [int]$_ -gt 65534 }).Count) {
    throw 'Use a canonical numeric three-part version with each part below 65535.'
}
$source = '[assembly: System.Reflection.AssemblyProduct("BAR Fight")]' + "`n" +
    '[assembly: System.Reflection.AssemblyInformationalVersion("' + $Version + '")]' + "`n" +
    '[assembly: System.Reflection.AssemblyFileVersion("' + $Version + '.0")]' + "`n" +
    '[assembly: System.Reflection.AssemblyVersion("' + $Version + '.0")]' + "`n" +
    'internal static class WidgetBuild { public const string Version = "' + $Version + '"; }' + "`n"
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $source, [Text.UTF8Encoding]::new($false))
