[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$WorkspaceRoot,
    [string]$HelpersDirectory = $PSScriptRoot,
    [string]$ContractDirectory,
    [string]$PublishedHelpersDirectory,
    [string]$HomePath = $HOME,
    [string]$LocalAppDataPath = $env:LOCALAPPDATA,
    [string]$NpmCachePath,
    [string]$TempPath = $env:TEMP,
    [string]$ConfigMsiPath = "$env:SystemDrive\Config.Msi",
    [string]$WindowsOldPath = "$env:SystemDrive\Windows.old",
    [long]$MinimumBuildArtifactBytes = 10MB,
    [long]$MinimumConfigMsiBytes = 100MB,
    [switch]$SkipSessionCensus
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$contractCandidates = @(
    $ContractDirectory,
    (Join-Path $PSScriptRoot '..\..\cleanup'),
    (Join-Path $PSScriptRoot '..\cleanup-contracts')
) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'Cleanup.Contracts.psm1')) }
if (@($contractCandidates).Count -eq 0) { throw 'Could not locate cleanup contract directory' }
$contractRoot = Resolve-Path @($contractCandidates)[0]
Import-Module (Join-Path $contractRoot 'Cleanup.Contracts.psm1') -Force
$scanSchema = Join-Path $contractRoot 'schemas\scan.schema.json'

function Get-CanonicalPath([string]$Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-StableId([string]$Prefix, [string]$Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant().Substring(0, 12)
    "$Prefix-$hash"
}

function Get-PathBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return [long]$item.Length }
    $sum = 0L
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $sum += [long]$file.Length
    }
    [long]$sum
}

function Get-DirectoryDigest([string]$Path) {
    $rows = foreach ($file in Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName).Replace('\', '/')
        $text = [IO.File]::ReadAllText($file.FullName).TrimStart([char]0xFEFF)
        $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $fileBytes = [Text.Encoding]::UTF8.GetBytes($normalized)
        $fileDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($fileBytes)).ToLowerInvariant()
        "$relative`n$fileDigest"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-AgentMarker([string]$Path) {
    (Test-Path -LiteralPath (Join-Path $Path '.claude')) -or
        (Test-Path -LiteralPath (Join-Path $Path '.opencode')) -or
        (Test-Path -LiteralPath (Join-Path $Path 'opencode.json') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $Path 'opencode.jsonc') -PathType Leaf)
}

function Resolve-Workspace([string]$Start, [string]$ExplicitRoot, [string]$Profile) {
    $cwd = Get-CanonicalPath $Start
    if ($ExplicitRoot) {
        $root = Get-CanonicalPath $ExplicitRoot
        $hasMarker = Test-AgentMarker $root
        return [ordered]@{
            cwd = $cwd
            root = $root
            scoped = $hasMarker
            resolution = if ($hasMarker) { 'outermost-marker-excluding-home' } else { 'cwd-fallback' }
            nearerMarker = $null
        }
    }
    $profileRoot = Get-CanonicalPath $Profile
    $markers = [System.Collections.Generic.List[string]]::new()
    $current = [IO.DirectoryInfo]::new($cwd)
    while ($null -ne $current) {
        $candidate = Get-CanonicalPath $current.FullName
        if ($candidate -ne $profileRoot -and (Test-AgentMarker $candidate)) {
            [void]$markers.Add($candidate)
        }
        $current = $current.Parent
    }
    if ($markers.Count -eq 0) {
        return [ordered]@{ cwd = $cwd; root = $cwd; scoped = $false; resolution = 'cwd-fallback'; nearerMarker = $null }
    }
    $root = $markers[$markers.Count - 1]
    [ordered]@{
        cwd = $cwd
        root = $root
        scoped = $true
        resolution = 'outermost-marker-excluding-home'
        nearerMarker = if ($markers.Count -gt 1) { $markers[0] } else { $null }
    }
}

