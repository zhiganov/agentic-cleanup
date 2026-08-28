$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$renderer = Join-Path $root 'render-scan.ps1'
$scan = Join-Path $root 'fixtures\windows-scan.json'
$output = @(& $renderer -ScanPath $scan) -join "`n"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Output "PASS: $Message"
}

Assert-True ($output -match 'package-manager-caches\tfound\t7\.92 GB\t572\.2 MB') 'Renderer keeps reclaimable and protected npm bytes separate'
Assert-True ($output -match 'windows-old\tfound\tunknown\t0 B') 'Renderer never substitutes logical bytes for an unknown reclaim estimate'
Assert-True ($output -match 'project-a-next') 'Renderer exposes stable item IDs rather than transient row identity'
Write-Output 'All cleanup renderer tests passed.'
