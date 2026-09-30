param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$file = (Get-Item -LiteralPath $FilePath).FullName
$tool = (Get-Item -LiteralPath $config.signTool).FullName
if ([IO.Path]::GetFileName($tool) -ine 'signtool.exe') { throw 'Configure Microsoft SignTool.' }
$timestamp = [Uri]$config.timestampUrl
if ($timestamp.Scheme -notin @('http','https') -or -not $timestamp.IsAbsoluteUri -or $timestamp.UserInfo) { throw 'Configure a public RFC3161 timestamp URL.' }
$arguments = @('sign','/fd','SHA256','/tr',$timestamp.AbsoluteUri,'/td','SHA256','/d','BAR Fight','/du','https://bar-fight.com/')
if ($config.provider -eq 'certificate-store') {
    if ($config.thumbprint -notmatch '^[0-9A-Fa-f]{40}$') { throw 'Configure the exact code-signing certificate thumbprint.' }
    $arguments += @('/sha1',$config.thumbprint,'/s','My')
    if ($config.localMachine -eq $true) { $arguments += '/sm' }
} elseif ($config.provider -eq 'artifact-signing') {
    $dll = (Get-Item -LiteralPath $config.dlib).FullName
    $metadata = (Get-Item -LiteralPath $config.metadataFile).FullName
    $arguments += @('/dlib',$dll,'/dmdf',$metadata)
} else { throw 'Use certificate-store or artifact-signing as the provider.' }
& $tool @arguments $file
if ($LASTEXITCODE -ne 0) { throw ('Code signing failed: ' + [IO.Path]::GetFileName($file)) }
& $tool verify /pa /all /v $file
if ($LASTEXITCODE -ne 0) { throw 'Windows signature verification failed.' }
$signature = Get-AuthenticodeSignature -LiteralPath $file
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) {
    throw 'A trusted, timestamped Windows publisher signature is required.'
}
Write-Output ('Verified publisher signature: ' + $signature.SignerCertificate.Subject)