function New-Sizes([long]$Logical, $Reclaimable, [long]$Protected) {
    [ordered]@{ logicalBytes = $Logical; estimatedReclaimableBytes = $Reclaimable; protectedBytes = $Protected }
}

function New-Message([string]$Code, [string]$Message, $CategoryId = $null, $ItemId = $null) {
    [ordered]@{ code = $Code; message = $Message; categoryId = $CategoryId; itemId = $ItemId }
}

function New-PackageManagerCategory([string]$CachePath) {
    $cacheRoot = Get-CanonicalPath $CachePath
    $cacache = Get-CanonicalPath (Join-Path $cacheRoot '_cacache')
    $npx = Get-CanonicalPath (Join-Path $cacheRoot '_npx')
    $cacacheBytes = Get-PathBytes $cacache
    $npxBytes = Get-PathBytes $npx
    $logical = $cacacheBytes + $npxBytes
    $resources = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $cacache) {
        $resources.Add([ordered]@{ resourceId = 'npm-cacache'; kind = 'directory'; canonicalPath = $cacache; logicalBytes = $cacacheBytes; protected = $false })
    }
    if (Test-Path -LiteralPath $npx) {
        $resources.Add([ordered]@{ resourceId = 'npm-npx'; kind = 'directory'; canonicalPath = $npx; logicalBytes = $npxBytes; protected = $true })
    }
    $items = @()
    $warnings = @()
    if ($resources.Count -gt 0) {
        $items = @([ordered]@{
            itemId = 'npm-cache'
            displayName = 'npm cache'
            disposition = if ($cacacheBytes -gt 0) { 'eligible' } else { 'skipped-protected' }
            sizes = New-Sizes $logical $cacacheBytes $npxBytes
            resources = @($resources)
            operationPreview = [ordered]@{ policyId = 'npm-cache-clean'; mode = 'tool-command'; elevated = $false }
            evidence = @([ordered]@{ kind = 'tool-installed'; source = 'get-command'; value = [bool](Get-Command npm -ErrorAction SilentlyContinue) })
            riskFlags = @('protected-npx')
            requiresPerItemConfirmation = $false
            affectedApplications = @()
        })
        if ($npxBytes -gt 0) { $warnings = @(New-Message 'npm-npx-protected' 'Protected _npx content is excluded from estimated reclaimable bytes.' 'package-manager-caches' 'npm-cache') }
    }
    [ordered]@{
        categoryId = 'package-manager-caches'; label = 'Package Manager Caches'
        status = if ($cacacheBytes -gt 0) { 'found' } elseif ($logical -gt 0) { 'skipped' } else { 'empty' }
        statusReason = $null; sizes = New-Sizes $logical $cacacheBytes $npxBytes; items = $items; warnings = $warnings
    }
}

function New-WindowsTempCategory([string]$Path) {
    $root = Get-CanonicalPath $Path
    $logical = Get-PathBytes $root
    $protected = 0L
    foreach ($name in @('agentic-cleanup', 'claude-cleanup', 'claude')) { $protected += Get-PathBytes (Join-Path $root $name) }
    $reclaimable = [Math]::Max(0L, $logical - $protected)
    [object[]]$items = if (Test-Path -LiteralPath $root) { ,([ordered]@{
        itemId = 'user-temp'; displayName = 'User temp'; disposition = if ($reclaimable -gt 0) { 'eligible' } else { 'skipped-protected' }
        sizes = New-Sizes $logical $reclaimable $protected
        resources = @([ordered]@{ resourceId = 'user-temp-root'; kind = 'directory'; canonicalPath = $root; logicalBytes = $logical; protected = $false })
        operationPreview = [ordered]@{ policyId = 'windows-user-temp'; mode = 'contents-only'; elevated = $false }
        evidence = @([ordered]@{ kind = 'directory-exists'; source = 'filesystem'; value = $true })
        riskFlags = @('locked-files-expected', 'runtime-scratch-excluded'); requiresPerItemConfirmation = $false; affectedApplications = @()
    }) } else { @() }
    [ordered]@{
        categoryId = 'windows-temp-files'; label = 'Windows Temp Files'
        status = if ($reclaimable -gt 0) { 'found' } elseif ($logical -gt 0) { 'skipped' } else { 'empty' }
        statusReason = $null; sizes = New-Sizes $logical $reclaimable $protected; items = $items; warnings = @()
    }
}

