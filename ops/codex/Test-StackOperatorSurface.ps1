Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $result = Invoke-ProcessCapture -FilePath "git" -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -ne 0) {
        $errorText = if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
            $result.StdErr.Trim()
        }
        else {
            $result.StdOut.Trim()
        }

        throw ("git {0} failed in {1}: {2}" -f ($Arguments -join " "), $WorkingDirectory, $errorText)
    }

    return $result
}

function Initialize-WorktreeTopologyManifestBridge {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $resolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $worktreesRoot = [System.IO.Path]::GetDirectoryName($resolvedRepoRoot)
    if ([string]::IsNullOrWhiteSpace($worktreesRoot) -or ([System.IO.Path]::GetFileName($worktreesRoot) -ine "worktrees")) {
        return [pscustomobject]@{
            created = $false
            path = $null
        }
    }

    $codexRoot = [System.IO.Path]::GetDirectoryName($worktreesRoot)
    if ([string]::IsNullOrWhiteSpace($codexRoot) -or ([System.IO.Path]::GetFileName($codexRoot) -ine ".codex")) {
        return [pscustomobject]@{
            created = $false
            path = $null
        }
    }

    $logicalStackRoot = [System.IO.Path]::GetDirectoryName($codexRoot)
    $sourcePath = [System.IO.Path]::GetFullPath((Join-Path -Path $logicalStackRoot -ChildPath "..\..\docs\LIFELINE_TOPOLOGY_MANIFEST.json"))
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw ("Atlas topology manifest bridge source was not found: {0}" -f $sourcePath)
    }

    $bridgeDirectory = Join-Path -Path $codexRoot -ChildPath "docs"
    $bridgePath = Join-Path -Path $bridgeDirectory -ChildPath "LIFELINE_TOPOLOGY_MANIFEST.json"
    if (Test-Path -LiteralPath $bridgePath) {
        return [pscustomobject]@{
            created = $false
            path = $bridgePath
        }
    }

    New-Item -ItemType Directory -Path $bridgeDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $bridgePath -Force
    return [pscustomobject]@{
        created = $true
        path = $bridgePath
    }
}

$topologyManifestBridge = $null

try {
$topologyManifestBridge = Initialize-WorktreeTopologyManifestBridge -RepoRoot (Get-Location).Path

$requiredFiles = @(
    "AGENTS.md",
    "README.md",
    "config/release-targets.json",
    "docs/codex-orchestration.md",
    "docs/dispatcher-protocol.md",
    "ops/assets/release-launcher.ico",
    "ops/Install-ReleaseLauncherShortcut.ps1",
    "ops/Open-ReleaseLauncher.ps1",
    "ops/Test-MazerDeployLink.ps1",
    "ops/Test-TroveDeployLink.ps1",
    "ops/codex/Start-CodexInboxRunner.ps1",
    "ops/codex/Invoke-CodexRepoTask.ps1",
    "ops/codex/Invoke-CodexCanonicalWorkspaceTask.ps1",
    "ops/codex/CodexRunner.Common.ps1",
    "ops/codex/Test-AtlasWorkspaceWriter.ps1",
    "ops/codex/Test-StackOperatorSurface.ps1",
    "ops/codex/adapter.schema.json",
    "ops/codex/execution-classes/atlas-workspace.writer.json",
    "ops/codex/repos/stack/adapter.json",
    "ops/codex/repos/stack/config.toml",
    "ops/stack/StackWorkerArtifacts.ps1",
    "ops/stack/Test-StackWorkerArtifacts.ps1",
    "ops/bin/release-launcher.cmd",
    "package.json",
    "config/mazer-deploy.identity.json",
    "config/trove-deploy.identity.json",
    "scripts/command-runner.mjs",
    "scripts/command-runner.test.mjs",
    "scripts/release-launcher.test.mjs",
    "scripts/release-launcher.mjs",
    "scripts/atlas-topology.mjs",
    ".vscode/tasks.json",
    "docs/runbooks/STACK-WORKER-FLOW.md",
    "docs/examples/stack-worker-artifacts/assignment.example.json",
    "docs/examples/stack-worker-artifacts/status.running.example.json",
    "docs/examples/stack-worker-artifacts/status.completed.example.json",
    "docs/examples/stack-worker-artifacts/completion.example.json",
    "docs/examples/stack-worker-artifacts/merge-request.example.json",
    "templates/child-task-handoff.md",
    "workspace.manifest.json"
)

$missingFiles = @(
    $requiredFiles |
    Where-Object { -not (Test-Path -LiteralPath $_) }
)
if ($missingFiles.Count -gt 0) {
    throw ("Missing required _stack operator files: {0}" -f ($missingFiles -join ", "))
}

$package = Get-Content -LiteralPath "package.json" -Raw | ConvertFrom-Json
$packageScripts = @($package.scripts.PSObject.Properties.Name)
$requiredScripts = @(
    "ops:install-shortcut",
    "release:launcher",
    "codex:atlas-workspace:task",
    "codex:stack:inbox",
    "codex:stack:inbox:once",
    "codex:stack:inbox:bootstrap:once",
    "codex:stack:task",
    "codex:stack:task:bootstrap",
    "codex:stack:verify",
    "trove:deploy:preflight"
)
$missingScripts = @(
    $requiredScripts |
    Where-Object { $_ -notin $packageScripts }
)
if ($missingScripts.Count -gt 0) {
    throw ("Missing required _stack Codex scripts: {0}" -f ($missingScripts -join ", "))
}

$tasks = Get-Content -LiteralPath ".vscode/tasks.json" -Raw | ConvertFrom-Json
$taskLabels = @($tasks.tasks | ForEach-Object { $_.label })
$requiredTaskLabels = @(
    "Release: Launcher",
    "Codex: Atlas Workspace Task",
    "Codex: Stack Inbox",
    "Codex: Stack Inbox (Once)",
    "Codex: Stack Task",
    "Codex: Stack Verify"
)
$missingTaskLabels = @(
    $requiredTaskLabels |
    Where-Object { $_ -notin $taskLabels }
)
if ($missingTaskLabels.Count -gt 0) {
    throw ("Missing required _stack VS Code tasks: {0}" -f ($missingTaskLabels -join ", "))
}

$taskRunnerText = Get-Content -LiteralPath "ops/codex/Invoke-CodexRepoTask.ps1" -Raw
foreach ($requiredSnippet in @(
    '[string]$Model = ""',
    '[string]$Reasoning = ""',
    '[string]$Speed = ""',
    '[string]$Permissions = ""',
    '[string]$PermissionProfile = ""',
    '[string]$SandboxMode = ""',
    '[string]$ApprovalPolicy = ""',
    '[string]$WebSearch = ""',
    'model = $Model',
    'reasoning = $Reasoning',
    'speed = $Speed',
    'permissions = $Permissions',
    'permission_profile = $PermissionProfile',
    'sandbox_mode = $SandboxMode',
    'approval = $ApprovalPolicy',
    'web_search = $WebSearch'
)) {
    if (-not $taskRunnerText.Contains($requiredSnippet)) {
        throw ("Invoke-CodexRepoTask.ps1 is missing runtime-policy pass-through snippet: {0}" -f $requiredSnippet)
    }
}

$inboxRunnerText = Get-Content -LiteralPath "ops/codex/Start-CodexInboxRunner.ps1" -Raw
foreach ($requiredSnippet in @(
    '[string]$Model = ""',
    '[string]$Reasoning = ""',
    '[string]$Speed = ""',
    '[string]$Permissions = ""',
    '[string]$PermissionProfile = ""',
    '[string]$SandboxMode = ""',
    '[string]$ApprovalPolicy = ""',
    '[string]$WebSearch = ""',
    '$taskArguments += @("-Model", $Model)',
    '$taskArguments += @("-Reasoning", $Reasoning)',
    '$taskArguments += @("-Speed", $Speed)',
    '$taskArguments += @("-Permissions", $Permissions)',
    '$taskArguments += @("-PermissionProfile", $PermissionProfile)',
    '$taskArguments += @("-SandboxMode", $SandboxMode)',
    '$taskArguments += @("-ApprovalPolicy", $ApprovalPolicy)',
    '$taskArguments += @("-WebSearch", $WebSearch)'
)) {
    if (-not $inboxRunnerText.Contains($requiredSnippet)) {
        throw ("Start-CodexInboxRunner.ps1 is missing runtime-policy forwarding snippet: {0}" -f $requiredSnippet)
    }
}

& node ".\scripts\release-launcher.mjs" --list | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "_stack release launcher config validation failed."
}

& node --test ".\scripts\command-runner.test.mjs" ".\scripts\release-launcher.test.mjs" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "_stack launcher regression coverage failed."
}

$launcherListOutput = & node ".\scripts\release-launcher.mjs" --list
if ($LASTEXITCODE -ne 0) {
    throw "_stack release launcher list command failed."
}
if (($launcherListOutput -join "`n") -notmatch "\[fitness/prod\]") {
    throw "_stack release launcher did not expose the canonical Atlas service key for the prod target."
}

