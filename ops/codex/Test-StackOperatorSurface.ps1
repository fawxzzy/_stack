Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")

$requiredFiles = @(
    "AGENTS.md",
    "README.md",
    "docs/codex-orchestration.md",
    "docs/dispatcher-protocol.md",
    "ops/codex/Start-CodexInboxRunner.ps1",
    "ops/codex/Invoke-CodexRepoTask.ps1",
    "ops/codex/CodexRunner.Common.ps1",
    "ops/codex/Test-StackOperatorSurface.ps1",
    "ops/codex/adapter.schema.json",
    "ops/codex/repos/stack/adapter.json",
    "ops/codex/repos/stack/config.toml",
    "package.json",
    ".vscode/tasks.json",
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
    "codex:stack:inbox",
    "codex:stack:inbox:once",
    "codex:stack:task"
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
    "Codex: Stack Inbox",
    "Codex: Stack Inbox (Once)",
    "Codex: Stack Task"
)
$missingTaskLabels = @(
    $requiredTaskLabels |
    Where-Object { $_ -notin $taskLabels }
)
if ($missingTaskLabels.Count -gt 0) {
    throw ("Missing required _stack VS Code tasks: {0}" -f ($missingTaskLabels -join ", "))
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
        },
        @{
            Name = "filename fallback"
            FileName = "lifeline-smoke-filename-fallback.md"
            Content = @"
Plain markdown prompt body with no structured metadata.
"@
            ExpectedTitle = "lifeline-smoke-filename-fallback"
            ExpectedVerify = @()
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