function Get-NewestWrite([string]$Path) {
    $latest = (Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object LastWriteTimeUtc -Maximum).Maximum
    if ($null -eq $latest) { return (Get-Item -LiteralPath $Path).LastWriteTimeUtc }
    [DateTime]$latest
}

function Get-GitEvidence([string]$Path) {
    $project = Split-Path -Parent $Path
    $root = (& git -C $project rev-parse --show-toplevel 2>$null)
    if (-not $root) { return [ordered]@{ active = $false; lastCommit = $null } }
    $recent = (& git -C $root log -1 --since='4 weeks ago' --format=%cI 2>$null)
    $last = (& git -C $root log -1 --format=%cI 2>$null)
    [ordered]@{ active = [bool]$recent; lastCommit = if ($last) { [string]$last } else { $null } }
}

function Find-BuildArtifacts([string]$Root) {
    $pending = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
    $pending.Enqueue([IO.DirectoryInfo]::new($Root))
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($child.Name -in @('.git', 'node_modules')) { continue }
            if ($child.Name -in @('.next', '.turbo', '.parcel-cache', '.vite')) { $child; continue }
            $pending.Enqueue($child)
        }
    }
}

function New-BuildArtifactCategory([string]$Root, [long]$MinimumBytes, [bool]$Enabled) {
    if (-not $Enabled) {
        return [ordered]@{
            categoryId = 'build-artifacts'; label = 'Build Artifacts'; status = 'skipped'
            statusReason = 'Workspace root is the user profile or a drive root.'
            sizes = New-Sizes 0 0 0; items = @(); warnings = @()
        }
    }
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($artifact in @(Find-BuildArtifacts $Root)) {
        $bytes = Get-PathBytes $artifact.FullName
        if ($bytes -lt $MinimumBytes) { continue }
        $git = Get-GitEvidence $artifact.FullName
        $newest = Get-NewestWrite $artifact.FullName
        $fresh = $newest -gt [DateTime]::UtcNow.AddHours(-24)
        $disposition = if ($git.active) { 'skipped-active' } elseif ($fresh) { 'skipped-fresh' } else { 'eligible' }
        $itemId = Get-StableId ($artifact.Name.TrimStart('.').Replace('.', '-')) (Get-CanonicalPath $artifact.FullName)
        $resourceId = "$itemId-dir"
        $items.Add([ordered]@{
            itemId = $itemId; displayName = "$($artifact.Parent.Name) $($artifact.Name)"; disposition = $disposition
            sizes = New-Sizes $bytes $(if ($disposition -eq 'eligible') { $bytes } else { 0L }) 0
            resources = @([ordered]@{ resourceId = $resourceId; kind = 'directory'; canonicalPath = Get-CanonicalPath $artifact.FullName; logicalBytes = $bytes; protected = $false })
            operationPreview = [ordered]@{ policyId = 'inactive-build-artifact'; mode = 'whole-directory'; elevated = $false }
            evidence = @(
                [ordered]@{ kind = 'git-last-commit'; source = 'git-log'; value = $git.lastCommit },
                [ordered]@{ kind = 'newest-file'; source = 'filesystem'; value = $newest.ToString('o') }
            )
            riskFlags = @('refresh-freshness', 'refresh-liveness'); requiresPerItemConfirmation = $false; affectedApplications = @()
        })
    }
    $eligible = @($items | Where-Object disposition -eq 'eligible')
    $logical = 0L
    foreach ($item in $items) { $logical += [long]$item.sizes.logicalBytes }
    $reclaimable = 0L
    foreach ($eligibleItem in $eligible) { $reclaimable += [long]$eligibleItem.sizes.estimatedReclaimableBytes }
    [ordered]@{
        categoryId = 'build-artifacts'; label = 'Build Artifacts'
        status = if ($eligible.Count -gt 0) { 'found' } elseif ($items.Count -gt 0) { 'skipped' } else { 'empty' }
        statusReason = $null; sizes = New-Sizes $logical $reclaimable 0; items = @($items); warnings = @()
    }
}