$launcherDryRunOutput = & node ".\scripts\release-launcher.mjs" --target "fitness-preview" --dry-run
if ($LASTEXITCODE -ne 0) {
    throw "_stack release launcher dry-run failed for the Fitness preview target."
}
if (($launcherDryRunOutput -join "`n") -notmatch "pr preview:\s+pr-\{number\}\.fitness\.fawxzzy\.com") {
    throw "_stack release launcher did not surface the Atlas PR preview naming hint for Fitness preview."
}

$mazerRepoPath = Join-Path -Path (Get-Location).Path -ChildPath "..\fawxzzy-mazer"
if (Test-Path -LiteralPath $mazerRepoPath) {
    $mazerIdentityOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File ".\ops\Test-MazerDeployLink.ps1" -ConfigPath ".\config\mazer-deploy.identity.json"
    if ($LASTEXITCODE -ne 0) {
        throw "_stack Mazer deploy identity preflight failed against the local canonical Vercel link."
    }
    if (($mazerIdentityOutput -join "`n") -notmatch "Mazer deploy link preflight passed") {
        throw "_stack Mazer deploy identity preflight did not report a clear pass message."
    }
}
else {
    Write-Host ("Skipping _stack Mazer deploy identity preflight because the workspace does not contain {0}." -f $mazerRepoPath)
}

$topologyFailureRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("stack-topology-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $topologyFailureRoot -Force | Out-Null

try {
    $invalidConfigPath = Join-Path -Path $topologyFailureRoot -ChildPath "invalid-release-targets.json"
    $invalidConfig = @"
{
  "version": 1,
  "actions": [
    {
      "id": "preview",
      "label": "Preview",
      "description": "Deploy the current app to its standard preview target."
    }
  ],
  "groups": [
    {
      "id": "release",
      "label": "Release",
      "description": "Approved preview and prod deploy paths."
    }
  ],
  "targets": [
    {
      "id": "lifeline-preview-invalid",
      "group": "release",
      "action": "preview",
      "advanced": false,
      "app": "lifeline",
      "environment": "preview",
      "label": "Lifeline Preview",
      "description": "Invalid preview target used to prove Atlas topology enforcement.",
      "script": "fitness:verify",
      "notes": [
        "This fixture must fail because Lifeline has no preview environment in Atlas topology."
      ],
      "tags": [
        "test",
        "lifeline"
      ]
    }
  ]
}
"@
    [System.IO.File]::WriteAllText($invalidConfigPath, $invalidConfig)

    $invalidStdoutPath = Join-Path -Path $topologyFailureRoot -ChildPath "invalid-release-stdout.log"
    $invalidStderrPath = Join-Path -Path $topologyFailureRoot -ChildPath "invalid-release-stderr.log"
    $invalidConfigProcess = Start-Process `
        -FilePath "node" `
        -ArgumentList @(".\scripts\release-launcher.mjs", "--config", $invalidConfigPath, "--list") `
        -WorkingDirectory (Get-Location).Path `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $invalidStdoutPath `
        -RedirectStandardError $invalidStderrPath

    $invalidConfigOutput = @()
    if (Test-Path -LiteralPath $invalidStdoutPath) {
        $invalidConfigOutput += Get-Content -LiteralPath $invalidStdoutPath
    }
    if (Test-Path -LiteralPath $invalidStderrPath) {
        $invalidConfigOutput += Get-Content -LiteralPath $invalidStderrPath
    }

    if ($invalidConfigProcess.ExitCode -eq 0) {
        throw "_stack release launcher accepted a preview target that Atlas topology forbids."
    }

    if (($invalidConfigOutput -join "`n") -notmatch "lifeline does not expose a preview environment") {
        throw "_stack release launcher did not report a clear Atlas topology contradiction for the invalid Lifeline preview target."
    }
}
finally {
    if (Test-Path -LiteralPath $topologyFailureRoot) {
        Remove-Item -LiteralPath $topologyFailureRoot -Recurse -Force
    }
}

$mazerPreflightFailureRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("mazer-identity-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $mazerPreflightFailureRoot -Force | Out-Null

try {
    & git -C $mazerPreflightFailureRoot init | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "_stack Mazer deploy identity fixture could not initialize a temporary git repo."
    }

    $vercelDir = Join-Path -Path $mazerPreflightFailureRoot -ChildPath ".vercel"
    New-Item -ItemType Directory -Path $vercelDir -Force | Out-Null

    $invalidProjectJsonPath = Join-Path -Path $vercelDir -ChildPath "project.json"
    $invalidProjectJson = @"
{
  "projectId": "prj_invalid_fixture",
  "orgId": "team_CMJn7MvzFZZBnhNnjVUZF2RD",
  "projectName": "fawxzzy-mazer"
}
"@
    [System.IO.File]::WriteAllText($invalidProjectJsonPath, $invalidProjectJson)

    $invalidStdoutPath = Join-Path -Path $mazerPreflightFailureRoot -ChildPath "invalid-stdout.log"
    $invalidStderrPath = Join-Path -Path $mazerPreflightFailureRoot -ChildPath "invalid-stderr.log"
    $invalidPreflightProcess = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ".\ops\Test-MazerDeployLink.ps1", "-RepoPath", $mazerPreflightFailureRoot, "-ConfigPath", ".\config\mazer-deploy.identity.json") `
        -WorkingDirectory (Get-Location).Path `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $invalidStdoutPath `
        -RedirectStandardError $invalidStderrPath

    $invalidPreflightOutput = @()
    if (Test-Path -LiteralPath $invalidStdoutPath) {
        $invalidPreflightOutput += Get-Content -LiteralPath $invalidStdoutPath
    }
    if (Test-Path -LiteralPath $invalidStderrPath) {
        $invalidPreflightOutput += Get-Content -LiteralPath $invalidStderrPath
    }

    if ($invalidPreflightProcess.ExitCode -eq 0) {
        throw "_stack Mazer deploy identity preflight accepted a mismatched project fixture."
    }

    if (($invalidPreflightOutput -join "`n") -notmatch "projectId does not match the required Mazer Vercel project ID") {
        throw "_stack Mazer deploy identity preflight did not report the expected projectId mismatch."
    }
}
finally {
    if (Test-Path -LiteralPath $mazerPreflightFailureRoot) {
        Remove-Item -LiteralPath $mazerPreflightFailureRoot -Recurse -Force
    }
}

$stackAdapter = Get-Content -LiteralPath "ops/codex/repos/stack/adapter.json" -Raw | ConvertFrom-Json
if ($stackAdapter.pushPolicy.mode -ne "manual-only" -or -not $stackAdapter.pushPolicy.skipPush -or $stackAdapter.pushPolicy.allowAutoPush) {
    throw "_stack adapter pushPolicy must stay manual-only with auto-push disabled."
}
if ($stackAdapter.execution.baseRef -ne "origin/main") {
    throw "_stack adapter execution.baseRef must keep origin/main as the preferred base ref."
}
if ($stackAdapter.exports.formatPatchBaseRef -ne "origin/main") {
    throw "_stack adapter exports.formatPatchBaseRef must keep origin/main as the preferred patch base ref."
}
if ($stackAdapter.localLandingPolicy.mode -ne "ff-only" -or $stackAdapter.localLandingPolicy.targetBranch -ne "main") {
    throw "_stack adapter localLandingPolicy must be ff-only on local main."
}
if (
    $null -ne (Get-ObjectPropertyValue -Object $stackAdapter.execution -Name "defaultSandbox" -DefaultValue $null) -or
    $null -ne (Get-ObjectPropertyValue -Object $stackAdapter.execution -Name "documentedWindowsFallback" -DefaultValue $null)
) {
    throw "_stack adapter execution contract must keep runtime policy defaults out of adapter.json."
}

$atlasWorkspaceExecutionClass = Get-Content -LiteralPath "ops/codex/execution-classes/atlas-workspace.writer.json" -Raw | ConvertFrom-Json
if ([string]$atlasWorkspaceExecutionClass.executionClass -ne "canonical_workspace") {
    throw "Atlas workspace writer execution class must be canonical_workspace."
}
if ([string]$atlasWorkspaceExecutionClass.pushPolicy.mode -ne "manual-only" -or -not $atlasWorkspaceExecutionClass.pushPolicy.skipPush -or $atlasWorkspaceExecutionClass.pushPolicy.allowAutoPush) {
    throw "Atlas workspace writer push policy must stay manual-only with auto-push disabled."
}
if ([string]$atlasWorkspaceExecutionClass.mutationAdmission.defaultMode -ne "read-only") {
    throw "Atlas workspace writer must default to read-only mutation admission."
}
if (-not [bool]$atlasWorkspaceExecutionClass.canonicalRoot.requireGitDirectory) {
    throw "Atlas workspace writer must require a real canonical .git directory."
}
$atlasWorkspaceRunnerText = Get-Content -LiteralPath "ops/codex/Invoke-CodexCanonicalWorkspaceTask.ps1" -Raw
foreach ($requiredSnippet in @(
    'Join-Path -Path $resolvedPath -ChildPath ".git"',
    'Test-Path -LiteralPath $gitDirectory -PathType Container',
    'canonical_workspace_git_directory_required'
)) {
    if (-not $atlasWorkspaceRunnerText.Contains($requiredSnippet)) {
        throw ("Atlas workspace writer must keep the explicit canonical .git guard proof snippet: {0}" -f $requiredSnippet)
    }
}

