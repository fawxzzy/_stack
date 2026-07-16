Set-StrictMode -Version Latest

$codexCommonPath = Join-Path -Path $PSScriptRoot -ChildPath "..\codex\CodexRunner.Common.ps1"
if (-not (Test-Path -LiteralPath $codexCommonPath)) {
    throw ("Codex runner common helpers were not found at {0}." -f $codexCommonPath)
}
. $codexCommonPath

function Get-StackLogicalRepoRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $resolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    try {
        $gitCommonDirectory = (& git -C $resolvedRepoRoot rev-parse --git-common-dir 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitCommonDirectory)) {
            if (-not [System.IO.Path]::IsPathRooted($gitCommonDirectory)) { $gitCommonDirectory = Join-Path $resolvedRepoRoot $gitCommonDirectory }
            $logicalRepoRoot = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($gitCommonDirectory))
            if (-not [string]::IsNullOrWhiteSpace($logicalRepoRoot)) { return $logicalRepoRoot }
        }
    }
    catch { }
    $worktreesRoot = [System.IO.Path]::GetDirectoryName($resolvedRepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($worktreesRoot) -and ([System.IO.Path]::GetFileName($worktreesRoot) -ieq "worktrees")) {
        $codexRoot = [System.IO.Path]::GetDirectoryName($worktreesRoot)
        if (-not [string]::IsNullOrWhiteSpace($codexRoot) -and ([System.IO.Path]::GetFileName($codexRoot) -ieq ".codex")) {
            $logicalRepoRoot = [System.IO.Path]::GetDirectoryName($codexRoot)
            if (-not [string]::IsNullOrWhiteSpace($logicalRepoRoot)) {
                return $logicalRepoRoot
            }
        }
    }

    return $resolvedRepoRoot
}

function Get-StackWorkspaceRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $logicalRepoRoot = Get-StackLogicalRepoRoot -RepoRoot $RepoRoot
    $workspaceRoot = Resolve-Path -LiteralPath (Join-Path -Path $logicalRepoRoot -ChildPath "..\..")
    return $workspaceRoot.Path
}

function Get-StackSha256Digest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return "sha256:{0}" -f ([System.BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-StackLockContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $workspaceRoot = Get-StackWorkspaceRoot -RepoRoot $RepoRoot
    $stackLockPath = Join-Path -Path $workspaceRoot -ChildPath "stack.lock.yaml"
    if (-not (Test-Path -LiteralPath $stackLockPath)) {
        throw ("stack.lock.yaml was not found at {0}." -f $stackLockPath)
    }

    $stackLockText = [System.IO.File]::ReadAllText($stackLockPath)
    if ($stackLockText -notmatch '(?m)^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$') {
        throw ("stack.lock.yaml does not declare lock_digest: {0}" -f $stackLockPath)
    }

    $stackLockDigest = $Matches[1].Trim()
    if ([string]::IsNullOrWhiteSpace($stackLockDigest)) {
        throw ("stack.lock.yaml lock_digest is empty: {0}" -f $stackLockPath)
    }

    return [ordered]@{
        workspaceRoot = $workspaceRoot
        stackLockPath = $stackLockPath
        stackLockDigest = $stackLockDigest
        stackLockFileDigest = Get-StackSha256Digest -Text $stackLockText
    }
}

function Get-StackArtifactDigest {
    param(
        [Parameter(Mandatory = $true)]
        $Artifact
    )

    $json = ($Artifact | ConvertTo-Json -Depth 20)
    return Get-StackSha256Digest -Text ($json + "`n")
}

function Write-StackWorkerArtifact {
    param(
        [Parameter(Mandatory = $true)]
        $Artifact,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = ($Artifact | ConvertTo-Json -Depth 20) + "`r`n"
    [System.IO.File]::WriteAllText($Path, $json)

    return [ordered]@{
        path = $Path
        digest = Get-StackArtifactDigest -Artifact $Artifact
    }
}

function New-StackTouchedRange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoCommit,
        [Parameter(Mandatory = $true)]
        [string]$RepoPath,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int]$StartLine,
        [Parameter(Mandatory = $true)]
        [int]$EndLine,
        [Parameter(Mandatory = $true)]
        [string]$Op,
        [Parameter(Mandatory = $true)]
        [string]$FileDigestBefore
    )

    return [ordered]@{
        repo_path = $RepoPath
        repo_commit = $RepoCommit
        file_digest_before = $FileDigestBefore
        path = $Path.Replace("\", "/")
        start_line = $StartLine
        end_line = $EndLine
        op = $Op
    }
}

function Get-StackFileDigestBefore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$BaseCommit,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $showResult = Invoke-Git -Arguments @("show", ("{0}:{1}" -f $BaseCommit, $Path)) -WorkingDirectory $WorkingDirectory
    if ($showResult.ExitCode -ne 0) {
        return "sha256:absent"
    }

    return Get-StackSha256Digest -Text $showResult.StdOut
}

function Get-StackRangeOperation {
    param([string]$StatusCode)

    switch ($StatusCode) {
        "A" { return "add" }
        "C" { return "modify" }
        "D" { return "delete" }
        "M" { return "modify" }
        "R" { return "rename" }
        "T" { return "modify" }
        "U" { return "modify" }
        "X" { return "modify" }
        default { return "scan" }
    }
}

function Get-StackTouchedRanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string]$CommitSha,
        [Parameter(Mandatory = $true)]
        [string[]]$ChangedPaths
    )

    $parentResult = Invoke-Git -Arguments @("rev-parse", ("{0}^" -f $CommitSha)) -WorkingDirectory $WorkingDirectory
    $baseCommit = if ($parentResult.ExitCode -eq 0) { $parentResult.StdOut.Trim() } else { "4b825dc642cb6eb9a060e54bf8d69288fbee4904" }

    $ranges = New-Object System.Collections.Generic.List[object]
    foreach ($changedPath in $ChangedPaths) {
        if ([string]::IsNullOrWhiteSpace($changedPath)) {
            continue
        }

        $statusResult = Invoke-Git -Arguments @("diff", "--name-status", $baseCommit, $CommitSha, "--", $changedPath) -WorkingDirectory $WorkingDirectory
        if ($statusResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($statusResult.StdOut)) {
            continue
        }

        $statusLine = ($statusResult.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($statusLine)) {
            continue
        }

        $statusToken = ($statusLine -split "`t")[0]
        if ([string]::IsNullOrWhiteSpace($statusToken)) {
            continue
        }

        $op = Get-StackRangeOperation -StatusCode $statusToken.Substring(0, 1)
        $fileDigestBefore = Get-StackFileDigestBefore -WorkingDirectory $WorkingDirectory -BaseCommit $baseCommit -Path $changedPath
        $diffResult = Invoke-Git -Arguments @("diff", "--no-color", "--unified=0", "--no-ext-diff", $baseCommit, $CommitSha, "--", $changedPath) -WorkingDirectory $WorkingDirectory
        if ($diffResult.ExitCode -ne 0) {
            continue
        }

        foreach ($line in ($diffResult.StdOut -split "`r?`n")) {
            if ($line -notmatch '^@@ -(?<oldStart>\d+)(?:,(?<oldLen>\d+))? \+(?<newStart>\d+)(?:,(?<newLen>\d+))? @@') {
                continue
            }

            $newStart = [int]$Matches['newStart']
            $newLen = if ($Matches.ContainsKey('newLen') -and -not [string]::IsNullOrWhiteSpace($Matches['newLen'])) { [int]$Matches['newLen'] } else { 1 }
            $oldStart = [int]$Matches['oldStart']
            $oldLen = if ($Matches.ContainsKey('oldLen') -and -not [string]::IsNullOrWhiteSpace($Matches['oldLen'])) { [int]$Matches['oldLen'] } else { 1 }

            $startLine = if ($op -eq "delete") { $oldStart } else { $newStart }
            $lineCount = if ($op -eq "delete") { $oldLen } else { $newLen }
            if ($lineCount -lt 1) {
                $lineCount = 1
            }

            $endLine = $startLine + $lineCount - 1
            [void]$ranges.Add((New-StackTouchedRange -RepoCommit $CommitSha -RepoPath "." -Path $changedPath -StartLine $startLine -EndLine $endLine -Op $op -FileDigestBefore $fileDigestBefore))
        }
    }

    return @($ranges.ToArray())
}

