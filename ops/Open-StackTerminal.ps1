[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Title,

  [Parameter(Mandatory = $true)]
  [string]$StackRoot,

  [Parameter(Mandatory = $true)]
  [string]$Command
)

Set-StrictMode -Version Latest

$resolvedStackRoot = (Resolve-Path -LiteralPath $StackRoot).Path
$runnerPath = Join-Path $resolvedStackRoot 'ops\Run-StackCommand.ps1'

if (-not (Test-Path -LiteralPath $runnerPath)) {
  throw "Runner script not found: $runnerPath"
}

$shell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
  'pwsh.exe'
} else {
  'powershell.exe'
}

$arguments = @(
  '-NoLogo',
  '-NoProfile',
  '-NoExit',
  '-ExecutionPolicy', 'Bypass',
  '-File', $runnerPath,
  '-Title', $Title,
  '-StackRoot', $resolvedStackRoot,
  '-Command', $Command
)

Start-Process -FilePath $shell -WorkingDirectory $resolvedStackRoot -ArgumentList $arguments | Out-Null
