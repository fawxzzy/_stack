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

function Get-SpecToDiffInstructionBlockText {
    param([string]$PromptText)

    if ([string]::IsNullOrWhiteSpace($PromptText)) {
        return $null
    }

    $normalized = $PromptText -replace "`r`n", "`n"
    $start = $normalized.IndexOf("Spec-to-diff completion contract:")
    if ($start -lt 0) {
        return $null
    }

    $tail = $normalized.Substring($start)
    $end = $tail.Length
    foreach ($terminator in @("`n`nVerified no-change contract:", "`n`nAtlas Contracts v2 preflight contract:")) {
        $index = $tail.IndexOf($terminator)
        if ($index -ge 0 -and $index -lt $end) {
            $end = $index
        }
    }

    return $tail.Substring(0, $end).Trim()
}

function Assert-CleanSpecToDiffInstructionBlock {
    param(
        [string]$Block,
        [string]$Context,
        [string[]]$ExpectedCriterionIds,
        [int]$ExpectedNoneDeclaredCount = 0
    )

    Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($Block)) -Message ("{0} did not include a spec-to-diff instruction block." -f $Context)
    Assert-Condition -Condition (-not $Block.Contains("System.Object[]")) -Message ("{0} rendered System.Object[] in the spec-to-diff instruction block." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("Expected changed paths:"))).Count -eq 1) -Message ("{0} repeated the Expected changed paths heading." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("Expected unchanged paths:"))).Count -eq 1) -Message ("{0} repeated the Expected unchanged paths heading." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("Blocked / skipped reporting rules:"))).Count -eq 1) -Message ("{0} repeated the blocked/skipped heading." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("- none declared"))).Count -eq $ExpectedNoneDeclaredCount) -Message ("{0} rendered the wrong count of '- none declared' lines." -f $Context)
    foreach ($criterionId in @($ExpectedCriterionIds)) {
        Assert-Condition -Condition ($Block.Contains("- {0}:" -f $criterionId)) -Message ("{0} did not include criterion id {1}." -f $Context, $criterionId)
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

$inheritedHandleScript = @'
const { spawn } = require("child_process");
const child = spawn(process.execPath, ["-e", "setTimeout(() => process.exit(0), 1500)"], {
  detached: true,
  stdio: ["ignore", "inherit", "inherit"],
  windowsHide: true
});
child.unref();
console.log("parent-complete");
'@
$captureStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$inheritedHandleCapture = Invoke-ProcessCapture `
    -FilePath "node" `
    -ArgumentList @("-e", $inheritedHandleScript) `
    -WorkingDirectory (Get-Location).Path `
    -OutputDrainTimeoutMilliseconds 100
$captureStopwatch.Stop()
Assert-Condition -Condition ($inheritedHandleCapture.ExitCode -eq 0) -Message "Inherited-handle capture fixture parent must exit successfully."
Assert-Condition -Condition ([bool]$inheritedHandleCapture.OutputDrainTimedOut) -Message "Inherited-handle capture fixture must receipt a bounded output-drain timeout."
Assert-Condition -Condition ($captureStopwatch.ElapsedMilliseconds -lt 1200) -Message "Process capture must not wait for an inherited output handle to close."
Assert-Condition -Condition ($inheritedHandleCapture.StdErr.Contains("process_capture_output_drain_timeout")) -Message "Process capture must preserve the stable output-drain timeout reason."

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
    "ops/codex/StackInboxSweep.ps1",
    "ops/codex/Invoke-StackInboxSweepLauncher.ps1",
    "ops/codex/Install-StackInboxSweepTask.ps1",
    "ops/codex/Test-StackInboxSweep.ps1",
    "ops/codex/Invoke-CodexRepoTask.ps1",
    "ops/codex/Invoke-CodexCanonicalWorkspaceTask.ps1",
    "ops/codex/AtlasContractsV2Producer.ps1",
    "ops/codex/Test-AtlasContractsV2Producer.ps1",
    "ops/codex/CodexRunner.Common.ps1",
    "ops/codex/Test-AtlasWorkspaceWriter.ps1",
    "ops/codex/Test-StackOperatorSurface.ps1",
    "ops/codex/adapter.schema.json",
    "ops/codex/execution-classes/atlas-workspace.writer.json",
    "ops/codex/repos/stack/adapter.json",
    "ops/codex/repos/stack/config.toml",
    "ops/codex/repos/discordos/adapter.json",
    "ops/codex/repos/discordos/config.toml",
    "ops/stack/StackWorkerArtifacts.ps1",
    "ops/stack/Test-StackWorkerArtifacts.ps1",
    "ops/branding/Invoke-AtlasBrand.mjs",
    "ops/branding/Invoke-AtlasBrand.test.mjs",
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
    "codex:discordos:inbox",
    "codex:discordos:inbox:once",
    "codex:discordos:task",
    "codex:playbook-doctrine:task",
    "codex:stack:inbox",
    "codex:stack:inbox:once",
    "codex:stack:inbox:test",
    "codex:stack:inbox:task:install",
    "codex:stack:inbox:task:enable",
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

$requiredDiscordOsScripts = @{
    "codex:discordos:inbox" = "powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\discordos\config.toml"
    "codex:discordos:inbox:once" = "powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Start-CodexInboxRunner.ps1 -ConfigPath .\ops\codex\repos\discordos\config.toml -RunOnce"
    "codex:discordos:task" = "powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\discordos\config.toml"
}
foreach ($scriptName in $requiredDiscordOsScripts.Keys) {
    $actualScript = [string]$package.scripts.PSObject.Properties[$scriptName].Value
    Assert-Condition -Condition ($actualScript -eq $requiredDiscordOsScripts[$scriptName]) -Message ("DiscordOS package script '{0}' must use its shared-runner config." -f $scriptName)
}

$brandScripts = @{
    "atlas:brand:build" = "node ops\branding\Invoke-AtlasBrand.mjs build"
    "atlas:brand:sync" = "node ops\branding\Invoke-AtlasBrand.mjs sync --consumer-id stack-launcher-icon"
    "atlas:brand:verify" = "node ops\branding\Invoke-AtlasBrand.mjs verify --consumer-id stack-launcher-icon"
    "atlas:brand:sync:all" = "node ops\branding\Invoke-AtlasBrand.mjs sync"
    "atlas:brand:verify:all" = "node ops\branding\Invoke-AtlasBrand.mjs verify"
}
foreach ($brandScriptName in $brandScripts.Keys) {
    $actualBrandScript = [string]$package.scripts.PSObject.Properties[$brandScriptName].Value
    if ($actualBrandScript -ne $brandScripts[$brandScriptName]) {
        throw ("Package script '{0}' must use the Atlas brand wrapper contract." -f $brandScriptName)
    }
}

$atlasBrandWrapperText = Get-Content -LiteralPath "ops/branding/Invoke-AtlasBrand.mjs" -Raw
foreach ($requiredSnippet in @(
    "--git-common-dir",
    "logicalStackRoot",
    "atlas_brand_canonical_script_not_found",
    "--consumer-id",
    "atlas_brand_consumer_not_found",
    "atlas_brand_consumer_duplicate",
    "temporaryManifestPath",
    "build-brand-assets.mjs",
    "sync-brand-assets.mjs"
)) {
    if (-not $atlasBrandWrapperText.Contains($requiredSnippet)) {
        throw ("Invoke-AtlasBrand.mjs is missing required worktree-safe scope snippet: {0}" -f $requiredSnippet)
    }
}

& node --test ".\ops\branding\Invoke-AtlasBrand.test.mjs"
if ($LASTEXITCODE -ne 0) {
    throw ("Atlas brand wrapper Node tests failed with exit code {0}." -f $LASTEXITCODE)
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

& powershell -NoProfile -ExecutionPolicy Bypass -File ".\ops\codex\Test-AtlasContractsV2Producer.ps1"
if ($LASTEXITCODE -ne 0) {
    throw ("Atlas Contracts v2 producer tests failed with exit code {0}." -f $LASTEXITCODE)
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
$requiredStackEvidenceMutationSurfaces = @(
    "exports/**",
    "tests/**"
)
$actualStackEvidenceMutationSurfaces = @(
    $stackAdapter.allowedMutationSurfaces |
        Where-Object { $_ -match '^(exports|tests)/\*\*$' } |
        Sort-Object -Unique
)
if ($null -ne (Compare-Object -ReferenceObject $requiredStackEvidenceMutationSurfaces -DifferenceObject $actualStackEvidenceMutationSurfaces)) {
    throw "_stack adapter evidence admission must contain exactly exports/** and tests/**."
}
$stackOperatorEvidenceDocumentation = Get-Content -LiteralPath "docs/codex-orchestration.md" -Raw
$requiredStackEvidenceContractPhrases = @(
    '`_stack` admits `exports/**` and `tests/**` only for `_stack`-owned contract evidence, repo-owned adoption exports, verification reports, schemas, and deterministic owner tests.',
    "This does not authorize product or application implementation, or cross-repo writes."
)
foreach ($requiredPhrase in $requiredStackEvidenceContractPhrases) {
    if (-not $stackOperatorEvidenceDocumentation.Contains($requiredPhrase)) {
        throw ("_stack operator evidence boundary documentation is missing: {0}" -f $requiredPhrase)
    }
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
if ([string]$stackConfig.runtime_policy.model -ne "gpt-5.6-sol" -or [string]$stackConfig.runtime_policy.reasoning -ne "xhigh" -or [string]$stackConfig.runtime_policy.approval -ne "never" -or [string]$stackConfig.runtime_policy.web_search -ne "live") {
    throw "_stack scheduled inbox runtime policy must default to Sol/xhigh/live/no-approvals."
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

# A linked worktree holds the physical config while the Git common directory identifies _stack/main.
# Resolve DiscordOS from that logical root so the same config reaches the canonical checkout in both modes.
$discordosPhysicalConfigPath = Join-Path -Path $physicalStackRoot -ChildPath "ops\\codex\\repos\\discordos\\config.toml"
$discordosLogicalConfigDirectory = Join-Path -Path $logicalStackRoot -ChildPath "ops\\codex\\repos\\discordos"
$discordosConfig = ConvertFrom-SimpleToml -Path $discordosPhysicalConfigPath
$expectedDiscordosConfigKeys = @("adapter_path", "repo_root")
$actualDiscordosConfigKeys = @($discordosConfig.Keys | Sort-Object)
Assert-Condition -Condition ($null -eq (Compare-Object -ReferenceObject $expectedDiscordosConfigKeys -DifferenceObject $actualDiscordosConfigKeys)) -Message "DiscordOS config must contain only repo_root and adapter_path."
Assert-Condition -Condition ([string]$discordosConfig.repo_root -eq "../../../../../DiscordOS") -Message "DiscordOS config repo_root must retain the canonical relative path."
Assert-Condition -Condition ([string]$discordosConfig.adapter_path -eq "./adapter.json") -Message "DiscordOS config adapter_path must stay local."

$canonicalDiscordosRoot = (Resolve-Path -LiteralPath (Join-Path -Path (Split-Path -Parent $logicalStackRoot) -ChildPath "DiscordOS")).Path
$discordosLogicalConfigCandidate = [System.IO.Path]::GetFullPath((Join-Path -Path $discordosLogicalConfigDirectory -ChildPath ([string]$discordosConfig.repo_root)))
$resolvedDiscordosConfigRoot = (Resolve-Path -LiteralPath $discordosLogicalConfigCandidate).Path
Assert-Condition -Condition ($resolvedDiscordosConfigRoot -eq $canonicalDiscordosRoot) -Message "DiscordOS config repo_root must resolve from _stack/main and isolated _stack worktrees to the canonical DiscordOS checkout."

$compactNameFixtureRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("atlas-worktree-name-fixture-{0}" -f ([guid]::NewGuid().ToString("N")))
try {
    New-Item -ItemType Directory -Path $compactNameFixtureRoot -Force | Out-Null

    Assert-Condition -Condition ($null -eq (Get-ValidatedWorktreeNameMaxLength -Execution ([pscustomobject]@{}))) -Message "An omitted worktreeNameMaxLength must preserve the existing unbounded physical-name behavior."
    Assert-Condition -Condition ((Get-ValidatedWorktreeNameMaxLength -Execution ([pscustomobject]@{ worktreeNameMaxLength = 16 })) -eq 16) -Message "A supported integer worktreeNameMaxLength must be accepted."
    foreach ($invalidWorktreeNameMaxLength in @(11, 129, "16", 16.5)) {
        $rejected = $false
        try {
            [void](Get-ValidatedWorktreeNameMaxLength -Execution ([pscustomobject]@{ worktreeNameMaxLength = $invalidWorktreeNameMaxLength }))
        }
        catch {
            $rejected = $_.Exception.Message.Contains("worktreeNameMaxLength")
        }
        Assert-Condition -Condition $rejected -Message ("worktreeNameMaxLength value '{0}' must fail closed." -f $invalidWorktreeNameMaxLength)
    }

    $shortTaskName = Get-UniqueTaskName -RootSlug "short-task" -BranchPrefix "codex/" -WorktreeRoot $compactNameFixtureRoot -WorktreeNameMaxLength 16 -WorkingDirectory $physicalStackRoot
    Assert-Condition -Condition ($shortTaskName.WorktreeDirectoryName -eq "short-task" -and $shortTaskName.BranchName -eq "codex/short-task") -Message "Short task candidates must remain deterministic and descriptive."

    $longTaskSlug = "worktree-directory-budget-contract-candidate-with-readable-prefix"
    $longTaskName = Get-UniqueTaskName -RootSlug $longTaskSlug -BranchPrefix "codex/" -WorktreeRoot $compactNameFixtureRoot -WorktreeNameMaxLength 16 -WorkingDirectory $physicalStackRoot
    $sameLongTaskName = Get-UniqueTaskName -RootSlug $longTaskSlug -BranchPrefix "codex/" -WorktreeRoot $compactNameFixtureRoot -WorktreeNameMaxLength 16 -WorkingDirectory $physicalStackRoot
    Assert-Condition -Condition ($longTaskName.WorktreeDirectoryName.Length -le 16 -and $longTaskName.WorktreeDirectoryName -match "^[a-z0-9-]+$" -and $longTaskName.WorktreeDirectoryName -match "-[a-f0-9]{8}$") -Message "Long task candidates must compact to a filesystem-safe 16-character readable-prefix hash name."
    Assert-Condition -Condition ($longTaskName.WorktreeDirectoryName -eq $sameLongTaskName.WorktreeDirectoryName) -Message "Long task candidate compaction must be deterministic."
    Assert-Condition -Condition ($longTaskName.BranchName -eq ("codex/{0}" -f $longTaskSlug) -and $longTaskName.WorktreeDirectoryName -ne $longTaskSlug) -Message "Branch identity must remain descriptive while the physical worktree directory is compact."

    $samePrefixTaskName = Get-UniqueTaskName -RootSlug "worktree-directory-budget-contract-candidate-with-readable-prefix-alternate" -BranchPrefix "codex/" -WorktreeRoot $compactNameFixtureRoot -WorktreeNameMaxLength 16 -WorkingDirectory $physicalStackRoot
    Assert-Condition -Condition ($longTaskName.WorktreeDirectoryName -ne $samePrefixTaskName.WorktreeDirectoryName) -Message "Long candidates with the same visible prefix must receive distinct hash-suffixed worktree names."

    New-Item -ItemType Directory -Path $longTaskName.WorktreePath -Force | Out-Null
    $collisionTaskName = Get-UniqueTaskName -RootSlug $longTaskSlug -BranchPrefix "codex/" -WorktreeRoot $compactNameFixtureRoot -WorktreeNameMaxLength 16 -WorkingDirectory $physicalStackRoot
    Assert-Condition -Condition ($collisionTaskName.Slug -eq ("{0}-2" -f $longTaskSlug) -and $collisionTaskName.BranchName -eq ("codex/{0}-2" -f $longTaskSlug) -and $collisionTaskName.WorktreeDirectoryName -ne $longTaskName.WorktreeDirectoryName) -Message "Physical worktree collisions must retain the descriptive branch collision counter while deriving a new compact directory name."
}
finally {
    if (Test-Path -LiteralPath $compactNameFixtureRoot) {
        Remove-Item -LiteralPath $compactNameFixtureRoot -Recurse -Force
    }
}

$discordosAdapter = Get-Content -LiteralPath (Join-Path -Path $physicalStackRoot -ChildPath "ops\\codex\\repos\\discordos\\adapter.json") -Raw | ConvertFrom-Json
Assert-Condition -Condition ([string]$discordosAdapter.schemaVersion -eq "1.2") -Message "DiscordOS adapter schemaVersion must be 1.2."
Assert-Condition -Condition ([string]$discordosAdapter.repoId -eq "discordos") -Message "DiscordOS adapter repoId must be discordos."
Assert-Condition -Condition ([string]$discordosAdapter.description -match "canonical board and Discord writer") -Message "DiscordOS adapter description must identify the canonical board and Discord writer."
Assert-Condition -Condition (@($discordosAdapter.verify.bootstrapCommands).Count -eq 1 -and [string]$discordosAdapter.verify.bootstrapCommands[0] -eq "npm ci") -Message "DiscordOS verification bootstrap must be npm ci."

$expectedDiscordosArtifactPaths = [ordered]@{
    inboxDir = "../../runtime/codex/discordos/inbox"
    archiveDir = "../../runtime/codex/discordos/archive"
    logsDir = "../../runtime/codex/discordos/logs"
    worktreeRoot = "../../runtime/w/d"
    exportsDir = "../../runtime/codex/discordos/exports"
}
$expectedDiscordosRuntimeRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $canonicalDiscordosRoot -ChildPath "../../runtime/codex/discordos"))
$expectedDiscordosWorktreeRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $canonicalDiscordosRoot -ChildPath "../../runtime/w/d"))
$expectedDiscordosArtifactDestinations = [ordered]@{
    inboxDir = (Join-Path -Path $expectedDiscordosRuntimeRoot -ChildPath "inbox")
    archiveDir = (Join-Path -Path $expectedDiscordosRuntimeRoot -ChildPath "archive")
    logsDir = (Join-Path -Path $expectedDiscordosRuntimeRoot -ChildPath "logs")
    worktreeRoot = $expectedDiscordosWorktreeRoot
    exportsDir = (Join-Path -Path $expectedDiscordosRuntimeRoot -ChildPath "exports")
}
foreach ($artifactName in $expectedDiscordosArtifactPaths.Keys) {
    $artifactPath = [string]$discordosAdapter.artifacts.$artifactName
    Assert-Condition -Condition ($artifactPath -eq $expectedDiscordosArtifactPaths[$artifactName]) -Message ("DiscordOS artifact path '{0}' must use the exact portable Atlas runtime path." -f $artifactName)
    Assert-Condition -Condition (-not $artifactPath.Contains(".codex")) -Message ("DiscordOS artifact path '{0}' must not target a .codex destination in the owner checkout." -f $artifactName)
}

# The config resolves DiscordOS to this canonical owner root from both _stack/main and a linked worktree.
# Resolve every adapter artifact from that owner root in each caller context; the destinations must stay in Atlas runtime.
$discordosArtifactResolutionContexts = @(
    [pscustomobject]@{ name = "_stack/main"; repoRoot = $canonicalDiscordosRoot },
    [pscustomobject]@{ name = "isolated _stack worktree"; repoRoot = $resolvedDiscordosConfigRoot }
)
foreach ($context in $discordosArtifactResolutionContexts) {
    foreach ($artifactName in $expectedDiscordosArtifactPaths.Keys) {
        $resolvedArtifactPath = Resolve-RepoPath -Root $context.repoRoot -Value ([string]$discordosAdapter.artifacts.$artifactName)
        Assert-Condition -Condition ([string]::Equals($resolvedArtifactPath, $expectedDiscordosArtifactDestinations[$artifactName], [System.StringComparison]::OrdinalIgnoreCase)) -Message ("DiscordOS artifact path '{0}' must resolve from {1} into its configured Atlas runtime destination." -f $artifactName, $context.name)
    }
}

$longestDiscordosTrackedRelativePathLength = [int]((Invoke-GitChecked -WorkingDirectory $canonicalDiscordosRoot -Arguments @("ls-files")).StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
$projectedDiscordosPathLength = (Join-Path -Path $expectedDiscordosWorktreeRoot -ChildPath ("x" * 16)).Length + 1 + $longestDiscordosTrackedRelativePathLength
Assert-Condition -Condition ($longestDiscordosTrackedRelativePathLength -eq 218) -Message "DiscordOS path-budget proof must measure the current 218-character longest tracked relative path."
Assert-Condition -Condition ($projectedDiscordosPathLength -lt 260) -Message ("DiscordOS short worktree root and 16-character directory budget must keep the longest checkout path below 260 characters; projected {0}." -f $projectedDiscordosPathLength)

$expectedDiscordosVerificationCommands = @(
    "npm run verify",
    "npm run verify:discord-update-post",
    "npm run verify:discord-update-target-admission",
    "npm run verify:discord-forum-card-lifecycle",
    "npm run verify:discord-publication-status",
    "npm run verify:discordos-board-lifecycle-sync",
    "npm run verify:discordos-product-workflow-live-readback",
    "git diff --check"
)
$actualDiscordosVerificationCommands = @($discordosAdapter.verify.defaultCommands | ForEach-Object { [string]$_ })
Assert-Condition -Condition ($actualDiscordosVerificationCommands.Count -eq $expectedDiscordosVerificationCommands.Count -and $null -eq (Compare-Object -ReferenceObject $expectedDiscordosVerificationCommands -DifferenceObject $actualDiscordosVerificationCommands)) -Message "DiscordOS adapter verification commands must match the complete owner contract."

$expectedDiscordosMutationSurfaces = @(
    ".codex/**",
    ".github/**",
    ".gitignore",
    "AGENTS.md",
    "README.md",
    "api/**",
    "config/**",
    "docs/**",
    "package.json",
    "package-lock.json",
    "public/**",
    "scripts/**",
    "src/**",
    "supabase/**",
    "tests/**",
    "tsconfig.json",
    "vercel.json"
)
$actualDiscordosMutationSurfaces = @($discordosAdapter.allowedMutationSurfaces | ForEach-Object { [string]$_ })
Assert-Condition -Condition ($actualDiscordosMutationSurfaces.Count -eq $expectedDiscordosMutationSurfaces.Count -and $null -eq (Compare-Object -ReferenceObject $expectedDiscordosMutationSurfaces -DifferenceObject $actualDiscordosMutationSurfaces)) -Message "DiscordOS adapter mutation allowlist must match the complete owner contract."

Assert-Condition -Condition ([string]$discordosAdapter.pushPolicy.mode -eq "manual-only" -and [bool]$discordosAdapter.pushPolicy.skipPush -and -not [bool]$discordosAdapter.pushPolicy.allowAutoPush) -Message "DiscordOS push policy must stay manual-only with auto-push disabled."
Assert-Condition -Condition ([bool]$discordosAdapter.autoCommitPolicy.enabled -and [string]$discordosAdapter.autoCommitPolicy.mode -eq "on-successful-mutation" -and [bool]$discordosAdapter.autoCommitPolicy.requireVerificationPass) -Message "DiscordOS auto-commit must require verified successful mutation."
Assert-Condition -Condition ([string]$discordosAdapter.localLandingPolicy.mode -eq "disabled") -Message "DiscordOS local landing must stay disabled."
Assert-Condition -Condition ([string]$discordosAdapter.execution.baseRef -eq "origin/main" -and [string]$discordosAdapter.execution.branchPrefix -eq "codex/" -and -not [bool]$discordosAdapter.execution.fetchOrigin -and -not [bool]$discordosAdapter.execution.cleanupWorktreeOnSuccess) -Message "DiscordOS execution policy must preserve its owner Git contract."
Assert-Condition -Condition ([int]$discordosAdapter.execution.worktreeNameMaxLength -eq 16) -Message "DiscordOS execution policy must use the 16-character physical worktree-name budget."
Assert-Condition -Condition ($null -eq (Get-ObjectPropertyValue -Object $discordosAdapter.execution -Name "defaultSandbox" -DefaultValue $null) -and $null -eq (Get-ObjectPropertyValue -Object $discordosAdapter.execution -Name "documentedWindowsFallback" -DefaultValue $null)) -Message "DiscordOS adapter must not carry runtime-policy defaults."

$discordosAuthorityRules = @($discordosAdapter.docsUpdateRules) -join "`n"
foreach ($requiredDiscordosAuthorityPhrase in @("one logical writer", "Host capability is not authority", "production-environment readiness", "exact bot-backed readback", "current-thread", "per named project")) {
    Assert-Condition -Condition ($discordosAuthorityRules.Contains($requiredDiscordosAuthorityPhrase)) -Message ("DiscordOS authority rule is missing: {0}" -f $requiredDiscordosAuthorityPhrase)
}

$discordosManifest = $workspaceManifest.repos.discordos
Assert-Condition -Condition ($null -ne $discordosManifest) -Message "Workspace manifest must declare DiscordOS."
Assert-Condition -Condition ([string]$discordosManifest.path -eq "../DiscordOS" -and [string]$discordosManifest.verify -eq "npm run verify" -and [string]$discordosManifest.deployModel -eq "vercel-cli") -Message "Workspace manifest must retain the DiscordOS path, verify command, and Vercel CLI deployment model."
Assert-Condition -Condition ([string]$discordosManifest.deployPreview -match "vercel.*deploy" -and [string]$discordosManifest.deployPreview -notmatch "--prod") -Message "Workspace manifest must declare a non-production DiscordOS preview deploy path."
Assert-Condition -Condition ([bool]$discordosManifest.productionApproval.required -and [string]$discordosManifest.productionApproval.scope -eq "current-thread-per-project" -and [string]$discordosManifest.productionApproval.contract -match "explicit current-thread approval") -Message "Workspace manifest must declare current-thread-per-project DiscordOS production approval."

$discordosOperatorDocumentation = (Get-Content -LiteralPath "README.md" -Raw) + "`n" + (Get-Content -LiteralPath "docs/codex-orchestration.md" -Raw)
foreach ($requiredDiscordosDocumentationPhrase in @('`_stack` is the execution operator', "single logical canonical board and Discord writer", "production-environment readiness", "exact bot-backed readback", "current-thread", "per named project")) {
    Assert-Condition -Condition ($discordosOperatorDocumentation.Contains($requiredDiscordosDocumentationPhrase)) -Message ("DiscordOS operator documentation is missing: {0}" -f $requiredDiscordosDocumentationPhrase)
}

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
    "ops/codex/repos/playbook-doctrine/adapter.json",
    "ops/codex/repos/lifeline/adapter.json",
    "ops/codex/repos/discordos/adapter.json"
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

$playbookDoctrineConfigPath = "ops/codex/repos/playbook-doctrine/config.toml"
$playbookDoctrineAdapterPath = "ops/codex/repos/playbook-doctrine/adapter.json"
Assert-Condition -Condition (Test-Path -LiteralPath $playbookDoctrineConfigPath) -Message "Playbook doctrine config is missing."
Assert-Condition -Condition (Test-Path -LiteralPath $playbookDoctrineAdapterPath) -Message "Playbook doctrine adapter is missing."

$playbookDoctrineAdapter = Get-Content -LiteralPath $playbookDoctrineAdapterPath -Raw | ConvertFrom-Json
$expectedDoctrineSurfaces = @(
    ".codex/**",
    ".agents/skills/review-project-next-step/**",
    "docs/doctrine/**",
    "scripts/validate-doctrine-registry.mjs",
    "test/scripts/validate-doctrine-registry.test.mjs"
)
foreach ($expectedDoctrineSurface in $expectedDoctrineSurfaces) {
    Assert-Condition -Condition ($expectedDoctrineSurface -in $playbookDoctrineAdapter.allowedMutationSurfaces) -Message ("Playbook doctrine adapter is missing exact surface: {0}" -f $expectedDoctrineSurface)
}
foreach ($forbiddenDoctrineSurface in @("packages/**", "docs/**", "scripts/**", "test/**", "package.json", "docs/PLAYBOOK_PRODUCT_ROADMAP.md")) {
    Assert-Condition -Condition ($forbiddenDoctrineSurface -notin $playbookDoctrineAdapter.allowedMutationSurfaces) -Message ("Playbook doctrine adapter must stay narrow: {0}" -f $forbiddenDoctrineSurface)
}
Assert-Condition -Condition ("pnpm agents:check" -notin $playbookDoctrineAdapter.verify.defaultCommands) -Message "Playbook doctrine verification must not fail on unrelated managed-doc drift outside its admitted paths."

$playbookDoctrineScript = [string]$package.scripts.PSObject.Properties["codex:playbook-doctrine:task"].Value
Assert-Condition -Condition ($playbookDoctrineScript -eq "powershell -NoProfile -ExecutionPolicy Bypass -File .\ops\codex\Invoke-CodexRepoTask.ps1 -ConfigPath .\ops\codex\repos\playbook-doctrine\config.toml") -Message "Playbook doctrine package script must use the dedicated shared-runner config."

$repoTaskRunnerText = Get-Content -LiteralPath "ops/codex/Invoke-CodexRepoTask.ps1" -Raw
Assert-Condition -Condition ($repoTaskRunnerText -match '(?ms)Resolve-StackRuntimePolicy.*?-ProbeTargetPath\s+\$worktreePath') -Message "Repo task runtime-policy probing must load configuration from the execution worktree, not the canonical checkout."

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
        },
        @{
            Name = "inline-code path pattern prompt"
            FileName = "inline-code-path-pattern-prompt.md"
            Content = @'
Title: Inline-code path pattern prompt

Objective:
Prove only path-pattern policy fields unwrap balanced inline code.

Acceptance Criteria:
- Keep `docs/ops/example.md` in acceptance-criterion prose.
- Preserve unmatched delimiter prose like `docs/ops/unmatched.md.

Expected Changed Paths:
- `docs/ops/example.md`
- ``docs/ops/**/*.md``
- docs/ops/plain.txt
- `docs/ops/unmatched.md

Expected Unchanged Paths:
- `docs/ops/unchanged.md`

Blocked / Skipped Reporting Rules:
- Report `docs/ops/example.md` verbatim in blocked/skipped prose.
'@
            ExpectedTitle = "Inline-code path pattern prompt"
            ExpectedVerify = @()
            ExpectedBranchSlug = $null
            ExpectedAcceptanceCriteria = @(
                @{ id = "ac-01"; text = 'Keep `docs/ops/example.md` in acceptance-criterion prose.' },
                @{ id = "ac-02"; text = 'Preserve unmatched delimiter prose like `docs/ops/unmatched.md.' }
            )
            ExpectedChangedPaths = @("docs/ops/example.md", "docs/ops/**/*.md", "docs/ops/plain.txt", '`docs/ops/unmatched.md')
            ExpectedUnchangedPaths = @("docs/ops/unchanged.md")
            ExpectedBlockedSkippedRules = @('Report `docs/ops/example.md` verbatim in blocked/skipped prose.')
        },
        @{
            Name = "verified no-change metadata"
            FileName = "verified-no-change-prompt.md"
            Content = @"
Title: Verified no-change canary
Allow No Changes: true
No-Change Proof Path: .codex/no-change-proof.json
No-Change Assertion IDs: canary-invoked, no-send-confirmed

Objective:
Prove the bounded no-send canary completed without repository changes.
"@
            ExpectedTitle = "Verified no-change canary"
            ExpectedVerify = @()
            ExpectedBranchSlug = $null
            ExpectedAllowNoChanges = $true
            ExpectedNoChangeProofPath = ".codex/no-change-proof.json"
            ExpectedNoChangeAssertionIds = @("canary-invoked", "no-send-confirmed")
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
        if ([bool](Get-ObjectPropertyValue -Object $parsedPrompt -Name "AllowNoChanges" -DefaultValue $false) -ne $(if ($promptCase.ContainsKey("ExpectedAllowNoChanges")) { [bool]$promptCase.ExpectedAllowNoChanges } else { $false })) {
            throw ("Parse-PromptFile resolved the wrong Allow No Changes value for the {0} case." -f $promptCase.Name)
        }
        if ([string](Get-ObjectPropertyValue -Object $parsedPrompt -Name "NoChangeProofPath" -DefaultValue "") -ne $(if ($promptCase.ContainsKey("ExpectedNoChangeProofPath")) { [string]$promptCase.ExpectedNoChangeProofPath } else { "" })) {
            throw ("Parse-PromptFile resolved the wrong No-Change Proof Path for the {0} case." -f $promptCase.Name)
        }
        $expectedNoChangeAssertionIds = if ($promptCase.ContainsKey("ExpectedNoChangeAssertionIds")) { @($promptCase.ExpectedNoChangeAssertionIds) } else { @() }
        if ((@($parsedPrompt.NoChangeAssertionIds) -join "|") -ne ($expectedNoChangeAssertionIds -join "|")) {
            throw ("Parse-PromptFile resolved the wrong No-Change Assertion IDs for the {0} case." -f $promptCase.Name)
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

    $sectionTerminationPromptPath = Join-Path -Path $parserTestRoot -ChildPath "section-termination-prompt.md"
    $sectionTerminationPromptText = @'
Title: Atlas lock refresh parser fixture

Objective:
Prove section termination at ordinary headings.

Acceptance Criteria:
- [ac-01] Keep the canonical writer lock refresh bounded.
- Confirm the parser preserves the second criterion id.

## Notes
This explanatory paragraph must not become ac-03.

```yaml
- this fenced example must not become ac-04
```

## Verification
- git diff --check

## Deliver back
```yaml
stack_spec_to_diff_prompt_parser_repair_receipt:
  regression: preserved
```
'@
    [System.IO.File]::WriteAllText($sectionTerminationPromptPath, $sectionTerminationPromptText)
    $sectionTerminationPromptRecord = Parse-PromptFile -Path $sectionTerminationPromptPath
    $sectionTerminationCriterionIds = @($sectionTerminationPromptRecord.AcceptanceCriteria | ForEach-Object { [string]$_.id })
    if (($sectionTerminationCriterionIds -join "|") -ne "ac-01|ac-02") {
        throw ("Section termination prompt produced the wrong criterion ids: {0}" -f ($sectionTerminationCriterionIds -join ", "))
    }
    if ($sectionTerminationCriterionIds -contains "ac-03") {
        throw "Section termination prompt incorrectly produced ac-03."
    }

    $emptySectionsPromptPath = Join-Path -Path $parserTestRoot -ChildPath "explicit-empty-spec-to-diff-sections.md"
    $emptySectionsPromptText = @'
Title: Explicit empty spec-to-diff sections

Objective:
Prove empty machine-readable sections stay empty.

Acceptance Criteria:
- [ac-01] Keep empty expected-path sections out of validation.

Expected Changed Paths:
-

Expected Unchanged Paths:
-

Blocked / Skipped Reporting Rules:
-
'@
    [System.IO.File]::WriteAllText($emptySectionsPromptPath, $emptySectionsPromptText)
    $emptySectionsPromptRecord = Parse-PromptFile -Path $emptySectionsPromptPath
    $emptySectionsPolicy = Get-SpecToDiffPromptPolicy -PromptRecord $emptySectionsPromptRecord
    if (@($emptySectionsPolicy.expectedChangedPaths).Count -ne 0 -or @($emptySectionsPolicy.expectedUnchangedPaths).Count -ne 0 -or @($emptySectionsPolicy.blockedSkippedRules).Count -ne 0) {
        throw "Explicit empty spec-to-diff sections should produce empty policy arrays."
    }
    $emptySectionsBlock = Get-SpecToDiffInstructionBlock -Policy $emptySectionsPolicy
    Assert-CleanSpecToDiffInstructionBlock -Block $emptySectionsBlock -Context "Shared formatter empty-sections fixture" -ExpectedCriterionIds @("ac-01") -ExpectedNoneDeclaredCount 3
    if ($emptySectionsBlock -match "Expected changed paths:\s*-+\s*$" -or $emptySectionsBlock -match "Expected unchanged paths:\s*-+\s*$") {
        throw "Shared formatter emitted an empty bullet marker instead of '- none declared'."
    }

    $invalidNoChangePromptPath = Join-Path -Path $parserTestRoot -ChildPath "invalid-no-change-prompt.md"
    [System.IO.File]::WriteAllText($invalidNoChangePromptPath, "Title: Invalid no change`r`nAllow No Changes: maybe`r`n`r`nObjective:`r`nReject invalid boolean metadata.`r`n")
    try { $null = Parse-PromptFile -Path $invalidNoChangePromptPath; throw "Invalid Allow No Changes metadata unexpectedly parsed." }
    catch { if ($_.Exception.Message -notmatch "Allow No Changes must be true or false") { throw } }

    $noChangePromptPath = Join-Path -Path $parserTestRoot -ChildPath "no-change-proof-prompt.md"
    [System.IO.File]::WriteAllText($noChangePromptPath, @"
Title: No-change proof fixture
Allow No Changes: true
No-Change Proof Path: .codex/no-change-proof.json
No-Change Assertion IDs: first-check, second-check

Objective:
Validate the verified no-change schema.
"@)
    $noChangePrompt = Parse-PromptFile -Path $noChangePromptPath
    $noChangePolicy = Get-NoChangePromptPolicy -PromptRecord $noChangePrompt
    if (-not $noChangePolicy.admissionValid) { throw ("Verified no-change admission fixture should be valid: {0}" -f ($noChangePolicy.blockingReasons -join "; ")) }
    $validNoChangeProof = [pscustomobject]@{ parseError = $null; payload = [pscustomobject]@{ schemaVersion = "1.0"; status = "passed"; summary = "Both bounded checks passed without a send."; assertions = @([pscustomobject]@{ id = "first-check"; status = "passed"; evidence = [pscustomobject]@{ command = "npm.cmd run canary" } }, [pscustomobject]@{ id = "second-check"; status = "passed"; evidence = [pscustomobject]@{ send = $false } }); blockers = @() } }
    $validNoChangeResult = Test-NoChangeCompletionProof -Policy $noChangePolicy -ArtifactRecord $validNoChangeProof
    if (-not $validNoChangeResult.isValid -or @($validNoChangeResult.provenAssertionIds).Count -ne 2) { throw "Verified no-change proof fixture should pass with complete, unique passed assertions." }
    foreach ($invalidNoChangeCase in @(
        @{ name = "missing"; proof = $null },
        @{ name = "malformed"; proof = [pscustomobject]@{ parseError = "Unexpected token"; payload = $null } },
        @{ name = "missing assertion"; proof = [pscustomobject]@{ parseError = $null; payload = [pscustomobject]@{ schemaVersion = "1.0"; status = "passed"; summary = "bounded"; assertions = @([pscustomobject]@{ id = "first-check"; status = "passed"; evidence = @{} }); blockers = @() } } },
        @{ name = "duplicate assertion"; proof = [pscustomobject]@{ parseError = $null; payload = [pscustomobject]@{ schemaVersion = "1.0"; status = "passed"; summary = "bounded"; assertions = @([pscustomobject]@{ id = "first-check"; status = "passed"; evidence = @{} }, [pscustomobject]@{ id = "first-check"; status = "passed"; evidence = @{} }, [pscustomobject]@{ id = "second-check"; status = "passed"; evidence = @{} }); blockers = @() } } },
        @{ name = "unknown assertion"; proof = [pscustomobject]@{ parseError = $null; payload = [pscustomobject]@{ schemaVersion = "1.0"; status = "passed"; summary = "bounded"; assertions = @([pscustomobject]@{ id = "first-check"; status = "passed"; evidence = @{} }, [pscustomobject]@{ id = "second-check"; status = "passed"; evidence = @{} }, [pscustomobject]@{ id = "unknown"; status = "passed"; evidence = @{} }); blockers = @() } } },
        @{ name = "non-passed assertion"; proof = [pscustomobject]@{ parseError = $null; payload = [pscustomobject]@{ schemaVersion = "1.0"; status = "passed"; summary = "bounded"; assertions = @([pscustomobject]@{ id = "first-check"; status = "failed"; evidence = @{} }, [pscustomobject]@{ id = "second-check"; status = "passed"; evidence = @{} }); blockers = @() } } },
        @{ name = "blocker"; proof = [pscustomobject]@{ parseError = $null; payload = [pscustomobject]@{ schemaVersion = "1.0"; status = "passed"; summary = "bounded"; assertions = @([pscustomobject]@{ id = "first-check"; status = "passed"; evidence = @{} }, [pscustomobject]@{ id = "second-check"; status = "passed"; evidence = @{} }); blockers = @("blocked") } } }
    )) {
        if ((Test-NoChangeCompletionProof -Policy $noChangePolicy -ArtifactRecord $invalidNoChangeCase.proof).isValid) { throw ("Verified no-change proof fixture '{0}' unexpectedly passed." -f $invalidNoChangeCase.name) }
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
    $emptyExpectedSectionsProof = Test-SpecToDiffCompletionProof `
        -PromptRecord $emptySectionsPromptRecord `
        -ArtifactRecord ([pscustomobject]@{
            parseError = $null
            payload = [pscustomobject]@{
                contract_version = "atlas.stack.spec_to_diff.v1"
                criteria = @(
                    [pscustomobject]@{
                        criterion_id = "ac-01"
                        status = "satisfied"
                        changed_paths = @("ops/codex/CodexRunner.Common.ps1")
                        diff_evidence = @("none declared")
                        note = ""
                    }
                )
                unchanged_path_justifications = @()
            }
        }) `
        -ChangedPaths @("ops/codex/CodexRunner.Common.ps1") `
        -PathEvidenceMap @{
            "ops/codex/CodexRunner.Common.ps1" = "+none declared"
        }
    if (-not $emptyExpectedSectionsProof.isValid) {
        throw ("Spec-to-diff validation should ignore empty expected-path sections. Reasons: {0}" -f ($emptyExpectedSectionsProof.blockingReasons -join "; "))
    }
    if (@($emptyExpectedSectionsProof.expectedChangedPathMatches).Count -ne 0) {
        throw "Spec-to-diff validation should not create expected-changed-path match records for empty sections."
    }
    if (($emptyExpectedSectionsProof.blockingReasons -join "`n") -match "Expected changed path pattern ''|Expected unchanged path ''") {
        throw "Spec-to-diff validation treated an empty expected-path section as an empty-string pattern."
    }

    $preflightScriptPath = Join-Path -Path (Get-Location).Path -ChildPath "ops/codex/Test-SpecToDiffProof.ps1"
    $preflightPackage = Get-Content -LiteralPath "package.json" -Raw | ConvertFrom-Json
    if ([string]$preflightPackage.scripts.'codex:spec-to-diff:preflight' -notmatch 'Test-SpecToDiffProof\.ps1') {
        throw "package.json does not expose the worker-runnable spec-to-diff preflight."
    }

    $preflightFixtureRoot = Join-Path -Path $parserTestRoot -ChildPath "spec-to-diff-preflight"
    New-Item -ItemType Directory -Path $preflightFixtureRoot -Force | Out-Null
    $null = Invoke-GitChecked -WorkingDirectory $preflightFixtureRoot -Arguments @("init", "--initial-branch=main")
    $null = Invoke-GitChecked -WorkingDirectory $preflightFixtureRoot -Arguments @("config", "user.name", "Atlas Test")
    $null = Invoke-GitChecked -WorkingDirectory $preflightFixtureRoot -Arguments @("config", "user.email", "atlas-test@example.invalid")
    $preflightSourcePath = Join-Path -Path $preflightFixtureRoot -ChildPath "feature.txt"
    [System.IO.File]::WriteAllText($preflightSourcePath, "baseline`n")
    $null = Invoke-GitChecked -WorkingDirectory $preflightFixtureRoot -Arguments @("add", "--", "feature.txt")
    $null = Invoke-GitChecked -WorkingDirectory $preflightFixtureRoot -Arguments @("commit", "-m", "test: add baseline")

    $preflightPromptPath = Join-Path -Path $preflightFixtureRoot -ChildPath "prompt.md"
    [System.IO.File]::WriteAllText($preflightPromptPath, @"
Title: Spec-to-diff preflight fixture

Objective:
Prove the worker preflight before returning control.

Acceptance Criteria:
- [ac-01] Add the deterministic preflight fixture behavior.

Expected Changed Paths:
- feature.txt
"@)
    [System.IO.File]::WriteAllText($preflightSourcePath, "baseline`ndeterministic preflight fixture`n")
    $preflightProofDirectory = Join-Path -Path $preflightFixtureRoot -ChildPath ".codex"
    New-Item -ItemType Directory -Path $preflightProofDirectory -Force | Out-Null
    $preflightProofPath = Join-Path -Path $preflightProofDirectory -ChildPath "spec-to-diff-proof.json"
    [System.IO.File]::WriteAllText($preflightProofPath, (@{
        contract_version = "atlas.stack.spec_to_diff.v1"
        criteria = @(@{
            criterion_id = "ac-01"
            status = "satisfied"
            changed_paths = @("feature.txt")
            diff_evidence = @("deterministic preflight fixture")
            note = ""
        })
        unchanged_path_justifications = @()
    } | ConvertTo-Json -Depth 8))

    $powershellExe = Join-Path -Path $PSHOME -ChildPath "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        $powershellExe = "powershell.exe"
    }
    $preflightEnvironment = @{
        ATLAS_CODEX_PROMPT_PATH = $preflightPromptPath
        ATLAS_CODEX_SPEC_TO_DIFF_PROOF_PATH = $preflightProofPath
    }
    $preflightPass = Invoke-ProcessCapture `
        -FilePath $powershellExe `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $preflightScriptPath) `
        -WorkingDirectory $preflightFixtureRoot `
        -Environment $preflightEnvironment
    if ($preflightPass.ExitCode -ne 0) {
        throw ("Worker spec-to-diff preflight should pass valid literal evidence. stdout: {0}; stderr: {1}" -f $preflightPass.StdOut, $preflightPass.StdErr)
    }
    $preflightPassRecord = $preflightPass.StdOut | ConvertFrom-Json
    if ([string]$preflightPassRecord.status -ne "passed" -or -not [bool]$preflightPassRecord.validation.isValid) {
        throw "Worker spec-to-diff preflight did not emit a passing validation record."
    }
    if (@($preflightPassRecord.changedPaths) -contains ".codex/spec-to-diff-proof.json") {
        throw "Worker spec-to-diff preflight treated its untracked temporary proof artifact as product diff."
    }

    $preservedDirtDirectory = Join-Path -Path $preflightFixtureRoot -ChildPath "accountsettings"
    New-Item -ItemType Directory -Path $preservedDirtDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path -Path $preservedDirtDirectory -ChildPath "preserved.txt"), "preserved dirt`n")
    $directoryEvidence = Get-SpecToDiffPathEvidenceMap -WorkingDirectory $preflightFixtureRoot -ChangedPaths @("accountsettings")
    if ($directoryEvidence["accountsettings"] -ne "") {
        throw "Directory evidence must be an empty non-content proof value."
    }

    $explicitPreflightEnvironment = @{
        ATLAS_CODEX_PROMPT_PATH = $preflightPromptPath
        ATLAS_CODEX_SPEC_TO_DIFF_PROOF_PATH = $preflightProofPath
    }
    $explicitPreflightPass = Invoke-ProcessCapture `
        -FilePath $powershellExe `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $preflightScriptPath, "-ChangedPath", "feature.txt") `
        -WorkingDirectory $preflightFixtureRoot `
        -Environment $explicitPreflightEnvironment
    if ($explicitPreflightPass.ExitCode -ne 0) {
        throw ("Explicit changed-path preflight should isolate task-owned evidence from preserved dirt. stdout: {0}; stderr: {1}" -f $explicitPreflightPass.StdOut, $explicitPreflightPass.StdErr)
    }
    $explicitPreflightRecord = $explicitPreflightPass.StdOut | ConvertFrom-Json
    if (@($explicitPreflightRecord.changedPaths).Count -ne 1 -or [string]$explicitPreflightRecord.changedPaths[0] -ne "feature.txt") {
        throw "Explicit changed-path preflight did not restrict validation to the requested task-owned file."
    }

    foreach ($invalidRequestedPath in @("unchanged.txt", "missing.txt", "../outside.txt", "")) {
        $invalidExplicitPreflight = Invoke-ProcessCapture `
            -FilePath $powershellExe `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $preflightScriptPath, "-ChangedPath", $invalidRequestedPath) `
            -WorkingDirectory $preflightFixtureRoot `
            -Environment $explicitPreflightEnvironment
        if ($invalidExplicitPreflight.ExitCode -eq 0) {
            throw ("Explicit changed-path preflight unexpectedly accepted invalid path '{0}'." -f $invalidRequestedPath)
        }
        $invalidExplicitRecord = $invalidExplicitPreflight.StdOut | ConvertFrom-Json
        if ([string]$invalidExplicitRecord.status -ne "failed" -or @($invalidExplicitRecord.blockingReasons).Count -eq 0) {
            throw ("Explicit changed-path preflight did not fail closed for invalid path '{0}'." -f $invalidRequestedPath)
        }
    }

    $invalidPreflightProof = Get-Content -LiteralPath $preflightProofPath -Raw | ConvertFrom-Json
    $invalidPreflightProof.criteria[0].diff_evidence = @("mistyped proof evidence")
    [System.IO.File]::WriteAllText($preflightProofPath, ($invalidPreflightProof | ConvertTo-Json -Depth 8))
    $preflightFail = Invoke-ProcessCapture `
        -FilePath $powershellExe `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $preflightScriptPath) `
        -WorkingDirectory $preflightFixtureRoot `
        -Environment $preflightEnvironment
    if ($preflightFail.ExitCode -eq 0) {
        throw "Worker spec-to-diff preflight should fail a mistyped literal evidence string."
    }
    $preflightFailRecord = $preflightFail.StdOut | ConvertFrom-Json
    if ([string]$preflightFailRecord.status -ne "failed" -or ($preflightFailRecord.validation.blockingReasons -join "`n") -notmatch "was not found in the final diff") {
        throw "Worker spec-to-diff preflight did not preserve the terminal gate's literal-evidence failure."
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

    $promptFullAccessPolicy = Resolve-StackRuntimePolicy `
        -Config $defaultsConfig `
        -RepoConfig @{} `
        -DefaultsConfig $defaultsConfig `
        -PromptRecord ([pscustomobject]@{
            RuntimePermissions = "full-access"
        }) `
        -ExplicitPolicy ([pscustomobject]@{}) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    if (
        [string]$promptFullAccessPolicy.requested.permissions.mode -ne "full-access" -or
        $null -ne $promptFullAccessPolicy.requested.permissions.permission_profile -or
        $null -ne $promptFullAccessPolicy.requested.permissions.sandbox_mode -or
        [string]$promptFullAccessPolicy.resolved.permissions.mode -ne "full-access" -or
        [string]$promptFullAccessPolicy.resolved.permissions.permission_profile -ne ":danger-full-access" -or
        $null -ne $promptFullAccessPolicy.resolved.permissions.sandbox_mode -or
        [string]$promptFullAccessPolicy.sources.permissions.mode -ne "prompt-metadata" -or
        [string]$promptFullAccessPolicy.sources.permissions.permission_profile -ne "derived-from-prompt-metadata" -or
        @($promptFullAccessPolicy.blockers).Count -ne 0
    ) {
        throw "Prompt full-access must suppress a lower-precedence sandbox and derive the modern permission profile."
    }
    if (@($promptFullAccessPolicy.warnings | Where-Object { $_ -match "suppressed lower-precedence legacy sandbox mode 'workspace-write' from shared-default" }).Count -ne 1) {
        throw "Prompt full-access suppression must receipt the lower-precedence shared sandbox warning."
    }
    $promptFullAccessInvocation = New-CodexInvocationPlan `
        -RuntimePolicy $promptFullAccessPolicy `
        -SummaryPath "C:\temp\summary.md" `
        -WorktreePath "C:\temp\worktree" `
        -Personality "pragmatic"
    if (($promptFullAccessInvocation.arguments -join " ") -notmatch 'default_permissions=":danger-full-access"' -or $promptFullAccessInvocation.arguments -contains "-s") {
        throw "Prompt full-access suppression must produce a modern-only invocation plan."
    }

    $fullAccessProfileDefaults = @{
        runtime_policy = @{
            permissions = "full-access"
            permission_profile = ":danger-full-access"
        }
    }
    $promptWorkspaceWritePolicy = Resolve-StackRuntimePolicy `
        -Config $fullAccessProfileDefaults `
        -RepoConfig @{} `
        -DefaultsConfig $fullAccessProfileDefaults `
        -PromptRecord ([pscustomobject]@{
            RuntimePermissions = "workspace-write"
        }) `
        -ExplicitPolicy ([pscustomobject]@{}) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    if (
        [string]$promptWorkspaceWritePolicy.requested.permissions.mode -ne "workspace-write" -or
        $null -ne $promptWorkspaceWritePolicy.requested.permissions.permission_profile -or
        $null -ne $promptWorkspaceWritePolicy.requested.permissions.sandbox_mode -or
        [string]$promptWorkspaceWritePolicy.resolved.permissions.mode -ne "workspace-write" -or
        $null -ne $promptWorkspaceWritePolicy.resolved.permissions.permission_profile -or
        [string]$promptWorkspaceWritePolicy.resolved.permissions.sandbox_mode -ne "workspace-write" -or
        [string]$promptWorkspaceWritePolicy.sources.permissions.sandbox_mode -ne "derived-from-prompt-metadata" -or
        @($promptWorkspaceWritePolicy.blockers).Count -ne 0
    ) {
        throw "Prompt workspace-write must suppress a lower-precedence full-access permission profile and derive the legacy sandbox."
    }
    if (@($promptWorkspaceWritePolicy.warnings | Where-Object { $_ -match "suppressed lower-precedence permission profile ':danger-full-access' from shared-default" }).Count -ne 1) {
        throw "Prompt workspace-write suppression must receipt the lower-precedence profile warning."
    }

    $explicitMechanismPolicy = Resolve-StackRuntimePolicy `
        -Config $mergedStackConfig `
        -RepoConfig $stackRepoConfig `
        -DefaultsConfig $defaultsConfig `
        -PromptRecord ([pscustomobject]@{}) `
        -ExplicitPolicy ([pscustomobject]@{
            sandbox_mode = "workspace-write"
        }) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    if (
        [string]$explicitMechanismPolicy.requested.permissions.mode -ne "workspace-write" -or
        [string]$explicitMechanismPolicy.resolved.permissions.mode -ne "workspace-write" -or
        [string]$explicitMechanismPolicy.resolved.permissions.sandbox_mode -ne "workspace-write" -or
        [string]$explicitMechanismPolicy.sources.permissions.mode -ne "explicit-arg" -or
        [string]$explicitMechanismPolicy.sources.permissions.sandbox_mode -ne "explicit-arg" -or
        @($explicitMechanismPolicy.blockers).Count -ne 0
    ) {
        throw "A higher-precedence explicit permission mechanism must suppress a lower-precedence permission mode and receipt its source."
    }
    if (@($explicitMechanismPolicy.warnings | Where-Object { $_ -match "suppressed lower-precedence permissions mode 'full-access' from repo-config" }).Count -ne 1) {
        throw "Explicit permission mechanism suppression must receipt the lower-precedence mode warning."
    }

    $equalPrecedenceModeConflictRaised = $false
    try {
        [void](Resolve-StackRuntimePolicy `
            -Config $defaultsConfig `
            -RepoConfig @{} `
            -DefaultsConfig @{} `
            -PromptRecord ([pscustomobject]@{
                RuntimePermissions = "full-access"
                RuntimeSandboxMode = "workspace-write"
            }) `
            -ExplicitPolicy ([pscustomobject]@{}) `
            -CodexCommand "codex.exe" `
            -CliContext $fakeCliContext)
    }
    catch {
        if ($_.Exception.Message -eq "Runtime policy conflict: permissions mode 'full-access' does not match the requested permission mechanism.") {
            $equalPrecedenceModeConflictRaised = $true
        }
        else {
            throw
        }
    }
    if (-not $equalPrecedenceModeConflictRaised) {
        throw "Equal-precedence mismatched permissions mode and mechanism must fail closed with the stable conflict message."
    }

    $sameModePolicy = Resolve-StackRuntimePolicy `
        -Config $defaultsConfig `
        -RepoConfig @{} `
        -DefaultsConfig $defaultsConfig `
        -PromptRecord ([pscustomobject]@{}) `
        -ExplicitPolicy ([pscustomobject]@{}) `
        -CodexCommand "codex.exe" `
        -CliContext $fakeCliContext
    if ([string]$sameModePolicy.resolved.permissions.mode -ne "workspace-write" -or [string]$sameModePolicy.resolved.permissions.sandbox_mode -ne "workspace-write" -or @($sameModePolicy.warnings).Count -ne 0) {
        throw "Matching permission mode and sandbox behavior must remain unchanged."
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
$gitCommonDirectory = (Invoke-GitChecked -WorkingDirectory $repoRoot -Arguments @("rev-parse", "--git-common-dir")).StdOut.Trim()
if (-not [System.IO.Path]::IsPathRooted($gitCommonDirectory)) { $gitCommonDirectory = Join-Path $repoRoot $gitCommonDirectory }
$logicalStackRoot = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($gitCommonDirectory))
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
import { spawnSync } from "node:child_process";

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

const repoRoot = path.resolve(worktreePath, "..", "..", "..");
const logRoot = path.join(repoRoot, ".codex", "logs");
const latestRun = fs.readdirSync(logRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort().at(-1);
const preflightManifest = latestRun
  ? JSON.parse(fs.readFileSync(path.join(logRoot, latestRun, "run.json"), "utf8"))
  : null;
const atlasContractsV2 = preflightManifest?.atlasContractsV2;
if (!atlasContractsV2 || atlasContractsV2.status?.preflight !== "validated") {
  process.stderr.write("Atlas Contracts v2 preflight was not receipted before fake Codex execution.\n");
  process.exit(43);
}
for (const artifactName of ["componentManifest", "jobEnvelope", "contextPacket", "approvalRecord", "workerLease"]) {
  if (!atlasContractsV2.artifactPaths?.[artifactName] || atlasContractsV2.validation?.[artifactName]?.ok !== true) {
    process.stderr.write(`Atlas Contracts v2 ${artifactName} was not validated before fake Codex execution.\n`);
    process.exit(44);
  }
}
if (!String(atlasContractsV2.validation.componentManifest.cliPath ?? "").endsWith("packages\\atlas-contracts\\scripts\\validate-artifact.mjs")) {
  process.stderr.write("Runner did not invoke the Atlas-owned validator CLI.\n");
  process.exit(45);
}

const codexArtifactDirectory = path.join(worktreePath, ".codex");
fs.mkdirSync(codexArtifactDirectory, { recursive: true });

const workerGitFixture = prompt.match(/WORKER_GIT_FIXTURE=([a-z-]+)/)?.[1] ?? null;
if (workerGitFixture) {
  const runGit = (gitArgs) => {
    const result = spawnSync("git", gitArgs, { cwd: worktreePath, encoding: "utf8" });
    if (result.status !== 0) {
      process.stderr.write(result.stderr || result.stdout || `git ${gitArgs.join(" ")} failed\n`);
      process.exit(46);
    }
    return String(result.stdout ?? "").trim();
  };
  if (workerGitFixture === "task-commit") {
    fs.appendFileSync(path.join(worktreePath, "docs", "fixture.md"), "worker committed unexpectedly\n", "utf8");
    runGit(["add", "--", "docs/fixture.md"]);
    runGit(["commit", "--quiet", "-m", "fixture worker commit"]);
  } else if (workerGitFixture === "landing-ref") {
    const tree = runGit(["rev-parse", "HEAD^{tree}"]);
    const parent = runGit(["rev-parse", "HEAD"]);
    const commit = runGit(["commit-tree", tree, "-p", parent, "-m", "fixture landing ref mutation"]);
    runGit(["update-ref", "refs/heads/main", commit]);
  }
  fs.writeFileSync(summaryPath, "Fake Codex attempted a prohibited Git state transition.\n", "utf8");
  process.stdout.write('{"status":"ok"}\n');
  process.exit(0);
}

if (!prompt.includes("Atlas Contracts v2 preflight contract:") ||
    !prompt.includes(atlasContractsV2.artifactPaths.componentManifest) ||
    !prompt.includes(atlasContractsV2.artifactPaths.jobEnvelope) ||
    !prompt.includes(atlasContractsV2.artifactPaths.contextPacket) ||
    !prompt.includes(atlasContractsV2.artifactPaths.approvalRecord) ||
    !prompt.includes(atlasContractsV2.artifactPaths.workerLease)) {
  process.stderr.write("Runner did not inject exact Atlas Contracts v2 preflight paths into the worker prompt.\n");
  process.exit(47);
}

const noChangeFixture = prompt.includes("Allow No Changes: true");
const noChangeMode = (prompt.match(/NO_CHANGE_FIXTURE=([a-z-]+)/)?.[1] ?? "passed");
if (noChangeFixture || noChangeMode === "unapproved") {
  const proofPath = prompt.match(/Write UTF-8 JSON to `([^`]+)`/)?.[1] ?? ".codex/no-change-proof.json";
  if (noChangeFixture && noChangeMode !== "missing") {
    const assertions = [
      { id: "canary-invoked", status: "passed", evidence: { command: "npm.cmd run canary" } },
      { id: "no-send-confirmed", status: "passed", evidence: { send: false } }
    ];
    if (noChangeMode === "duplicate") assertions.push({ id: "canary-invoked", status: "passed", evidence: {} });
    if (noChangeMode === "unknown") assertions.push({ id: "unknown", status: "passed", evidence: {} });
    if (noChangeMode === "failed") assertions[0].status = "failed";
    const proof = noChangeMode === "malformed" ? "{bad json" : JSON.stringify({
      schemaVersion: "1.0",
      status: "passed",
      summary: "Fixture canary ran without a send.",
      assertions: noChangeMode === "partial" ? assertions.slice(0, 1) : assertions,
      blockers: noChangeMode === "blocker" ? ["fixture blocker"] : []
    }, null, 2) + "\n";
    fs.mkdirSync(path.dirname(path.join(worktreePath, proofPath)), { recursive: true });
    fs.writeFileSync(path.join(worktreePath, proofPath), proof, "utf8");
  }
  fs.writeFileSync(summaryPath, "Fake Codex completed the no-change fixture.\n", "utf8");
  process.stdout.write('{"status":"ok"}\n');
  process.exit(0);
}

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

