Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedScanDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-CleanupSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$SchemaPath
    )

    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $schemaErrors = @()
    if (-not ($json | Test-Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors)) {
        $details = @($schemaErrors | ForEach-Object Exception | ForEach-Object Message) -join '; '
        throw "Document does not match schema: $SchemaPath. $details"
    }
}

function Assert-UniqueValues {
    param([object[]]$Values, [string]$Label)
    $all = @($Values)
    $unique = @($all | Sort-Object -Unique)
    if ($all.Count -ne $unique.Count) { throw "Duplicate $Label detected" }
}

function Assert-NativeAbsolutePath {
    param([string]$Path, [string]$PlatformFamily, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty" }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { throw "$Label contains traversal: $Path" }
    if ($PlatformFamily -eq 'windows') {
        if ($Path -notmatch '^(?:[A-Za-z]:\\|\\\\)') { throw "$Label is not an absolute native Windows path: $Path" }
        if ($Path.Contains('/')) { throw "$Label mixes Windows and POSIX separators: $Path" }
    } elseif ($Path -notmatch '^/') {
        throw "$Label is not an absolute native path: $Path"
    }
}

function Assert-ScanSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Scan)

    $family = [string]$Scan.platform.family
    Assert-NativeAbsolutePath $Scan.workspace.cwd $family 'workspace.cwd'
    if ($null -ne $Scan.workspace.root) { Assert-NativeAbsolutePath $Scan.workspace.root $family 'workspace.root' }
    Assert-NativeAbsolutePath $Scan.helpers.directory $family 'helpers.directory'

    $categories = @($Scan.categories)
    Assert-UniqueValues @($categories.categoryId) 'categoryId'
    $allItemIds = [System.Collections.Generic.List[string]]::new()
    $allResourceIds = [System.Collections.Generic.List[string]]::new()
    foreach ($category in $categories) {
        $items = @($category.items)
        Assert-UniqueValues @($items | ForEach-Object itemId) "itemId in category '$($category.categoryId)'"
        $itemLogicalBytes = 0L
        $itemProtectedBytes = 0L
        $itemReclaimableBytes = 0L
        $allItemEstimatesKnown = $true
        foreach ($item in $items) {
            $allItemIds.Add([string]$item.itemId)
            if ($item.sizes.protectedBytes -gt $item.sizes.logicalBytes) {
                throw "Item '$($item.itemId)' has protected bytes above logical bytes"
            }
            if ($null -ne $item.sizes.estimatedReclaimableBytes) {
                if ($item.sizes.estimatedReclaimableBytes -gt $item.sizes.logicalBytes) {
                    throw "Item '$($item.itemId)' has reclaimable bytes above logical bytes"
                }
                if (($item.sizes.estimatedReclaimableBytes + $item.sizes.protectedBytes) -gt $item.sizes.logicalBytes) {
                    throw "Item '$($item.itemId)' double-counts reclaimable and protected bytes"
                }
                $itemReclaimableBytes += [long]$item.sizes.estimatedReclaimableBytes
            } else {
                $allItemEstimatesKnown = $false
            }
            $itemLogicalBytes += [long]$item.sizes.logicalBytes
            $itemProtectedBytes += [long]$item.sizes.protectedBytes
            $resources = @($item.resources)
            Assert-UniqueValues @($resources | ForEach-Object resourceId) "resourceId in item '$($item.itemId)'"
            foreach ($resource in $resources) {
                $allResourceIds.Add([string]$resource.resourceId)
                if ($null -ne $resource.canonicalPath) {
                    Assert-NativeAbsolutePath $resource.canonicalPath $family "resource '$($resource.resourceId)' path"
                }
            }
        }
        if ($category.sizes.logicalBytes -ne $itemLogicalBytes -or $category.sizes.protectedBytes -ne $itemProtectedBytes) {
            throw "Category '$($category.categoryId)' size totals do not match its items"
        }
        if ($null -ne $category.sizes.estimatedReclaimableBytes) {
            if (-not $allItemEstimatesKnown -or $category.sizes.estimatedReclaimableBytes -ne $itemReclaimableBytes) {
                throw "Category '$($category.categoryId)' reclaimable total does not match its items"
            }
        } elseif ($allItemEstimatesKnown -and $items.Count -gt 0) {
            throw "Category '$($category.categoryId)' discards known item reclaimable totals"
        }
    }
    Assert-UniqueValues @($allItemIds) 'itemId across scan'
    Assert-UniqueValues @($allResourceIds) 'resourceId across scan'
}

