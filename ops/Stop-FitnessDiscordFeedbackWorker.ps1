[CmdletBinding()]
param(
  [string]$PidPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PidPath)) {
  $PidPath = Join-Path $PSScriptRoot '..\..\..\runtime\logs\discord-feedback-worker.pid'
}

$resolvedPidPath = if (Test-Path -LiteralPath $PidPath) {
  (Resolve-Path -LiteralPath $PidPath).Path
} else {
  [System.IO.Path]::GetFullPath($PidPath)
}

if (-not (Test-Path -LiteralPath $resolvedPidPath)) {
  Write-Host 'No worker pid file found.' -ForegroundColor Yellow
  exit 0
}

$rawPid = (Get-Content -LiteralPath $resolvedPidPath -ErrorAction Stop | Select-Object -First 1).Trim()
if ($rawPid -notmatch '^\d+$') {
  Remove-Item -LiteralPath $resolvedPidPath -Force
  Write-Host 'Removed invalid worker pid file.' -ForegroundColor Yellow
  exit 0
}

$process = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
if ($null -eq $process) {
  Remove-Item -LiteralPath $resolvedPidPath -Force
  Write-Host 'Removed stale worker pid file.' -ForegroundColor Yellow
  exit 0
}

Stop-Process -Id $process.Id -Force
Start-Sleep -Seconds 1
Remove-Item -LiteralPath $resolvedPidPath -Force
Write-Host ("Stopped Fitness Discord feedback worker pid {0}." -f $process.Id) -ForegroundColor Green
