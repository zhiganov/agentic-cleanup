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
    Add-TestFile (Join-Path $temp 'claude-cleanup\scan.bin')
    $artifactFile = Join-Path $workspace 'project-a\.next\cache.bin'
    Add-TestFile $artifactFile
    (Get-Item -LiteralPath $artifactFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    Add-TestFile (Join-Path $configMsi 'rollback.bin')
    Add-TestFile (Join-Path $windowsOld 'windows.bin')

    & $scanner -OutputPath $output -WorkspaceRoot $workspace -HomePath (Join-Path $root 'home') `
        -HelpersDirectory $helpers -PublishedHelpersDirectory $publishedHelpers `
        -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld `
        -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null

    $scan = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -Depth 100
    Assert-True (@($scan.categories).Count -eq 5) 'Scanner emits all five representative categories'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'package-manager-caches').sizes.protectedBytes -gt 0) 'Scanner separates protected npm _npx bytes'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'windows-temp-files').sizes.protectedBytes -gt 0) 'Scanner excludes Claude and cleanup scratch from reclaimable temp bytes'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'build-artifacts').items[0].disposition -eq 'eligible') 'Scanner emits an inactive, cold build artifact'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'config-msi-leftovers').items[0].operationPreview.elevated) 'Scanner marks Config.Msi as elevated'
    Assert-True (($scan.categories | Where-Object categoryId -eq 'windows-old').items[0].disposition -eq 'manual-only') 'Scanner keeps Windows.old manual-only'
    Assert-True ($scan.sessionCensus.status -eq 'unsupported') 'Fixture scan records an explicitly skipped session census'
    Assert-True ($scan.helpers.provenance.status -eq 'matched-published') 'Helper provenance ignores LF versus CRLF checkout differences'
    try {
        & $scanner -OutputPath $output -WorkspaceRoot $workspace -HomePath (Join-Path $root 'home') `
            -HelpersDirectory $helpers -PublishedHelpersDirectory $publishedHelpers `
            -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld `
            -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
        throw 'FAIL: Scanner overwrote an existing immutable scan'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: Scanner overwrote an existing immutable scan') { throw }
        Write-Output 'PASS: Scanner refuses to overwrite an existing immutable scan'
    }

    $profileOutput = Join-Path $root 'profile-scan.json'
    $profileRoot = Join-Path $root 'profile'
    [IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    Add-TestFile (Join-Path $profileRoot 'project\.next\cache.bin')
    & $scanner -OutputPath $profileOutput -WorkspaceRoot $profileRoot -HomePath $profileRoot `
        -LocalAppDataPath $local -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp `
        -ConfigMsiPath $configMsi -WindowsOldPath $windowsOld -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
    $profileScan = Get-Content -LiteralPath $profileOutput -Raw | ConvertFrom-Json -Depth 100
    Assert-True (($profileScan.categories | Where-Object categoryId -eq 'build-artifacts').status -eq 'skipped') 'Profile-root workspace scans skip build artifacts'
    Assert-True ($profileScan.workspace.resolution -eq 'profile-root-rejected') 'Profile-root rejection is persisted in scan evidence'

    Add-Content -LiteralPath $publishedReadme -Value 'drift'
    $driftOutput = Join-Path $root 'drift-scan.json'
    try {
        & $scanner -OutputPath $driftOutput -WorkspaceRoot $workspace -HomePath (Join-Path $root 'home') `
            -HelpersDirectory $helpers -PublishedHelpersDirectory $publishedHelpers -LocalAppDataPath $local `
            -NpmCachePath (Join-Path $local 'npm-cache') -TempPath $temp -ConfigMsiPath $configMsi `
            -WindowsOldPath $windowsOld -MinimumBuildArtifactBytes 1 -MinimumConfigMsiBytes 1 -SkipSessionCensus | Out-Null
        throw 'FAIL: Scanner accepted drifted published helpers'
    } catch {
        if ($_.Exception.Message -eq 'FAIL: Scanner accepted drifted published helpers') { throw }
        Write-Output 'PASS: Scanner rejects drifted published helpers'
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All cleanup scanner tests passed.'
