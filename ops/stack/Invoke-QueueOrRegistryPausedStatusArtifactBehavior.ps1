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
$pauseStatusResult = Invoke-StackMergeRequestPauseStatusConsumer `
    -RepoRoot $repoRoot `
    -ArtifactSearchRoot $ArtifactSearchRoot `
    -MergeRequestPath $MergeRequestPath

$response = [ordered]@{
    pause_status_refs = @($pauseStatusResult.pause_status_refs)
    payload = [ordered]@{
        merge_request_id = [string]$pauseStatusResult.merge_request_id
        merge_request_ref = [string]$pauseStatusResult.merge_request_ref
        stack_lock_digest = [string]$pauseStatusResult.stack_lock_digest
        tool_id = [string]$pauseStatusResult.tool_id
        extension_id = $pauseStatusResult.extension_id
        registry_digest = [string]$pauseStatusResult.registry_digest
        pause_statuses = @($pauseStatusResult.pause_statuses)
    }
}

$response | ConvertTo-Json -Depth 20