function New-StackWorkerAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssignmentId,
        [Parameter(Mandatory = $true)]
        [string]$WorkerId,
        [Parameter(Mandatory = $true)]
        [string]$TaskId,
        [Parameter(Mandatory = $true)]
        [string]$StackLockDigest,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedGlobs,
        [Parameter(Mandatory = $true)]
        [string[]]$ForbiddenGlobs,
        [Parameter(Mandatory = $true)]
        [string[]]$InputHandoffRefs,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedOutputs,
        [string]$ToolId = "",
        [AllowNull()]
        [string]$ExtensionId = $null,
        [string]$RegistryDigest = "",
        [string]$Notes = $null
    )

    $artifact = [ordered]@{
        contract_version = "atlas.worker.assignment.v1"
        assignment_id = $AssignmentId
        worker_id = $WorkerId
        task_id = $TaskId
        stack_lock_digest = $StackLockDigest
        allowed_globs = @($AllowedGlobs)
        forbidden_globs = @($ForbiddenGlobs)
        input_handoff_refs = @($InputHandoffRefs)
        expected_outputs = @($ExpectedOutputs)
    }

    if (-not [string]::IsNullOrWhiteSpace($ToolId)) {
        $artifact["tool_id"] = $ToolId
        $artifact["extension_id"] = $ExtensionId
        $artifact["registry_digest"] = $RegistryDigest
    }

    if (-not [string]::IsNullOrWhiteSpace($Notes)) {
        $artifact["notes"] = $Notes
    }

    return $artifact
}

function New-StackWorkerStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkerId,
        [Parameter(Mandatory = $true)]
        [string]$AssignmentId,
        [Parameter(Mandatory = $true)]
        [string]$State,
        [Parameter(Mandatory = $true)]
        [string]$HeartbeatAt,
        [object[]]$TouchedRanges = @(),
        [string[]]$OutputRefs = @(),
        [AllowNull()]
        [string]$BlockedReason = $null,
        [AllowNull()]
        [string]$MergeRequestRef = $null,
        [string]$ToolId = "",
        [AllowNull()]
        [string]$ExtensionId = $null,
        [string]$RegistryDigest = ""
    )

    $artifact = [ordered]@{
        contract_version = "atlas.worker.status.v1"
        worker_id = $WorkerId
        assignment_id = $AssignmentId
        state = $State
        heartbeat_at = $HeartbeatAt
        touched_ranges = @($TouchedRanges)
        output_refs = @($OutputRefs)
        blocked_reason = $BlockedReason
        merge_request_ref = $MergeRequestRef
    }

    if (-not [string]::IsNullOrWhiteSpace($ToolId)) {
        $artifact["tool_id"] = $ToolId
        $artifact["extension_id"] = $ExtensionId
        $artifact["registry_digest"] = $RegistryDigest
    }

    return $artifact
}

function New-StackWorkerMergeRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MergeRequestId,
        [Parameter(Mandatory = $true)]
        [string]$StackLockDigest,
        [Parameter(Mandatory = $true)]
        [string[]]$ConflictingWorkers,
        [Parameter(Mandatory = $true)]
        [object[]]$Overlaps,
        [Parameter(Mandatory = $true)]
        [string[]]$PausedHandoffRefs,
        [Parameter(Mandatory = $true)]
        [object]$MergeWorkerHandoff,
        [string]$ToolId = "",
        [AllowNull()]
        [string]$ExtensionId = $null,
        [string]$RegistryDigest = "",
        [string]$Notes = $null
    )

    $artifact = [ordered]@{
        contract_version = "atlas.worker.merge-request.v1"
        merge_request_id = $MergeRequestId
        stack_lock_digest = $StackLockDigest
        conflicting_workers = @($ConflictingWorkers)
        overlaps = @($Overlaps)
        paused_handoff_refs = @($PausedHandoffRefs)
        merge_worker_handoff = $MergeWorkerHandoff
    }

    if (-not [string]::IsNullOrWhiteSpace($ToolId)) {
        $artifact["tool_id"] = $ToolId
        $artifact["extension_id"] = $ExtensionId
        $artifact["registry_digest"] = $RegistryDigest
    }

    if (-not [string]::IsNullOrWhiteSpace($Notes)) {
        $artifact["notes"] = $Notes
    }

    return $artifact
}

function Get-StackRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $workspaceRoot = [System.IO.Path]::GetFullPath((Get-StackWorkspaceRoot -RepoRoot $RepoRoot))
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if ($resolvedPath.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = $resolvedPath.Substring($workspaceRoot.Length).TrimStart('\', '/')
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            return "."
        }

        return $relativePath.Replace("\", "/")
    }

    return $resolvedPath.Replace("\", "/")
}

function Resolve-StackReferencePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Reference must not be empty."
    }

    if ($Reference -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        throw ("URI-style references are not supported for filesystem resolution: {0}" -f $Reference)
    }

    if ([System.IO.Path]::IsPathRooted($Reference)) {
        return [System.IO.Path]::GetFullPath($Reference)
    }

    $workspaceRoot = Get-StackWorkspaceRoot -RepoRoot $RepoRoot
    return [System.IO.Path]::GetFullPath((Join-Path -Path $workspaceRoot -ChildPath $Reference))
}

function Resolve-StackRepoRegistryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$RepoId
    )

    $workspaceRoot = Get-StackWorkspaceRoot -RepoRoot $RepoRoot
    $stackYamlPath = Join-Path -Path $workspaceRoot -ChildPath "stack.yaml"
    if (-not (Test-Path -LiteralPath $stackYamlPath)) {
        throw ("stack.yaml was not found at {0}." -f $stackYamlPath)
    }

    $lines = @(Get-Content -LiteralPath $stackYamlPath)
    $inRepoRegistry = $false
    $inTargetRepo = $false

    foreach ($line in $lines) {
        if (-not $inRepoRegistry) {
            if ($line -match '^\s*repo_registry:\s*$') {
                $inRepoRegistry = $true
            }
            continue
        }

        if ($line -match '^\S') {
            break
        }

        if ($line -match '^\s{2}(?<repoId>[A-Za-z0-9._-]+):\s*$') {
            $inTargetRepo = ([string]$Matches.repoId -eq [string]$RepoId)
            continue
        }

        if ($inTargetRepo -and $line -match '^\s{4}path:\s*(?<path>.+?)\s*$') {
            $repoPathValue = $Matches.path.Trim()
            return Resolve-RepoPath -Root $workspaceRoot -Value $repoPathValue
        }
    }

    throw ("Repo registry entry '{0}' does not declare a path in {1}." -f $RepoId, $stackYamlPath)
}

