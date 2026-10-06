# Metadata-only, bounded traversal shared by scanning and execution guards.
function Get-CleanupTreeEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [int]$MaximumEntries = 500000, [int]$MaximumSeconds = 60)
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in selected scope' }
    $pending = [Collections.Generic.Queue[string]]::new()
    $bytes = 0L
    $newest = [DateTime]::MinValue
    $count = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ($root.PSIsContainer) { $pending.Enqueue($root.FullName) }
    else { $bytes = [long]$root.Length; $newest = $root.LastWriteTimeUtc; $count = 1 }
    while ($pending.Count) {
        if ($timer.Elapsed.TotalSeconds -ge $MaximumSeconds) { throw 'Selected scope metadata budget exceeded' }
        foreach ($child in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop) {
            $count++
            if ($count -gt $MaximumEntries -or $timer.Elapsed.TotalSeconds -ge $MaximumSeconds) { throw 'Selected scope metadata budget exceeded' }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in selected scope' }
            if ($child.PSIsContainer) { $pending.Enqueue($child.FullName) }
            else {
                $bytes += [long]$child.Length
                if ($child.LastWriteTimeUtc -gt $newest) { $newest = $child.LastWriteTimeUtc }
            }
        }
    }
    if ($newest -eq [DateTime]::MinValue) { $newest = $root.LastWriteTimeUtc }
    [ordered]@{ logicalBytes = $bytes; newestWriteUtc = $newest; entries = $count }
}
