param(
    [Parameter(Mandatory = $true)]
    [string]$PromptPath,
    [string]$ConfigPath = "",
    [string]$RepoRoot = "",
    [string]$AdapterPath = "",
    [string]$CodexCommand = "",
    [string]$Model = "",
    [string]$Reasoning = "",
    [string]$Speed = "",
    [string]$Permissions = "",
    [string]$PermissionProfile = "",
    [string]$SandboxMode = "",
    [string]$ApprovalPolicy = "",
    [string]$WebSearch = "",
    [switch]$KeepWorktree,
    [switch]$SkipVerification,
    [switch]$NoCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "..\stack\StackWorkerArtifacts.ps1")

$status = "setup_failed"
$archivePath = $null
$manifestPath = $null
$logDirectory = $null
$runId = $null
$branchName = $null
$worktreePath = $null
$commitSha = $null
$exportErrors = @()
$verifyRecords = @()
$proofGateRecord = $null
$proofGateFailureReason = $null
$promptRecord = $null
$config = @{}
$baseRef = "origin/main"
$configuredBaseRef = "origin/main"
$baseRefCandidates = @()
$baseRefUsedFallback = $false
$codexStdOutPath = $null
$codexStdErrPath = $null
$summaryPath = $null
$archiveDirectory = $null
$effectiveVerifyCommands = @()
$verificationSource = "prompt"
$effectiveSandboxMode = $null
$runtimePolicy = $null
$codexCommandRecord = $null
$stackLockContext = $null
$workerAssignmentPath = $null
$workerRunningStatusPath = $null
$workerCompletedStatusPath = $null
$workerMergeRequestPath = $null
$workerAssignmentRecord = $null
$workerRunningStatusRecord = $null
$workerCompletedStatusRecord = $null
$workerMergeRequestRecord = $null
$workerContextRecord = $null
$workerContextPath = $null
$workerContextRef = $null
$governedFlowContext = $null
$governedSessionId = $null
$supervisorReportRecord = $null
$supervisorReportPath = $null
$supervisorConsumerRecord = $null
$supervisorConsumerPath = $null
$changedPaths = @()
$mutationScopeViolations = @()
$verifyBootstrapRecords = @()
$proofGateConfig = $null
$adapterContract = $null
$adapterContractPath = $null
$autoCommitEnabled = $true
$pushPolicy = $null
$autoCommitPolicy = $null
$localLandingPolicy = $null
$exportsDirectory = $null
$repoRoot = $null
$resolvedConfig = $null
$commitMetadataPolicy = $null
$commitMetadataArtifactPath = $null
$commitMetadataArtifactRecord = $null
$commitMetadataArtifactTracked = $false
$commitMetadataArtifactRemoved = $false
$specToDiffPolicy = $null
$specToDiffArtifactPath = $null
$specToDiffArtifactRecord = $null
$specToDiffArtifactTracked = $false
$specToDiffArtifactRemoved = $false
$specToDiffRecord = $null
$specToDiffFailureReason = $null
$commitMetadataRawPath = $null
$commitMetadataResolvedPath = $null
$commitMessagePath = $null
$specToDiffRawPath = $null
$specToDiffValidationPath = $null
$resolvedCommit = $null
$commitMessage = $null
$localLandingMode = "disabled"
$localLandingTargetBranch = "main"
$landedToMain = $false
$landingFailureReason = "disabled_by_policy"
$worktreeNameMaxLength = $null
$worktreeDirectoryName = $null
$configuredFormatPatchBaseRef = $null
$resolvedFormatPatchBaseRef = $null
$formatPatchBaseRefCandidates = @()
$formatPatchBaseRefUsedFallback = $false
$exportPatch = $false
$exportBundle = $false

