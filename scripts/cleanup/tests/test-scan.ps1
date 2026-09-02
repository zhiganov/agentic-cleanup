$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cleanupRoot = Split-Path -Parent $PSScriptRoot
$scanner = Join-Path $repoRoot 'windows\cleanup\scan.ps1'
$helpers = Split-Path -Parent $scanner
$root = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-scan-test-{0}" -f [guid]::NewGuid())

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

function Assert-Fails([scriptblock]$Action, [string]$Message) {
    try { & $Action; throw "FAIL: $Message" } catch {
        if ($_.Exception.Message -eq "FAIL: $Message") { throw }
        Write-Output "PASS: $Message"
    }
}

function Add-TestFile([string]$Path, [int]$Bytes = 128) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllBytes($Path, [byte[]]::new($Bytes))
}

try {
    $workspace = Join-Path $root 'workspace'
    $local = Join-Path $root 'local-app-data'
    $temp = Join-Path $root 'temp'
    $configMsi = Join-Path $root 'Config.Msi'
    $windowsOld = Join-Path $root 'Windows.old'
    $fakeHome = Join-Path $root 'home'
    $output = Join-Path $root 'scan.json'
    $publishedHelpers = Join-Path $root 'published-helpers'
    Copy-Item -LiteralPath $helpers -Destination $publishedHelpers -Recurse
    $publishedReadme = Join-Path $publishedHelpers 'README.md'
    $readmeText = [IO.File]::ReadAllText($publishedReadme).Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText($publishedReadme, $readmeText.Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.claude')) | Out-Null
    Add-TestFile (Join-Path $local 'npm-cache\_cacache\content.bin')
    Add-TestFile (Join-Path $local 'npm-cache\_npx\server.bin')
    Add-TestFile (Join-Path $temp 'ordinary\cache.bin')
    Add-TestFile (Join-Path $temp 'claude\live.bin')
    Add-TestFile (Join-Path $temp 'opencode\live.bin')
    Add-TestFile (Join-Path $temp 'agentic-cleanup\scan.bin')
    Add-TestFile (Join-Path $temp 'claude-cleanup\legacy-scan.bin')
    $artifactFile = Join-Path $workspace 'project-a\.next\cache.bin'
    Add-TestFile $artifactFile
    (Get-Item -LiteralPath $artifactFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    Add-TestFile (Join-Path $configMsi 'rollback.bin')
    Add-TestFile (Join-Path $windowsOld 'windows.bin')
    Add-TestFile (Join-Path $workspace 'inactive-project\node_modules\package\index.js')
    Add-TestFile (Join-Path $workspace 'inactive-project\node_modules\package\node_modules\nested\index.js')
    Add-TestFile (Join-Path $workspace 'claude-mcp\node_modules\package\index.js')
    Add-TestFile (Join-Path $workspace 'claude-mcp\dist\server.js')
    Add-TestFile (Join-Path $workspace 'opencode-mcp\node_modules\package\index.js')
    Add-TestFile (Join-Path $workspace 'opencode-mcp\dist\server.js')
    Add-TestFile (Join-Path $workspace 'small-project\node_modules\tiny.bin') 16
    [IO.Directory]::CreateDirectory($fakeHome) | Out-Null
    [ordered]@{
        mcpServers = [ordered]@{
            fixture = [ordered]@{ command = 'node'; args = @((Join-Path $workspace 'claude-mcp\dist\server.js')) }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fakeHome '.claude.json') -Encoding utf8NoBOM
    [IO.File]::WriteAllText((Join-Path $workspace 'opencode-mcp\opencode.jsonc'), @"
{
  // JSONC and relative command paths are both supported.
  "mcp": { "servers": { "fixture": { "type": "local", "command": ["node", "./dist/server.js"], }, }, },
}
"@, [Text.UTF8Encoding]::new($false))

    & $scanner -OutputPath $output -WorkspaceRoot $workspace -HomePath $fakeHome `
        -HelpersDirectory $helpers -PublishedHelpersDirectory $publishedHelpers `
        -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld `
        -MinimumNodeModulesBytes 64 -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null

    $scan = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -Depth 100
    Assert-True (@($scan.categories).Count -eq 6) 'Scanner emits all six representative categories'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'package-manager-caches').sizes.protectedBytes -gt 0) 'Scanner separates protected npm _npx bytes'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'windows-temp-files').sizes.protectedBytes -ge 512) 'Scanner excludes cleanup and both runtime scratch directories from reclaimable temp bytes'
    $nodeModules = $scan.categories | Where-Object categoryId -eq 'node-modules'
    Assert-True (@($nodeModules.items).Count -eq 3) 'Scanner emits top-level node_modules above the threshold without nested duplicates'
    Assert-True (@($nodeModules.items | Where-Object disposition -eq 'eligible').Count -eq 1) 'Scanner makes inactive unregistered node_modules eligible'
    Assert-True (@($nodeModules.items | Where-Object disposition -eq 'skipped-protected').Count -eq 2) 'Scanner protects Claude Code and OpenCode registered MCP projects'
    Assert-True ($nodeModules.sizes.estimatedReclaimableBytes -gt 0 -and $nodeModules.sizes.protectedBytes -gt 0) 'Scanner separates reclaimable and MCP-protected node_modules bytes'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'build-artifacts').items[0].disposition -eq 'eligible') 'Scanner emits an inactive, cold build artifact'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'config-msi-leftovers').items[0].operationPreview.elevated) 'Scanner marks Config.Msi as elevated'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'windows-old').items[0].disposition -eq 'manual-only') 'Scanner keeps Windows.old manual-only'
    Assert-True ($scan.sessionCensus.status -eq 'unsupported') 'Fixture scan records an explicitly skipped session census'
    Assert-True ($scan.helpers.provenance.status -eq 'matched-published') 'Helper provenance ignores LF versus CRLF checkout differences'

    $gitFailureWorkspace = Join-Path $root 'git-failure-workspace'
    $gitFailureProject = Join-Path $gitFailureWorkspace 'repository-project'
    Add-TestFile (Join-Path $gitFailureProject 'node_modules\package\index.js')
    [IO.Directory]::CreateDirectory((Join-Path $gitFailureProject '.git')) | Out-Null
    $fakeBin = Join-Path $root 'fake-git-bin'
    [IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $fakeGit = Join-Path $fakeBin 'git.cmd'
    @"
@echo off
if "%~3"=="rev-parse" (
  echo $gitFailureProject
  exit /b 0
)
exit /b 7
"@ | Set-Content -LiteralPath $fakeGit -Encoding ascii
    $originalPath = $env:PATH
    try {
        $env:PATH = "$fakeBin;$originalPath"
        Assert-Fails {
            & $scanner -OutputPath (Join-Path $root 'git-failure-scan.json') -WorkspaceRoot $gitFailureWorkspace -HomePath $fakeHome `
                -HelpersDirectory $helpers -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') `
                -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -MinimumNodeModulesBytes 1 `
                -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
        } 'Scanner fails closed when Git history inspection fails'
    } finally {
        $env:PATH = $originalPath
    }

    $openCodeWorkspace = Join-Path $root 'opencode-workspace'
    $openCodeNested = Join-Path $openCodeWorkspace 'packages\nested'
    $openCodeOutput = Join-Path $root 'opencode-scan.json'
    [IO.Directory]::CreateDirectory($openCodeNested) | Out-Null
    [IO.File]::WriteAllText((Join-Path $openCodeWorkspace 'opencode.jsonc'), '{}', [Text.UTF8Encoding]::new($false))
    Push-Location $openCodeNested
    try {
        & $scanner -OutputPath $openCodeOutput -HomePath $HOME `
            -HelpersDirectory $helpers -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') `
            -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -SkipSessionCensus | Out-Null
    } finally {
        Pop-Location
    }
    $openCodeScan = Get-Content -LiteralPath $openCodeOutput -Raw | ConvertFrom-Json -Depth 100
    Assert-True ($openCodeScan.workspace.root -eq [IO.Path]::GetFullPath($openCodeWorkspace)) 'Scanner resolves a nested OpenCode invocation to its opencode.jsonc project root'

    try {
        & $scanner -OutputPath $output -WorkspaceRoot $workspace -HomePath $fakeHome `
            -HelpersDirectory $helpers -PublishedHelpersDirectory $publishedHelpers `
            -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld `
            -MinimumNodeModulesBytes 64 -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
        throw 'FAIL: Scanner overwrote an existing immutable scan'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: Scanner overwrote an existing immutable scan') { throw }
        Write-Output 'PASS: Scanner refuses to overwrite an existing immutable scan'
    }

    $profileOutput = Join-Path $root 'profile-scan.json'
    $profileRoot = Join-Path $root 'profile'
    [IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    Add-TestFile (Join-Path $profileRoot 'project\.next\cache.bin')
    Add-TestFile (Join-Path $profileRoot 'project\node_modules\cache.bin')
    & $scanner -OutputPath $profileOutput -WorkspaceRoot $profileRoot -HomePath $profileRoot `
        -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp `
        -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
    $profileScan = Get-Content -LiteralPath $profileOutput -Raw | ConvertFrom-Json -Depth 100
    Assert-True (($profileScan.categories | Where-Object categoryId -eq 'build-artifacts').status -eq 'skipped') 'Profile-root workspace scans skip build artifacts'
    Assert-True (($profileScan.categories | Where-Object categoryId -eq 'node-modules').status -eq 'skipped') 'Profile-root workspace scans skip node_modules'
    Assert-True ($profileScan.workspace.resolution -eq 'profile-root-rejected') 'Profile-root rejection is persisted in scan evidence'

    Add-Content -LiteralPath $publishedReadme -Value 'drift'
    $driftOutput = Join-Path $root 'drift-scan.json'
    try {
        & $scanner -OutputPath $driftOutput -WorkspaceRoot $workspace -HomePath $fakeHome `
            -HelpersDirectory $helpers -PublishedHelpersDirectory $publishedHelpers -LocalAppDataPath $local `
            -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp -ConfigMsiPath $configMsi `
            -WindowsOldPath $windowsOld -MinimumNodeModulesBytes 64 -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
        throw 'FAIL: Scanner accepted drifted published helpers'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: Scanner accepted drifted published helpers') { throw }
        Write-Output 'PASS: Scanner rejects drifted published helpers'
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup scanner tests passed.'
