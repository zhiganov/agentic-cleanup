$ErrorActionPreference = 'Stop'

$cleanupRoot = Split-Path -Parent $PSScriptRoot
$scriptsRoot = Split-Path -Parent $cleanupRoot
$scanner = Join-Path $scriptsRoot 'windows\cleanup\scan.ps1'
$executor = Join-Path $scriptsRoot 'windows\cleanup\execute-plan.ps1'
$builder = Join-Path $cleanupRoot 'build-plan.ps1'
$processFixture = Join-Path $cleanupRoot 'fixtures\windows-processes.json'
$planSwapWrapper = Join-Path $cleanupRoot 'fixtures\validator-plan-swap-wrapper.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-executor-test-{0}" -f [guid]::NewGuid())
$originalTemp = $env:TEMP

function Add-TestFile([string]$Path) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllBytes($Path, [byte[]]::new(128))
}

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

try {
    $workspace = Join-Path $root 'workspace'
    $local = Join-Path $root 'local'
    $temp = Join-Path $root 'temp'
    $configMsi = Join-Path $root 'Config.Msi'
    $windowsOld = Join-Path $root 'Windows.old'
    $scratch = Join-Path $temp 'agentic-cleanup'
    $scan = Join-Path $scratch 'scan.json'
    $plan = Join-Path $scratch 'plan.json'
    $resultPath = Join-Path $scratch 'result.json'
    $testContracts = Join-Path $root 'contracts'
    Copy-Item -LiteralPath $cleanupRoot -Destination $testContracts -Recurse
    Move-Item -LiteralPath (Join-Path $testContracts 'validate-plan.ps1') -Destination (Join-Path $testContracts 'validate-plan-real.ps1')
    Copy-Item -LiteralPath $planSwapWrapper -Destination (Join-Path $testContracts 'validate-plan.ps1')
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.claude')) | Out-Null
    $env:TEMP = $temp
    Add-TestFile (Join-Path $temp 'ordinary\cache.bin')
    Add-TestFile (Join-Path $temp 'claude\live.bin')
    Add-TestFile (Join-Path $temp 'opencode\live.bin')
    Add-TestFile (Join-Path $temp 'agentic-cleanup\scan.bin')
    Add-TestFile (Join-Path $temp 'claude-cleanup\legacy-scan.bin')
    Add-TestFile (Join-Path $local 'npm-cache\_cacache\cache.bin')
    Add-TestFile (Join-Path $local 'npm-cache\_npx\server.bin')
    $artifact = Join-Path $workspace 'project-a\.next\cache.bin'
    Add-TestFile $artifact
    (Get-Item -LiteralPath $artifact).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    Add-TestFile (Join-Path $windowsOld 'windows.bin')
    $nodeModules = Join-Path $workspace 'mcp-project\node_modules'
    Add-TestFile (Join-Path $nodeModules 'package\index.js')

    $fakeHome = Join-Path $root 'home'
    & $scanner -OutputPath $scan -WorkspaceRoot $workspace -HomePath $fakeHome -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') `
        -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -MinimumBuildArtifactBytes 1 `
        -MinimumNodeModulesBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
    $nodePlan = Join-Path $root 'node-plan.json'
    & $builder -ScanPath $scan -OutputPath $nodePlan -CategoryId 'node-modules' | Out-Null
    $registeredEntry = Join-Path $workspace 'mcp-project\dist\server.js'
    [IO.Directory]::CreateDirectory($fakeHome) | Out-Null
    [ordered]@{ mcpServers = [ordered]@{ late = [ordered]@{ command = 'node'; args = @($registeredEntry) } } } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fakeHome '.claude.json') -Encoding utf8NoBOM
    Assert-Fails { & $executor -ScanPath $scan -PlanPath $nodePlan -OutputPath (Join-Path $root 'home-context-result.json') -HomePath $fakeHome -WhatIf } 'Executor forwards custom HomePath to MCP revalidation'
    Remove-Item -LiteralPath (Join-Path $fakeHome '.claude.json') -Force

    $customClaude = Join-Path $root 'custom\claude.json'
    $customOpenCode = Join-Path $root 'custom\opencode.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $customClaude)) | Out-Null
    $customScan = Join-Path $root 'custom-context-scan.json'
    & $scanner -OutputPath $customScan -WorkspaceRoot $workspace -HomePath (Join-Path $root 'empty-home') -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') `
        -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -ClaudeConfigPath $customClaude -OpenCodeConfigPath $customOpenCode `
        -MinimumBuildArtifactBytes 1 -MinimumNodeModulesBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
    $customPlan = Join-Path $root 'custom-context-plan.json'
    & $builder -ScanPath $customScan -OutputPath $customPlan -CategoryId 'node-modules' | Out-Null
    $customResult = Join-Path $root 'claude-context-result.json'
    $env:CLEANUP_TEST_LATE_CLAUDE_CONFIG = $customClaude
    $env:CLEANUP_TEST_LATE_MCP_ENTRY = $registeredEntry
    try {
        & $executor -ScanPath $customScan -PlanPath $customPlan -OutputPath $customResult -ContractDirectory $testContracts `
            -HomePath (Join-Path $root 'empty-home') -ClaudeConfigPath $customClaude -OpenCodeConfigPath $customOpenCode -WhatIf | Out-Null
    } finally {
        Remove-Item Env:CLEANUP_TEST_LATE_CLAUDE_CONFIG, Env:CLEANUP_TEST_LATE_MCP_ENTRY -ErrorAction SilentlyContinue
    }
    $customExecution = Get-Content -LiteralPath $customResult -Raw | ConvertFrom-Json -Depth 100
    Assert-True ($customExecution.operations[0].status -eq 'failed') 'Executor forwards explicit Claude config paths to per-operation MCP revalidation'
    Remove-Item -LiteralPath $customClaude -Force

    [ordered]@{ mcp = [ordered]@{ servers = [ordered]@{ late = [ordered]@{ type = 'local'; command = @('node', $registeredEntry) } } } } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $customOpenCode -Encoding utf8NoBOM
    Assert-Fails { & $executor -ScanPath $customScan -PlanPath $customPlan -OutputPath (Join-Path $root 'opencode-context-result.json') -HomePath (Join-Path $root 'empty-home') `
        -ClaudeConfigPath $customClaude -OpenCodeConfigPath $customOpenCode -WhatIf } 'Executor forwards explicit OpenCode config paths to MCP revalidation'
    Remove-Item -LiteralPath $customOpenCode -Force

    $refreshPlan = Join-Path $root 'refresh-plan.json'
    & $builder -ScanPath $scan -OutputPath $refreshPlan -CategoryId @('package-manager-caches', 'build-artifacts') | Out-Null
    $refresh = Get-Content -LiteralPath $refreshPlan -Raw | ConvertFrom-Json -Depth 100
    $refresh.operations = @(
        $refresh.operations | Where-Object categoryId -eq 'package-manager-caches'
        $refresh.operations | Where-Object categoryId -eq 'build-artifacts'
    )
    $refresh | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $refreshPlan -Encoding utf8NoBOM
    $fakeBin = Join-Path $root 'fake-bin'
    [IO.Directory]::CreateDirectory($fakeBin) | Out-Null
    $fakeNpm = Join-Path $fakeBin 'npm.ps1'
    @"
if (`$args[0] -eq 'config') { Write-Output '$((Join-Path $local 'npm-cache').Replace("'", "''"))'; exit 0 }
if (`$args[0] -eq 'cache') {
  `$cache = '$((Join-Path $local 'npm-cache\_cacache').Replace("'", "''"))'
  Remove-Item -LiteralPath `$cache -Recurse -Force
  [IO.Directory]::CreateDirectory(`$cache) | Out-Null
  [IO.File]::WriteAllBytes((Join-Path `$cache 'recreated.bin'), [byte[]]::new(64))
  if (`$env:CLEANUP_TEST_TOUCH_ARTIFACT) { (Get-Item -LiteralPath '$($artifact.Replace("'", "''"))').LastWriteTimeUtc = [DateTime]::UtcNow }
  exit 0
}
exit 1
"@ | Set-Content -LiteralPath $fakeNpm -Encoding utf8NoBOM
    $originalPath = $env:PATH
    try {
        $env:PATH = "$fakeBin;$originalPath"
        $packagePlan = Join-Path $root 'package-plan.json'
        $packageResultPath = Join-Path $root 'package-result.json'
        & $builder -ScanPath $scan -OutputPath $packagePlan -CategoryId 'package-manager-caches' | Out-Null
        & $executor -ScanPath $scan -PlanPath $packagePlan -OutputPath $packageResultPath | Out-Null
        $packageResult = Get-Content -LiteralPath $packageResultPath -Raw | ConvertFrom-Json -Depth 100
        Assert-True ($packageResult.operations[0].status -eq 'recreated') 'Executor distinguishes a recreated cache from a hard failure'
        Assert-True (@($packageResult.failures).Count -eq 0) 'Recreated cache content is not reported as a hard failure'
        $env:CLEANUP_TEST_TOUCH_ARTIFACT = '1'
        $refreshResultPath = Join-Path $root 'refresh-result.json'
        & $executor -ScanPath $scan -PlanPath $refreshPlan -OutputPath $refreshResultPath | Out-Null
        $refreshResult = Get-Content -LiteralPath $refreshResultPath -Raw | ConvertFrom-Json -Depth 100
        Assert-True (@($refreshResult.operations | Where-Object status -eq 'recreated').Count -eq 1) 'Earlier successful operations remain accounted when a later precondition fails'
        Assert-True (@($refreshResult.operations | Where-Object status -eq 'failed').Count -eq 1) 'Later precondition failure is persisted in result.json'
    } finally {
        $env:PATH = $originalPath
        Remove-Item Env:CLEANUP_TEST_TOUCH_ARTIFACT -ErrorAction SilentlyContinue
    }
    Assert-True (Test-Path -LiteralPath (Split-Path -Parent $artifact)) 'Per-operation refresh prevents deletion of the newly fresh build artifact'
    (Get-Item -LiteralPath $artifact).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)

    & $builder -ScanPath $scan -OutputPath $plan -CategoryId @('windows-temp-files', 'build-artifacts') | Out-Null
    $originalPlanId = (Get-Content -LiteralPath $plan -Raw | ConvertFrom-Json -Depth 100).planId
    $replacementPlan = Join-Path $root 'replacement-plan.json'
    & $builder -ScanPath $scan -OutputPath $replacementPlan -CategoryId 'windows-temp-files' | Out-Null
    $env:CLEANUP_TEST_REPLACEMENT_PLAN = $replacementPlan
    $env:CLEANUP_TEST_ACTIVE_PLAN = $plan
    $lockedPath = Join-Path $temp 'ordinary\cache.bin'
    $lockedStream = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        & $executor -ScanPath $scan -PlanPath $plan -OutputPath $resultPath -ContractDirectory $testContracts | Out-Null
    } finally {
        $lockedStream.Dispose()
        Remove-Item Env:CLEANUP_TEST_REPLACEMENT_PLAN, Env:CLEANUP_TEST_ACTIVE_PLAN -ErrorAction SilentlyContinue
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -Depth 100

    Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $artifact))) 'Executor removes a validated inactive build artifact'
    Assert-True (Test-Path -LiteralPath $lockedPath) 'Executor does not retry or kill the holder of a locked temp file'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'claude\live.bin')) 'Executor preserves runtime scratch exclusion'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'opencode\live.bin')) 'Executor preserves OpenCode runtime scratch exclusion'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'agentic-cleanup\scan.bin')) 'Executor preserves cleanup scratch exclusion'
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'claude-cleanup\legacy-scan.bin')) 'Executor preserves pre-rename cleanup scratch exclusion'
    Assert-True (Test-Path -LiteralPath $scan) 'Executor accepts scan and plan evidence inside protected cleanup scratch'
    Assert-True (@($result.operations | Where-Object status -eq 'removed').Count -eq 1) 'Result records removed build artifact'
    Assert-True (@($result.operations | Where-Object status -eq 'locked-skipped').Count -eq 1) 'Expected locked temp content is not reported as a hard failure'
    Assert-True ($result.planId -eq $originalPlanId) 'Executor dispatches the exact in-memory plan that passed validation'
    Assert-True (@($result.failures).Count -eq 0) "Representative execution has no hard failures: $($result.failures -join '; ')"

    $clearResultPath = Join-Path $root 'clear-result.json'
    & $executor -ScanPath $scan -PlanPath $replacementPlan -OutputPath $clearResultPath | Out-Null
    $clearResult = Get-Content -LiteralPath $clearResultPath -Raw | ConvertFrom-Json -Depth 100
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $temp 'ordinary'))) 'Executor clears temp content after its holder exits'
    Assert-True ($clearResult.operations[0].status -eq 'contents-cleared') 'Protected scratch does not prevent contents-cleared verification'
} finally {
    $env:TEMP = $originalTemp
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup executor tests passed.'
