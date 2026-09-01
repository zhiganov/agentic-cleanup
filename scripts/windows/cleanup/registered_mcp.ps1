Set-StrictMode -Version Latest

function Get-PropertyValue {
  param([object]$Value, [string]$Name)
  if ($null -eq $Value) { return $null }
  $property = $Value.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  $property.Value
}

function Test-PathWithin {
  param([string]$Path, [string]$Root)
  $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
  $parent = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  $candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or
    $candidate.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $candidate.StartsWith($parent + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Expand-McpPathToken {
  param([string]$Token, [string]$Runtime)
  $value = $Token
  if ($Runtime -eq 'opencode') {
    $value = [regex]::Replace($value, '\{env:([A-Za-z_][A-Za-z0-9_]*)\}', {
      param($match)
      $replacement = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
      if ($null -eq $replacement) { $match.Value } else { $replacement }
    })
  } else {
    $value = [regex]::Replace($value, '\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}', {
      param($match)
      $replacement = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
      if ([string]::IsNullOrEmpty($replacement) -and $match.Groups[3].Success) { $replacement = $match.Groups[3].Value }
      if ($null -eq $replacement) { $match.Value } else { $replacement }
    })
  }
  $value
}

function Resolve-McpLaunchPath {
  param([string]$Token, [string]$BasePath, [string]$Runtime)
  if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
  $value = (Expand-McpPathToken $Token $Runtime).Trim().Trim('"').Trim("'")
  if ($value -match '^--?[^=]+=(.+)$') { $value = $Matches[1] }
  if ($value -match '[{}]') { return $null }
  if ([IO.Path]::IsPathFullyQualified($value)) { return [IO.Path]::GetFullPath($value) }
  if ($value -match '[\\/]' -or $value -match '\.(?:[cm]?[jt]s|py|rb|ps1|sh)$') {
    return [IO.Path]::GetFullPath((Join-Path $BasePath $value))
  }
  $null
}

function Get-AncestorDirectories {
  param([string]$StartPath, [string]$StopPath)
  $stop = [IO.Path]::GetFullPath($StopPath).TrimEnd('\', '/')
  $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($StartPath))
  while ($null -ne $current) {
    $path = $current.FullName.TrimEnd('\', '/')
    if (-not (Test-PathWithin $path $stop)) { break }
    $path
    if ($path.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) { break }
    $current = $current.Parent
  }
}

function Get-ClaudeConfigSources {
  param([string]$ProjectPath, [string]$WorkspaceRoot, [string]$HomePath, [string[]]$ExplicitPaths)
  $explicit = @($ExplicitPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($explicit.Count -gt 0) {
    return @($explicit | ForEach-Object {
      [ordered]@{ path = [IO.Path]::GetFullPath($_); scope = $ProjectPath; kind = 'explicit' }
    })
  }
  $sources = [System.Collections.Generic.List[object]]::new()
  $configRoot = if ($env:CLAUDE_CONFIG_DIR) { [IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR) } else { [IO.Path]::GetFullPath($HomePath) }
  $userConfig = Join-Path $configRoot '.claude.json'
  if (Test-Path -LiteralPath $userConfig -PathType Leaf) {
    $sources.Add([ordered]@{ path = $userConfig; scope = $ProjectPath; kind = 'user-local' })
  }
  foreach ($directory in @(Get-AncestorDirectories $ProjectPath $WorkspaceRoot)) {
    $projectConfig = Join-Path $directory '.mcp.json'
    if (Test-Path -LiteralPath $projectConfig -PathType Leaf) {
      $sources.Add([ordered]@{ path = $projectConfig; scope = $directory; kind = 'project' })
    }
  }
  @($sources)
}

function Get-OpenCodeConfigSources {
  param([string]$ProjectPath, [string]$WorkspaceRoot, [string]$HomePath, [string[]]$ExplicitPaths)
  $explicit = @($ExplicitPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($explicit.Count -gt 0) {
    return @($explicit | ForEach-Object {
      [ordered]@{ path = [IO.Path]::GetFullPath($_); scope = $ProjectPath; kind = 'explicit' }
    })
  }
  $sources = [System.Collections.Generic.List[object]]::new()
  $globalRoot = Join-Path ([IO.Path]::GetFullPath($HomePath)) '.config\opencode'
  foreach ($name in @('opencode.json', 'opencode.jsonc')) {
    $path = Join-Path $globalRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $sources.Add([ordered]@{ path = $path; scope = $ProjectPath; kind = 'global' })
    }
  }
  foreach ($directory in @(Get-AncestorDirectories $ProjectPath $WorkspaceRoot)) {
    foreach ($relative in @('opencode.json', 'opencode.jsonc', '.opencode\opencode.json', '.opencode\opencode.jsonc')) {
      $path = Join-Path $directory $relative
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        $sources.Add([ordered]@{ path = $path; scope = $directory; kind = 'project' })
      }
    }
  }
  @($sources)
}

function Add-McpRegistrations {
  param(
    [System.Collections.Generic.List[object]]$Registrations,
    [object]$Servers,
    [string]$Runtime,
    [object]$Source,
    [bool]$ClaudeShape
  )
  if ($null -eq $Servers) { return }
  foreach ($property in @($Servers.PSObject.Properties)) {
    $server = $property.Value
    if (-not $ClaudeShape -and (Get-PropertyValue $server 'type') -ne 'local') { continue }
    $command = Get-PropertyValue $server 'command'
    if ($null -eq $command) { continue }
    $basePath = [string]$Source.scope
    $paths = [System.Collections.Generic.List[string]]::new()
    $cwd = Get-PropertyValue $server 'cwd'
    if ($cwd) {
      $resolvedCwd = Resolve-McpLaunchPath ([string]$cwd) $basePath $Runtime
      if ($resolvedCwd) {
        $basePath = $resolvedCwd
        $paths.Add($resolvedCwd)
      }
    }
    $tokens = if ($ClaudeShape) { @([string]$command) + @(Get-PropertyValue $server 'args') } else { @($command) }
    foreach ($token in $tokens) {
      $path = Resolve-McpLaunchPath ([string]$token) $basePath $Runtime
      if ($path) { $paths.Add($path) }
    }
    if ($paths.Count -gt 0) {
      $Registrations.Add([ordered]@{
        runtime = $Runtime
        name = [string]$property.Name
        sourceKind = [string]$Source.kind
        sourcePath = [string]$Source.path
        launchPaths = @($paths | Sort-Object -Unique)
      })
    }
  }
}

function Get-RegisteredMcpOwnership {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$HomePath = $HOME,
    [string[]]$ClaudeConfigPath,
    [string[]]$OpenCodeConfigPath
  )

  $project = [IO.Path]::GetFullPath($ProjectPath)
  $workspace = [IO.Path]::GetFullPath($WorkspaceRoot)
  $registrations = [System.Collections.Generic.List[object]]::new()
  $sources = [System.Collections.Generic.List[string]]::new()

  foreach ($source in @(Get-ClaudeConfigSources $project $workspace $HomePath $ClaudeConfigPath)) {
    if (-not (Test-Path -LiteralPath $source.path -PathType Leaf)) { continue }
    $sources.Add([string]$source.path)
    $config = Get-Content -LiteralPath $source.path -Raw | ConvertFrom-Json -Depth 100
    Add-McpRegistrations $registrations (Get-PropertyValue $config 'mcpServers') 'claude-code' $source $true
    $projects = Get-PropertyValue $config 'projects'
    if ($projects) {
      foreach ($property in @($projects.PSObject.Properties)) {
        if (-not [IO.Path]::IsPathFullyQualified([string]$property.Name)) { continue }
        $projectSource = [ordered]@{ path = $source.path; scope = [string]$property.Name; kind = 'local' }
        Add-McpRegistrations $registrations (Get-PropertyValue $property.Value 'mcpServers') 'claude-code' $projectSource $true
      }
    }
  }

  foreach ($source in @(Get-OpenCodeConfigSources $project $workspace $HomePath $OpenCodeConfigPath)) {
    if (-not (Test-Path -LiteralPath $source.path -PathType Leaf)) { continue }
    $sources.Add([string]$source.path)
    $config = Get-Content -LiteralPath $source.path -Raw | ConvertFrom-Json -Depth 100
    $mcp = Get-PropertyValue $config 'mcp'
    Add-McpRegistrations $registrations (Get-PropertyValue $mcp 'servers') 'opencode' $source $false
  }

  $owners = @($registrations | Where-Object {
    $registration = $_
    @($registration.launchPaths | Where-Object { Test-PathWithin $_ $project }).Count -gt 0
  } | ForEach-Object {
    [ordered]@{ runtime = $_.runtime; name = $_.name; sourceKind = $_.sourceKind; sourcePath = $_.sourcePath }
  })
  [ordered]@{
    status = 'complete'
    owners = $owners
    sources = @($sources | Sort-Object -Unique)
  }
}
