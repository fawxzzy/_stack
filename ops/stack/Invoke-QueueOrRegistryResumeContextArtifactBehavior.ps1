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
$resumeContextResult = Invoke-StackMergeRequestResumeContextConsumer `
    -RepoRoot $repoRoot `
    -ArtifactSearchRoot $ArtifactSearchRoot `
    -MergeRequestPath $MergeRequestPath

$response = [ordered]@{
    resume_context_refs = @($resumeContextResult.resume_context_refs)
    merge_assignment_ref = [string]$resumeContextResult.merge_assignment_ref
    merge_prompt_ref = [string]$resumeContextResult.merge_prompt_ref
    merge_context_ref = [string]$resumeContextResult.merge_context_ref
    merge_handoff_ref = [string]$resumeContextResult.merge_handoff_ref
    payload = [ordered]@{
        merge_request_id = [string]$resumeContextResult.merge_request_id
        merge_request_ref = [string]$resumeContextResult.merge_request_ref
        stack_lock_digest = [string]$resumeContextResult.stack_lock_digest
        tool_id = [string]$resumeContextResult.tool_id
        extension_id = $resumeContextResult.extension_id
        registry_digest = [string]$resumeContextResult.registry_digest
        pause_status_refs = @($resumeContextResult.pause_status_refs)
        pause_statuses = @($resumeContextResult.pause_statuses)
        resume_contexts = @($resumeContextResult.resume_contexts)
        merge_assignment_ref = [string]$resumeContextResult.merge_assignment_ref
        merge_prompt_ref = [string]$resumeContextResult.merge_prompt_ref
        merge_context_ref = [string]$resumeContextResult.merge_context_ref
        merge_handoff_ref = [string]$resumeContextResult.merge_handoff_ref
    }
}

$response | ConvertTo-Json -Depth 20
