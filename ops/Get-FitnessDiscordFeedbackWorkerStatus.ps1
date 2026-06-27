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

$pidValue = $null
if (Test-Path -LiteralPath $resolvedPidPath) {
  $rawPid = (Get-Content -LiteralPath $resolvedPidPath -ErrorAction Stop | Select-Object -First 1).Trim()
  if ($rawPid -match '^\d+$') {
    $pidValue = [int]$rawPid
  }
}

$process = $null
if ($null -ne $pidValue) {
  $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
}

$logExists = Test-Path -LiteralPath $resolvedLogPath
$errLogExists = Test-Path -LiteralPath $resolvedErrLogPath
$logTail = @()
$errLogTail = @()

if ($logExists) {
  $logTail = @(Get-Content -LiteralPath $resolvedLogPath -Tail 5 | ForEach-Object { [string]$_ })
}

if ($errLogExists) {
  $errLogTail = @(Get-Content -LiteralPath $resolvedErrLogPath -Tail 5 | ForEach-Object { [string]$_ })
}

[pscustomobject]@{
  repoPath = $resolvedRepoPath
  envPath = $resolvedEnvPath
  pidPath = $resolvedPidPath
  pid = $pidValue
  running = $null -ne $process
  processStartTime = if ($process) { $process.StartTime.ToString('o') } else { $null }
  logPath = $resolvedLogPath
  logExists = $logExists
  logLastWriteTime = if ($logExists) { (Get-Item -LiteralPath $resolvedLogPath).LastWriteTime.ToString('o') } else { $null }
  errLogPath = $resolvedErrLogPath
  errLogExists = $errLogExists
  errLogLastWriteTime = if ($errLogExists) { (Get-Item -LiteralPath $resolvedErrLogPath).LastWriteTime.ToString('o') } else { $null }
  logTail = $logTail
  errLogTail = $errLogTail
} | ConvertTo-Json -Depth 5
