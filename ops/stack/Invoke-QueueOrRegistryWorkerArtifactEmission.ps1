param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$Intent,
    [Parameter(Mandatory = $true)]
    [string]$ArtifactInputPath,
    [Parameter(Mandatory = $true)]
    [string]$LogDirPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "StackWorkerArtifacts.ps1")

function Get-OptionalArtifactProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    if ($InputObject.PSObject.Properties.Name -contains $Name) {
        return $InputObject.$Name
    }

    return $DefaultValue
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $WorkspaceRoot -ChildPath "repos\_stack")).Path
$artifactInput = Get-Content -LiteralPath $ArtifactInputPath -Raw | ConvertFrom-Json

$toolId = [string](Get-OptionalArtifactProperty -InputObject $artifactInput -Name "tool_id" -DefaultValue "")
$extensionId = Get-OptionalArtifactProperty -InputObject $artifactInput -Name "extension_id" -DefaultValue $null
$registryDigest = [string](Get-OptionalArtifactProperty -InputObject $artifactInput -Name "registry_digest" -DefaultValue "")
$notes = [string](Get-OptionalArtifactProperty -InputObject $artifactInput -Name "notes" -DefaultValue "")
$blockedReason = Get-OptionalArtifactProperty -InputObject $artifactInput -Name "blocked_reason" -DefaultValue $null
$mergeRequestRef = Get-OptionalArtifactProperty -InputObject $artifactInput -Name "merge_request_ref" -DefaultValue $null

switch ($Intent) {
    "assignment" {
        $artifact = New-StackWorkerAssignment `
            -AssignmentId ([string]$artifactInput.assignment_id) `
            -WorkerId ([string]$artifactInput.worker_id) `
            -TaskId ([string]$artifactInput.task_id) `
            -StackLockDigest ([string]$artifactInput.stack_lock_digest) `
            -AllowedGlobs @($artifactInput.allowed_globs) `
            -ForbiddenGlobs @($artifactInput.forbidden_globs) `
            -InputHandoffRefs @($artifactInput.input_handoff_refs) `
            -ExpectedOutputs @($artifactInput.expected_outputs) `
            -ToolId $toolId `
            -ExtensionId $extensionId `
            -RegistryDigest $registryDigest `
            -Notes $notes
        $artifactFileName = "worker.assignment.json"
    }
    "status-running" {
        $artifact = New-StackWorkerStatus `
            -WorkerId ([string]$artifactInput.worker_id) `
            -AssignmentId ([string]$artifactInput.assignment_id) `
            -State ([string]$artifactInput.state) `
            -HeartbeatAt ([string]$artifactInput.heartbeat_at) `
            -TouchedRanges @($artifactInput.touched_ranges) `
            -OutputRefs @($artifactInput.output_refs) `
            -BlockedReason $blockedReason `
            -MergeRequestRef $mergeRequestRef `
            -ToolId $toolId `
            -ExtensionId $extensionId `
            -RegistryDigest $registryDigest
        $artifactFileName = "worker.status.running.json"
    }
    "status-completed" {
        $artifact = New-StackWorkerStatus `
            -WorkerId ([string]$artifactInput.worker_id) `
            -AssignmentId ([string]$artifactInput.assignment_id) `
            -State ([string]$artifactInput.state) `
            -HeartbeatAt ([string]$artifactInput.heartbeat_at) `
            -TouchedRanges @($artifactInput.touched_ranges) `
            -OutputRefs @($artifactInput.output_refs) `
            -BlockedReason $blockedReason `
            -MergeRequestRef $mergeRequestRef `
            -ToolId $toolId `
            -ExtensionId $extensionId `
            -RegistryDigest $registryDigest
        $artifactFileName = "worker.status.completed.json"
    }
    default {
        throw ("Unsupported worker-artifact emission intent: {0}" -f $Intent)
    }
}

$outputPath = Join-Path -Path $LogDirPath -ChildPath $artifactFileName
[void](Write-StackWorkerArtifact -Artifact $artifact -Path $outputPath)

$response = [ordered]@{
    emitted_artifact_ref = Get-StackRelativePath -RepoRoot $repoRoot -Path $outputPath
    emitted_contract_version = [string]$artifact.contract_version
    payload = $artifact
}

$response | ConvertTo-Json -Depth 20
