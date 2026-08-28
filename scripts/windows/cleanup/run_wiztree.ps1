# Elevated WizTree full-drive export.
# Run via the native PowerShell tool:
#   powershell.exe -NoProfile -File run_wiztree.ps1 -WizTree "<exe>" -OutCsv "<winpath>" [-Target "C:"]
#
# WizTree's instant scan reads the NTFS Master File Table, which REQUIRES admin.
# Non-elevated /admin=0 silently falls back to a per-file walk that is as slow as
# Get-ChildItem and TIMES OUT on a large or near-full drive (Windows, 2026-06-23).
# So always elevate -- one UAC prompt. Pass -OutCsv as a Windows path
# (cygpath -w of the /tmp target), e.g. %TEMP%\agentic-cleanup\wiztree.csv.
param(
  [Parameter(Mandatory = $true)][string]$WizTree,
  [Parameter(Mandatory = $true)][string]$OutCsv,
  [string]$Target = "C:"
)
$argline = '"' + $Target + '" /export="' + $OutCsv + '" /admin=1 /silent'
Start-Process -FilePath $WizTree -ArgumentList $argline -Verb RunAs -Wait
if (Test-Path -LiteralPath $OutCsv) {
  $mb = [math]::Round((Get-Item -LiteralPath $OutCsv).Length / 1MB)
  Write-Output "OK: $OutCsv ($mb MB)"
} else {
  Write-Output "FAIL: no CSV produced (elevation declined, or WizTree path wrong)"
}
