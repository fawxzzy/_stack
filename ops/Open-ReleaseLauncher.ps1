[CmdletBinding()]
param(
  [string]$StackRoot,
  [switch]$UseWindowsTerminal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($StackRoot)) {
  $StackRoot = Join-Path $PSScriptRoot '..'
}

$resolvedStackRoot = (Resolve-Path -LiteralPath $StackRoot).Path
$terminalOpenerPath = Join-Path $resolvedStackRoot 'ops\Open-StackTerminal.ps1'

if (-not (Test-Path -LiteralPath $terminalOpenerPath)) {
  throw "Terminal opener not found: $terminalOpenerPath"
}

& $terminalOpenerPath `
  -Title 'Stack Release Launcher' `
  -StackRoot $resolvedStackRoot `
  -Command 'pnpm run release:launcher' `
  -UseWindowsTerminal:$UseWindowsTerminal