const promptRenderingFixture = prompt.includes("renders machine-readable prompt sections exactly");
const fixtureProofLines = promptRenderingFixture
  ? ["prompt parser repair proof A", "prompt parser repair proof B"]
  : ["runtime policy integration proof"];
const fixtureCriteria = promptRenderingFixture
  ? [
      {
        criterion_id: "ac-01",
        status: "satisfied",
        changed_paths: ["docs/fixture.md"],
        diff_evidence: ["prompt parser repair proof A"],
        note: "Fake Codex completed criterion ac-01."
      },
      {
        criterion_id: "ac-02",
        status: "satisfied",
        changed_paths: ["docs/fixture.md"],
        diff_evidence: ["prompt parser repair proof B"],
        note: "Fake Codex completed criterion ac-02."
      }
    ]
  : [
      {
        criterion_id: "ac-01",
        status: "satisfied",
        changed_paths: ["docs/fixture.md"],
        diff_evidence: ["runtime policy integration proof"],
        note: "Fake Codex completed the fixture mutation."
      }
    ];
fs.appendFileSync(path.join(worktreePath, "docs", "fixture.md"), `${fixtureProofLines.join("\n")}\n`, "utf8");
fs.writeFileSync(
  path.join(codexArtifactDirectory, "commit-meta.json"),
  '{"type":"test","scope":"runtime-fixture","summary":"record runtime policy proof"}\n',
  "utf8"
);
fs.writeFileSync(
  path.join(codexArtifactDirectory, "spec-to-diff-proof.json"),
  `${JSON.stringify({
    contract_version: "atlas.stack.spec_to_diff.v1",
    criteria: fixtureCriteria,
    unchanged_path_justifications: []
  }, null, 2)}\n`,
  "utf8"
);
fs.writeFileSync(summaryPath, promptRenderingFixture ? "Fake Codex completed the prompt rendering fixture.\n" : "Fake Codex completed the runtime-policy fixture.\n", "utf8");

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

    if ($null -eq $integrationManifest.atlasContractsV2 -or [string]$integrationManifest.atlasContractsV2.status.preflight -ne "validated" -or [string]$integrationManifest.atlasContractsV2.status.terminal -ne "success") {
        throw "Integration fixture did not preserve the Atlas Contracts v2 preflight and terminal state."
    }
    foreach ($artifactName in @("componentManifest", "jobEnvelope", "contextPacket", "approvalRecord", "workerLease", "evidenceBundle", "executionReceipt")) {
        $artifactPath = [string]$integrationManifest.atlasContractsV2.artifactPaths.$artifactName
        if ([string]::IsNullOrWhiteSpace($artifactPath) -or -not (Test-Path -LiteralPath $artifactPath)) {
            throw ("Integration fixture did not retain the Atlas Contracts v2 {0} artifact." -f $artifactName)
        }
    }
    if (-not [bool]$integrationManifest.atlasContractsV2.validation.executionReceipt.ok) {
        throw "Integration fixture did not validate the Atlas Contracts v2 terminal receipt."
    }
    $integrationExecutionReceipt = Get-Content -LiteralPath ([string]$integrationManifest.atlasContractsV2.artifactPaths.executionReceipt) -Raw | ConvertFrom-Json
    if ([string]$integrationExecutionReceipt.extensions.run_id -ne [string]$integrationManifest.runId) {
        throw "Integration fixture terminal receipt did not preserve the native run id."
    }
    foreach ($artifactName in @("contextPacket", "approvalRecord", "workerLease", "workerLeaseTerminal", "evidenceBundle")) {
        if (-not [bool]$integrationManifest.atlasContractsV2.validation.$artifactName.ok) {
            throw ("Integration fixture did not validate the Atlas Contracts v2 {0}." -f $artifactName)
        }
    }
    $integrationApprovalRecord = Get-Content -LiteralPath ([string]$integrationManifest.atlasContractsV2.artifactPaths.approvalRecord) -Raw | ConvertFrom-Json
    $integrationWorkerLease = Get-Content -LiteralPath ([string]$integrationManifest.atlasContractsV2.artifactPaths.workerLease) -Raw | ConvertFrom-Json
    if ([string]$integrationWorkerLease.status -ne "released" -or [string]::IsNullOrWhiteSpace([string]$integrationWorkerLease.released_at)) {
        throw "Integration fixture did not release the repo-task WorkerLease at accepted completion."
    }
    if ([string]$integrationWorkerLease.workspace.worktree -ne [string]$integrationExecutionReceipt.correlations.worktree -or [string]$integrationWorkerLease.workspace.branch -ne [string]$integrationExecutionReceipt.correlations.branch) {
        throw "Integration fixture WorkerLease and ExecutionReceipt did not retain the exact isolated worktree and branch identity."
    }
    if ([string]$integrationExecutionReceipt.extensions.worker_lease_binding.lease_id -ne [string]$integrationWorkerLease.lease_id -or [string]$integrationExecutionReceipt.extensions.worker_lease_binding.status -ne "released") {
        throw "Integration fixture ExecutionReceipt did not bind the released WorkerLease."
    }
    if ([string]$integrationApprovalRecord.decision -ne "rejected") {
        throw "Integration fixture fabricated external authority approval."
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

    $renderingPromptPath = Join-Path -Path $integrationRepoRoot -ChildPath ".codex\inbox\spec-to-diff-rendering-fixture.md"
    $renderingHandoffPath = Join-Path -Path $integrationRepoRoot -ChildPath ".codex\inbox\governed-handoff-fixture.json"
    [System.IO.File]::WriteAllText($renderingHandoffPath, '{"fixture":true}' + "`r`n")
    $renderingPrompt = @'
Title: Spec-to-diff prompt rendering fixture
Handoff Ref: .codex/inbox/governed-handoff-fixture.json

Objective:
Prove the shared runner renders machine-readable prompt sections exactly.

Acceptance Criteria:
- [ac-01] Preserve the first declared criterion id in the rendered block.
- Preserve the generated second criterion id in the rendered block.

## Notes
This explanatory paragraph must not become ac-03.

## Verification
- git diff --check

## Deliver back
```yaml
stack_spec_to_diff_prompt_parser_repair_receipt:
  next_packet: Atlas Root Lock Refresh Then DiscordOS Projection Consumer
```
'@
    [System.IO.File]::WriteAllText($renderingPromptPath, $renderingPrompt.TrimStart("`r", "`n") + "`r`n")
    $renderingPromptRecord = Parse-PromptFile -Path $renderingPromptPath
    $renderingExpectedBlock = Get-SpecToDiffInstructionBlock -Policy (Get-SpecToDiffPromptPolicy -PromptRecord $renderingPromptRecord)
    & $powershellExe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexRepoTask.ps1") `
        -PromptPath $renderingPromptPath `
        -ConfigPath $fixtureConfigPath `
        -CodexCommand $fakeCodexCmdPath
    if ($LASTEXITCODE -ne 0) {
        throw ("Repo runner prompt-rendering fixture failed with exit code {0}." -f $LASTEXITCODE)
    }
    $renderingLogDirectory = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $integrationRepoRoot -ChildPath ".codex\logs") -Directory |
        Sort-Object Name |
        Select-Object -Last 1
    )[0]
    if ($null -eq $renderingLogDirectory) {
        throw "Repo runner prompt-rendering fixture did not create a run log directory."
    }
    $renderingManifest = Get-Content -LiteralPath (Join-Path -Path $renderingLogDirectory.FullName -ChildPath "run.json") -Raw | ConvertFrom-Json
    if ([string]$renderingManifest.status -ne "success") {
        throw ("Repo runner prompt-rendering fixture expected success but found '{0}'." -f [string]$renderingManifest.status)
    }
    $renderingEffectivePrompt = Get-Content -LiteralPath (Join-Path -Path $renderingLogDirectory.FullName -ChildPath "effective.prompt.md") -Raw
    $renderingActualBlock = Get-SpecToDiffInstructionBlockText -PromptText $renderingEffectivePrompt
    if ((($renderingActualBlock -replace "`r`n", "`n").Trim()) -ne (($renderingExpectedBlock -replace "`r`n", "`n").Trim())) {
        throw "Repo runner prompt-rendering fixture did not emit the exact shared spec-to-diff instruction block."
    }
    Assert-CleanSpecToDiffInstructionBlock -Block $renderingActualBlock -Context "Repo runner prompt-rendering fixture" -ExpectedCriterionIds @("ac-01", "ac-02") -ExpectedNoneDeclaredCount 3
    if ($renderingActualBlock.Contains("ac-03")) {
        throw "Repo runner prompt-rendering fixture incorrectly rendered ac-03."
    }
    if (-not $renderingEffectivePrompt.Contains("- Governed input handoff references:")) {
        throw "Repo runner prompt-rendering fixture omitted the governed handoff reference heading."
    }
    if (-not $renderingEffectivePrompt.Contains('  - .codex/inbox/governed-handoff-fixture.json')) {
        throw "Repo runner prompt-rendering fixture omitted the normalized governed handoff reference."
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

    $setupFailurePromptPath = Join-Path -Path $integrationRepoRoot -ChildPath ".codex\inbox\setup-failure-fixture.md"
    [System.IO.File]::WriteAllText($setupFailurePromptPath, "Title: Setup failure fixture`r`n`r`nObjective:`r`nProve a pre-worker failure receipts its original classification.`r`n")
    $missingCodexCommandPath = Join-Path -Path $integrationRepoRoot -ChildPath "missing-codex.exe"
    & $powershellExe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexRepoTask.ps1") `
        -PromptPath $setupFailurePromptPath `
        -ConfigPath $fixtureConfigPath `
        -CodexCommand $missingCodexCommandPath
    if ($LASTEXITCODE -eq 0) {
        throw "Repo runner pre-worker setup-failure fixture unexpectedly succeeded."
    }
    $setupFailureLogDirectory = @(
        Get-ChildItem -LiteralPath (Join-Path -Path $integrationRepoRoot -ChildPath ".codex\logs") -Directory |
        Sort-Object Name |
        Select-Object -Last 1
    )[0]
    if ($null -eq $setupFailureLogDirectory) {
        throw "Repo runner pre-worker setup-failure fixture did not create a run log directory."
    }
    $setupFailureManifestPath = Join-Path -Path $setupFailureLogDirectory.FullName -ChildPath "run.json"
    $setupFailureManifestRaw = Get-Content -LiteralPath $setupFailureManifestPath -Raw
    $setupFailureManifest = $setupFailureManifestRaw | ConvertFrom-Json
    if ([string]$setupFailureManifest.status -ne "codex_command_resolution_failed") {
        throw ("Repo runner pre-worker setup-failure fixture must preserve codex_command_resolution_failed, found '{0}'." -f [string]$setupFailureManifest.status)
    }
    if ($null -ne $setupFailureManifest.workerArtifacts.mergeRequest) {
        throw "Repo runner pre-worker setup-failure fixture must receipt a null workerArtifacts.mergeRequest."
    }
    if ($setupFailureManifestRaw.Contains("ParameterArgumentValidationErrorNullNotAllowed")) {
        throw "Repo runner pre-worker setup-failure fixture must not let manifest finalization mask the original failure."
    }

    function Invoke-WorkerGitMutationFixture {
        param([string]$Name, [string]$Mode)
        $path = Join-Path -Path $integrationRepoRoot -ChildPath (".codex\inbox\{0}.md" -f $Name)
        [System.IO.File]::WriteAllText($path, ("Title: $Name`r`n`r`nObjective:`r`nWORKER_GIT_FIXTURE=$Mode`r`n"))
        & $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexRepoTask.ps1") -PromptPath $path -ConfigPath $fixtureConfigPath -CodexCommand $fakeCodexCmdPath | Out-Host
        $exitCode = $LASTEXITCODE
        $log = @(Get-ChildItem -LiteralPath (Join-Path -Path $integrationRepoRoot -ChildPath ".codex\logs") -Directory | Sort-Object Name | Select-Object -Last 1)[0]
        return [pscustomobject]@{ exitCode = $exitCode; manifest = (Get-Content -LiteralPath (Join-Path -Path $log.FullName -ChildPath "run.json") -Raw | ConvertFrom-Json) }
    }

    foreach ($workerGitCase in @(
        [pscustomobject]@{ name = "worker-task-head-mutation"; mode = "task-commit"; violation = "worker_task_head_mutation_detected" },
        [pscustomobject]@{ name = "worker-landing-ref-mutation"; mode = "landing-ref"; violation = "worker_landing_ref_mutation_detected" }
    )) {
        $workerGitResult = Invoke-WorkerGitMutationFixture -Name $workerGitCase.name -Mode $workerGitCase.mode
        if ($workerGitResult.exitCode -ne 18 -or [string]$workerGitResult.manifest.status -ne "worker_git_state_failed") {
            throw ("Worker Git mutation fixture {0} did not fail closed with exit code 18." -f $workerGitCase.mode)
        }
        if ([string]$workerGitResult.manifest.workerGitState.failureCode -ne "worker_git_head_mutation_detected" -or $workerGitCase.violation -notin @($workerGitResult.manifest.workerGitState.violations)) {
            throw ("Worker Git mutation fixture {0} did not receipt the expected stable failure code." -f $workerGitCase.mode)
        }
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

    function Invoke-NoChangeRunnerFixture {
        param([string]$Name, [string]$Mode, [bool]$OptIn = $true, [string]$ProofPath = ".codex/no-change-proof.json", [string]$Verify = "")
        $path = Join-Path -Path $integrationRepoRoot -ChildPath (".codex\inbox\{0}.md" -f $Name)
        $metadata = if ($OptIn) { "Allow No Changes: true`r`nNo-Change Proof Path: $ProofPath`r`nNo-Change Assertion IDs: canary-invoked, no-send-confirmed`r`n" } else { "" }
        $verifyLine = if ([string]::IsNullOrWhiteSpace($Verify)) { "" } else { "Verify: $Verify`r`n" }
        [System.IO.File]::WriteAllText($path, ("Title: $Name`r`n$metadata$verifyLine`r`nObjective:`r`nNO_CHANGE_FIXTURE=$Mode`r`n"))
        & $powershellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexRepoTask.ps1") -PromptPath $path -ConfigPath $fixtureConfigPath -CodexCommand $fakeCodexCmdPath | Out-Host
        $exitCode = $LASTEXITCODE
        $log = @(Get-ChildItem -LiteralPath (Join-Path -Path $integrationRepoRoot -ChildPath ".codex\logs") -Directory | Sort-Object Name | Select-Object -Last 1)[0]
        return [pscustomobject]@{ exitCode = $exitCode; log = $log; manifest = (Get-Content -LiteralPath (Join-Path -Path $log.FullName -ChildPath "run.json") -Raw | ConvertFrom-Json) }
    }

    $noChangeSuccess = Invoke-NoChangeRunnerFixture -Name "no-change-success" -Mode "passed"
    if ($noChangeSuccess.exitCode -ne 0 -or [string]$noChangeSuccess.manifest.status -ne "success_no_changes" -or [string]$noChangeSuccess.manifest.workerArtifacts.completedStatus -eq "") { throw "Opted-in verified no-change fixture must succeed with success_no_changes and a completed worker receipt." }
    if ($null -ne $noChangeSuccess.manifest.commitSha -or @($noChangeSuccess.manifest.changedPaths).Count -ne 0 -or -not $noChangeSuccess.manifest.noChange.artifactRemoved -or -not (Test-Path -LiteralPath (Join-Path -Path $noChangeSuccess.log.FullName -ChildPath "no-change-proof.raw.json")) -or (Test-Path -LiteralPath (Join-Path -Path ([string]$noChangeSuccess.manifest.worktreePath) -ChildPath ".codex\no-change-proof.json"))) { throw "Verified no-change success must not commit, must remove the temporary proof, and must retain its durable raw proof receipt." }
    $noChangeWorker = Get-Content -LiteralPath ([string]$noChangeSuccess.manifest.workerArtifacts.completedStatus) -Raw | ConvertFrom-Json
    if ([string]$noChangeWorker.state -ne "completed") { throw "Verified no-change success must complete the worker." }

    $unapprovedNoChange = Invoke-NoChangeRunnerFixture -Name "no-change-unapproved" -Mode "unapproved" -OptIn $false
    if ($unapprovedNoChange.exitCode -ne 14 -or [string]$unapprovedNoChange.manifest.status -ne "no_changes") { throw "Unapproved clean worktree fixture must preserve no_changes exit code 14." }
    foreach ($mode in @("missing", "malformed", "partial", "duplicate", "unknown", "failed", "blocker")) {
        $failedNoChange = Invoke-NoChangeRunnerFixture -Name ("no-change-" + $mode) -Mode $mode
        if ($failedNoChange.exitCode -ne 14 -or [string]$failedNoChange.manifest.status -ne "no_changes" -or [string]::IsNullOrWhiteSpace([string]$failedNoChange.manifest.noChange.failureReason)) { throw ("Verified no-change {0} fixture must fail closed with no_changes exit code 14." -f $mode) }
    }
    $outsideNoChange = Invoke-NoChangeRunnerFixture -Name "no-change-outside" -Mode "passed" -ProofPath "outside-proof.json"
    if ($outsideNoChange.exitCode -ne 14 -or [string]$outsideNoChange.manifest.status -ne "no_changes") { throw "Outside-.codex proof path fixture must fail closed before execution." }
    $verificationFailureNoChange = Invoke-NoChangeRunnerFixture -Name "no-change-verification-failure" -Mode "passed" -Verify "cmd /c exit 1"
    if ($verificationFailureNoChange.exitCode -ne 11 -or [string]$verificationFailureNoChange.manifest.status -ne "verification_failed" -or $verificationFailureNoChange.manifest.noChange.validationPassed) { throw "A final no-change proof must not bypass a declared verification failure." }

    $trackedProofPath = Join-Path -Path $integrationRepoRoot -ChildPath ".codex\no-change-proof.json"
    [System.IO.File]::WriteAllText($trackedProofPath, "{}")
    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("add", ".codex/no-change-proof.json")
    Invoke-GitChecked -WorkingDirectory $integrationRepoRoot -Arguments @("commit", "--quiet", "-m", "tracked proof fixture")
    $trackedNoChange = Invoke-NoChangeRunnerFixture -Name "no-change-tracked" -Mode "passed"
    if ($trackedNoChange.exitCode -ne 14 -or [string]$trackedNoChange.manifest.status -ne "no_changes" -or $trackedNoChange.manifest.noChange.artifactUntracked) { throw "Tracked no-change proof fixture must fail closed." }

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
