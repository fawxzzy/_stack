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
$mergeCompletionResult = Invoke-StackMergeRequestMergeCompletionConsumer `
    -RepoRoot $repoRoot `
    -ArtifactSearchRoot $ArtifactSearchRoot `
    -MergeRequestPath $MergeRequestPath

$response = [ordered]@{
    completion_ref = [string]$mergeCompletionResult.completion_ref
    resume_context_refs = @($mergeCompletionResult.resume_context_refs)
    merge_assignment_ref = [string]$mergeCompletionResult.merge_assignment_ref
    merge_prompt_ref = [string]$mergeCompletionResult.merge_prompt_ref
    merge_context_ref = [string]$mergeCompletionResult.merge_context_ref
    merge_handoff_ref = [string]$mergeCompletionResult.merge_handoff_ref
    payload = [ordered]@{
        merge_request_id = [string]$mergeCompletionResult.merge_request_id
        merge_request_ref = [string]$mergeCompletionResult.merge_request_ref
        stack_lock_digest = [string]$mergeCompletionResult.stack_lock_digest
        tool_id = [string]$mergeCompletionResult.tool_id
        extension_id = $mergeCompletionResult.extension_id
        registry_digest = [string]$mergeCompletionResult.registry_digest
        pause_status_refs = @($mergeCompletionResult.pause_status_refs)
        pause_statuses = @($mergeCompletionResult.pause_statuses)
        resume_context_refs = @($mergeCompletionResult.resume_context_refs)
        resume_contexts = @($mergeCompletionResult.resume_contexts)
        merge_assignment_ref = [string]$mergeCompletionResult.merge_assignment_ref
        merge_prompt_ref = [string]$mergeCompletionResult.merge_prompt_ref
        merge_context_ref = [string]$mergeCompletionResult.merge_context_ref
        merge_handoff_ref = [string]$mergeCompletionResult.merge_handoff_ref
        completion_ref = [string]$mergeCompletionResult.completion_ref
    }
}

$response | ConvertTo-Json -Depth 20
