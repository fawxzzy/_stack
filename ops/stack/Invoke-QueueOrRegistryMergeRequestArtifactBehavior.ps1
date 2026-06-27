param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$ArtifactInputPath,
    [Parameter(Mandatory = $true)]
    [string]$LogDirPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "StackWorkerArtifacts.ps1")

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $WorkspaceRoot -ChildPath "repos\_stack")).Path
$artifactInput = Get-Content -LiteralPath $ArtifactInputPath -Raw | ConvertFrom-Json

$artifact = New-StackWorkerMergeRequest `
    -MergeRequestId ([string]$artifactInput.merge_request_id) `
    -StackLockDigest ([string]$artifactInput.stack_lock_digest) `
    -ConflictingWorkers @($artifactInput.conflicting_workers) `
    -Overlaps @($artifactInput.overlaps) `
    -PausedHandoffRefs @($artifactInput.paused_handoff_refs) `
    -MergeWorkerHandoff $artifactInput.merge_worker_handoff `
    -ToolId ([string]$artifactInput.tool_id) `
    -ExtensionId $artifactInput.extension_id `
    -RegistryDigest ([string]$artifactInput.registry_digest) `
    -Notes ([string]$artifactInput.notes)

$outputPath = Join-Path -Path $LogDirPath -ChildPath "worker.merge-request.json"
[void](Write-StackWorkerArtifact -Artifact $artifact -Path $outputPath)

$response = [ordered]@{
    emitted_artifact_ref = Get-StackRelativePath -RepoRoot $repoRoot -Path $outputPath
    emitted_contract_version = [string]$artifact.contract_version
    payload = $artifact
}

$response | ConvertTo-Json -Depth 20
