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
    "ops/codex/CodexRunner.Common.ps1",
    "ops/codex/Test-StackOperatorSurface.ps1",
    "ops/codex/adapter.schema.json",
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
    "codex:stack:inbox",
    "codex:stack:inbox:once",
    "codex:stack:task",
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
}
finally {
    if (Test-Path -LiteralPath $parserTestRoot) {
        Remove-Item -LiteralPath $parserTestRoot -Recurse -Force
    }
}

Write-Host "Validated _stack operator surface and Codex entrypoints."
