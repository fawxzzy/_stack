param(
    [string]$AtlasRoot = "",
    [string]$SourceRepoRoot = "",
    [switch]$Enable,
    [switch]$SkipTaskRegistration,
    [switch]$RequireCommittedSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "CodexRunner.Common.ps1")

function Get-StackInboxTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($hash.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Resolve-StackInboxAtlasRoot {
    param([string]$Requested, [Parameter(Mandatory = $true)][string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { return [System.IO.Path]::GetFullPath($Requested) }
    $candidate = [System.IO.Path]::GetFullPath($RepoRoot)
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if ((Test-Path -LiteralPath (Join-Path $candidate "stack.yaml") -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $candidate "repos\_stack") -PathType Container)) { return $candidate }
        $parent = Split-Path -Parent $candidate
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
    throw "stack_inbox_atlas_root_not_found"
}

function Get-StackInboxLauncherFiles {
    return @(
        [pscustomobject]@{ source = "ops/codex/Invoke-StackInboxSweepLauncher.ps1"; destination = "Invoke-StackInboxSweepLauncher.ps1" },
        [pscustomobject]@{ source = "ops/codex/Start-CodexInboxRunner.ps1"; destination = "ops/codex/Start-CodexInboxRunner.ps1" },
        [pscustomobject]@{ source = "ops/codex/StackInboxSweep.ps1"; destination = "ops/codex/StackInboxSweep.ps1" },
        [pscustomobject]@{ source = "ops/codex/CodexRunner.Common.ps1"; destination = "ops/codex/CodexRunner.Common.ps1" },
        [pscustomobject]@{ source = "ops/codex/Invoke-CodexRepoTask.ps1"; destination = "ops/codex/Invoke-CodexRepoTask.ps1" },
        [pscustomobject]@{ source = "ops/codex/AtlasContractsV2Producer.ps1"; destination = "ops/codex/AtlasContractsV2Producer.ps1" },
        [pscustomobject]@{ source = "ops/codex/config.defaults.toml"; destination = "ops/codex/config.defaults.toml" },
        [pscustomobject]@{ source = "ops/codex/repos/stack/config.toml"; destination = "ops/codex/repos/stack/config.toml" },
        [pscustomobject]@{ source = "ops/codex/repos/stack/adapter.json"; destination = "ops/codex/repos/stack/adapter.json" },
        [pscustomobject]@{ source = "ops/stack/StackWorkerArtifacts.ps1"; destination = "ops/stack/StackWorkerArtifacts.ps1" }
    )
}

function Install-StackInboxLauncherSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedAtlasRoot,
        [bool]$RequireCommittedSource = $false
    )

    $launcherRoot = Join-Path $ResolvedAtlasRoot "runtime\codex\stack\launcher"
    $currentPath = Join-Path $launcherRoot "current"
    $versionsPath = Join-Path $launcherRoot "versions"
    New-Item -ItemType Directory -Path $launcherRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $versionsPath -Force | Out-Null
    $stagingPath = Join-Path $launcherRoot (".staging-{0}" -f ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $stagingPath -ErrorAction Stop | Out-Null
    $manifestFiles = New-Object System.Collections.Generic.List[object]
    try {
        $sourceHead = (& git -C $RepoRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw "stack_inbox_launcher_source_head_unavailable" }
        $sourceCommitted = $true
        foreach ($mapping in @(Get-StackInboxLauncherFiles)) {
            $sourcePath = Join-Path $RepoRoot ([string]$mapping.source).Replace("/", "\")
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw ("stack_inbox_launcher_source_missing: {0}" -f $mapping.source) }
            $sourceTreeOutput = @(& git -C $RepoRoot ls-tree $sourceHead -- ([string]$mapping.source))
            if ($LASTEXITCODE -ne 0) { throw ("stack_inbox_launcher_source_tree_unavailable: {0}" -f $mapping.source) }
            $sourceBlob = $null
            if ($sourceTreeOutput.Count -gt 0 -and [string]$sourceTreeOutput[0] -match '\bblob\s+([0-9a-f]{40,64})\t') { $sourceBlob = [string]$Matches[1] }
            $worktreeBlobOutput = @(& git -C $RepoRoot hash-object ("--path={0}" -f [string]$mapping.source) $sourcePath 2>$null)
            if ($LASTEXITCODE -ne 0 -or $worktreeBlobOutput.Count -eq 0) { throw ("stack_inbox_launcher_source_hash_unavailable: {0}" -f $mapping.source) }
            $worktreeBlob = [string]$worktreeBlobOutput[0].Trim()
            $matchesRevision = -not [string]::IsNullOrWhiteSpace($sourceBlob) -and $worktreeBlob -eq $sourceBlob
            if (-not $matchesRevision) { $sourceCommitted = $false }
            $destinationPath = Join-Path $stagingPath ([string]$mapping.destination).Replace("/", "\")
            New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
            [void]$manifestFiles.Add([ordered]@{
                path = [string]$mapping.destination
                source_path = [string]$mapping.source
                source_blob = $sourceBlob
                source_matches_revision = $matchesRevision
                bytes = (Get-Item -LiteralPath $destinationPath).Length
                sha256 = Get-DeterministicFileSha256 -Path $destinationPath
            })
        }
        if ($RequireCommittedSource -and -not $sourceCommitted) { throw "stack_inbox_launcher_source_not_exact_committed_head" }
        $manifest = [ordered]@{
            contract_version = "atlas.stack.inbox-launcher-manifest.v1"
            source_repository = "_stack"
            source_revision = $sourceHead
            source_committed = $sourceCommitted
            files = @($manifestFiles.ToArray())
        }
        $manifestPath = Join-Path $stagingPath "launcher-manifest.json"
        $manifestJson = ($manifest | ConvertTo-Json -Depth 8) + "`r`n"
        [System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))
        $manifestDigest = Get-DeterministicFileSha256 -Path $manifestPath
        [System.IO.File]::WriteAllText((Join-Path $stagingPath "launcher-manifest.sha256"), "$manifestDigest`r`n", (New-Object System.Text.UTF8Encoding($false)))

        $existingDigest = $null
        if (Test-Path -LiteralPath (Join-Path $currentPath "launcher-manifest.sha256") -PathType Leaf) { $existingDigest = (Get-Content -LiteralPath (Join-Path $currentPath "launcher-manifest.sha256") -Raw).Trim().ToLowerInvariant() }
        if ($existingDigest -eq $manifestDigest) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
            return [pscustomobject]@{ status = "unchanged"; launcher_path = $currentPath; manifest_path = Join-Path $currentPath "launcher-manifest.json"; manifest_sha256 = $manifestDigest; file_count = $manifestFiles.Count }
        }
        if (Test-Path -LiteralPath $currentPath -PathType Container) {
            $preserved = Join-Path $versionsPath ("preserved-{0}-{1}" -f ([DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")), ([guid]::NewGuid().ToString("N")))
            Move-Item -LiteralPath $currentPath -Destination $preserved
        }
        Move-Item -LiteralPath $stagingPath -Destination $currentPath
        return [pscustomobject]@{ status = "installed"; launcher_path = $currentPath; manifest_path = Join-Path $currentPath "launcher-manifest.json"; manifest_sha256 = $manifestDigest; file_count = $manifestFiles.Count }
    }
    catch {
        if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
        throw
    }
}

function New-StackInboxSweepTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$Author,
        [Parameter(Mandatory = $true)][string]$PowerShellExecutable,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [bool]$Enabled
    )

    $escape = { param($value) [System.Security.SecurityElement]::Escape([string]$value) }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $LauncherPath
    $enabledText = if ($Enabled) { "true" } else { "false" }
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$(& $escape $Author)</Author>
    <Description>Runs one bounded, correlated _stack inbox sweep every five minutes and exits.</Description>
    <URI>\AtlasStackInboxSweep</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(& $escape $UserSid)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>true</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>$enabledText</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $escape $PowerShellExecutable)</Command>
      <Arguments>$(& $escape $arguments)</Arguments>
      <WorkingDirectory>$(& $escape $WorkingDirectory)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Assert-StackInboxSweepTaskReadback {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutable,
        [Parameter(Mandatory = $true)][string]$ExpectedLauncher,
        [Parameter(Mandatory = $true)][string]$ExpectedWorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedSid,
        [bool]$ExpectedEnabled
    )
    if ($Task.TaskName -ne "AtlasStackInboxSweep" -or $Task.TaskPath -ne "\") { throw "stack_inbox_task_identity_mismatch" }
    if (@($Task.Actions).Count -ne 1) { throw "stack_inbox_task_action_count_mismatch" }
    $action = @($Task.Actions)[0]
    if ([string]$action.Execute -ne $ExpectedExecutable -or [string]$action.Arguments -ne ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ExpectedLauncher) -or [string]$action.WorkingDirectory -ne $ExpectedWorkingDirectory) { throw "stack_inbox_task_action_mismatch" }
    $currentName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $currentLeafName = @($currentName -split "\\")[-1]
    if ([string]$Task.Principal.UserId -notin @($ExpectedSid, $currentName, $currentLeafName) -or [string]$Task.Principal.LogonType -notin @("InteractiveToken", "Interactive") -or [string]$Task.Principal.RunLevel -notin @("Limited", "LeastPrivilege")) { throw "stack_inbox_task_principal_mismatch" }
    if ([string]$Task.Settings.MultipleInstances -ne "IgnoreNew" -or [bool]$Task.Settings.Enabled -ne $ExpectedEnabled -or -not [bool]$Task.Settings.StartWhenAvailable) { throw "stack_inbox_task_settings_mismatch" }
}

