[CmdletBinding()]
param(
    [string]$PromptPath = $env:ATLAS_CODEX_PROMPT_PATH,
    [string]$ProofPath = $env:ATLAS_CODEX_SPEC_TO_DIFF_PROOF_PATH,
    [string]$WorkingDirectory = (Get-Location).Path,
    [AllowEmptyCollection()]
    [string[]]$ChangedPath = $null
)

$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")

function Write-PreflightResult {
    param(
        [Parameter(Mandatory = $true)]
        $Record,
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    Write-Output ($Record | ConvertTo-Json -Depth 10)
    exit $ExitCode
}

try {
    if ([string]::IsNullOrWhiteSpace($PromptPath)) {
        throw "ATLAS_CODEX_PROMPT_PATH or -PromptPath is required."
    }

    $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
    $resolvedPromptPath = (Resolve-Path -LiteralPath $PromptPath).Path
    if ([string]::IsNullOrWhiteSpace($ProofPath)) {
        $ProofPath = ".codex/spec-to-diff-proof.json"
    }

    $resolvedProofPath = if ([System.IO.Path]::IsPathRooted($ProofPath)) {
        [System.IO.Path]::GetFullPath($ProofPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path -Path $resolvedWorkingDirectory -ChildPath $ProofPath))
    }

    $promptRecord = Parse-PromptFile -Path $resolvedPromptPath
    $policy = Get-SpecToDiffPromptPolicy -PromptRecord $promptRecord
    $artifactRecord = Read-SpecToDiffArtifact -Path $resolvedProofPath
    $changedPaths = @(Get-ChangedPaths -WorkingDirectory $resolvedWorkingDirectory)

    $workingDirectoryPrefix = $resolvedWorkingDirectory.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    $proofIsRepoRelative = $resolvedProofPath.StartsWith($workingDirectoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    $proofRelativePath = if ($proofIsRepoRelative) {
        $resolvedProofPath.Substring($workingDirectoryPrefix.Length).Replace("\", "/")
    }
    else {
        ""
    }
    if ($proofIsRepoRelative -and -not (Test-GitPathTracked -Path $proofRelativePath -WorkingDirectory $resolvedWorkingDirectory)) {
        $changedPaths = @($changedPaths | Where-Object { $_.Replace("\", "/") -ne $proofRelativePath })
    }

    $requestedPathValidation = $null
    if ($PSBoundParameters.ContainsKey("ChangedPath")) {
        $requestedPathValidation = Resolve-SpecToDiffRequestedChangedPaths -RequestedPaths $ChangedPath -ActualChangedPaths $changedPaths
        if (-not $requestedPathValidation.isValid) {
            Write-PreflightResult -Record ([ordered]@{
                schemaVersion = "1.0"
                status = "failed"
                workingDirectory = $resolvedWorkingDirectory
                promptPath = $resolvedPromptPath
                proofPath = $resolvedProofPath
                changedPaths = @($changedPaths)
                requestedChangedPaths = @($requestedPathValidation.paths)
                validation = $null
                blockingReasons = @($requestedPathValidation.blockingReasons)
            }) -ExitCode 1
        }
        $changedPaths = @($requestedPathValidation.paths)
    }

    $validation = Test-SpecToDiffCompletionProof `
        -PromptRecord $promptRecord `
        -ArtifactRecord $artifactRecord `
        -ChangedPaths $changedPaths `
        -WorkingDirectory $resolvedWorkingDirectory

    $status = if (-not $validation.enabled) {
        "skipped"
    }
    elseif ($validation.isValid) {
        "passed"
    }
    else {
        "failed"
    }

    $record = [ordered]@{
        schemaVersion = "1.0"
        status = $status
        workingDirectory = $resolvedWorkingDirectory
        promptPath = $resolvedPromptPath
        proofPath = $resolvedProofPath
        changedPaths = @($changedPaths)
        requestedChangedPaths = if ($null -ne $requestedPathValidation) { @($requestedPathValidation.paths) } else { $null }
        validation = $validation
    }

    Write-PreflightResult -Record $record -ExitCode $(if ($validation.isValid) { 0 } else { 1 })
}
catch {
    Write-PreflightResult -Record ([ordered]@{
        schemaVersion = "1.0"
        status = "setup_failed"
        workingDirectory = $WorkingDirectory
        promptPath = $PromptPath
        proofPath = $ProofPath
        changedPaths = @()
        validation = $null
        blockingReasons = @($_.Exception.Message)
    }) -ExitCode 2
}
