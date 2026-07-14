Set-StrictMode -Version Latest

# Atlas owns schema registration and validation. This producer only creates
# `_stack` execution facts and invokes the published Atlas CLI.
$script:AtlasContractsV2ArtifactNames = [ordered]@{
    componentManifest = "atlas.component-manifest.v2.json"
    jobEnvelope = "atlas.job-envelope.v2.json"
    contextPacket = "atlas.context-packet.v2.json"
    approvalRecord = "atlas.approval-record.v2.json"
    evidenceBundle = "atlas.evidence-bundle.v2.json"
    executionReceipt = "atlas.execution-receipt.v2.json"
}

function Get-AtlasContractsV2ContractPaths {
    param([Parameter(Mandatory = $true)][string]$AtlasRoot)

    $resolvedAtlasRoot = (Resolve-Path -LiteralPath $AtlasRoot -ErrorAction Stop).Path
    $packageRoot = Join-Path -Path $resolvedAtlasRoot -ChildPath "packages\atlas-contracts"
    $validatorPath = Join-Path -Path $packageRoot -ChildPath "scripts\validate-artifact.mjs"
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
        throw "atlas_contracts_v2_package_unavailable"
    }
    if (-not (Test-Path -LiteralPath $validatorPath -PathType Leaf)) {
        throw "atlas_contracts_v2_validator_unavailable"
    }

    return [pscustomobject]@{
        atlasRoot = $resolvedAtlasRoot
        packageRoot = $packageRoot
        validatorPath = $validatorPath
    }
}

function ConvertTo-AtlasContractsV2Runtime {
    param($RuntimePolicy)

    $resolved = Get-ObjectPropertyValue -Object $RuntimePolicy -Name "resolved" -DefaultValue $null
    $permissions = Get-ObjectPropertyValue -Object $resolved -Name "permissions" -DefaultValue $null
    $permissionMode = [string](Get-ObjectPropertyValue -Object $permissions -Name "mode" -DefaultValue "custom")
    if ($permissionMode -in @("danger-full-access", "full-access")) { $permissionMode = "full-access" }
    elseif ($permissionMode -in @("workspace-write", "read-only", "custom")) { }
    else { $permissionMode = "custom" }

    return [ordered]@{
        model = [string](Get-ObjectPropertyValue -Object $resolved -Name "model" -DefaultValue "unknown")
        reasoning = [string](Get-ObjectPropertyValue -Object $resolved -Name "reasoning" -DefaultValue "medium")
        speed = [string](Get-ObjectPropertyValue -Object $resolved -Name "speed" -DefaultValue "standard")
        permissions = $permissionMode
        approval_policy = [string](Get-ObjectPropertyValue -Object $resolved -Name "approval" -DefaultValue "never")
    }
}

function Get-AtlasContractsV2ReasonCode {
    param($ValidationResult)

    $validatorCode = [string](Get-ObjectPropertyValue -Object $ValidationResult -Name "code" -DefaultValue "")
    if ($validatorCode -eq "UNSUPPORTED_CONTRACT_VERSION") { return "atlas_contracts_v2_validator_unsupported_contract_version" }
    if ($validatorCode -eq "UNKNOWN_SCHEMA") { return "atlas_contracts_v2_validator_unknown_schema" }
    if ($validatorCode -eq "INVALID_SCHEMA_REFERENCE") { return "atlas_contracts_v2_validator_invalid_schema_reference" }
    if ($validatorCode -eq "MISSING_INPUT") { return "atlas_contracts_v2_validator_missing_input" }
    if ($validatorCode -eq "MALFORMED_JSON") { return "atlas_contracts_v2_validator_malformed_json" }
    if ($validatorCode -eq "INVALID_ARTIFACT") { return "atlas_contracts_v2_validator_invalid_artifact" }
    return "atlas_contracts_v2_validator_failed"
}