function New-ConfigMsiCategory([string]$Path, [long]$MinimumBytes) {
    $canonical = Get-CanonicalPath $Path
    $bytes = Get-PathBytes $canonical
    $installerProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object ProcessName -in @('msiexec', 'TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker'))
    $installerActive = $installerProcesses.Count -gt 0
    $items = [System.Collections.Generic.List[object]]::new()
    if ($bytes -ge $MinimumBytes -and (Test-Path -LiteralPath $canonical)) {
        $items.Add([ordered]@{
            itemId = 'config-msi'; displayName = 'Config.Msi'; disposition = if ($installerActive) { 'skipped-active' } else { 'eligible' }
            sizes = New-Sizes $bytes $(if ($installerActive) { 0L } else { $bytes }) 0
            resources = @([ordered]@{ resourceId = 'config-msi-dir'; kind = 'directory'; canonicalPath = $canonical; logicalBytes = $bytes; protected = $false })
            operationPreview = [ordered]@{ policyId = 'config-msi-leftovers'; mode = 'whole-directory'; elevated = $true }
            evidence = @([ordered]@{ kind = 'installer-process-census'; source = 'process-list'; value = $installerActive })
            riskFlags = @('installer-process-guard', 'requires-elevation'); requiresPerItemConfirmation = $false; affectedApplications = @()
        })
    }
    $itemCount = $items.Count
    [ordered]@{
        categoryId = 'config-msi-leftovers'; label = 'Config.Msi Leftovers'
        status = if ($itemCount -and $installerActive) { 'skipped' } elseif ($itemCount) { 'found' } else { 'empty' }
        statusReason = if ($itemCount -and $installerActive) { 'Installer or Windows update process is active.' } else { $null }
        sizes = New-Sizes $(if ($itemCount) { $bytes } else { 0L }) $(if ($itemCount -and -not $installerActive) { $bytes } else { 0L }) 0
        items = @($items); warnings = @()
    }
}

function New-WindowsOldCategory([string]$Path) {
    $canonical = Get-CanonicalPath $Path
    $bytes = Get-PathBytes $canonical
    $items = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $canonical) {
        $items.Add([ordered]@{
            itemId = 'windows-old'; displayName = 'Previous Windows installation'; disposition = 'manual-only'; sizes = New-Sizes $bytes $null 0
            resources = @([ordered]@{ resourceId = 'windows-old-dir'; kind = 'manual'; canonicalPath = $canonical; logicalBytes = $bytes; protected = $false })
            operationPreview = [ordered]@{ policyId = 'windows-old-manual'; mode = 'manual-only'; elevated = $true }
            evidence = @([ordered]@{ kind = 'directory-exists'; source = 'filesystem'; value = $true })
            riskFlags = @('manual-settings-only'); requiresPerItemConfirmation = $false; affectedApplications = @()
        })
    }
    $itemCount = $items.Count
    [ordered]@{
        categoryId = 'windows-old'; label = 'Windows.old'; status = if ($itemCount) { 'found' } else { 'empty' }
        statusReason = $null; sizes = New-Sizes $bytes $(if ($itemCount) { $null } else { 0L }) 0; items = @($items); warnings = @()
    }
}

