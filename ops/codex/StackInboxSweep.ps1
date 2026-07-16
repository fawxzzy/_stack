Set-StrictMode -Version Latest

$script:StackInboxContractVersion = "atlas.stack.inbox.v1"
$script:StackInboxClaimContractVersion = "atlas.stack.inbox-claim.v1"
$script:StackInboxTerminalContractVersion = "atlas.stack.inbox-terminal.v1"
$script:StackInboxSweepContractVersion = "atlas.stack.inbox-sweep.v1"
$script:StackInboxLeaseContractVersion = "atlas.stack.inbox-sweep-lease.v1"
$script:KnownStaleStackPrompt = [ordered]@{
    name = "stack-auto-land-proof.md"
    bytes = 703
    sha256 = "0001b5b76422fb642c8a81f1956ab891de6626340fff796f8541549d7061cf95"
    last_modified_before_utc = "2026-04-09T00:00:00.0000000Z"
}

function Get-StackInboxUtcNow {
    return [DateTimeOffset]::UtcNow
}

function ConvertTo-StackInboxUtcString {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$Value)
    return $Value.UtcDateTime.ToString("o")
}

function Get-StackInboxObjectValue {
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $DefaultValue = $null)

    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $DefaultValue
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Read-StackInboxJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Write-StackInboxJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryPath = Join-Path -Path $parent -ChildPath (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString("N")))
    $json = ($Value | ConvertTo-Json -Depth 24) + "`r`n"
    [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-StackInboxFileEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return [pscustomobject]@{
        name = $item.Name
        path = $item.FullName
        bytes = [long]$item.Length
        sha256 = Get-DeterministicFileSha256 -Path $item.FullName
        last_modified_utc = $item.LastWriteTimeUtc.ToString("o")
    }
}

function Get-StackInboxLogMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ path = $Path; bytes = 0L; line_count = 0L; sha256 = $null; exists = $false }
    }
    [long]$lineCount = 0
    $reader = [System.IO.File]::OpenText($Path)
    try {
        while ($null -ne $reader.ReadLine()) { $lineCount += 1 }
    }
    finally {
        $reader.Dispose()
    }
    return [pscustomobject]@{
        path = $Path
        bytes = [long](Get-Item -LiteralPath $Path).Length
        line_count = $lineCount
        sha256 = Get-DeterministicFileSha256 -Path $Path
        exists = $true
    }
}

function Test-StackInboxFileSettled {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$SettleSeconds = 2,
        [DateTimeOffset]$Now = (Get-StackInboxUtcNow)
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($SettleSeconds -gt 0 -and ($Now.UtcDateTime - $item.LastWriteTimeUtc).TotalSeconds -lt $SettleSeconds) { return $false }
    try {
        $stream = [System.IO.File]::Open($item.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-StackInboxHeaderMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = [ordered]@{}
    $duplicates = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line -notmatch '^(?<key>[A-Za-z][A-Za-z0-9 -]*):\s*(?<value>.*)$') { break }
        $key = ($Matches.key -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($values.Contains($key)) {
            [void]$duplicates.Add($key)
            continue
        }
        $values[$key] = $Matches.value.Trim()
    }

    return [pscustomobject]@{
        values = $values
        duplicate_keys = @($duplicates.ToArray())
    }
}

function Test-KnownStaleStackPrompt {
    param([Parameter(Mandatory = $true)]$Evidence)

    $cutoff = [DateTimeOffset]::Parse([string]$script:KnownStaleStackPrompt.last_modified_before_utc)
    $observedLastWrite = [DateTimeOffset]::Parse([string]$Evidence.last_modified_utc)
    return (
        [string]$Evidence.name -eq [string]$script:KnownStaleStackPrompt.name -and
        [long]$Evidence.bytes -eq [long]$script:KnownStaleStackPrompt.bytes -and
        [string]$Evidence.sha256 -eq [string]$script:KnownStaleStackPrompt.sha256 -and
        $observedLastWrite -lt $cutoff
    )
}

function Test-StackInboxAdmission {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$FreshnessMinutes = 30,
        [int]$FutureSkewMinutes = 5,
        [DateTimeOffset]$Now = (Get-StackInboxUtcNow)
    )

    $evidence = Get-StackInboxFileEvidence -Path $Path
    $headers = Get-StackInboxHeaderMetadata -Path $Path
    $values = $headers.values
    $owner = if ($values.Contains("inboxowner")) { [string]$values["inboxowner"] } else { $null }

    if (Test-KnownStaleStackPrompt -Evidence $evidence) {
        return [pscustomobject]@{
            admitted = $false
            disposition = "quarantine"
            reason_code = "known_stale_april_prompt"
            evidence = $evidence
            metadata = [pscustomobject]@{ owner = $owner; accepted_at = $null; idempotency_key = $null; inbox_job_id = $null; contract_version = $null }
            details = [ordered]@{ expected = $script:KnownStaleStackPrompt; exact_evidence_match = $true }
        }
    }

    if ([string]::IsNullOrWhiteSpace($owner)) {
        return [pscustomobject]@{ admitted = $false; disposition = "leave-in-place"; reason_code = "ambiguous_ownership"; evidence = $evidence; metadata = $null; details = [ordered]@{ duplicate_keys = @($headers.duplicate_keys) } }
    }
    if ($owner -ne "stack") {
        return [pscustomobject]@{ admitted = $false; disposition = "leave-in-place"; reason_code = "foreign_ownership"; evidence = $evidence; metadata = [pscustomobject]@{ owner = $owner }; details = [ordered]@{ duplicate_keys = @($headers.duplicate_keys) } }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    if (@($headers.duplicate_keys).Count -gt 0) { [void]$errors.Add("duplicate_metadata_keys") }
    $contractVersion = if ($values.Contains("inboxcontract")) { [string]$values["inboxcontract"] } else { "" }
    $acceptedAtRaw = if ($values.Contains("acceptedat")) { [string]$values["acceptedat"] } else { "" }
    $idempotencyKey = if ($values.Contains("idempotencykey")) { [string]$values["idempotencykey"] } else { "" }
    $inboxJobId = if ($values.Contains("jobid")) { [string]$values["jobid"] } else { "" }

    if ($contractVersion -ne $script:StackInboxContractVersion) { [void]$errors.Add("unsupported_inbox_contract") }
    if ($idempotencyKey -notmatch '^[a-z0-9][a-z0-9._:-]{2,127}$') { [void]$errors.Add("invalid_idempotency_key") }
    if ($inboxJobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$') { [void]$errors.Add("invalid_job_id") }

    $acceptedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($acceptedAtRaw, [ref]$acceptedAt)) {
        [void]$errors.Add("invalid_accepted_at")
    }
    elseif ($acceptedAt.Offset -ne [TimeSpan]::Zero) {
        [void]$errors.Add("accepted_at_must_be_utc")
    }
    elseif ($acceptedAt -gt $Now.AddMinutes($FutureSkewMinutes)) {
        [void]$errors.Add("accepted_at_in_future")
    }
    elseif ($acceptedAt -lt $Now.AddMinutes(-1 * $FreshnessMinutes)) {
        [void]$errors.Add("stale_accepted_at")
    }

    $permissionProfile = if ($values.Contains("runtimepermissionprofile")) { [string]$values["runtimepermissionprofile"] } else { "" }
    $sandboxMode = if ($values.Contains("runtimesandboxmode")) { [string]$values["runtimesandboxmode"] } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($permissionProfile) -and -not [string]::IsNullOrWhiteSpace($sandboxMode)) {
        [void]$errors.Add("modern_legacy_permission_mixing")
    }
    $runtimeReasoning = if ($values.Contains("runtimereasoning")) { [string]$values["runtimereasoning"] } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($runtimeReasoning) -and $runtimeReasoning -notin @("medium", "high", "xhigh")) { [void]$errors.Add("unsupported_runtime_reasoning") }
    $runtimeWebSearch = if ($values.Contains("runtimewebsearch")) { [string]$values["runtimewebsearch"] } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($runtimeWebSearch) -and $runtimeWebSearch -notin @("live", "disabled", "cached")) { [void]$errors.Add("unsupported_runtime_web_search") }

    $metadata = [pscustomobject]@{
        owner = $owner
        contract_version = $contractVersion
        accepted_at = if ($acceptedAt -eq [DateTimeOffset]::MinValue) { $acceptedAtRaw } else { ConvertTo-StackInboxUtcString -Value $acceptedAt }
        idempotency_key = $idempotencyKey
        inbox_job_id = $inboxJobId
    }
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{
            admitted = $false
            disposition = "quarantine"
            reason_code = if ($errors.Contains("stale_accepted_at")) { "stale_accepted_at" } else { "malformed_or_unsupported_metadata" }
            evidence = $evidence
            metadata = $metadata
            details = [ordered]@{ errors = @($errors.ToArray()); duplicate_keys = @($headers.duplicate_keys) }
        }
    }

    return [pscustomobject]@{ admitted = $true; disposition = "claim"; reason_code = "admitted"; evidence = $evidence; metadata = $metadata; details = [ordered]@{ errors = @() } }
}