function Invoke-AtlasContractsV2Validation {
    param(
        [Parameter(Mandatory = $true)]$Contracts,
        [Parameter(Mandatory = $true)][string]$SchemaId,
        [Parameter(Mandatory = $true)][string]$ArtifactPath,
        [Parameter(Mandatory = $true)][string]$EvidencePath
    )

    $processResult = Invoke-ProcessCapture `
        -FilePath "node" `
        -ArgumentList @($Contracts.validatorPath, "--json", "--schema", $SchemaId, "--artifact", $ArtifactPath) `
        -WorkingDirectory $Contracts.atlasRoot
    $validatorResult = $null
    $parseError = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$processResult.StdOut)) {
        try { $validatorResult = $processResult.StdOut | ConvertFrom-Json -ErrorAction Stop }
        catch { $parseError = $_.Exception.Message }
    }

    $record = [ordered]@{
        invoked = $true
        cliPath = $Contracts.validatorPath
        schemaId = $SchemaId
        artifactPath = $ArtifactPath
        exitCode = [int]$processResult.ExitCode
        result = $validatorResult
        stdout = [string]$processResult.StdOut
        stderr = [string]$processResult.StdErr
        parseError = $parseError
        ok = $processResult.ExitCode -eq 0 -and $null -ne $validatorResult -and [bool]$validatorResult.ok
        reasonCode = $null
    }
    if (-not $record.ok) { $record.reasonCode = Get-AtlasContractsV2ReasonCode -ValidationResult $validatorResult }
    Write-TextFile -Path $EvidencePath -Content (($record | ConvertTo-Json -Depth 12) + "`r`n")
    return [pscustomobject]$record
}

function Assert-AtlasContractsV2Validation {
    param([Parameter(Mandatory = $true)]$Validation)
    if (-not [bool]$Validation.ok) { throw ([string]$Validation.reasonCode) }
}

function Get-AtlasContractsV2Surface {
    param($Producer, [string]$TerminalStatus = $null, $ReceiptValidation = $null, [string]$PreflightFailureReason = $null)
    if ($null -eq $Producer) {
        if ([string]::IsNullOrWhiteSpace($PreflightFailureReason)) { return $null }
        return [ordered]@{
            artifactPaths = $null
            validation = $null
            identities = $null
            status = [ordered]@{ preflight = "failed"; terminal = $TerminalStatus; receiptValidated = $null; reasonCode = $PreflightFailureReason }
        }
    }
    return [ordered]@{
        artifactPaths = $Producer.paths
        validation = [ordered]@{
            componentManifest = $Producer.validation.componentManifest
            jobEnvelope = $Producer.validation.jobEnvelope
            contextPacket = $Producer.validation.contextPacket
            approvalRecord = $Producer.validation.approvalRecord
            evidenceBundle = $Producer.validation.evidenceBundle
            executionReceipt = $ReceiptValidation
        }
        identities = [ordered]@{
            componentId = $Producer.componentId
            jobId = $Producer.jobId
            runId = $Producer.runId
            executionClass = $Producer.executionClass
        }
        status = [ordered]@{
            preflight = if ([bool]$Producer.preflightValidated) { "validated" } else { "failed" }
            terminal = $TerminalStatus
            receiptValidated = if ($null -eq $ReceiptValidation) { $null } else { [bool]$ReceiptValidation.ok }
            reasonCode = $PreflightFailureReason
        }
    }
}

function New-AtlasContractsV2Producer {
    param(
        [Parameter(Mandatory = $true)][string]$AtlasRoot,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)]$PromptRecord,
        [Parameter(Mandatory = $true)]$RuntimePolicy,
        [Parameter(Mandatory = $true)][string]$ExecutionClass,
        [string]$BaseRef,
        [string]$Branch,
        [string]$Worktree,
        [string[]]$AllowedPaths = @(),
        [string[]]$ForbiddenPaths = @(),
        [string[]]$VerificationCommands = @(),
        [string]$ProjectId = "atlas",
        $CardId = $null,
        $ParentJobId = $null
    )

    $contracts = Get-AtlasContractsV2ContractPaths -AtlasRoot $AtlasRoot
    $paths = [ordered]@{}
    $validationPaths = [ordered]@{}
    foreach ($key in $script:AtlasContractsV2ArtifactNames.Keys) {
        $paths[$key] = Join-Path -Path $LogDirectory -ChildPath $script:AtlasContractsV2ArtifactNames[$key]
        $validationPaths[$key] = "$($paths[$key]).validation.json"
    }
    $runtime = ConvertTo-AtlasContractsV2Runtime -RuntimePolicy $RuntimePolicy
    $jobId = "atlas-stack-{0}" -f $RunId
    $component = [ordered]@{
        contract_version = "atlas.component-manifest.v2"
        component_id = "stack"
        display_name = "Atlas Stack Operator"
        kind = "operator"
        owner = [ordered]@{ id = "stack"; authority = "owner-repository" }
        repository = [ordered]@{ repo_id = "stack"; root_path = "repos/_stack"; default_branch = "main"; remote = $null }
        capabilities = @("governed-codex-execution", "worktree-management", "verification", "execution-facts-producer")
        dependencies = @([ordered]@{ component_id = "atlas"; kind = "contracts"; required = $true })
        protocols = [ordered]@{ atlas_contracts = "v2"; playbook_profile = "operator"; agent_instructions = "AGENTS.md" }
        extensions = [ordered]@{ validation_owner = "atlas-root"; external_authority = "denied" }
    }
    $envelope = [ordered]@{
        contract_version = "atlas.job-envelope.v2"
        job_id = $jobId
        component_id = "stack"
        project_id = $ProjectId
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        objective = [string](Get-ObjectPropertyValue -Object $PromptRecord -Name "Title" -DefaultValue "Governed Atlas task")
        scope = [ordered]@{ owner_repository = "stack"; allowed_paths = @($AllowedPaths); forbidden_paths = @($ForbiddenPaths) }
        runtime = $runtime
        authority = [ordered]@{ external_mutations = @(); production_deploy = $false; destructive_actions = $false }
        verification = [ordered]@{ commands = @($VerificationCommands); evidence_required = @("runner-log", "terminal-receipt") }
        correlations = [ordered]@{ card_id = $CardId; parent_job_id = $ParentJobId }
        expected_receipt_version = "atlas.execution-receipt.v2"
        extensions = [ordered]@{
            run_id = $RunId
            execution_class = $ExecutionClass
            base_ref = $BaseRef
            branch = $Branch
            worktree = $Worktree
            native_thread_id = $env:CODEX_THREAD_ID
            native_turn_id = $env:CODEX_TURN_ID
            local_capability = $runtime.permissions
            external_authority = [ordered]@{ push = "denied"; deploy = "denied"; production = "denied"; discord = "denied"; board = "denied"; data_mutation = "denied" }
        }
    }
    $contextPacket = [ordered]@{
        contract_version = "atlas.context-packet.v2"
        context_id = "atlas-stack-context-$RunId"
        job_id = $jobId
        component_id = "stack"
        assembled_at = (Get-Date).ToUniversalTime().ToString("o")
        sources = @(
            [ordered]@{ kind = "repository"; ref = "AGENTS.md"; authority = "authoritative"; digest = $null },
            [ordered]@{ kind = "receipt"; ref = $paths.componentManifest; authority = "authoritative"; digest = $null },
            [ordered]@{ kind = "receipt"; ref = $paths.jobEnvelope; authority = "authoritative"; digest = $null },
            [ordered]@{ kind = "decision"; ref = "runtime-policy"; authority = "advisory"; digest = $null }
        )
        rules = @(
            "Admit changes only within the governed allowed paths.",
            "Preserve forbidden paths and do not expose secrets.",
            "Do not stage, commit, move Git refs, push, deploy, or mutate external systems."
        )
        decisions = @(
            "Atlas root owns schema validation through the canonical validator.",
            "Local full access is capability only and does not grant external authority."
        )
        risks = @(
            "External mutations remain denied for this job.",
            "Worker Git state transitions must fail closed."
        )
        extensions = [ordered]@{ run_id = $RunId; execution_class = $ExecutionClass; allowed_paths = @($AllowedPaths); forbidden_paths = @($ForbiddenPaths) }
    }
    $approvalRecord = [ordered]@{
        contract_version = "atlas.approval-record.v2"
        approval_id = "atlas-stack-external-mutation-denial-$RunId"
        job_id = $jobId
        recorded_at = (Get-Date).ToUniversalTime().ToString("o")
        actor = "governed-stack-runner"
        action = [ordered]@{ kind = "external-mutation"; target = "external execution surfaces"; scope = "push, deploy, production, discord, board, and data mutation" }
        decision = "rejected"
        expires_at = $null
        constraints = @(
            "No external mutation authority was granted.",
            "Full local access does not grant external authority.",
            "Push remains manual-only."
        )
        extensions = [ordered]@{ component_id = "stack"; run_id = $RunId; external_authority = "denied" }
    }
    Write-TextFile -Path $paths.componentManifest -Content (($component | ConvertTo-Json -Depth 16) + "`r`n")
    Write-TextFile -Path $paths.jobEnvelope -Content (($envelope | ConvertTo-Json -Depth 16) + "`r`n")
    Write-TextFile -Path $paths.contextPacket -Content (($contextPacket | ConvertTo-Json -Depth 16) + "`r`n")
    Write-TextFile -Path $paths.approvalRecord -Content (($approvalRecord | ConvertTo-Json -Depth 16) + "`r`n")
    $componentValidation = Invoke-AtlasContractsV2Validation -Contracts $contracts -SchemaId "atlas.component-manifest.v2" -ArtifactPath $paths.componentManifest -EvidencePath $validationPaths.componentManifest
    Assert-AtlasContractsV2Validation -Validation $componentValidation
    $jobValidation = Invoke-AtlasContractsV2Validation -Contracts $contracts -SchemaId "atlas.job-envelope.v2" -ArtifactPath $paths.jobEnvelope -EvidencePath $validationPaths.jobEnvelope
    Assert-AtlasContractsV2Validation -Validation $jobValidation
    $contextValidation = Invoke-AtlasContractsV2Validation -Contracts $contracts -SchemaId "atlas.context-packet.v2" -ArtifactPath $paths.contextPacket -EvidencePath $validationPaths.contextPacket
    Assert-AtlasContractsV2Validation -Validation $contextValidation
    $approvalValidation = Invoke-AtlasContractsV2Validation -Contracts $contracts -SchemaId "atlas.approval-record.v2" -ArtifactPath $paths.approvalRecord -EvidencePath $validationPaths.approvalRecord
    Assert-AtlasContractsV2Validation -Validation $approvalValidation

    return [pscustomobject]@{
        contracts = $contracts
        paths = $paths
        validationPaths = $validationPaths
        validation = [ordered]@{ componentManifest = $componentValidation; jobEnvelope = $jobValidation; contextPacket = $contextValidation; approvalRecord = $approvalValidation; evidenceBundle = $null }
        componentId = "stack"
        jobId = $jobId
        runId = $RunId
        executionClass = $ExecutionClass
        envelope = $envelope
        preflightValidated = $true
    }
}

function Get-AtlasContractsV2WorkerInstructions {
    param([Parameter(Mandatory = $true)]$Producer)

    if (-not [bool]$Producer.preflightValidated) {
        throw "atlas_contracts_v2_worker_context_requires_validated_preflight"
    }

    return @(
        "Atlas Contracts v2 preflight contract:",
        "- Preflight status: validated.",
        ("- ComponentManifest: `{0}`." -f [string]$Producer.paths.componentManifest),
        ("- JobEnvelope: `{0}`." -f [string]$Producer.paths.jobEnvelope),
        ("- ComponentManifest validation: `{0}`." -f [string]$Producer.validationPaths.componentManifest),
        ("- JobEnvelope validation: `{0}`." -f [string]$Producer.validationPaths.jobEnvelope),
        ("- ContextPacket: `{0}`." -f [string]$Producer.paths.contextPacket),
        ("- ApprovalRecord: `{0}`." -f [string]$Producer.paths.approvalRecord),
        ("- ContextPacket validation: `{0}`." -f [string]$Producer.validationPaths.contextPacket),
        ("- ApprovalRecord validation: `{0}`." -f [string]$Producer.validationPaths.approvalRecord),
        "- These artifacts live in the parent runner log, not necessarily inside the isolated worktree.",
        "- Read the exact paths above when the task requires preflight evidence; do not rediscover them by scanning worktree-local `.codex/logs`."
    ) -join "`r`n"
}

function Write-AtlasContractsV2TerminalReceipt {
    param(
        [Parameter(Mandatory = $true)]$Producer,
        [Parameter(Mandatory = $true)][string]$RunnerStatus,
        [string[]]$ChangedPaths = @(),
        [string]$CommitSha,
        $RuntimePolicy,
        [string[]]$VerificationCommands = @(),
        $VerificationRecords = @(),
        [string]$Branch,
        [string]$Worktree,
        [string]$Reason,
        [string[]]$EvidenceRefs = @()
    )

    $receiptStatus = switch ($RunnerStatus) {
        "success" { "succeeded" }
        "success_no_changes" { "succeeded" }
        "runtime_policy_blocked" { "blocked" }
        "verification_failed" { "failed" }
        "proof_gate_failed" { "failed" }
        "spec_to_diff_failed" { "failed" }
        "mutation_scope_failed" { "failed" }
        "mutation_admission_failed" { "failed" }
        default { "failed" }
    }
    $verification = @($VerificationRecords | ForEach-Object {
        [ordered]@{
            command = [string]$_.command
            status = if ([int]$_.exitCode -eq 0) { "passed" } else { "failed" }
            evidence_refs = @([string]$_.stdoutPath, [string]$_.stderrPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    })
    if ($verification.Count -eq 0) {
        $verification = @([ordered]@{
            command = if ($VerificationCommands.Count -gt 0) { [string]$VerificationCommands[0] } else { "runner terminal state" }
            status = if ($receiptStatus -eq "succeeded") { "passed" } else { "skipped" }
            evidence_refs = @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        })
    }
    $evidence = @($VerificationRecords | ForEach-Object {
        $status = if ([int]$_.exitCode -eq 0) { "passed" } else { "failed" }
        $ref = [string]$_.stdoutPath
        if ([string]::IsNullOrWhiteSpace($ref)) { $ref = [string]$_.command }
        [ordered]@{
            kind = "command"
            ref = $ref
            status = $status
            digest = $null
            summary = ("Terminal verification {0}: {1}" -f $status, [string]$_.command)
        }
    })
    if ($evidence.Count -eq 0) {
        $terminalRef = @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        $evidence = @([ordered]@{
            kind = "source"
            ref = if ($terminalRef.Count -gt 0) { [string]$terminalRef[0] } else { "runner terminal state" }
            status = "unavailable"
            digest = $null
            summary = "No terminal verification record was available."
        })
    }
    [object[]]$evidenceClassifications = if ($VerificationRecords.Count -gt 0) { @("verified") } else { @("unknown") }
    $evidenceBundle = [ordered]@{
        contract_version = "atlas.evidence-bundle.v2"
        bundle_id = "atlas-stack-evidence-$($Producer.runId)"
        job_id = $Producer.jobId
        recorded_at = (Get-Date).ToUniversalTime().ToString("o")
        environment = [ordered]@{ component_id = $Producer.componentId; commit = if ([string]::IsNullOrWhiteSpace($CommitSha)) { $null } else { $CommitSha }; branch = if ([string]::IsNullOrWhiteSpace($Branch)) { $null } else { $Branch } }
        evidence = $evidence
        classifications = [object[]]$evidenceClassifications
        extensions = [ordered]@{ run_id = $Producer.runId; runner_status = $RunnerStatus; worktree = $Worktree }
    }
    Write-TextFile -Path $Producer.paths.evidenceBundle -Content (($evidenceBundle | ConvertTo-Json -Depth 16) + "`r`n")
    $evidenceValidation = Invoke-AtlasContractsV2Validation -Contracts $Producer.contracts -SchemaId "atlas.evidence-bundle.v2" -ArtifactPath $Producer.paths.evidenceBundle -EvidencePath $Producer.validationPaths.evidenceBundle
    Assert-AtlasContractsV2Validation -Validation $evidenceValidation
    $Producer.validation.evidenceBundle = $evidenceValidation
    $commitList = [object[]]@()
    if (-not [string]::IsNullOrWhiteSpace($CommitSha)) { $commitList = [object[]]@($CommitSha) }
    $blockerList = [object[]]@()
    if ($receiptStatus -ne "succeeded") {
        if ([string]::IsNullOrWhiteSpace($Reason)) { $blockerList = [object[]]@($RunnerStatus) }
        else { $blockerList = [object[]]@($Reason) }
    }
    $receipt = [ordered]@{
        contract_version = "atlas.execution-receipt.v2"
        receipt_id = "atlas-stack-receipt-$($Producer.runId)"
        job_id = $Producer.jobId
        recorded_at = (Get-Date).ToUniversalTime().ToString("o")
        status = $receiptStatus
        component_id = $Producer.componentId
        project_id = "atlas"
        runtime_effective = ConvertTo-AtlasContractsV2Runtime -RuntimePolicy $RuntimePolicy
        changed_paths = @($ChangedPaths)
        commits = $commitList
        verification = $verification
        evidence_refs = @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) + @($Producer.paths.contextPacket, $Producer.paths.approvalRecord, $Producer.paths.evidenceBundle, $Producer.validationPaths.contextPacket, $Producer.validationPaths.approvalRecord, $Producer.validationPaths.evidenceBundle)
        blockers = $blockerList
        follow_up = @()
        correlations = [ordered]@{ card_id = $Producer.envelope.correlations.card_id; thread_id = $env:CODEX_THREAD_ID; turn_id = $env:CODEX_TURN_ID; branch = $Branch; worktree = $Worktree }
        authority_actions = @()
        summary = if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { $Reason }
        extensions = [ordered]@{
            runner_status = $RunnerStatus
            validation_owner = "atlas-root"
            artifact_refs = [ordered]@{ context_packet = $Producer.paths.contextPacket; approval_record = $Producer.paths.approvalRecord; evidence_bundle = $Producer.paths.evidenceBundle }
            validation_evidence_refs = @($Producer.validationPaths.componentManifest, $Producer.validationPaths.jobEnvelope, $Producer.validationPaths.contextPacket, $Producer.validationPaths.approvalRecord, $Producer.validationPaths.evidenceBundle)
            external_authority = [ordered]@{ push = "not-exercised"; deploy = "not-exercised"; production = "not-exercised"; discord = "not-exercised"; board = "not-exercised"; data_mutation = "not-exercised" }
        }
    }
    Write-TextFile -Path $Producer.paths.executionReceipt -Content (($receipt | ConvertTo-Json -Depth 16) + "`r`n")
    return Invoke-AtlasContractsV2Validation -Contracts $Producer.contracts -SchemaId "atlas.execution-receipt.v2" -ArtifactPath $Producer.paths.executionReceipt -EvidencePath $Producer.validationPaths.executionReceipt
}
