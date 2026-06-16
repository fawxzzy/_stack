[CmdletBinding()]
param(
  [string]$RepoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
  $RepoPath = Join-Path $PSScriptRoot '..\..\mazer'
}

$resolvedRepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$expectedName = 'Zachariah Redfield'
$expectedEmail = 'zjhredfield@icloud.com'

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

function Invoke-GitCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [switch]$AllowEmpty
  )

  $output = & git -C $resolvedRepoPath @Arguments 2>$null
  $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }

  if ($exitCode -ne 0) {
    if ($AllowEmpty) {
      return $null
    }

    throw ("git {0} failed for {1} with exit code {2}." -f ($Arguments -join ' '), $resolvedRepoPath, $exitCode)
  }

  $text = ($output | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

  return $text
}

$configName = Invoke-GitCapture -Arguments @('config', 'user.name') -AllowEmpty
$configEmail = Invoke-GitCapture -Arguments @('config', 'user.email') -AllowEmpty
$commitAuthorText = Invoke-GitCapture -Arguments @('log', '-1', '--format=%an%n%ae')
$commitAuthorParts = @($commitAuthorText -split "`r?`n")

if ($commitAuthorParts.Count -lt 2) {
  throw "Unable to read the latest Mazer commit author."
}

$commitAuthorName = $commitAuthorParts[0].Trim()
$commitAuthorEmail = $commitAuthorParts[1].Trim()

$mismatches = New-Object System.Collections.Generic.List[string]

if ($configName -ne $expectedName) {
  $mismatches.Add("repo git config user.name does not match the required owner name")
}

if ($configEmail -ne $expectedEmail) {
  $mismatches.Add("repo git config user.email does not match the required owner email")
}

if ($commitAuthorName -ne $expectedName) {
  $mismatches.Add("latest commit author name does not match the required owner name")
}

if ($commitAuthorEmail -ne $expectedEmail) {
  $mismatches.Add("latest commit author email does not match the required owner email")
}

if ($mismatches.Count -gt 0) {
  Write-Host "Mazer deploy blocked before Vercel." -ForegroundColor Red
  Write-Host "Private Hobby-team deploys require the owner commit author on the Mazer repo." -ForegroundColor Yellow
  Write-Host ""
  Write-Host ("Expected owner identity: {0} <{1}>" -f $expectedName, $expectedEmail)
  Write-Host ("Repo path: {0}" -f $resolvedRepoPath)
  Write-Host ""
  Write-Host "Observed repo identity:"
  Write-Host ("  git config user.name:  {0}" -f (Get-DisplayValue -Value $configName))
  Write-Host ("  git config user.email: {0}" -f (Get-DisplayValue -Value $configEmail))
  Write-Host ("  latest commit author:  {0} <{1}>" -f (Get-DisplayValue -Value $commitAuthorName), (Get-DisplayValue -Value $commitAuthorEmail))
  Write-Host ""
  Write-Host "Mismatch details:"
  foreach ($mismatch in $mismatches) {
    Write-Host ("  - {0}" -f $mismatch)
  }
  Write-Host ""
  Write-Host "Fix commands:"
  Write-Host ("  git -C ""{0}"" config user.name ""{1}""" -f $resolvedRepoPath, $expectedName)
  Write-Host ("  git -C ""{0}"" config user.email ""{1}""" -f $resolvedRepoPath, $expectedEmail)
  Write-Host ("  git -C ""{0}"" commit --amend --reset-author --no-edit" -f $resolvedRepoPath)
  exit 1
}

Write-Host ("Mazer deploy preflight passed for {0} <{1}>." -f $expectedName, $expectedEmail) -ForegroundColor Green