function Get-StackInboxCurrentProcessIdentity {
    $process = Get-Process -Id $PID -ErrorAction Stop
    return [pscustomobject]@{
        pid = [int]$PID
        process_start_time_utc = $process.StartTime.ToUniversalTime().ToString("o")
    }
}

function Test-StackInboxProcessIdentity {
    param([Parameter(Mandatory = $true)]$Owner)

    $ownerPid = 0
    $ownerStartRaw = [string](Get-StackInboxObjectValue -Object $Owner -Name "process_start_time_utc" -DefaultValue "")
    if (-not [int]::TryParse([string](Get-StackInboxObjectValue -Object $Owner -Name "pid" -DefaultValue ""), [ref]$ownerPid) -or $ownerPid -le 0) {
        return [pscustomobject]@{ conclusion = "unknown"; conclusive = $false; live = $false; reason = "invalid_owner_pid" }
    }
    $ownerStart = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($ownerStartRaw, [ref]$ownerStart)) {
        return [pscustomobject]@{ conclusion = "unknown"; conclusive = $false; live = $false; reason = "invalid_owner_start_time" }
    }

    try {
        $process = Get-Process -Id $ownerPid -ErrorAction Stop
    }
    catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
        return [pscustomobject]@{ conclusion = "dead"; conclusive = $true; live = $false; reason = "pid_not_found" }
    }
    catch {
        return [pscustomobject]@{ conclusion = "unknown"; conclusive = $false; live = $false; reason = "process_query_failed" }
    }

    try { $actualStart = [DateTimeOffset]$process.StartTime.ToUniversalTime() }
    catch { return [pscustomobject]@{ conclusion = "unknown"; conclusive = $false; live = $false; reason = "process_start_time_unavailable" } }
    if ([Math]::Abs(($actualStart - $ownerStart).TotalMilliseconds) -le 1) {
        return [pscustomobject]@{ conclusion = "live"; conclusive = $true; live = $true; reason = "pid_and_start_time_match" }
    }
    return [pscustomobject]@{ conclusion = "dead"; conclusive = $true; live = $false; reason = "pid_reused_start_time_mismatch" }
}

function Initialize-StackInboxStateDirectories {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    foreach ($name in @("processing", "claim-history", "archive", "quarantine", "terminal", "sweeps", "lease-history")) {
        New-Item -ItemType Directory -Path (Join-Path $StateRoot $name) -Force | Out-Null
    }
}

