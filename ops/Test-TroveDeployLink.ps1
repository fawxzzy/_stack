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

function Get-DisplayValue {
  param(
    [AllowNull()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return '<missing>'
  }

  return $Value
}

$stackRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  $RepoPath = Join-Path $PSScriptRoot '..\..\fawxzzy-trove'
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path 'config' 'trove-deploy.identity.json'
}

$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$resolvedConfigPath = Get-AbsolutePath -Path $ConfigPath -BasePath $stackRoot
$projectJsonPath = Join-Path $resolvedRepoPath '.vercel\project.json'

if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
  throw ("Trove deploy identity config was not found at {0}." -f $resolvedConfigPath)
}

$deployIdentityConfig = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$expectedTeamId = [string]$deployIdentityConfig.vercel.teamId
$expectedScope = [string]$deployIdentityConfig.vercel.scope
$expectedProjectId = [string]$deployIdentityConfig.vercel.projectId
$expectedProject = [string]$deployIdentityConfig.vercel.project

$repoGitTopLevel = (& git -C $resolvedRepoPath rev-parse --show-toplevel 2>$null)
$repoGitExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
$normalizedRepoGitTopLevel = if ([string]::IsNullOrWhiteSpace($repoGitTopLevel)) { $null } else { [System.IO.Path]::GetFullPath($repoGitTopLevel.Trim()) }
$normalizedRepoPath = [System.IO.Path]::GetFullPath($resolvedRepoPath)

if ($repoGitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($normalizedRepoGitTopLevel) -or $normalizedRepoGitTopLevel -ne $normalizedRepoPath) {
  Write-Host 'Trove deploy blocked before Vercel.' -ForegroundColor Red
  Write-Host 'The target path is not a real standalone Trove repo boundary.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ("git rev-parse --show-toplevel: {0}" -f (Get-DisplayValue -Value $normalizedRepoGitTopLevel))
  Write-Host 'Expected: the Trove repo path must be its own git toplevel before any deploy lane can run.'
  exit 1
}

if (-not (Test-Path -LiteralPath $projectJsonPath)) {
  Write-Host 'Trove deploy blocked before Vercel.' -ForegroundColor Red
  Write-Host 'The repo is not linked to the canonical local Vercel project yet.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ("Expected Vercel identity: team {0} / project {1} ({2}/{3})" -f $expectedTeamId, $expectedProjectId, $expectedScope, $expectedProject)
  Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
  Write-Host ''
  Write-Host 'Expected local file:'
  Write-Host ("  {0}" -f $projectJsonPath)
  Write-Host ''
  Write-Host 'Fix command:'
  Write-Host ("  pnpm dlx vercel --cwd ""{0}"" link --yes --project {1} --scope {2}" -f $resolvedRepoPath, $expectedProjectId, $expectedScope)
  Write-Host '  The project ID is the source of truth; the scope slug only refreshes the current local CLI link metadata.'
  exit 1
}

$projectJson = Get-Content -LiteralPath $projectJsonPath -Raw | ConvertFrom-Json
$linkedTeamId = [string]$projectJson.orgId
$linkedProjectId = [string]$projectJson.projectId
$linkedProjectName = [string]$projectJson.projectName

$mismatches = New-Object System.Collections.Generic.List[string]
$diagnoses = New-Object System.Collections.Generic.List[string]

if ($linkedTeamId -ne $expectedTeamId) {
  $mismatches.Add('.vercel/project.json orgId does not match the required Trove Vercel team ID')
  $diagnoses.Add('Wrong account or team link: the local .vercel metadata points at a different Vercel team ID than the canonical Trove lane.')
}

if ($linkedProjectId -ne $expectedProjectId) {
  $mismatches.Add('.vercel/project.json projectId does not match the required Trove Vercel project ID')
  if ($linkedTeamId -eq $expectedTeamId) {
    $diagnoses.Add('Wrong project link: the repo is linked to the correct team ID but a different project ID.')
  }
}

if ($linkedProjectName -ne $expectedProject) {
  $mismatches.Add('.vercel/project.json projectName does not match the required current Trove project name')
  if ($linkedTeamId -eq $expectedTeamId -and $linkedProjectId -eq $expectedProjectId) {
    $diagnoses.Add('Rename drift: immutable IDs match the canonical Trove project, but the current human-readable project name is stale.')
  }
}

if ($mismatches.Count -gt 0) {
  Write-Host 'Trove deploy blocked before Vercel.' -ForegroundColor Red
  Write-Host 'Preview and production deploys must target the canonical Trove Vercel identity first.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host ("Expected Vercel identity: team {0} / project {1} ({2}/{3})" -f $expectedTeamId, $expectedProjectId, $expectedScope, $expectedProject)
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
  Write-Host ("Local project.json path: {0}" -f $projectJsonPath)
  Write-Host ''
  Write-Host 'Observed local Vercel link state:'
  Write-Host ("  .vercel orgId:       {0}" -f (Get-DisplayValue -Value $linkedTeamId))
  Write-Host ("  .vercel projectId:   {0}" -f (Get-DisplayValue -Value $linkedProjectId))
  Write-Host ("  .vercel projectName: {0}" -f (Get-DisplayValue -Value $linkedProjectName))
  Write-Host ''
  Write-Host 'Mismatch details:'
  foreach ($mismatch in $mismatches) {
    Write-Host ("  - {0}" -f $mismatch)
  }
  if ($diagnoses.Count -gt 0) {
    Write-Host ''
    Write-Host 'Likely classification:'
    foreach ($diagnosis in $diagnoses | Select-Object -Unique) {
      Write-Host ("  - {0}" -f $diagnosis)
    }
  }
  Write-Host ''
  Write-Host 'Fix command:'
  Write-Host ("  pnpm dlx vercel --cwd ""{0}"" link --yes --project {1} --scope {2}" -f $resolvedRepoPath, $expectedProjectId, $expectedScope)
  Write-Host '  The project ID is the source of truth; the scope slug only refreshes the current local CLI link metadata.'
  exit 1
}

Write-Host ("Trove deploy preflight passed for team {0} / project {1} ({2}/{3})." -f $expectedTeamId, $expectedProjectId, $expectedScope, $expectedProject) -ForegroundColor Green
Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
Write-Host ("Local project.json path: {0}" -f $projectJsonPath)