$stackConfig = ConvertFrom-SimpleToml -Path "ops/codex/repos/stack/config.toml"
if ([string]$stackConfig.runtime_policy.permissions -ne "full-access") {
    throw "_stack runtime_policy.permissions must default governed stack jobs to full access."
}
if ([string]$stackConfig.runtime_policy.permission_profile -ne ":danger-full-access") {
    throw "_stack runtime_policy.permission_profile must use the modern :danger-full-access profile."
}
if ($stackConfig.runtime_policy.ContainsKey("sandbox_mode")) {
    throw "_stack runtime policy defaults must not mix a modern permission profile with a legacy sandbox mode."
}

$physicalStackRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..\..")).Path
$gitCommonDirectory = (Invoke-GitChecked -WorkingDirectory $physicalStackRoot -Arguments @("rev-parse", "--git-common-dir")).StdOut.Trim()
if (-not [System.IO.Path]::IsPathRooted($gitCommonDirectory)) {
    $gitCommonDirectory = Join-Path -Path $physicalStackRoot -ChildPath $gitCommonDirectory
}
$logicalStackRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($gitCommonDirectory))
$canonicalOwnerRoots = @{
    playbook = (Resolve-Path -LiteralPath (Join-Path -Path (Split-Path -Parent $logicalStackRoot) -ChildPath "playbook")).Path
    lifeline = (Resolve-Path -LiteralPath (Join-Path -Path (Split-Path -Parent $logicalStackRoot) -ChildPath "lifeline")).Path
}
$workspaceManifest = Get-Content -LiteralPath "workspace.manifest.json" -Raw | ConvertFrom-Json

foreach ($ownerId in @("playbook", "lifeline")) {
    $configPath = Join-Path -Path $physicalStackRoot -ChildPath ("ops\codex\repos\{0}\config.toml" -f $ownerId)
    $config = ConvertFrom-SimpleToml -Path $configPath
    $logicalConfigDirectory = Join-Path -Path $logicalStackRoot -ChildPath ("ops\codex\repos\{0}" -f $ownerId)
    $resolvedConfigCandidate = Join-Path -Path $logicalConfigDirectory -ChildPath ([string]$config.repo_root)
    $resolvedManifestCandidate = Join-Path -Path $logicalStackRoot -ChildPath ([string]$workspaceManifest.repos.$ownerId.path)
    $resolvedConfigCandidate = [System.IO.Path]::GetFullPath($resolvedConfigCandidate)
    $resolvedManifestCandidate = [System.IO.Path]::GetFullPath($resolvedManifestCandidate)
    $resolvedConfigRoot = (Resolve-Path -LiteralPath $resolvedConfigCandidate).Path
    $resolvedManifestRoot = (Resolve-Path -LiteralPath $resolvedManifestCandidate).Path

    Assert-Condition -Condition ($resolvedConfigRoot -eq $canonicalOwnerRoots[$ownerId]) -Message ("{0} config repo_root must resolve to the canonical owner checkout." -f $ownerId)
    Assert-Condition -Condition ($resolvedManifestRoot -eq $canonicalOwnerRoots[$ownerId]) -Message ("{0} workspace manifest path must resolve to the canonical owner checkout." -f $ownerId)
}

$canonicalOwnerContractPaths = @(
    (Join-Path -Path $canonicalOwnerRoots.playbook -ChildPath "docs\contracts\WORKFLOW_PACK_REUSE_CONTRACT.md"),
    (Join-Path -Path $canonicalOwnerRoots.playbook -ChildPath "docs\CONSUMER_INTEGRATION_CONTRACT.md"),
    (Join-Path -Path $canonicalOwnerRoots.lifeline -ChildPath "docs\contracts\privileged-execution-contract.md"),
    (Join-Path -Path $canonicalOwnerRoots.lifeline -ChildPath "examples\privileged-execution\capability-profile.json"),
    (Join-Path -Path $canonicalOwnerRoots.lifeline -ChildPath "examples\privileged-execution\capability-profile.scoped-write-dry-run.json")
)
foreach ($ownerContractPath in $canonicalOwnerContractPaths) {
    Assert-Condition -Condition (Test-Path -LiteralPath $ownerContractPath) -Message ("Canonical owner contract or fixture is missing: {0}" -f $ownerContractPath)
}

$activeOwnerPathSurfaces = @(
    "workspace.manifest.json",
    "ops/codex/repos/playbook/config.toml",
    "ops/codex/repos/lifeline/config.toml",
    "docs/codex-orchestration.md",
    "docs/dispatcher-protocol.md",
    "docs/STACK-ORCHESTRATION-ADOPTION.md",
    "ops/codex/Test-StackOperatorSurface.ps1",
    "ops/stack/Test-StackWorkerArtifacts.ps1"
)
$staleOwnerAliases = @("fawxzzy-" + "playbook", "fawxzzy-" + "lifeline")
foreach ($surfacePath in $activeOwnerPathSurfaces) {
    $surfaceText = [System.IO.File]::ReadAllText((Join-Path -Path $physicalStackRoot -ChildPath $surfacePath))
    foreach ($staleOwnerAlias in $staleOwnerAliases) {
        Assert-Condition -Condition (-not $surfaceText.Contains($staleOwnerAlias)) -Message ("Active owner path surface still contains retired alias '{0}': {1}" -f $staleOwnerAlias, $surfacePath)
    }
}

$disabledLandingAdapters = @(
    "ops/codex/repos/atlas/adapter.json",
    "ops/codex/repos/playbook/adapter.json",
    "ops/codex/repos/lifeline/adapter.json"
)
foreach ($adapterPath in $disabledLandingAdapters) {
    $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
    if ($adapter.localLandingPolicy.mode -ne "disabled") {
        throw ("Adapter must keep local landing disabled by default in this rollout: {0}" -f $adapterPath)
    }
    if (
        $null -ne (Get-ObjectPropertyValue -Object $adapter.execution -Name "defaultSandbox" -DefaultValue $null) -or
        $null -ne (Get-ObjectPropertyValue -Object $adapter.execution -Name "documentedWindowsFallback" -DefaultValue $null)
    ) {
        throw ("Adapter execution contract must not keep runtime policy defaults in adapter.json: {0}" -f $adapterPath)
    }
}

$playbookAdapter = Get-Content -LiteralPath "ops/codex/repos/playbook/adapter.json" -Raw | ConvertFrom-Json
$requiredPlaybookMutationSurfaces = @(
    ".codex/**",
    "packages/engine/src/release/changelog/**",
    "packages/engine/src/release/index.ts",
    "packages/engine/src/index.ts",
    "packages/cli/src/commands/changelog/**",
    "packages/cli/src/commands/changelog.ts",
    "packages/cli/src/commands/index.ts",
    "packages/cli/src/lib/commandMetadata.ts",
    "docs/CHANGELOG-GENERATOR.md",
    "docs/RELEASING.md",
    "docs/CHANGELOG.md",
    ".github/workflows/changelog.yml",
    "CHANGELOG-GENERATOR-PLAN.md",
    "docs/codex/CHANGELOG-GENERATOR-PLAN.md"
)
foreach ($requiredSurface in $requiredPlaybookMutationSurfaces) {
    if ($requiredSurface -notin $playbookAdapter.allowedMutationSurfaces) {
        throw ("Playbook adapter is missing the changelog-generator mutation surface: {0}" -f $requiredSurface)
    }
}

$forbiddenPlaybookMutationSurfaces = @(
    "packages/**",
    "packages/engine/**",
    "packages/cli/**",
    "docs/**",
    ".github/**",
    "scripts/**"
)
foreach ($forbiddenSurface in $forbiddenPlaybookMutationSurfaces) {
    if ($forbiddenSurface -in $playbookAdapter.allowedMutationSurfaces) {
        throw ("Playbook adapter must not widen to the broad mutation surface: {0}" -f $forbiddenSurface)
    }
}

$parserTestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("stack-parser-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $parserTestRoot -Force | Out-Null

try {
    $promptCases = @(
        @{
            Name = "explicit title"
            FileName = "explicit-title.md"
            Content = @"
Title: Lifeline smoke title
Verify: pnpm ci:verify:esbuild

Objective
Keep structured prompts working.
"@
            ExpectedTitle = "Lifeline smoke title"
            ExpectedVerify = @("pnpm ci:verify:esbuild")
            ExpectedBranchSlug = $null
        },
        @{
            Name = "heading only"
            FileName = "heading-only.md"
            Content = @"
# Lifeline heading fallback

Body text for the heading-only prompt.
"@
            ExpectedTitle = "Lifeline heading fallback"
            ExpectedVerify = @()
            ExpectedBranchSlug = $null
        },
        @{
            Name = "objective only"
            FileName = "objective-only.md"
            Content = @"
Objective:
Support Lifeline smoke prompts without a structured title.

Context:
- Shared runner prompt shape.
"@
            ExpectedTitle = "Support Lifeline smoke prompts without a structured title."
            ExpectedVerify = @()
            ExpectedBranchSlug = $null
        },
        @{
            Name = "metadata without title"
            FileName = "metadata-without-title.md"
            Content = @"
Verify: pnpm ci:verify:esbuild
Branch: lifeline-title-fallback

Objective:
Support Lifeline inbox prompts without a Title field.

Context:
- Keep metadata parsing intact while deriving a safe title fallback.
"@
            ExpectedTitle = "Support Lifeline inbox prompts without a Title field."
            ExpectedVerify = @("pnpm ci:verify:esbuild")
            ExpectedBranchSlug = "lifeline-title-fallback"
        },
        @{
            Name = "runtime policy metadata"
            FileName = "runtime-policy-metadata.md"
            Content = @"
Title: Stack runtime policy metadata
Runtime Model: gpt-5.4
Runtime Reasoning: high
Runtime Speed: fast
Runtime Permissions: full-access
Runtime Permission Profile: :danger-full-access
Runtime Approval: never
Runtime Web Search: disabled

Objective:
Keep runtime-policy metadata parsing aligned with the shared resolver.
"@
            ExpectedTitle = "Stack runtime policy metadata"
            ExpectedVerify = @()
            ExpectedBranchSlug = $null
            ExpectedRuntimeModel = "gpt-5.4"
            ExpectedRuntimeReasoning = "high"
            ExpectedRuntimeSpeed = "fast"
            ExpectedRuntimePermissions = "full-access"
            ExpectedRuntimePermissionProfile = ":danger-full-access"
            ExpectedRuntimeApproval = "never"
            ExpectedRuntimeWebSearch = "disabled"
        },
        @{
            Name = "filename fallback"
            FileName = "lifeline-smoke-filename-fallback.md"
            Content = @"
Plain markdown prompt body with no structured metadata.
"@
            ExpectedTitle = "lifeline-smoke-filename-fallback"
            ExpectedVerify = @()
            ExpectedBranchSlug = $null
        },
        @{
            Name = "acceptance criteria prompt"
            FileName = "acceptance-criteria-prompt.md"
            Content = @"
Title: Stack proof gate prompt

Objective:
Implement the bounded proof gate update.

Acceptance Criteria:
- Update the shared runner completion gate.
- Add criterion-level proof validation.

Expected Changed Paths:
- ops/codex/**
- docs/**

Expected Unchanged Paths:
- package.json

Blocked / Skipped Reporting Rules:
- Report blocked criteria explicitly.
"@
            ExpectedTitle = "Stack proof gate prompt"
            ExpectedVerify = @()
            ExpectedBranchSlug = $null
            ExpectedAcceptanceCriteria = @(
                @{ id = "ac-01"; text = "Update the shared runner completion gate." },
                @{ id = "ac-02"; text = "Add criterion-level proof validation." }
            )
            ExpectedChangedPaths = @("ops/codex/**", "docs/**")
            ExpectedUnchangedPaths = @("package.json")
            ExpectedBlockedSkippedRules = @("Report blocked criteria explicitly.")
        }
    )

    foreach ($promptCase in $promptCases) {
        $promptPath = Join-Path -Path $parserTestRoot -ChildPath $promptCase.FileName
        [System.IO.File]::WriteAllText($promptPath, ($promptCase.Content.TrimStart("`r", "`n")))

        $parsedPrompt = Parse-PromptFile -Path $promptPath

        if ([string]::IsNullOrWhiteSpace($parsedPrompt.Title)) {
            throw ("Parse-PromptFile returned an empty title for the {0} case." -f $promptCase.Name)
        }

        if ($parsedPrompt.Title -ne $promptCase.ExpectedTitle) {
            throw ("Parse-PromptFile resolved the wrong title for the {0} case. Expected '{1}', got '{2}'." -f $promptCase.Name, $promptCase.ExpectedTitle, $parsedPrompt.Title)
        }

        $expectedBranchSlug = $promptCase.ExpectedBranchSlug
        if ($parsedPrompt.BranchSlug -ne $expectedBranchSlug) {
            throw ("Parse-PromptFile resolved the wrong branch slug for the {0} case. Expected '{1}', got '{2}'." -f $promptCase.Name, $expectedBranchSlug, $parsedPrompt.BranchSlug)
        }

        $actualVerify = @($parsedPrompt.Verify)
        $expectedVerify = @($promptCase.ExpectedVerify)
        if ($actualVerify.Count -ne $expectedVerify.Count) {
            throw ("Parse-PromptFile resolved the wrong verify command count for the {0} case." -f $promptCase.Name)
        }

        for ($index = 0; $index -lt $expectedVerify.Count; $index++) {
            if ($actualVerify[$index] -ne $expectedVerify[$index]) {
                throw ("Parse-PromptFile resolved the wrong verify command for the {0} case at index {1}." -f $promptCase.Name, $index)
            }
        }

        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "RuntimeModel" -DefaultValue $null) -ne $(if ($promptCase.ContainsKey("ExpectedRuntimeModel")) { [string]$promptCase.ExpectedRuntimeModel } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong runtime model for the {0} case." -f $promptCase.Name)
        }
        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "RuntimeReasoning" -DefaultValue $null) -ne $(if ($promptCase.ContainsKey("ExpectedRuntimeReasoning")) { [string]$promptCase.ExpectedRuntimeReasoning } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong runtime reasoning for the {0} case." -f $promptCase.Name)
        }
        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "RuntimeSpeed" -DefaultValue $null) -ne $(if ($promptCase.ContainsKey("ExpectedRuntimeSpeed")) { [string]$promptCase.ExpectedRuntimeSpeed } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong runtime speed for the {0} case." -f $promptCase.Name)
        }
        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "RuntimePermissions" -DefaultValue $null) -ne $(if ($promptCase.ContainsKey("ExpectedRuntimePermissions")) { [string]$promptCase.ExpectedRuntimePermissions } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong runtime permissions for the {0} case." -f $promptCase.Name)
        }
        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "RuntimePermissionProfile" -DefaultValue $null) -ne $(if ($promptCase.ContainsKey("ExpectedRuntimePermissionProfile")) { [string]$promptCase.ExpectedRuntimePermissionProfile } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong runtime permission profile for the {0} case." -f $promptCase.Name)
        }
        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "RuntimeApproval" -DefaultValue $null) -ne $(if ($promptCase.ContainsKey("ExpectedRuntimeApproval")) { [string]$promptCase.ExpectedRuntimeApproval } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong runtime approval for the {0} case." -f $promptCase.Name)
        }
        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "RuntimeWebSearch" -DefaultValue $null) -ne $(if ($promptCase.ContainsKey("ExpectedRuntimeWebSearch")) { [string]$promptCase.ExpectedRuntimeWebSearch } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong runtime web-search mode for the {0} case." -f $promptCase.Name)
        }

        $expectedAcceptanceCriteria = if ($promptCase.ContainsKey("ExpectedAcceptanceCriteria")) {
            @($promptCase.ExpectedAcceptanceCriteria)
        }
        else {
            @()
        }
        [object[]]$actualAcceptanceCriteria = @($parsedPrompt.AcceptanceCriteria)
        if (@($actualAcceptanceCriteria).Length -ne @($expectedAcceptanceCriteria).Length) {
            throw ("Parse-PromptFile resolved the wrong acceptance-criteria count for the {0} case." -f $promptCase.Name)
        }
        for ($index = 0; $index -lt @($expectedAcceptanceCriteria).Length; $index++) {
            if ([string]$actualAcceptanceCriteria[$index].id -ne [string]$expectedAcceptanceCriteria[$index].id) {
                throw ("Parse-PromptFile resolved the wrong acceptance-criteria id for the {0} case at index {1}." -f $promptCase.Name, $index)
            }
            if ([string]$actualAcceptanceCriteria[$index].text -ne [string]$expectedAcceptanceCriteria[$index].text) {
                throw ("Parse-PromptFile resolved the wrong acceptance-criteria text for the {0} case at index {1}." -f $promptCase.Name, $index)
            }
        }

        $expectedChangedPaths = if ($promptCase.ContainsKey("ExpectedChangedPaths")) {
            @($promptCase.ExpectedChangedPaths)
        }
        else {
            @()
        }
        [object[]]$actualChangedPaths = @($parsedPrompt.ExpectedChangedPaths)
        if (@($actualChangedPaths).Length -ne @($expectedChangedPaths).Length) {
            throw ("Parse-PromptFile resolved the wrong expected-changed-path count for the {0} case." -f $promptCase.Name)
        }
        if ((@($actualChangedPaths) -join "|") -ne (@($expectedChangedPaths) -join "|")) {
            throw ("Parse-PromptFile resolved the wrong expected changed paths for the {0} case." -f $promptCase.Name)
        }

        $expectedUnchangedPaths = if ($promptCase.ContainsKey("ExpectedUnchangedPaths")) {
            @($promptCase.ExpectedUnchangedPaths)
        }
        else {
            @()
        }
        [object[]]$actualUnchangedPaths = @($parsedPrompt.ExpectedUnchangedPaths)
        if (@($actualUnchangedPaths).Length -ne @($expectedUnchangedPaths).Length) {
            throw ("Parse-PromptFile resolved the wrong expected-unchanged-path count for the {0} case." -f $promptCase.Name)
        }
        if ((@($actualUnchangedPaths) -join "|") -ne (@($expectedUnchangedPaths) -join "|")) {
            throw ("Parse-PromptFile resolved the wrong expected unchanged paths for the {0} case." -f $promptCase.Name)
        }

        $expectedBlockedSkippedRules = if ($promptCase.ContainsKey("ExpectedBlockedSkippedRules")) {
            @($promptCase.ExpectedBlockedSkippedRules)
        }
        else {
            @()
        }
        [object[]]$actualBlockedSkippedRules = @($parsedPrompt.BlockedSkippedRules)
        if (@($actualBlockedSkippedRules).Length -ne @($expectedBlockedSkippedRules).Length) {
            throw ("Parse-PromptFile resolved the wrong blocked/skipped-rule count for the {0} case." -f $promptCase.Name)
        }
        if ((@($actualBlockedSkippedRules) -join "|") -ne (@($expectedBlockedSkippedRules) -join "|")) {
            throw ("Parse-PromptFile resolved the wrong blocked/skipped rules for the {0} case." -f $promptCase.Name)
        }
    }

    $proofPromptPath = Join-Path -Path $parserTestRoot -ChildPath "proof-gate-prompt.md"
    $proofPromptContent = @"
Title: Proof gate prompt

Objective:
Implement the spec-to-diff gate.

Acceptance Criteria:
- Add spec-to-diff validation to the runner.
- Update the shared worker docs.

Expected Changed Paths:
- ops/codex/**
- docs/**

Expected Unchanged Paths:
- package.json

Blocked / Skipped Reporting Rules:
- Mark incomplete criteria as blocked, skipped, or failed.
"@
    [System.IO.File]::WriteAllText($proofPromptPath, ($proofPromptContent.TrimStart("`r", "`n")))
    $proofPrompt = Parse-PromptFile -Path $proofPromptPath

    $missingArtifactResult = Test-SpecToDiffCompletionProof `
        -PromptRecord $proofPrompt `
        -ArtifactRecord $null `
        -ChangedPaths @("ops/codex/Invoke-CodexRepoTask.ps1", "docs/codex-orchestration.md") `
        -PathEvidenceMap @{
            "ops/codex/Invoke-CodexRepoTask.ps1" = "+spec gate"
            "docs/codex-orchestration.md" = "+spec gate docs"
        }
    if ($missingArtifactResult.isValid) {
        throw "Spec-to-diff validation should fail when the completion artifact is missing."
    }
    if (($missingArtifactResult.blockingReasons -join "`n") -notmatch "artifact is required") {
        throw "Spec-to-diff validation did not report the missing artifact failure."
    }

    $unsupportedDiffResult = Test-SpecToDiffCompletionProof `
        -PromptRecord $proofPrompt `
        -ArtifactRecord ([pscustomobject]@{
            parseError = $null
            payload = [pscustomobject]@{
                contract_version = "atlas.stack.spec_to_diff.v1"
                criteria = @(
                    [pscustomobject]@{
                        criterion_id = "ac-01"
                        status = "satisfied"
                        changed_paths = @("ops/codex/Invoke-CodexRepoTask.ps1")
                        diff_evidence = @("missing literal snippet")
                        note = "proof provided"
                    },
                    [pscustomobject]@{
                        criterion_id = "ac-02"
                        status = "satisfied"
                        changed_paths = @("docs/codex-orchestration.md")
                        diff_evidence = @("Add worker docs")
                        note = ""
                    }
                )
                unchanged_path_justifications = @()
            }
        }) `
        -ChangedPaths @("ops/codex/Invoke-CodexRepoTask.ps1", "docs/codex-orchestration.md") `
        -PathEvidenceMap @{
            "ops/codex/Invoke-CodexRepoTask.ps1" = "+Add spec-to-diff validation to the runner."
            "docs/codex-orchestration.md" = "+Update the shared worker docs."
        }
    if ($unsupportedDiffResult.isValid) {
        throw "Spec-to-diff validation should fail when a satisfied criterion lacks supporting diff evidence."
    }
    if (($unsupportedDiffResult.blockingReasons -join "`n") -notmatch "was not found in the final diff") {
        throw "Spec-to-diff validation did not report the unsupported diff-evidence failure."
    }

    $blockedCriterionResult = Test-SpecToDiffCompletionProof `
        -PromptRecord $proofPrompt `
        -ArtifactRecord ([pscustomobject]@{
            parseError = $null
            payload = [pscustomobject]@{
                contract_version = "atlas.stack.spec_to_diff.v1"
                criteria = @(
                    [pscustomobject]@{
                        criterion_id = "ac-01"
                        status = "blocked"
                        changed_paths = @()
                        diff_evidence = @()
                        note = "Dependent repo change is not available."
                    },
                    [pscustomobject]@{
                        criterion_id = "ac-02"
                        status = "satisfied"
                        changed_paths = @("docs/codex-orchestration.md")
                        diff_evidence = @("Update the shared worker docs.")
                        note = ""
                    }
                )
                unchanged_path_justifications = @()
            }
        }) `
        -ChangedPaths @("docs/codex-orchestration.md") `
        -PathEvidenceMap @{
            "docs/codex-orchestration.md" = "+Update the shared worker docs."
        }
    if ($blockedCriterionResult.isValid) {
        throw "Spec-to-diff validation should fail when any criterion is blocked or skipped."
    }
    if (($blockedCriterionResult.blockingReasons -join "`n") -notmatch "is blocked") {
        throw "Spec-to-diff validation did not preserve blocked-criterion reporting."
    }

    $unchangedViolationResult = Test-SpecToDiffCompletionProof `
        -PromptRecord $proofPrompt `
        -ArtifactRecord ([pscustomobject]@{
            parseError = $null
            payload = [pscustomobject]@{
                contract_version = "atlas.stack.spec_to_diff.v1"
                criteria = @(
                    [pscustomobject]@{
                        criterion_id = "ac-01"
                        status = "satisfied"
                        changed_paths = @("ops/codex/Invoke-CodexRepoTask.ps1")
                        diff_evidence = @("Add spec-to-diff validation to the runner.")
                        note = ""
                    },
                    [pscustomobject]@{
                        criterion_id = "ac-02"
                        status = "satisfied"
                        changed_paths = @("docs/codex-orchestration.md")
                        diff_evidence = @("Update the shared worker docs.")
                        note = ""
                    }
                )
                unchanged_path_justifications = @()
            }
        }) `
        -ChangedPaths @("ops/codex/Invoke-CodexRepoTask.ps1", "docs/codex-orchestration.md", "package.json") `
        -PathEvidenceMap @{
            "ops/codex/Invoke-CodexRepoTask.ps1" = "+Add spec-to-diff validation to the runner."
            "docs/codex-orchestration.md" = "+Update the shared worker docs."
            "package.json" = "+unexpected change"
        }
    if ($unchangedViolationResult.isValid) {
        throw "Spec-to-diff validation should fail when an expected unchanged path changes without justification."
    }
    if (($unchangedViolationResult.blockingReasons -join "`n") -notmatch "Expected unchanged path 'package.json' changed without explicit justification") {
        throw "Spec-to-diff validation did not report the expected-unchanged-path violation."
    }

    $successfulProofResult = Test-SpecToDiffCompletionProof `
        -PromptRecord $proofPrompt `
        -ArtifactRecord ([pscustomobject]@{
            parseError = $null
            payload = [pscustomobject]@{
                contract_version = "atlas.stack.spec_to_diff.v1"
                criteria = @(
                    [pscustomobject]@{
                        criterion_id = "ac-01"
                        status = "satisfied"
                        changed_paths = @("ops/codex/Invoke-CodexRepoTask.ps1")
                        diff_evidence = @("Add spec-to-diff validation to the runner.")
                        note = ""
                    },
                    [pscustomobject]@{
                        criterion_id = "ac-02"
                        status = "satisfied"
                        changed_paths = @("docs/codex-orchestration.md")
                        diff_evidence = @("Update the shared worker docs.")
                        note = ""
                    }
                )
                unchanged_path_justifications = @()
            }
        }) `
        -ChangedPaths @("ops/codex/Invoke-CodexRepoTask.ps1", "docs/codex-orchestration.md") `
        -PathEvidenceMap @{
            "ops/codex/Invoke-CodexRepoTask.ps1" = "+Add spec-to-diff validation to the runner."
            "docs/codex-orchestration.md" = "+Update the shared worker docs."
        }
    if (-not $successfulProofResult.isValid) {
        throw ("Spec-to-diff validation should pass when every criterion is satisfied and provable. Reasons: {0}" -f ($successfulProofResult.blockingReasons -join "; "))
    }

    $defaultsConfig = ConvertFrom-SimpleToml -Path "ops/codex/config.defaults.toml"
    $stackRepoConfig = ConvertFrom-SimpleToml -Path "ops/codex/repos/stack/config.toml"
    $mergedStackConfig = Merge-Hashtable -Base $defaultsConfig -Overlay $stackRepoConfig

    $resolutionFixtureRoot = Join-Path -Path $parserTestRoot -ChildPath "native-resolution"
    $fixtureAppData = Join-Path -Path $resolutionFixtureRoot -ChildPath "appdata"
    $configuredNativePath = Join-Path -Path $fixtureAppData -ChildPath "npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe"
    $explicitNativePath = Join-Path -Path $resolutionFixtureRoot -ChildPath "explicit-codex.exe"
    New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($configuredNativePath)) -Force | Out-Null
    [System.IO.File]::WriteAllText($configuredNativePath, "configured native fixture")
    [System.IO.File]::WriteAllText($explicitNativePath, "explicit native fixture")
    $configuredCommand = "%APPDATA%/npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe"
    $originalAppData = $env:APPDATA
    try {
        $env:APPDATA = $fixtureAppData
        $configuredResolution = Resolve-CodexCommand -ExplicitCodexCommand "" -Config @{ windows = @{ codex_command = $configuredCommand } } -BasePath $resolutionFixtureRoot
        if ([string]$configuredResolution.requestedPath -ne $configuredCommand -or [string]$configuredResolution.expandedPath -ne $configuredNativePath -or [string]$configuredResolution.resolvedNativePath -ne $configuredNativePath) {
            throw "Configured %APPDATA% native executable fixture did not preserve requestedPath, expandedPath, and resolvedNativePath."
        }

        $explicitResolution = Resolve-CodexCommand -ExplicitCodexCommand $explicitNativePath -Config @{ windows = @{ codex_command = $configuredCommand } } -BasePath $resolutionFixtureRoot
        if ([string]$explicitResolution.source -ne "explicit-arg" -or [string]$explicitResolution.resolvedNativePath -ne $explicitNativePath) {
            throw "Explicit -CodexCommand fixture did not take precedence over merged windows.codex_command."
        }

        $missingConfiguredPath = Join-Path -Path $resolutionFixtureRoot -ChildPath "missing-configured-codex.exe"
        $missingConfiguredResolution = Resolve-CodexCommand -ExplicitCodexCommand "" -Config @{ windows = @{ codex_command = $missingConfiguredPath } } -BasePath $resolutionFixtureRoot
        if ([string]$missingConfiguredResolution.source -ne "runtime-config/windows.codex_command" -or [string]$missingConfiguredResolution.reasonCode -ne "codex_native_executable_not_found") {
            throw "Configured missing native executable fixture did not fail closed before probing."
        }
    }
    finally {
        $env:APPDATA = $originalAppData
    }

    function Invoke-CodexModelCapabilityProbe {
        param([string]$CodexCommand, [string]$ProbeTargetPath, [string]$Model)
        return [pscustomobject]@{
            requested_model = $Model
            effective_model = $Model
            status = "accepted"
            note = $null
            exit_code = 0
        }
    }

    $fakeCliContext = [pscustomobject]@{
        codexVersion = "codex-cli 0.144.1"
    }

    $stackDefaultRuntimePolicy = Resolve-StackRuntimePolicy `
        -Config $mergedStackConfig `
        -RepoConfig $stackRepoConfig `
        -DefaultsConfig $defaultsConfig `
        -PromptRecord ([pscustomobject]@{}) `
        -ExplicitPolicy ([pscustomobject]@{}) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    if ([string]$stackDefaultRuntimePolicy.resolved.permissions.permission_profile -ne ":danger-full-access") {
        throw "_stack default runtime policy must resolve the modern :danger-full-access permission profile."
    }
    if ($null -ne $stackDefaultRuntimePolicy.resolved.permissions.sandbox_mode) {
        throw "_stack default runtime policy must not keep a legacy sandbox mode active when the modern permission profile is selected."
    }
    if ([string]$stackDefaultRuntimePolicy.sources.permissions.mode -ne "repo-config") {
        throw "_stack default runtime policy must report repo-config as the source for its default full-access posture."
    }
    if ([string]$stackDefaultRuntimePolicy.codex_version -ne "codex-cli 0.144.1") {
        throw "Runtime policy receipts must expose the installed Codex version at the envelope level."
    }
    if ($null -eq $stackDefaultRuntimePolicy.warnings -or $null -eq $stackDefaultRuntimePolicy.blockers) {
        throw "Runtime policy receipts must include warnings and blockers collections."
    }

    $precedencePolicy = Resolve-StackRuntimePolicy `
        -Config $mergedStackConfig `
        -RepoConfig $stackRepoConfig `
        -DefaultsConfig $defaultsConfig `
        -PromptRecord ([pscustomobject]@{
            RuntimeReasoning = "medium"
            RuntimeSpeed = "fast"
        }) `
        -ExplicitPolicy ([pscustomobject]@{
            model = "gpt-5.5"
        }) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    if ([string]$precedencePolicy.requested_model -ne "gpt-5.5" -or [string]$precedencePolicy.sources.model -ne "explicit-arg") {
        throw "Runtime policy precedence must prefer explicit model arguments."
    }
    if ([string]$precedencePolicy.resolved.reasoning -ne "medium" -or [string]$precedencePolicy.sources.reasoning -ne "prompt-metadata") {
        throw "Runtime policy precedence must prefer prompt metadata over repo config for reasoning."
    }
    if ([string]$precedencePolicy.resolved.speed -ne "fast" -or [string]$precedencePolicy.sources.speed -notmatch "^prompt-metadata") {
        throw "Runtime policy precedence must prefer prompt metadata over repo config for speed when Fast is supported."
    }

    $fastFallbackPolicy = Resolve-StackRuntimePolicy `
        -Config $mergedStackConfig `
        -RepoConfig $stackRepoConfig `
        -DefaultsConfig $defaultsConfig `
        -PromptRecord ([pscustomobject]@{}) `
        -ExplicitPolicy ([pscustomobject]@{
            model = "gpt-5.4-mini"
            speed = "fast"
            permissions = "full-access"
            permission_profile = ":danger-full-access"
        }) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    if ([string]$fastFallbackPolicy.resolved.speed -ne "fast" -or [string]$fastFallbackPolicy.sources.speed -ne "explicit-arg") {
        throw "Runtime policy must retain the requested speed without a static model catalog."
    }

    $modernInvocation = New-CodexInvocationPlan `
        -RuntimePolicy $stackDefaultRuntimePolicy `
        -SummaryPath "C:\temp\summary.md" `
        -WorktreePath "C:\temp\worktree" `
        -Personality "pragmatic"
    if (($modernInvocation.arguments -join " ") -notmatch 'default_permissions=":danger-full-access"') {
        throw "Modern runtime policy invocation must pass the resolved permission profile through Codex config."
    }
    if ($modernInvocation.arguments -contains "-s") {
        throw "Modern runtime policy invocation must not also activate a legacy sandbox mode."
    }

    $legacyRuntimePolicy = Resolve-StackRuntimePolicy `
        -Config $mergedStackConfig `
        -RepoConfig $stackRepoConfig `
        -DefaultsConfig $defaultsConfig `
        -PromptRecord ([pscustomobject]@{}) `
        -ExplicitPolicy ([pscustomobject]@{
            sandbox_mode = "danger-full-access"
        }) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    $legacyInvocation = New-CodexInvocationPlan `
        -RuntimePolicy $legacyRuntimePolicy `
        -SummaryPath "C:\temp\summary.md" `
        -WorktreePath "C:\temp\worktree" `
        -Personality "pragmatic"
    if ($legacyInvocation.arguments -notcontains "-s" -or $legacyInvocation.arguments -notcontains "danger-full-access") {
        throw "Legacy runtime policy invocation must preserve explicit sandbox-mode compatibility."
    }
    if (($legacyInvocation.arguments -join " ") -match 'default_permissions=') {
        throw "Legacy runtime policy invocation must not activate a modern permission profile."
    }

    $conflictRaised = $false
    try {
        [void](Resolve-StackRuntimePolicy `
            -Config $mergedStackConfig `
            -RepoConfig $stackRepoConfig `
            -DefaultsConfig $defaultsConfig `
            -PromptRecord ([pscustomobject]@{}) `
            -ExplicitPolicy ([pscustomobject]@{
                permission_profile = ":danger-full-access"
                sandbox_mode = "danger-full-access"
            }) `
            -CodexCommand "codex.exe" `
            -CliContext $fakeCliContext)
    }
    catch {
        if ($_.Exception.Message -match "cannot be active together") {
            $conflictRaised = $true
        }
        else {
            throw
        }
    }
    if (-not $conflictRaised) {
        throw "Runtime policy resolution must fail when both a modern permission profile and a legacy sandbox mode are requested."
    }

    if ($null -eq $stackDefaultRuntimePolicy.requested -or $null -eq $stackDefaultRuntimePolicy.resolved -or $null -eq $stackDefaultRuntimePolicy.sources) {
        throw "Runtime policy receipts must include requested, resolved, and sources sections."
    }
    if ([string]$stackDefaultRuntimePolicy.resolved.codex_version -ne "codex-cli 0.144.1") {
        throw "Runtime policy receipts must capture the installed Codex version when it is available."
    }
}
finally {
    if (Test-Path -LiteralPath $parserTestRoot) {
        Remove-Item -LiteralPath $parserTestRoot -Recurse -Force
    }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..\..")).Path
$logicalStackRoot = [System.IO.Path]::GetFullPath($repoRoot)
$worktreesRoot = [System.IO.Path]::GetDirectoryName($logicalStackRoot)
if (-not [string]::IsNullOrWhiteSpace($worktreesRoot) -and ([System.IO.Path]::GetFileName($worktreesRoot) -ieq "worktrees")) {
    $codexRoot = [System.IO.Path]::GetDirectoryName($worktreesRoot)
    if (-not [string]::IsNullOrWhiteSpace($codexRoot) -and ([System.IO.Path]::GetFileName($codexRoot) -ieq ".codex")) {
        $logicalStackRoot = [System.IO.Path]::GetDirectoryName($codexRoot)
    }
}
$workspaceRoot = (Resolve-Path -LiteralPath (Join-Path -Path $logicalStackRoot -ChildPath "..\..")).Path
$integrationRepoRoot = Join-Path -Path $workspaceRoot -ChildPath ("repos\stack-runtime-policy-fixture-{0}" -f ([guid]::NewGuid().ToString("N")))
$integrationPromptPath = $null
$integrationManifestPath = $null
$integrationContextPath = $null

try {
    New-Item -ItemType Directory -Path $integrationRepoRoot -Force | Out-Null
    foreach ($relativePath in @(
        ".codex\archive",
        ".codex\exports",
        ".codex\inbox",
        ".codex\logs",
        ".codex\worktrees",
        "docs"
    )) {
        New-Item -ItemType Directory -Path (Join-Path -Path $integrationRepoRoot -ChildPath $relativePath) -Force | Out-Null
    }

    [System.IO.File]::WriteAllText((Join-Path -Path $integrationRepoRoot -ChildPath "docs\fixture.md"), "Fixture baseline.`r`n")
    [System.IO.File]::WriteAllText((Join-Path -Path $integrationRepoRoot -ChildPath ".codex\config.toml"), "approval = `"on-failure`"`r`n")

    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("init", "--quiet")
    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("config", "user.name", "Stack Runtime Policy Fixture")
    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("config", "user.email", "stack-runtime-policy-fixture@local")
    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("add", ".")
    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("commit", "--quiet", "-m", "fixture baseline")
    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("branch", "-M", "main")

    $fixtureAdapterPath = Join-Path -Path $integrationRepoRoot -ChildPath "adapter.json"
    $fixtureAdapter = [ordered]@{
        kind = "stack.codex.repo-adapter"
        schemaVersion = 1
        repoId = "stack-runtime-fixture"
        description = "_stack runtime-policy integration fixture"
        allowedMutationSurfaces = @(
            ".codex/**",
            "docs/**"
        )
        docsUpdateRules = @(
            "Keep fixture edits limited to docs/ and temporary .codex artifacts."
        )
        verify = [ordered]@{
            bootstrapCommands = @()
            defaultCommands = @("git diff --check")
        }
        artifacts = [ordered]@{
            inboxDir = ".codex/inbox"
            archiveDir = ".codex/archive"
            logsDir = ".codex/logs"
            worktreeRoot = ".codex/worktrees"
            exportsDir = ".codex/exports"
        }
        pushPolicy = [ordered]@{
            mode = "manual-only"
            skipPush = $true
            allowAutoPush = $false
        }
        autoCommitPolicy = [ordered]@{
            enabled = $true
            commitMetadata = [ordered]@{
                artifactPath = ".codex/commit-meta.json"
                allowedTypes = @("feat", "fix", "docs", "refactor", "test", "chore")
            }
        }
        localLandingPolicy = [ordered]@{
            mode = "disabled"
            targetBranch = "main"
        }
        exports = [ordered]@{
            patch = $false
            bundle = $false
            formatPatchBaseRef = "origin/main"
        }
        execution = [ordered]@{
            baseRef = "origin/main"
            branchPrefix = "codex/"
            cleanupWorktreeOnSuccess = $false
            fetchOrigin = $false
        }
    }
    [System.IO.File]::WriteAllText($fixtureAdapterPath, (($fixtureAdapter | ConvertTo-Json -Depth 10) + "`r`n"))

    $fixtureConfigPath = Join-Path -Path $integrationRepoRoot -ChildPath "config.toml"
    $fixtureConfig = @"
repo_root = "."
adapter_path = "./adapter.json"

[runtime_policy]
model = "gpt-5.4"
reasoning = "high"
speed = "standard"
permissions = "full-access"
permission_profile = ":danger-full-access"
approval = "never"
web_search = "disabled"
"@
    [System.IO.File]::WriteAllText($fixtureConfigPath, $fixtureConfig.TrimStart("`r", "`n") + "`r`n")

    $fakeCodexJsPath = Join-Path -Path $integrationRepoRoot -ChildPath "fake-codex.mjs"
    $fakeCodexJs = @'
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);

if (args[0] === "--version") {
  process.stdout.write("codex-cli 0.144.1-fixture\n");
  process.exit(0);
}

let summaryPath = null;
let worktreePath = null;
let requestedModel = null;
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "-m") { requestedModel = args[index + 1] ?? null; index += 1; continue; }
  if (args[index] === "-o") {
    summaryPath = args[index + 1] ?? null;
    index += 1;
    continue;
  }

  if (args[index] === "-C") {
    worktreePath = args[index + 1] ?? null;
    index += 1;
  }
}

const prompt = fs.readFileSync(0, "utf8");
if (prompt.includes("ATLAS_MODEL_CAPABILITY_ACCEPTED")) {
  if (String(requestedModel ?? "").includes("unsupported")) { process.stderr.write("The model is not supported when using Codex.\n"); process.exit(1); }
  fs.writeFileSync(summaryPath, "accepted\n", "utf8"); process.exit(0);
}
if (!summaryPath || !worktreePath) {
  process.stderr.write("Fake Codex did not receive both -o and -C.\n");
  process.exit(1);
}

const codexArtifactDirectory = path.join(worktreePath, ".codex");
fs.mkdirSync(codexArtifactDirectory, { recursive: true });

const executionRecord = {
  cwd: process.cwd(),
  worktreePath,
  summaryPath,
  arguments: args
};
fs.writeFileSync(
  path.join(codexArtifactDirectory, "fake-codex.execution.json"),
  `${JSON.stringify(executionRecord, null, 2)}\n`,
  "utf8"
);

fs.appendFileSync(path.join(worktreePath, "docs", "fixture.md"), "runtime policy integration proof\n", "utf8");
fs.writeFileSync(
  path.join(codexArtifactDirectory, "commit-meta.json"),
  '{"type":"test","scope":"runtime-fixture","summary":"record runtime policy proof"}\n',
  "utf8"
);
fs.writeFileSync(
  path.join(codexArtifactDirectory, "spec-to-diff-proof.json"),
  `${JSON.stringify({
    contract_version: "atlas.stack.spec_to_diff.v1",
    criteria: [
      {
        criterion_id: "ac-01",
        status: "satisfied",
        changed_paths: ["docs/fixture.md"],
        diff_evidence: ["runtime policy integration proof"],
        note: "Fake Codex completed the fixture mutation."
      }
    ],
    unchanged_path_justifications: []
  }, null, 2)}\n`,
  "utf8"
);
fs.writeFileSync(summaryPath, "Fake Codex completed the runtime-policy fixture.\n", "utf8");

process.stdout.write('{"status":"ok"}\n');
'@
    [System.IO.File]::WriteAllText($fakeCodexJsPath, $fakeCodexJs.TrimStart("`r", "`n") + "`r`n")

    $fakeCodexCmdPath = Join-Path -Path $integrationRepoRoot -ChildPath "fake-codex.exe"
    $launcherSource = @'
using System; using System.Diagnostics; public static class FixtureLauncher { public static int Main(string[] a) { var s=new ProcessStartInfo(); s.FileName=Environment.GetEnvironmentVariable("FAKE_CODEX_NODE_PATH"); s.Arguments="\""+Environment.GetEnvironmentVariable("FAKE_CODEX_SCRIPT_PATH")+"\" "+String.Join(" ",a); s.UseShellExecute=false; s.RedirectStandardInput=true; s.RedirectStandardOutput=true; s.RedirectStandardError=true; using(var p=Process.Start(s)){p.StandardInput.Write(Console.In.ReadToEnd());p.StandardInput.Close();Console.Out.Write(p.StandardOutput.ReadToEnd());Console.Error.Write(p.StandardError.ReadToEnd());p.WaitForExit();return p.ExitCode;}}}
'@
    $env:FAKE_CODEX_NODE_PATH = (Get-Command node -ErrorAction Stop).Source
    $env:FAKE_CODEX_SCRIPT_PATH = $fakeCodexJsPath
    Add-Type -TypeDefinition $launcherSource -Language CSharp -OutputAssembly $fakeCodexCmdPath -OutputType ConsoleApplication | Out-Null

    $integrationPromptPath = Join-Path -Path $integrationRepoRoot -ChildPath ".codex\inbox\runtime-policy-fixture.md"
    $integrationPrompt = @"
Title: Runtime policy fixture
Runtime Model: gpt-5.4-mini
Runtime Speed: fast

Objective:
Prove the completed run.json runtime-policy envelope through the shared runner.

Acceptance Criteria:
- Update docs/fixture.md with runtime policy integration proof text.

Expected Changed Paths:
- docs/**

Blocked / Skipped Reporting Rules:
- Report any unproven criterion as blocked, skipped, or failed.
"@
    [System.IO.File]::WriteAllText($integrationPromptPath, $integrationPrompt.TrimStart("`r", "`n") + "`r`n")

    $powershellExe = Join-Path -Path $PSHOME -ChildPath "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        $powershellExe = "powershell.exe"
    }

    & $powershellExe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexRepoTask.ps1") `
        -PromptPath $integrationPromptPath `
        -ConfigPath $fixtureConfigPath `
        -CodexCommand $fakeCodexCmdPath

    if ($LASTEXITCODE -ne 0) {
        throw ("Invoke-CodexRepoTask integration fixture failed with exit code {0}." -f $LASTEXITCODE)
    }

    $integrationLogDirectory = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $integrationRepoRoot -ChildPath ".codex\logs") -Directory |
        Sort-Object Name |
        Select-Object -Last 1
    )[0]
    if ($null -eq $integrationLogDirectory) {
        throw "Integration fixture did not create a run log directory."
    }

    $integrationManifestPath = Join-Path -Path $integrationLogDirectory.FullName -ChildPath "run.json"
    $integrationManifest = Get-Content -LiteralPath $integrationManifestPath -Raw | ConvertFrom-Json
    if ([string]$integrationManifest.status -ne "success") {
        throw ("Integration fixture expected a successful run.json but found status '{0}'." -f [string]$integrationManifest.status)
    }

    $runtimePolicyRecord = $integrationManifest.runtimePolicy
    if ($null -eq $runtimePolicyRecord) {
        throw "Integration fixture run.json did not record runtimePolicy."
    }
    foreach ($requiredProperty in @("requested", "resolved", "sources", "codex_version", "warnings", "blockers")) {
        if ($runtimePolicyRecord.PSObject.Properties.Name -notcontains $requiredProperty) {
            throw ("Integration fixture runtimePolicy is missing required field '{0}'." -f $requiredProperty)
        }
    }

    if ([string]$runtimePolicyRecord.requested.model -ne "gpt-5.4-mini") {
        throw "Integration fixture did not receipt the prompt-requested model."
    }
    if ([string]$runtimePolicyRecord.requested.speed -ne "fast") {
        throw "Integration fixture did not receipt the prompt-requested speed."
    }
    if ([string]$runtimePolicyRecord.resolved.speed -ne "fast" -or [string]$runtimePolicyRecord.sources.speed -ne "prompt-metadata") {
        throw "Integration fixture did not preserve requested speed without a static model catalog."
    }
    if ([string]$runtimePolicyRecord.codex_version -ne "codex-cli 0.144.1-fixture") {
        throw "Integration fixture did not receipt the fake Codex version at the runtime-policy envelope level."
    }
    if ([string]$runtimePolicyRecord.model_capability.status -ne "accepted" -or [string]$runtimePolicyRecord.effective_model -ne "gpt-5.4-mini") {
        throw "Integration fixture did not receipt accepted requested-versus-effective model capability truth."
    }
    if ([string]$runtimePolicyRecord.resolved.permissions.permission_profile -ne ":danger-full-access") {
        throw "Integration fixture did not keep the repo-config full-access permission profile."
    }
    if ($null -ne $runtimePolicyRecord.resolved.permissions.sandbox_mode) {
        throw "Integration fixture must not activate a legacy sandbox mode when the repo config selects the modern permission profile."
    }

    $unsupportedPromptPath = Join-Path -Path $integrationRepoRoot -ChildPath ".codex\inbox\unsupported-model-fixture.md"
    [System.IO.File]::WriteAllText($unsupportedPromptPath, "Title: Unsupported model fixture`r`n`r`nObjective:`r`nProve unsupported_model classification.`r`n")
    & $powershellExe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexRepoTask.ps1") `
        -PromptPath $unsupportedPromptPath `
        -ConfigPath $fixtureConfigPath `
        -CodexCommand $fakeCodexCmdPath `
        -Model "unsupported-fixture"
    if ($LASTEXITCODE -eq 0) {
        throw "Repo runner unsupported_model fixture unexpectedly succeeded."
    }
    $unsupportedLogDirectory = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $integrationRepoRoot -ChildPath ".codex\logs") -Directory |
        Sort-Object Name |
        Select-Object -Last 1
    )[0]
    $unsupportedManifest = Get-Content -LiteralPath (Join-Path -Path $unsupportedLogDirectory.FullName -ChildPath "run.json") -Raw | ConvertFrom-Json
    if ([string]$unsupportedManifest.status -ne "runtime_policy_blocked" -or [string]$unsupportedManifest.runtimePolicy.model_capability.status -ne "unsupported_model") {
        throw "Repo runner fixture did not distinguish unsupported_model from probe_failed."
    }

    if ([string]$integrationManifest.specToDiff.validationPassed -ne "True") {
        throw "Integration fixture expected spec-to-diff validation to pass."
    }
    if ([string]$integrationManifest.commit.enabled -ne "True" -or [string]::IsNullOrWhiteSpace([string]$integrationManifest.commitSha)) {
        throw "Integration fixture expected a committed successful run."
    }
    if (@($integrationManifest.verification).Count -eq 0 -or [int]$integrationManifest.verification[0].exitCode -ne 0) {
        throw "Integration fixture expected verification to pass."
    }
    if ("docs/fixture.md" -notin @($integrationManifest.changedPaths)) {
        throw "Integration fixture did not record the expected changed path."
    }

    $fakeExecutionRecordPath = Join-Path -Path ([string]$integrationManifest.worktreePath) -ChildPath ".codex\fake-codex.execution.json"
    $fakeExecutionRecord = Get-Content -LiteralPath $fakeExecutionRecordPath -Raw | ConvertFrom-Json
    $neutralHostDirectory = Get-CodexRuntimeHostDirectory
    if ([string]$fakeExecutionRecord.cwd -eq [string]$fakeExecutionRecord.worktreePath) {
        throw "Integration fixture must launch Codex from a neutral host directory instead of the repo-local worktree."
    }
    if ([string]$fakeExecutionRecord.cwd -ne $neutralHostDirectory) {
        throw "Integration fixture expected Codex to launch from the shared neutral host directory."
    }

    $integrationContextRef = [string]$integrationManifest.workerArtifacts.context
    if (-not [string]::IsNullOrWhiteSpace($integrationContextRef)) {
        $integrationContextPath = Join-Path -Path $workspaceRoot -ChildPath $integrationContextRef
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($integrationContextPath) -and (Test-Path -LiteralPath $integrationContextPath)) {
        Remove-Item -LiteralPath $integrationContextPath -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($integrationRepoRoot) -and (Test-Path -LiteralPath $integrationRepoRoot)) {
        Remove-Item -LiteralPath $integrationRepoRoot -Recurse -Force
    }
}
}
finally {
    if ($null -ne $topologyManifestBridge -and [bool]$topologyManifestBridge.created -and (Test-Path -LiteralPath $topologyManifestBridge.path)) {
        Remove-Item -LiteralPath $topologyManifestBridge.path -Force
    }
}

Write-Host "Validated _stack operator surface and Codex entrypoints."