function Enter-StackInboxSweepLease {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$SweepId,
        [Parameter(Mandatory = $true)][string]$CorrelationId
    )

    Initialize-StackInboxStateDirectories -StateRoot $StateRoot
    $lockPath = Join-Path $StateRoot "lease.lock"
    $historyRoot = Join-Path $StateRoot "lease-history"
    $staleDiagnosis = $null

    if (Test-Path -LiteralPath $lockPath) {
        $existingPath = Join-Path $lockPath "lease.json"
        $existing = Read-StackInboxJson -Path $existingPath
        if ($null -eq $existing) {
            return [pscustomobject]@{ acquired = $false; status = "overlap_rejected"; reason_code = "existing_lease_malformed"; stale_owner_diagnosis = [ordered]@{ conclusion = "unknown"; conclusive = $false }; context = $null }
        }
        $staleDiagnosis = Test-StackInboxProcessIdentity -Owner (Get-StackInboxObjectValue -Object $existing -Name "owner")
        if ([bool]$staleDiagnosis.live) {
            return [pscustomobject]@{ acquired = $false; status = "overlap_rejected"; reason_code = "live_sweep_owner"; stale_owner_diagnosis = $staleDiagnosis; context = $null }
        }
        if (-not [bool]$staleDiagnosis.conclusive) {
            return [pscustomobject]@{ acquired = $false; status = "overlap_rejected"; reason_code = "stale_owner_not_conclusive"; stale_owner_diagnosis = $staleDiagnosis; context = $null }
        }
        $staleName = "stale-{0}-{1}-{2}" -f ([DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")), (Get-StackInboxObjectValue -Object $existing -Name "sweep_id" -DefaultValue "unknown"), ([guid]::NewGuid().ToString("N"))
        try { Move-Item -LiteralPath $lockPath -Destination (Join-Path $historyRoot $staleName) -ErrorAction Stop }
        catch { return [pscustomobject]@{ acquired = $false; status = "overlap_rejected"; reason_code = "stale_lease_takeover_race"; stale_owner_diagnosis = $staleDiagnosis; context = $null } }
    }

    try { New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null }
    catch { return [pscustomobject]@{ acquired = $false; status = "overlap_rejected"; reason_code = "lease_acquire_race"; stale_owner_diagnosis = $staleDiagnosis; context = $null } }

    $now = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
    $lease = [ordered]@{
        contract_version = $script:StackInboxLeaseContractVersion
        task_name = $TaskName
        sweep_id = $SweepId
        correlation_id = $CorrelationId
        status = "active"
        owner = Get-StackInboxCurrentProcessIdentity
        acquired_at = $now
        renewed_at = $now
        released_at = $null
        stale_owner_diagnosis = $staleDiagnosis
        takeover_policy = "conclusive-owner-death-only"
    }
    $leasePath = Join-Path $lockPath "lease.json"
    Write-StackInboxJsonAtomic -Path $leasePath -Value $lease
    return [pscustomobject]@{ acquired = $true; status = "active"; reason_code = "acquired"; stale_owner_diagnosis = $staleDiagnosis; context = [pscustomobject]@{ lock_path = $lockPath; lease_path = $leasePath; lease = $lease; state_root = $StateRoot } }
}

function Update-StackInboxSweepLease {
    param([Parameter(Mandatory = $true)]$LeaseContext)

    $lease = $LeaseContext.lease
    $lease.renewed_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
    Write-StackInboxJsonAtomic -Path $LeaseContext.lease_path -Value $lease
}

function Exit-StackInboxSweepLease {
    param([Parameter(Mandatory = $true)]$LeaseContext, [string]$TerminalStatus = "released")

    if (-not (Test-Path -LiteralPath $LeaseContext.lock_path -PathType Container)) { return $null }
    $now = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
    $LeaseContext.lease.status = $TerminalStatus
    $LeaseContext.lease.renewed_at = $now
    $LeaseContext.lease.released_at = $now
    Write-StackInboxJsonAtomic -Path $LeaseContext.lease_path -Value $LeaseContext.lease
    $historyRoot = Join-Path $LeaseContext.state_root "lease-history"
    $target = Join-Path $historyRoot ("released-{0}-{1}-{2}" -f ([DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")), $LeaseContext.lease.sweep_id, ([guid]::NewGuid().ToString("N")))
    Move-Item -LiteralPath $LeaseContext.lock_path -Destination $target -ErrorAction Stop
    return $target
}

function Get-StackInboxTerminalRecords {
    param([Parameter(Mandatory = $true)][string]$StateRoot)

    $root = Join-Path $StateRoot "terminal"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Filter *.json -File | Sort-Object Name | ForEach-Object { Read-StackInboxJson -Path $_.FullName } | Where-Object { $null -ne $_ })
}

function Find-StackInboxReplayRecord {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$Admission,
        [string]$ExcludeClaimId = ""
    )

    foreach ($record in @(Get-StackInboxTerminalRecords -StateRoot $StateRoot)) {
        if ([string]$record.content_sha256 -eq [string]$Admission.evidence.sha256) { return [pscustomobject]@{ reason_code = "content_hash_replay"; record = $record } }
        if ([string]$record.idempotency_key -eq [string]$Admission.metadata.idempotency_key) { return [pscustomobject]@{ reason_code = "duplicate_idempotency_key"; record = $record } }
        if ([string]$record.inbox_job_id -eq [string]$Admission.metadata.inbox_job_id) { return [pscustomobject]@{ reason_code = "already_terminal_job"; record = $record } }
    }

    $processingRoot = Join-Path $StateRoot "processing"
    if (Test-Path -LiteralPath $processingRoot -PathType Container) {
        foreach ($claimPath in @(Get-ChildItem -LiteralPath $processingRoot -Filter claim.json -File -Recurse)) {
            $claim = Read-StackInboxJson -Path $claimPath.FullName
            if ($null -eq $claim -or [string]$claim.claim_id -eq $ExcludeClaimId) { continue }
            if ([string]$claim.content_sha256 -eq [string]$Admission.evidence.sha256) { return [pscustomobject]@{ reason_code = "content_hash_already_claimed"; record = $claim } }
            if ([string]$claim.idempotency_key -eq [string]$Admission.metadata.idempotency_key) { return [pscustomobject]@{ reason_code = "idempotency_key_already_claimed"; record = $claim } }
            if ([string]$claim.inbox_job_id -eq [string]$Admission.metadata.inbox_job_id) { return [pscustomobject]@{ reason_code = "job_already_claimed"; record = $claim } }
        }
    }
    return $null
}

function Move-StackInboxToTerminalDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$PromptPath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][ValidateSet("archive", "quarantine")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Identity
    )

    $directory = Join-Path (Join-Path $StateRoot $Kind) ("{0}-{1}" -f ([DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")), $Identity)
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    $destination = Join-Path $directory ([System.IO.Path]::GetFileName($PromptPath))
    Move-Item -LiteralPath $PromptPath -Destination $destination -ErrorAction Stop
    return [pscustomobject]@{ directory = $directory; prompt_path = $destination }
}

function Write-StackInboxObservation {
    param([Parameter(Mandatory = $true)][string]$SweepDirectory, [Parameter(Mandatory = $true)]$Record)
    $name = "observation-{0}.json" -f ([guid]::NewGuid().ToString("N"))
    $path = Join-Path $SweepDirectory $name
    Write-StackInboxJsonAtomic -Path $path -Value $Record
    return $path
}

function Quarantine-StackInboxSourcePrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$SweepId,
        [Parameter(Mandatory = $true)]$Admission
    )

    $identity = [guid]::NewGuid().ToString("N")
    $terminal = Move-StackInboxToTerminalDirectory -PromptPath $Path -StateRoot $StateRoot -Kind "quarantine" -Identity $identity
    $record = [ordered]@{
        contract_version = $script:StackInboxTerminalContractVersion
        terminal_id = "terminal-$identity"
        sweep_id = $SweepId
        disposition = "quarantined"
        reason_code = [string]$Admission.reason_code
        source = $Admission.evidence
        content_sha256 = [string]$Admission.evidence.sha256
        idempotency_key = if ($null -eq $Admission.metadata) { $null } else { Get-StackInboxObjectValue -Object $Admission.metadata -Name "idempotency_key" }
        inbox_job_id = if ($null -eq $Admission.metadata) { $null } else { Get-StackInboxObjectValue -Object $Admission.metadata -Name "inbox_job_id" }
        accepted_at = if ($null -eq $Admission.metadata) { $null } else { Get-StackInboxObjectValue -Object $Admission.metadata -Name "accepted_at" }
        terminal_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
        prompt_path = $terminal.prompt_path
        quarantine_record_path = Join-Path $terminal.directory "quarantine.json"
        execution_started = $false
        atlas_contracts_v2 = $null
        details = $Admission.details
    }
    Write-StackInboxJsonAtomic -Path $record.quarantine_record_path -Value $record
    Write-StackInboxJsonAtomic -Path (Join-Path (Join-Path $StateRoot "terminal") ("{0}.json" -f $record.terminal_id)) -Value $record
    return [pscustomobject]$record
}

function New-StackInboxClaim {
    param(
        [Parameter(Mandatory = $true)][string]$PromptPath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$SweepId,
        [Parameter(Mandatory = $true)][string]$CorrelationId,
        [Parameter(Mandatory = $true)]$Admission,
        [Parameter(Mandatory = $true)]$Owner
    )

    $claimId = "claim-{0}" -f ([guid]::NewGuid().ToString("N"))
    $claimDirectory = Join-Path (Join-Path $StateRoot "processing") $claimId
    New-Item -ItemType Directory -Path $claimDirectory -ErrorAction Stop | Out-Null
    $claimedPromptPath = Join-Path $claimDirectory ([System.IO.Path]::GetFileName($PromptPath))
    $claimPath = Join-Path $claimDirectory "claim.json"
    $record = [ordered]@{
        contract_version = $script:StackInboxClaimContractVersion
        claim_id = $claimId
        task_name = $TaskName
        sweep_id = $SweepId
        sweep_correlation_id = $CorrelationId
        state = "prepared"
        owner = $Owner
        source_path = [string]$Admission.evidence.path
        source_name = [string]$Admission.evidence.name
        source_last_modified_utc = [string]$Admission.evidence.last_modified_utc
        bytes = [long]$Admission.evidence.bytes
        content_sha256 = [string]$Admission.evidence.sha256
        accepted_at = [string]$Admission.metadata.accepted_at
        idempotency_key = [string]$Admission.metadata.idempotency_key
        inbox_job_id = [string]$Admission.metadata.inbox_job_id
        prepared_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
        claimed_at = $null
        execution_started_at = $null
        result_path = Join-Path $claimDirectory "task-result.json"
        prompt_path = $claimedPromptPath
        terminal_record_path = $null
    }
    Write-StackInboxJsonAtomic -Path $claimPath -Value $record
    Move-Item -LiteralPath $PromptPath -Destination $claimedPromptPath -ErrorAction Stop
    $record.state = "claimed"
    $record.claimed_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
    Write-StackInboxJsonAtomic -Path $claimPath -Value $record
    return [pscustomobject]@{ directory = $claimDirectory; claim_path = $claimPath; prompt_path = $claimedPromptPath; record = $record }
}

function Test-StackInboxContractsCorrelation {
    param([Parameter(Mandatory = $true)]$TaskResult)

    $paths = Get-StackInboxObjectValue -Object $TaskResult -Name "atlas_contracts_v2" -DefaultValue $null
    if ($null -eq $paths) { return [pscustomobject]@{ ok = $false; reason_code = "contracts_v2_paths_missing"; identities = $null } }
    $envelope = Read-StackInboxJson -Path ([string](Get-StackInboxObjectValue -Object $paths -Name "job_envelope" -DefaultValue ""))
    $lease = Read-StackInboxJson -Path ([string](Get-StackInboxObjectValue -Object $paths -Name "worker_lease" -DefaultValue ""))
    $receipt = Read-StackInboxJson -Path ([string](Get-StackInboxObjectValue -Object $paths -Name "execution_receipt" -DefaultValue ""))
    if ($null -eq $envelope -or $null -eq $lease -or $null -eq $receipt) { return [pscustomobject]@{ ok = $false; reason_code = "contracts_v2_artifact_missing_or_malformed"; identities = $null } }
    if ([string]$envelope.contract_version -ne "atlas.job-envelope.v2" -or [string]$lease.contract_version -ne "atlas.worker-lease.v2" -or [string]$receipt.contract_version -ne "atlas.execution-receipt.v2") {
        return [pscustomobject]@{ ok = $false; reason_code = "contracts_v2_version_mismatch"; identities = $null }
    }
    if ([string]$envelope.job_id -ne [string]$lease.job_id -or [string]$envelope.job_id -ne [string]$receipt.job_id) {
        return [pscustomobject]@{ ok = $false; reason_code = "contracts_v2_job_correlation_mismatch"; identities = $null }
    }
    $binding = Get-StackInboxObjectValue -Object $receipt.extensions -Name "worker_lease_binding" -DefaultValue $null
    if ($null -eq $binding -or [string]$binding.lease_id -ne [string]$lease.lease_id) {
        return [pscustomobject]@{ ok = $false; reason_code = "contracts_v2_lease_correlation_mismatch"; identities = $null }
    }
    $runId = [string](Get-StackInboxObjectValue -Object $TaskResult -Name "run_id" -DefaultValue "")
    if ([string]$envelope.extensions.run_id -ne $runId -or [string]$receipt.extensions.run_id -ne $runId) {
        return [pscustomobject]@{ ok = $false; reason_code = "contracts_v2_run_correlation_mismatch"; identities = $null }
    }
    return [pscustomobject]@{
        ok = $true
        reason_code = "correlated"
        identities = [ordered]@{
            run_id = $runId
            job_id = [string]$envelope.job_id
            lease_id = [string]$lease.lease_id
            receipt_id = [string]$receipt.receipt_id
            envelope_path = [string]$paths.job_envelope
            lease_path = [string]$paths.worker_lease
            receipt_path = [string]$paths.execution_receipt
            lease_status = [string]$lease.status
            receipt_status = [string]$receipt.status
        }
    }
}

function Complete-StackInboxClaim {
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$TaskResult,
        [int]$TaskExitCode
    )

    $correlation = Test-StackInboxContractsCorrelation -TaskResult $TaskResult
    $runnerStatus = [string](Get-StackInboxObjectValue -Object $TaskResult -Name "status" -DefaultValue "unknown")
    $acceptedSuccess = $TaskExitCode -eq 0 -and $runnerStatus -in @("success", "success_no_changes") -and [bool]$correlation.ok -and [string]$correlation.identities.receipt_status -eq "succeeded" -and [string]$correlation.identities.lease_status -eq "released"
    $kind = if ($acceptedSuccess) { "archive" } else { "quarantine" }
    $disposition = if ($acceptedSuccess) { "archived" } else { "quarantined" }
    $reasonCode = if (-not [bool]$correlation.ok) { [string]$correlation.reason_code } elseif (-not $acceptedSuccess) { "terminal_execution_failed" } else { "terminal_success" }
    $terminalId = "terminal-{0}" -f ([guid]::NewGuid().ToString("N"))
    $terminalIndexPath = Join-Path (Join-Path $StateRoot "terminal") "$terminalId.json"
    $terminalRecord = [ordered]@{
        contract_version = $script:StackInboxTerminalContractVersion
        terminal_id = $terminalId
        claim_id = [string]$Claim.record.claim_id
        sweep_id = [string]$Claim.record.sweep_id
        sweep_correlation_id = [string]$Claim.record.sweep_correlation_id
        disposition = $disposition
        reason_code = $reasonCode
        content_sha256 = [string]$Claim.record.content_sha256
        idempotency_key = [string]$Claim.record.idempotency_key
        inbox_job_id = [string]$Claim.record.inbox_job_id
        accepted_at = [string]$Claim.record.accepted_at
        execution_started = $true
        execution_started_at = [string]$Claim.record.execution_started_at
        terminal_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
        task_exit_code = $TaskExitCode
        runner_status = $runnerStatus
        result_path = [string]$Claim.record.result_path
        prompt_path = $null
        task_output = Get-StackInboxObjectValue -Object $Claim.record -Name "task_output" -DefaultValue $null
        atlas_contracts_v2 = if ([bool]$correlation.ok) { $correlation.identities } else { $null }
        correlation_validation = [ordered]@{ ok = [bool]$correlation.ok; reason_code = [string]$correlation.reason_code }
    }
    Write-StackInboxJsonAtomic -Path $terminalIndexPath -Value $terminalRecord
    $terminal = Move-StackInboxToTerminalDirectory -PromptPath $Claim.prompt_path -StateRoot $StateRoot -Kind $kind -Identity $terminalId
    $terminalRecord.prompt_path = $terminal.prompt_path
    $terminalRecord.terminal_directory = $terminal.directory
    Write-StackInboxJsonAtomic -Path $terminalIndexPath -Value $terminalRecord
    Write-StackInboxJsonAtomic -Path (Join-Path $terminal.directory "terminal.json") -Value $terminalRecord
    $Claim.record.state = "terminal"
    $Claim.record.terminal_record_path = $terminalIndexPath
    Write-StackInboxJsonAtomic -Path $Claim.claim_path -Value $Claim.record
    return [pscustomobject]$terminalRecord
}

