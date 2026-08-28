$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$manifestPath = Join-Path $repoRoot 'install-manifest.sha256'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

function Get-NormalizedDigest([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Resolve-Source([string]$InstallPath) {
    if ($InstallPath -eq 'commands/cleanup.md') { return Join-Path $repoRoot '.claude\commands\cleanup.md' }
    if ($InstallPath.StartsWith('cleanup-scripts/')) {
        return Join-Path $repoRoot ('scripts\windows\cleanup\' + $InstallPath.Substring('cleanup-scripts/'.Length))
    }
    if ($InstallPath.StartsWith('cleanup-contracts/')) {
        return Join-Path $repoRoot ('scripts\cleanup\' + $InstallPath.Substring('cleanup-contracts/'.Length))
    }
    throw "Unknown install path: $InstallPath"
}

$entries = foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Invalid manifest line: $line" }
    [ordered]@{ digest = $Matches[1]; installPath = $Matches[2]; sourcePath = Resolve-Source $Matches[2] }
}

Assert-True (@($entries).Count -eq 24) 'Install manifest lists every command, helper, contract, schema, and policy file'
foreach ($entry in $entries) {
    Assert-True (Test-Path -LiteralPath $entry.sourcePath) "Manifest source exists: $($entry.installPath)"
    Assert-True ((Get-NormalizedDigest $entry.sourcePath) -eq $entry.digest) "Manifest digest matches: $($entry.installPath)"
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-install-manifest-{0}" -f [guid]::NewGuid())
try {
    foreach ($entry in $entries) {
        $destination = Join-Path $stage ($entry.installPath -replace '/', '\')
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        $normalized = [IO.File]::ReadAllText($entry.sourcePath).TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
        [IO.File]::WriteAllText($destination, $normalized, [Text.UTF8Encoding]::new($false))
    }
    $allMatch = @($entries | Where-Object { (Get-FileHash -LiteralPath (Join-Path $stage ($_.installPath -replace '/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $_.digest }).Count -eq 0
    Assert-True $allMatch 'A complete staged installation matches the release manifest'
    Add-Content -LiteralPath (Join-Path $stage 'cleanup-scripts\scan.ps1') -Value 'interrupted-copy'
    $tamperDetected = (Get-FileHash -LiteralPath (Join-Path $stage 'cleanup-scripts\scan.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() -ne ($entries | Where-Object installPath -eq 'cleanup-scripts/scan.ps1').digest
    Assert-True $tamperDetected 'An interrupted or mixed helper set fails manifest verification'
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup install-manifest tests passed.'
