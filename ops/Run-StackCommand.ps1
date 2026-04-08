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
Set-Location -LiteralPath $resolvedStackRoot

try {
  $Host.UI.RawUI.WindowTitle = $Title
} catch {
}

Write-Host $Title -ForegroundColor Cyan
Write-Host ("stack: {0}" -f $resolvedStackRoot)
Write-Host ("run:   {0}" -f $Command)
Write-Host ""

Invoke-Expression $Command

$exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
if ($exitCode -ne 0) {
  Write-Host ""
  Write-Host ("Command exited with code {0}." -f $exitCode) -ForegroundColor Red
  exit $exitCode
}