function Quarantine-StackInboxClaimWithoutExecution {
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    $terminalId = "terminal-{0}" -f ([guid]::NewGuid().ToString("N"))
    $terminalPath = Join-Path (Join-Path $StateRoot "terminal") "$terminalId.json"
    $record = [ordered]@{
        contract_version = $script:StackInboxTerminalContractVersion
        terminal_id = $terminalId
        claim_id = [string]$Claim.record.claim_id
        sweep_id = [string]$Claim.record.sweep_id
        sweep_correlation_id = [string]$Claim.record.sweep_correlation_id
        disposition = "quarantined"
        reason_code = $ReasonCode
        content_sha256 = [string]$Claim.record.content_sha256
        idempotency_key = [string]$Claim.record.idempotency_key
        inbox_job_id = [string]$Claim.record.inbox_job_id
        accepted_at = [string]$Claim.record.accepted_at
        execution_started = -not [string]::IsNullOrWhiteSpace([string]$Claim.record.execution_started_at)
        execution_started_at = $Claim.record.execution_started_at
        terminal_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
        prompt_path = $null
        task_output = Get-StackInboxObjectValue -Object $Claim.record -Name "task_output" -DefaultValue $null
        atlas_contracts_v2 = $null
    }
    Write-StackInboxJsonAtomic -Path $terminalPath -Value $record
    if (Test-Path -LiteralPath $Claim.prompt_path -PathType Leaf) {
        $terminal = Move-StackInboxToTerminalDirectory -PromptPath $Claim.prompt_path -StateRoot $StateRoot -Kind "quarantine" -Identity $terminalId
        $record.prompt_path = $terminal.prompt_path
        $record.terminal_directory = $terminal.directory
        Write-StackInboxJsonAtomic -Path $terminalPath -Value $record
        Write-StackInboxJsonAtomic -Path (Join-Path $terminal.directory "terminal.json") -Value $record
    }
    $Claim.record.state = "terminal"
    $Claim.record.terminal_record_path = $terminalPath
    Write-StackInboxJsonAtomic -Path $Claim.claim_path -Value $Claim.record
    return [pscustomobject]$record
}