function Invoke-StackInboxSweepTaskInstall {
    param([string]$RequestedAtlasRoot, [string]$RequestedSourceRepoRoot, [bool]$TaskEnabled, [bool]$LauncherOnly, [bool]$RequireCommittedSource = $false)

    if ($env:GITHUB_ACTIONS -eq "true" -and -not $LauncherOnly) {
        throw "stack_inbox_task_registration_forbidden_in_ci"
    }

    $repoRoot = if ([string]::IsNullOrWhiteSpace($RequestedSourceRepoRoot)) { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) } else { [System.IO.Path]::GetFullPath($RequestedSourceRepoRoot) }
    $resolvedAtlasRoot = Resolve-StackInboxAtlasRoot -Requested $RequestedAtlasRoot -RepoRoot $repoRoot
    $launcher = Install-StackInboxLauncherSnapshot -RepoRoot $repoRoot -ResolvedAtlasRoot $resolvedAtlasRoot -RequireCommittedSource $RequireCommittedSource
    $launcherScript = Join-Path $launcher.launcher_path "Invoke-StackInboxSweepLauncher.ps1"
    & (Join-Path $PSHOME "powershell.exe") -NoProfile -ExecutionPolicy Bypass -File $launcherScript -VerifyOnly | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "stack_inbox_launcher_verification_failed" }
    if ($LauncherOnly) { return [pscustomobject]@{ task_registered = $false; launcher = $launcher; atlas_root = $resolvedAtlasRoot } }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    $author = $identity.Name
    $powershellExecutable = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $existing = Get-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\" -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if (@($existing.Actions).Count -ne 1 -or [string]@($existing.Actions)[0].Execute -ne $powershellExecutable -or [string]@($existing.Actions)[0].Arguments -ne ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $launcherScript)) { throw "stack_inbox_existing_task_not_packet_owned" }
    }
    $xml = New-StackInboxSweepTaskXml -UserSid $sid -Author $author -PowerShellExecutable $powershellExecutable -LauncherPath $launcherScript -WorkingDirectory $launcher.launcher_path -Enabled $TaskEnabled
    Register-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\" -Xml $xml -Force | Out-Null
    $task = Get-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\" -ErrorAction Stop
    Assert-StackInboxSweepTaskReadback -Task $task -ExpectedExecutable $powershellExecutable -ExpectedLauncher $launcherScript -ExpectedWorkingDirectory $launcher.launcher_path -ExpectedSid $sid -ExpectedEnabled $TaskEnabled
    $exportedXml = Export-ScheduledTask -TaskName "AtlasStackInboxSweep" -TaskPath "\"
    $xmlSha256 = Get-StackInboxTextSha256 -Text $exportedXml
    $info = $task | Get-ScheduledTaskInfo
    return [pscustomobject]@{
        task_registered = $true
        task_name = $task.TaskName
        task_path = $task.TaskPath
        uri = $task.URI
        state = [string]$task.State
        enabled = [bool]$task.Settings.Enabled
        principal = [ordered]@{ user_id = [string]$task.Principal.UserId; sid = $sid; logon_type = [string]$task.Principal.LogonType; run_level = [string]$task.Principal.RunLevel }
        action = [ordered]@{ executable = [string]$task.Actions[0].Execute; arguments = [string]$task.Actions[0].Arguments; working_directory = [string]$task.Actions[0].WorkingDirectory }
        cadence = "PT5M"
        multiple_instances = [string]$task.Settings.MultipleInstances
        xml_sha256 = $xmlSha256
        exported_xml = $exportedXml
        last_run_time = $info.LastRunTime
        last_task_result = $info.LastTaskResult
        next_run_time = $info.NextRunTime
        launcher = $launcher
        atlas_root = $resolvedAtlasRoot
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $result = Invoke-StackInboxSweepTaskInstall -RequestedAtlasRoot $AtlasRoot -RequestedSourceRepoRoot $SourceRepoRoot -TaskEnabled $Enable.IsPresent -LauncherOnly $SkipTaskRegistration.IsPresent -RequireCommittedSource $RequireCommittedSource.IsPresent
    $result | ConvertTo-Json -Depth 12
}
