$ErrorActionPreference = 'Stop'

$RepoUrl = "https://raw.githubusercontent.com/zhiganov/claude-cleanup/master"
$ClaudeDir = "$env:USERPROFILE\.claude"

Write-Host "Installing claude-cleanup..."

$stage = Join-Path $ClaudeDir ('.cleanup-install-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path "$stage\commands", "$stage\cleanup-scripts", "$stage\cleanup-contracts\schemas", "$stage\cleanup-contracts\policies" | Out-Null
try {
  Invoke-WebRequest -Uri "$RepoUrl/.claude/commands/cleanup.md" -OutFile "$stage\commands\cleanup.md"

# Windows helper scripts used by the scan/delete steps. The command resolves
# these from ~/.claude/cleanup-scripts/ when present.
$scripts = @('wt_lookup.py','find_targets.py','assert_list.py','live_paths.ps1','diskspace.ps1','run_wiztree.ps1','squirrel.ps1',
             'appdata_orphans.ps1','winsdk.ps1','vs_orphans.ps1','scrub.ps1','scan.ps1','execute-plan.ps1','README.md')
foreach ($f in $scripts) {
  Invoke-WebRequest -Uri "$RepoUrl/scripts/windows/cleanup/$f" -OutFile "$stage\cleanup-scripts\$f"
}

# Structured cleanup contracts. PowerShell 7 is required only for the opt-in
# --structured-preview path while category migration is in progress.
$contractDir = "$stage\cleanup-contracts"
$contracts = @('Cleanup.Contracts.psm1','build-plan.ps1','validate-plan.ps1','render-scan.ps1','README.md',
               'schemas/scan.schema.json','schemas/plan.schema.json','schemas/result.schema.json',
               'policies/windows.v1.json')
foreach ($f in $contracts) {
  $destination = Join-Path $contractDir ($f -replace '/', '\')
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Invoke-WebRequest -Uri "$RepoUrl/scripts/cleanup/$f" -OutFile $destination
}
  Invoke-WebRequest -Uri "$RepoUrl/install-manifest.sha256" -OutFile "$stage\cleanup-manifest.sha256"
  foreach ($line in Get-Content -LiteralPath "$stage\cleanup-manifest.sha256") {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Invalid cleanup manifest line: $line" }
    $file = Join-Path $stage ($Matches[2] -replace '/', '\')
    if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1]) {
      throw "Cleanup install manifest mismatch: $($Matches[2])"
    }
  }

  # Install the command first and the verified manifest last. The new command
  # refuses to run if this copy sequence is interrupted.
  foreach ($target in @("$ClaudeDir\cleanup-scripts", "$ClaudeDir\cleanup-contracts")) {
    if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing to overwrite cleanup install reparse point: $target"
    }
  }
  New-Item -ItemType Directory -Force -Path "$ClaudeDir\commands", "$ClaudeDir\cleanup-scripts", "$ClaudeDir\cleanup-contracts" | Out-Null
  Copy-Item -LiteralPath "$stage\commands\cleanup.md" -Destination "$ClaudeDir\commands\cleanup.md" -Force
  Copy-Item -Path "$stage\cleanup-scripts\*" -Destination "$ClaudeDir\cleanup-scripts" -Recurse -Force
  Copy-Item -Path "$stage\cleanup-contracts\*" -Destination "$ClaudeDir\cleanup-contracts" -Recurse -Force
  Copy-Item -LiteralPath "$stage\cleanup-manifest.sha256" -Destination "$ClaudeDir\cleanup-manifest.sha256" -Force
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Installed cleanup.md -> ~/.claude/commands/"
Write-Host "Installed Windows helper scripts -> ~/.claude/cleanup-scripts/"
Write-Host "Installed structured contracts -> ~/.claude/cleanup-contracts/"

Write-Host ""
Write-Host "Installation complete! Use /cleanup in Claude Code to get started."