function Get-StackInboxRecoverableClaims {
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)]$CurrentOwner,
        [Parameter(Mandatory = $true)][string]$SweepId,
        [Parameter(Mandatory = $true)][string]$CorrelationId
    )

    $recoverable = New-Object System.Collections.Generic.List[object]
    $terminalized = New-Object System.Collections.Generic.List[object]
    $preMoveRecovered = New-Object System.Collections.Generic.List[object]
    $processingRoot = Join-Path $StateRoot "processing"
    if (-not (Test-Path -LiteralPath $processingRoot -PathType Container)) { return [pscustomobject]@{ recoverable = @(); terminalized = @(); pre_move_recovered = @() } }
    foreach ($claimFile in @(Get-ChildItem -LiteralPath $processingRoot -Filter claim.json -File -Recurse | Sort-Object FullName)) {
        $record = Read-StackInboxJson -Path $claimFile.FullName
        if ($null -eq $record -or [string]$record.contract_version -ne $script:StackInboxClaimContractVersion) { continue }
        if ([string]$record.state -eq "terminal") { continue }
        $claim = [pscustomobject]@{ directory = $claimFile.Directory.FullName; claim_path = $claimFile.FullName; prompt_path = [string]$record.prompt_path; record = $record }
        $ownerState = Test-StackInboxProcessIdentity -Owner $record.owner
        if ([bool]$ownerState.live) { continue }
        if (-not [bool]$ownerState.conclusive) { continue }
        if (Test-Path -LiteralPath ([string]$record.result_path) -PathType Leaf) {
            $taskResult = Read-StackInboxJson -Path ([string]$record.result_path)
            if ($null -ne $taskResult) { [void]$terminalized.Add((Complete-StackInboxClaim -Claim $claim -StateRoot $StateRoot -TaskResult $taskResult -TaskExitCode ([int](Get-StackInboxObjectValue -Object $taskResult -Name "exit_code" -DefaultValue 1)))); continue }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$record.execution_started_at)) {
            [void]$terminalized.Add((Quarantine-StackInboxClaimWithoutExecution -Claim $claim -StateRoot $StateRoot -ReasonCode "ambiguous_crash_after_execution_start")); continue
        }
        if (-not (Test-Path -LiteralPath $claim.prompt_path -PathType Leaf)) {
            if ([string]$record.state -eq "prepared" -and (Test-Path -LiteralPath ([string]$record.source_path) -PathType Leaf)) {
                $sourceEvidence = Get-StackInboxFileEvidence -Path ([string]$record.source_path)
                $sourceMatchesPreparedClaim = (
                    [string]$sourceEvidence.name -eq [string]$record.source_name -and
                    [long]$sourceEvidence.bytes -eq [long]$record.bytes -and
                    [string]$sourceEvidence.sha256 -eq [string]$record.content_sha256 -and
                    [string]$sourceEvidence.last_modified_utc -eq [string]$record.source_last_modified_utc
                )
                if ($sourceMatchesPreparedClaim) {
                    $record.state = "abandoned_before_source_move"
                    $record | Add-Member -MemberType NoteProperty -Name recovery_reason_code -Value "prepared_claim_source_move_not_observed" -Force
                    $record | Add-Member -MemberType NoteProperty -Name recovered_at -Value (ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)) -Force
                    $record | Add-Member -MemberType NoteProperty -Name recovery_sweep_id -Value $SweepId -Force
                    $record | Add-Member -MemberType NoteProperty -Name recovery_correlation_id -Value $CorrelationId -Force
                    Write-StackInboxJsonAtomic -Path $claim.claim_path -Value $record
                    $historyDirectory = Join-Path (Join-Path $StateRoot "claim-history") ("{0}-{1}" -f $record.claim_id, ([guid]::NewGuid().ToString("N")))
                    Move-Item -LiteralPath $claim.directory -Destination $historyDirectory -ErrorAction Stop
                    [void]$preMoveRecovered.Add([pscustomobject]@{
                        claim_id = [string]$record.claim_id
                        state = [string]$record.state
                        source_path = [string]$record.source_path
                        history_path = $historyDirectory
                        source_evidence = $sourceEvidence
                    })
                }
            }
            continue
        }
        $record.owner = $CurrentOwner
        $record.sweep_id = $SweepId
        $record.sweep_correlation_id = $CorrelationId
        $record.state = "recovered"
        Write-StackInboxJsonAtomic -Path $claim.claim_path -Value $record
        [void]$recoverable.Add([pscustomobject]@{ directory = $claim.directory; claim_path = $claim.claim_path; prompt_path = $claim.prompt_path; record = $record })
    }
    return [pscustomobject]@{ recoverable = @($recoverable.ToArray()); terminalized = @($terminalized.ToArray()); pre_move_recovered = @($preMoveRecovered.ToArray()) }
}

