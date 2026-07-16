Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "CodexRunner.Common.ps1")
. (Join-Path $PSScriptRoot "StackInboxSweep.ps1")
$taskBeforeInstallDotSource = Get-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\" -ErrorAction SilentlyContinue
$taskXmlBeforeInstallDotSource = if ($null -ne $taskBeforeInstallDotSource) { Export-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\" } else { $null }
. (Join-Path $PSScriptRoot "Install-StackInboxSweepTask.ps1")
$taskAfterInstallDotSource = Get-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\" -ErrorAction SilentlyContinue
$taskXmlAfterInstallDotSource = if ($null -ne $taskAfterInstallDotSource) { Export-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\" } else { $null }
if (($null -eq $taskBeforeInstallDotSource) -ne ($null -eq $taskAfterInstallDotSource) -or $taskXmlBeforeInstallDotSource -ne $taskXmlAfterInstallDotSource) {
    throw "Dot-sourcing the task installer registered or modified AtlasStackInboxSweep."
}

function Assert-Sweep {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestRoot {
    param([string]$Name)
    $path = Join-Path $env:TEMP ("stack-inbox-{0}-{1}" -f $Name, ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Write-TestPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Owner = "stack",
        [string]$AcceptedAt = "",
        [string]$IdempotencyKey = "test.idempotency",
        [string]$JobId = "test-job",
        [string]$Body = "# Synthetic no-change fixture",
        [string[]]$AdditionalHeaders = @()
    )
    if ([string]::IsNullOrWhiteSpace($AcceptedAt)) { $AcceptedAt = [DateTimeOffset]::UtcNow.ToString("o") }
    $headers = @(
        "Inbox Contract: atlas.stack.inbox.v1",
        "Inbox Owner: $Owner",
        "Accepted At: $AcceptedAt",
        "Idempotency Key: $IdempotencyKey",
        "Job ID: $JobId"
    ) + @($AdditionalHeaders)
    [System.IO.File]::WriteAllText($Path, (($headers -join "`r`n") + "`r`n`r`n$Body`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    (Get-Item -LiteralPath $Path).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-5)
}

function New-FakeRepoTaskScript {
    param([Parameter(Mandatory = $true)][string]$Root)
    $path = Join-Path $Root "fake-repo-task.ps1"
    $content = @'
param(
    [Parameter(Mandatory = $true)][string]$PromptPath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [switch]$SkipPromptArchive,
    [string]$ConfigPath = "",
    [string]$RepoRoot = "",
    [string]$AdapterPath = "",
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$Remaining
)
$ErrorActionPreference = "Stop"
$providedRuntimePaths = @(@($ConfigPath, $RepoRoot, $AdapterPath) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
if ($providedRuntimePaths.Count -notin @(0, 3)) { throw "Runtime path arguments must retain their values." }
if ($providedRuntimePaths.Count -eq 3 -and ([IO.Path]::GetFileName($ConfigPath) -ne "config.toml" -or [IO.Path]::GetFileName($RepoRoot) -ne "repo" -or [IO.Path]::GetFileName($AdapterPath) -ne "adapter.json")) { throw "Runtime path argument names and values were not paired exactly." }
if ($providedRuntimePaths.Count -eq 3 -and ($ConfigPath -ne $env:ATLAS_INBOX_CONFIG_PATH -or $RepoRoot -ne $env:ATLAS_INBOX_REPO_ROOT -or $AdapterPath -ne $env:ATLAS_INBOX_ADAPTER_PATH)) { throw "Scheduled runtime path environment bindings did not match the child arguments." }
$runId = "fake-" + [guid]::NewGuid().ToString("N")
$artifactRoot = Join-Path (Split-Path -Parent $ResultPath) "fake-contracts"
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
$jobPath = Join-Path $artifactRoot "atlas.job-envelope.v2.json"
$leasePath = Join-Path $artifactRoot "atlas.worker-lease.v2.json"
$receiptPath = Join-Path $artifactRoot "atlas.execution-receipt.v2.json"
$jobId = "atlas-stack-$runId"
$leaseId = "atlas-stack-lease-$runId"
$job = [ordered]@{ contract_version = "atlas.job-envelope.v2"; job_id = $jobId; extensions = [ordered]@{ run_id = $runId; inbox = [ordered]@{ sweep_id = $env:ATLAS_INBOX_SWEEP_ID; correlation_id = $env:ATLAS_INBOX_SWEEP_CORRELATION_ID; idempotency_key = $env:ATLAS_INBOX_IDEMPOTENCY_KEY; inbox_job_id = $env:ATLAS_INBOX_JOB_ID } } }
$lease = [ordered]@{ contract_version = "atlas.worker-lease.v2"; lease_id = $leaseId; job_id = $jobId; status = "released" }
$receipt = [ordered]@{ contract_version = "atlas.execution-receipt.v2"; receipt_id = "atlas-stack-receipt-$runId"; job_id = $jobId; status = "succeeded"; extensions = [ordered]@{ run_id = $runId; worker_lease_binding = [ordered]@{ lease_id = $leaseId; status = "released" } } }
[IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 8))
[IO.File]::WriteAllText($leasePath, ($lease | ConvertTo-Json -Depth 8))
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 8))
$counter = 0
if (Test-Path -LiteralPath $env:STACK_INBOX_FAKE_COUNTER) { $counter = [int](Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw) }
[IO.File]::WriteAllText($env:STACK_INBOX_FAKE_COUNTER, [string]($counter + 1))
$result = [ordered]@{ contract_version = "atlas.stack.repo-task-result.v1"; run_id = $runId; status = "success_no_changes"; exit_code = 0; sweep_id = $env:ATLAS_INBOX_SWEEP_ID; sweep_correlation_id = $env:ATLAS_INBOX_SWEEP_CORRELATION_ID; atlas_contracts_v2 = [ordered]@{ job_envelope = $jobPath; worker_lease = $leasePath; execution_receipt = $receiptPath }; runtime_policy = [ordered]@{ resolved = [ordered]@{ model = "gpt-5.6-sol"; reasoning = "xhigh"; permissions = [ordered]@{ mode = "full-access"; profile = ":danger-full-access" }; sandbox_mode = $null; approval = "never"; web_search = "live" } } }
[IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Depth 12))
$noiseLine = "N" * 2048
for ($index = 0; $index -lt 512; $index += 1) { Write-Output ("stdout-{0:D4}-{1}" -f $index, $noiseLine) }
for ($index = 0; $index -lt 32; $index += 1) { [Console]::Error.WriteLine(("stderr-{0:D4}" -f $index)) }
exit 0
'@
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Invoke-TestSweep {
    param([string]$Inbox, [string]$State, [string]$TaskScript, [int]$SettleSeconds = 0, [int]$FreshnessMinutes = 30, [string]$ConfigPath = "", [string]$RepoRoot = "", [string]$AdapterPath = "")
    $powershellExe = Join-Path $PSHOME "powershell.exe"
    return Invoke-StackInboxRunOnceSweep -InboxDirectory $Inbox -StateRoot $State -TaskScriptPath $TaskScript -PowerShellExecutable $powershellExe -SettleSeconds $SettleSeconds -FreshnessMinutes $FreshnessMinutes -ConfigPath $ConfigPath -RepoRoot $RepoRoot -AdapterPath $AdapterPath
}

$roots = New-Object System.Collections.Generic.List[string]
try {
    $lifecycleRoot = New-TestRoot -Name "lifecycle"
    [void]$roots.Add($lifecycleRoot)
    $inbox = Join-Path $lifecycleRoot "inbox"
    $state = Join-Path $lifecycleRoot "state"
    New-Item -ItemType Directory -Path $inbox | Out-Null
    $fakeTask = New-FakeRepoTaskScript -Root $lifecycleRoot
    $env:STACK_INBOX_FAKE_COUNTER = Join-Path $lifecycleRoot "fake-counter.txt"
    $prompt = Join-Path $inbox "synthetic.md"
    Write-TestPrompt -Path $prompt -IdempotencyKey "synthetic.once" -JobId "synthetic-job" -Body "# Synthetic safe no-change fixture"
    $first = Invoke-TestSweep -Inbox $inbox -State $state -TaskScript $fakeTask -ConfigPath (Join-Path $lifecycleRoot "config.toml") -RepoRoot (Join-Path $lifecycleRoot "repo") -AdapterPath (Join-Path $lifecycleRoot "adapter.json")
    Assert-Sweep (@($first).Count -eq 1) "Noisy child output contaminated the structured sweep result stream."
    $firstFailureDiagnostics = [ordered]@{
        exit_code = $first.exit_code
        status = $first.status
        reason_code = $first.reason_code
        counts = $first.counts
        terminal_records = @($first.terminal_records | ForEach-Object {
            $correlationValidation = Get-StackInboxObjectValue -Object $_ -Name "correlation_validation" -DefaultValue $null
            [ordered]@{
                disposition = Get-StackInboxObjectValue -Object $_ -Name "disposition" -DefaultValue $null
                reason_code = Get-StackInboxObjectValue -Object $_ -Name "reason_code" -DefaultValue $null
                task_exit_code = Get-StackInboxObjectValue -Object $_ -Name "task_exit_code" -DefaultValue $null
                runner_status = Get-StackInboxObjectValue -Object $_ -Name "runner_status" -DefaultValue $null
                correlation_reason_code = if ($null -eq $correlationValidation) { $null } else { Get-StackInboxObjectValue -Object $correlationValidation -Name "reason_code" -DefaultValue $null }
                task_output = Get-StackInboxObjectValue -Object $_ -Name "task_output" -DefaultValue $null
            }
        })
        claims = @(Get-ChildItem -LiteralPath (Join-Path $state "processing") -Filter claim.json -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $claimRecord = Read-StackInboxJson -Path $_.FullName
            [ordered]@{
                state = Get-StackInboxObjectValue -Object $claimRecord -Name "state" -DefaultValue $null
                execution_started_at = Get-StackInboxObjectValue -Object $claimRecord -Name "execution_started_at" -DefaultValue $null
                result_exists = Test-Path -LiteralPath ([string](Get-StackInboxObjectValue -Object $claimRecord -Name "result_path" -DefaultValue "")) -PathType Leaf
                prompt_exists = Test-Path -LiteralPath ([string](Get-StackInboxObjectValue -Object $claimRecord -Name "prompt_path" -DefaultValue "")) -PathType Leaf
                task_output = Get-StackInboxObjectValue -Object $claimRecord -Name "task_output" -DefaultValue $null
            }
        })
    }
    Assert-Sweep ($first.exit_code -eq 0 -and $first.counts.claimed -eq 1 -and $first.counts.executed -eq 1 -and $first.counts.archived -eq 1) ("RunOnce did not perform exactly one claim, execution, and archive. diagnostics={0}" -f ($firstFailureDiagnostics | ConvertTo-Json -Depth 8 -Compress))
    Assert-Sweep (-not (Test-Path -LiteralPath $prompt)) "Atomic claim did not remove the admitted source from inbox."
    Assert-Sweep ((Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw) -eq "1") "Synthetic task executed an unexpected number of times."
    $firstTerminal = @($first.terminal_records)[0]
    Assert-Sweep ([bool]$firstTerminal.task_output.stdout.exists -and [long]$firstTerminal.task_output.stdout.bytes -gt 1048576 -and [long]$firstTerminal.task_output.stdout.line_count -eq 512) "Noisy stdout was not streamed to a durable claim-owned log with compact metadata."
    Assert-Sweep ([bool]$firstTerminal.task_output.stderr.exists -and [long]$firstTerminal.task_output.stderr.bytes -gt 0 -and [long]$firstTerminal.task_output.stderr.line_count -ge 32) "Noisy stderr was not streamed to a durable claim-owned log with compact metadata."
    Assert-Sweep ([string]$firstTerminal.task_output.stdout.sha256 -match '^[0-9a-f]{64}$' -and [string]$firstTerminal.task_output.stderr.sha256 -match '^[0-9a-f]{64}$') "Child output logs did not receive deterministic content hashes."
    Assert-Sweep (($firstTerminal.task_output | ConvertTo-Json -Depth 8).Length -lt 4096) "Child output metadata included an unbounded transcript payload."
    Assert-Sweep ([bool]$firstTerminal.correlation_validation.ok) "JobEnvelope, WorkerLease, and ExecutionReceipt were not correlated."
    Assert-Sweep ([string]$firstTerminal.atlas_contracts_v2.receipt_status -eq "succeeded" -and [string]$firstTerminal.atlas_contracts_v2.lease_status -eq "released") "Contracts v2 terminal state was not accepted."

    $bindingRoot = Join-Path $lifecycleRoot "binding"
    $bindingResolved = Resolve-ScheduledInboxRuntimePath -Name "repo_root" -ArgumentValue "" -EnvironmentValue $bindingRoot -SweepId "binding-sweep"
    Assert-Sweep ($bindingResolved -eq [IO.Path]::GetFullPath($bindingRoot)) "Scheduled runtime path did not resolve from the correlated environment binding."
    try { $null = Resolve-ScheduledInboxRuntimePath -Name "repo_root" -ArgumentValue (Join-Path $lifecycleRoot "other") -EnvironmentValue $bindingRoot -SweepId "binding-sweep"; throw "Mismatched scheduled runtime binding was accepted." }
    catch { if ($_.Exception.Message -notmatch "scheduled_inbox_runtime_binding_mismatch") { throw } }

    Copy-Item -LiteralPath $firstTerminal.prompt_path -Destination $prompt
    (Get-Item -LiteralPath $prompt).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-5)
    $replay = Invoke-TestSweep -Inbox $inbox -State $state -TaskScript $fakeTask
    Assert-Sweep ($replay.counts.replay_rejected -eq 1 -and $replay.counts.executed -eq 0 -and $replay.counts.quarantined -eq 1) "Content-hash replay was not terminally rejected."
    Assert-Sweep ((Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw) -eq "1") "Replay rejection still executed the task."

    $duplicate = Join-Path $inbox "duplicate-idempotency.md"
    Write-TestPrompt -Path $duplicate -IdempotencyKey "synthetic.once" -JobId "synthetic-job-2" -Body "# Different bytes, duplicate idempotency key"
    $duplicateResult = Invoke-TestSweep -Inbox $inbox -State $state -TaskScript $fakeTask
    Assert-Sweep ($duplicateResult.counts.replay_rejected -eq 1 -and $duplicateResult.counts.executed -eq 0) "Duplicate idempotency key was not rejected."

    $unsettledRoot = New-TestRoot -Name "unsettled"
    [void]$roots.Add($unsettledRoot)
    $unsettledInbox = Join-Path $unsettledRoot "inbox"
    New-Item -ItemType Directory -Path $unsettledInbox | Out-Null
    $unsettledPrompt = Join-Path $unsettledInbox "unsettled.md"
    Write-TestPrompt -Path $unsettledPrompt -IdempotencyKey "unsettled.one" -JobId "unsettled-job"
    (Get-Item -LiteralPath $unsettledPrompt).LastWriteTimeUtc = [DateTime]::UtcNow
    $unsettledResult = Invoke-TestSweep -Inbox $unsettledInbox -State (Join-Path $unsettledRoot "state") -TaskScript $fakeTask -SettleSeconds 60
    Assert-Sweep ($unsettledResult.counts.unsettled -eq 1 -and (Test-Path -LiteralPath $unsettledPrompt)) "Unsettled prompt was not left in place."

    $admissionRoot = New-TestRoot -Name "admission"
    [void]$roots.Add($admissionRoot)
    $admissionInbox = Join-Path $admissionRoot "inbox"
    New-Item -ItemType Directory -Path $admissionInbox | Out-Null
    Write-TestPrompt -Path (Join-Path $admissionInbox "stale.md") -AcceptedAt "2026-04-08T00:00:00.0000000Z" -IdempotencyKey "stale.one" -JobId "stale-job"
    Write-TestPrompt -Path (Join-Path $admissionInbox "foreign.md") -Owner "another-owner" -IdempotencyKey "foreign.one" -JobId "foreign-job"
    Write-TestPrompt -Path (Join-Path $admissionInbox "mixed-policy.md") -IdempotencyKey "mixed.one" -JobId "mixed-job" -AdditionalHeaders @("Runtime Permission Profile: :danger-full-access", "Runtime Sandbox Mode: danger-full-access")
    $admissionResult = Invoke-TestSweep -Inbox $admissionInbox -State (Join-Path $admissionRoot "state") -TaskScript $fakeTask
    Assert-Sweep ($admissionResult.counts.quarantined -eq 2 -and $admissionResult.counts.left_in_place -eq 1 -and $admissionResult.counts.executed -eq 0) "Stale, malformed, or foreign admission did not fail closed."
    Assert-Sweep (Test-Path -LiteralPath (Join-Path $admissionInbox "foreign.md")) "Foreign prompt was moved without ownership evidence."

    $crashRoot = New-TestRoot -Name "crash-recovery"
    [void]$roots.Add($crashRoot)
    $crashInbox = Join-Path $crashRoot "inbox"
    $crashState = Join-Path $crashRoot "state"
    New-Item -ItemType Directory -Path $crashInbox | Out-Null
    Initialize-StackInboxStateDirectories -StateRoot $crashState
    $crashPrompt = Join-Path $crashInbox "recoverable.md"
    Write-TestPrompt -Path $crashPrompt -IdempotencyKey "crash.recoverable" -JobId "crash-recoverable-job"
    $crashAdmission = Test-StackInboxAdmission -Path $crashPrompt
    $deadOwner = [pscustomobject]@{ pid = 2147483646; process_start_time_utc = "2000-01-01T00:00:00.0000000Z" }
    $crashClaim = New-StackInboxClaim -PromptPath $crashPrompt -StateRoot $crashState -TaskName "AtlasStackInboxSweep" -SweepId "crashed-sweep" -CorrelationId "crashed-correlation" -Admission $crashAdmission -Owner $deadOwner
    $beforeCrashCount = [int](Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw)
    $recovered = Invoke-TestSweep -Inbox $crashInbox -State $crashState -TaskScript $fakeTask
    Assert-Sweep ($recovered.counts.recovered -eq 1 -and $recovered.counts.executed -eq 1 -and $recovered.counts.archived -eq 1) "A pre-execution crash claim was not safely recovered."
    Assert-Sweep ([int](Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw) -eq ($beforeCrashCount + 1)) "Recoverable claim did not execute exactly once."

    $ambiguousPrompt = Join-Path $crashInbox "ambiguous.md"
    Write-TestPrompt -Path $ambiguousPrompt -IdempotencyKey "crash.ambiguous" -JobId "crash-ambiguous-job"
    $ambiguousAdmission = Test-StackInboxAdmission -Path $ambiguousPrompt
    $ambiguousClaim = New-StackInboxClaim -PromptPath $ambiguousPrompt -StateRoot $crashState -TaskName "AtlasStackInboxSweep" -SweepId "crashed-after-start" -CorrelationId "crashed-after-start-correlation" -Admission $ambiguousAdmission -Owner $deadOwner
    $ambiguousClaim.record.execution_started_at = "2026-07-16T00:00:00.0000000Z"
    $ambiguousClaim.record.state = "executing"
    Write-StackInboxJsonAtomic -Path $ambiguousClaim.claim_path -Value $ambiguousClaim.record
    $beforeAmbiguous = [int](Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw)
    $ambiguousResult = Invoke-TestSweep -Inbox $crashInbox -State $crashState -TaskScript $fakeTask
    Assert-Sweep ($ambiguousResult.counts.executed -eq 0 -and $ambiguousResult.counts.quarantined -eq 1) "Crash after execution start was not quarantined without replay."
    Assert-Sweep ([int](Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw) -eq $beforeAmbiguous) "Ambiguous post-start claim replayed."

    $preparedPrompt = Join-Path $crashInbox "prepared-before-move.md"
    Write-TestPrompt -Path $preparedPrompt -IdempotencyKey "crash.prepared-before-move" -JobId "crash-prepared-before-move-job"
    $preparedAdmission = Test-StackInboxAdmission -Path $preparedPrompt
    $preparedClaim = New-StackInboxClaim -PromptPath $preparedPrompt -StateRoot $crashState -TaskName "AtlasStackInboxSweep" -SweepId "crashed-before-move" -CorrelationId "crashed-before-move-correlation" -Admission $preparedAdmission -Owner $deadOwner
    Move-Item -LiteralPath $preparedClaim.prompt_path -Destination $preparedPrompt
    $preparedClaim.record.state = "prepared"
    $preparedClaim.record.claimed_at = $null
    Write-StackInboxJsonAtomic -Path $preparedClaim.claim_path -Value $preparedClaim.record
    $beforePreparedRecovery = [int](Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw)
    $preparedRecoveryResult = Invoke-TestSweep -Inbox $crashInbox -State $crashState -TaskScript $fakeTask
    Assert-Sweep ($preparedRecoveryResult.counts.pre_move_recovered -eq 1 -and $preparedRecoveryResult.counts.executed -eq 1 -and $preparedRecoveryResult.counts.archived -eq 1 -and $preparedRecoveryResult.counts.replay_rejected -eq 0) ("An interrupted prepared claim did not restore the exact intact source to normal admission: {0}" -f ($preparedRecoveryResult.counts | ConvertTo-Json -Compress))
    Assert-Sweep ([int](Get-Content -LiteralPath $env:STACK_INBOX_FAKE_COUNTER -Raw) -eq ($beforePreparedRecovery + 1)) "Recovered pre-move source did not execute exactly once."
    Assert-Sweep (-not (Test-Path -LiteralPath $preparedClaim.directory)) "Recovered pre-move orphan remained in active processing."
    $preparedHistoryRecords = @(Get-ChildItem -LiteralPath (Join-Path $crashState "claim-history") -Filter claim.json -File -Recurse | ForEach-Object { Read-StackInboxJson -Path $_.FullName } | Where-Object { [string]$_.claim_id -eq [string]$preparedClaim.record.claim_id })
    Assert-Sweep ($preparedHistoryRecords.Count -eq 1 -and [string]$preparedHistoryRecords[0].state -eq "abandoned_before_source_move") "Recovered pre-move claim was not retired with durable evidence."

    $leaseRoot = New-TestRoot -Name "lease"
    [void]$roots.Add($leaseRoot)
    $leaseState = Join-Path $leaseRoot "state"
    $firstLease = Enter-StackInboxSweepLease -StateRoot $leaseState -TaskName "AtlasStackInboxSweep" -SweepId "live-one" -CorrelationId "live-correlation"
    $overlapLease = Enter-StackInboxSweepLease -StateRoot $leaseState -TaskName "AtlasStackInboxSweep" -SweepId "live-two" -CorrelationId "live-correlation-two"
    Assert-Sweep (-not [bool]$overlapLease.acquired -and [string]$overlapLease.reason_code -eq "live_sweep_owner") "Application overlap lease did not reject a live owner."
    $firstLease.context.lease.owner = $deadOwner
    Write-StackInboxJsonAtomic -Path $firstLease.context.lease_path -Value $firstLease.context.lease
    $takeoverLease = Enter-StackInboxSweepLease -StateRoot $leaseState -TaskName "AtlasStackInboxSweep" -SweepId "stale-takeover" -CorrelationId "stale-correlation"
    Assert-Sweep ([bool]$takeoverLease.acquired -and [bool]$takeoverLease.stale_owner_diagnosis.conclusive) "Conclusive stale-owner takeover failed."
    $null = Exit-StackInboxSweepLease -LeaseContext $takeoverLease.context
    Assert-Sweep (-not (Test-Path -LiteralPath (Join-Path $leaseState "lease.lock"))) "Lease residue remained after release."

    $unknownState = Join-Path $leaseRoot "unknown-state"
    Initialize-StackInboxStateDirectories -StateRoot $unknownState
    New-Item -ItemType Directory -Path (Join-Path $unknownState "lease.lock") | Out-Null
    Write-StackInboxJsonAtomic -Path (Join-Path $unknownState "lease.lock\lease.json") -Value ([ordered]@{ owner = [ordered]@{ pid = $PID; process_start_time_utc = "not-a-time" }; sweep_id = "unknown-owner" })
    $unknownTakeover = Enter-StackInboxSweepLease -StateRoot $unknownState -TaskName "AtlasStackInboxSweep" -SweepId "must-not-take-over" -CorrelationId "unknown-correlation"
    Assert-Sweep (-not [bool]$unknownTakeover.acquired -and [string]$unknownTakeover.reason_code -eq "stale_owner_not_conclusive") "Unknown stale-owner evidence did not fail closed."

    $xmlRoot = New-TestRoot -Name "task-xml"
    [void]$roots.Add($xmlRoot)
    $launcherPath = Join-Path $xmlRoot "runtime\codex\stack\launcher\current\Invoke-StackInboxSweepLauncher.ps1"
    $workingDirectory = Split-Path -Parent $launcherPath
    $xmlText = New-StackInboxSweepTaskXml -UserSid "S-1-5-21-1000" -Author "fixture-user" -PowerShellExecutable (Join-Path $PSHOME "powershell.exe") -LauncherPath $launcherPath -WorkingDirectory $workingDirectory -Enabled $false
    [xml]$xml = $xmlText
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")
    Assert-Sweep ($xml.SelectNodes("/t:Task/t:Actions/t:Exec", $ns).Count -eq 1) "Task XML must contain exactly one action."
    Assert-Sweep ($xml.SelectSingleNode("/t:Task/t:Triggers/t:CalendarTrigger/t:Repetition/t:Interval", $ns).InnerText -eq "PT5M") "Task cadence is not five minutes."
    Assert-Sweep ($xml.SelectSingleNode("/t:Task/t:Principals/t:Principal/t:LogonType", $ns).InnerText -eq "InteractiveToken" -and $xml.SelectSingleNode("/t:Task/t:Principals/t:Principal/t:RunLevel", $ns).InnerText -eq "LeastPrivilege") "Task principal is not limited current-user interactive."
    Assert-Sweep ($xml.SelectSingleNode("/t:Task/t:Settings/t:MultipleInstancesPolicy", $ns).InnerText -eq "IgnoreNew") "Task scheduler overlap policy is not IgnoreNew."
    Assert-Sweep ($xml.SelectSingleNode("/t:Task/t:Settings/t:Enabled", $ns).InnerText -eq "false") "Task must install disabled before proof."
    $arguments = $xml.SelectSingleNode("/t:Task/t:Actions/t:Exec/t:Arguments", $ns).InnerText
    Assert-Sweep ($arguments -notmatch '(?i)[\\/]\.codex[\\/]worktrees[\\/]' -and $arguments -notmatch '(?i)[\\/]runtime[\\/]codex[\\/]worktrees[\\/]') "Task action contains a linked or disposable worktree path."

    $snapshotRoot = New-TestRoot -Name "snapshot"
    [void]$roots.Add($snapshotRoot)
    $sourceRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $snapshot = Invoke-StackInboxSweepTaskInstall -RequestedAtlasRoot $snapshotRoot -RequestedSourceRepoRoot $sourceRepoRoot -TaskEnabled $false -LauncherOnly $true
    Assert-Sweep ([string]$snapshot.launcher.manifest_sha256 -match '^[0-9a-f]{64}$' -and $snapshot.launcher.file_count -eq 10) "Stable launcher snapshot manifest was not produced."
    Assert-Sweep ([string]$snapshot.launcher.launcher_path -notlike "*$sourceRepoRoot*") "Stable launcher is coupled to the source worktree."
    $snapshotManifest = Get-Content -LiteralPath $snapshot.launcher.manifest_path -Raw | ConvertFrom-Json
    Assert-Sweep ([string]$snapshotManifest.source_revision -eq (& git -C $sourceRepoRoot rev-parse HEAD).Trim() -and @($snapshotManifest.files).Count -eq 10) "Launcher manifest did not bind every installed file to the source revision."
    Assert-Sweep (@($snapshotManifest.files | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.source_path) -or $null -eq $_.source_matches_revision }).Count -eq 0) "Launcher manifest omitted per-file committed-head evidence."

    $ciRegistrationRoot = New-TestRoot -Name "ci-registration-guard"
    [void]$roots.Add($ciRegistrationRoot)
    $priorGithubActions = $env:GITHUB_ACTIONS
    try {
        $env:GITHUB_ACTIONS = "true"
        try {
            $null = Invoke-StackInboxSweepTaskInstall -RequestedAtlasRoot $ciRegistrationRoot -RequestedSourceRepoRoot $sourceRepoRoot -TaskEnabled $false -LauncherOnly $false
            throw "CI task registration was accepted."
        }
        catch {
            if ($_.Exception.Message -notmatch "stack_inbox_task_registration_forbidden_in_ci") { throw }
        }
    }
    finally {
        if ($null -eq $priorGithubActions) { Remove-Item Env:\GITHUB_ACTIONS -ErrorAction SilentlyContinue }
        else { $env:GITHUB_ACTIONS = $priorGithubActions }
    }
    Assert-Sweep (-not (Test-Path -LiteralPath (Join-Path $ciRegistrationRoot "runtime"))) "CI registration guard wrote launcher or scheduler state before rejecting."

    Add-Content -LiteralPath (Join-Path $snapshot.launcher.launcher_path "ops\codex\StackInboxSweep.ps1") -Value "# tamper"
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & (Join-Path $PSHOME "powershell.exe") -NoProfile -ExecutionPolicy Bypass -File (Join-Path $snapshot.launcher.launcher_path "Invoke-StackInboxSweepLauncher.ps1") -VerifyOnly 2>$null | Out-Null
    $tamperExitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldErrorActionPreference
    Assert-Sweep ($tamperExitCode -ne 0) "Launcher integrity verification accepted tampered bytes."

    $stackConfig = Get-Content -LiteralPath (Join-Path $PSScriptRoot "repos\stack\config.toml") -Raw
    Assert-Sweep ($stackConfig -match 'model\s*=\s*"gpt-5\.6-sol"' -and $stackConfig -match 'reasoning\s*=\s*"xhigh"' -and $stackConfig -match 'permission_profile\s*=\s*":danger-full-access"' -and $stackConfig -match 'approval\s*=\s*"never"' -and $stackConfig -match 'web_search\s*=\s*"live"') "_stack scheduled runtime defaults are not Sol/xhigh/full-access/live/no-approvals."
    Assert-Sweep ($stackConfig -notmatch '(?m)^\s*sandbox_mode\s*=') "_stack runtime config mixes modern and legacy permissions."

    "stack-inbox-sweep-tests: ok"
}
finally {
    Remove-Item Env:\STACK_INBOX_FAKE_COUNTER -ErrorAction SilentlyContinue
    foreach ($root in @($roots.ToArray())) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}
