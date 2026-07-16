param(
    [string]$AtlasRoot = "",
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LauncherSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$manifestPath = Join-Path $PSScriptRoot "launcher-manifest.json"
$manifestDigestPath = Join-Path $PSScriptRoot "launcher-manifest.sha256"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestDigestPath -PathType Leaf)) {
    throw "stack_inbox_launcher_manifest_missing"
}
$expectedManifestDigest = (Get-Content -LiteralPath $manifestDigestPath -Raw).Trim().ToLowerInvariant()
$actualManifestDigest = Get-LauncherSha256 -Path $manifestPath
if ($expectedManifestDigest -ne $actualManifestDigest) { throw "stack_inbox_launcher_manifest_digest_mismatch" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.contract_version -ne "atlas.stack.inbox-launcher-manifest.v1") { throw "stack_inbox_launcher_manifest_version_unsupported" }
foreach ($file in @($manifest.files)) {
    $relativePath = ([string]$file.path).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "stack_inbox_launcher_manifest_path_unsafe" }
    $path = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ("stack_inbox_launcher_file_missing: {0}" -f $file.path) }
    $actual = Get-LauncherSha256 -Path $path
    if ($actual -ne ([string]$file.sha256).ToLowerInvariant() -or (Get-Item -LiteralPath $path).Length -ne [long]$file.bytes) {
        throw ("stack_inbox_launcher_file_integrity_failed: {0}" -f $file.path)
    }
}

if ($VerifyOnly.IsPresent) {
    [pscustomobject]@{ status = "verified"; manifest_path = $manifestPath; manifest_sha256 = $actualManifestDigest; file_count = @($manifest.files).Count } | ConvertTo-Json
    exit 0
}

if ([string]::IsNullOrWhiteSpace($AtlasRoot)) {
    $candidate = $PSScriptRoot
    for ($index = 0; $index -lt 5; $index++) { $candidate = Split-Path -Parent $candidate }
    $AtlasRoot = $candidate
}
$AtlasRoot = [System.IO.Path]::GetFullPath($AtlasRoot)
$repoRoot = Join-Path $AtlasRoot "repos\_stack"
$runnerPath = Join-Path $PSScriptRoot "ops\codex\Start-CodexInboxRunner.ps1"
$configPath = Join-Path $PSScriptRoot "ops\codex\repos\stack\config.toml"
$adapterPath = Join-Path $PSScriptRoot "ops\codex\repos\stack\adapter.json"
$inboxPath = Join-Path $repoRoot ".codex\inbox"
$stateRoot = Join-Path $AtlasRoot "runtime\codex\stack\inbox-sweep"
foreach ($required in @($repoRoot, $runnerPath, $configPath, $adapterPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw ("stack_inbox_launcher_required_path_missing: {0}" -f $required) }
}
$powershellExe = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) { $powershellExe = "powershell.exe" }
$oldTaskName = $env:ATLAS_SCHEDULED_TASK_NAME
try {
    $env:ATLAS_SCHEDULED_TASK_NAME = "AtlasStackInboxSweep"
    & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $runnerPath -RunOnce -TaskName "AtlasStackInboxSweep" -ConfigPath $configPath -RepoRoot $repoRoot -AdapterPath $adapterPath -InboxDir $inboxPath -StateRoot $stateRoot
    $exitCode = $LASTEXITCODE
}
finally {
    $env:ATLAS_SCHEDULED_TASK_NAME = $oldTaskName
}
exit $exitCode
