param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)]
    [string]$PendingQueueDropPath,
    [Parameter(Mandatory = $true)]
    [string]$StackRunnerConfigPath,
    [Parameter(Mandatory = $true)]
    [string]$DispatchInboxRootPath,
    [Parameter(Mandatory = $true)]
    [string]$DispatchLogsRootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-WorkspaceRelativeRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRootPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $resolvedWorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRootPath)
    $resolvedTargetPath = [System.IO.Path]::GetFullPath($TargetPath)
    $relativePath = [System.IO.Path]::GetRelativePath($resolvedWorkspaceRoot, $resolvedTargetPath)
    return $relativePath.Replace("\", "/")
}

function New-LaunchDispatchResult {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Ok,
        [string]$Kind = "",
        [string]$Message = "",
        [string]$StagedPromptRef = "",
        [string]$WorkerAssignmentRef = "",
        [string]$WorkerRunningStatusRef = "",
        [int]$RunnerExitCode = 0
    )

    $result = [ordered]@{
        ok = $Ok
        runner_exit_code = $RunnerExitCode
    }

    if ($Ok) {
        $result["staged_prompt_ref"] = $StagedPromptRef
        $result["worker_assignment_ref"] = $WorkerAssignmentRef
        $result["worker_running_status_ref"] = $WorkerRunningStatusRef
    }
    else {
        $result["kind"] = $Kind
        $result["message"] = $Message
    }

    return $result
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $WorkspaceRoot -ChildPath "repos\_stack")).Path
$startRunnerScriptPath = Join-Path -Path $repoRoot -ChildPath "ops\codex\Start-CodexInboxRunner.ps1"
$powershellExe = Join-Path -Path $PSHOME -ChildPath "powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe)) {
    $powershellExe = "powershell.exe"
}

$resolvedPendingQueueDropPath = [System.IO.Path]::GetFullPath($PendingQueueDropPath)
$resolvedStackRunnerConfigPath = [System.IO.Path]::GetFullPath($StackRunnerConfigPath)
$resolvedDispatchInboxRootPath = [System.IO.Path]::GetFullPath($DispatchInboxRootPath)
$resolvedDispatchLogsRootPath = [System.IO.Path]::GetFullPath($DispatchLogsRootPath)

$stagedPromptPath = Join-Path -Path $resolvedDispatchInboxRootPath -ChildPath ([System.IO.Path]::GetFileName($resolvedPendingQueueDropPath))
$runnerExitCode = 0

