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
$workspaceRoot = (Resolve-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath "..\..")).Path

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
