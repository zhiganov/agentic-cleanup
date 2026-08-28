$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$installer = Join-Path $repoRoot 'install.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentic-cleanup-installer-test-{0}" -f [guid]::NewGuid())
$fixtureUrl = 'https://agentic-cleanup.test'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

function Invoke-WebRequest {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile)
    if (-not $Uri.StartsWith("$fixtureUrl/", [StringComparison]::Ordinal)) { throw "Unexpected fixture URL: $Uri" }
    $relative = $Uri.Substring($fixtureUrl.Length + 1) -replace '/', '\'
    if ($relative -eq 'install-manifest.sha256' -and $script:manifestOverride) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $OutFile)) | Out-Null
        [IO.File]::WriteAllLines($OutFile, $script:manifestOverride, [Text.UTF8Encoding]::new($false))
        return
    }
    $source = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing fixture source: $relative" }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $OutFile)) | Out-Null
    $text = [IO.File]::ReadAllText($source).TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($OutFile, $text, [Text.UTF8Encoding]::new($false))
}

$savedEnvironment = @{}
foreach ($name in @('AGENTIC_CLEANUP_REPO_URL', 'CLAUDE_CONFIG_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    $env:AGENTIC_CLEANUP_REPO_URL = $fixtureUrl
    $env:CLAUDE_CONFIG_DIR = Join-Path $testRoot 'claude'
    $env:XDG_CONFIG_HOME = Join-Path $testRoot 'config'
    $env:XDG_DATA_HOME = Join-Path $testRoot 'data'

    & { . $installer }

    $dataDir = Join-Path $env:XDG_DATA_HOME 'agentic-cleanup'
    $claudeCommand = Join-Path $env:CLAUDE_CONFIG_DIR 'commands\cleanup.md'
    $openCodeCommand = Join-Path $env:XDG_CONFIG_HOME 'opencode\commands\cleanup.md'
    Assert-True (Test-Path -LiteralPath $claudeCommand -PathType Leaf) 'PowerShell installer publishes the Claude Code command'
    Assert-True (Test-Path -LiteralPath $openCodeCommand -PathType Leaf) 'PowerShell installer publishes the OpenCode command'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataDir 'install-manifest.sha256') -PathType Leaf) 'PowerShell installer publishes the shared manifest'
    Assert-True ((Get-FileHash -LiteralPath $claudeCommand).Hash -eq (Get-FileHash -LiteralPath $openCodeCommand).Hash) 'PowerShell runtime command copies are byte-identical'

    $manifestLines = @(Get-Content -LiteralPath (Join-Path $repoRoot 'install-manifest.sha256'))
    $script:manifestOverride = @($manifestLines[0..($manifestLines.Count - 2)]) + ($manifestLines[0] -replace '  cleanup\.md$', '  Cleanup.md')
    $caseRoot = Join-Path $testRoot 'case-inventory'
    $env:CLAUDE_CONFIG_DIR = Join-Path $caseRoot 'claude'
    $env:XDG_CONFIG_HOME = Join-Path $caseRoot 'config'
    $env:XDG_DATA_HOME = Join-Path $caseRoot 'data'
    try {
        & { . $installer }
        throw 'FAIL: PowerShell installer accepted a case-variant duplicate manifest path'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: PowerShell installer accepted a case-variant duplicate manifest path') { throw }
        if ($_.Exception.Message -notlike 'Invalid cleanup manifest inventory path:*') { throw }
        Write-Output 'PASS: PowerShell installer rejects a case-variant duplicate manifest path'
    } finally {
        $script:manifestOverride = $null
    }

    $guardRoot = Join-Path $testRoot 'guard'
    $external = Join-Path $testRoot 'external-scripts'
    $guardData = Join-Path $guardRoot 'data\agentic-cleanup'
    [IO.Directory]::CreateDirectory($external) | Out-Null
    [IO.Directory]::CreateDirectory($guardData) | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $guardData 'scripts') -Target $external | Out-Null
    $env:CLAUDE_CONFIG_DIR = Join-Path $guardRoot 'claude'
    $env:XDG_CONFIG_HOME = Join-Path $guardRoot 'config'
    $env:XDG_DATA_HOME = Join-Path $guardRoot 'data'
    try {
        & { . $installer }
        throw 'FAIL: PowerShell installer followed a nested data reparse point'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: PowerShell installer followed a nested data reparse point') { throw }
        if ($_.Exception.Message -notlike 'Refusing to overwrite cleanup install reparse point:*\scripts') { throw }
        Write-Output 'PASS: PowerShell installer rejects a nested data reparse point'
    }
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup installer integration tests passed.'
