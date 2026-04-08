[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Title,

  [Parameter(Mandatory = $true)]
  [string]$StackRoot,

  [Parameter(Mandatory = $true)]
  [string]$Command,

  [string]$BrowserUrl,

  [int]$BrowserWaitTimeoutSeconds = 20
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

if ([string]::IsNullOrWhiteSpace($BrowserUrl)) {
  return
}

$deadline = (Get-Date).AddSeconds($BrowserWaitTimeoutSeconds)
$browserReady = $false

while ((Get-Date) -lt $deadline) {
  try {
    Invoke-WebRequest -Uri $BrowserUrl -Method Get -TimeoutSec 2 | Out-Null
    $browserReady = $true
    break
  } catch {
    Start-Sleep -Milliseconds 500
  }
}

if (-not $browserReady) {
  Start-Sleep -Seconds 1
}

Start-Process -FilePath $BrowserUrl | Out-Null
