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
    if ($InstallPath -eq 'cleanup.md') { return Join-Path $repoRoot 'cleanup.md' }
    if ($InstallPath -eq 'skills/agentic-cleanup/SKILL.md') { return Join-Path $repoRoot 'skills\agentic-cleanup\SKILL.md' }
    if ($InstallPath.StartsWith('scripts/windows/cleanup/')) {
        return Join-Path $repoRoot ($InstallPath -replace '/', '\')
    }
    if ($InstallPath.StartsWith('scripts/cleanup/')) {
        return Join-Path $repoRoot ($InstallPath -replace '/', '\')
    }
    throw "Unknown install path: $InstallPath"
}

$commandText = [IO.File]::ReadAllText((Join-Path $repoRoot 'cleanup.md'))
$positionPlaceholder = [regex]'\$(\d+)'
Assert-True (([regex]::Matches($commandText, '\$ARGUMENTS')).Count -eq 1) 'Thin command forwards the complete argument string exactly once'
Assert-True (-not $positionPlaceholder.IsMatch($commandText)) 'Command template contains no OpenCode positional placeholder collisions'
Assert-True ($commandText.Length -lt 300) 'Command template stays thin enough not to dump the workflow into chat'
Assert-True ($commandText.Contains('`agentic-cleanup` skill')) 'Command delegates to the installed cleanup skill'
$sampleArguments = '--dry-run'
$renderedCommand = $commandText.Replace('$ARGUMENTS', $sampleArguments)
Assert-True ($renderedCommand.Contains($sampleArguments)) 'OpenCode rendering forwards command arguments intact'

$skillText = [IO.File]::ReadAllText((Join-Path $repoRoot 'skills\agentic-cleanup\SKILL.md'))
Assert-True ($skillText.Contains('name: agentic-cleanup')) 'Cleanup skill declares its discoverable name'
Assert-True ($skillText.Contains('# Developer Workstation Disk Cleanup')) 'Cleanup skill owns the full workflow'
Assert-True ($skillText.Contains('manifest_paths=(')) 'Cleanup skill retains the installed integrity preamble'

$entries = foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Invalid manifest line: $line" }
    [ordered]@{ digest = $Matches[1]; installPath = $Matches[2]; sourcePath = Resolve-Source $Matches[2] }
}

Assert-True (@($entries).Count -eq 26) 'Install manifest lists every command, skill, helper, contract, schema, and policy file'
Assert-True (@($entries.installPath | Sort-Object -Unique).Count -eq 26) 'Install manifest inventory has no duplicate paths'
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
    Add-Content -LiteralPath (Join-Path $stage 'scripts\windows\cleanup\scan.ps1') -Value 'interrupted-copy'
    $tamperDetected = (Get-FileHash -LiteralPath (Join-Path $stage 'scripts\windows\cleanup\scan.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() -ne ($entries | Where-Object installPath -eq 'scripts/windows/cleanup/scan.ps1').digest
    Assert-True $tamperDetected 'An interrupted or mixed helper set fails manifest verification'

    $partialEntries = @($entries | Select-Object -Skip 1)
    Assert-True ($partialEntries.Count -ne $entries.Count) 'A truncated manifest fails the complete-inventory requirement'
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$shellInstaller = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.sh'))
$powerShellInstaller = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.ps1'))
foreach ($installer in @($shellInstaller, $powerShellInstaller)) {
    Assert-True ($installer.Contains('zhiganov/agentic-cleanup')) 'Installer fetches the renamed repository'
    Assert-True ($installer.Contains('opencode')) 'Installer publishes an OpenCode command copy'
    Assert-True ($installer.Contains('skills/agentic-cleanup')) 'Installer publishes the cleanup skill'
    Assert-True ($installer.Contains('agentic-cleanup')) 'Installer publishes an agent-neutral shared payload'
}

Write-Output 'All cleanup install-manifest tests passed.'