function Normalize-StackHandoffRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        return $Reference
    }

    if ($Reference -match '^[A-Za-z0-9+.-]+://') {
        return $Reference
    }

    try {
        if ([System.IO.Path]::IsPathRooted($Reference) -or (Test-Path -LiteralPath $Reference)) {
            return Get-StackRelativePath -RepoRoot $RepoRoot -Path $Reference
        }
    }
    catch {
        return $Reference.Replace("\", "/")
    }

    return $Reference.Replace("\", "/")
}

function Resolve-AtlasObservationSessionId {
    param(
        [string]$WorkerId = "",
        [string]$AssignmentId = "",
        [string[]]$SourceArtifactRefs = @(),
        [string]$FallbackSessionId = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($FallbackSessionId)) {
        return $FallbackSessionId
    }

    $candidates = @($SourceArtifactRefs + @($AssignmentId, $WorkerId)) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { ([string]$_).Replace("\", "/") }

    foreach ($candidate in $candidates) {
        if ($candidate -match '(?:^|/)runtime/atlas/sessions/(?<session>[^/]+)/') {
            return [string]$Matches.session
        }
        if ($candidate -match '^(?<session>session-.+)-assignment(?:[-/]|$)') {
            return [string]$Matches.session
        }
        if ($candidate -match '^(?<session>session-.+)-worker(?:[-/]|$)') {
            return [string]$Matches.session
        }
        if ($candidate -match '^assignment-(?<session>.+)$') {
            return [string]$Matches.session
        }
        if ($candidate -match '^worker-(?<session>.+)$') {
            return [string]$Matches.session
        }
    }

    return $null
}

function Resolve-AtlasGovernedFlowContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string[]]$References = @()
    )

    $normalizedReferences = @(
        $References |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Normalize-StackHandoffRef -RepoRoot $RepoRoot -Reference ([string]$_) } |
        Select-Object -Unique
    )
    if ($normalizedReferences.Count -eq 0) {
        return $null
    }

    $sessionId = $null
    $stackLockDigest = $null
    $toolId = $null
    $extensionId = $null
    $registryDigest = $null
    $sourceArtifactRefs = New-Object System.Collections.Generic.List[string]

    foreach ($reference in $normalizedReferences) {
        if ([string]::IsNullOrWhiteSpace($reference) -or $reference -match '^[A-Za-z0-9+.-]+://') {
            continue
        }

        $absolutePath = $null
        try {
            $absolutePath = Resolve-StackReferencePath -RepoRoot $RepoRoot -Reference $reference
        }
        catch {
            continue
        }

        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            continue
        }

        $artifact = $null
        try {
            $artifact = Read-StackJsonArtifact -Path $absolutePath
        }
        catch {
            continue
        }

        $relativeRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $absolutePath
        if (-not [string]::IsNullOrWhiteSpace($relativeRef)) {
            [void]$sourceArtifactRefs.Add($relativeRef)
        }

        $artifactWorkerId = [string](Get-ObjectPropertyValue -Object $artifact -Name "worker_id" -DefaultValue "")
        $artifactAssignmentId = [string](Get-ObjectPropertyValue -Object $artifact -Name "assignment_id" -DefaultValue "")
        $artifactSessionId = [string](Get-ObjectPropertyValue -Object $artifact -Name "session_id" -DefaultValue "")
        $artifactContractVersion = [string](Get-ObjectPropertyValue -Object $artifact -Name "contract_version" -DefaultValue "")
        $artifactStackLockDigest = [string](Get-ObjectPropertyValue -Object $artifact -Name "stack_lock_digest" -DefaultValue "")
        $artifactToolId = [string](Get-ObjectPropertyValue -Object $artifact -Name "tool_id" -DefaultValue "")
        $artifactExtensionId = [string](Get-ObjectPropertyValue -Object $artifact -Name "extension_id" -DefaultValue "")
        $artifactRegistryDigest = [string](Get-ObjectPropertyValue -Object $artifact -Name "registry_digest" -DefaultValue "")

        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            $sessionId = Resolve-AtlasObservationSessionId `
                -WorkerId $artifactWorkerId `
                -AssignmentId $artifactAssignmentId `
                -SourceArtifactRefs @($relativeRef)
            if ([string]::IsNullOrWhiteSpace($sessionId) -and -not [string]::IsNullOrWhiteSpace($artifactSessionId)) {
                $sessionId = $artifactSessionId
            }
        }

        if ($artifactContractVersion -eq "atlas.session.v1") {
            if ([string]::IsNullOrWhiteSpace($sessionId) -and -not [string]::IsNullOrWhiteSpace($artifactSessionId)) {
                $sessionId = $artifactSessionId
            }
            if ([string]::IsNullOrWhiteSpace($stackLockDigest) -and -not [string]::IsNullOrWhiteSpace($artifactStackLockDigest)) {
                $stackLockDigest = $artifactStackLockDigest
            }

            $governedSurfaces = Get-ObjectPropertyValue -Object $artifact -Name "governed_surfaces" -DefaultValue $null
            if ($null -ne $governedSurfaces) {
                $surfaceRegistryDigest = [string](Get-ObjectPropertyValue -Object $governedSurfaces -Name "registry_digest" -DefaultValue "")
                if ([string]::IsNullOrWhiteSpace($registryDigest) -and -not [string]::IsNullOrWhiteSpace($surfaceRegistryDigest)) {
                    $registryDigest = $surfaceRegistryDigest
                }

                $executionSurface = Get-ObjectPropertyValue -Object $governedSurfaces -Name "execution" -DefaultValue $null
                if ($null -ne $executionSurface) {
                    $executionToolId = [string](Get-ObjectPropertyValue -Object $executionSurface -Name "tool_id" -DefaultValue "")
                    $executionExtensionId = [string](Get-ObjectPropertyValue -Object $executionSurface -Name "extension_id" -DefaultValue "")
                    if ([string]::IsNullOrWhiteSpace($toolId) -and -not [string]::IsNullOrWhiteSpace($executionToolId)) {
                        $toolId = $executionToolId
                    }
                    if ($null -eq $extensionId -and -not [string]::IsNullOrWhiteSpace($executionExtensionId)) {
                        $extensionId = $executionExtensionId
                    }
                }
            }

            continue
        }

        if ([string]::IsNullOrWhiteSpace($stackLockDigest) -and -not [string]::IsNullOrWhiteSpace($artifactStackLockDigest)) {
            $stackLockDigest = $artifactStackLockDigest
        }
        if ([string]::IsNullOrWhiteSpace($toolId) -and -not [string]::IsNullOrWhiteSpace($artifactToolId)) {
            $toolId = $artifactToolId
        }
        if ($null -eq $extensionId -and -not [string]::IsNullOrWhiteSpace($artifactExtensionId)) {
            $extensionId = $artifactExtensionId
        }
        if ([string]::IsNullOrWhiteSpace($registryDigest) -and -not [string]::IsNullOrWhiteSpace($artifactRegistryDigest)) {
            $registryDigest = $artifactRegistryDigest
        }
    }

    if (
        [string]::IsNullOrWhiteSpace($sessionId) -or
        [string]::IsNullOrWhiteSpace($stackLockDigest) -or
        [string]::IsNullOrWhiteSpace($toolId) -or
        [string]::IsNullOrWhiteSpace($registryDigest)
    ) {
        return $null
    }

    return [ordered]@{
        session_id = $sessionId
        stack_lock_digest = $stackLockDigest
        tool_id = $toolId
        extension_id = $extensionId
        registry_digest = $registryDigest
        source_artifact_refs = @($sourceArtifactRefs | Select-Object -Unique)
    }
}

function New-AtlasGovernedObservationDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SessionId,
        [Parameter(Mandatory = $true)]
        [string]$StackLockDigest,
        [Parameter(Mandatory = $true)]
        [string]$ToolId,
        [Parameter(Mandatory = $true)]
        [string]$RegistryDigest,
        [string]$WorkerId = "",
        [string]$AssignmentId = "",
        [AllowNull()]
        [string]$ExtensionId = $null,
        [string[]]$SourceArtifactRefs = @(),
        [hashtable]$AdditionalDetails = $null
    )

    $details = [ordered]@{
        session_id = $SessionId
        stack_lock_digest = $StackLockDigest
        tool_id = $ToolId
        registry_digest = $RegistryDigest
        source_artifact_refs = @(
            $SourceArtifactRefs |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [string]$_ } |
            Select-Object -Unique
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkerId)) {
        $details["worker_id"] = $WorkerId
    }
    if (-not [string]::IsNullOrWhiteSpace($AssignmentId)) {
        $details["assignment_id"] = $AssignmentId
    }
    if (-not [string]::IsNullOrWhiteSpace($ExtensionId)) {
        $details["extension_id"] = $ExtensionId
    }
    if ($null -ne $AdditionalDetails) {
        foreach ($entry in $AdditionalDetails.GetEnumerator()) {
            if ($null -ne $entry.Value) {
                $details[[string]$entry.Key] = $entry.Value
            }
        }
    }

    return $details
}

function Publish-AtlasObservation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        [Parameter(Mandatory = $true)]
        [string]$ObservationType,
        [Parameter(Mandatory = $true)]
        [string]$SourceKind,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$SourceRef,
        [AllowNull()]
        [string]$ObservedAt = $null,
        [AllowNull()]
        [string]$ScopeRef = $null,
        [hashtable]$Details = $null
    )

    $workspaceRoot = Get-StackWorkspaceRoot -RepoRoot $RepoRoot
    $observationScriptPath = Join-Path -Path $workspaceRoot -ChildPath "ops\atlas\observations.py"
    if (-not (Test-Path -LiteralPath $observationScriptPath)) {
        throw ("ATLAS observation helper was not found at {0}." -f $observationScriptPath)
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    $detailsPayload = if ($null -ne $Details) { $Details } else { @{} }
    [void]$arguments.Add("-m")
    [void]$arguments.Add("ops.atlas.observations")
    [void]$arguments.Add("emit")
    [void]$arguments.Add("--root")
    [void]$arguments.Add($workspaceRoot)
    [void]$arguments.Add("--owner")
    [void]$arguments.Add($Owner)
    [void]$arguments.Add("--observation-type")
    [void]$arguments.Add($ObservationType)
    [void]$arguments.Add("--source-kind")
    [void]$arguments.Add($SourceKind)
    [void]$arguments.Add("--status")
    [void]$arguments.Add($Status)
    [void]$arguments.Add("--source-ref")
    [void]$arguments.Add($SourceRef)
    [void]$arguments.Add("--details-json")
    [void]$arguments.Add(($detailsPayload | ConvertTo-Json -Depth 32 -Compress))

    if (-not [string]::IsNullOrWhiteSpace($ObservedAt)) {
        [void]$arguments.Add("--observed-at")
        [void]$arguments.Add($ObservedAt)
    }
    if (-not [string]::IsNullOrWhiteSpace($ScopeRef)) {
        [void]$arguments.Add("--scope-ref")
        [void]$arguments.Add($ScopeRef)
    }

    $result = Invoke-ProcessCapture -FilePath "python" -ArgumentList @($arguments.ToArray()) -WorkingDirectory $workspaceRoot
    if ($result.ExitCode -ne 0) {
        $errorText = if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { $result.StdErr.Trim() } else { $result.StdOut.Trim() }
        throw ("ATLAS observation emission failed for '{0}' ({1}): {2}" -f $ObservationType, $SourceRef, $errorText)
    }

    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        return $null
    }

    return $result.StdOut | ConvertFrom-Json
}

function Read-StackJsonArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Artifact path does not exist: {0}" -f $Path)
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw ("Artifact file is empty: {0}" -f $Path)
    }

    return ($raw | ConvertFrom-Json)
}

function Write-StackJsonArtifact {
    param(
        [Parameter(Mandatory = $true)]
        $Artifact,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = ($Artifact | ConvertTo-Json -Depth 32) + "`r`n"
    [System.IO.File]::WriteAllText($Path, $json)

    return [ordered]@{
        path = $Path
        digest = Get-StackSha256Digest -Text $json
    }
}

function Get-StackWorkerArtifactIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactRoot
    )

    $assignmentsById = @{}
    $assignmentsByWorker = @{}
    $statusesByWorker = @{}

    if (-not (Test-Path -LiteralPath $ArtifactRoot)) {
        return [ordered]@{
            assignmentsById = $assignmentsById
            assignmentsByWorker = $assignmentsByWorker
            statusesByWorker = $statusesByWorker
        }
    }

    foreach ($artifactPath in (Get-ChildItem -LiteralPath $ArtifactRoot -Recurse -File -Filter *.json | Sort-Object FullName)) {
        $artifact = $null
        try {
            $artifact = Read-StackJsonArtifact -Path $artifactPath.FullName
        }
        catch {
            continue
        }

        $contractVersion = [string](Get-ObjectPropertyValue -Object $artifact -Name "contract_version" -DefaultValue "")
        switch ($contractVersion) {
            "atlas.worker.assignment.v1" {
                $entry = [ordered]@{
                    path = $artifactPath.FullName
                    artifact = $artifact
                }
                $assignmentId = [string](Get-ObjectPropertyValue -Object $artifact -Name "assignment_id" -DefaultValue "")
                $workerId = [string](Get-ObjectPropertyValue -Object $artifact -Name "worker_id" -DefaultValue "")
                if ([string]::IsNullOrWhiteSpace($assignmentId) -or [string]::IsNullOrWhiteSpace($workerId)) {
                    continue
                }
                $assignmentsById[$assignmentId] = $entry
                $assignmentsByWorker[$workerId] = $entry
            }
            "atlas.worker.status.v1" {
                $workerId = [string](Get-ObjectPropertyValue -Object $artifact -Name "worker_id" -DefaultValue "")
                if ([string]::IsNullOrWhiteSpace($workerId)) {
                    continue
                }
                if (-not $statusesByWorker.ContainsKey($workerId)) {
                    $statusesByWorker[$workerId] = New-Object System.Collections.Generic.List[object]
                }

                [void]$statusesByWorker[$workerId].Add([ordered]@{
                    path = $artifactPath.FullName
                    artifact = $artifact
                })
            }
            default { }
        }
    }

    return [ordered]@{
        assignmentsById = $assignmentsById
        assignmentsByWorker = $assignmentsByWorker
        statusesByWorker = $statusesByWorker
    }
}

function Get-StackLatestWorkerStatusEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Entries
    )

    return @($Entries | Sort-Object {
            try {
                [DateTimeOffset]::Parse([string]$_.artifact.heartbeat_at)
            }
            catch {
                [DateTimeOffset]::MinValue
            }
        } -Descending | Select-Object -First 1)[0]
}

function Invoke-StackWorkerContextBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$AssignmentId,
        [Parameter(Mandatory = $true)]
        [string]$WorkerId,
        [Parameter(Mandatory = $true)]
        [string]$TaskId,
        [Parameter(Mandatory = $true)]
        [string]$StackLockDigest,
        [string[]]$QueryTerms = @(),
        [string[]]$TaskTags = @(),
        [string]$OutputPath = ""
    )

    $workspaceRoot = Get-StackWorkspaceRoot -RepoRoot $RepoRoot
    $builderPath = Join-Path -Path $workspaceRoot -ChildPath "ops\cortex\build_worker_context.py"
    if (-not (Test-Path -LiteralPath $builderPath)) {
        throw ("Worker context builder was not found at {0}." -f $builderPath)
    }

    $resolvedOutputPath = $OutputPath
    if ([string]::IsNullOrWhiteSpace($resolvedOutputPath)) {
        $resolvedOutputPath = Join-Path -Path $workspaceRoot -ChildPath ("runtime\cortex\context\{0}.json" -f $AssignmentId)
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    [void]$arguments.Add($builderPath)
    [void]$arguments.Add("--assignment-id")
    [void]$arguments.Add($AssignmentId)
    [void]$arguments.Add("--worker-id")
    [void]$arguments.Add($WorkerId)
    [void]$arguments.Add("--task-id")
    [void]$arguments.Add($TaskId)
    [void]$arguments.Add("--stack-lock-digest")
    [void]$arguments.Add($StackLockDigest)
    [void]$arguments.Add("--output-path")
    [void]$arguments.Add($resolvedOutputPath)

    foreach ($queryTerm in @($QueryTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        [void]$arguments.Add("--query-term")
        [void]$arguments.Add([string]$queryTerm)
    }
    foreach ($taskTag in @($TaskTags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        [void]$arguments.Add("--task-tag")
        [void]$arguments.Add([string]$taskTag)
    }

    $result = Invoke-ProcessCapture -FilePath "python" -ArgumentList @($arguments.ToArray()) -WorkingDirectory $workspaceRoot
    if ($result.ExitCode -ne 0) {
        $errorText = if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { $result.StdErr.Trim() } else { $result.StdOut.Trim() }
        throw ("Worker context build failed: {0}" -f $errorText)
    }

    $summary = $result.StdOut | ConvertFrom-Json
    $artifact = Read-StackJsonArtifact -Path $resolvedOutputPath
    return [ordered]@{
        summary = $summary
        artifact = $artifact
        outputPath = $resolvedOutputPath
        relativePath = Get-StackRelativePath -RepoRoot $RepoRoot -Path $resolvedOutputPath
    }
}

function Invoke-StackLifelineExecution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$WorkerAssignmentRef,
        [Parameter(Mandatory = $true)]
        [string]$WorkerStatusRef,
        [Parameter(Mandatory = $true)]
        [string]$CapabilityProfileRef,
        [Parameter(Mandatory = $true)]
        [string]$RequestRef,
        [Parameter(Mandatory = $true)]
        [string]$ApprovalReceiptRef,
        [string]$ReceiptOutputRoot = ""
    )

    $stackLockContext = Get-StackLockContext -RepoRoot $RepoRoot
    $assignmentPath = Resolve-StackReferencePath -RepoRoot $RepoRoot -Reference $WorkerAssignmentRef
    $statusPath = Resolve-StackReferencePath -RepoRoot $RepoRoot -Reference $WorkerStatusRef
    $capabilityPath = Resolve-StackReferencePath -RepoRoot $RepoRoot -Reference $CapabilityProfileRef
    $requestPath = Resolve-StackReferencePath -RepoRoot $RepoRoot -Reference $RequestRef
    $approvalPath = Resolve-StackReferencePath -RepoRoot $RepoRoot -Reference $ApprovalReceiptRef

    $assignment = Read-StackJsonArtifact -Path $assignmentPath
    $status = Read-StackJsonArtifact -Path $statusPath
    $capability = Read-StackJsonArtifact -Path $capabilityPath
    $request = Read-StackJsonArtifact -Path $requestPath
    $approval = Read-StackJsonArtifact -Path $approvalPath

    if ([string]$assignment.contract_version -ne "atlas.worker.assignment.v1") {
        throw ("Worker assignment contract is not atlas.worker.assignment.v1: {0}" -f $assignmentPath)
    }
    if ([string]$status.contract_version -ne "atlas.worker.status.v1") {
        throw ("Worker status contract is not atlas.worker.status.v1: {0}" -f $statusPath)
    }
    if ([string]$request.contract_version -ne "atlas.privileged-action.request.v1") {
        throw ("Privileged action request contract is not atlas.privileged-action.request.v1: {0}" -f $requestPath)
    }
    if ([string]$approval.contract_version -ne "atlas.approval.receipt.v1") {
        throw ("Approval receipt contract is not atlas.approval.receipt.v1: {0}" -f $approvalPath)
    }
    if ([string]$capability.contract_version -ne "atlas.capability.profile.v1") {
        throw ("Capability profile contract is not atlas.capability.profile.v1: {0}" -f $capabilityPath)
    }

    if ([string]$assignment.worker_id -ne [string]$status.worker_id -or [string]$assignment.assignment_id -ne [string]$status.assignment_id) {
        throw "Worker status does not match the assignment artifact."
    }
    if ([string]$assignment.worker_id -ne [string]$request.worker_id -or [string]$assignment.assignment_id -ne [string]$request.assignment_id) {
        throw "Privileged action request does not match the worker assignment."
    }
    if ([string]$request.requested_capability.capability_profile_id -ne [string]$capability.capability_profile_id) {
        throw "Privileged action request does not match the provided capability profile."
    }
    if ([string]$request.request_id -ne [string]$approval.request_id) {
        throw "Approval receipt does not match the privileged action request."
    }
    if ([string]$request.worker_id -ne [string]$approval.worker_id -or [string]$request.assignment_id -ne [string]$approval.assignment_id) {
        throw "Approval receipt does not match the worker assignment."
    }
    if (
        (-not [string]::IsNullOrWhiteSpace([string]$assignment.tool_id) -and [string]$assignment.tool_id -ne [string]$request.tool_id) -or
        (-not [string]::IsNullOrWhiteSpace([string]$status.tool_id) -and [string]$status.tool_id -ne [string]$request.tool_id)
    ) {
        throw "Governed tool_id does not stay aligned across assignment, status, and request artifacts."
    }
    if (
        (-not [string]::IsNullOrWhiteSpace([string]$assignment.registry_digest) -and [string]$assignment.registry_digest -ne [string]$request.registry_digest) -or
        (-not [string]::IsNullOrWhiteSpace([string]$status.registry_digest) -and [string]$status.registry_digest -ne [string]$request.registry_digest)
    ) {
        throw "Governed registry_digest does not stay aligned across assignment, status, and request artifacts."
    }
    if ([string]$assignment.stack_lock_digest -ne [string]$stackLockContext.stackLockDigest -or [string]$request.stack_lock_digest -ne [string]$stackLockContext.stackLockDigest -or [string]$approval.stack_lock_digest -ne [string]$stackLockContext.stackLockDigest) {
        throw "Execution artifacts must all match the current root stack lock digest."
    }

    $operation = [string]$request.action.operation
    if (@("read_only_scan", "scoped_write") -notcontains $operation) {
        throw ("_stack only bridges read_only_scan and dry-run scoped_write actions in this phase; got '{0}'." -f $operation)
    }

    $lifelineRepoRoot = Resolve-StackRepoRegistryPath -RepoRoot $RepoRoot -RepoId "lifeline"
    $lifelineCliPath = Join-Path -Path $lifelineRepoRoot -ChildPath "dist\cli.js"
    if (-not (Test-Path -LiteralPath $lifelineCliPath)) {
        throw ("Lifeline CLI is not built at {0}. Run `pnpm build` in the Lifeline repo first." -f $lifelineCliPath)
    }

    if ([string]::IsNullOrWhiteSpace($ReceiptOutputRoot)) {
        $ReceiptOutputRoot = Join-Path -Path $stackLockContext.workspaceRoot -ChildPath ("runtime\lifeline\worker-execution\{0}" -f [string]$assignment.assignment_id)
    }
    New-Item -ItemType Directory -Path $ReceiptOutputRoot -Force | Out-Null

    $executionResult = Invoke-ProcessCapture `
        -FilePath "node" `
        -ArgumentList @(
            $lifelineCliPath,
            "execute",
            $requestPath,
            "--capability-profile", $capabilityPath,
            "--approval-receipt", $approvalPath,
            "--receipt-dir", $ReceiptOutputRoot
        ) `
        -WorkingDirectory $stackLockContext.workspaceRoot

    $receiptPath = $null
    if ($executionResult.StdOut -match '(?m)^Receipt written:\s*(?<path>.+?)\s*$') {
        $receiptPath = [System.IO.Path]::GetFullPath($Matches.path.Trim())
    }
    if ([string]::IsNullOrWhiteSpace($receiptPath)) {
        $latestReceipt = Get-ChildItem -LiteralPath $ReceiptOutputRoot -File -Filter *.json -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -ne $latestReceipt) {
            $receiptPath = $latestReceipt.FullName
        }
    }
    if ([string]::IsNullOrWhiteSpace($receiptPath) -or -not (Test-Path -LiteralPath $receiptPath)) {
        throw ("Lifeline execute did not emit a readable receipt. stdout: {0}" -f $executionResult.StdOut.Trim())
    }

    $receipt = Read-StackJsonArtifact -Path $receiptPath
    if ([string]$receipt.contract_version -ne "atlas.privileged-action.receipt.v1") {
        throw ("Privileged action receipt contract is not atlas.privileged-action.receipt.v1: {0}" -f $receiptPath)
    }

    $assignmentRefNormalized = Normalize-StackHandoffRef -RepoRoot $RepoRoot -Reference $WorkerAssignmentRef
    $statusRefNormalized = Normalize-StackHandoffRef -RepoRoot $RepoRoot -Reference $WorkerStatusRef
    $requestRefNormalized = Normalize-StackHandoffRef -RepoRoot $RepoRoot -Reference $RequestRef
    $approvalRefNormalized = Normalize-StackHandoffRef -RepoRoot $RepoRoot -Reference $ApprovalReceiptRef
    $capabilityRefNormalized = Normalize-StackHandoffRef -RepoRoot $RepoRoot -Reference $CapabilityProfileRef
    $receiptRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $receiptPath
    $lifelineRepoRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $lifelineRepoRoot

    $updatedOutputRefs = @(
        @($status.output_refs) +
        @($requestRefNormalized, $approvalRefNormalized, $capabilityRefNormalized, $receiptRef)
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [string]$_ } |
        Select-Object -Unique

    $updatedState = [string]$status.state
    if ([string]::IsNullOrWhiteSpace($updatedState)) {
        $updatedState = "completed"
    }

    $blockedReason = [string]$status.blocked_reason
    switch ([string]$receipt.result) {
        "blocked" {
            $updatedState = "blocked"
            $blockedReason = [string]$receipt.blocked_reason
        }
        "failed" {
            $updatedState = "failed"
            $blockedReason = "lifeline_execution_failed"
        }
        default {
            if ($updatedState -ne "failed" -and $updatedState -ne "blocked") {
                $updatedState = "completed"
                $blockedReason = $null
            }
        }
    }

    $statusUpdatePath = Join-Path -Path (Split-Path -Parent $statusPath) -ChildPath ("worker.status.execution.{0}.json" -f (ConvertTo-Slug -Value ([string]$receipt.receipt_id)))
    $statusUpdateArtifact = New-StackWorkerStatus `
        -WorkerId ([string]$assignment.worker_id) `
        -AssignmentId ([string]$assignment.assignment_id) `
        -State $updatedState `
        -HeartbeatAt ([string](Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
        -TouchedRanges @($status.touched_ranges) `
        -OutputRefs @($updatedOutputRefs) `
        -BlockedReason $blockedReason `
        -MergeRequestRef ([string]$status.merge_request_ref) `
        -ToolId ([string]$request.tool_id) `
        -ExtensionId ([string]$request.extension_id) `
        -RegistryDigest ([string]$request.registry_digest)
    [void](Write-StackWorkerArtifact -Artifact $statusUpdateArtifact -Path $statusUpdatePath)
    $statusUpdateRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $statusUpdatePath

    $bridgePath = Join-Path -Path (Split-Path -Parent $statusPath) -ChildPath ("worker.execution.{0}.json" -f (ConvertTo-Slug -Value ([string]$receipt.receipt_id)))
    $bridgeArtifact = [ordered]@{
        schema_version = "atlas.stack.lifeline-execution.v1"
        worker_id = [string]$assignment.worker_id
        assignment_id = [string]$assignment.assignment_id
        stack_lock_digest = [string]$stackLockContext.stackLockDigest
        worker_assignment_ref = $assignmentRefNormalized
        worker_status_ref = $statusRefNormalized
        request_ref = $requestRefNormalized
        approval_receipt_ref = $approvalRefNormalized
        capability_profile_ref = $capabilityRefNormalized
        lifeline_repo_ref = $lifelineRepoRef
        receipt_ref = $receiptRef
        worker_status_update_ref = $statusUpdateRef
        tool_id = [string]$request.tool_id
        extension_id = [string]$request.extension_id
        registry_digest = [string]$request.registry_digest
        execution_mode = [string]$receipt.execution_mode
        result = [string]$receipt.result
        approval_status = [string]$receipt.approval_status
        lifeline_exit_code = [int]$executionResult.ExitCode
    }
    $bridgeArtifact["content_digest"] = Get-StackArtifactDigest -Artifact $bridgeArtifact
    [void](Write-StackJsonArtifact -Artifact $bridgeArtifact -Path $bridgePath)

    return [ordered]@{
        worker_id = [string]$assignment.worker_id
        assignment_id = [string]$assignment.assignment_id
        stack_lock_digest = [string]$stackLockContext.stackLockDigest
        request_ref = $requestRefNormalized
        approval_receipt_ref = $approvalRefNormalized
        capability_profile_ref = $capabilityRefNormalized
        receipt_ref = $receiptRef
        worker_status_update_ref = $statusUpdateRef
        bridge_record_ref = Get-StackRelativePath -RepoRoot $RepoRoot -Path $bridgePath
        tool_id = [string]$request.tool_id
        extension_id = [string]$request.extension_id
        registry_digest = [string]$request.registry_digest
        result = [string]$receipt.result
        approval_status = [string]$receipt.approval_status
        execution_mode = [string]$receipt.execution_mode
        lifeline_exit_code = [int]$executionResult.ExitCode
    }
}

function New-StackMergePromptText {
    param(
        [Parameter(Mandatory = $true)]
        $MergeRequest,
        [Parameter(Mandatory = $true)]
        [string]$MergeRequestRef,
        [Parameter(Mandatory = $true)]
        [string]$MergedHandoffRef,
        [Parameter(Mandatory = $true)]
        [string]$ContextRef
    )

    $pausedRefs = @($MergeRequest.paused_handoff_refs)
    $pausedRefsLine = if ($pausedRefs.Count -gt 0) { $pausedRefs -join ", " } else { "" }
    $queryTerms = @(
        @($MergeRequest.overlaps | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_.path) })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    return @(
        ("Title: Resolve {0}" -f [string]$MergeRequest.merge_request_id)
        ("Branch: {0}" -f [string]$MergeRequest.merge_request_id)
        ("PausedHandoffRefs: {0}" -f $pausedRefsLine)
        ("MergeRequestRefs: {0}" -f $MergeRequestRef)
        ("HandoffRefs: {0}" -f $ContextRef)
        ("QueryTerms: {0}" -f ($queryTerms -join ", "))
        "TaskTags: merge, conflict, supervisor"
        "Verify: pnpm run codex:stack:verify"
        ""
        ("Resolve merge request `{0}` using only the paused handoff refs, the merge request artifact, and the worker context artifact." -f [string]$MergeRequest.merge_request_id)
        ""
        "Rules:"
        "- Do not reconstruct or depend on raw hidden transcript history."
        "- Use the paused handoff refs as the worker context boundary."
        "- Produce a single merged handoff artifact at the reserved output ref."
        "- Keep the merge outcome deterministic and scoped to the reported overlaps."
        ""
        ("Reserved merged handoff output: {0}" -f $MergedHandoffRef)
    ) -join "`r`n"
}

