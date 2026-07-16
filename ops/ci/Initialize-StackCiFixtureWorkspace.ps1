param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$StackRepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:GITHUB_ACTIONS -ne "true") {
    throw "stack_ci_fixture_workspace_github_actions_only"
}

$resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$resolvedStackRepoRoot = [System.IO.Path]::GetFullPath($StackRepoRoot)
$atlasRoot = Join-Path $resolvedWorkspaceRoot "atlas"
$expectedStackRepoRoot = Join-Path $atlasRoot "repos\_stack"
if (-not [string]::Equals($resolvedStackRepoRoot, $expectedStackRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "stack_ci_fixture_workspace_repo_layout_mismatch"
}
if (-not (Test-Path -LiteralPath (Join-Path $resolvedStackRepoRoot "package.json") -PathType Leaf)) {
    throw "stack_ci_fixture_workspace_stack_checkout_missing"
}

$fixtureRoot = Join-Path $resolvedStackRepoRoot "tests\fixtures\ci-workspace"
$fixtureAtlasRoot = Join-Path $fixtureRoot "atlas"
$manifestPath = Join-Path $fixtureRoot "snapshot-manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $fixtureAtlasRoot -PathType Container)) {
    throw "stack_ci_fixture_workspace_snapshot_missing"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]$manifest.schema_version -ne "atlas.stack.ci-workspace-fixture.v1") {
    throw "stack_ci_fixture_workspace_manifest_version_unsupported"
}
if ([string]$manifest.hash_mode -ne "utf8-lf-normalized-sha256") {
    throw "stack_ci_fixture_workspace_hash_mode_unsupported"
}
foreach ($file in @($manifest.files)) {
    $fixturePath = Join-Path $fixtureRoot ([string]$file.path).Replace("/", "\")
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw ("stack_ci_fixture_workspace_file_missing: {0}" -f $file.path)
    }
    $normalizedText = [System.IO.File]::ReadAllText($fixturePath).Replace("`r`n", "`n").Replace("`r", "`n")
    $normalizedBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $actualSha256 = ([System.BitConverter]::ToString($sha256.ComputeHash($normalizedBytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha256.Dispose() }
    if ($actualSha256 -ne [string]$file.sha256) {
        throw ("stack_ci_fixture_workspace_file_hash_mismatch: {0}" -f $file.path)
    }
}

New-Item -ItemType Directory -Path $atlasRoot -Force | Out-Null
foreach ($item in @(Get-ChildItem -LiteralPath $fixtureAtlasRoot -Force)) {
    Copy-Item -LiteralPath $item.FullName -Destination $atlasRoot -Recurse -Force
}

$brandSourcePath = Join-Path $atlasRoot "branding\source\stack-release-launcher.ico"
New-Item -ItemType Directory -Path (Split-Path -Parent $brandSourcePath) -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $resolvedStackRepoRoot "ops\assets\release-launcher.ico") -Destination $brandSourcePath -Force

$discordOsRoot = Join-Path $atlasRoot "repos\DiscordOS"
& git -C $discordOsRoot init --quiet
if ($LASTEXITCODE -ne 0) { throw "stack_ci_fixture_discordos_git_init_failed" }
& git -C $discordOsRoot config user.name "Stack CI Fixture"
& git -C $discordOsRoot config user.email "stack-ci-fixture@example.invalid"
& git -C $discordOsRoot add README.md
if ($LASTEXITCODE -ne 0) { throw "stack_ci_fixture_discordos_git_add_failed" }
$longRelativePath = "p/" + ("x" * 216)
$blobSha = ("fixture`n" | & git -C $discordOsRoot hash-object -w --stdin).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($blobSha)) { throw "stack_ci_fixture_discordos_blob_failed" }
& git -C $discordOsRoot update-index --add --cacheinfo ("100644,{0},{1}" -f $blobSha, $longRelativePath)
if ($LASTEXITCODE -ne 0) { throw "stack_ci_fixture_discordos_index_failed" }
& git -C $discordOsRoot commit --quiet -m "fixture baseline"
if ($LASTEXITCODE -ne 0) { throw "stack_ci_fixture_discordos_commit_failed" }

$result = [ordered]@{
    mode = "github_actions_versioned_fixture"
    manifest = $manifestPath
    manifest_source_revisions = $manifest.source_revisions
    file_count = @($manifest.files).Count
    atlas_root = $atlasRoot
    stack_repo_root = $resolvedStackRepoRoot
    sibling_repository_clones = 0
    persisted_credentials = $false
    scheduled_task_registration = $false
}
$resultJson = $result | ConvertTo-Json -Depth 8
Write-Host "stack-ci-fixture-mode: github_actions_versioned_fixture"
Write-Output $resultJson
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    @(
        "### _stack verification fixture mode",
        "",
        '- Mode: `github_actions_versioned_fixture`',
        "- Versioned fixture files: $(@($manifest.files).Count)",
        "- Sibling repository clones: 0",
        "- Persisted checkout credentials: false",
        "- Scheduled task registration: false"
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}