try {
    if (-not (Test-Path -LiteralPath $startRunnerScriptPath)) {
        throw "The shared _stack runner start surface is missing."
    }

    New-Item -ItemType Directory -Path $resolvedDispatchInboxRootPath -Force | Out-Null
    New-Item -ItemType Directory -Path $resolvedDispatchLogsRootPath -Force | Out-Null

    $existingInboxPrompts = @(
        Get-ChildItem -LiteralPath $resolvedDispatchInboxRootPath -File -Filter *.md -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "README.md" }
    )
    if ($existingInboxPrompts.Count -gt 0) {
        $result = New-LaunchDispatchResult `
            -Ok $false `
            -Kind "prompt-stage-write-failed" `
            -Message "The bounded dispatch inbox root must be empty before staging one explicit queue drop."
        $result | ConvertTo-Json -Depth 20
        exit 1
    }

    try {
        Copy-Item -LiteralPath $resolvedPendingQueueDropPath -Destination $stagedPromptPath -ErrorAction Stop
    }
    catch {
        $result = New-LaunchDispatchResult `
            -Ok $false `
            -Kind "prompt-stage-write-failed" `
            -Message "The bounded dispatch inbox writer could not stage the explicit queue drop."
        $result | ConvertTo-Json -Depth 20
        exit 1
    }

    $beforeLogDirectories = @(
        Get-ChildItem -LiteralPath $resolvedDispatchLogsRootPath -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.Path]::GetFullPath($_.FullName) }
    )

    $runnerArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $startRunnerScriptPath,
        "-ConfigPath", $resolvedStackRunnerConfigPath,
        "-InboxDir", $resolvedDispatchInboxRootPath,
        "-SettleSeconds", "0",
        "-RunOnce"
    )
    if (-not [string]::IsNullOrWhiteSpace($env:STACK_QUEUE_OR_REGISTRY_LAUNCH_OR_DISPATCH_CODEX_COMMAND)) {
        $runnerArguments += @("-CodexCommand", $env:STACK_QUEUE_OR_REGISTRY_LAUNCH_OR_DISPATCH_CODEX_COMMAND)
    }

    & $powershellExe @runnerArguments
    $runnerExitCode = $LASTEXITCODE

    $afterLogDirectories = @(
        Get-ChildItem -LiteralPath $resolvedDispatchLogsRootPath -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.Path]::GetFullPath($_.FullName) }
    )
    $newLogDirectories = @(
        $afterLogDirectories |
        Where-Object { $_ -notin $beforeLogDirectories } |
        Sort-Object
    )

    if ($newLogDirectories.Count -eq 0) {
        $result = New-LaunchDispatchResult `
            -Ok $false `
            -Kind "launch-start-failed" `
            -Message "The shared _stack runner did not emit a new bounded log directory for the staged queue drop." `
            -RunnerExitCode $runnerExitCode
        $result | ConvertTo-Json -Depth 20
        exit 1
    }

    if ($newLogDirectories.Count -ne 1) {
        $result = New-LaunchDispatchResult `
            -Ok $false `
            -Kind "worker-start-artifacts-missing" `
            -Message "The shared _stack runner emitted an ambiguous worker-start log surface instead of one exact log directory." `
            -RunnerExitCode $runnerExitCode
        $result | ConvertTo-Json -Depth 20
        exit 1
    }

    $newLogDirectory = $newLogDirectories[0]
    $workerAssignmentPath = Join-Path -Path $newLogDirectory -ChildPath "worker.assignment.json"
    $workerRunningStatusPath = Join-Path -Path $newLogDirectory -ChildPath "worker.status.running.json"

    if (-not (Test-Path -LiteralPath $workerAssignmentPath -PathType Leaf) -or -not (Test-Path -LiteralPath $workerRunningStatusPath -PathType Leaf)) {
        $result = New-LaunchDispatchResult `
            -Ok $false `
            -Kind "worker-start-artifacts-missing" `
            -Message "The shared _stack runner did not emit one exact worker assignment and running-status pair." `
            -RunnerExitCode $runnerExitCode
        $result | ConvertTo-Json -Depth 20
        exit 1
    }

    $result = New-LaunchDispatchResult `
        -Ok $true `
        -StagedPromptRef (Get-WorkspaceRelativeRef -WorkspaceRootPath $WorkspaceRoot -TargetPath $stagedPromptPath) `
        -WorkerAssignmentRef (Get-WorkspaceRelativeRef -WorkspaceRootPath $WorkspaceRoot -TargetPath $workerAssignmentPath) `
        -WorkerRunningStatusRef (Get-WorkspaceRelativeRef -WorkspaceRootPath $WorkspaceRoot -TargetPath $workerRunningStatusPath) `
        -RunnerExitCode $runnerExitCode
    $result | ConvertTo-Json -Depth 20
    exit 0
}
catch {
    $result = New-LaunchDispatchResult `
        -Ok $false `
        -Kind "launch-start-failed" `
        -Message $_.Exception.Message `
        -RunnerExitCode $runnerExitCode
    $result | ConvertTo-Json -Depth 20
    exit 1
}
finally {
    if (Test-Path -LiteralPath $stagedPromptPath -PathType Leaf) {
        Remove-Item -LiteralPath $stagedPromptPath -Force -ErrorAction SilentlyContinue
    }
}
