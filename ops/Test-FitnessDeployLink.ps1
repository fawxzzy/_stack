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

function Resolve-ExpectedValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentName,

    [AllowNull()]
    [string]$ConfigValue,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
  if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
    return [pscustomobject]@{
      Value  = $environmentValue.Trim()
      Source = ("environment variable {0}" -f $EnvironmentName)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($ConfigValue)) {
    return [pscustomobject]@{
      Value  = $ConfigValue.Trim()
      Source = ("config file {0}" -f $ResolvedConfigPath)
    }
  }

  throw ("Fitness deploy identity is missing the expected {0}. Set {1} or update {2}." -f $Label, $EnvironmentName, $ResolvedConfigPath)
}

function Get-PnpmCommand {
  $pnpmCommand = (Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue).Source
  if ([string]::IsNullOrWhiteSpace($pnpmCommand)) {
    $pnpmCommand = (Get-Command 'pnpm' -ErrorAction Stop).Source
  }

  return $pnpmCommand
}

function Invoke-PnpmCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string[]]$ArgumentList
  )

  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()

  try {
    $process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $ArgumentList `
      -Wait `
      -NoNewWindow `
      -PassThru `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath

    $stdoutText = if (Test-Path -LiteralPath $stdoutPath) { (Get-Content -LiteralPath $stdoutPath -Raw) } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Raw) } else { '' }
    $combinedText = ($stdoutText, $stderrText | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine

    return [pscustomobject]@{
      ExitCode = [int]$process.ExitCode
      StdOut   = $stdoutText
      StdErr   = $stderrText
      Combined = $combinedText.Trim()
    }
  }
  finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue
  }
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
$projectJsonPath = Join-Path $resolvedRepoPath '.vercel\project.json'

if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
  throw ("Fitness deploy identity config was not found at {0}." -f $resolvedConfigPath)
}

$deployIdentityConfig = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$configTeamId = if ($null -ne $deployIdentityConfig.vercel) { [string]$deployIdentityConfig.vercel.teamId } else { [string]$deployIdentityConfig.teamId }
$configScope = if ($null -ne $deployIdentityConfig.vercel) { [string]$deployIdentityConfig.vercel.scope } else { [string]$deployIdentityConfig.scope }
$configProjectId = if ($null -ne $deployIdentityConfig.vercel) { [string]$deployIdentityConfig.vercel.projectId } else { [string]$deployIdentityConfig.projectId }
$configProject = if ($null -ne $deployIdentityConfig.vercel) { [string]$deployIdentityConfig.vercel.project } else { [string]$deployIdentityConfig.project }
$configCreateDeployments = if ($null -ne $deployIdentityConfig.vercel -and $null -ne $deployIdentityConfig.vercel.gitProviderOptions) {
  [string]$deployIdentityConfig.vercel.gitProviderOptions.createDeployments
}
elseif ($null -ne $deployIdentityConfig.gitProviderOptions) {
  [string]$deployIdentityConfig.gitProviderOptions.createDeployments
}
else {
  $null
}

$expectedTeamIdInfo = Resolve-ExpectedValue `
  -EnvironmentName 'VERCEL_EXPECTED_TEAM_ID' `
  -ConfigValue $configTeamId `
  -ResolvedConfigPath $resolvedConfigPath `
  -Label 'Vercel team ID'

$expectedScopeInfo = Resolve-ExpectedValue `
  -EnvironmentName 'VERCEL_EXPECTED_SCOPE' `
  -ConfigValue $configScope `
  -ResolvedConfigPath $resolvedConfigPath `
  -Label 'Vercel owner/team scope'

$expectedProjectIdInfo = Resolve-ExpectedValue `
  -EnvironmentName 'VERCEL_EXPECTED_PROJECT_ID' `
  -ConfigValue $configProjectId `
  -ResolvedConfigPath $resolvedConfigPath `
  -Label 'Vercel project ID'

