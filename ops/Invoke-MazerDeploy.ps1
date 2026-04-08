[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('preview', 'prod')]
  [string]$Target,

  [string]$StackRoot,

  [string]$RepoPath,

  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($StackRoot)) {
  $StackRoot = Join-Path $PSScriptRoot '..'
}

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  $RepoPath = Join-Path $PSScriptRoot '..\..\fawxzzy-mazer'
}

$resolvedStackRoot = (Resolve-Path -LiteralPath $StackRoot).Path
$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$preflightPath = Join-Path $resolvedStackRoot 'ops\Test-MazerDeployIdentity.ps1'

if (-not (Test-Path -LiteralPath $preflightPath)) {
  throw "Preflight script not found: $preflightPath"
}

Set-Location -LiteralPath $resolvedStackRoot

& $preflightPath -RepoPath $resolvedRepoPath
$preflightExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
if ($preflightExitCode -ne 0) {
  exit $preflightExitCode
}

Write-Host ""
Write-Host "Running Mazer local verify..." -ForegroundColor Cyan
& pnpm run mazer:verify
$verifyExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
if ($verifyExitCode -ne 0) {
  exit $verifyExitCode
}

$deployArgs = @('dlx', 'vercel', '--cwd', $resolvedRepoPath, 'deploy')
if ($Target -eq 'prod') {
  $deployArgs += '--prod'
}

Write-Host ""
if ($DryRun) {
  Write-Host "Dry run enabled. Vercel deploy command not executed." -ForegroundColor Yellow
  Write-Host ("Would run: pnpm {0}" -f ($deployArgs -join ' '))
  exit 0
}

Write-Host ("Running Mazer {0} deploy..." -f $Target) -ForegroundColor Cyan
& pnpm @deployArgs
$deployExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
if ($deployExitCode -ne 0) {
  exit $deployExitCode
}
