[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Title,

  [Parameter(Mandatory = $true)]
  [string]$StackRoot,

  [Parameter(Mandatory = $true)]
  [string]$Command,

  [string]$BrowserUrl,

  [int]$BrowserWaitTimeoutSeconds = 20,

  [switch]$UseWindowsTerminal
)

Set-StrictMode -Version Latest

$resolvedStackRoot = (Resolve-Path -LiteralPath $StackRoot).Path
$runnerPath = Join-Path $resolvedStackRoot 'ops\Run-StackCommand.ps1'

if (-not (Test-Path -LiteralPath $runnerPath)) {
  throw "Runner script not found: $runnerPath"
}

$pwshCommand = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue
if ($pwshCommand) {
  $shell = $pwshCommand.Source
} else {
  $defaultPowerShellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path -LiteralPath $defaultPowerShellPath) {
    $shell = $defaultPowerShellPath
  } else {
    $shell = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
  }
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

if ($UseWindowsTerminal) {
  $windowsTerminalPath = $null
  $defaultWindowsTerminalPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
  if (Test-Path -LiteralPath $defaultWindowsTerminalPath) {
    $windowsTerminalPath = $defaultWindowsTerminalPath
  } else {
    $wtCommand = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($wtCommand) {
      $windowsTerminalPath = $wtCommand.Source
    }
  }

  if ($windowsTerminalPath) {
    $terminalArguments = @(
      'new-tab',
      '-d', $resolvedStackRoot,
      $shell,
      '-NoLogo',
      '-NoProfile',
      '-NoExit',
      '-ExecutionPolicy', 'Bypass',
      '-File', ('"{0}"' -f $runnerPath),
      '-Title', ('"{0}"' -f $Title),
      '-StackRoot', ('"{0}"' -f $resolvedStackRoot),
      '-Command', ('"{0}"' -f $Command)
    )

    Start-Process -FilePath $windowsTerminalPath -WorkingDirectory $resolvedStackRoot -ArgumentList $terminalArguments | Out-Null
  } else {
    Write-Warning 'Windows Terminal was requested but wt.exe was not found. Falling back to PowerShell.'
    Start-Process -FilePath $shell -WorkingDirectory $resolvedStackRoot -ArgumentList $arguments | Out-Null
  }
} else {
  Start-Process -FilePath $shell -WorkingDirectory $resolvedStackRoot -ArgumentList $arguments | Out-Null
}

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
