$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$installer = Join-Path $repoRoot 'install.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("agentic-cleanup-installer-test-{0}" -f [guid]::NewGuid())
$fixtureUrl = 'https://agentic-cleanup.test'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

function ConvertTo-MsysPath([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -notmatch '^([A-Za-z]):\\(.*)$') { throw "Cannot convert path to MSYS format: $Path" }
    '/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2].Replace('\', '/')
}

function Invoke-GitBash([string]$GitBash, [string]$Command) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GitBash
    $startInfo.Arguments = '-lc "' + $Command.Replace('"', '\"') + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
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
foreach ($name in @('AGENTIC_CLEANUP_REPO_URL', 'AGENTIC_CLEANUP_RUNTIME', 'CLAUDE_CONFIG_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    $env:AGENTIC_CLEANUP_REPO_URL = $fixtureUrl
    $env:CLAUDE_CONFIG_DIR = Join-Path $testRoot 'claude'
    $env:XDG_CONFIG_HOME = Join-Path $testRoot 'config'
    $env:XDG_DATA_HOME = Join-Path $testRoot 'data'
    $env:AGENTIC_CLEANUP_RUNTIME = 'all'

    & { . $installer }

    $dataDir = Join-Path $env:XDG_DATA_HOME 'agentic-cleanup'
    $claudeCommand = Join-Path $env:CLAUDE_CONFIG_DIR 'commands\cleanup.md'
    $openCodeCommand = Join-Path $env:XDG_CONFIG_HOME 'opencode\commands\cleanup.md'
    $claudeSkill = Join-Path $env:CLAUDE_CONFIG_DIR 'skills\agentic-cleanup\SKILL.md'
    $openCodeSkill = Join-Path $env:XDG_CONFIG_HOME 'opencode\skills\agentic-cleanup\SKILL.md'
    Assert-True (Test-Path -LiteralPath $claudeCommand -PathType Leaf) 'PowerShell installer publishes the Claude Code command'
    Assert-True (Test-Path -LiteralPath $openCodeCommand -PathType Leaf) 'PowerShell installer publishes the OpenCode command'
    Assert-True (Test-Path -LiteralPath $claudeSkill -PathType Leaf) 'PowerShell installer publishes the Claude Code skill'
    Assert-True (Test-Path -LiteralPath $openCodeSkill -PathType Leaf) 'PowerShell installer publishes the OpenCode skill'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataDir 'install-manifest.sha256') -PathType Leaf) 'PowerShell installer publishes the shared manifest'
    Assert-True ((Get-FileHash -LiteralPath $claudeCommand).Hash -eq (Get-FileHash -LiteralPath $openCodeCommand).Hash) 'PowerShell runtime command copies are byte-identical'

    $env:AGENTIC_CLEANUP_RUNTIME = 'opencode'
    $claudeTimestamp = [datetime]'2001-01-01T00:00:00Z'
    (Get-Item -LiteralPath $claudeCommand).LastWriteTimeUtc = $claudeTimestamp
    (Get-Item -LiteralPath $claudeSkill).LastWriteTimeUtc = $claudeTimestamp
    $claudeTimestamp = (Get-Item -LiteralPath $claudeCommand).LastWriteTimeUtc
    $claudeSkillTimestamp = (Get-Item -LiteralPath $claudeSkill).LastWriteTimeUtc
    & { . $installer }
    Assert-True ((Get-Item -LiteralPath $claudeCommand).LastWriteTimeUtc -eq $claudeTimestamp) 'Same-release OpenCode-only transition does not rewrite Claude Code'
    Assert-True ((Get-Item -LiteralPath $claudeSkill).LastWriteTimeUtc -eq $claudeSkillTimestamp) 'Same-release OpenCode-only transition does not rewrite the Claude Code skill'

    [IO.File]::WriteAllText($claudeCommand, 'stale-claude-command', [Text.UTF8Encoding]::new($false))
    $payloadHashBeforeRefusal = (Get-FileHash -LiteralPath (Join-Path $dataDir 'cleanup.md')).Hash
    try {
        & { . $installer }
        throw 'FAIL: PowerShell installer allowed a stale unselected Claude command'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: PowerShell installer allowed a stale unselected Claude command') { throw }
        Assert-True ($_.Exception.Message -like 'Refusing to leave a stale Claude Code command:*') 'OpenCode-only upgrade rejects a stale Claude command'
    }
    Assert-True (([IO.File]::ReadAllText($claudeCommand)) -eq 'stale-claude-command') 'Rejected upgrade does not modify the stale Claude command'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $dataDir 'cleanup.md')).Hash -eq $payloadHashBeforeRefusal) 'Rejected upgrade does not modify the shared payload'

    $env:AGENTIC_CLEANUP_RUNTIME = 'all'
    & { . $installer }
    $env:AGENTIC_CLEANUP_RUNTIME = 'opencode'
    [IO.File]::WriteAllText($claudeSkill, 'stale-claude-skill', [Text.UTF8Encoding]::new($false))
    $skillPayloadHashBeforeRefusal = (Get-FileHash -LiteralPath (Join-Path $dataDir 'skills\agentic-cleanup\SKILL.md')).Hash
    try {
        & { . $installer }
        throw 'FAIL: PowerShell installer allowed a stale unselected Claude skill'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: PowerShell installer allowed a stale unselected Claude skill') { throw }
        Assert-True ($_.Exception.Message -like 'Refusing to leave a stale Claude Code skill:*') 'OpenCode-only upgrade rejects a stale Claude skill'
    }
    Assert-True (([IO.File]::ReadAllText($claudeSkill)) -eq 'stale-claude-skill') 'Rejected upgrade does not modify the stale Claude skill'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $dataDir 'skills\agentic-cleanup\SKILL.md')).Hash -eq $skillPayloadHashBeforeRefusal) 'Rejected upgrade does not modify the shared skill payload'

    $openCodeOnlyRoot = Join-Path $testRoot 'opencode-only'
    $env:CLAUDE_CONFIG_DIR = Join-Path $openCodeOnlyRoot 'claude'
    $env:XDG_CONFIG_HOME = Join-Path $openCodeOnlyRoot 'config'
    $env:XDG_DATA_HOME = Join-Path $openCodeOnlyRoot 'data'
    $env:AGENTIC_CLEANUP_RUNTIME = 'opencode'
    $untouchedClaudeCommand = Join-Path $env:CLAUDE_CONFIG_DIR 'commands\cleanup.md'
    $untouchedClaudeSkill = Join-Path $env:CLAUDE_CONFIG_DIR 'skills\agentic-cleanup\SKILL.md'
    & { . $installer }
    $openCodeOnlyCommand = Join-Path $env:XDG_CONFIG_HOME 'opencode\commands\cleanup.md'
    $openCodeOnlySkill = Join-Path $env:XDG_CONFIG_HOME 'opencode\skills\agentic-cleanup\SKILL.md'
    $openCodeOnlyState = Join-Path $env:XDG_DATA_HOME 'agentic-cleanup\installed-runtimes'
    Assert-True (-not (Test-Path -LiteralPath $untouchedClaudeCommand)) 'OpenCode-only installation does not create a Claude Code command'
    Assert-True (-not (Test-Path -LiteralPath $untouchedClaudeSkill)) 'OpenCode-only installation does not create a Claude Code skill'
    Assert-True (Test-Path -LiteralPath $openCodeOnlyCommand -PathType Leaf) 'OpenCode-only installation publishes the OpenCode command'
    Assert-True (Test-Path -LiteralPath $openCodeOnlySkill -PathType Leaf) 'OpenCode-only installation publishes the OpenCode skill'
    Assert-True (-not (Test-Path -LiteralPath $openCodeOnlyState)) 'Installation does not rely on mutable runtime-selection state'

    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    Assert-True (Test-Path -LiteralPath $gitBash -PathType Leaf) 'Git Bash is available for shell installer integration tests'
    $bashRoot = Join-Path $testRoot 'bash'
    $bashFixture = Join-Path $bashRoot 'source'
    foreach ($line in Get-Content -LiteralPath (Join-Path $repoRoot 'install-manifest.sha256')) {
        $relative = $line.Substring(66)
        $source = Join-Path $repoRoot ($relative -replace '/', '\')
        $destination = Join-Path $bashFixture ($relative -replace '/', '\')
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        $text = [IO.File]::ReadAllText($source).TrimStart([char]0xFEFF).Replace("`r`n", "`n").Replace("`r", "`n")
        [IO.File]::WriteAllText($destination, $text, [Text.UTF8Encoding]::new($false))
    }
    $manifestText = [IO.File]::ReadAllText((Join-Path $repoRoot 'install-manifest.sha256')).Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText((Join-Path $bashFixture 'install-manifest.sha256'), $manifestText, [Text.UTF8Encoding]::new($false))
    $bashInstaller = Join-Path $bashRoot 'install.sh'
    $installerText = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.sh')).Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($bashInstaller, $installerText, [Text.UTF8Encoding]::new($false))
    $bashPath = ConvertTo-MsysPath $bashRoot
    $bashFixtureUrl = 'file:///' + $bashFixture.Replace('\', '/')
    $bashEnvironment = "AGENTIC_CLEANUP_REPO_URL='$bashFixtureUrl' CLAUDE_CONFIG_DIR='$bashPath/claude' XDG_CONFIG_HOME='$bashPath/config' XDG_DATA_HOME='$bashPath/data' TMPDIR='$bashPath'"
    $bashResult = Invoke-GitBash $gitBash "$bashEnvironment AGENTIC_CLEANUP_RUNTIME=opencode '$bashPath/install.sh'"
    if ($bashResult.ExitCode -ne 0) { throw "FAIL: Git Bash OpenCode-only installation exited $($bashResult.ExitCode): $($bashResult.Stderr)" }
    $bashClaudeCommand = Join-Path $bashRoot 'claude\commands\cleanup.md'
    $bashClaudeSkill = Join-Path $bashRoot 'claude\skills\agentic-cleanup\SKILL.md'
    $bashOpenCodeCommand = Join-Path $bashRoot 'config\opencode\commands\cleanup.md'
    $bashOpenCodeSkill = Join-Path $bashRoot 'config\opencode\skills\agentic-cleanup\SKILL.md'
    $bashDataPayload = Join-Path $bashRoot 'data\agentic-cleanup\cleanup.md'
    $bashDataSkill = Join-Path $bashRoot 'data\agentic-cleanup\skills\agentic-cleanup\SKILL.md'
    Assert-True (-not (Test-Path -LiteralPath $bashClaudeCommand)) 'Git Bash OpenCode-only installation does not create a Claude command'
    Assert-True (-not (Test-Path -LiteralPath $bashClaudeSkill)) 'Git Bash OpenCode-only installation does not create a Claude skill'
    Assert-True (Test-Path -LiteralPath $bashOpenCodeCommand -PathType Leaf) 'Git Bash OpenCode-only installation publishes the OpenCode command'
    Assert-True (Test-Path -LiteralPath $bashOpenCodeSkill -PathType Leaf) 'Git Bash OpenCode-only installation publishes the OpenCode skill'

    $bashResult = Invoke-GitBash $gitBash "$bashEnvironment AGENTIC_CLEANUP_RUNTIME=all '$bashPath/install.sh'"
    if ($bashResult.ExitCode -ne 0) { throw "FAIL: Git Bash all-runtime installation exited $($bashResult.ExitCode): $($bashResult.Stderr)" }
    $installedSkill = [IO.File]::ReadAllText($bashOpenCodeSkill)
    $preambleMatch = [regex]::Match($installedSkill, '(?s)```bash\r?\n(.*?)\r?\n```')
    Assert-True $preambleMatch.Success 'Installed skill exposes its integrity preamble'
    $guardScript = Join-Path $bashRoot 'verify.sh'
    [IO.File]::WriteAllText($guardScript, ($preambleMatch.Groups[1].Value.Replace("`r`n", "`n").Replace("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Join-Path $bashRoot 'work')) | Out-Null
    $guardCommand = "cd '$bashPath/work' && CLAUDE_CONFIG_DIR='$bashPath/claude' XDG_CONFIG_HOME='$bashPath/config' XDG_DATA_HOME='$bashPath/data' '$bashPath/verify.sh'"
    $bashResult = Invoke-GitBash $gitBash $guardCommand
    if ($bashResult.ExitCode -ne 0) { throw "FAIL: Installed command integrity preamble exited $($bashResult.ExitCode): $($bashResult.Stderr)" }
    [IO.File]::WriteAllText($bashClaudeCommand, 'stale-claude-command', [Text.UTF8Encoding]::new($false))
    $bashPayloadHash = (Get-FileHash -LiteralPath $bashDataPayload).Hash
    $bashResult = Invoke-GitBash $gitBash $guardCommand
    Assert-True ($bashResult.ExitCode -ne 0) 'Installed command rejects any stale existing runtime copy'
    $bashResult = Invoke-GitBash $gitBash "$bashEnvironment AGENTIC_CLEANUP_RUNTIME=opencode '$bashPath/install.sh'"
    Assert-True ($bashResult.ExitCode -ne 0) 'Git Bash OpenCode-only upgrade rejects a stale Claude command'
    Assert-True ((Get-FileHash -LiteralPath $bashDataPayload).Hash -eq $bashPayloadHash) 'Rejected Git Bash upgrade does not modify the shared payload'

    $bashResult = Invoke-GitBash $gitBash "$bashEnvironment AGENTIC_CLEANUP_RUNTIME=all '$bashPath/install.sh'"
    if ($bashResult.ExitCode -ne 0) { throw "FAIL: Git Bash reinstall before skill-staleness test exited $($bashResult.ExitCode): $($bashResult.Stderr)" }
    [IO.File]::WriteAllText($bashClaudeSkill, 'stale-claude-skill', [Text.UTF8Encoding]::new($false))
    $bashSkillHash = (Get-FileHash -LiteralPath $bashDataSkill).Hash
    $bashResult = Invoke-GitBash $gitBash $guardCommand
    Assert-True ($bashResult.ExitCode -ne 0) 'Installed skill rejects any stale existing runtime skill copy'
    $bashResult = Invoke-GitBash $gitBash "$bashEnvironment AGENTIC_CLEANUP_RUNTIME=opencode '$bashPath/install.sh'"
    Assert-True ($bashResult.ExitCode -ne 0) 'Git Bash OpenCode-only upgrade rejects a stale Claude skill'
    Assert-True ((Get-FileHash -LiteralPath $bashDataSkill).Hash -eq $bashSkillHash) 'Rejected Git Bash upgrade does not modify the shared skill payload'

    $env:AGENTIC_CLEANUP_RUNTIME = 'invalid'
    try {
        & { . $installer }
        throw 'FAIL: PowerShell installer accepted an invalid runtime selector'
    } catch {
        Assert-True ($_.Exception.Message -like 'Invalid AGENTIC_CLEANUP_RUNTIME:*') 'PowerShell installer rejects an invalid runtime selector'
    }

    $manifestLines = @(Get-Content -LiteralPath (Join-Path $repoRoot 'install-manifest.sha256'))
    $script:manifestOverride = @($manifestLines[0..($manifestLines.Count - 2)]) + ($manifestLines[0] -replace '  cleanup\.md$', '  Cleanup.md')
    $caseRoot = Join-Path $testRoot 'case-inventory'
    $env:CLAUDE_CONFIG_DIR = Join-Path $caseRoot 'claude'
    $env:XDG_CONFIG_HOME = Join-Path $caseRoot 'config'
    $env:XDG_DATA_HOME = Join-Path $caseRoot 'data'
    $env:AGENTIC_CLEANUP_RUNTIME = 'all'
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
