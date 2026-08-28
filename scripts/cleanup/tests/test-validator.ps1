$ErrorActionPreference = 'Stop'

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoScripts = Split-Path -Parent $scriptsRoot
$scanner = Join-Path $repoScripts 'windows\cleanup\scan.ps1'
$builder = Join-Path $scriptsRoot 'build-plan.ps1'
$validator = Join-Path $scriptsRoot 'validate-plan.ps1'
$processFixture = Join-Path $scriptsRoot 'fixtures\windows-processes.json'
$root = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-validator-test-{0}" -f [guid]::NewGuid())

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
    $workspace = Join-Path $root 'workspace'
    $local = Join-Path $root 'local'
    $temp = Join-Path $root 'temp'
    $configMsi = Join-Path $root 'Config.Msi'
    $windowsOld = Join-Path $root 'Windows.old'
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

    & $scanner -OutputPath $scan -WorkspaceRoot $workspace -HomePath (Join-Path $root 'home') -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') `
        -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -MinimumBuildArtifactBytes 1 `
        -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
    & $builder -ScanPath $scan -OutputPath $plan -CategoryId @('package-manager-caches', 'windows-temp-files', 'build-artifacts', 'config-msi-leftovers', 'windows-old') | Out-Null
    Assert-Pass { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -Quiet } 'Validator accepts an unchanged, inactive representative plan'

    $scratchFixture = Join-Path $root 'scratch-process.json'
    @([ordered]@{
        ProcessId = 450; ParentProcessId = 1; Name = 'pwsh.exe'
        CommandLine = "pwsh.exe -File execute-plan.ps1 -PlanPath `"$(Join-Path $temp 'claude-cleanup\plan.json')`" -OutputPath `"$(Join-Path $temp 'claude-cleanup\result.json')`""
        ExecutablePath = 'C:\Program Files\PowerShell\7\pwsh.exe'
    }) | ConvertTo-Json | Set-Content -LiteralPath $scratchFixture -Encoding utf8NoBOM
    Assert-Pass { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $scratchFixture -Quiet } 'Protected cleanup scratch paths do not veto their contents-only temp operation'

    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture (Join-Path $root 'missing-processes.json') -Quiet } 'Validator fails closed when process enumeration fails'

    (Get-Item -LiteralPath $artifact).LastWriteTimeUtc = [DateTime]::UtcNow
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -Quiet } 'Validator rejects a build artifact that became fresh after scanning'
    (Get-Item -LiteralPath $artifact).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)

    $artifactDirectory = Split-Path -Parent $artifact
    $artifactReal = "$artifactDirectory-real"
    Move-Item -LiteralPath $artifactDirectory -Destination $artifactReal
    New-Item -ItemType Junction -Path $artifactDirectory -Target $artifactReal | Out-Null
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $processFixture -Quiet } 'Validator rejects a target replaced by a junction after scanning'
    & cmd.exe /d /c rmdir "$artifactDirectory"
    if ($LASTEXITCODE -ne 0) { throw 'Could not remove test junction' }
    Move-Item -LiteralPath $artifactReal -Destination $artifactDirectory

    $liveFixture = Join-Path $root 'live-process.json'
    @([ordered]@{ ProcessId = 500; ParentProcessId = 1; Name = 'node.exe'; CommandLine = "node `"$((Split-Path -Parent $artifact))\server.js`""; ExecutablePath = 'C:\Program Files\nodejs\node.exe' }) |
        ConvertTo-Json | Set-Content -LiteralPath $liveFixture -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $liveFixture -Quiet } 'Validator rejects a target used by a running process'

    $installerFixture = Join-Path $root 'installer-process.json'
    @([ordered]@{ ProcessId = 600; ParentProcessId = 1; Name = 'msiexec.exe'; CommandLine = 'msiexec.exe /i package.msi'; ExecutablePath = 'C:\Windows\System32\msiexec.exe' }) |
        ConvertTo-Json | Set-Content -LiteralPath $installerFixture -Encoding utf8NoBOM
    Assert-Fails { & $validator -ScanPath $scan -PlanPath $plan -ProcessFixture $installerFixture -Quiet } 'Validator rejects Config.Msi while an installer is active'

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
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup validator tests passed.'
