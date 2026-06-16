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

function Format-ByteCount {
  param(
    [Parameter(Mandatory = $true)]
    [long]$Bytes
  )

  if ($Bytes -ge 1GB) {
    return ("{0:N2} GiB ({1} bytes)" -f ($Bytes / 1GB), $Bytes)
  }

  if ($Bytes -ge 1MB) {
    return ("{0:N2} MiB ({1} bytes)" -f ($Bytes / 1MB), $Bytes)
  }

  if ($Bytes -ge 1KB) {
    return ("{0:N2} KiB ({1} bytes)" -f ($Bytes / 1KB), $Bytes)
  }

  return ("{0} bytes" -f $Bytes)
}

function Get-DirectoryByteCount {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum

  if ($null -eq $sum) {
    return 0L
  }

  return [long]$sum
}

function Get-GitTrackedPayloadProfile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath
  )

  $relativePaths = & git -C $RepoPath ls-files 2>$null
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  if ($exitCode -ne 0) {
    throw ("git ls-files failed for {0} with exit code {1}." -f $RepoPath, $exitCode)
  }

  $fileCount = 0
  $totalBytes = 0L
  $largest = New-Object System.Collections.Generic.List[object]

  foreach ($relativePath in $relativePaths) {
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
      continue
    }

    $fullPath = Join-Path $RepoPath $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      continue
    }

    $item = Get-Item -LiteralPath $fullPath
    $fileCount += 1
    $totalBytes += [long]$item.Length
    $largest.Add([pscustomobject]@{
        RelativePath = $relativePath
        Bytes        = [long]$item.Length
      })
  }

  return [pscustomobject]@{
    FileCount  = $fileCount
    TotalBytes = $totalBytes
    Largest    = @($largest | Sort-Object -Property Bytes -Descending | Select-Object -First 5)
  }
}

function Write-DeployProfile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoPath
  )

  $trackedProfile = Get-GitTrackedPayloadProfile -RepoPath $RepoPath
  $distBytes = Get-DirectoryByteCount -Path (Join-Path $RepoPath 'dist')
  $vercelOutputBytes = Get-DirectoryByteCount -Path (Join-Path $RepoPath '.vercel\output')

  Write-Host ""
  Write-Host "Mazer deploy payload profile:" -ForegroundColor DarkCyan
  Write-Host ("  repo path: {0}" -f $RepoPath)
  Write-Host ("  tracked files: {0}" -f $trackedProfile.FileCount)
  Write-Host ("  tracked bytes: {0}" -f (Format-ByteCount -Bytes $trackedProfile.TotalBytes))

  if ($null -ne $distBytes) {
    Write-Host ("  dist bytes: {0}" -f (Format-ByteCount -Bytes $distBytes))
  }

  if ($null -ne $vercelOutputBytes) {
    Write-Host ("  .vercel/output bytes: {0}" -f (Format-ByteCount -Bytes $vercelOutputBytes))
  }

  if ($trackedProfile.Largest.Count -gt 0) {
    Write-Host "  largest tracked files:"
    foreach ($entry in $trackedProfile.Largest) {
      Write-Host ("    - {0} ({1})" -f $entry.RelativePath, (Format-ByteCount -Bytes $entry.Bytes))
    }
  }
}

if ([string]::IsNullOrWhiteSpace($StackRoot)) {
  $StackRoot = Join-Path $PSScriptRoot '..'
}

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  $RepoPath = Join-Path $PSScriptRoot '..\..\mazer'
}

$resolvedStackRoot = (Resolve-Path -LiteralPath $StackRoot).Path
$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$authorPreflightPath = Join-Path $resolvedStackRoot 'ops\Test-MazerDeployIdentity.ps1'
$linkPreflightPath = Join-Path $resolvedStackRoot 'ops\Test-MazerDeployLink.ps1'
$linkConfigPath = Join-Path $resolvedStackRoot 'config\mazer-deploy.identity.json'

if (-not (Test-Path -LiteralPath $authorPreflightPath)) {
  throw "Preflight script not found: $authorPreflightPath"
}

if (-not (Test-Path -LiteralPath $linkPreflightPath)) {
  throw "Preflight script not found: $linkPreflightPath"
}

Set-Location -LiteralPath $resolvedStackRoot

$preflightStageFailures = New-Object System.Collections.Generic.List[string]

& $authorPreflightPath -RepoPath $resolvedRepoPath
$preflightExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
if ($preflightExitCode -ne 0) {
  exit $preflightExitCode
}

& $linkPreflightPath -RepoPath $resolvedRepoPath -ConfigPath $linkConfigPath
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

$vercelVersion = & cmd /c "pnpm dlx vercel --version 2>&1"
$vercelVersionExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }

Write-Host ""
if ($vercelVersionExitCode -eq 0) {
  $versionText = (($vercelVersion | Out-String).Trim())
  if (-not [string]::IsNullOrWhiteSpace($versionText)) {
    Write-Host ("Vercel CLI version: {0}" -f $versionText) -ForegroundColor DarkCyan
  }
}
else {
  Write-Host ("Unable to read Vercel CLI version before deploy (exit {0})." -f $vercelVersionExitCode) -ForegroundColor Yellow
}

Write-DeployProfile -RepoPath $resolvedRepoPath

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
