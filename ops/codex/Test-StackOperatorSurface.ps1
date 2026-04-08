Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

Write-Host "Validated _stack operator surface and Codex entrypoints."
