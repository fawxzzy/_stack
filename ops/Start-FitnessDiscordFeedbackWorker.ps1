[CmdletBinding()]
param(
  [string]$RepoPath,
  [string]$EnvPath,
  [string]$LogPath,
  [string]$ErrLogPath,
  [string]$PidPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingOrLiteralPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (Test-Path -LiteralPath $Path) {
    return (Resolve-Path -LiteralPath $Path).Path
  }

  return [System.IO.Path]::GetFullPath($Path)
}

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  $RepoPath = Join-Path $PSScriptRoot '..\..\fawxzzy-fitness'
}

if ([string]::IsNullOrWhiteSpace($EnvPath)) {
  $EnvPath = Join-Path $PSScriptRoot '..\..\..\secrets\local\fawxzzy-fitness-discord-worker.env'
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
  $LogPath = Join-Path $PSScriptRoot '..\..\..\runtime\logs\discord-feedback-worker.log'
}

if ([string]::IsNullOrWhiteSpace($ErrLogPath)) {
  $ErrLogPath = Join-Path $PSScriptRoot '..\..\..\runtime\logs\discord-feedback-worker.err.log'
}

if ([string]::IsNullOrWhiteSpace($PidPath)) {
  $PidPath = Join-Path $PSScriptRoot '..\..\..\runtime\logs\discord-feedback-worker.pid'
}

$resolvedRepoPath = Resolve-ExistingOrLiteralPath -Path $RepoPath
$resolvedEnvPath = Resolve-ExistingOrLiteralPath -Path $EnvPath
$resolvedLogPath = Resolve-ExistingOrLiteralPath -Path $LogPath
$resolvedErrLogPath = Resolve-ExistingOrLiteralPath -Path $ErrLogPath
$resolvedPidPath = Resolve-ExistingOrLiteralPath -Path $PidPath

if (-not (Test-Path -LiteralPath $resolvedRepoPath)) {
  throw "Repo path not found: $resolvedRepoPath"
}

if (-not (Test-Path -LiteralPath $resolvedEnvPath)) {
  throw "Worker env path not found: $resolvedEnvPath"
}

$packageJsonPath = Join-Path $resolvedRepoPath 'package.json'
$workerScriptPath = Join-Path $resolvedRepoPath 'scripts\discord-feedback-gateway-worker.mjs'

if (-not (Test-Path -LiteralPath $packageJsonPath)) {
  throw "Repo boundary mismatch. Missing package.json at $packageJsonPath"
}

if (-not (Test-Path -LiteralPath $workerScriptPath)) {
  throw "Repo boundary mismatch. Missing worker script at $workerScriptPath"
}

$statusJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Get-FitnessDiscordFeedbackWorkerStatus.ps1') `
  -RepoPath $resolvedRepoPath `
  -EnvPath $resolvedEnvPath `
  -LogPath $resolvedLogPath `
  -ErrLogPath $resolvedErrLogPath `
  -PidPath $resolvedPidPath
$status = $statusJson | ConvertFrom-Json
if ($status.running) {
  Write-Host 'Fitness Discord feedback worker is already running.' -ForegroundColor Yellow
  Write-Host $statusJson
  exit 0
}

$logDirectory = Split-Path -Parent $resolvedLogPath
$errLogDirectory = Split-Path -Parent $resolvedErrLogPath
$pidDirectory = Split-Path -Parent $resolvedPidPath
foreach ($directory in @($logDirectory, $errLogDirectory, $pidDirectory)) {
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory | Out-Null
  }
}

$escapedEnvPath = $resolvedEnvPath.Replace("'", "''")
$escapedRepoPath = $resolvedRepoPath.Replace("'", "''")
$workerCommand = "& { `$env:FITNESS_ENV_FILE = '$escapedEnvPath'; Set-Location -LiteralPath '$escapedRepoPath'; node 'scripts/discord-feedback-gateway-worker.mjs' }"

if (Test-Path -LiteralPath $resolvedPidPath) {
  Remove-Item -LiteralPath $resolvedPidPath -Force
}

$process = Start-Process `
  -FilePath 'powershell' `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $workerCommand) `
  -WorkingDirectory $resolvedRepoPath `
  -RedirectStandardOutput $resolvedLogPath `
  -RedirectStandardError $resolvedErrLogPath `
  -WindowStyle Hidden `
  -PassThru

Set-Content -LiteralPath $resolvedPidPath -Value ([string]$process.Id) -NoNewline
Start-Sleep -Seconds 3

$startedProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
if ($null -eq $startedProcess) {
  throw "Worker process exited immediately. Check $resolvedErrLogPath"
}

$finalStatusJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Get-FitnessDiscordFeedbackWorkerStatus.ps1') `
  -RepoPath $resolvedRepoPath `
  -EnvPath $resolvedEnvPath `
  -LogPath $resolvedLogPath `
  -ErrLogPath $resolvedErrLogPath `
  -PidPath $resolvedPidPath

Write-Host 'Started Fitness Discord feedback worker.' -ForegroundColor Green
Write-Host $finalStatusJson
