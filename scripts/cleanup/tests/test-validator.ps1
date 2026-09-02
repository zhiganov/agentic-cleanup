$ErrorActionPreference = 'Stop'

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoScripts = Split-Path -Parent $scriptsRoot
$scanner = Join-Path $repoScripts 'windows\cleanup\scan.ps1'
$builder = Join-Path $scriptsRoot 'build-plan.ps1'
$validator = Join-Path $scriptsRoot 'validate-plan.ps1'
$processFixture = Join-Path $scriptsRoot 'fixtures\windows-processes.json'
$root = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-validator-test-{0}" -f [guid]::NewGuid())
$originalXdgConfigHome = $env:XDG_CONFIG_HOME
$unresolvedEnvName = 'CLEANUP_TEST_UNRESOLVED_MCP_ROOT'
$originalUnresolvedEnv = [Environment]::GetEnvironmentVariable($unresolvedEnvName)

function Add-TestFile([string]$Path) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllBytes($Path, [byte[]]::new(128))
}

function Assert-Pass([scriptblock]$Action, [string]$Message) {
    & $Action
    Write-Output "PASS: $Message"
}

function Assert-Fails([scriptblock]$Action, [string]$Message) {
    try { & $Action; throw "FAIL: $Message" } catch {
        if ($_.Exception.Message -eq "FAIL: $Message") { throw }
        Write-Output "PASS: $Message"
    }
}

