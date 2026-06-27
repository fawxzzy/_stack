param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$MergeRequestPath,
    [Parameter(Mandatory = $true)]
    [string]$ArtifactSearchRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "StackWorkerArtifacts.ps1")

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $WorkspaceRoot -ChildPath "repos\_stack")).Path
$mergerAssignmentResult = Invoke-StackMergeRequestMergerAssignmentConsumer `
    -RepoRoot $repoRoot `
    -ArtifactSearchRoot $ArtifactSearchRoot `
    -MergeRequestPath $MergeRequestPath

$response = [ordered]@{
    merge_assignment_ref = [string]$mergerAssignmentResult.merge_assignment_ref
    merge_prompt_ref = [string]$mergerAssignmentResult.merge_prompt_ref
    merge_context_ref = [string]$mergerAssignmentResult.merge_context_ref
    payload = [ordered]@{
        merge_request_id = [string]$mergerAssignmentResult.merge_request_id
        merge_request_ref = [string]$mergerAssignmentResult.merge_request_ref
        stack_lock_digest = [string]$mergerAssignmentResult.stack_lock_digest
        tool_id = [string]$mergerAssignmentResult.tool_id
        extension_id = $mergerAssignmentResult.extension_id
        registry_digest = [string]$mergerAssignmentResult.registry_digest
        pause_status_refs = @($mergerAssignmentResult.pause_status_refs)
        pause_statuses = @($mergerAssignmentResult.pause_statuses)
        merge_context_ref = [string]$mergerAssignmentResult.merge_context_ref
        merge_prompt_ref = [string]$mergerAssignmentResult.merge_prompt_ref
        merge_assignment_ref = [string]$mergerAssignmentResult.merge_assignment_ref
    }
}

$response | ConvertTo-Json -Depth 20
