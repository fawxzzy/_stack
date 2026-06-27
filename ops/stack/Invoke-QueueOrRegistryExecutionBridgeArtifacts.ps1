param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$WorkerAssignmentPath,
    [Parameter(Mandatory = $true)]
    [string]$WorkerStatusPath,
    [Parameter(Mandatory = $true)]
    [string]$CapabilityProfilePath,
    [Parameter(Mandatory = $true)]
    [string]$RequestPath,
    [Parameter(Mandatory = $true)]
    [string]$ApprovalReceiptPath,
    [Parameter(Mandatory = $true)]
    [string]$ReceiptOutputRootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "StackWorkerArtifacts.ps1")

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $WorkspaceRoot -ChildPath "repos\_stack")).Path
$bridge = Invoke-StackLifelineExecution `
    -RepoRoot $repoRoot `
    -WorkerAssignmentRef $WorkerAssignmentPath `
    -WorkerStatusRef $WorkerStatusPath `
    -CapabilityProfileRef $CapabilityProfilePath `
    -RequestRef $RequestPath `
    -ApprovalReceiptRef $ApprovalReceiptPath `
    -ReceiptOutputRoot $ReceiptOutputRootPath

$bridge | ConvertTo-Json -Depth 20