function Invoke-StackSupervisorConsumer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactSearchRoot,
        [string]$SupervisorOutputRoot = "",
        [string]$MergeRequestPath = "",
        [string]$TargetWorkerId = ""
    )

    $stackLockContext = Get-StackLockContext -RepoRoot $RepoRoot
    $workspaceRoot = $stackLockContext.workspaceRoot
    if ([string]::IsNullOrWhiteSpace($SupervisorOutputRoot)) {
        $SupervisorOutputRoot = Join-Path -Path $workspaceRoot -ChildPath "runtime\cortex\supervisor"
    }

    $mergeRequestPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($MergeRequestPath)) {
        $mergeRequestPaths = @([System.IO.Path]::GetFullPath($MergeRequestPath))
    }
    elseif (Test-Path -LiteralPath $SupervisorOutputRoot) {
        $mergeRequestPaths = @(
            Get-ChildItem -LiteralPath $SupervisorOutputRoot -File -Filter *.json |
            Where-Object { $_.Name -notlike "*.merge-handoff.json" } |
            Sort-Object FullName |
            ForEach-Object { $_.FullName }
        )
    }

    $artifactIndex = Get-StackWorkerArtifactIndex -ArtifactRoot $ArtifactSearchRoot
    $processed = New-Object System.Collections.Generic.List[object]

    foreach ($candidatePath in $mergeRequestPaths) {
        $mergeRequest = Read-StackJsonArtifact -Path $candidatePath
        if ([string]$mergeRequest.contract_version -ne "atlas.worker.merge-request.v1") {
            continue
        }
        if ([string]$mergeRequest.stack_lock_digest -ne [string]$stackLockContext.stackLockDigest) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($TargetWorkerId) -and @($mergeRequest.conflicting_workers) -notcontains $TargetWorkerId) {
            continue
        }

        $mergeRequestRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $candidatePath
        $mergeSessionId = Resolve-AtlasObservationSessionId `
            -WorkerId ([string]($mergeRequest.conflicting_workers | Select-Object -First 1)) `
            -AssignmentId "" `
            -SourceArtifactRefs @($mergeRequestRef)
        $mergeOutputRoot = Join-Path -Path $ArtifactSearchRoot -ChildPath ("merge\{0}" -f [string]$mergeRequest.merge_request_id)
        $completionPath = Join-Path -Path $mergeOutputRoot -ChildPath "completion.json"
        if (Test-Path -LiteralPath $completionPath) {
            [void]$processed.Add([ordered]@{
                merge_request_id = [string]$mergeRequest.merge_request_id
                completion_path = Get-StackRelativePath -RepoRoot $RepoRoot -Path $completionPath
                tool_id = [string]$mergeRequest.tool_id
                extension_id = [string]$mergeRequest.extension_id
                registry_digest = [string]$mergeRequest.registry_digest
                already_processed = $true
            })
            continue
        }

        if (
            -not [string]::IsNullOrWhiteSpace($mergeSessionId) -and
            -not [string]::IsNullOrWhiteSpace([string]$mergeRequest.tool_id) -and
            -not [string]::IsNullOrWhiteSpace([string]$mergeRequest.registry_digest)
        ) {
            [void](Publish-AtlasObservation `
                -RepoRoot $RepoRoot `
                -Owner "_stack" `
                -ObservationType "merge_requested" `
                -SourceKind "worker_merge_request" `
                -Status "open" `
                -SourceRef $mergeRequestRef `
                -ObservedAt ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
                -ScopeRef $mergeSessionId `
                -Details (New-AtlasGovernedObservationDetails `
                    -SessionId $mergeSessionId `
                    -StackLockDigest ([string]$mergeRequest.stack_lock_digest) `
                    -ToolId ([string]$mergeRequest.tool_id) `
                    -ExtensionId ([string]$mergeRequest.extension_id) `
                    -RegistryDigest ([string]$mergeRequest.registry_digest) `
                    -SourceArtifactRefs @($mergeRequestRef) `
                    -AdditionalDetails @{
                        conflicting_workers = @($mergeRequest.conflicting_workers)
                        merge_request_id = [string]$mergeRequest.merge_request_id
                    }))
        }

        $pauseStatusRefs = New-Object System.Collections.Generic.List[string]
        $resumeContextRefs = New-Object System.Collections.Generic.List[string]
        $pauseStatusOutputs = New-Object System.Collections.Generic.List[object]
        $resumeContextOutputs = New-Object System.Collections.Generic.List[object]
        $assignmentEntries = New-Object System.Collections.Generic.List[object]

        foreach ($workerId in @($mergeRequest.conflicting_workers)) {
            if (-not $artifactIndex.assignmentsByWorker.ContainsKey([string]$workerId)) {
                throw ("No worker assignment was found for merge-request worker '{0}'." -f [string]$workerId)
            }
            if (-not $artifactIndex.statusesByWorker.ContainsKey([string]$workerId)) {
                throw ("No worker status artifacts were found for merge-request worker '{0}'." -f [string]$workerId)
            }

            $assignmentEntry = $artifactIndex.assignmentsByWorker[[string]$workerId]
            $latestStatusEntry = Get-StackLatestWorkerStatusEntry -Entries @($artifactIndex.statusesByWorker[[string]$workerId].ToArray())
            [void]$assignmentEntries.Add($assignmentEntry)

            $pauseStatusPath = Join-Path -Path (Split-Path -Parent $latestStatusEntry.path) -ChildPath ("worker.status.paused.{0}.json" -f [string]$mergeRequest.merge_request_id)
            $blockedReason = "paused_by_merge_request:{0}" -f [string]$mergeRequest.merge_request_id
            $pauseStatus = New-StackWorkerStatus `
                -WorkerId ([string]$workerId) `
                -AssignmentId ([string]$assignmentEntry.artifact.assignment_id) `
                -State "paused" `
                -HeartbeatAt ([string](Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
                -TouchedRanges @($latestStatusEntry.artifact.touched_ranges) `
                -OutputRefs @($latestStatusEntry.artifact.output_refs) `
                -BlockedReason $blockedReason `
                -MergeRequestRef $mergeRequestRef `
                -ToolId ([string]$latestStatusEntry.artifact.tool_id) `
                -ExtensionId ([string]$latestStatusEntry.artifact.extension_id) `
                -RegistryDigest ([string]$latestStatusEntry.artifact.registry_digest)
            [void](Write-StackWorkerArtifact -Artifact $pauseStatus -Path $pauseStatusPath)
            $pauseStatusRel = Get-StackRelativePath -RepoRoot $RepoRoot -Path $pauseStatusPath
            [void]$pauseStatusRefs.Add($pauseStatusRel)
            [void]$pauseStatusOutputs.Add([ordered]@{
                worker_id = [string]$workerId
                path = $pauseStatusRel
            })
            if (
                -not [string]::IsNullOrWhiteSpace($mergeSessionId) -and
                -not [string]::IsNullOrWhiteSpace([string]$pauseStatus.tool_id) -and
                -not [string]::IsNullOrWhiteSpace([string]$pauseStatus.registry_digest)
            ) {
                [void](Publish-AtlasObservation `
                    -RepoRoot $RepoRoot `
                    -Owner "_stack" `
                    -ObservationType "paused" `
                    -SourceKind "worker_status" `
                    -Status "paused" `
                    -SourceRef $pauseStatusRel `
                    -ObservedAt ([string]$pauseStatus.heartbeat_at) `
                    -ScopeRef $mergeSessionId `
                    -Details (New-AtlasGovernedObservationDetails `
                        -SessionId $mergeSessionId `
                        -WorkerId ([string]$pauseStatus.worker_id) `
                        -AssignmentId ([string]$pauseStatus.assignment_id) `
                        -StackLockDigest ([string]$mergeRequest.stack_lock_digest) `
                        -ToolId ([string]$pauseStatus.tool_id) `
                        -ExtensionId ([string]$pauseStatus.extension_id) `
                        -RegistryDigest ([string]$pauseStatus.registry_digest) `
                        -SourceArtifactRefs @($mergeRequestRef, $pauseStatusRel) `
                        -AdditionalDetails @{
                            merge_request_ref = $mergeRequestRef
                        }))
            }

            $resumeContextPath = Join-Path -Path $mergeOutputRoot -ChildPath ("resume-context.{0}.json" -f [string]$workerId)
            $resumeContext = [ordered]@{
                schema_version = "atlas.stack.resume-context.v1"
                merge_request_id = [string]$mergeRequest.merge_request_id
                worker_id = [string]$workerId
                assignment_id = [string]$assignmentEntry.artifact.assignment_id
                stack_lock_digest = [string]$stackLockContext.stackLockDigest
                tool_id = [string]$mergeRequest.tool_id
                extension_id = [string]$mergeRequest.extension_id
                registry_digest = [string]$mergeRequest.registry_digest
                merge_request_ref = $mergeRequestRef
                paused_status_ref = $pauseStatusRel
                paused_handoff_refs = @($mergeRequest.paused_handoff_refs)
                merge_handoff_ref = [string]$mergeRequest.merge_worker_handoff.handoff_ref
                transcript_dependency = $false
            }
            [void](Write-StackJsonArtifact -Artifact $resumeContext -Path $resumeContextPath)
            $resumeContextRel = Get-StackRelativePath -RepoRoot $RepoRoot -Path $resumeContextPath
            [void]$resumeContextRefs.Add($resumeContextRel)
            [void]$resumeContextOutputs.Add([ordered]@{
                worker_id = [string]$workerId
                assignment_id = [string]$assignmentEntry.artifact.assignment_id
                path = $resumeContextRel
            })
        }

        $mergeWorkerId = [string]$mergeRequest.merge_worker_handoff.worker_id
        $mergeAssignmentId = [string]$mergeRequest.merge_worker_handoff.assignment_id
        $mergeTaskId = [string]$mergeRequest.merge_worker_handoff.task_id
        $mergeContextBuild = Invoke-StackWorkerContextBuild `
            -RepoRoot $RepoRoot `
            -AssignmentId $mergeAssignmentId `
            -WorkerId $mergeWorkerId `
            -TaskId $mergeTaskId `
            -StackLockDigest $stackLockContext.stackLockDigest `
            -QueryTerms @($mergeRequest.overlaps | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_.path) }) `
            -TaskTags @("merge", "conflict", "supervisor")
        $mergeContextRef = [string]$mergeContextBuild.relativePath

        $mergePromptPath = Join-Path -Path $mergeOutputRoot -ChildPath "merge.prompt.md"
        $mergePromptText = New-StackMergePromptText `
            -MergeRequest $mergeRequest `
            -MergeRequestRef $mergeRequestRef `
            -MergedHandoffRef ([string]$mergeRequest.merge_worker_handoff.handoff_ref) `
            -ContextRef $mergeContextRef
        Write-TextFile -Path $mergePromptPath -Content ($mergePromptText + "`r`n")
        $mergePromptRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $mergePromptPath

        $mergeAssignmentPath = Join-Path -Path $mergeOutputRoot -ChildPath "worker.assignment.merge.json"
        $mergeAssignment = New-StackWorkerAssignment `
            -AssignmentId $mergeAssignmentId `
            -WorkerId $mergeWorkerId `
            -TaskId $mergeTaskId `
            -StackLockDigest $stackLockContext.stackLockDigest `
            -AllowedGlobs @($assignmentEntries | ForEach-Object { @($_.artifact.allowed_globs) } | Select-Object -Unique) `
            -ForbiddenGlobs @($assignmentEntries | ForEach-Object { @($_.artifact.forbidden_globs) } | Select-Object -Unique) `
            -InputHandoffRefs @(@($mergeRequest.paused_handoff_refs) + @($mergeRequestRef, $mergeContextRef)) `
            -ExpectedOutputs @([string]$mergeRequest.merge_worker_handoff.handoff_ref, $mergePromptRef) `
            -ToolId ([string]$mergeRequest.merge_worker_handoff.tool_id) `
            -ExtensionId ([string]$mergeRequest.merge_worker_handoff.extension_id) `
            -RegistryDigest ([string]$mergeRequest.merge_worker_handoff.registry_digest) `
            -Notes ("Supervisor-consumed merge assignment for {0}." -f [string]$mergeRequest.merge_request_id)
        [void](Write-StackWorkerArtifact -Artifact $mergeAssignment -Path $mergeAssignmentPath)
        $mergeAssignmentRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $mergeAssignmentPath

        if (
            -not [string]::IsNullOrWhiteSpace($mergeSessionId) -and
            -not [string]::IsNullOrWhiteSpace([string]$mergeAssignment.tool_id) -and
            -not [string]::IsNullOrWhiteSpace([string]$mergeAssignment.registry_digest)
        ) {
            [void](Publish-AtlasObservation `
                -RepoRoot $RepoRoot `
                -Owner "_stack" `
                -ObservationType "merger_assigned" `
                -SourceKind "worker_assignment" `
                -Status "assigned" `
                -SourceRef $mergeAssignmentRef `
                -ObservedAt ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
                -ScopeRef $mergeSessionId `
                -Details (New-AtlasGovernedObservationDetails `
                    -SessionId $mergeSessionId `
                    -WorkerId ([string]$mergeAssignment.worker_id) `
                    -AssignmentId ([string]$mergeAssignment.assignment_id) `
                    -StackLockDigest ([string]$mergeRequest.stack_lock_digest) `
                    -ToolId ([string]$mergeAssignment.tool_id) `
                    -ExtensionId ([string]$mergeAssignment.extension_id) `
                    -RegistryDigest ([string]$mergeAssignment.registry_digest) `
                    -SourceArtifactRefs @($mergeRequestRef, $mergeAssignmentRef, $mergeContextRef, $mergePromptRef) `
                    -AdditionalDetails @{
                        merge_request_ref = $mergeRequestRef
                    }))
        }

        $completion = [ordered]@{
            schema_version = "atlas.stack.supervisor-consumer.v1"
            merge_request_id = [string]$mergeRequest.merge_request_id
            merge_request_ref = $mergeRequestRef
            stack_lock_digest = [string]$stackLockContext.stackLockDigest
            tool_id = [string]$mergeRequest.tool_id
            extension_id = [string]$mergeRequest.extension_id
            registry_digest = [string]$mergeRequest.registry_digest
            pause_statuses = @($pauseStatusOutputs.ToArray())
            resume_contexts = @($resumeContextOutputs.ToArray())
            merge_assignment_ref = $mergeAssignmentRef
            merge_prompt_ref = $mergePromptRef
            merge_context_ref = $mergeContextRef
            merge_handoff_ref = [string]$mergeRequest.merge_worker_handoff.handoff_ref
            transcript_dependency = $false
        }
        $completion = $completion + [ordered]@{
            content_digest = Get-StackArtifactDigest -Artifact $completion
        }
        [void](Write-StackJsonArtifact -Artifact $completion -Path $completionPath)
        $completionRef = Get-StackRelativePath -RepoRoot $RepoRoot -Path $completionPath

        if (
            -not [string]::IsNullOrWhiteSpace($mergeSessionId) -and
            -not [string]::IsNullOrWhiteSpace([string]$mergeRequest.tool_id) -and
            -not [string]::IsNullOrWhiteSpace([string]$mergeRequest.registry_digest)
        ) {
            foreach ($resumeContextOutput in @($resumeContextOutputs.ToArray())) {
                [void](Publish-AtlasObservation `
                    -RepoRoot $RepoRoot `
                    -Owner "_stack" `
                    -ObservationType "resume_ready" `
                    -SourceKind "resume_context" `
                    -Status "ready" `
                    -SourceRef ([string]$resumeContextOutput.path) `
                    -ObservedAt ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) `
                    -ScopeRef $mergeSessionId `
                    -Details (New-AtlasGovernedObservationDetails `
                        -SessionId $mergeSessionId `
                        -WorkerId ([string]$resumeContextOutput.worker_id) `
                        -AssignmentId ([string]$resumeContextOutput.assignment_id) `
                        -StackLockDigest ([string]$mergeRequest.stack_lock_digest) `
                        -ToolId ([string]$mergeRequest.tool_id) `
                        -ExtensionId ([string]$mergeRequest.extension_id) `
                        -RegistryDigest ([string]$mergeRequest.registry_digest) `
                        -SourceArtifactRefs @(
                            $mergeRequestRef,
                            $mergeAssignmentRef,
                            $completionRef,
                            [string]$resumeContextOutput.path,
                            [string]$mergeRequest.merge_worker_handoff.handoff_ref
                        ) `
                        -AdditionalDetails @{
                            merge_completion_ref = $completionRef
                        }))
            }
        }

        [void]$processed.Add([ordered]@{
            merge_request_id = [string]$mergeRequest.merge_request_id
            merge_request_ref = $mergeRequestRef
            pause_statuses = @($pauseStatusOutputs.ToArray())
            resume_contexts = @($resumeContextOutputs.ToArray())
            merge_assignment_ref = $mergeAssignmentRef
            merge_prompt_ref = $mergePromptRef
            merge_context_ref = $mergeContextRef
            merge_handoff_ref = [string]$mergeRequest.merge_worker_handoff.handoff_ref
            tool_id = [string]$mergeRequest.tool_id
            extension_id = [string]$mergeRequest.extension_id
            registry_digest = [string]$mergeRequest.registry_digest
            completion_path = $completionRef
            already_processed = $false
        })
    }

    return [ordered]@{
        stack_lock_digest = [string]$stackLockContext.stackLockDigest
        processed_count = $processed.Count
        merge_requests = @($processed.ToArray())
    }
}
