Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "..\codex\CodexRunner.Common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "StackWorkerArtifacts.ps1")

function Invoke-GitChecked {
    param([string[]]$Arguments)

    & git @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed with exit code {1}." -f ($Arguments -join " "), $LASTEXITCODE)
    }
}

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Resolve-TestArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot
    )

    if ([System.IO.Path]::IsPathRooted($Reference)) {
        return $Reference
    }

    return Join-Path -Path $WorkspaceRoot -ChildPath $Reference
}

function Get-StableJsonSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $nodeScript = @'
const crypto = require("node:crypto");
const fs = require("node:fs");

function stable(value) {
  if (Array.isArray(value)) {
    return value.map(stable);
  }

  if (value && typeof value === "object") {
    const sorted = {};
    for (const key of Object.keys(value).sort()) {
      sorted[key] = stable(value[key]);
    }
    return sorted;
  }

  return value;
}

const payloadPath = process.argv[1];
const payload = JSON.parse(fs.readFileSync(payloadPath, "utf8"));
const json = JSON.stringify(stable(payload), null, 2);
process.stdout.write(`sha256:${crypto.createHash("sha256").update(json).digest("hex")}`);
'@

    $result = Invoke-ProcessCapture -FilePath "node" -ArgumentList @("-e", $nodeScript, $Path) -WorkingDirectory $WorkingDirectory
    Assert-Condition -Condition ($result.ExitCode -eq 0) -Message ("Failed to compute stable JSON digest for {0}: {1}" -f $Path, $result.StdErr)
    return $result.StdOut.Trim()
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..\..")).Path
$stackLockContext = Get-StackLockContext -RepoRoot $repoRoot
$testToolId = "read_only_scan"
$testRegistryDigest = "sha256:stack-worker-test-governed"

