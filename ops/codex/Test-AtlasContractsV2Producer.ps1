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

try {
    $producerSource = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "AtlasContractsV2Producer.ps1") -Raw
    Assert-Condition -Condition $producerSource.Contains("scripts\validate-artifact.mjs") -Message "Producer must invoke the Atlas-owned validate-artifact.mjs CLI."
    Assert-Condition -Condition (-not $producerSource.Contains("Validate-AtlasContractsV2Artifact.mjs")) -Message "Owner-side generic validator launcher must not be present."
    Assert-Condition -Condition (-not $producerSource.Contains("validate-json-schema.mjs")) -Message "Producer must not import or copy the Atlas validator engine."
    Assert-Condition -Condition (-not (Test-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "Validate-AtlasContractsV2Artifact.mjs"))) -Message "Discarded owner-side validator file must not exist."

    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $runtimePolicy = [pscustomobject]@{
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

    $producer = New-AtlasContractsV2Producer `
        -AtlasRoot $atlasRoot `
        -LogDirectory $temporaryRoot `
        -RunId "fixture-run" `
        -PromptRecord $prompt `
        -RuntimePolicy $runtimePolicy `
        -ExecutionClass "codex:repo:task" `
        -Branch "codex/fixture" `
        -Worktree "fixture-worktree" `
        -AllowedPaths @("ops/**") `
        -ForbiddenPaths @("runtime/**") `
        -VerificationCommands @("git diff --check")
    Assert-Condition -Condition $producer.preflightValidated -Message "ComponentManifest and JobEnvelope must validate before execution."
    foreach ($artifactName in @("componentManifest", "jobEnvelope")) {
        $path = [string]$producer.paths.$artifactName
        Assert-Condition -Condition (Test-Path -LiteralPath $path) -Message "Producer did not write required preflight artifact path: $path"
    }
    foreach ($validation in @($producer.validation.componentManifest, $producer.validation.jobEnvelope)) {
        Assert-Condition -Condition $validation.ok -Message "Atlas validator did not accept preflight artifact."
        Assert-Condition -Condition ($validation.cliPath -eq (Join-Path $atlasRoot "packages\atlas-contracts\scripts\validate-artifact.mjs")) -Message "Producer did not invoke the canonical Atlas validator path."
    }
    $workerInstructions = Get-AtlasContractsV2WorkerInstructions -Producer $producer
    Assert-Condition -Condition $workerInstructions.Contains([string]$producer.paths.componentManifest) -Message "Worker context must expose the exact ComponentManifest path."
    Assert-Condition -Condition $workerInstructions.Contains([string]$producer.paths.jobEnvelope) -Message "Worker context must expose the exact JobEnvelope path."
    Assert-Condition -Condition $workerInstructions.Contains("parent runner log") -Message "Worker context must explain the worktree visibility boundary."
    $envelope = Get-Content -LiteralPath $producer.paths.jobEnvelope -Raw | ConvertFrom-Json
    foreach ($authorityName in @("push", "deploy", "production", "discord", "board", "data_mutation")) {
        Assert-Condition -Condition ([string]$envelope.extensions.external_authority.$authorityName -eq "denied") -Message "External authority '$authorityName' must default to denied even with full local access."
    }

    $unknownMajor = Invoke-AtlasContractsV2Validation -Contracts $producer.contracts -SchemaId "atlas.component-manifest.v99" -ArtifactPath $producer.paths.componentManifest -EvidencePath (Join-Path $temporaryRoot "unknown-major.validation.json")
    Assert-Condition -Condition (-not $unknownMajor.ok) -Message "Unknown contract major must be rejected."
    Assert-Condition -Condition ($unknownMajor.reasonCode -eq "atlas_contracts_v2_validator_unsupported_contract_version") -Message "Unknown contract major must preserve the stable _stack reason code."
    Assert-Condition -Condition ([string]$unknownMajor.result.code -eq "UNSUPPORTED_CONTRACT_VERSION") -Message "Unknown contract major must retain the Atlas CLI JSON result."

    $successReceipt = Write-AtlasContractsV2TerminalReceipt -Producer $producer -RunnerStatus "success" -RuntimePolicy $runtimePolicy -VerificationCommands @("git diff --check") -Branch "codex/fixture" -Worktree "fixture-worktree" -EvidenceRefs @("fixture.log")
    Assert-Condition -Condition $successReceipt.ok -Message "Successful terminal receipt must validate through Atlas CLI."
    $failedReceipt = Write-AtlasContractsV2TerminalReceipt -Producer $producer -RunnerStatus "codex_failed" -RuntimePolicy $runtimePolicy -VerificationCommands @("git diff --check") -Branch "codex/fixture" -Worktree "fixture-worktree" -Reason "fixture failure" -EvidenceRefs @("fixture.log")
    Assert-Condition -Condition $failedReceipt.ok -Message "Non-success terminal receipt must validate through Atlas CLI."
    Assert-Condition -Condition (Test-Path -LiteralPath $producer.paths.executionReceipt) -Message "Producer did not write the required terminal ExecutionReceipt artifact."
    $receipt = Get-Content -LiteralPath $producer.paths.executionReceipt -Raw | ConvertFrom-Json
    Assert-Condition -Condition ([string]$receipt.status -eq "failed") -Message "Non-success runner state must produce a failed ExecutionReceipt."
    Assert-Condition -Condition (@($receipt.authority_actions).Count -eq 0) -Message "Producer must not claim external authority actions."

    Write-Output "Atlas Contracts v2 producer tests passed."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