$expectedProjectInfo = Resolve-ExpectedValue `
  -EnvironmentName 'VERCEL_EXPECTED_PROJECT' `
  -ConfigValue $configProject `
  -ResolvedConfigPath $resolvedConfigPath `
  -Label 'Vercel project name'

$expectedTeamId = $expectedTeamIdInfo.Value
$expectedScope = $expectedScopeInfo.Value
$expectedProjectId = $expectedProjectIdInfo.Value
$expectedProject = $expectedProjectInfo.Value
$expectedCreateDeployments = if (-not [string]::IsNullOrWhiteSpace($configCreateDeployments)) { $configCreateDeployments.Trim() } else { 'disabled' }
$pnpmCommand = Get-PnpmCommand

$repoGitTopLevel = (& git -C $resolvedRepoPath rev-parse --show-toplevel 2>$null)
$repoGitExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
$normalizedRepoGitTopLevel = if ([string]::IsNullOrWhiteSpace($repoGitTopLevel)) { $null } else { [System.IO.Path]::GetFullPath($repoGitTopLevel.Trim()) }
$normalizedRepoPath = [System.IO.Path]::GetFullPath($resolvedRepoPath)

if ($repoGitExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($normalizedRepoGitTopLevel) -or $normalizedRepoGitTopLevel -ne $normalizedRepoPath) {
  Write-Host 'Fitness deploy blocked before Vercel.' -ForegroundColor Red
  Write-Host 'The target path is not a real standalone Fitness repo boundary.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ("git rev-parse --show-toplevel: {0}" -f (Get-DisplayValue -Value $normalizedRepoGitTopLevel))
  Write-Host 'Expected: the Fitness repo path must be its own git toplevel before any deploy lane can run.'
  exit 1
}

if (-not (Test-Path -LiteralPath $projectJsonPath)) {
  Write-Host 'Fitness deploy blocked before Vercel.' -ForegroundColor Red
  Write-Host 'The repo is not linked to a local Vercel project yet.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ("Expected Vercel identity: team {0} / project {1}" -f $expectedTeamId, $expectedProjectId)
  Write-Host ("Expected current slug/name: {0}/{1}" -f $expectedScope, $expectedProject)
  Write-Host ("Expected team ID source: {0}" -f $expectedTeamIdInfo.Source)
  Write-Host ("Expected scope source: {0}" -f $expectedScopeInfo.Source)
  Write-Host ("Expected project ID source: {0}" -f $expectedProjectIdInfo.Source)
  Write-Host ("Expected project source: {0}" -f $expectedProjectInfo.Source)
  Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
  Write-Host ''
  Write-Host 'Fix command:'
  Write-Host ("  pnpm dlx vercel@51.6.1 --cwd ""{0}"" link --yes --project {1} --scope {2}" -f $resolvedRepoPath, $expectedProjectId, $expectedScope)
  Write-Host '  The project ID is the source of truth; the scope slug is only the current CLI context for link.'
  exit 1
}

$projectJson = Get-Content -LiteralPath $projectJsonPath -Raw | ConvertFrom-Json
$linkedTeamId = [string]$projectJson.orgId
$linkedProjectId = [string]$projectJson.projectId
$linkedProjectName = [string]$projectJson.projectName

$inspectResult = Invoke-PnpmCapture `
  -FilePath $pnpmCommand `
  -ArgumentList @('dlx', 'vercel@51.6.1', '--cwd', $resolvedRepoPath, 'project', 'inspect')

if ($inspectResult.ExitCode -ne 0) {
  throw ("Unable to inspect the linked Fitness Vercel project for {0}. Output:`n{1}" -f $resolvedRepoPath, $inspectResult.Combined)
}

$inspectText = $inspectResult.Combined

$projectApiResult = Invoke-PnpmCapture `
  -FilePath $pnpmCommand `
  -ArgumentList @('dlx', 'vercel@51.6.1', '--cwd', $resolvedRepoPath, 'api', ('/v9/projects/{0}' -f $expectedProjectId), '--scope', $expectedScope, '--raw')

