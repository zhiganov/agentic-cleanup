$ErrorActionPreference = 'Stop'
$contracts = Split-Path -Parent $PSScriptRoot
$helpers = Join-Path (Split-Path -Parent $contracts) 'windows\cleanup'
$root = Join-Path ([IO.Path]::GetTempPath()) ('cleanup-scan-guards-' + [guid]::NewGuid())
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}
function Get-CimInstance { param([string]$ClassName) @() }
try {
    $workspace = Join-Path $root 'workspace'
    $cache = Join-Path $workspace 'valid\.next\cache'
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.claude')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $cache 'cold.bin'), [byte[]]::new(128))
    (Get-Item (Join-Path $cache 'cold.bin')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    $args = @{ WorkspaceRoot = $workspace; HomePath = (Join-Path $root 'home')
        LocalAppDataPath = (Join-Path $root 'local'); NpmCachePath = (Join-Path $root 'local\npm-cache')
        TempPath = (Join-Path $root 'temp'); ConfigMsiPath = (Join-Path $root 'Config.Msi')
        WindowsOldPath = (Join-Path $root 'Windows.old'); MinimumBuildArtifactBytes = 1
        MinimumNodeModulesBytes = 1; SkipSessionCensus = $true; BuildCacheOnly = $true }
    $scanPath = Join-Path $root 'scan.json'
    & (Join-Path $helpers 'scan.ps1') -OutputPath $scanPath @args | Out-Null
    $scan = [IO.File]::ReadAllText($scanPath) | ConvertFrom-Json -Depth 100
    $builds = @($scan.categories | Where-Object categoryId -eq 'build-artifacts')[0]
    $planPath = Join-Path $root 'plan.json'
    & (Join-Path $contracts 'build-plan.ps1') -ScanPath $scanPath -OutputPath $planPath -CategoryId 'build-artifacts' | Out-Null
    Remove-Item -LiteralPath $cache -Recurse -Force
    [IO.File]::WriteAllBytes($cache, [byte[]]::new(128))
    (Get-Item $cache).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    $blocked = $false
    try { & (Join-Path $helpers 'execute-plan.ps1') -ScanPath $scanPath -PlanPath $planPath -OutputPath (Join-Path $root 'result.json') -HomePath $args.HomePath | Out-Null }
    catch { $blocked = $true }
    Assert-True ($blocked -and (Test-Path -LiteralPath $cache -PathType Leaf)) 'Replacing an approved directory with a file fails closed and preserves that file'

    Remove-Item -LiteralPath $cache -Force
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $cache 'cold.bin'), [byte[]]::new(128))
    (Get-Item (Join-Path $cache 'cold.bin')).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    $fileRoot = Join-Path $workspace 'file-root\.next\cache'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $fileRoot)) | Out-Null
    [IO.File]::WriteAllBytes($fileRoot, [byte[]]::new(128))
    (Get-Item $fileRoot).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    $linked = Join-Path $workspace 'dependencies\node_modules\linked-package'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $linked)) | Out-Null
    $outside = Join-Path $root 'retained-link-target'
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'sentinel.bin'), 'preserve')
    New-Item -ItemType Junction -Path $linked -Target $outside | Out-Null
    try {
        $linkedScanPath = Join-Path $root 'linked-scan.json'
        & (Join-Path $helpers 'scan.ps1') -OutputPath $linkedScanPath @args | Out-Null
        $linkedScan = [IO.File]::ReadAllText($linkedScanPath) | ConvertFrom-Json -Depth 100
        $dependencies = @($linkedScan.categories | Where-Object categoryId -eq 'node-modules')[0]
        $builds = @($linkedScan.categories | Where-Object categoryId -eq 'build-artifacts')[0]
        Assert-True (@($builds.items.resources | Where-Object canonicalPath -eq $fileRoot).Count -eq 0) 'A regular file named cache is never offered as a cache directory'
        Assert-True (@($dependencies.warnings).Count -gt 0 -and @($builds.items).Count -eq 1) 'Linked dependency metadata is disclosed as skipped without aborting unrelated cache discovery'
        Assert-True (Test-Path (Join-Path $outside 'sentinel.bin')) 'The linked dependency target remains untouched'
    } finally {
        & cmd.exe /d /c rmdir "$linked"
        if ($LASTEXITCODE) { throw 'Fixture junction removal failed' }
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $root) { throw 'Fixture cleanup incomplete' }
}