function Invoke-StackInboxClaimTask {
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)][string]$TaskScriptPath,
        [Parameter(Mandatory = $true)][string]$PowerShellExecutable,
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
        [string]$WebSearch = ""
    )

    $Claim.record.state = "executing"
    $Claim.record.execution_started_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
    Write-StackInboxJsonAtomic -Path $Claim.claim_path -Value $Claim.record
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $TaskScriptPath, "-PromptPath", $Claim.prompt_path, "-ResultPath", $Claim.record.result_path, "-SkipPromptArchive")
    foreach ($option in @(
        [pscustomobject]@{ name = "ConfigPath"; value = $ConfigPath },
        [pscustomobject]@{ name = "RepoRoot"; value = $RepoRoot },
        [pscustomobject]@{ name = "AdapterPath"; value = $AdapterPath },
        [pscustomobject]@{ name = "CodexCommand"; value = $CodexCommand },
        [pscustomobject]@{ name = "Model"; value = $Model },
        [pscustomobject]@{ name = "Reasoning"; value = $Reasoning },
        [pscustomobject]@{ name = "Speed"; value = $Speed },
        [pscustomobject]@{ name = "Permissions"; value = $Permissions },
        [pscustomobject]@{ name = "PermissionProfile"; value = $PermissionProfile },
        [pscustomobject]@{ name = "SandboxMode"; value = $SandboxMode },
        [pscustomobject]@{ name = "ApprovalPolicy"; value = $ApprovalPolicy },
        [pscustomobject]@{ name = "WebSearch"; value = $WebSearch }
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$option.value)) {
            $arguments += ("-{0}" -f $option.name)
            $arguments += [string]$option.value
        }
    }
    $oldSweepId = $env:ATLAS_INBOX_SWEEP_ID
    $oldCorrelationId = $env:ATLAS_INBOX_SWEEP_CORRELATION_ID
    $oldIdempotencyKey = $env:ATLAS_INBOX_IDEMPOTENCY_KEY
    $oldInboxJobId = $env:ATLAS_INBOX_JOB_ID
    $oldConfigPath = $env:ATLAS_INBOX_CONFIG_PATH
    $oldRepoRoot = $env:ATLAS_INBOX_REPO_ROOT
    $oldAdapterPath = $env:ATLAS_INBOX_ADAPTER_PATH
    try {
        $env:ATLAS_INBOX_SWEEP_ID = [string]$Claim.record.sweep_id
        $env:ATLAS_INBOX_SWEEP_CORRELATION_ID = [string]$Claim.record.sweep_correlation_id
        $env:ATLAS_INBOX_IDEMPOTENCY_KEY = [string]$Claim.record.idempotency_key
        $env:ATLAS_INBOX_JOB_ID = [string]$Claim.record.inbox_job_id
        $env:ATLAS_INBOX_CONFIG_PATH = $ConfigPath
        $env:ATLAS_INBOX_REPO_ROOT = $RepoRoot
        $env:ATLAS_INBOX_ADAPTER_PATH = $AdapterPath
        $stdoutPath = Join-Path $Claim.directory "task.stdout.log"
        $stderrPath = Join-Path $Claim.directory "task.stderr.log"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $PowerShellExecutable @arguments 1> $stdoutPath 2> $stderrPath
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }
    finally {
        $env:ATLAS_INBOX_SWEEP_ID = $oldSweepId
        $env:ATLAS_INBOX_SWEEP_CORRELATION_ID = $oldCorrelationId
        $env:ATLAS_INBOX_IDEMPOTENCY_KEY = $oldIdempotencyKey
        $env:ATLAS_INBOX_JOB_ID = $oldInboxJobId
        $env:ATLAS_INBOX_CONFIG_PATH = $oldConfigPath
        $env:ATLAS_INBOX_REPO_ROOT = $oldRepoRoot
        $env:ATLAS_INBOX_ADAPTER_PATH = $oldAdapterPath
    }
    $taskOutput = [ordered]@{
        stdout = Get-StackInboxLogMetadata -Path $stdoutPath
        stderr = Get-StackInboxLogMetadata -Path $stderrPath
    }
    if ($Claim.record -is [System.Collections.IDictionary]) { $Claim.record["task_output"] = $taskOutput }
    else { $Claim.record | Add-Member -MemberType NoteProperty -Name task_output -Value $taskOutput -Force }
    Write-StackInboxJsonAtomic -Path $Claim.claim_path -Value $Claim.record
    $result = Read-StackInboxJson -Path ([string]$Claim.record.result_path)
    if ($null -eq $result) { return [pscustomobject]@{ exit_code = $exitCode; result = $null; reason_code = "task_result_missing"; task_output = $taskOutput } }
    return [pscustomobject]@{ exit_code = $exitCode; result = $result; reason_code = "task_result_available"; task_output = $taskOutput }
}

