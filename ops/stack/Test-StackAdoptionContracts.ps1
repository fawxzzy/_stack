Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..\..")).Path
$workerArtifactsPath = Join-Path -Path $repoRoot -ChildPath "ops\stack\StackWorkerArtifacts.ps1"
Assert-Condition -Condition (Test-Path -LiteralPath $workerArtifactsPath) -Message ("Worktree-aware workspace helper is missing: {0}" -f $workerArtifactsPath)
. $workerArtifactsPath

$workspaceRoot = Get-StackWorkspaceRoot -RepoRoot $repoRoot
$stackYamlPath = Join-Path -Path $workspaceRoot -ChildPath "stack.yaml"
$stackLockPath = Join-Path -Path $workspaceRoot -ChildPath "stack.lock.yaml"
Assert-Condition -Condition (Test-Path -LiteralPath $stackYamlPath) -Message ("Canonical workspace root must contain stack.yaml: {0}" -f $stackYamlPath)
Assert-Condition -Condition (Test-Path -LiteralPath $stackLockPath) -Message ("Canonical workspace root must contain stack.lock.yaml: {0}" -f $stackLockPath)

$isolatedWorktreeRoot = Join-Path -Path $workspaceRoot -ChildPath "repos\_stack\.codex\worktrees\isolated-adoption-contract-test"
$ordinaryLogicalRepoRoot = Join-Path -Path $workspaceRoot -ChildPath "repos\_stack"
$isolatedWorkspaceRoot = Get-StackWorkspaceRoot -RepoRoot $isolatedWorktreeRoot
$ordinaryWorkspaceRoot = Get-StackWorkspaceRoot -RepoRoot $ordinaryLogicalRepoRoot
Assert-Condition -Condition ($isolatedWorkspaceRoot -eq $workspaceRoot) -Message "An isolated .codex/worktrees repo root must resolve external contracts from the canonical workspace."
Assert-Condition -Condition ($ordinaryWorkspaceRoot -eq $workspaceRoot) -Message "An ordinary logical repo root must resolve external contracts from the canonical workspace."

$adoptionDocPath = Join-Path -Path $repoRoot -ChildPath "docs\STACK-ORCHESTRATION-ADOPTION.md"
$runbookPath = Join-Path -Path $repoRoot -ChildPath "docs\runbooks\STACK-WORKER-FLOW.md"
$readmePath = Join-Path -Path $repoRoot -ChildPath "README.md"
$playbookWorkflowPackPath = Join-Path -Path $workspaceRoot -ChildPath "repos\playbook\docs\contracts\WORKFLOW_PACK_REUSE_CONTRACT.md"
$playbookConsumerPath = Join-Path -Path $workspaceRoot -ChildPath "repos\playbook\docs\CONSUMER_INTEGRATION_CONTRACT.md"
$lifelineContractPath = Join-Path -Path $workspaceRoot -ChildPath "repos\lifeline\docs\contracts\privileged-execution-contract.md"
$fitnessContractPath = Join-Path -Path $workspaceRoot -ChildPath "repos\fawxzzy-fitness\src\lib\ecosystem\fitness-integration-contract.ts"

$requiredPaths = @(
    $adoptionDocPath
    $runbookPath
    $readmePath
    $playbookWorkflowPackPath
    $playbookConsumerPath
    $lifelineContractPath
    $fitnessContractPath
)

foreach ($path in $requiredPaths) {
    Assert-Condition -Condition (Test-Path -LiteralPath $path) -Message ("Required adoption path is missing: {0}" -f $path)
}

$adoptionDoc = Get-Content -Raw -LiteralPath $adoptionDocPath
$runbookDoc = Get-Content -Raw -LiteralPath $runbookPath
$readmeDoc = Get-Content -Raw -LiteralPath $readmePath

$requiredAdoptionSnippets = @(
    "owner freeze landed"
    "consumer, not a copy"
    "WORKFLOW_PACK_REUSE_CONTRACT.md"
    "CONSUMER_INTEGRATION_CONTRACT.md"
    "privileged-execution-contract.md"
    "fitness-integration-contract.ts"
    "atlas.capability.profile.v1"
    "atlas.privileged-action.request.v1"
    "atlas.approval.receipt.v1"
    "atlas.privileged-action.receipt.v1"
    "assignment_created"
    "resume_ready"
)

foreach ($snippet in $requiredAdoptionSnippets) {
    Assert-Condition -Condition ($adoptionDoc.Contains($snippet)) -Message ("Adoption doc is missing required snippet: {0}" -f $snippet)
}

Assert-Condition -Condition ($runbookDoc.Contains("STACK-ORCHESTRATION-ADOPTION.md")) -Message "Worker-flow runbook must reference the _stack adoption contract map."
Assert-Condition -Condition ($runbookDoc.Contains("consumes the Playbook workflow-pack bundle as a consumer")) -Message "Worker-flow runbook must state the Playbook consumer boundary."
Assert-Condition -Condition ($readmeDoc.Contains("STACK-ORCHESTRATION-ADOPTION")) -Message "README must advertise the _stack adoption contract map."

Write-Host "Validated _stack owner-contract adoption against Playbook, Lifeline, and Fitness."
