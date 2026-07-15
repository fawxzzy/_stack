Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "AtlasContractsV2Producer.ps1")

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..\..")).Path
$logicalStackRoot = $repoRoot
if ((Split-Path -Leaf (Split-Path -Parent $logicalStackRoot)) -ieq "worktrees" -and (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $logicalStackRoot))) -ieq ".codex") {
    $logicalStackRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $logicalStackRoot))
}
$atlasRoot = (Resolve-Path -LiteralPath (Join-Path -Path $logicalStackRoot -ChildPath "..\..")).Path
$temporaryRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("atlas-contracts-v2-producer-{0}" -f [guid]::NewGuid().ToString("N"))
$previousThreadId = $env:CODEX_THREAD_ID
$previousTurnId = $env:CODEX_TURN_ID

try {
    $env:CODEX_THREAD_ID = "thread-producer-fixture"
    $env:CODEX_TURN_ID = "turn-producer-fixture"
    $producerSource = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "AtlasContractsV2Producer.ps1") -Raw
    Assert-Condition -Condition $producerSource.Contains("scripts\validate-artifact.mjs") -Message "Producer must invoke the Atlas-owned validate-artifact.mjs CLI."
    Assert-Condition -Condition (-not $producerSource.Contains("Validate-AtlasContractsV2Artifact.mjs")) -Message "Owner-side generic validator launcher must not be present."
    Assert-Condition -Condition (-not $producerSource.Contains("validate-json-schema.mjs")) -Message "Producer must not import or copy the Atlas validator engine."
    Assert-Condition -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "Validate-AtlasContractsV2Artifact.mjs"))) -Message "Discarded owner-side validator file must not exist."
    Assert-Condition -Condition ($script:AtlasContractsV2ArtifactNames.contextPacket -eq "atlas.context-packet.v2.json" -and $script:AtlasContractsV2ArtifactNames.approvalRecord -eq "atlas.approval-record.v2.json" -and $script:AtlasContractsV2ArtifactNames.evidenceBundle -eq "atlas.evidence-bundle.v2.json" -and $script:AtlasContractsV2ArtifactNames.workerLease -eq "atlas.worker-lease.v2.json") -Message "Producer must preserve the six accepted artifact families and add the exact WorkerLease filename."

    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $runtimePolicy = [pscustomobject]@{
        requested = [pscustomobject]@{
            model = "gpt-5.4"
            reasoning = "high"
            speed = "standard"
            permissions = [pscustomobject]@{ mode = "full-access" }
            approval = "never"
        }
        resolved = [pscustomobject]@{
            model = "gpt-5.4"
            reasoning = "high"
            speed = "standard"
            permissions = [pscustomobject]@{ mode = "full-access" }
            approval = "never"
        }
    }
    $prompt = [pscustomobject]@{ Title = "Atlas producer fixture" }

    # This is the pre-execution absence gate: the fake Codex callback is only
    # eligible after producer construction has succeeded.
    $fakeCodexLaunched = $false
    $absenceRejected = $false
    try {
        [void](New-AtlasContractsV2Producer -AtlasRoot $temporaryRoot -LogDirectory $temporaryRoot -RunId "absence" -PromptRecord $prompt -RuntimePolicy $runtimePolicy -ExecutionClass "fixture")
        $fakeCodexLaunched = $true
    }
    catch {
        $absenceRejected = $_.Exception.Message -eq "atlas_contracts_v2_package_unavailable"
    }
    Assert-Condition -Condition $absenceRejected -Message "Missing Atlas package must fail with the stable producer reason code."
    Assert-Condition -Condition (-not $fakeCodexLaunched) -Message "Missing Atlas package must stop before fake Codex execution."

    foreach ($rejectedSchema in @("atlas.context-packet.v2", "atlas.approval-record.v2", "atlas.worker-lease.v2")) {
        $rejectingAtlasRoot = Join-Path -Path $temporaryRoot -ChildPath ("rejecting-{0}" -f ($rejectedSchema -replace "[^a-z0-9]", "-"))
        $rejectingValidatorDirectory = Join-Path -Path $rejectingAtlasRoot -ChildPath "packages\atlas-contracts\scripts"
        New-Item -ItemType Directory -Path $rejectingValidatorDirectory -Force | Out-Null
        $rejectingValidatorPath = Join-Path -Path $rejectingValidatorDirectory -ChildPath "validate-artifact.mjs"
        [System.IO.File]::WriteAllText($rejectingValidatorPath, @"
const schema = process.argv[process.argv.indexOf('--schema') + 1];
const rejected = schema === '$rejectedSchema';
console.log(JSON.stringify(rejected ? { ok: false, code: 'INVALID_ARTIFACT' } : { ok: true }));
process.exit(rejected ? 1 : 0);
"@)
        $clusterTwoPreflightRejected = $false
        try {
            [void](New-AtlasContractsV2Producer -AtlasRoot $rejectingAtlasRoot -LogDirectory (Join-Path -Path $rejectingAtlasRoot -ChildPath "logs") -RunId "reject-$($rejectedSchema -replace '[^a-z0-9]', '-')" -PromptRecord $prompt -RuntimePolicy $runtimePolicy -ExecutionClass "fixture")
        }
        catch {
            $expectedReason = if ($rejectedSchema -eq "atlas.worker-lease.v2") { "atlas_contracts_v2_worker_lease_preflight_invalid" } else { "atlas_contracts_v2_validator_invalid_artifact" }
            $clusterTwoPreflightRejected = $_.Exception.Message -eq $expectedReason
        }
        Assert-Condition -Condition $clusterTwoPreflightRejected -Message ("Invalid {0} must fail closed before Codex execution." -f $rejectedSchema)
    }

    $producer = New-AtlasContractsV2Producer `
        -AtlasRoot $atlasRoot `
        -LogDirectory $temporaryRoot `
        -RunId "fixture-run" `
        -PromptRecord $prompt `
        -RuntimePolicy $runtimePolicy `
        -ExecutionClass "codex:repo:task" `
        -Branch "codex/fixture" `
        -WorkspaceRoot $temporaryRoot `
        -Worktree (Join-Path $temporaryRoot "fixture-worktree") `
        -WorkerId "worker-fixture" `
        -RecoveryCheckpoint (Join-Path $temporaryRoot "runner.active.json") `
        -AllowedPaths @("ops/**") `
        -ForbiddenPaths @("runtime/**") `
        -VerificationCommands @("git diff --check")
    Assert-Condition -Condition $producer.preflightValidated -Message "All required preflight artifacts must validate before execution."
    foreach ($artifactName in @("componentManifest", "jobEnvelope", "contextPacket", "approvalRecord", "workerLease")) {
        $path = [string]$producer.paths.$artifactName
        Assert-Condition -Condition (Test-Path -LiteralPath $path) -Message "Producer did not write required preflight artifact path: $path"
    }
    foreach ($validation in @($producer.validation.componentManifest, $producer.validation.jobEnvelope, $producer.validation.contextPacket, $producer.validation.approvalRecord, $producer.validation.workerLease)) {
        Assert-Condition -Condition $validation.ok -Message "Atlas validator did not accept preflight artifact."
        Assert-Condition -Condition ($validation.cliPath -eq (Join-Path $atlasRoot "packages\atlas-contracts\scripts\validate-artifact.mjs")) -Message "Producer did not invoke the canonical Atlas validator path."
    }
    $workerInstructions = Get-AtlasContractsV2WorkerInstructions -Producer $producer
    Assert-Condition -Condition $workerInstructions.Contains([string]$producer.paths.componentManifest) -Message "Worker context must expose the exact ComponentManifest path."
    Assert-Condition -Condition $workerInstructions.Contains([string]$producer.paths.jobEnvelope) -Message "Worker context must expose the exact JobEnvelope path."
    Assert-Condition -Condition $workerInstructions.Contains([string]$producer.paths.contextPacket) -Message "Worker context must expose the exact ContextPacket path."
    Assert-Condition -Condition $workerInstructions.Contains([string]$producer.paths.approvalRecord) -Message "Worker context must expose the exact ApprovalRecord path."
    Assert-Condition -Condition $workerInstructions.Contains([string]$producer.paths.workerLease) -Message "Worker context must expose the exact active WorkerLease path."
    Assert-Condition -Condition $workerInstructions.Contains("parent runner log") -Message "Worker context must explain the worktree visibility boundary."
    $envelope = Get-Content -LiteralPath $producer.paths.jobEnvelope -Raw | ConvertFrom-Json
    foreach ($authorityName in @("push", "deploy", "production", "discord", "board", "data_mutation")) {
        Assert-Condition -Condition ([string]$envelope.extensions.external_authority.$authorityName -eq "denied") -Message "External authority '$authorityName' must default to denied even with full local access."
    }
    $contextPacket = Get-Content -LiteralPath $producer.paths.contextPacket -Raw | ConvertFrom-Json
    Assert-Condition -Condition ([string]$contextPacket.job_id -eq [string]$producer.jobId -and [string]$contextPacket.component_id -eq [string]$producer.componentId) -Message "ContextPacket must correlate to the governed job and component."
    Assert-Condition -Condition (@($contextPacket.sources | Where-Object { $_.authority -eq "authoritative" }).Count -gt 0) -Message "ContextPacket must include authoritative runner sources."
    $approvalRecord = Get-Content -LiteralPath $producer.paths.approvalRecord -Raw | ConvertFrom-Json
    Assert-Condition -Condition ([string]$approvalRecord.job_id -eq [string]$producer.jobId) -Message "ApprovalRecord must correlate to the governed job."
    Assert-Condition -Condition ([string]$approvalRecord.decision -eq "rejected" -and [string]$approvalRecord.action.kind -eq "external-mutation") -Message "ApprovalRecord must honestly reject ungranted external mutation authority."
    $activeLease = Get-Content -LiteralPath $producer.paths.workerLease -Raw | ConvertFrom-Json
    Assert-Condition -Condition ([string]$activeLease.status -eq "active" -and $null -eq $activeLease.released_at) -Message "Preflight WorkerLease must be active and unreleased."
    Assert-Condition -Condition ([string]$activeLease.job_id -eq [string]$producer.jobId -and [string]$activeLease.component_id -eq [string]$producer.componentId -and [string]$activeLease.owner.worker_id -eq "worker-fixture") -Message "WorkerLease must retain job, component, and worker identity."
    Assert-Condition -Condition ([string]$activeLease.owner.thread_id -eq "thread-producer-fixture" -and [string]$activeLease.owner.turn_id -eq "turn-producer-fixture") -Message "WorkerLease must retain available native thread and turn IDs."
    Assert-Condition -Condition ([string]$activeLease.workspace.root -eq $temporaryRoot -and [string]$activeLease.workspace.worktree -eq (Join-Path $temporaryRoot "fixture-worktree") -and [string]$activeLease.workspace.branch -eq "codex/fixture") -Message "Repo WorkerLease must claim the exact workspace root, isolated worktree, and branch."
    Assert-Condition -Condition (@($activeLease.resources | Where-Object { $_.kind -eq "worktree" -and $_.resource_id -eq (Join-Path $temporaryRoot "fixture-worktree") -and $_.exclusive }).Count -eq 1 -and @($activeLease.resources | Where-Object { $_.kind -eq "branch" -and $_.resource_id -eq "codex/fixture" -and $_.exclusive }).Count -eq 1) -Message "Repo WorkerLease must claim only its governed worktree and branch posture."
    Assert-Condition -Condition (@($activeLease.resources | Where-Object { $_.kind -in @("process", "port", "browser", "database", "external-writer") }).Count -eq 0) -Message "WorkerLease must not invent process, port, browser, database, or external-writer claims."

    $canonicalDirectory = Join-Path $temporaryRoot "canonical"
    $canonicalProducer = New-AtlasContractsV2Producer -AtlasRoot $atlasRoot -LogDirectory $canonicalDirectory -RunId "canonical-fixture" -PromptRecord $prompt -RuntimePolicy $runtimePolicy -ExecutionClass "canonical_workspace" -Branch "main" -WorkspaceRoot $temporaryRoot -Worktree $null -WorkerId "canonical-worker" -CanonicalWorkspace -CanonicalWriterResource (Join-Path $temporaryRoot ".codex\locks\writer.json") -RecoveryCheckpoint (Join-Path $canonicalDirectory "run.json")
    $canonicalLease = Get-Content -LiteralPath $canonicalProducer.paths.workerLease -Raw | ConvertFrom-Json
    Assert-Condition -Condition ($null -eq $canonicalLease.workspace.worktree -and [string]$canonicalLease.workspace.root -eq $temporaryRoot -and [string]$canonicalLease.workspace.branch -eq "main") -Message "Canonical WorkerLease must claim the canonical workspace without inventing a worktree."
    Assert-Condition -Condition (@($canonicalLease.resources | Where-Object { [string](Get-ObjectPropertyValue -Object $_.metadata -Name "resource_type" -DefaultValue "") -eq "canonical-workspace" }).Count -eq 1 -and @($canonicalLease.resources | Where-Object { [string](Get-ObjectPropertyValue -Object $_.metadata -Name "resource_type" -DefaultValue "") -eq "canonical-single-writer" }).Count -eq 1 -and @($canonicalLease.resources | Where-Object { $_.kind -eq "worktree" }).Count -eq 0) -Message "Canonical WorkerLease must claim its workspace and single-writer lock without a worktree claim."

    $unknownMajor = Invoke-AtlasContractsV2Validation -Contracts $producer.contracts -SchemaId "atlas.component-manifest.v99" -ArtifactPath $producer.paths.componentManifest -EvidencePath (Join-Path $temporaryRoot "unknown-major.validation.json")
    Assert-Condition -Condition (-not $unknownMajor.ok) -Message "Unknown contract major must be rejected."
    Assert-Condition -Condition ($unknownMajor.reasonCode -eq "atlas_contracts_v2_validator_unsupported_contract_version") -Message "Unknown contract major must preserve the stable _stack reason code."
    Assert-Condition -Condition ([string]$unknownMajor.result.code -eq "UNSUPPORTED_CONTRACT_VERSION") -Message "Unknown contract major must retain the Atlas CLI JSON result."

    $verificationRecord = [pscustomobject]@{ command = "git diff --check"; exitCode = 0; stdoutPath = "fixture-verify.stdout.log"; stderrPath = "fixture-verify.stderr.log" }
    $successReceipt = Write-AtlasContractsV2TerminalReceipt -Producer $producer -RunnerStatus "success" -RuntimePolicy $runtimePolicy -VerificationCommands @("git diff --check") -VerificationRecords @($verificationRecord) -Branch "codex/fixture" -Worktree (Join-Path $temporaryRoot "fixture-worktree") -EvidenceRefs @("fixture.log") -LeaseReleaseProven $true -LeaseRecoveryCheckpoint (Join-Path $temporaryRoot "run.json")
    Assert-Condition -Condition $successReceipt.ok -Message "Successful terminal receipt must validate through Atlas CLI."
    $releasedLease = Get-Content -LiteralPath $producer.paths.workerLease -Raw | ConvertFrom-Json
    Assert-Condition -Condition ([string]$releasedLease.status -eq "released" -and -not [string]::IsNullOrWhiteSpace([string]$releasedLease.released_at) -and ([DateTimeOffset]$releasedLease.released_at) -ge ([DateTimeOffset]$releasedLease.acquired_at)) -Message "Accepted completion must release the same WorkerLease with monotonic terminal timing."
    Assert-Condition -Condition ([bool]$producer.validation.workerLeaseTerminal.ok) -Message "Terminal WorkerLease must validate through the Atlas-owned CLI before receipt acceptance."
    $successEvidenceBundle = Get-Content -LiteralPath $producer.paths.evidenceBundle -Raw | ConvertFrom-Json
    Assert-Condition -Condition ([string]$successEvidenceBundle.evidence[0].status -eq "passed" -and [string]$successEvidenceBundle.classifications[0] -eq "verified") -Message "Successful terminal EvidenceBundle must derive verified evidence from actual verification records."
    $recoveryDirectory = Join-Path $temporaryRoot "recovery"
    $recoveryProducer = New-AtlasContractsV2Producer -AtlasRoot $atlasRoot -LogDirectory $recoveryDirectory -RunId "recovery-fixture" -PromptRecord $prompt -RuntimePolicy $runtimePolicy -ExecutionClass "codex:repo:task" -Branch "codex/recovery" -WorkspaceRoot $temporaryRoot -Worktree (Join-Path $temporaryRoot "recovery-worktree") -WorkerId "worker-recovery" -RecoveryCheckpoint (Join-Path $recoveryDirectory "worker.status.running.json")
    $failedReceipt = Write-AtlasContractsV2TerminalReceipt -Producer $recoveryProducer -RunnerStatus "codex_failed" -RuntimePolicy $runtimePolicy -VerificationCommands @("git diff --check") -Branch "codex/recovery" -Worktree (Join-Path $temporaryRoot "recovery-worktree") -Reason "fixture failure" -EvidenceRefs @("fixture.log") -LeaseReleaseProven $false -LeaseRecoveryCheckpoint (Join-Path $recoveryDirectory "run.json")
    Assert-Condition -Condition $failedReceipt.ok -Message "Non-success terminal receipt must validate through Atlas CLI."
    Assert-Condition -Condition (Test-Path -LiteralPath $recoveryProducer.paths.executionReceipt) -Message "Producer did not write the required terminal ExecutionReceipt artifact."
    $receipt = Get-Content -LiteralPath $recoveryProducer.paths.executionReceipt -Raw | ConvertFrom-Json
    $evidenceBundle = Get-Content -LiteralPath $recoveryProducer.paths.evidenceBundle -Raw | ConvertFrom-Json
    $recoveryLease = Get-Content -LiteralPath $recoveryProducer.paths.workerLease -Raw | ConvertFrom-Json
    Assert-Condition -Condition ([string]$recoveryLease.status -eq "recovery-required" -and $null -eq $recoveryLease.released_at -and [string]$recoveryLease.recovery.checkpoint -eq (Join-Path $recoveryDirectory "run.json")) -Message "Unproven release must terminalize as recovery-required with durable runner evidence."
    Assert-Condition -Condition $recoveryProducer.validation.evidenceBundle.ok -Message "Terminal EvidenceBundle must validate through Atlas CLI."
    Assert-Condition -Condition ([string]$evidenceBundle.job_id -eq [string]$recoveryProducer.jobId -and [string]$evidenceBundle.environment.component_id -eq [string]$recoveryProducer.componentId -and [string]$evidenceBundle.extensions.run_id -eq [string]$recoveryProducer.runId) -Message "EvidenceBundle must retain job, component, and run correlations."
    Assert-Condition -Condition ([string]$evidenceBundle.evidence[0].status -eq "unavailable" -and [string]$evidenceBundle.classifications[0] -eq "unknown") -Message "Terminal EvidenceBundle must honestly record unavailable verification facts."
    Assert-Condition -Condition (@($receipt.evidence_refs | Where-Object { $_ -eq $recoveryProducer.paths.contextPacket -or $_ -eq $recoveryProducer.paths.approvalRecord -or $_ -eq $recoveryProducer.paths.workerLease -or $_ -eq $recoveryProducer.paths.evidenceBundle }).Count -eq 4) -Message "ExecutionReceipt must retain durable references to all additive artifacts."
    Assert-Condition -Condition ([string]$receipt.status -eq "failed") -Message "Non-success runner state must produce a failed ExecutionReceipt."
    Assert-Condition -Condition (@($receipt.authority_actions).Count -eq 0) -Message "Producer must not claim external authority actions."
    Assert-Condition -Condition ([string]$receipt.extensions.runtime_requested.model -eq "gpt-5.4" -and [string]$receipt.runtime_effective.model -eq "gpt-5.4") -Message "Terminal receipt must correlate requested and effective runtime policy."
    Assert-Condition -Condition ([string]$receipt.extensions.identity_correlations.job_id -eq [string]$recoveryProducer.jobId -and [string]$receipt.extensions.identity_correlations.run_id -eq [string]$recoveryProducer.runId) -Message "Terminal receipt must preserve the artifact identity chain."
    Assert-Condition -Condition ([string]$receipt.extensions.worker_lease_binding.lease_id -eq [string]$recoveryLease.lease_id -and [string]$receipt.extensions.worker_lease_binding.status -eq "recovery-required" -and [string]$receipt.extensions.worker_lease_binding.digest -eq (Get-AtlasContractsV2ArtifactDigest -Path $recoveryProducer.paths.workerLease) -and [string]$receipt.extensions.worker_lease_binding.artifact_ref -eq [string]$recoveryProducer.paths.workerLease) -Message "ExecutionReceipt must bind the exact terminal WorkerLease ID, status, digest, and artifact path."
    Assert-Condition -Condition ([string]$receipt.extensions.compatibility.v1 -eq "preserved" -and @($receipt.extensions.compatibility.cluster_1_artifacts).Count -eq 3) -Message "Terminal receipt must prove additive Cluster 1 and v1 compatibility."
    Assert-Condition -Condition ([string]$receipt.extensions.commit_state.status -eq "not-created" -and [string]$receipt.extensions.prohibited_action_confirmation.push -eq "not-exercised") -Message "Terminal receipt must record commit state and prohibited-action confirmation."

    $invalidTerminalDirectory = Join-Path $temporaryRoot "invalid-terminal"
    $invalidTerminalProducer = New-AtlasContractsV2Producer -AtlasRoot $atlasRoot -LogDirectory $invalidTerminalDirectory -RunId "invalid-terminal" -PromptRecord $prompt -RuntimePolicy $runtimePolicy -ExecutionClass "codex:repo:task" -Branch "codex/invalid-terminal" -WorkspaceRoot $temporaryRoot -Worktree (Join-Path $temporaryRoot "invalid-terminal-worktree") -WorkerId "worker-invalid-terminal"
    $invalidTerminalProducer.lease.workspace.root = ""
    $invalidTerminalRejected = $false
    try { [void](Complete-AtlasContractsV2WorkerLease -Producer $invalidTerminalProducer -RunnerStatus "success" -ReleaseProven $true -RecoveryCheckpoint (Join-Path $invalidTerminalDirectory "run.json")) }
    catch { $invalidTerminalRejected = $_.Exception.Message -eq "atlas_contracts_v2_worker_lease_terminal_invalid" }
    Assert-Condition -Condition $invalidTerminalRejected -Message "Invalid terminal WorkerLease must fail the receipt path with a stable reason code."
    Assert-Condition -Condition (-not [bool]$invalidTerminalProducer.validation.workerLeaseTerminal.ok) -Message "Invalid terminal WorkerLease must retain Atlas CLI rejection evidence."

    Write-Output "Atlas Contracts v2 producer tests passed."
}
finally {
    $env:CODEX_THREAD_ID = $previousThreadId
    $env:CODEX_TURN_ID = $previousTurnId
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
