Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")

$requiredFiles = @(
    "AGENTS.md",
    "README.md",
    "config/release-targets.json",
    "docs/codex-orchestration.md",
    "docs/dispatcher-protocol.md",
    "ops/assets/release-launcher.ico",
    "ops/Install-ReleaseLauncherShortcut.ps1",
    "ops/Open-ReleaseLauncher.ps1",
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
    "codex:stack:verify"
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
    }
}
finally {
    if (Test-Path -LiteralPath $parserTestRoot) {
        Remove-Item -LiteralPath $parserTestRoot -Recurse -Force
    }
}

Write-Host "Validated _stack operator surface and Codex entrypoints."
