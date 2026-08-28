$ErrorActionPreference = 'Stop'

$RepoUrl = if ($env:AGENTIC_CLEANUP_REPO_URL) { $env:AGENTIC_CLEANUP_REPO_URL } else { 'https://raw.githubusercontent.com/zhiganov/agentic-cleanup/master' }
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
$OpenCodeDir = Join-Path $configHome 'opencode'
$dataHome = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local\share' }
$DataDir = if ($env:AGENTIC_CLEANUP_DATA_DIR) { $env:AGENTIC_CLEANUP_DATA_DIR } else { Join-Path $dataHome 'agentic-cleanup' }
$Runtime = if ($env:AGENTIC_CLEANUP_RUNTIME) { $env:AGENTIC_CLEANUP_RUNTIME } else { 'all' }
if ($Runtime -notin @('all', 'claude', 'opencode')) { throw "Invalid AGENTIC_CLEANUP_RUNTIME: $Runtime (expected all, claude, or opencode)" }
$installClaude = $Runtime -in @('all', 'claude')
$installOpenCode = $Runtime -in @('all', 'opencode')

Write-Host 'Installing agentic-cleanup...'

$stage = Join-Path ([IO.Path]::GetTempPath()) ('agentic-cleanup-install-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path "$stage\scripts\windows\cleanup", "$stage\scripts\cleanup\schemas", "$stage\scripts\cleanup\policies" | Out-Null
try {
  Invoke-WebRequest -Uri "$RepoUrl/cleanup.md" -OutFile "$stage\cleanup.md"

  $scripts = @('wt_lookup.py','find_targets.py','assert_list.py','live_paths.ps1','diskspace.ps1','run_wiztree.ps1','squirrel.ps1',
               'appdata_orphans.ps1','winsdk.ps1','vs_orphans.ps1','scrub.ps1','scan.ps1','execute-plan.ps1','README.md')
  foreach ($f in $scripts) {
    Invoke-WebRequest -Uri "$RepoUrl/scripts/windows/cleanup/$f" -OutFile "$stage\scripts\windows\cleanup\$f"
  }

  $contracts = @('Cleanup.Contracts.psm1','build-plan.ps1','validate-plan.ps1','render-scan.ps1','README.md',
                 'schemas/scan.schema.json','schemas/plan.schema.json','schemas/result.schema.json','policies/windows.v1.json')
  foreach ($f in $contracts) {
    $destination = Join-Path "$stage\scripts\cleanup" ($f -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Invoke-WebRequest -Uri "$RepoUrl/scripts/cleanup/$f" -OutFile $destination
  }

  Invoke-WebRequest -Uri "$RepoUrl/install-manifest.sha256" -OutFile "$stage\install-manifest.sha256"
  $expectedPaths = @('cleanup.md') + @($scripts | ForEach-Object { "scripts/windows/cleanup/$_" }) + @($contracts | ForEach-Object { "scripts/cleanup/$_" })
  $manifestLines = @(Get-Content -LiteralPath "$stage\install-manifest.sha256")
  if ($manifestLines.Count -ne $expectedPaths.Count) { throw 'Cleanup install manifest inventory is incomplete' }
  $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($line in $manifestLines) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Invalid cleanup manifest line: $line" }
    $installPath = $Matches[2]
    if ($expectedPaths -cnotcontains $installPath -or -not $seenPaths.Add($installPath)) { throw "Invalid cleanup manifest inventory path: $installPath" }
    $file = Join-Path $stage ($installPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1]) {
      throw "Cleanup install manifest mismatch: $installPath"
    }
  }

  $claudeCommand = Join-Path $ClaudeDir 'commands\cleanup.md'
  $openCodeCommand = Join-Path $OpenCodeDir 'commands\cleanup.md'
  $protectedTargets = @(
    $DataDir, "$DataDir\cleanup.md", "$DataDir\install-manifest.sha256", "$DataDir\installed-runtimes",
    "$DataDir\scripts", "$DataDir\scripts\windows", "$DataDir\scripts\windows\cleanup",
    "$DataDir\scripts\cleanup", "$DataDir\scripts\cleanup\schemas", "$DataDir\scripts\cleanup\policies",
    $claudeCommand, $openCodeCommand
  )
  if ($installClaude) { $protectedTargets += @($ClaudeDir, (Split-Path -Parent $claudeCommand)) }
  if ($installOpenCode) { $protectedTargets += @($OpenCodeDir, (Split-Path -Parent $openCodeCommand)) }
  foreach ($target in $protectedTargets) {
    if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing to overwrite cleanup install reparse point: $target"
    }
  }

  $stagedPayloadHash = (Get-FileHash -LiteralPath "$stage\cleanup.md" -Algorithm SHA256).Hash
  foreach ($unselectedCommand in @(
    [pscustomobject]@{ Selected = $installClaude; Path = $claudeCommand; Runtime = 'Claude Code' },
    [pscustomobject]@{ Selected = $installOpenCode; Path = $openCodeCommand; Runtime = 'OpenCode' }
  )) {
    if (-not $unselectedCommand.Selected -and (Test-Path -LiteralPath $unselectedCommand.Path) -and
        (Get-FileHash -LiteralPath $unselectedCommand.Path -Algorithm SHA256).Hash -ne $stagedPayloadHash) {
      throw "Refusing to leave a stale $($unselectedCommand.Runtime) command: $($unselectedCommand.Path). Install all runtimes or remove that command first."
    }
  }

  New-Item -ItemType Directory -Force -Path "$DataDir\scripts\windows\cleanup", "$DataDir\scripts\cleanup" | Out-Null
  Copy-Item -LiteralPath "$stage\cleanup.md" -Destination "$DataDir\cleanup.md" -Force
  Copy-Item -Path "$stage\scripts\windows\cleanup\*" -Destination "$DataDir\scripts\windows\cleanup" -Recurse -Force
  Copy-Item -Path "$stage\scripts\cleanup\*" -Destination "$DataDir\scripts\cleanup" -Recurse -Force
  $payloadHash = (Get-FileHash -LiteralPath "$DataDir\cleanup.md" -Algorithm SHA256).Hash
  if ($installClaude) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $claudeCommand) | Out-Null
    Copy-Item -LiteralPath "$stage\cleanup.md" -Destination $claudeCommand -Force
    if ((Get-FileHash -LiteralPath $claudeCommand -Algorithm SHA256).Hash -ne $payloadHash) { throw 'Claude Code command copy does not match the verified shared payload' }
    Write-Host "Installed /cleanup for Claude Code -> $claudeCommand"
  }
  if ($installOpenCode) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $openCodeCommand) | Out-Null
    Copy-Item -LiteralPath "$stage\cleanup.md" -Destination $openCodeCommand -Force
    if ((Get-FileHash -LiteralPath $openCodeCommand -Algorithm SHA256).Hash -ne $payloadHash) { throw 'OpenCode command copy does not match the verified shared payload' }
    Write-Host "Installed /cleanup for OpenCode V2 -> $openCodeCommand"
  }
  Remove-Item -LiteralPath "$DataDir\installed-runtimes" -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath "$stage\install-manifest.sha256" -Destination "$DataDir\install-manifest.sha256" -Force
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Installed verified shared payload -> $DataDir"
