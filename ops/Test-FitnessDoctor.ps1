[CmdletBinding()]
param(
  [string]$RepoPath,
  [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AbsolutePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function Read-DotEnv {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $entries = @{}
  if (-not (Test-Path -LiteralPath $Path)) {
    return $entries
  }

  foreach ($rawLine in Get-Content -LiteralPath $Path) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
      continue
    }

    $separatorIndex = $line.IndexOf('=')
    if ($separatorIndex -lt 1) {
      continue
    }

    $key = $line.Substring(0, $separatorIndex).Trim()
    $value = $line.Substring($separatorIndex + 1).Trim().Trim('"').Trim("'")
    $entries[$key] = $value
  }

  return $entries
}

function Resolve-EnvValue {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$DotEnv,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($DotEnv.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$DotEnv[$Name])) {
    return [pscustomobject]@{
      Name    = $Name
      Value   = ([string]$DotEnv[$Name]).Trim()
      Source  = '.env.local'
      Present = $true
    }
  }

  $shellValue = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($shellValue)) {
    return [pscustomobject]@{
      Name    = $Name
      Value   = $shellValue.Trim()
      Source  = 'shell'
      Present = $true
    }
  }

  return [pscustomobject]@{
    Name    = $Name
    Value   = $null
    Source  = $null
    Present = $false
  }
}

function Add-Failure {
  param(
    [System.Collections.Generic.List[string]]$Failures,

    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  $Failures.Add($Message) | Out-Null
}

$stackRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  $RepoPath = Join-Path $PSScriptRoot '..\..\fawxzzy-fitness'
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path 'config' 'fitness-deploy.identity.json'
}

$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$resolvedConfigPath = Get-AbsolutePath -Path $ConfigPath -BasePath $stackRoot
$envPath = Join-Path $resolvedRepoPath '.env.local'
$failures = New-Object System.Collections.Generic.List[string]

$repoGitTopLevel = (& git -C $resolvedRepoPath rev-parse --show-toplevel 2>$null)
$repoGitExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
$normalizedRepoGitTopLevel = if ([string]::IsNullOrWhiteSpace($repoGitTopLevel)) { $null } else { [System.IO.Path]::GetFullPath($repoGitTopLevel.Trim()) }
$normalizedRepoPath = [System.IO.Path]::GetFullPath($resolvedRepoPath)

if ($repoGitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($normalizedRepoGitTopLevel) -or $normalizedRepoGitTopLevel -ne $normalizedRepoPath) {
  Add-Failure -Failures $failures -Message ("Repo boundary is not real. Expected {0}, got {1}." -f $normalizedRepoPath, $(if ($normalizedRepoGitTopLevel) { $normalizedRepoGitTopLevel } else { '<missing>' }))
}

$preflightProcess = Start-Process `
  -FilePath 'powershell' `
  -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Test-FitnessDeployLink.ps1'), '-RepoPath', $resolvedRepoPath, '-ConfigPath', $resolvedConfigPath) `
  -Wait `
  -NoNewWindow `
  -PassThru

if ([int]$preflightProcess.ExitCode -ne 0) {
  Add-Failure -Failures $failures -Message 'Deploy preflight failed. See output above for Vercel identity or Git auto-deploy drift.'
}

$dotenv = Read-DotEnv -Path $envPath
$requiredEnv = @(
  'NEXT_PUBLIC_SUPABASE_URL',
  'NEXT_PUBLIC_SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'FITNESS_QA_EMAIL',
  'FITNESS_QA_PASSWORD'
)
$resolvedEnv = @{}
foreach ($name in $requiredEnv) {
  $resolved = Resolve-EnvValue -DotEnv $dotenv -Name $name
  $resolvedEnv[$name] = $resolved
  if (-not $resolved.Present) {
    Add-Failure -Failures $failures -Message ("Missing required local Fitness QA/env value: {0}. Set it in {1} or the shell." -f $name, $envPath)
  }
}

$browserUrl = $resolvedEnv['NEXT_PUBLIC_SUPABASE_URL']
if ($browserUrl.Present) {
  $serverUrl = $resolvedEnv['NEXT_PUBLIC_SUPABASE_URL']
  if ($serverUrl.Present -and $browserUrl.Value -ne $serverUrl.Value) {
    Add-Failure -Failures $failures -Message 'Browser/server Supabase URL mismatch detected.'
  }
}

if ($failures.Count -gt 0) {
  Write-Host 'Fitness doctor failed.' -ForegroundColor Red
  Write-Host ''
  foreach ($failure in $failures) {
    Write-Host ("- {0}" -f $failure)
  }
  Write-Host ''
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
  Write-Host ("Local env path: {0}" -f $envPath)
  exit 1
}

Write-Host 'Fitness doctor passed.' -ForegroundColor Green
Write-Host ("Repo boundary: {0}" -f $normalizedRepoGitTopLevel)
Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
Write-Host ("Local env path: {0}" -f $envPath)
foreach ($name in $requiredEnv) {
  Write-Host ("{0}: present via {1}" -f $name, $resolvedEnv[$name].Source)
}