try {
    $PromptPath = (Resolve-Path -LiteralPath $PromptPath).Path
    $resolvedConfig = Import-StackCodexConfiguration -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath -RepoRoot $RepoRoot -AdapterPath $AdapterPath
    $config = $resolvedConfig.Config
    $repoRoot = $resolvedConfig.RepoRoot
    $stackLockContext = Get-StackLockContext -RepoRoot $repoRoot
    $adapterContractPath = $resolvedConfig.AdapterPath
    $adapterContract = Read-JsonFile -Path $adapterContractPath

    if ($null -eq $adapterContract) {
        throw ("Adapter contract is empty or unreadable: {0}" -f $adapterContractPath)
    }

    $configuredBaseRef = [string]$adapterContract.execution.baseRef
    if ([string]::IsNullOrWhiteSpace($configuredBaseRef)) {
        $configuredBaseRef = "origin/main"
    }
    $baseRef = $configuredBaseRef

    $branchPrefix = [string]$adapterContract.execution.branchPrefix
    if ([string]::IsNullOrWhiteSpace($branchPrefix)) {
        $branchPrefix = "codex/"
    }
    $worktreeNameMaxLength = Get-ValidatedWorktreeNameMaxLength -Execution $adapterContract.execution

    $fetchOrigin = ConvertTo-RunnerBoolean -Value $adapterContract.execution.fetchOrigin -DefaultValue $false
    $cleanupWorktreeOnSuccess = -not $KeepWorktree.IsPresent -and (ConvertTo-RunnerBoolean -Value $adapterContract.execution.cleanupWorktreeOnSuccess -DefaultValue $false)

    $autoCommitPolicy = if ($null -ne $adapterContract.autoCommitPolicy) { $adapterContract.autoCommitPolicy } else { [pscustomobject]@{} }
    $pushPolicy = if ($null -ne $adapterContract.pushPolicy) { $adapterContract.pushPolicy } else { [pscustomobject]@{} }
    $localLandingPolicy = if ($null -ne $adapterContract.localLandingPolicy) { $adapterContract.localLandingPolicy } else { [pscustomobject]@{} }
    $autoCommitEnabled = -not $NoCommit.IsPresent -and (ConvertTo-RunnerBoolean -Value $autoCommitPolicy.enabled -DefaultValue $true)
    $resolvedLandingPolicy = Get-LocalLandingPolicy -Policy $localLandingPolicy
    $localLandingMode = [string]$resolvedLandingPolicy.mode
    $localLandingTargetBranch = [string]$resolvedLandingPolicy.targetBranch
    if ($localLandingMode -eq "disabled") {
        $landingFailureReason = "disabled_by_policy"
    }
    elseif (-not $autoCommitEnabled) {
        $landingFailureReason = "auto_commit_disabled"
    }
    else {
        $landingFailureReason = "commit_not_created"
    }
    $commitMetadataPolicy = Get-CommitMetadataPolicy -AutoCommitPolicy $autoCommitPolicy -RepoId ([string]$adapterContract.repoId)
    if ([System.IO.Path]::IsPathRooted([string]$commitMetadataPolicy.artifactPath)) {
        throw "autoCommitPolicy.commitMetadata.artifactPath must be repo-relative."
    }

    $inboxDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.inboxDir)
    $archiveDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.archiveDir)
    $logsDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.logsDir)
    $worktreeRoot = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.worktreeRoot)
    $exportsDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.exportsDir)

    foreach ($directory in @($inboxDirectory, $archiveDirectory, $logsDirectory, $worktreeRoot, $exportsDirectory)) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            throw "Adapter contract is missing one or more artifact paths."
        }

        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    $promptRecord = Parse-PromptFile -Path $PromptPath
    $specToDiffPolicy = Get-SpecToDiffPromptPolicy -PromptRecord $promptRecord
    $effectiveVerifyCommands = @($promptRecord.Verify)
    $adapterVerifyConfig = if ($null -ne $adapterContract) { Get-ObjectPropertyValue -Object $adapterContract -Name "verify" -DefaultValue $null } else { $null }
    if ($effectiveVerifyCommands.Count -eq 0 -and $null -ne $adapterVerifyConfig) {
        $effectiveVerifyCommands = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $adapterVerifyConfig -Name "defaultCommands" -DefaultValue @()))
        if ($effectiveVerifyCommands.Count -gt 0) {
            $verificationSource = "adapter-default"
        }
    }
    $proofGateCandidate = if ($null -ne $adapterVerifyConfig) { Get-ObjectPropertyValue -Object $adapterVerifyConfig -Name "proofGate" -DefaultValue $null } else { $null }
    if ($null -ne $proofGateCandidate) {
        $proofGateConfig = $proofGateCandidate
    }

    $slugSeed = $promptRecord.BranchSlug
    if ([string]::IsNullOrWhiteSpace($slugSeed)) {
        $slugSeed = $promptRecord.Title
    }
    if ([string]::IsNullOrWhiteSpace($slugSeed)) {
        $slugSeed = [System.IO.Path]::GetFileNameWithoutExtension($PromptPath)
    }

    $rootSlug = ConvertTo-Slug -Value $slugSeed
    $taskName = Get-UniqueTaskName -RootSlug $rootSlug -BranchPrefix $branchPrefix -WorktreeRoot $worktreeRoot -WorktreeNameMaxLength $worktreeNameMaxLength -WorkingDirectory $repoRoot
    $branchName = $taskName.BranchName
    $worktreeDirectoryName = $taskName.WorktreeDirectoryName
    $worktreePath = $taskName.WorktreePath
    $runId = "{0}-{1}" -f ((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")), $taskName.Slug
    $logDirectory = Join-Path -Path $logsDirectory -ChildPath $runId
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $manifestPath = Join-Path -Path $logDirectory -ChildPath "run.json"

    Write-RunnerMessage -Message ("Preparing task {0} from {1}" -f $taskName.Slug, $PromptPath)
    Copy-Item -LiteralPath $PromptPath -Destination (Join-Path -Path $logDirectory -ChildPath "input.prompt.md")

    if ([string]::IsNullOrWhiteSpace($promptRecord.Body)) {
        throw "Prompt body is empty."
    }

    $codexCommandRecord = Resolve-CodexCommand -ExplicitCodexCommand $CodexCommand -Config $config -BasePath $repoRoot
    if (-not [bool](Get-ObjectPropertyValue -Object $codexCommandRecord -Name "isNativeExecutable" -DefaultValue $false)) { $status = "codex_command_resolution_failed"; throw (Get-CodexCommandResolutionFailureMessage -ResolutionRecord $codexCommandRecord) }
    $codexCommandValue = [string](Get-ObjectPropertyValue -Object $codexCommandRecord -Name "resolvedNativePath" -DefaultValue "")

    if ($fetchOrigin) {
        Write-RunnerMessage -Message ("Fetching {0} before worktree creation" -f $configuredBaseRef)
        $fetchArguments = @("fetch", "--quiet")
        if ($configuredBaseRef -match '^origin/(?<branch>.+)$') {
            $fetchArguments += @("origin", $Matches.branch)
        }
        else {
            $fetchArguments += @("origin")
        }

        $fetchResult = Invoke-Git -Arguments $fetchArguments -WorkingDirectory $repoRoot
        Assert-CommandSucceeded -Result $fetchResult -Description ("git {0}" -f ($fetchArguments -join " "))
    }

    $baseRefResolution = Resolve-GitRef -PreferredRef $configuredBaseRef -WorkingDirectory $repoRoot
    $baseRefCandidates = @($baseRefResolution.candidates)
    $baseRefUsedFallback = [bool]$baseRefResolution.usedFallback
    $baseRef = [string]$baseRefResolution.resolvedRef
    if ([string]::IsNullOrWhiteSpace($baseRef)) {
        throw ("Base ref does not exist locally. Tried: {0}" -f ($baseRefCandidates -join ", "))
    }

    if ($baseRefUsedFallback) {
        Write-RunnerMessage -Message ("Configured base ref {0} unavailable locally; using fallback {1}" -f $configuredBaseRef, $baseRef) -Level "WARN"
    }
    else {
        Write-RunnerMessage -Message ("Resolved base ref to {0}" -f $baseRef)
    }

    Write-RunnerMessage -Message ("Creating worktree {0} on branch {1} from {2}" -f $worktreePath, $branchName, $baseRef)
    $worktreeResult = Invoke-Git -Arguments @("worktree", "add", "-b", $branchName, $worktreePath, $baseRef) -WorkingDirectory $repoRoot
    Assert-CommandSucceeded -Result $worktreeResult -Description "git worktree add"
    $commitMetadataArtifactPath = Resolve-PathFromBase -BasePath $worktreePath -Value ([string]$commitMetadataPolicy.artifactPath)
    if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        $specToDiffArtifactPath = Resolve-PathFromBase -BasePath $worktreePath -Value ([string]$specToDiffPolicy.artifactPath)
    }

    $summaryPath = Join-Path -Path $logDirectory -ChildPath "final-summary.md"
    $codexStdOutPath = Join-Path -Path $logDirectory -ChildPath "codex.stdout.log"
    $codexStdErrPath = Join-Path -Path $logDirectory -ChildPath "codex.stderr.log"
    $workerAssignmentPath = Join-Path -Path $logDirectory -ChildPath "worker.assignment.json"
    $workerRunningStatusPath = Join-Path -Path $logDirectory -ChildPath "worker.status.running.json"
    $workerCompletedStatusPath = Join-Path -Path $logDirectory -ChildPath "worker.status.completed.json"
    $workerMergeRequestPath = Join-Path -Path $logDirectory -ChildPath "worker.merge-request.json"
    $workerAssignmentId = "assignment-{0}" -f $runId
    $workerId = "worker-{0}" -f $runId
    $contextQueryTerms = @()
    if ($null -ne $promptRecord -and $promptRecord.PSObject.Properties.Name -contains "QueryTerms") {
        $contextQueryTerms = @($promptRecord.QueryTerms)
    }
    if ($contextQueryTerms.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($promptRecord.Title)) {
        $contextQueryTerms = @($promptRecord.Title)
    }
    if ($contextQueryTerms.Count -eq 0) {
        $contextQueryTerms = @($taskName.Slug.Replace("-", " "))
    }

    $contextTaskTags = @()
    if ($null -ne $promptRecord -and $promptRecord.PSObject.Properties.Name -contains "TaskTags") {
        $contextTaskTags = @($promptRecord.TaskTags)
    }
    $contextTaskTags += @("worker", [string]$adapterContract.repoId)
    $contextTaskTags = @(
        $contextTaskTags |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [string]$_ } |
        Select-Object -Unique
    )

    $workerContextRecord = Invoke-StackWorkerContextBuild `
        -RepoRoot $repoRoot `
        -AssignmentId $workerAssignmentId `
        -WorkerId $workerId `
        -TaskId $taskName.Slug `
        -StackLockDigest $stackLockContext.stackLockDigest `
        -QueryTerms $contextQueryTerms `
        -TaskTags $contextTaskTags
    $workerContextPath = $workerContextRecord.outputPath
    $workerContextRef = $workerContextRecord.relativePath

    $effectivePrompt = $promptRecord.Body.Trim()
    if (-not [string]::IsNullOrWhiteSpace($promptRecord.DocsUpdateNote)) {
        $effectivePrompt = $effectivePrompt + "`r`n`r`nDocs update note: " + $promptRecord.DocsUpdateNote.Trim()
    }
    $commitContractInstructions = @(
        "Commit metadata contract:",
        ("- If you make repository changes that should be committed, write UTF-8 JSON to `{0}`." -f $commitMetadataPolicy.artifactPath),
        ('- Use exactly this shape: {"type":"<type>","scope":"<scope>","summary":"<summary>"}'),
        ("- Allowed commit types: {0}." -f (($commitMetadataPolicy.allowedTypes -join ", "))),
        "- Scope must be a short lowercase slug using letters, digits, and hyphens.",
        "- Summary must be specific, contain at least two words, and must not be generic like update, done, fixes, or misc changes.",
        "- If you make no repository changes, do not create the commit metadata artifact.",
        "- The runner will consume and remove the artifact before staging.",
        "- Do not push. Push remains manual-only."
    ) -join "`r`n"
    $workerContextInstructions = @(
        "Worker context contract:",
        ("- Deterministic worker context artifact: `{0}`." -f $workerContextRef),
        "- Use the worker context artifact, paused handoff refs, and merge request refs as the governed context surfaces.",
        "- Do not rely on raw hidden transcript history or ad hoc pasted summaries."
    ) -join "`r`n"
    $effectivePrompt = $effectivePrompt + "`r`n`r`n" + $workerContextInstructions + "`r`n`r`n" + $commitContractInstructions
    if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        $criterionLines = @(
            $specToDiffPolicy.acceptanceCriteria |
            ForEach-Object { "- {0}: {1}" -f [string]$_.id, [string]$_.text }
        )
        $expectedChangedLines = if (@($specToDiffPolicy.expectedChangedPaths).Length -gt 0) {
            @($specToDiffPolicy.expectedChangedPaths | ForEach-Object { "- {0}" -f [string]$_ })
        }
        else {
            @("- none declared")
        }
        $expectedUnchangedLines = if (@($specToDiffPolicy.expectedUnchangedPaths).Length -gt 0) {
            @($specToDiffPolicy.expectedUnchangedPaths | ForEach-Object { "- {0}" -f [string]$_ })
        }
        else {
            @("- none declared")
        }
        $blockedSkippedRuleLines = if (@($specToDiffPolicy.blockedSkippedRules).Length -gt 0) {
            @($specToDiffPolicy.blockedSkippedRules | ForEach-Object { "- {0}" -f [string]$_ })
        }
        else {
            @("- If a criterion cannot be proven from the final diff, mark it as blocked, skipped, or failed instead of satisfied.")
        }
        $specToDiffInstructions = @(
            "Spec-to-diff completion contract:",
            ("- This prompt declares acceptance criteria, so write UTF-8 JSON to `{0}`." -f $specToDiffPolicy.artifactPath),
            "- Use exactly this shape:",
            '- {"contract_version":"atlas.stack.spec_to_diff.v1","criteria":[{"criterion_id":"ac-01","status":"satisfied","changed_paths":["docs/example.md"],"diff_evidence":["literal diff snippet"],"note":"optional note"}],"unchanged_path_justifications":[{"path":"docs/example.md","justification":"why the expected unchanged path changed","criterion_ids":["ac-01"]}]}',
            "- Emit one criteria entry for every acceptance criterion id listed below.",
            "- Allowed criterion statuses: satisfied, skipped, failed, blocked.",
            "- For satisfied criteria, changed_paths must list the actual changed repo-relative files and diff_evidence must quote short literal snippets that appear in the final diff or newly added file content.",
            "- Do not mark a criterion satisfied unless it is provable from the final diff.",
            "- If any criterion cannot be completed or proven, mark it blocked, skipped, or failed and explain why in note.",
            "- If an expected unchanged path changes, add an unchanged_path_justifications entry with an explicit reason.",
            "Acceptance criteria ids:",
            $criterionLines -join "`r`n",
            "Expected changed paths:",
            $expectedChangedLines -join "`r`n",
            "Expected unchanged paths:",
            $expectedUnchangedLines -join "`r`n",
            "Blocked / skipped reporting rules:",
            $blockedSkippedRuleLines -join "`r`n"
        ) -join "`r`n"
        $effectivePrompt = $effectivePrompt + "`r`n`r`n" + $specToDiffInstructions
    }
    Write-TextFile -Path (Join-Path -Path $logDirectory -ChildPath "effective.prompt.md") -Content $effectivePrompt

    $inputHandoffRefs = @()
    if ($null -ne $promptRecord -and $promptRecord.PSObject.Properties.Name -contains "HandoffRefs") {
        $inputHandoffRefs = @($promptRecord.HandoffRefs | ForEach-Object { Normalize-StackHandoffRef -RepoRoot $repoRoot -Reference ([string]$_) })
    }
    if ($inputHandoffRefs.Count -eq 0 -and $null -ne $promptRecord -and $promptRecord.PSObject.Properties.Name -contains "PausedHandoffRefs") {
        $inputHandoffRefs = @($promptRecord.PausedHandoffRefs | ForEach-Object { Normalize-StackHandoffRef -RepoRoot $repoRoot -Reference ([string]$_) })
    }
    if ($inputHandoffRefs.Count -eq 0) {
        $inputHandoffRefs = @((Normalize-StackHandoffRef -RepoRoot $repoRoot -Reference $PromptPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($workerContextRef)) {
        $inputHandoffRefs += $workerContextRef
    }
    $inputHandoffRefs = @($inputHandoffRefs | Select-Object -Unique)
    $governedContextRefs = New-Object System.Collections.Generic.List[string]
    foreach ($reference in $inputHandoffRefs) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reference)) {
            [void]$governedContextRefs.Add([string]$reference)
        }
    }
    if ($null -ne $promptRecord -and $promptRecord.PSObject.Properties.Name -contains "MergeRequestRefs") {
        foreach ($reference in @($promptRecord.MergeRequestRefs)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$reference)) {
                [void]$governedContextRefs.Add((Normalize-StackHandoffRef -RepoRoot $repoRoot -Reference ([string]$reference)))
            }
        }
    }
    $governedFlowContext = Resolve-AtlasGovernedFlowContext -RepoRoot $repoRoot -References @($governedContextRefs.ToArray())
    $governedSessionId = if ($null -ne $governedFlowContext) { [string]$governedFlowContext.session_id } else { $runId }
    $governedToolId = if ($null -ne $governedFlowContext) { [string]$governedFlowContext.tool_id } else { "" }
    $governedExtensionId = if ($null -ne $governedFlowContext) { [string]$governedFlowContext.extension_id } else { $null }
    $governedRegistryDigest = if ($null -ne $governedFlowContext) { [string]$governedFlowContext.registry_digest } else { "" }
    $governedSourceRefs = if ($null -ne $governedFlowContext) { @($governedFlowContext.source_artifact_refs) } else { @() }

    $allowedGlobs = @($adapterContract.allowedMutationSurfaces)
    $forbiddenGlobs = @(
        "secrets/**",
        "runtime/**",
        "repos/Verta-Core/**"
    )
    $expectedOutputs = @(
        "logs/run.json",
        "logs/effective.prompt.md",
        "logs/final-summary.md",
        "logs/worker.status.completed.json"
    )

    $workerAssignmentRecord = New-StackWorkerAssignment `
        -AssignmentId $workerAssignmentId `
        -WorkerId $workerId `
        -TaskId $taskName.Slug `
        -StackLockDigest $stackLockContext.stackLockDigest `
        -AllowedGlobs $allowedGlobs `
        -ForbiddenGlobs $forbiddenGlobs `
        -InputHandoffRefs $inputHandoffRefs `
        -ExpectedOutputs $expectedOutputs `
        -ToolId $governedToolId `
        -ExtensionId $governedExtensionId `
        -RegistryDigest $governedRegistryDigest `
        -Notes ("Stack worker assignment stamped from {0}." -f $stackLockContext.stackLockPath)
    [void](Write-StackWorkerArtifact -Artifact $workerAssignmentRecord -Path $workerAssignmentPath)
    $workerAssignmentRef = Get-StackRelativePath -RepoRoot $repoRoot -Path $workerAssignmentPath
    $workerAssignmentToolId = [string](Get-ObjectPropertyValue -Object $workerAssignmentRecord -Name "tool_id" -DefaultValue "")
    $workerAssignmentExtensionId = Get-ObjectPropertyValue -Object $workerAssignmentRecord -Name "extension_id" -DefaultValue $null
    $workerAssignmentRegistryDigest = [string](Get-ObjectPropertyValue -Object $workerAssignmentRecord -Name "registry_digest" -DefaultValue "")
    if (
        -not [string]::IsNullOrWhiteSpace($workerAssignmentToolId) -and
        -not [string]::IsNullOrWhiteSpace($workerAssignmentRegistryDigest)
    ) {
        $assignmentObservationRefs = @($governedSourceRefs + @($workerAssignmentRef) | Select-Object -Unique)
        [void](Publish-AtlasObservation `
            -RepoRoot $repoRoot `
            -Owner "_stack" `
            -ObservationType "assignment_created" `
            -SourceKind "worker_assignment" `
            -Status "emitted" `
            -SourceRef $workerAssignmentRef `
            -ObservedAt ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
            -ScopeRef $governedSessionId `
            -Details (New-AtlasGovernedObservationDetails `
                -SessionId $governedSessionId `
                -WorkerId ([string]$workerAssignmentRecord.worker_id) `
                -AssignmentId ([string]$workerAssignmentRecord.assignment_id) `
                -StackLockDigest ([string]$workerAssignmentRecord.stack_lock_digest) `
                -ToolId $workerAssignmentToolId `
                -ExtensionId $workerAssignmentExtensionId `
                -RegistryDigest $workerAssignmentRegistryDigest `
                -SourceArtifactRefs $assignmentObservationRefs))
    }

    $workerRunningStatusRecord = New-StackWorkerStatus `
        -WorkerId $workerAssignmentRecord.worker_id `
        -AssignmentId $workerAssignmentRecord.assignment_id `
        -State "running" `
        -HeartbeatAt ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
        -TouchedRanges @() `
        -OutputRefs @() `
        -BlockedReason $null `
        -MergeRequestRef $null `
        -ToolId $workerAssignmentToolId `
        -ExtensionId $workerAssignmentExtensionId `
        -RegistryDigest $workerAssignmentRegistryDigest
    [void](Write-StackWorkerArtifact -Artifact $workerRunningStatusRecord -Path $workerRunningStatusPath)
    $workerRunningStatusRef = Get-StackRelativePath -RepoRoot $repoRoot -Path $workerRunningStatusPath
    $workerRunningStatusToolId = [string](Get-ObjectPropertyValue -Object $workerRunningStatusRecord -Name "tool_id" -DefaultValue "")
    $workerRunningStatusExtensionId = Get-ObjectPropertyValue -Object $workerRunningStatusRecord -Name "extension_id" -DefaultValue $null
    $workerRunningStatusRegistryDigest = [string](Get-ObjectPropertyValue -Object $workerRunningStatusRecord -Name "registry_digest" -DefaultValue "")
    if (
        -not [string]::IsNullOrWhiteSpace($workerRunningStatusToolId) -and
        -not [string]::IsNullOrWhiteSpace($workerRunningStatusRegistryDigest)
    ) {
        $runningObservationRefs = @($governedSourceRefs + @($workerAssignmentRef, $workerRunningStatusRef) | Select-Object -Unique)
        [void](Publish-AtlasObservation `
            -RepoRoot $repoRoot `
            -Owner "_stack" `
            -ObservationType "heartbeat" `
            -SourceKind "worker_status" `
            -Status "running" `
            -SourceRef $workerRunningStatusRef `
            -ObservedAt ([string]$workerRunningStatusRecord.heartbeat_at) `
            -ScopeRef $governedSessionId `
            -Details (New-AtlasGovernedObservationDetails `
                -SessionId $governedSessionId `
                -WorkerId ([string]$workerRunningStatusRecord.worker_id) `
                -AssignmentId ([string]$workerRunningStatusRecord.assignment_id) `
                -StackLockDigest ([string]$workerAssignmentRecord.stack_lock_digest) `
                -ToolId $workerRunningStatusToolId `
                -ExtensionId $workerRunningStatusExtensionId `
                -RegistryDigest $workerRunningStatusRegistryDigest `
                -SourceArtifactRefs $runningObservationRefs))
    }

    $runtimePolicy = Resolve-StackRuntimePolicy `
        -Config $config `
        -RepoConfig $resolvedConfig.RepoConfig `
        -DefaultsConfig $resolvedConfig.DefaultsConfig `
        -PromptRecord $promptRecord `
        -ExplicitPolicy ([pscustomobject]@{
            model = $Model
            reasoning = $Reasoning
            speed = $Speed
            permissions = $Permissions
            permission_profile = $PermissionProfile
            sandbox_mode = $SandboxMode
            approval = $ApprovalPolicy
            web_search = $WebSearch
        }) `
        -CodexCommand $codexCommandValue `
        -ProbeTargetPath $repoRoot
    $null = Set-CodexCommandVersion -ResolutionRecord $codexCommandRecord -CodexVersion ([string]$runtimePolicy.codex_version)
    if (@($runtimePolicy.blockers).Count -gt 0) { $status = "runtime_policy_blocked"; throw (@($runtimePolicy.blockers) -join "; ") }
    foreach ($runtimeNote in @($runtimePolicy.warnings)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$runtimeNote)) {
            Write-RunnerMessage -Message ([string]$runtimeNote) -Level "WARN"
        }
    }

    $personality = [string](Get-ConfigValue -Config $config -Path @("personality") -DefaultValue "")
    $codexInvocation = New-CodexInvocationPlan `
        -RuntimePolicy $runtimePolicy `
        -SummaryPath $summaryPath `
        -WorktreePath $worktreePath `
        -Personality $personality
    $effectiveSandboxMode = $codexInvocation.legacySandboxMode

    Write-RunnerMessage -Message "Running Codex in non-interactive mode"
    $codexResult = Invoke-ProcessCapture -FilePath $codexCommandValue -ArgumentList @($codexInvocation.arguments) -WorkingDirectory $codexInvocation.workingDirectory -StandardInputText $effectivePrompt
    Write-TextFile -Path $codexStdOutPath -Content $codexResult.StdOut
    Write-TextFile -Path $codexStdErrPath -Content $codexResult.StdErr

    if ($codexResult.ExitCode -ne 0) {
        $status = "codex_failed"
        throw ("Codex exec failed with exit code {0}." -f $codexResult.ExitCode)
    }

    $commitMetadataArtifactRecord = Read-CommitMetadataArtifact -Path $commitMetadataArtifactPath
    if ($null -ne $commitMetadataArtifactRecord) {
        $commitMetadataRawPath = Join-Path -Path $logDirectory -ChildPath "commit-meta.raw.json"
        Write-TextFile -Path $commitMetadataRawPath -Content $commitMetadataArtifactRecord.rawContent

        $commitMetadataArtifactTracked = Test-GitPathTracked -Path ([string]$commitMetadataPolicy.artifactPath) -WorkingDirectory $worktreePath
        if (-not $commitMetadataArtifactTracked) {
            Remove-Item -LiteralPath $commitMetadataArtifactPath -Force
            $commitMetadataArtifactRemoved = $true
        }
        else {
            Write-RunnerMessage -Message ("Commit metadata artifact path is tracked and could not be treated as temporary: {0}" -f $commitMetadataPolicy.artifactPath) -Level "WARN"
        }
    }
    if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        $specToDiffArtifactRecord = Read-SpecToDiffArtifact -Path $specToDiffArtifactPath
        if ($null -ne $specToDiffArtifactRecord) {
            $specToDiffRawPath = Join-Path -Path $logDirectory -ChildPath "spec-to-diff.raw.json"
            Write-TextFile -Path $specToDiffRawPath -Content $specToDiffArtifactRecord.rawContent

            $specToDiffArtifactTracked = Test-GitPathTracked -Path ([string]$specToDiffPolicy.artifactPath) -WorkingDirectory $worktreePath
            if (-not $specToDiffArtifactTracked) {
                Remove-Item -LiteralPath $specToDiffArtifactPath -Force
                $specToDiffArtifactRemoved = $true
            }
        }
    }

    $verificationDirectory = Join-Path -Path $logDirectory -ChildPath "verification"
    New-Item -ItemType Directory -Path $verificationDirectory -Force | Out-Null
    if (-not $SkipVerification.IsPresent) {
        $bootstrapIndex = 0
        if ($null -ne $adapterVerifyConfig) {
            foreach ($bootstrapCommand in (ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $adapterVerifyConfig -Name "bootstrapCommands" -DefaultValue @()))) {
                $bootstrapIndex += 1
                Write-RunnerMessage -Message ("Running verification bootstrap {0}: {1}" -f $bootstrapIndex, $bootstrapCommand)
                $bootstrapResult = Invoke-ShellCommand -Command $bootstrapCommand -WorkingDirectory $worktreePath
                $bootstrapStdOutPath = Join-Path -Path $verificationDirectory -ChildPath ("bootstrap-{0:00}.stdout.log" -f $bootstrapIndex)
                $bootstrapStdErrPath = Join-Path -Path $verificationDirectory -ChildPath ("bootstrap-{0:00}.stderr.log" -f $bootstrapIndex)
                Write-TextFile -Path $bootstrapStdOutPath -Content $bootstrapResult.StdOut
                Write-TextFile -Path $bootstrapStdErrPath -Content $bootstrapResult.StdErr

                $bootstrapRecord = [ordered]@{
                    command = $bootstrapCommand
                    exitCode = $bootstrapResult.ExitCode
                    stdoutPath = $bootstrapStdOutPath
                    stderrPath = $bootstrapStdErrPath
                }
                $verifyBootstrapRecords += [pscustomobject]$bootstrapRecord

                if ($bootstrapResult.ExitCode -ne 0) {
                    $status = "verification_failed"
                    throw ("Verification bootstrap failed: {0}" -f $bootstrapCommand)
                }
            }
        }

        $verifyIndex = 0
        foreach ($verificationCommand in $effectiveVerifyCommands) {
            $verifyIndex += 1
            Write-RunnerMessage -Message ("Running verification command {0}: {1}" -f $verifyIndex, $verificationCommand)
            $verificationResult = Invoke-ShellCommand -Command $verificationCommand -WorkingDirectory $worktreePath
            $verifyStdOutPath = Join-Path -Path $verificationDirectory -ChildPath ("verify-{0:00}.stdout.log" -f $verifyIndex)
            $verifyStdErrPath = Join-Path -Path $verificationDirectory -ChildPath ("verify-{0:00}.stderr.log" -f $verifyIndex)
            Write-TextFile -Path $verifyStdOutPath -Content $verificationResult.StdOut
            Write-TextFile -Path $verifyStdErrPath -Content $verificationResult.StdErr

            $record = [ordered]@{
                command = $verificationCommand
                exitCode = $verificationResult.ExitCode
                stdoutPath = $verifyStdOutPath
                stderrPath = $verifyStdErrPath
            }
            $verifyRecords += [pscustomobject]$record

            if ($verificationResult.ExitCode -ne 0) {
                $status = "verification_failed"
                throw ("Verification command failed: {0}" -f $verificationCommand)
            }
        }

        if ($null -ne $proofGateConfig) {
            $proofGateCommand = [string]$proofGateConfig.command
            if ([string]::IsNullOrWhiteSpace($proofGateCommand)) {
                $status = "proof_gate_failed"
                throw "Proof gate is configured without a command."
            }

            $proofGateStatusArtifactPath = Resolve-PathFromBase -BasePath $worktreePath -Value ([string]$proofGateConfig.statusArtifactPath)
            if ([string]::IsNullOrWhiteSpace($proofGateStatusArtifactPath)) {
                $status = "proof_gate_failed"
                throw "Proof gate is configured without a status artifact path."
            }

            Write-RunnerMessage -Message ("Running proof gate: {0}" -f $proofGateCommand)
            $proofGateResult = Invoke-ShellCommand -Command $proofGateCommand -WorkingDirectory $worktreePath
            $proofGateStdOutPath = Join-Path -Path $verificationDirectory -ChildPath "proof-gate.stdout.log"
            $proofGateStdErrPath = Join-Path -Path $verificationDirectory -ChildPath "proof-gate.stderr.log"
            Write-TextFile -Path $proofGateStdOutPath -Content $proofGateResult.StdOut
            Write-TextFile -Path $proofGateStdErrPath -Content $proofGateResult.StdErr

            $proofGateRecord = [ordered]@{
                command = $proofGateCommand
                exitCode = $proofGateResult.ExitCode
                stdoutPath = $proofGateStdOutPath
                stderrPath = $proofGateStdErrPath
                statusArtifactPath = $proofGateStatusArtifactPath
                summaryStatus = $null
                completionReady = $false
                blockingReasons = @()
                reportId = $null
            }

            $proofGateStatus = Read-JsonFile -Path $proofGateStatusArtifactPath
            if ($null -ne $proofGateStatus) {
                $proofGateRecord.summaryStatus = if ($null -ne $proofGateStatus.summary) { [string]$proofGateStatus.summary.status } else { $null }
                $proofGateRecord.completionReady = [bool]$proofGateStatus.completion_ready
                $proofGateRecord.blockingReasons = @(ConvertTo-StringArray -Value $proofGateStatus.blocking_reasons)
                $proofGateRecord.reportId = [string]$proofGateStatus.report_id
            }
            else {
                $proofGateRecord.blockingReasons = @("Proof gate status artifact is missing or unreadable.")
            }

            if ($proofGateResult.ExitCode -ne 0) {
                if ($proofGateRecord.blockingReasons.Count -gt 0) {
                    $proofGateFailureReason = [string]$proofGateRecord.blockingReasons[0]
                }
                else {
                    $proofGateFailureReason = "Proof gate command exited non-zero."
                }
                $status = "proof_gate_failed"
                throw ("Proof gate failed: {0}" -f $proofGateFailureReason)
            }

            if (-not $proofGateRecord.completionReady) {
                if ($proofGateRecord.blockingReasons.Count -gt 0) {
                    $proofGateFailureReason = [string]$proofGateRecord.blockingReasons[0]
                }
                else {
                    $proofGateFailureReason = "Proof gate reported completion_ready=false."
                }
                $status = "proof_gate_failed"
                throw ("Proof gate blocked completion: {0}" -f $proofGateFailureReason)
            }
        }
    }

    if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        if ($null -eq $specToDiffArtifactRecord) {
            $status = "spec_to_diff_failed"
            $specToDiffFailureReason = "Spec-to-diff completion artifact is required when acceptance criteria are declared."
            throw $specToDiffFailureReason
        }
        if ($specToDiffArtifactTracked) {
            $status = "spec_to_diff_failed"
            $specToDiffFailureReason = ("Spec-to-diff artifact path is tracked and cannot be treated as temporary: {0}" -f $specToDiffPolicy.artifactPath)
            throw $specToDiffFailureReason
        }
    }

    $statusResult = Invoke-Git -Arguments @("status", "--porcelain") -WorkingDirectory $worktreePath
    Assert-CommandSucceeded -Result $statusResult -Description "git status --porcelain"
    if ([string]::IsNullOrWhiteSpace($statusResult.StdOut)) {
        $status = "no_changes"
        throw "Codex completed without producing repository changes."
    }

    $changedPaths = @(Get-ChangedPaths -WorkingDirectory $worktreePath)
    $allowedMutationSurfaces = @(ConvertTo-StringArray -Value $adapterContract.allowedMutationSurfaces)
    if ($allowedMutationSurfaces.Count -gt 0) {
        $mutationScopeViolations = @(
            $changedPaths |
            Where-Object { -not (Test-PathMatchesAllowedSurface -Path $_ -AllowedPatterns $allowedMutationSurfaces) }
        )
        if ($mutationScopeViolations.Count -gt 0) {
            $status = "mutation_scope_failed"
            throw ("Changed files exceeded repo adapter mutation scope: {0}" -f ($mutationScopeViolations -join ", "))
        }
    }
    if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        $specToDiffRecord = Test-SpecToDiffCompletionProof `
            -PromptRecord $promptRecord `
            -ArtifactRecord $specToDiffArtifactRecord `
            -ChangedPaths $changedPaths `
            -WorkingDirectory $worktreePath
        $specToDiffValidationPath = Join-Path -Path $logDirectory -ChildPath "spec-to-diff.validation.json"
        Write-TextFile -Path $specToDiffValidationPath -Content (($specToDiffRecord | ConvertTo-Json -Depth 8) + "`r`n")
        if (-not $specToDiffRecord.isValid) {
            $status = "spec_to_diff_failed"
            $specToDiffFailureReason = if ($specToDiffRecord.blockingReasons.Count -gt 0) {
                [string]$specToDiffRecord.blockingReasons[0]
            }
            else {
                "Spec-to-diff validation failed."
            }
            throw ("Spec-to-diff verification gate failed: {0}" -f $specToDiffFailureReason)
        }
    }

    $resolvedCommit = Resolve-CommitMetadata -PromptRecord $promptRecord -ArtifactRecord $commitMetadataArtifactRecord -CommitPolicy $commitMetadataPolicy -ChangedPaths $changedPaths -RepoId ([string]$adapterContract.repoId)
    $commitMessage = $resolvedCommit.message
    $commitMetadataResolvedPath = Join-Path -Path $logDirectory -ChildPath "commit-meta.resolved.json"
    $commitMessagePath = Join-Path -Path $logDirectory -ChildPath "commit-message.txt"
    Write-TextFile -Path $commitMetadataResolvedPath -Content (([ordered]@{
        source = $resolvedCommit.source
        type = $resolvedCommit.type
        scope = $resolvedCommit.scope
        summary = $resolvedCommit.summary
        message = $resolvedCommit.message
        fallbackType = if ($resolvedCommit.PSObject.Properties.Name -contains "fallbackType") { $resolvedCommit.fallbackType } else { $null }
        fallbackArea = if ($resolvedCommit.PSObject.Properties.Name -contains "fallbackArea") { $resolvedCommit.fallbackArea } else { $null }
        candidateErrors = if ($resolvedCommit.PSObject.Properties.Name -contains "candidateErrors") { @($resolvedCommit.candidateErrors) } else { @() }
    } | ConvertTo-Json -Depth 6) + "`r`n")
    Write-TextFile -Path $commitMessagePath -Content ($commitMessage + "`r`n")

    if ($autoCommitEnabled) {
        Write-RunnerMessage -Message "Staging and committing task changes"
        $addResult = Invoke-Git -Arguments @("add", "-A") -WorkingDirectory $worktreePath
        Assert-CommandSucceeded -Result $addResult -Description "git add -A"

        $gitEnvironment = @{}
        $authorName = [string](Get-ConfigValue -Config $config -Path @("git", "author_name") -DefaultValue "")
        $authorEmail = [string](Get-ConfigValue -Config $config -Path @("git", "author_email") -DefaultValue "")
        if (-not [string]::IsNullOrWhiteSpace($authorName)) {
            $gitEnvironment["GIT_AUTHOR_NAME"] = $authorName
            $gitEnvironment["GIT_COMMITTER_NAME"] = $authorName
        }
        if (-not [string]::IsNullOrWhiteSpace($authorEmail)) {
            $gitEnvironment["GIT_AUTHOR_EMAIL"] = $authorEmail
            $gitEnvironment["GIT_COMMITTER_EMAIL"] = $authorEmail
        }

        $commitResult = Invoke-Git -Arguments @("commit", "-m", $commitMessage) -WorkingDirectory $worktreePath -Environment $gitEnvironment
        if ($commitResult.ExitCode -ne 0) {
            $status = "commit_failed"
            throw ("git commit failed. {0}" -f $commitResult.StdErr.Trim())
        }

        $shaResult = Invoke-Git -Arguments @("rev-parse", "HEAD") -WorkingDirectory $worktreePath
        Assert-CommandSucceeded -Result $shaResult -Description "git rev-parse HEAD"
        $commitSha = $shaResult.StdOut.Trim()

        if ($localLandingMode -ne "disabled") {
            Write-RunnerMessage -Message ("Attempting local landing to {0} in {1} mode" -f $localLandingTargetBranch, $localLandingMode)
            $landingResult = Invoke-LocalBranchLanding -WorkingDirectory $repoRoot -TargetBranch $localLandingTargetBranch -CommitSha $commitSha -TaskBranch $branchName -Mode $localLandingMode
            $landedToMain = [bool]$landingResult.landed_to_main
            $landingFailureReason = $landingResult.failureReason

            if ($landedToMain) {
                Write-RunnerMessage -Message ("Landed {0} to local {1}" -f $commitSha, $localLandingTargetBranch)
            }
            else {
                Write-RunnerMessage -Message ("Skipped local landing to {0}: {1}" -f $localLandingTargetBranch, $landingFailureReason) -Level "WARN"
            }
        }
    }

    $exportPatch = ConvertTo-RunnerBoolean -Value (Get-ConfigValue -Config $config -Path @("exports", "patch") -DefaultValue $true) -DefaultValue $true
    $exportBundle = ConvertTo-RunnerBoolean -Value (Get-ConfigValue -Config $config -Path @("exports", "bundle") -DefaultValue $false)
    if ($null -ne $adapterContract.exports) {
        $exportPatch = ConvertTo-RunnerBoolean -Value $adapterContract.exports.patch -DefaultValue $exportPatch
        $exportBundle = ConvertTo-RunnerBoolean -Value $adapterContract.exports.bundle -DefaultValue $exportBundle
    }
    if ($null -ne $promptRecord.ExportPatch) {
        $exportPatch = ConvertTo-RunnerBoolean -Value $promptRecord.ExportPatch -DefaultValue $exportPatch
    }
    if ($null -ne $promptRecord.ExportBundle) {
        $exportBundle = ConvertTo-RunnerBoolean -Value $promptRecord.ExportBundle -DefaultValue $exportBundle
    }

    if ($commitSha) {
        $configuredFormatPatchBaseRef = [string]$adapterContract.exports.formatPatchBaseRef
        if ([string]::IsNullOrWhiteSpace($configuredFormatPatchBaseRef)) {
            $configuredFormatPatchBaseRef = $configuredBaseRef
        }
        $formatPatchBaseRefResolution = Resolve-GitRef -PreferredRef $configuredFormatPatchBaseRef -WorkingDirectory $worktreePath
        $formatPatchBaseRefCandidates = @($formatPatchBaseRefResolution.candidates)
        $formatPatchBaseRefUsedFallback = [bool]$formatPatchBaseRefResolution.usedFallback
        $resolvedFormatPatchBaseRef = [string]$formatPatchBaseRefResolution.resolvedRef

        if ($exportPatch) {
            $patchPath = Join-Path -Path $exportsDirectory -ChildPath ("{0}.patch" -f $runId)
            if ([string]::IsNullOrWhiteSpace($resolvedFormatPatchBaseRef)) {
                $exportErrors += ("Patch export failed: format patch base ref was not available locally. Tried: {0}" -f ($formatPatchBaseRefCandidates -join ", "))
            }
            else {
                if ($formatPatchBaseRefUsedFallback) {
                    Write-RunnerMessage -Message ("Configured patch base ref {0} unavailable locally; using fallback {1}" -f $configuredFormatPatchBaseRef, $resolvedFormatPatchBaseRef) -Level "WARN"
                }
                else {
                    Write-RunnerMessage -Message ("Resolved patch export base ref to {0}" -f $resolvedFormatPatchBaseRef)
                }

                $patchResult = Invoke-Git -Arguments @("format-patch", "--stdout", ("{0}..HEAD" -f $resolvedFormatPatchBaseRef)) -WorkingDirectory $worktreePath
                if ($patchResult.ExitCode -eq 0) {
                    Write-TextFile -Path $patchPath -Content $patchResult.StdOut
                }
                else {
                    $exportErrors += ("Patch export failed: {0}" -f $patchResult.StdErr.Trim())
                }
            }
        }

        if ($exportBundle) {
            $bundlePath = Join-Path -Path $exportsDirectory -ChildPath ("{0}.bundle" -f $runId)
            $bundleResult = Invoke-Git -Arguments @("bundle", "create", $bundlePath, "HEAD", ("^{0}" -f $baseRef)) -WorkingDirectory $worktreePath
            if ($bundleResult.ExitCode -ne 0) {
                $exportErrors += ("Bundle export failed: {0}" -f $bundleResult.StdErr.Trim())
            }
        }
    }

    $status = "success"

    if ($cleanupWorktreeOnSuccess) {
        Write-RunnerMessage -Message ("Removing successful worktree {0}" -f $worktreePath)
        $removeResult = Invoke-Git -Arguments @("worktree", "remove", $worktreePath) -WorkingDirectory $repoRoot
        Assert-CommandSucceeded -Result $removeResult -Description "git worktree remove"
        $worktreePath = $null
    }
}
catch {
    Write-RunnerMessage -Message $_.Exception.Message -Level "ERROR"
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-RunnerMessage -Message $_.ScriptStackTrace.Trim() -Level "ERROR"
    }
}
finally {
    if ($null -ne $promptRecord) {
        try {
            $archiveSlug = ConvertTo-Slug -Value ([System.IO.Path]::GetFileNameWithoutExtension($PromptPath))
            $archivePath = New-ArchivePath -ArchiveDirectory $archiveDirectory -Slug $archiveSlug -Status $status -Extension ([System.IO.Path]::GetExtension($PromptPath))
            Move-Item -LiteralPath $PromptPath -Destination $archivePath -Force
        }
        catch {
            Write-RunnerMessage -Message ("Failed to archive prompt: {0}" -f $_.Exception.Message) -Level "ERROR"
            if ($status -eq "success") {
                $status = "archive_failed"
            }
        }
    }

    if ($null -ne $logDirectory) {
        $workerAssignmentId = if ($null -ne $workerAssignmentRecord) { $workerAssignmentRecord.assignment_id } else { $null }
        $workerAssignmentWorkerId = if ($null -ne $workerAssignmentRecord) { $workerAssignmentRecord.worker_id } else { $null }
        if ($null -ne $workerAssignmentRecord) {
            $touchedRanges = @()
            if (-not [string]::IsNullOrWhiteSpace($commitSha) -and ($null -ne $changedPaths) -and $changedPaths.Count -gt 0) {
                $touchedRanges = @(Get-StackTouchedRanges -WorkingDirectory $repoRoot -CommitSha $commitSha -ChangedPaths $changedPaths)
            }

            $workerState = switch ($status) {
                "success" { "completed" }
                "verification_failed" { "blocked" }
                "proof_gate_failed" { "blocked" }
                "mutation_scope_failed" { "blocked" }
                "spec_to_diff_failed" { "blocked" }
                "no_changes" { "blocked" }
                "codex_failed" { "failed" }
                "commit_failed" { "failed" }
                "archive_failed" { "failed" }
                default { "failed" }
            }

            $workerBlockedReason = if ($workerState -eq "completed") {
                $null
            }
            elseif ($status -eq "proof_gate_failed" -and -not [string]::IsNullOrWhiteSpace($proofGateFailureReason)) {
                "proof_gate_failed: $proofGateFailureReason"
            }
            elseif ($status -eq "spec_to_diff_failed" -and -not [string]::IsNullOrWhiteSpace($specToDiffFailureReason)) {
                "spec_to_diff_failed: $specToDiffFailureReason"
            }
            else {
                $status
            }
            $workerOutputRefs = @(
                (Get-StackRelativePath -RepoRoot $repoRoot -Path $manifestPath),
                (Get-StackRelativePath -RepoRoot $repoRoot -Path $summaryPath)
            )
            if (-not [string]::IsNullOrWhiteSpace($workerContextRef)) {
                $workerOutputRefs += $workerContextRef
            }
            $workerCompletedStatusRecord = New-StackWorkerStatus `
                -WorkerId $workerAssignmentWorkerId `
                -AssignmentId $workerAssignmentId `
                -State $workerState `
                -HeartbeatAt ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
                -TouchedRanges $touchedRanges `
                -OutputRefs $workerOutputRefs `
                -BlockedReason $workerBlockedReason `
                -MergeRequestRef $null `
                -ToolId $workerAssignmentToolId `
                -ExtensionId $workerAssignmentExtensionId `
                -RegistryDigest $workerAssignmentRegistryDigest
            [void](Write-StackWorkerArtifact -Artifact $workerCompletedStatusRecord -Path $workerCompletedStatusPath)
            $workerCompletedStatusRef = Get-StackRelativePath -RepoRoot $repoRoot -Path $workerCompletedStatusPath
            $workerCompletedStatusToolId = [string](Get-ObjectPropertyValue -Object $workerCompletedStatusRecord -Name "tool_id" -DefaultValue "")
            $workerCompletedStatusExtensionId = Get-ObjectPropertyValue -Object $workerCompletedStatusRecord -Name "extension_id" -DefaultValue $null
            $workerCompletedStatusRegistryDigest = [string](Get-ObjectPropertyValue -Object $workerCompletedStatusRecord -Name "registry_digest" -DefaultValue "")
            if (
                $workerState -eq "completed" -and
                -not [string]::IsNullOrWhiteSpace($workerCompletedStatusToolId) -and
                -not [string]::IsNullOrWhiteSpace($workerCompletedStatusRegistryDigest)
            ) {
                $completedObservationRefs = @($governedSourceRefs + @($workerAssignmentRef, $workerCompletedStatusRef) | Select-Object -Unique)
                [void](Publish-AtlasObservation `
                    -RepoRoot $repoRoot `
                    -Owner "_stack" `
                    -ObservationType "completed" `
                    -SourceKind "worker_status" `
                    -Status "completed" `
                    -SourceRef $workerCompletedStatusRef `
                    -ObservedAt ([string]$workerCompletedStatusRecord.heartbeat_at) `
                    -ScopeRef $governedSessionId `
                    -Details (New-AtlasGovernedObservationDetails `
                        -SessionId $governedSessionId `
                        -WorkerId ([string]$workerCompletedStatusRecord.worker_id) `
                        -AssignmentId ([string]$workerCompletedStatusRecord.assignment_id) `
                        -StackLockDigest ([string]$workerAssignmentRecord.stack_lock_digest) `
                        -ToolId $workerCompletedStatusToolId `
                        -ExtensionId $workerCompletedStatusExtensionId `
                        -RegistryDigest $workerCompletedStatusRegistryDigest `
                        -SourceArtifactRefs $completedObservationRefs))
            }

            try {
                $supervisorScriptPath = Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "ops\cortex\supervise_workers.py"
                $supervisorOutputRoot = Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "runtime\cortex\supervisor"
                $supervisorStdOutPath = Join-Path -Path $logDirectory -ChildPath "supervisor.stdout.log"
                $supervisorStdErrPath = Join-Path -Path $logDirectory -ChildPath "supervisor.stderr.log"
                $supervisorResult = Invoke-ProcessCapture `
                    -FilePath "python" `
                    -ArgumentList @($supervisorScriptPath, "--artifact-path", $logsDirectory, "--output-dir", $supervisorOutputRoot) `
                    -WorkingDirectory $stackLockContext.workspaceRoot
                Write-TextFile -Path $supervisorStdOutPath -Content $supervisorResult.StdOut
                Write-TextFile -Path $supervisorStdErrPath -Content $supervisorResult.StdErr

                if ($supervisorResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($supervisorResult.StdOut)) {
                    $supervisorReportRecord = $supervisorResult.StdOut | ConvertFrom-Json
                    $supervisorReportPath = Join-Path -Path $logDirectory -ChildPath "supervisor.report.json"
                    Write-TextFile -Path $supervisorReportPath -Content (($supervisorReportRecord | ConvertTo-Json -Depth 32) + "`r`n")

                    $supervisorConsumerRecord = Invoke-StackSupervisorConsumer `
                        -RepoRoot $repoRoot `
                        -ArtifactSearchRoot $logsDirectory `
                        -SupervisorOutputRoot $supervisorOutputRoot `
                        -TargetWorkerId $workerAssignmentWorkerId
                    $supervisorConsumerPath = Join-Path -Path $logDirectory -ChildPath "supervisor.consumer.json"
                    Write-TextFile -Path $supervisorConsumerPath -Content (($supervisorConsumerRecord | ConvertTo-Json -Depth 32) + "`r`n")

                    if ($supervisorConsumerRecord.processed_count -gt 0) {
                        $firstProcessedMerge = @($supervisorConsumerRecord.merge_requests | Where-Object { -not $_.already_processed } | Select-Object -First 1)[0]
                        if ($null -ne $firstProcessedMerge) {
                            $firstMergeRequestRef = [string]$firstProcessedMerge.merge_request_ref
                            if (-not [string]::IsNullOrWhiteSpace($firstMergeRequestRef)) {
                                $workerMergeRequestPath = Join-Path -Path $stackLockContext.workspaceRoot -ChildPath $firstMergeRequestRef
                                if (Test-Path -LiteralPath $workerMergeRequestPath) {
                                    $workerMergeRequestRecord = Read-StackJsonArtifact -Path $workerMergeRequestPath
                                }
                            }
                        }
                    }
                }
                else {
                    Write-RunnerMessage -Message "Supervisor scan did not complete successfully; merge consumption was skipped." -Level "WARN"
                }
            }
            catch {
                Write-RunnerMessage -Message ("Supervisor consumption failed: {0}" -f $_.Exception.Message) -Level "WARN"
            }
        }

        $manifest = [ordered]@{
            runId = $runId
            status = $status
            repoRoot = $repoRoot
            configPath = if ($null -ne $resolvedConfig) { $resolvedConfig.ConfigPath } else { $null }
            defaultsPath = if ($null -ne $resolvedConfig) { $resolvedConfig.DefaultsPath } else { $null }
            promptPath = $PromptPath
            archivePath = $archivePath
            branchName = $branchName
            baseRef = $baseRef
            configuredBaseRef = $configuredBaseRef
            baseRefUsedFallback = $baseRefUsedFallback
            baseRefCandidates = @($baseRefCandidates)
            worktreeDirectoryName = $worktreeDirectoryName
            worktreeNameMaxLength = $worktreeNameMaxLength
            worktreePath = $worktreePath
            commitSha = $commitSha
            stackLock = [ordered]@{
                path = $stackLockContext.stackLockPath
                digest = $stackLockContext.stackLockDigest
                fileDigest = $stackLockContext.stackLockFileDigest
                workspaceRoot = $stackLockContext.workspaceRoot
            }
            commit = [ordered]@{
                enabled = $autoCommitEnabled
                message = $commitMessage
                messagePath = $commitMessagePath
                metadataPath = $commitMetadataResolvedPath
                source = if ($null -ne $resolvedCommit) { $resolvedCommit.source } else { $null }
                artifactPath = if ($null -ne $commitMetadataPolicy) { $commitMetadataPolicy.artifactPath } else { $null }
                artifactLogPath = $commitMetadataRawPath
                artifactProvided = $null -ne $commitMetadataArtifactRecord
                artifactParseError = if ($null -ne $commitMetadataArtifactRecord) { $commitMetadataArtifactRecord.parseError } else { $null }
                artifactTracked = $commitMetadataArtifactTracked
                artifactRemoved = $commitMetadataArtifactRemoved
                validationFailures = if ($null -ne $resolvedCommit -and $resolvedCommit.PSObject.Properties.Name -contains "candidateErrors") { @($resolvedCommit.candidateErrors) } else { @() }
            }
            specToDiff = [ordered]@{
                enabled = if ($null -ne $specToDiffPolicy) { [bool]$specToDiffPolicy.enabled } else { $false }
                artifactPath = if ($null -ne $specToDiffPolicy) { [string]$specToDiffPolicy.artifactPath } else { $null }
                artifactLogPath = $specToDiffRawPath
                artifactProvided = $null -ne $specToDiffArtifactRecord
                artifactParseError = if ($null -ne $specToDiffArtifactRecord) { $specToDiffArtifactRecord.parseError } else { $null }
                artifactTracked = $specToDiffArtifactTracked
                artifactRemoved = $specToDiffArtifactRemoved
                validationPath = $specToDiffValidationPath
                validationPassed = if ($null -ne $specToDiffRecord) { [bool]$specToDiffRecord.isValid } else { $null }
                failureReason = $specToDiffFailureReason
                acceptanceCriteria = if ($null -ne $specToDiffPolicy) { @($specToDiffPolicy.acceptanceCriteria) } else { @() }
                expectedChangedPaths = if ($null -ne $specToDiffPolicy) { @($specToDiffPolicy.expectedChangedPaths) } else { @() }
                expectedUnchangedPaths = if ($null -ne $specToDiffPolicy) { @($specToDiffPolicy.expectedUnchangedPaths) } else { @() }
                blockedSkippedRules = if ($null -ne $specToDiffPolicy) { @($specToDiffPolicy.blockedSkippedRules) } else { @() }
            }
            sandboxMode = $effectiveSandboxMode
            codexCommand = $codexCommandRecord
            runtimePolicy = Get-RuntimePolicyReceipt -RuntimePolicy $runtimePolicy
            logs = [ordered]@{
                directory = $logDirectory
                manifest = $manifestPath
                codexStdOut = $codexStdOutPath
                codexStdErr = $codexStdErrPath
                finalSummary = $summaryPath
            }
            verification = @($verifyRecords)
            verificationBootstrap = @($verifyBootstrapRecords)
            proofGate = $proofGateRecord
            proofGateFailureReason = $proofGateFailureReason
            verificationSource = $verificationSource
            changedPaths = @($changedPaths)
            workerArtifacts = [ordered]@{
                assignment = if ($null -ne $workerAssignmentRecord) { $workerAssignmentPath } else { $null }
                runningStatus = if ($null -ne $workerAssignmentRecord) { $workerRunningStatusPath } else { $null }
                completedStatus = if ($null -ne $workerAssignmentRecord) { $workerCompletedStatusPath } else { $null }
                context = $workerContextRef
                mergeRequest = if (
                    -not [string]::IsNullOrWhiteSpace($workerMergeRequestPath) -and
                    (Test-Path -LiteralPath $workerMergeRequestPath)
                ) { $workerMergeRequestPath } else { $null }
            }
            supervisorLoop = [ordered]@{
                reportPath = $supervisorReportPath
                consumerPath = $supervisorConsumerPath
                processedMergeRequests = if ($null -ne $supervisorConsumerRecord) { @($supervisorConsumerRecord.merge_requests) } else { @() }
            }
            mutationScopeViolations = @($mutationScopeViolations)
            exportErrors = @($exportErrors)
            exports = [ordered]@{
                enabledPatch = $exportPatch
                enabledBundle = $exportBundle
                configuredFormatPatchBaseRef = $configuredFormatPatchBaseRef
                resolvedFormatPatchBaseRef = $resolvedFormatPatchBaseRef
                formatPatchBaseRefUsedFallback = $formatPatchBaseRefUsedFallback
                formatPatchBaseRefCandidates = @($formatPatchBaseRefCandidates)
            }
            docsUpdateNote = if ($null -ne $promptRecord) { $promptRecord.DocsUpdateNote } else { $null }
            repoAdapter = [ordered]@{
                path = $adapterContractPath
                kind = $adapterContract.kind
                schemaVersion = $adapterContract.schemaVersion
                repoId = $adapterContract.repoId
                description = $adapterContract.description
                allowedMutationSurfaces = @(ConvertTo-StringArray -Value $adapterContract.allowedMutationSurfaces)
                docsUpdateRules = @(ConvertTo-StringArray -Value $adapterContract.docsUpdateRules)
                bootstrapVerifyCommands = if ($null -ne $adapterVerifyConfig) { @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $adapterVerifyConfig -Name "bootstrapCommands" -DefaultValue @())) } else { @() }
                defaultVerifyCommands = if ($null -ne $adapterVerifyConfig) { @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $adapterVerifyConfig -Name "defaultCommands" -DefaultValue @())) } else { @() }
                proofGate = if ($null -ne $adapterVerifyConfig) { Get-ObjectPropertyValue -Object $adapterVerifyConfig -Name "proofGate" -DefaultValue $null } else { $null }
                artifacts = $adapterContract.artifacts
                pushPolicy = $pushPolicy
                autoCommitPolicy = $autoCommitPolicy
                localLandingPolicy = $localLandingPolicy
                exports = $adapterContract.exports
                execution = $adapterContract.execution
            }
            effectivePolicies = [ordered]@{
                autoCommitEnabled = $autoCommitEnabled
                pushMode = if ($null -ne $pushPolicy) { $pushPolicy.mode } else { $null }
                skipPush = if ($null -ne $pushPolicy) { $pushPolicy.skipPush } else { $null }
                localLandingMode = $localLandingMode
                localLandingTargetBranch = $localLandingTargetBranch
            }
            localLanding = [ordered]@{
                mode = $localLandingMode
                targetBranch = $localLandingTargetBranch
                taskBranch = $branchName
                commitSha = $commitSha
                landed_to_main = $landedToMain
                failureReason = if ($landedToMain) { $null } else { $landingFailureReason }
            }
        }

        Write-TextFile -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 8) + "`r`n")
    }
}

exit (Get-StatusExitCode -Status $status)