try {
    $env:XDG_CONFIG_HOME = $null
    [Environment]::SetEnvironmentVariable($unresolvedEnvName, $null)
    $workspace = Join-Path $root 'workspace'
    $local = Join-Path $root 'local'
    $temp = Join-Path $root 'temp'
    $configMsi = Join-Path $root 'Config.Msi'
    $windowsOld = Join-Path $root 'Windows.old'
    $fakeHome = Join-Path $root 'home'
    $scan = Join-Path $root 'scan.json'
    $plan = Join-Path $root 'plan.json'
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.claude')) | Out-Null
    Add-TestFile (Join-Path $local 'npm-cache\_cacache\cache.bin')
    Add-TestFile (Join-Path $local 'npm-cache\_npx\server.bin')
    Add-TestFile (Join-Path $temp 'ordinary\cache.bin')
    Add-TestFile (Join-Path $temp 'claude\live.bin')
    $artifact = Join-Path $workspace 'project-a\.next\cache.bin'
    Add-TestFile $artifact
    (Get-Item -LiteralPath $artifact).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    Add-TestFile (Join-Path $configMsi 'rollback.bin')
    Add-TestFile (Join-Path $windowsOld 'windows.bin')
    Add-TestFile (Join-Path $workspace 'inactive-project\node_modules\package\index.js')

    & $scanner -OutputPath $scan -WorkspaceRoot $workspace -HomePath $fakeHome -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') `
        -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -MinimumBuildArtifactBytes 1 `
        -MinimumNodeModulesBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
    & $builder -ScanPath $scan -OutputPath $plan -CategoryId @('package-manager-caches', 'windows-temp-files', 'node-modules', 'build-artifacts', 'config-msi-leftovers', 'windows-old') | Out-Null
    Assert-Pass { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator accepts an unchanged, inactive representative plan'

    [IO.Directory]::CreateDirectory($fakeHome) | Out-Null
    $registeredEntry = Join-Path $workspace 'inactive-project\dist\server.js'
    [ordered]@{ mcpServers = [ordered]@{ late = [ordered]@{ command = 'node'; args = @($registeredEntry) } } } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fakeHome '.claude.json') -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator rejects node_modules registered by Claude Code after scanning'
    Remove-Item -LiteralPath (Join-Path $fakeHome '.claude.json') -Force

    $openCodeConfig = Join-Path $fakeHome '.config\opencode\opencode.jsonc'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $openCodeConfig)) | Out-Null
    [IO.File]::WriteAllText($openCodeConfig, "{`n  // late registration`n  `"mcp`": { `"servers`": { `"late`": { `"type`": `"local`", `"command`": [`"node`", `"$($registeredEntry.Replace('\', '\\'))`"], }, }, },`n}", [Text.UTF8Encoding]::new($false))
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator rejects node_modules registered by OpenCode after scanning'
    [IO.File]::WriteAllText($openCodeConfig, '{ malformed', [Text.UTF8Encoding]::new($false))
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator fails closed on malformed MCP configuration'
    Remove-Item -LiteralPath $openCodeConfig -Force

    $unresolvedToken = '${' + $unresolvedEnvName + '}\dist\server.js'
    [ordered]@{ mcpServers = [ordered]@{ late = [ordered]@{ command = 'node'; args = @($unresolvedToken) } } } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fakeHome '.claude.json') -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator fails closed on unresolved environment-backed MCP registration'
    Remove-Item -LiteralPath (Join-Path $fakeHome '.claude.json') -Force

    $xdgConfigHome = Join-Path $root 'xdg-config'
    $env:XDG_CONFIG_HOME = $xdgConfigHome
    $xdgOpenCodeConfig = Join-Path $xdgConfigHome 'opencode\opencode.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $xdgOpenCodeConfig)) | Out-Null
    [ordered]@{ mcp = [ordered]@{ servers = [ordered]@{ late = [ordered]@{ type = 'local'; command = @('node', $registeredEntry) } } } } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $xdgOpenCodeConfig -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator rejects node_modules registered through XDG_CONFIG_HOME after scanning'
    Remove-Item -LiteralPath $xdgOpenCodeConfig -Force
    $env:XDG_CONFIG_HOME = $null

    $ancestorOpenCodeConfig = Join-Path $root 'opencode.json'
    [ordered]@{ mcp = [ordered]@{ servers = [ordered]@{ late = [ordered]@{ type = 'local'; command = @('node', $registeredEntry) } } } } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ancestorOpenCodeConfig -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator rejects node_modules registered above the cleanup workspace root after scanning'
    Remove-Item -LiteralPath $ancestorOpenCodeConfig -Force

    function Assert-InvalidNodeRoot([string]$Target, [string]$Message) {
        Add-TestFile (Join-Path $Target 'package\index.js')
        $invalidScanPath = Join-Path $root ("invalid-scan-{0}.json" -f [guid]::NewGuid())
        $invalidPlanPath = Join-Path $root ("invalid-plan-{0}.json" -f [guid]::NewGuid())
        try {
            $invalidScan = Get-Content -LiteralPath $scan -Raw | ConvertFrom-Json -Depth 100
            $category = $invalidScan.categories | Where-Object categoryId -eq 'node-modules'
            $item = @($category.items | Where-Object disposition -eq 'eligible')[0]
            $bytes = [long]((Get-ChildItem -LiteralPath $Target -File -Recurse | Measure-Object Length -Sum).Sum)
            $item.resources[0].canonicalPath = [IO.Path]::GetFullPath($Target)
            $item.resources[0].logicalBytes = $bytes
            $item.sizes.logicalBytes = $bytes
            $item.sizes.estimatedReclaimableBytes = $bytes
            $category.sizes.logicalBytes = $bytes
            $category.sizes.estimatedReclaimableBytes = $bytes
            $invalidScan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $invalidScanPath -Encoding utf8NoBOM
            & $builder -ScanPath $invalidScanPath -OutputPath $invalidPlanPath -CategoryId 'node-modules' | Out-Null
            Assert-Fails { & $validator -ScanPath $invalidScanPath -PlanPath $invalidPlanPath -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } $Message
        } finally {
            Remove-Item -LiteralPath $invalidScanPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $invalidPlanPath -Force -ErrorAction SilentlyContinue
        }
    }
    Assert-InvalidNodeRoot (Join-Path $root 'outside\node_modules') 'Validator rejects node_modules outside the scanned workspace'
    Assert-InvalidNodeRoot (Join-Path $workspace 'nested\node_modules\package\node_modules') 'Validator rejects node_modules nested inside another node_modules tree'

    $scratchFixture = Join-Path $root 'scratch-process.json'
    @([ordered]@{
        ProcessId = 450; ParentProcessId = 1; Name = 'pwsh.exe'
        CommandLine = "pwsh.exe -File execute-plan.ps1 -PlanPath `"$(Join-Path $temp 'agentic-cleanup\plan.json')`" -OutputPath `"$(Join-Path $temp 'agentic-cleanup\result.json')`""
        ExecutablePath = 'C:\Program Files\PowerShell\7\pwsh.exe'
    }) | ConvertTo-Json | Set-Content -LiteralPath $scratchFixture -Encoding utf8NoBOM
    Assert-Pass { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $scratchFixture -HomePath $fakeHome -Quiet } 'Protected cleanup scratch paths do not veto their contents-only temp operation'

    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture (Join-Path $root 'missing-processes.json') -HomePath $fakeHome -Quiet } 'Validator fails closed when process enumeration fails'

    (Get-Item -LiteralPath $artifact).LastWriteTimeUtc = [DateTime]::UtcNow
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator rejects a build artifact that became fresh after scanning'
    (Get-Item -LiteralPath $artifact).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)

    $artifactDirectory = Split-Path -Parent $artifact
    $artifactReal = "$artifactDirectory-real"
    Move-Item -LiteralPath $artifactDirectory -Destination $artifactReal
    New-Item -ItemType Junction -Path $artifactDirectory -Target $artifactReal | Out-Null
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator rejects a target replaced by a junction after scanning'
    & cmd.exe /d /c rmdir "$artifactDirectory"
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove test junction' }
    Move-Item -LiteralPath $artifactReal -Destination $artifactDirectory

    $nodeProject = Join-Path $workspace 'inactive-project'
    $nodeProjectReal = Join-Path $root 'inactive-project-real'
    Move-Item -LiteralPath $nodeProject -Destination $nodeProjectReal
    New-Item -ItemType Junction -Path $nodeProject -Target $nodeProjectReal | Out-Null
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -HomePath $fakeHome -Quiet } 'Validator rejects a node_modules target redirected through an ancestor junction'
    & cmd.exe /d /c rmdir "$nodeProject"
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove ancestor test junction' }
    Move-Item -LiteralPath $nodeProjectReal -Destination $nodeProject

    $liveFixture = Join-Path $root 'live-process.json'
    @([ordered]@{ ProcessId = 500; ParentProcessId = 1; Name = 'node.exe'; CommandLine = "node `"$((Split-Path -Parent $artifact))\server.js`""; ExecutablePath = 'C:\Program Files\nodejs\node.exe' }) |
        ConvertTo-Json | Set-Content -LiteralPath $liveFixture -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $liveFixture -HomePath $fakeHome -Quiet } 'Validator rejects a target used by a running process'

    $installerFixture = Join-Path $root 'installer-process.json'
    @([ordered]@{ ProcessId = 600; ParentProcessId = 1; Name = 'msiexec.exe'; CommandLine = 'msiexec.exe /i package.msi'; ExecutablePath = 'C:\Windows\System32\msiexec.exe' }) |
        ConvertTo-Json | Set-Content -LiteralPath $installerFixture -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $installerFixture -HomePath $fakeHome -Quiet } 'Validator rejects Config.Msi while an installer is active'

    $npmPlan = Join-Path $root 'npm-plan.json'
    & $builder -ScanPath $scan -OutputPath $npmPlan -CategoryId 'package-manager-caches' | Out-Null
    $originalNpmCache = $env:npm_config_cache
    try {
        $env:npm_config_cache = Join-Path $root 'different-npm-cache'
        Assert-Fails { & $validator -ScanPath $scan -PlanPath $npmPlan -Quiet } 'Validator rejects npm cache configuration drift before execution'
    } finally {
        $env:npm_config_cache = $originalNpmCache
    }
} finally {
    $env:XDG_CONFIG_HOME = $originalXdgConfigHome
    [Environment]::SetEnvironmentVariable($unresolvedEnvName, $originalUnresolvedEnv)
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup validator tests passed.'
