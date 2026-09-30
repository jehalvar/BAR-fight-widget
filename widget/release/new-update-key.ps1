param(
    [string]$KeyPath = (Join-Path $env:LOCALAPPDATA 'BARFightRelease\update-key.dpapi'),
    [string]$PublicSource = (Join-Path $PSScriptRoot '..\updater\UpdateTrust.cs')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
if (Test-Path -LiteralPath $KeyPath) { throw 'A release key already exists. Do not replace a key trusted by installed clients.' }
if (Test-Path -LiteralPath $PublicSource) { throw 'A public trust key already exists. Key rotation requires an explicit migration.' }
$keyDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($KeyPath))
New-Item -ItemType Directory -Path $keyDirectory -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($identity)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
Set-Acl -LiteralPath $keyDirectory -AclObject $acl
$rsa = [Security.Cryptography.RSACryptoServiceProvider]::new(3072)
$rsa.PersistKeyInCsp = $false
try {
    $privateBytes = [Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true))
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($privateBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($KeyPath, $protected)
    } finally { [Array]::Clear($privateBytes, 0, $privateBytes.Length) }
    $publicXml = $rsa.ToXmlString($false)
    $source = '// Public release-verification key. The private key is never shipped.' + "`n" +
        'internal static class UpdateTrust {' + "`n" +
        '    public const string PublicKeyXml = @"' + $publicXml + '";' + "`n" + '}' + "`n"
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PublicSource))) -Force | Out-Null
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($PublicSource), $source, [Text.UTF8Encoding]::new($false))
    Write-Output 'Created a Windows-user-protected update key and its public verification source.'
    Write-Output 'This authenticates BAR Fight updates; it is not a Windows publisher certificate.'
} finally { $rsa.Dispose() }