if ($projectApiResult.ExitCode -ne 0) {
  throw ("Unable to read the linked Fitness Vercel project API state for {0}. Output:`n{1}" -f $resolvedRepoPath, $projectApiResult.Combined)
}

$projectApi = $projectApiResult.StdOut | ConvertFrom-Json
$observedCreateDeployments = if ($null -ne $projectApi.gitProviderOptions) {
  [string]$projectApi.gitProviderOptions.createDeployments
}
else {
  $null
}

$matched = [regex]::Match($inspectText, 'Found Project\s+([^\s/]+)/([^\s\[]+)')
$linkedScope = $null
$inspectedProjectName = $null

if ($matched.Success) {
  $linkedScope = $matched.Groups[1].Value.Trim()
  $inspectedProjectName = $matched.Groups[2].Value.Trim()
}
else {
  $ownerMatch = [regex]::Match($inspectText, "(?m)^\s*Owner\s+(.+?)\s*$")
  $projectMatch = [regex]::Match($inspectText, "(?m)^\s*Name\s+(.+?)\s*$")

  if ($ownerMatch.Success) {
    $linkedScope = $ownerMatch.Groups[1].Value.Trim()
  }

  if ($projectMatch.Success) {
    $inspectedProjectName = $projectMatch.Groups[1].Value.Trim()
  }
}

$mismatches = New-Object System.Collections.Generic.List[string]
$diagnoses = New-Object System.Collections.Generic.List[string]

if ($linkedTeamId -ne $expectedTeamId) {
  $mismatches.Add('.vercel/project.json orgId does not match the required Fitness Vercel team ID')
}

if ($linkedProjectId -ne $expectedProjectId) {
  $mismatches.Add('.vercel/project.json projectId does not match the required Fitness Vercel project ID')
}

if ($linkedProjectName -ne $expectedProject) {
  $mismatches.Add('.vercel/project.json projectName does not match the configured current Fitness project name')
}

if ([string]::IsNullOrWhiteSpace($linkedScope)) {
  $mismatches.Add('vercel project inspect did not return a parseable current owner/team slug')
}
elseif ($linkedScope -ne $expectedScope) {
  $mismatches.Add('vercel project inspect resolved a different current owner/team slug than the configured Fitness slug')
}

if ([string]::IsNullOrWhiteSpace($inspectedProjectName)) {
  $mismatches.Add('vercel project inspect did not return a parseable current project name')
}
elseif ($inspectedProjectName -ne $expectedProject) {
  $mismatches.Add('vercel project inspect resolved a different current project name than the configured Fitness project name')
}

if ([string]::IsNullOrWhiteSpace($observedCreateDeployments)) {
  $mismatches.Add('Vercel project API did not return gitProviderOptions.createDeployments')
}
elseif ($observedCreateDeployments -ne $expectedCreateDeployments) {
  $mismatches.Add(("Vercel Git auto-deploy createDeployments is {0}; expected {1}" -f $observedCreateDeployments, $expectedCreateDeployments))
}

if ($linkedTeamId -ne $expectedTeamId) {
  $diagnoses.Add('Wrong account or team link: the local .vercel metadata points at a different Vercel team ID than the canonical Fitness lane.')
}

if ($linkedTeamId -eq $expectedTeamId -and $linkedProjectId -ne $expectedProjectId) {
  $diagnoses.Add('Wrong project link: the repo is linked to the correct team ID but a different project ID.')
}

if ($linkedTeamId -eq $expectedTeamId -and $linkedProjectId -eq $expectedProjectId -and (
    $linkedProjectName -ne $expectedProject -or
    $linkedScope -ne $expectedScope -or
    $inspectedProjectName -ne $expectedProject
  )) {
  $diagnoses.Add('Rename drift: immutable IDs match the canonical Fitness project, but the configured current slug and/or project name is stale.')
}