function Invoke-StackInboxRunOnceSweep {
    param(
        [Parameter(Mandatory = $true)][string]$InboxDirectory,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$TaskScriptPath,
        [Parameter(Mandatory = $true)][string]$PowerShellExecutable,
        [string]$TaskName = "AtlasStackInboxSweep",
        [string]$SweepId = "",
        [int]$SettleSeconds = 2,
        [int]$FreshnessMinutes = 30,
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
        [string]$WebSearch = ""
    )

    if ([string]::IsNullOrWhiteSpace($SweepId)) { $SweepId = "sweep-{0}" -f ([guid]::NewGuid().ToString("N")) }
    $correlationId = "atlas-stack-sweep-{0}" -f ([guid]::NewGuid().ToString("N"))
    $startedAt = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
    $sweepDirectory = Join-Path (Join-Path $StateRoot "sweeps") $SweepId
    $receiptPath = Join-Path $sweepDirectory "sweep.json"
    $counts = [ordered]@{ observed = 0; unsettled = 0; admitted = 0; claimed = 0; executed = 0; archived = 0; quarantined = 0; left_in_place = 0; replay_rejected = 0; recovered = 0; pre_move_recovered = 0 }
    $terminalRecords = New-Object System.Collections.Generic.List[object]
    $observations = New-Object System.Collections.Generic.List[string]
    $leaseAttempt = Enter-StackInboxSweepLease -StateRoot $StateRoot -TaskName $TaskName -SweepId $SweepId -CorrelationId $correlationId
    if (-not [bool]$leaseAttempt.acquired) {
        return [pscustomobject]@{ exit_code = 20; status = "overlap_rejected"; reason_code = [string]$leaseAttempt.reason_code; sweep_id = $SweepId; correlation_id = $correlationId; lease = $leaseAttempt; receipt_path = $null; counts = $counts }
    }

    $leaseHistoryPath = $null
    $sweepStatus = "succeeded"
    $failureReason = $null
    try {
        New-Item -ItemType Directory -Path $sweepDirectory -Force | Out-Null
        if (-not (Test-Path -LiteralPath $InboxDirectory -PathType Container)) { New-Item -ItemType Directory -Path $InboxDirectory -Force | Out-Null }
        $owner = Get-StackInboxCurrentProcessIdentity
        $recovery = Get-StackInboxRecoverableClaims -StateRoot $StateRoot -CurrentOwner $owner -SweepId $SweepId -CorrelationId $correlationId
        $claims = New-Object System.Collections.Generic.List[object]
        foreach ($claim in @($recovery.recoverable)) { [void]$claims.Add($claim); $counts.recovered += 1 }
        foreach ($terminal in @($recovery.terminalized)) { [void]$terminalRecords.Add($terminal); $counts.quarantined += 1 }
        $counts.pre_move_recovered = @($recovery.pre_move_recovered).Count

        foreach ($prompt in @(Get-ChildItem -LiteralPath $InboxDirectory -Filter *.md -File | Where-Object { $_.Name -ne "README.md" } | Sort-Object Name)) {
            $counts.observed += 1
            if (-not (Test-StackInboxFileSettled -Path $prompt.FullName -SettleSeconds $SettleSeconds)) {
                $counts.unsettled += 1
                [void]$observations.Add((Write-StackInboxObservation -SweepDirectory $sweepDirectory -Record ([ordered]@{ prompt_path = $prompt.FullName; reason_code = "unsettled"; observed_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow); moved = $false })))
                continue
            }
            $admission = Test-StackInboxAdmission -Path $prompt.FullName -FreshnessMinutes $FreshnessMinutes
            if (-not [bool]$admission.admitted) {
                if ([string]$admission.disposition -eq "quarantine") {
                    $terminal = Quarantine-StackInboxSourcePrompt -Path $prompt.FullName -StateRoot $StateRoot -SweepId $SweepId -Admission $admission
                    [void]$terminalRecords.Add($terminal)
                    $counts.quarantined += 1
                }
                else {
                    $counts.left_in_place += 1
                    [void]$observations.Add((Write-StackInboxObservation -SweepDirectory $sweepDirectory -Record ([ordered]@{ prompt = $admission.evidence; reason_code = $admission.reason_code; observed_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow); moved = $false })))
                }
                continue
            }
            $counts.admitted += 1
            $replay = Find-StackInboxReplayRecord -StateRoot $StateRoot -Admission $admission
            if ($null -ne $replay) {
                $admission.admitted = $false
                $admission.disposition = "quarantine"
                $admission.reason_code = [string]$replay.reason_code
                $admission.details = [ordered]@{ replay_record = $replay.record }
                $terminal = Quarantine-StackInboxSourcePrompt -Path $prompt.FullName -StateRoot $StateRoot -SweepId $SweepId -Admission $admission
                [void]$terminalRecords.Add($terminal)
                $counts.quarantined += 1
                $counts.replay_rejected += 1
                continue
            }
            $claim = New-StackInboxClaim -PromptPath $prompt.FullName -StateRoot $StateRoot -TaskName $TaskName -SweepId $SweepId -CorrelationId $correlationId -Admission $admission -Owner $owner
            [void]$claims.Add($claim)
            $counts.claimed += 1
        }

        foreach ($claim in @($claims.ToArray())) {
            Update-StackInboxSweepLease -LeaseContext $leaseAttempt.context
            $execution = Invoke-StackInboxClaimTask -Claim $claim -TaskScriptPath $TaskScriptPath -PowerShellExecutable $PowerShellExecutable -ConfigPath $ConfigPath -RepoRoot $RepoRoot -AdapterPath $AdapterPath -CodexCommand $CodexCommand -Model $Model -Reasoning $Reasoning -Speed $Speed -Permissions $Permissions -PermissionProfile $PermissionProfile -SandboxMode $SandboxMode -ApprovalPolicy $ApprovalPolicy -WebSearch $WebSearch
            $counts.executed += 1
            if ($null -eq $execution.result) {
                $terminal = Quarantine-StackInboxClaimWithoutExecution -Claim $claim -StateRoot $StateRoot -ReasonCode ([string]$execution.reason_code)
            }
            else {
                $terminal = Complete-StackInboxClaim -Claim $claim -StateRoot $StateRoot -TaskResult $execution.result -TaskExitCode ([int]$execution.exit_code)
            }
            [void]$terminalRecords.Add($terminal)
            if ([string]$terminal.disposition -eq "archived") { $counts.archived += 1 } else { $counts.quarantined += 1 }
            Update-StackInboxSweepLease -LeaseContext $leaseAttempt.context
        }
    }
    catch {
        $sweepStatus = "failed"
        $failureReason = $_.Exception.Message
    }
    finally {
        try { $leaseHistoryPath = Exit-StackInboxSweepLease -LeaseContext $leaseAttempt.context -TerminalStatus "released" }
        catch { $sweepStatus = "failed"; if ([string]::IsNullOrWhiteSpace($failureReason)) { $failureReason = "lease_release_failed: {0}" -f $_.Exception.Message } }
    }

    $receipt = [ordered]@{
        contract_version = $script:StackInboxSweepContractVersion
        task_name = $TaskName
        sweep_id = $SweepId
        correlation_id = $correlationId
        status = $sweepStatus
        reason = $failureReason
        started_at = $startedAt
        terminal_at = ConvertTo-StackInboxUtcString -Value (Get-StackInboxUtcNow)
        counts = $counts
        terminal_records = @($terminalRecords.ToArray() | ForEach-Object { Get-StackInboxObjectValue -Object $_ -Name "terminal_id" })
        observation_paths = @($observations.ToArray())
        lease = [ordered]@{ acquired = $true; history_path = $leaseHistoryPath; stale_owner_diagnosis = $leaseAttempt.stale_owner_diagnosis }
        run_once = $true
    }
    Write-StackInboxJsonAtomic -Path $receiptPath -Value $receipt
    return [pscustomobject]@{ exit_code = if ($sweepStatus -eq "succeeded") { 0 } else { 1 }; status = $sweepStatus; reason_code = $failureReason; sweep_id = $SweepId; correlation_id = $correlationId; receipt_path = $receiptPath; counts = $counts; terminal_records = @($terminalRecords.ToArray()); lease_history_path = $leaseHistoryPath }
}
