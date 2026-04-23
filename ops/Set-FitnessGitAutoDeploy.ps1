[CmdletBinding()]
param(
  [ValidateSet('disabled', 'enabled')]
  [string]$State = 'disabled',

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

$stackRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  $RepoPath = Join-Path $PSScriptRoot '..\..\fawxzzy-fitness'
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path 'config' 'fitness-deploy.identity.json'
}

$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$resolvedConfigPath = Get-AbsolutePath -Path $ConfigPath -BasePath $stackRoot
$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$projectId = [string]$config.vercel.projectId
$scope = [string]$config.vercel.scope

if ([string]::IsNullOrWhiteSpace($projectId) -or [string]::IsNullOrWhiteSpace($scope)) {
  throw ("Fitness deploy identity config is missing projectId or scope: {0}" -f $resolvedConfigPath)
}

$bodyPath = [System.IO.Path]::GetTempFileName()
try {
  $body = @{
    gitProviderOptions = @{
      createDeployments = $State
    }
  } | ConvertTo-Json -Depth 5

  Set-Content -LiteralPath $bodyPath -Value $body -NoNewline
  pnpm dlx vercel@51.6.1 --cwd $resolvedRepoPath api "/v9/projects/$projectId" --scope $scope --method PATCH --input $bodyPath --silent

  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}
finally {
  Remove-Item -LiteralPath $bodyPath -ErrorAction SilentlyContinue
}

Write-Host ("Fitness Vercel Git auto-deploy createDeployments set to {0}." -f $State) -ForegroundColor Green