if ([string]::IsNullOrWhiteSpace($linkedScope) -or [string]::IsNullOrWhiteSpace($inspectedProjectName)) {
  $diagnoses.Add('CLI inspection did not return the current human-readable identity cleanly. Re-run vercel project inspect manually before deploying if this persists.')
}

if ($observedCreateDeployments -ne $expectedCreateDeployments) {
  $diagnoses.Add('Git auto-deploy drift: disable Git-triggered deployments again before manual Fitness deploys. Use pnpm run fitness:git:autodeploy:disable from _stack.')
}

if ($mismatches.Count -gt 0) {
  Write-Host 'Fitness deploy blocked before Vercel.' -ForegroundColor Red
  Write-Host 'Production deploys must target the canonical Fitness Vercel IDs first, then confirm the current slug/name.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host ("Expected Vercel identity: team {0} / project {1}" -f $expectedTeamId, $expectedProjectId)
  Write-Host ("Expected current slug/name: {0}/{1}" -f $expectedScope, $expectedProject)
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ("Expected team ID source: {0}" -f $expectedTeamIdInfo.Source)
  Write-Host ("Expected scope source: {0}" -f $expectedScopeInfo.Source)
  Write-Host ("Expected project ID source: {0}" -f $expectedProjectIdInfo.Source)
  Write-Host ("Expected project source: {0}" -f $expectedProjectInfo.Source)
  Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
  Write-Host ''
  Write-Host 'Observed Vercel link state:'
  Write-Host ("  .vercel orgId:            {0}" -f (Get-DisplayValue -Value $linkedTeamId))
  Write-Host ("  .vercel projectId:        {0}" -f (Get-DisplayValue -Value $linkedProjectId))
  Write-Host ("  .vercel projectName:      {0}" -f (Get-DisplayValue -Value $linkedProjectName))
  Write-Host ("  inspected owner/team:     {0}" -f (Get-DisplayValue -Value $linkedScope))
  Write-Host ("  inspected project name:   {0}" -f (Get-DisplayValue -Value $inspectedProjectName))
  Write-Host ("  Git auto-deploy state:    {0}" -f (Get-DisplayValue -Value $observedCreateDeployments))
  Write-Host ("  local project.json path:  {0}" -f $projectJsonPath)
  Write-Host ''
  Write-Host 'Mismatch details:'
  foreach ($mismatch in $mismatches) {
    Write-Host ("  - {0}" -f $mismatch)
  }
  if ($diagnoses.Count -gt 0) {
    Write-Host ''
    Write-Host 'Likely classification:'
    foreach ($diagnosis in $diagnoses) {
      Write-Host ("  - {0}" -f $diagnosis)
    }
  }
  Write-Host ''
  Write-Host 'Fix command:'
  Write-Host ("  pnpm dlx vercel@51.6.1 --cwd ""{0}"" link --yes --project {1} --scope {2}" -f $resolvedRepoPath, $expectedProjectId, $expectedScope)
  Write-Host '  The project ID is the source of truth; the scope slug only refreshes the human-readable CLI link metadata.'
  exit 1
}

Write-Host ("Fitness deploy preflight passed for team {0} / project {1} ({2}/{3})." -f $expectedTeamId, $expectedProjectId, $expectedScope, $expectedProject) -ForegroundColor Green
Write-Host ("Expected team ID source: {0}" -f $expectedTeamIdInfo.Source)
Write-Host ("Expected scope source: {0}" -f $expectedScopeInfo.Source)
Write-Host ("Expected project ID source: {0}" -f $expectedProjectIdInfo.Source)
Write-Host ("Expected project source: {0}" -f $expectedProjectInfo.Source)
Write-Host ("Git auto-deploy createDeployments: {0}" -f $observedCreateDeployments)
Write-Host ("Deploy identity config: {0}" -f $resolvedConfigPath)