$workspace = Resolve-Workspace (Get-Location).Path $WorkspaceRoot $HomePath
$profileRoot = Get-CanonicalPath $HomePath
$workspacePathRoot = Get-CanonicalPath ([IO.Path]::GetPathRoot($workspace.root))
$workspaceScoped = $workspace.root -ne $profileRoot -and $workspace.root -ne $workspacePathRoot
if (-not $workspaceScoped) {
    $workspace.scoped = $false
    $workspace.resolution = 'profile-root-rejected'
}
$resolvedNpmCache = if ($NpmCachePath) {
    Get-CanonicalPath $NpmCachePath
} else {
    $configured = if (Get-Command npm -ErrorAction SilentlyContinue) { (& npm config get cache 2>$null | Select-Object -First 1) } else { $null }
    if ($configured -and [IO.Path]::IsPathFullyQualified([string]$configured)) {
        Get-CanonicalPath ([string]$configured)
    } else {
        Get-CanonicalPath (Join-Path $LocalAppDataPath 'npm-cache')
    }
}
$helperPath = Get-CanonicalPath $HelpersDirectory
$canonicalDigest = Get-DirectoryDigest $helperPath
$publishedPath = if ($PublishedHelpersDirectory) { Get-CanonicalPath $PublishedHelpersDirectory } else { $null }
$publishedDigest = if ($publishedPath -and (Test-Path -LiteralPath $publishedPath)) { Get-DirectoryDigest $publishedPath } else { $null }
$provenanceStatus = if (-not $publishedPath) { 'canonical-only' } elseif ($canonicalDigest -eq $publishedDigest) { 'matched-published' } else { 'failed' }
if ($provenanceStatus -eq 'failed') { throw 'Canonical and published cleanup helpers differ' }

$driveName = ([IO.Path]::GetPathRoot($workspace.root)).TrimEnd('\').TrimEnd(':')
$drive = Get-PSDrive -Name $driveName
$now = [DateTime]::UtcNow
$sessionCensus = if ($SkipSessionCensus) {
    [ordered]@{ status = 'unsupported'; capturedAt = $now.ToString('o'); sessions = @(); limitations = @('Session census skipped by explicit scanner option.') }
} else {
    try {
        & (Join-Path $helperPath 'live_paths.ps1') -JsonSummary | ConvertFrom-Json -Depth 20
    } catch {
        [ordered]@{ status = 'failed'; capturedAt = $now.ToString('o'); sessions = @(); limitations = @("Session census failed: $($_.Exception.Message)") }
    }
}

$scan = [ordered]@{
    schemaVersion = '1.0'; runId = [guid]::NewGuid().ToString(); createdAt = $now.ToString('o'); arguments = @($MyInvocation.UnboundArguments)
    platform = [ordered]@{ family = 'windows'; uname = [Environment]::OSVersion.VersionString; distribution = $null }
    workspace = $workspace
    helpers = [ordered]@{
        directory = $helperPath
        provenance = [ordered]@{
            status = $provenanceStatus; canonicalDirectory = $helperPath; publishedDirectory = $publishedPath
            digestAlgorithm = 'sha256'; canonicalDigest = $canonicalDigest; publishedDigest = $publishedDigest
        }
    }
    diskBaseline = [ordered]@{ capturedAt = $now.ToString('o'); freeBytes = [long]$drive.Free; totalBytes = [long]($drive.Used + $drive.Free) }
    measurement = [ordered]@{ source = 'filesystem'; capturedAt = $now.ToString('o'); snapshotPath = $null; snapshotBytes = 0L }
    sessionCensus = $sessionCensus
    categories = @(
        New-PackageManagerCategory $resolvedNpmCache
        New-WindowsTempCategory $TempPath
        New-BuildArtifactCategory $workspace.root $MinimumBuildArtifactBytes $workspaceScoped
        New-ConfigMsiCategory $ConfigMsiPath $MinimumConfigMsiBytes
        New-WindowsOldCategory $WindowsOldPath
    )
    warnings = @(); failures = @()
}

Assert-CleanupSchema $scan $scanSchema
Assert-ScanSemantics $scan
Write-ImmutableJson $scan (Get-CanonicalPath $OutputPath)
Write-Output (Get-CanonicalPath $OutputPath)