function Test-PathInside {
    param([string]$Path, [string]$Root, [string]$Relationship)
    $comparison = [StringComparison]::OrdinalIgnoreCase
    $p = $Path.TrimEnd('\', '/')
    $r = $Root.TrimEnd('\', '/')
    if ($p.Equals($r, $comparison)) { return $true }
    if ($Relationship -eq 'exact') { return $false }
    return $p.StartsWith($r + '\', $comparison) -or $p.StartsWith($r + '/', $comparison)
}

function Assert-PlanSemantics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Scan,
        [string]$ScanPath,
        [Parameter(Mandatory)][object]$PolicyRegistry,
        [string]$ScanDigest
    )

    if ($Plan.runId -ne $Scan.runId) { throw 'Plan runId does not match scan runId' }
    if ($Plan.scan.schemaVersion -ne $Scan.schemaVersion) { throw 'Plan scan schemaVersion does not match scan' }
    if ($Plan.scan.createdAt -ne $Scan.createdAt) { throw 'Plan scan createdAt does not match scan' }
    $actualScanDigest = if ($ScanDigest) { $ScanDigest } elseif ($ScanPath) { Get-NormalizedScanDigest $ScanPath } else { throw 'Scan digest evidence is required' }
    if ($Plan.scan.sha256 -ne $actualScanDigest) { throw 'Plan scan digest does not match immutable scan text' }

    $selectedCategories = @($Plan.selection.categoryIds)
    $selectedItems = @($Plan.selection.itemIds)
    $buckets = @($Plan.assertionBuckets)
    $operations = @($Plan.operations)
    Assert-UniqueValues $selectedCategories 'selected categoryId'
    Assert-UniqueValues $selectedItems 'selected itemId'
    Assert-UniqueValues @($buckets.categoryId) 'assertion bucket categoryId'
    Assert-UniqueValues @($operations.operationId) 'operationId'
    Assert-UniqueValues @($operations | ForEach-Object { $_.target.resourceId }) 'operation target resourceId'
    $exclusions = @($Plan.exclusions)
    Assert-UniqueValues @($exclusions.policyId) 'exclusion policyId'
    if (Compare-Object @($selectedCategories | Sort-Object) @($buckets.categoryId | Sort-Object)) {
        throw 'Assertion buckets must match selected categories exactly'
    }

    $expectedExclusions = [ordered]@{}
    $npmNpx = @($Scan.categories.items.resources | Where-Object resourceId -eq 'npm-npx')
    if ($npmNpx.Count -eq 1 -and $npmNpx[0].canonicalPath) {
        $expectedExclusions['protect-npm-npx'] = [ordered]@{ path = [string]$npmNpx[0].canonicalPath; relationship = 'subtree' }
    }
    $userTemp = @($Scan.categories.items.resources | Where-Object resourceId -eq 'user-temp-root')
    if ($userTemp.Count -eq 1 -and $userTemp[0].canonicalPath) {
        $expectedExclusions['protect-cleanup-scratch'] = [ordered]@{ path = [IO.Path]::GetFullPath((Join-Path $userTemp[0].canonicalPath 'agentic-cleanup')); relationship = 'subtree' }
        $expectedExclusions['protect-legacy-cleanup-scratch'] = [ordered]@{ path = [IO.Path]::GetFullPath((Join-Path $userTemp[0].canonicalPath 'claude-cleanup')); relationship = 'subtree' }
        $expectedExclusions['protect-runtime-scratch'] = [ordered]@{ path = [IO.Path]::GetFullPath((Join-Path $userTemp[0].canonicalPath 'claude')); relationship = 'subtree' }
        $expectedExclusions['protect-opencode-runtime-scratch'] = [ordered]@{ path = [IO.Path]::GetFullPath((Join-Path $userTemp[0].canonicalPath 'opencode')); relationship = 'subtree' }
    }
    if (Compare-Object @($expectedExclusions.Keys | Sort-Object) @($exclusions.policyId | Sort-Object)) {
        throw 'Plan exclusions must match mandatory scan-derived exclusions exactly'
    }
    foreach ($policyId in $expectedExclusions.Keys) {
        $actual = @($exclusions | Where-Object policyId -eq $policyId)[0]
        $expected = $expectedExclusions[$policyId]
        if ($actual.canonicalPath -ne $expected.path -or $actual.relationship -ne $expected.relationship) {
            throw "Mandatory exclusion '$policyId' differs from scan evidence"
        }
    }

    $policies = @($PolicyRegistry.policies)
    Assert-UniqueValues @($policies.policyId) 'policy registry policyId'
    $executors = @($PolicyRegistry.executors)
    $rootPolicies = @($PolicyRegistry.rootPolicies)
    Assert-UniqueValues @($executors.executorId) 'executor registry executorId'
    Assert-UniqueValues @($rootPolicies.rootPolicyId) 'root policy registry rootPolicyId'
    foreach ($bucket in $buckets) {
        $count = @($operations | Where-Object categoryId -eq $bucket.categoryId).Count
        if ($count -lt $bucket.minimumOperationCount) {
            throw "Selected category '$($bucket.categoryId)' does not meet its minimum operation count"
        }
    }
    $operationItemIds = @($operations | ForEach-Object itemId | Sort-Object -Unique)
    if (Compare-Object @($selectedItems | Sort-Object) $operationItemIds) {
        throw 'Selected items must match operation items exactly'
    }

    foreach ($operation in $operations) {
        if ($operation.categoryId -notin $selectedCategories) { throw "Operation '$($operation.operationId)' has an unselected category" }
        if ($operation.itemId -notin $selectedItems) { throw "Operation '$($operation.operationId)' has an unselected item" }
        $category = @($Scan.categories | Where-Object categoryId -eq $operation.categoryId)
        $item = @($category.items | Where-Object itemId -eq $operation.itemId)
        $resource = @($item.resources | Where-Object resourceId -eq $operation.target.resourceId)
        $policy = @($policies | Where-Object policyId -eq $operation.policyId)
        if ($category.Count -ne 1 -or $item.Count -ne 1 -or $resource.Count -ne 1) {
            throw "Operation '$($operation.operationId)' does not map uniquely to scan evidence"
        }
        if ($resource[0].protected) { throw "Operation '$($operation.operationId)' targets a protected resource" }
        if ($policy.Count -ne 1) { throw "Operation '$($operation.operationId)' uses unknown policy '$($operation.policyId)'" }
        $expected = $policy[0]
        $executor = @($executors | Where-Object executorId -eq $operation.executorId)
        $rootPolicy = @($rootPolicies | Where-Object rootPolicyId -eq $operation.preconditions.rootPolicyId)
        if ($executor.Count -ne 1) { throw "Operation '$($operation.operationId)' uses an unregistered executor" }
        if ($rootPolicy.Count -ne 1) { throw "Operation '$($operation.operationId)' uses an unregistered root policy" }
        foreach ($field in @('executorId', 'mode', 'elevated')) {
            if ($operation.$field -ne $expected.$field) { throw "Operation '$($operation.operationId)' violates policy field '$field'" }
        }
        if ($executor[0].mode -ne $operation.mode -or $executor[0].elevated -ne $operation.elevated) {
            throw "Operation '$($operation.operationId)' violates executor registration"
        }
        if ($operation.preconditions.rootPolicyId -ne $expected.rootPolicyId) {
            throw "Operation '$($operation.operationId)' violates its root policy"
        }
        foreach ($field in @('requireExists', 'rejectReparsePoint', 'liveness', 'freshness', 'registeredMcpOwnership')) {
            if ($operation.preconditions.$field -ne $expected.preconditions.$field) {
                throw "Operation '$($operation.operationId)' violates precondition '$field'"
            }
        }
        if ($operation.policyId -ne $item.operationPreview.policyId -or $operation.mode -ne $item.operationPreview.mode -or $operation.elevated -ne $item.operationPreview.elevated) {
            throw "Operation '$($operation.operationId)' differs from its scan preview"
        }
        if ($operation.target.expectedKind -ne $resource[0].kind -or $operation.target.canonicalPath -ne $resource[0].canonicalPath -or $operation.target.expectedLogicalBytes -ne $resource[0].logicalBytes) {
            throw "Operation '$($operation.operationId)' target metadata differs from scan evidence"
        }
        if ($item.requiresPerItemConfirmation -and $operation.confirmation -ne 'item-confirmed') {
            throw "Operation '$($operation.operationId)' requires per-item confirmation"
        }
        if ($null -ne $operation.target.canonicalPath) {
            Assert-NativeAbsolutePath $operation.target.canonicalPath $Scan.platform.family "operation '$($operation.operationId)' path"
            foreach ($exclusion in $exclusions) {
                if (Test-PathInside $operation.target.canonicalPath $exclusion.canonicalPath $exclusion.relationship) {
                    throw "Operation '$($operation.operationId)' targets excluded path '$($exclusion.canonicalPath)'"
                }
            }
        }
    }
}

function Write-ImmutableJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $json = ($Value | ConvertTo-Json -Depth 100) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json.Replace("`r`n", "`n"))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
}

Export-ModuleMember -Function Get-NormalizedScanDigest, Assert-CleanupSchema, Assert-ScanSemantics, Assert-PlanSemantics, Write-ImmutableJson