$correlationSessionId = Resolve-AtlasObservationSessionId `
    -SourceArtifactRefs @("runtime/atlas/sessions/acceptance-correlation-test/cortex-stack-dispatch-request.json")
Assert-Condition -Condition ($correlationSessionId -eq "acceptance-correlation-test") -Message "Canonical Atlas session handoff path did not preserve its correlation identity."
$nonSessionCorrelation = Resolve-AtlasObservationSessionId -SourceArtifactRefs @("tmp/atlas/unrelated.json")
Assert-Condition -Condition ([string]::IsNullOrWhiteSpace($nonSessionCorrelation)) -Message "Non-session handoff path must not create a correlation identity."

$activeOwnerPathSurfaces = @(
    "workspace.manifest.json",
    "ops/codex/repos/playbook/config.toml",
    "ops/codex/repos/lifeline/config.toml",
    "docs/codex-orchestration.md",
    "docs/dispatcher-protocol.md",
    "docs/STACK-ORCHESTRATION-ADOPTION.md",
    "ops/codex/Test-StackOperatorSurface.ps1",
    "ops/stack/Test-StackWorkerArtifacts.ps1"
)
$staleOwnerAliases = @("fawxzzy-" + "playbook", "fawxzzy-" + "lifeline")
foreach ($surfacePath in $activeOwnerPathSurfaces) {
    $surfaceText = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath $surfacePath))
    foreach ($staleOwnerAlias in $staleOwnerAliases) {
        Assert-Condition -Condition (-not $surfaceText.Contains($staleOwnerAlias)) -Message ("Active owner path surface still contains retired alias '{0}': {1}" -f $staleOwnerAlias, $surfacePath)
    }
}

$canonicalLifelineFixturePaths = @(
    (Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "repos\lifeline\examples\privileged-execution\capability-profile.json"),
    (Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "repos\lifeline\examples\privileged-execution\capability-profile.scoped-write-dry-run.json")
)
foreach ($fixturePath in $canonicalLifelineFixturePaths) {
    Assert-Condition -Condition (Test-Path -LiteralPath $fixturePath) -Message ("Canonical Lifeline privileged-execution fixture is missing: {0}" -f $fixturePath)
}

$stackLockText = [System.IO.File]::ReadAllText($stackLockContext.stackLockPath)
if ($stackLockText -notmatch '(?m)^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$') {
    throw "stack.lock.yaml does not expose lock_digest."
}

if ($Matches[1].Trim() -ne $stackLockContext.stackLockDigest) {
    throw "Resolved stack lock digest does not match the on-disk stack.lock.yaml digest."
}

$tempRoot = Join-Path -Path $stackLockContext.workspaceRoot -ChildPath ("tmp\stack-worker-artifacts-{0}" -f ([guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $assignment = New-StackWorkerAssignment `
        -AssignmentId "assignment-stack-test-001" `
        -WorkerId "worker-stack-test-001" `
        -TaskId "stack-contracts" `
        -StackLockDigest $stackLockContext.stackLockDigest `
        -AllowedGlobs @("docs/**", "ops/**") `
        -ForbiddenGlobs @("secrets/**", "runtime/**") `
        -InputHandoffRefs @("handoff://root/stack-contracts") `
        -ExpectedOutputs @("logs/run.json", "logs/worker.status.completed.json") `
        -ToolId $testToolId `
        -ExtensionId $null `
        -RegistryDigest $testRegistryDigest `
        -Notes "Deterministic stack worker contract test."

    $runningStatus = New-StackWorkerStatus `
        -WorkerId $assignment.worker_id `
        -AssignmentId $assignment.assignment_id `
        -State "running" `
        -HeartbeatAt "2026-04-13T20:30:00Z" `
        -TouchedRanges @() `
        -OutputRefs @() `
        -BlockedReason $null `
        -MergeRequestRef $null `
        -ToolId $testToolId `
        -ExtensionId $null `
        -RegistryDigest $testRegistryDigest

    $mergeRequest = New-StackWorkerMergeRequest `
        -MergeRequestId "merge-request-stack-test-001" `
        -StackLockDigest $stackLockContext.stackLockDigest `
        -ConflictingWorkers @("worker-a", "worker-b") `
        -Overlaps @(
            [ordered]@{
                repo_path = "."
                path = "docs/codex-orchestration.md"
                overlap_type = "line_overlap"
                file_digest_before = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                conflicting_ranges = @(
                    [ordered]@{ worker_id = "worker-a"; start_line = 1; end_line = 4; op = "modify" },
                    [ordered]@{ worker_id = "worker-b"; start_line = 3; end_line = 6; op = "modify" }
                )
                reason = "Same file, overlapping ranges, same file digest before edit."
            }
        ) `
        -PausedHandoffRefs @("handoff://paused/worker-a", "handoff://paused/worker-b") `
        -MergeWorkerHandoff ([ordered]@{
            worker_id = "merge-worker-1"
            assignment_id = "assignment-stack-test-merge"
            task_id = "stack-merge"
            handoff_ref = "handoff://merge/worker-a-worker-b"
            tool_id = $testToolId
            extension_id = $null
            registry_digest = $testRegistryDigest
        }) `
        -ToolId $testToolId `
        -ExtensionId $null `
        -RegistryDigest $testRegistryDigest `
        -Notes "Merger consumes paused handoff artifacts only."

    $completedStatus = New-StackWorkerStatus `
        -WorkerId $assignment.worker_id `
        -AssignmentId $assignment.assignment_id `
        -State "completed" `
        -HeartbeatAt "2026-04-13T20:31:00Z" `
        -TouchedRanges @(
            [ordered]@{
                repo_path = "."
                repo_commit = "stack@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                file_digest_before = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                path = "docs/codex-orchestration.md"
                start_line = 1
                end_line = 8
                op = "modify"
            }
        ) `
        -OutputRefs @("logs/run.json", "logs/final-summary.md") `
        -BlockedReason $null `
        -MergeRequestRef $null `
        -ToolId $testToolId `
        -ExtensionId $null `
        -RegistryDigest $testRegistryDigest

    $firstAssignmentPath = Join-Path -Path $tempRoot -ChildPath "assignment-1.json"
    $secondAssignmentPath = Join-Path -Path $tempRoot -ChildPath "assignment-2.json"
    $firstAssignment = Write-StackWorkerArtifact -Artifact $assignment -Path $firstAssignmentPath
    $secondAssignment = Write-StackWorkerArtifact -Artifact $assignment -Path $secondAssignmentPath
    if ($firstAssignment.digest -ne $secondAssignment.digest) {
        throw "Assignment artifact digest changed across identical writes."
    }

    $firstStatusPath = Join-Path -Path $tempRoot -ChildPath "status-1.json"
    $secondStatusPath = Join-Path -Path $tempRoot -ChildPath "status-2.json"
    $firstStatus = Write-StackWorkerArtifact -Artifact $completedStatus -Path $firstStatusPath
    $secondStatus = Write-StackWorkerArtifact -Artifact $completedStatus -Path $secondStatusPath
    if ($firstStatus.digest -ne $secondStatus.digest) {
        throw "Completion status artifact digest changed across identical writes."
    }

    $firstMergePath = Join-Path -Path $tempRoot -ChildPath "merge-1.json"
    $secondMergePath = Join-Path -Path $tempRoot -ChildPath "merge-2.json"
    $firstMerge = Write-StackWorkerArtifact -Artifact $mergeRequest -Path $firstMergePath
    $secondMerge = Write-StackWorkerArtifact -Artifact $mergeRequest -Path $secondMergePath
    if ($firstMerge.digest -ne $secondMerge.digest) {
        throw "Merge-request artifact digest changed across identical writes."
    }

    $gitRepoRoot = Join-Path -Path $tempRoot -ChildPath "git-ranges"
    New-Item -ItemType Directory -Path $gitRepoRoot -Force | Out-Null
    $originalLocation = Get-Location
    try {
        Set-Location -LiteralPath $gitRepoRoot
        Invoke-GitChecked -Arguments @("init", "--quiet")
        Invoke-GitChecked -Arguments @("config", "user.name", "Stack Worker Artifact Test")
        Invoke-GitChecked -Arguments @("config", "user.email", "stack-worker-artifact-test@local")

        $samplePath = Join-Path -Path $gitRepoRoot -ChildPath "sample.md"
        @(
            "alpha"
            "bravo"
            "charlie"
        ) | Set-Content -LiteralPath $samplePath
        Invoke-GitChecked -Arguments @("add", "sample.md")
        Invoke-GitChecked -Arguments @("commit", "--quiet", "-m", "initial sample")
        $initialCommit = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "git rev-parse HEAD failed after the initial sample commit."
        }

        @(
            "alpha"
            "BRAVO"
            "charlie"
        ) | Set-Content -LiteralPath $samplePath
        Invoke-GitChecked -Arguments @("add", "sample.md")
        Invoke-GitChecked -Arguments @("commit", "--quiet", "-m", "update sample")

        $commitSha = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "git rev-parse HEAD failed after the updated sample commit."
        }
        $ranges = @(Get-StackTouchedRanges -WorkingDirectory $gitRepoRoot -CommitSha $commitSha -ChangedPaths @("sample.md"))
        if ($ranges.Count -ne 1) {
            throw ("Expected one touched range, got {0}." -f $ranges.Count)
        }

        $range = $ranges[0]
        if ($range.path -ne "sample.md" -or $range.start_line -ne 2 -or $range.end_line -ne 2 -or $range.op -ne "modify") {
            throw "Touched range parsing did not preserve the expected line range or operation."
        }

        $expectedDigest = Get-StackFileDigestBefore -WorkingDirectory $gitRepoRoot -BaseCommit $initialCommit -Path "sample.md"
        if ($range.file_digest_before -ne $expectedDigest) {
            throw "Touched range parser did not preserve the pre-edit file digest."
        }

        $contextOutputA = Join-Path -Path $tempRoot -ChildPath "worker-context-a.json"
        $contextOutputB = Join-Path -Path $tempRoot -ChildPath "worker-context-b.json"
        $contextBuildA = Invoke-StackWorkerContextBuild `
            -RepoRoot $repoRoot `
            -AssignmentId "assignment-context-test-001" `
            -WorkerId "worker-context-test-001" `
            -TaskId "atlas-context-check" `
            -StackLockDigest $stackLockContext.stackLockDigest `
            -QueryTerms @("atlas interoperability") `
            -TaskTags @("architecture") `
            -OutputPath $contextOutputA
        $contextBuildB = Invoke-StackWorkerContextBuild `
            -RepoRoot $repoRoot `
            -AssignmentId "assignment-context-test-001" `
            -WorkerId "worker-context-test-001" `
            -TaskId "atlas-context-check" `
            -StackLockDigest $stackLockContext.stackLockDigest `
            -QueryTerms @("atlas interoperability") `
            -TaskTags @("architecture") `
            -OutputPath $contextOutputB
        Assert-Condition -Condition ($contextBuildA.artifact.content_digest -eq $contextBuildB.artifact.content_digest) -Message "Worker context digest changed across identical builds."

        $atlasContextItem = @($contextBuildA.artifact.context_items | Where-Object { $_.archive_id -eq "personal--atlas-universal-interoperable-technology-stack" } | Select-Object -First 1)[0]
        Assert-Condition -Condition ($null -ne $atlasContextItem) -Message "Expected derived ATLAS archive to appear in the worker context."
        Assert-Condition -Condition ($null -ne $atlasContextItem.derived) -Message "Derived-only ATLAS archive did not expose derived context."

        $vertaContextOutput = Join-Path -Path $tempRoot -ChildPath "worker-context-verta.json"
        $vertaContextBuild = Invoke-StackWorkerContextBuild `
            -RepoRoot $repoRoot `
            -AssignmentId "assignment-context-test-verta" `
            -WorkerId "worker-context-test-verta" `
            -TaskId "verta-context-check" `
            -StackLockDigest $stackLockContext.stackLockDigest `
            -QueryTerms @("verta core sanitized") `
            -TaskTags @("quarantine") `
            -OutputPath $vertaContextOutput
        $vertaContextItem = @($vertaContextBuild.artifact.context_items | Where-Object { $_.archive_id -eq "personal--verta-core-sanitized" } | Select-Object -First 1)[0]
        Assert-Condition -Condition ($null -ne $vertaContextItem) -Message "Expected Verta sanitized archive to appear in the worker context."
        Assert-Condition -Condition (-not ($vertaContextItem.PSObject.Properties.Name -contains "derived")) -Message "Metadata-only Verta archive leaked derived context."

        $supervisorScriptPath = Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "ops\cortex\supervise_workers.py"
        $scenarioRoot = Join-Path -Path $tempRoot -ChildPath "supervisor-scenarios"
        New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null

        function Invoke-SupervisorScenario {
            param(
                [string]$Name,
                [string]$Path,
                [string]$FirstDigest,
                [string]$SecondDigest,
                [int]$FirstStart,
                [int]$FirstEnd,
                [int]$SecondStart,
                [int]$SecondEnd
            )

            $root = Join-Path -Path $scenarioRoot -ChildPath $Name
            New-Item -ItemType Directory -Path $root -Force | Out-Null

            $assignmentA = New-StackWorkerAssignment `
                -AssignmentId ("assignment-{0}-a" -f $Name) `
                -WorkerId ("worker-{0}-a" -f $Name) `
                -TaskId ("task-{0}-a" -f $Name) `
                -StackLockDigest $stackLockContext.stackLockDigest `
                -AllowedGlobs @("docs/**") `
                -ForbiddenGlobs @("secrets/**") `
                -InputHandoffRefs @("handoff://{0}/a" -f $Name) `
                -ExpectedOutputs @("logs/run.json") `
                -ToolId $testToolId `
                -ExtensionId $null `
                -RegistryDigest $testRegistryDigest
            $assignmentB = New-StackWorkerAssignment `
                -AssignmentId ("assignment-{0}-b" -f $Name) `
                -WorkerId ("worker-{0}-b" -f $Name) `
                -TaskId ("task-{0}-b" -f $Name) `
                -StackLockDigest $stackLockContext.stackLockDigest `
                -AllowedGlobs @("docs/**") `
                -ForbiddenGlobs @("secrets/**") `
                -InputHandoffRefs @("handoff://{0}/b" -f $Name) `
                -ExpectedOutputs @("logs/run.json") `
                -ToolId $testToolId `
                -ExtensionId $null `
                -RegistryDigest $testRegistryDigest

            $statusA = New-StackWorkerStatus `
                -WorkerId $assignmentA.worker_id `
                -AssignmentId $assignmentA.assignment_id `
                -State "running" `
                -HeartbeatAt "2026-04-14T02:00:00Z" `
                -TouchedRanges @(
                    (New-StackTouchedRange -RepoCommit "stack@sha256:1111" -RepoPath "." -Path $Path -StartLine $FirstStart -EndLine $FirstEnd -Op "modify" -FileDigestBefore $FirstDigest)
                ) `
                -OutputRefs @("handoff://paused/{0}/a" -f $Name) `
                -BlockedReason $null `
                -MergeRequestRef $null `
                -ToolId $testToolId `
                -ExtensionId $null `
                -RegistryDigest $testRegistryDigest
            $statusB = New-StackWorkerStatus `
                -WorkerId $assignmentB.worker_id `
                -AssignmentId $assignmentB.assignment_id `
                -State "running" `
                -HeartbeatAt "2026-04-14T02:00:30Z" `
                -TouchedRanges @(
                    (New-StackTouchedRange -RepoCommit "stack@sha256:2222" -RepoPath "." -Path $Path -StartLine $SecondStart -EndLine $SecondEnd -Op "modify" -FileDigestBefore $SecondDigest)
                ) `
                -OutputRefs @("handoff://paused/{0}/b" -f $Name) `
                -BlockedReason $null `
                -MergeRequestRef $null `
                -ToolId $testToolId `
                -ExtensionId $null `
                -RegistryDigest $testRegistryDigest

            [void](Write-StackWorkerArtifact -Artifact $assignmentA -Path (Join-Path -Path $root -ChildPath "assignment-a.json"))
            [void](Write-StackWorkerArtifact -Artifact $assignmentB -Path (Join-Path -Path $root -ChildPath "assignment-b.json"))
            [void](Write-StackWorkerArtifact -Artifact $statusA -Path (Join-Path -Path $root -ChildPath "status-a.json"))
            [void](Write-StackWorkerArtifact -Artifact $statusB -Path (Join-Path -Path $root -ChildPath "status-b.json"))

            $supervisorOutput = Join-Path -Path $root -ChildPath "supervisor"
            $supervisorResult = Invoke-ProcessCapture `
                -FilePath "python" `
                -ArgumentList @($supervisorScriptPath, "--artifact-path", $root, "--output-dir", $supervisorOutput) `
                -WorkingDirectory $stackLockContext.workspaceRoot
            Assert-Condition -Condition ($supervisorResult.ExitCode -eq 0) -Message ("Supervisor script failed for scenario {0}: {1}" -f $Name, $supervisorResult.StdErr)
            $report = $supervisorResult.StdOut | ConvertFrom-Json
            $consumer = Invoke-StackSupervisorConsumer -RepoRoot $repoRoot -ArtifactSearchRoot $root -SupervisorOutputRoot $supervisorOutput -TargetWorkerId $assignmentB.worker_id
            return [ordered]@{
                root = $root
                report = $report
                consumer = $consumer
            }
        }

        $overlapScenario = Invoke-SupervisorScenario `
            -Name "overlap" `
            -Path "docs/architecture/ATLAS-CORTEX-PLAYBOOK-CODEX.md" `
            -FirstDigest "sha256:overlap-same" `
            -SecondDigest "sha256:overlap-same" `
            -FirstStart 10 `
            -FirstEnd 20 `
            -SecondStart 18 `
            -SecondEnd 28
        Assert-Condition -Condition ($overlapScenario.report.merge_requests.Count -eq 1) -Message "Overlap scenario did not produce a merge request."
        Assert-Condition -Condition ($overlapScenario.consumer.processed_count -eq 1) -Message "Overlap scenario was not consumed into merger artifacts."
        $overlapProcessed = @($overlapScenario.consumer.merge_requests | Select-Object -First 1)[0]
        Assert-Condition -Condition ($overlapProcessed.pause_statuses.Count -eq 2) -Message "Overlap scenario did not pause both workers."
        Assert-Condition -Condition ($overlapProcessed.resume_contexts.Count -eq 2) -Message "Overlap scenario did not emit resume-context artifacts."
        Assert-Condition -Condition ((Test-Path -LiteralPath (Resolve-TestArtifactPath -Reference ([string]$overlapProcessed.merge_assignment_ref) -WorkspaceRoot $stackLockContext.workspaceRoot))) -Message "Overlap scenario did not emit a merger assignment."
        Assert-Condition -Condition ((Test-Path -LiteralPath (Resolve-TestArtifactPath -Reference ([string]$overlapProcessed.merge_prompt_ref) -WorkspaceRoot $stackLockContext.workspaceRoot))) -Message "Overlap scenario did not emit a merge prompt."
        $overlapResumeContext = Read-StackJsonArtifact -Path (Resolve-TestArtifactPath -Reference ([string]$overlapProcessed.resume_contexts[0].path) -WorkspaceRoot $stackLockContext.workspaceRoot)
        $overlapPauseStatus = Read-StackJsonArtifact -Path (Resolve-TestArtifactPath -Reference ([string]$overlapProcessed.pause_statuses[0].path) -WorkspaceRoot $stackLockContext.workspaceRoot)
        $overlapMergeAssignment = Read-StackJsonArtifact -Path (Resolve-TestArtifactPath -Reference ([string]$overlapProcessed.merge_assignment_ref) -WorkspaceRoot $stackLockContext.workspaceRoot)
        $overlapCompletion = Read-StackJsonArtifact -Path (Resolve-TestArtifactPath -Reference ([string]$overlapProcessed.completion_path) -WorkspaceRoot $stackLockContext.workspaceRoot)
        Assert-Condition -Condition (-not [bool]$overlapResumeContext.transcript_dependency) -Message "Resume context must stay transcript-free."
        Assert-Condition -Condition ([string]$overlapPauseStatus.tool_id -eq $testToolId) -Message "Pause status did not preserve the governed tool id."
        Assert-Condition -Condition ([string]$overlapResumeContext.tool_id -eq $testToolId) -Message "Resume context did not preserve the governed tool id."
        Assert-Condition -Condition ([string]$overlapMergeAssignment.tool_id -eq $testToolId) -Message "Merge assignment did not preserve the governed tool id."
        Assert-Condition -Condition ([string]$overlapCompletion.tool_id -eq $testToolId) -Message "Merge completion did not preserve the governed tool id."

        $nonOverlapScenario = Invoke-SupervisorScenario `
            -Name "non-overlap" `
            -Path "docs/ops/CORTEX-SUPERVISOR-RUNBOOK.md" `
            -FirstDigest "sha256:clean-same" `
            -SecondDigest "sha256:clean-same" `
            -FirstStart 1 `
            -FirstEnd 5 `
            -SecondStart 20 `
            -SecondEnd 24
        Assert-Condition -Condition ($nonOverlapScenario.report.merge_requests.Count -eq 0) -Message "Non-overlap scenario produced a false merge request."
        Assert-Condition -Condition ($nonOverlapScenario.consumer.processed_count -eq 0) -Message "Non-overlap scenario should not consume any merge request."

        $driftScenario = Invoke-SupervisorScenario `
            -Name "drift" `
            -Path "docs/ops/REPO-GITDIR-HYGIENE.md" `
            -FirstDigest "sha256:drift-a" `
            -SecondDigest "sha256:drift-b" `
            -FirstStart 10 `
            -FirstEnd 14 `
            -SecondStart 10 `
            -SecondEnd 14
        Assert-Condition -Condition ($driftScenario.report.merge_requests.Count -eq 1) -Message "Drift scenario did not produce a merge request."
        Assert-Condition -Condition ($driftScenario.report.merge_requests[0].overlaps[0].overlap_type -eq "file_digest_drift") -Message "Drift scenario was not classified as file_digest_drift."
        Assert-Condition -Condition ($driftScenario.consumer.processed_count -eq 1) -Message "Drift scenario merge request was not consumed."

        function Invoke-LifelineExecutionScenario {
            param(
                [string]$Name,
                [string]$Operation,
                [string]$ApprovalStatus,
                [string]$ExpiryAt,
                [string[]]$Command,
                [string[]]$TargetPaths = @(),
                [string[]]$TargetResources = @()
            )

            $root = Join-Path -Path $scenarioRoot -ChildPath ("lifeline-{0}" -f $Name)
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $toolId = if ($Operation -eq "read_only_scan") { "read_only_scan" } else { "scoped_write.dry_run" }
            $capabilityRef = if ($toolId -eq "read_only_scan") {
                "repos/lifeline/examples/privileged-execution/capability-profile.json"
            }
            else {
                "repos/lifeline/examples/privileged-execution/capability-profile.scoped-write-dry-run.json"
            }

            $assignment = New-StackWorkerAssignment `
                -AssignmentId ("assignment-lifeline-{0}" -f $Name) `
                -WorkerId ("worker-lifeline-{0}" -f $Name) `
                -TaskId ("task-lifeline-{0}" -f $Name) `
                -StackLockDigest $stackLockContext.stackLockDigest `
                -AllowedGlobs @("docs/**", "ops/**", "runtime/**") `
                -ForbiddenGlobs @("secrets/**") `
                -InputHandoffRefs @("handoff://lifeline/{0}" -f $Name) `
                -ExpectedOutputs @("runtime/lifeline/worker-execution/{0}" -f $Name) `
                -ToolId $toolId `
                -ExtensionId $null `
                -RegistryDigest $testRegistryDigest
            $status = New-StackWorkerStatus `
                -WorkerId $assignment.worker_id `
                -AssignmentId $assignment.assignment_id `
                -State "completed" `
                -HeartbeatAt "2026-04-14T03:00:00Z" `
                -TouchedRanges @() `
                -OutputRefs @("logs/final-summary.md") `
                -BlockedReason $null `
                -MergeRequestRef $null `
                -ToolId $toolId `
                -ExtensionId $null `
                -RegistryDigest $testRegistryDigest

            $assignmentPath = Join-Path -Path $root -ChildPath "worker.assignment.json"
            $statusPath = Join-Path -Path $root -ChildPath "worker.status.completed.json"
            [void](Write-StackWorkerArtifact -Artifact $assignment -Path $assignmentPath)
            [void](Write-StackWorkerArtifact -Artifact $status -Path $statusPath)

            $assignmentRef = Get-StackRelativePath -RepoRoot $repoRoot -Path $assignmentPath
            $statusRef = Get-StackRelativePath -RepoRoot $repoRoot -Path $statusPath
            $capabilityPath = Resolve-TestArtifactPath -Reference $capabilityRef -WorkspaceRoot $stackLockContext.workspaceRoot
            $capability = Read-StackJsonArtifact -Path $capabilityPath

            $request = [ordered]@{
                contract_version = "atlas.privileged-action.request.v1"
                request_id = ("request-lifeline-{0}" -f $Name)
                requested_at = "2026-04-14T03:01:00Z"
                worker_id = [string]$assignment.worker_id
                assignment_id = [string]$assignment.assignment_id
                stack_lock_digest = [string]$stackLockContext.stackLockDigest
                tool_id = $toolId
                extension_id = $null
                registry_digest = $testRegistryDigest
                automation_level = "request_action"
                source_refs = @($assignmentRef, $statusRef)
                action = [ordered]@{
                    summary = ("Execute {0} through Lifeline for {1}." -f $Operation, $Name)
                    operation = $Operation
                    command = @($Command)
                    cwd = "."
                }
                requested_capability = $capability
                dry_run_output = "Deterministic worker execution through Lifeline."
                justification = "Exercise the _stack -> Lifeline execution bridge."
            }
            if ($TargetPaths.Count -gt 0) {
                $request["target_paths"] = @($TargetPaths)
            }
            if ($TargetResources.Count -gt 0) {
                $request["target_resources"] = @($TargetResources)
            }

            $requestPath = Join-Path -Path $root -ChildPath "request.json"
            [void](Write-StackJsonArtifact -Artifact $request -Path $requestPath)
            $requestRef = Get-StackRelativePath -RepoRoot $repoRoot -Path $requestPath
            $requestDigest = Get-StableJsonSha256 -Path $requestPath -WorkingDirectory $stackLockContext.workspaceRoot

            $approval = [ordered]@{
                contract_version = "atlas.approval.receipt.v1"
                approval_receipt_id = ("approval-lifeline-{0}" -f $Name)
                request_id = [string]$request.request_id
                worker_id = [string]$assignment.worker_id
                assignment_id = [string]$assignment.assignment_id
                stack_lock_digest = [string]$stackLockContext.stackLockDigest
                tool_id = $toolId
                extension_id = $null
                registry_digest = $testRegistryDigest
                automation_level = "approved_action"
                approver = [ordered]@{
                    kind = "system"
                    name = "stack-worker-test"
                }
                approval_status = $ApprovalStatus
                granted_scope = if ($ApprovalStatus -eq "rejected") { $null } else { $capability }
                expiry_at = if ([string]::IsNullOrWhiteSpace($ExpiryAt)) { $null } else { $ExpiryAt }
                request_digest = $requestDigest
                issued_at = "2026-04-14T03:02:00Z"
            }
            if ($ApprovalStatus -eq "rejected") {
                $approval["reason"] = "Execution was intentionally rejected for contract testing."
            }

            $approvalPath = Join-Path -Path $root -ChildPath "approval.json"
            [void](Write-StackJsonArtifact -Artifact $approval -Path $approvalPath)
            $approvalRef = Get-StackRelativePath -RepoRoot $repoRoot -Path $approvalPath

            $bridge = Invoke-StackLifelineExecution `
                -RepoRoot $repoRoot `
                -WorkerAssignmentRef $assignmentRef `
                -WorkerStatusRef $statusRef `
                -CapabilityProfileRef $capabilityRef `
                -RequestRef $requestRef `
                -ApprovalReceiptRef $approvalRef `
                -ReceiptOutputRoot (Join-Path -Path $root -ChildPath "receipts")

            return [ordered]@{
                bridge = $bridge
                bridgeRecord = Read-StackJsonArtifact -Path (Resolve-TestArtifactPath -Reference ([string]$bridge.bridge_record_ref) -WorkspaceRoot $stackLockContext.workspaceRoot)
                receipt = Read-StackJsonArtifact -Path (Resolve-TestArtifactPath -Reference ([string]$bridge.receipt_ref) -WorkspaceRoot $stackLockContext.workspaceRoot)
                updatedStatus = Read-StackJsonArtifact -Path (Resolve-TestArtifactPath -Reference ([string]$bridge.worker_status_update_ref) -WorkspaceRoot $stackLockContext.workspaceRoot)
            }
        }

        $lifelineRequiredPaths = @(
            (Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "repos\lifeline"),
            (Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "repos\lifeline\dist\cli.js"),
            (Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "repos\lifeline\examples\privileged-execution\capability-profile.json"),
            (Join-Path -Path $stackLockContext.workspaceRoot -ChildPath "repos\lifeline\examples\privileged-execution\capability-profile.scoped-write-dry-run.json")
        )
        $missingLifelinePaths = @($lifelineRequiredPaths | Where-Object { -not (Test-Path -LiteralPath $_) })

        if ($missingLifelinePaths.Count -eq 0) {
            $approvedExpiryAt = "2099-12-31T23:59:59Z"

            $lifelineReadOnlyScenario = Invoke-LifelineExecutionScenario `
                -Name "read-only" `
                -Operation "read_only_scan" `
                -ApprovalStatus "approved" `
                -ExpiryAt $approvedExpiryAt `
                -Command @("node", "--version") `
                -TargetPaths @("README.md")
            Assert-Condition -Condition ($lifelineReadOnlyScenario.receipt.result -eq "succeeded") -Message "Read-only Lifeline bridge should succeed."
            Assert-Condition -Condition ($lifelineReadOnlyScenario.receipt.execution_mode -eq "read_only_scan") -Message "Read-only Lifeline bridge should preserve the read_only_scan execution mode."
            Assert-Condition -Condition ($lifelineReadOnlyScenario.updatedStatus.output_refs -contains [string]$lifelineReadOnlyScenario.bridge.receipt_ref) -Message "Read-only Lifeline bridge did not write the receipt ref back into worker status."
            Assert-Condition -Condition ($lifelineReadOnlyScenario.receipt.worker_id -eq $lifelineReadOnlyScenario.bridge.worker_id) -Message "Read-only Lifeline receipt lost the worker id."
            Assert-Condition -Condition ($lifelineReadOnlyScenario.receipt.assignment_id -eq $lifelineReadOnlyScenario.bridge.assignment_id) -Message "Read-only Lifeline receipt lost the assignment id."
            Assert-Condition -Condition ($lifelineReadOnlyScenario.receipt.stack_lock_digest -eq $stackLockContext.stackLockDigest) -Message "Read-only Lifeline receipt lost the stack lock digest."
            Assert-Condition -Condition ([string]$lifelineReadOnlyScenario.receipt.contract_version -eq "atlas.privileged-action.receipt.v1") -Message "Read-only Lifeline bridge must preserve the Lifeline receipt contract version."
            Assert-Condition -Condition ([string]$lifelineReadOnlyScenario.receipt.tool_id -eq "read_only_scan") -Message "Read-only Lifeline receipt lost the governed tool id."
            Assert-Condition -Condition ([string]$lifelineReadOnlyScenario.receipt.registry_digest -eq $testRegistryDigest) -Message "Read-only Lifeline receipt lost the registry digest."
            Assert-Condition -Condition ([string]$lifelineReadOnlyScenario.bridgeRecord.schema_version -eq "atlas.stack.lifeline-execution.v1") -Message "Read-only Lifeline bridge record must keep the _stack bridge contract version."
            Assert-Condition -Condition ([string]$lifelineReadOnlyScenario.bridgeRecord.request_ref -eq [string]$lifelineReadOnlyScenario.bridge.request_ref) -Message "Read-only Lifeline bridge record lost the canonical request ref."
            Assert-Condition -Condition ([string]$lifelineReadOnlyScenario.bridgeRecord.approval_receipt_ref -eq [string]$lifelineReadOnlyScenario.bridge.approval_receipt_ref) -Message "Read-only Lifeline bridge record lost the canonical approval ref."
            Assert-Condition -Condition ([string]$lifelineReadOnlyScenario.bridgeRecord.receipt_ref -eq [string]$lifelineReadOnlyScenario.bridge.receipt_ref) -Message "Read-only Lifeline bridge record lost the canonical receipt ref."

            $lifelineDryRunScenario = Invoke-LifelineExecutionScenario `
                -Name "dry-run" `
                -Operation "scoped_write" `
                -ApprovalStatus "approved" `
                -ExpiryAt $approvedExpiryAt `
                -Command @("node", "--version") `
                -TargetResources @("node")
            Assert-Condition -Condition ($lifelineDryRunScenario.receipt.result -eq "succeeded") -Message "Dry-run Lifeline bridge should succeed."
            Assert-Condition -Condition ($lifelineDryRunScenario.receipt.execution_mode -eq "dry_run_command") -Message "Dry-run Lifeline bridge should use the dry_run_command execution mode."
            Assert-Condition -Condition ($lifelineDryRunScenario.receipt.command_result.command[0] -eq "node") -Message "Dry-run Lifeline bridge did not preserve the requested command."
            Assert-Condition -Condition ([string]$lifelineDryRunScenario.receipt.contract_version -eq "atlas.privileged-action.receipt.v1") -Message "Dry-run Lifeline bridge must preserve the Lifeline receipt contract version."
            Assert-Condition -Condition ([string]$lifelineDryRunScenario.receipt.tool_id -eq "scoped_write.dry_run") -Message "Dry-run Lifeline receipt lost the governed tool id."

            $lifelineRejectedScenario = Invoke-LifelineExecutionScenario `
                -Name "rejected" `
                -Operation "scoped_write" `
                -ApprovalStatus "rejected" `
                -ExpiryAt "" `
                -Command @("node", "--version") `
                -TargetResources @("node")
            Assert-Condition -Condition ($lifelineRejectedScenario.receipt.result -eq "blocked") -Message "Rejected approval should emit a blocked receipt."
            Assert-Condition -Condition ($lifelineRejectedScenario.updatedStatus.state -eq "blocked") -Message "Rejected approval should write a blocked worker status."
            Assert-Condition -Condition ($lifelineRejectedScenario.updatedStatus.output_refs -contains [string]$lifelineRejectedScenario.bridge.receipt_ref) -Message "Rejected approval did not write the receipt ref back into worker status."

            $lifelineExpiredScenario = Invoke-LifelineExecutionScenario `
                -Name "expired" `
                -Operation "scoped_write" `
                -ApprovalStatus "approved" `
                -ExpiryAt "2026-04-13T00:00:00Z" `
                -Command @("node", "--version") `
                -TargetResources @("node")
            Assert-Condition -Condition ($lifelineExpiredScenario.receipt.result -eq "blocked") -Message "Expired approval should emit a blocked receipt."
            Assert-Condition -Condition ($lifelineExpiredScenario.updatedStatus.state -eq "blocked") -Message "Expired approval should write a blocked worker status."
            Assert-Condition -Condition ([string]$lifelineExpiredScenario.receipt.blocked_reason -match "expired") -Message "Expired approval should report an expired blocked reason."
        }
        else {
            Write-Host ("Skipping Lifeline bridge execution fixtures because required workspace dependencies are missing: {0}" -f ($missingLifelinePaths -join ", "))
        }
    }
    finally {
        Set-Location -LiteralPath $originalLocation
    }

    Write-Host "Validated _stack worker artifacts and touched-range parsing."
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
