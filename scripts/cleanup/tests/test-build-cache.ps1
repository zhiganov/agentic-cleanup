$ErrorActionPreference = 'Stop'
$contracts = Split-Path -Parent $PSScriptRoot
$helpers = Join-Path (Split-Path -Parent $contracts) 'windows\cleanup'
$root = Join-Path ([IO.Path]::GetTempPath()) ('cleanup-cache-test-' + [guid]::NewGuid())
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}
# The scanner and validator see synthetic processes only. No live workstation
# path, package manager, or system directory is used by this fixture.
function Get-CimInstance { param([string]$ClassName) if ($ClassName -ne 'Win32_Process') { throw 'Unexpected fixture probe' }; @() }
try {
    $workspace = Join-Path $root 'workspace'
    $cache = Join-Path $workspace 'project\.next\cache'
    $sibling = Join-Path $workspace 'project\.next\BUILD_ID'
    $source = Join-Path $workspace 'project\src\index.js'
    $dependency = Join-Path $workspace 'project\node_modules\retained.js'
    foreach ($path in @((Join-Path $cache 'nested\cache.bin'), $sibling, $source, $dependency)) {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllBytes($path, [byte[]]::new(128))
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    }
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.claude')) | Out-Null
    $scan = Join-Path $root 'scan.json'
    $plan = Join-Path $root 'plan.json'
    $scanArgs = @{ WorkspaceRoot = $workspace; HomePath = (Join-Path $root 'home')
        LocalAppDataPath = (Join-Path $root 'local'); NpmCachePath = (Join-Path $root 'local\npm-cache')
        TempPath = (Join-Path $root 'temp'); ConfigMsiPath = (Join-Path $root 'Config.Msi')
        WindowsOldPath = (Join-Path $root 'Windows.old'); MinimumBuildArtifactBytes = 1
        SkipSessionCensus = $true; BuildCacheOnly = $true }
    & (Join-Path $helpers 'scan.ps1') -OutputPath $scan @scanArgs | Out-Null
    & (Join-Path $contracts 'build-plan.ps1') -ScanPath $scan -OutputPath $plan -CategoryId 'build-artifacts' | Out-Null
    $planned = [IO.File]::ReadAllText($plan) | ConvertFrom-Json -Depth 100
    Assert-True ($planned.operations[0].target.canonicalPath -eq $cache -and $planned.operations[0].mode -eq 'contents-only') 'Cache-only plan cannot expand to the build tree'
    $cacheFile = Join-Path $cache 'nested\cache.bin'
    [IO.File]::WriteAllBytes($cacheFile, [byte[]]::new(256))
    (Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    # Status is a synthetic constant, never a user repository or raw transcript.
    [IO.Directory]::CreateDirectory((Join-Path $workspace 'project\.git')) | Out-Null
    function git { param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) $global:LASTEXITCODE = 0; ' M src/index.js' }
    $resultPath = Join-Path $root 'result.json'
    & (Join-Path $helpers 'execute-plan.ps1') -ScanPath $scan -PlanPath $plan -OutputPath $resultPath -HomePath $scanArgs.HomePath | Out-Null
    $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json -Depth 100
    Assert-True ($result.operations[0].status -eq 'contents-cleared') 'Validated cold cache contents are cleared'
    Assert-True ($result.operations[0].bytesBefore -eq 256) 'Execution accounting refreshes the selected scope size instead of reusing scan totals'
    Assert-True $result.operations[0].repositoryStatusUnchanged 'Repository status is compared without persisting filenames or status output'
    Assert-True ((Test-Path $cache) -and (Test-Path $sibling) -and (Test-Path $source) -and (Test-Path $dependency)) 'Cache root, sibling metadata, source and dependencies survive'
    Remove-Item -LiteralPath $cache -Recurse -Force
    $absentPath = Join-Path $root 'absent-result.json'
    & (Join-Path $helpers 'execute-plan.ps1') -ScanPath $scan -PlanPath $plan -OutputPath $absentPath -HomePath $scanArgs.HomePath | Out-Null
    $absent = [IO.File]::ReadAllText($absentPath) | ConvertFrom-Json -Depth 100
    Assert-True ($absent.operations[0].status -eq 'validated-noop' -and $absent.operations[0].bytesBefore -eq 0) 'Disappeared exact cache/worktree target becomes an explicit no-op'
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    [IO.File]::WriteAllText((Join-Path $cache 'fresh.bin'), 'fresh')
    $failed = $false
    try { & (Join-Path $helpers 'execute-plan.ps1') -ScanPath $scan -PlanPath $plan -OutputPath (Join-Path $root 'fresh-result.json') -HomePath $scanArgs.HomePath } catch { $failed = $true }
    Assert-True ($failed -and (Test-Path (Join-Path $cache 'fresh.bin'))) 'A post-scan write fails closed before any mutation'
    (Get-Item -LiteralPath (Join-Path $cache 'fresh.bin')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    function Get-CimInstance {
        param([string]$ClassName)
        @([pscustomobject]@{ Name = 'node.exe'; ProcessId = 991; ParentProcessId = 1; ExecutablePath = 'C:\fixture\node.exe'; CommandLine = 'node next build' })
    }
    $failed = $false
    try { & (Join-Path $helpers 'execute-plan.ps1') -ScanPath $scan -PlanPath $plan -OutputPath (Join-Path $root 'active-result.json') -HomePath $scanArgs.HomePath } catch { $failed = $true }
    Assert-True ($failed -and (Test-Path (Join-Path $cache 'fresh.bin'))) 'An unattributed relative Next.js build is preserved despite cold timestamps'

    # Signed net delta and unknown scope measurement are rendering contracts.
    $result.diskBefore.freeBytes = 4096
    $result.diskAfter.freeBytes = 2048
    $result.operations[0].bytesAfter = $null
    $negativePath = Join-Path $root 'negative-result.json'
    $result | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $negativePath
    $rendered = & (Join-Path $contracts 'render-result.ps1') -ResultPath $negativePath | ConvertFrom-Json -Depth 10
    Assert-True ($rendered.netFreeSpaceChangeBytes -eq -2048 -and $null -eq $rendered.operations[0].logicalScopeDecrease) 'Concurrent negative disk deltas and unknown measurements are not flattened to zero'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $root) { throw 'Fixture cleanup incomplete' }
}
Write-Output 'All focused build-cache fixtures passed.'
