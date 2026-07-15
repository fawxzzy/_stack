param(
    [Parameter(Mandatory = $true)]
    [string]$PromptPath,
    [Parameter(Mandatory = $true)]
    [string]$CanonicalRootPath,
    [string]$RuntimeConfigPath = ".\ops\codex\repos\stack\config.toml",
    [string]$ExecutionClassPath = ".\ops\codex\execution-classes\atlas-workspace.writer.json",
    [string]$CodexCommand = "",
    [string]$Model = "",
    [string]$Reasoning = "",
    [string]$Speed = "",
    [string]$Permissions = "",
    [string]$PermissionProfile = "",
    [string]$SandboxMode = "",
    [string]$ApprovalPolicy = "",
    [string]$WebSearch = "",
    [string[]]$AdmittedChangedPath = @(),
    [switch]$SkipVerification,
    [switch]$NoCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "AtlasContractsV2Producer.ps1")

$script:CanonicalRootValidationState = $null
$script:CanonicalRootCommonGitDirectory = $null

function Import-CanonicalRuntimeConfiguration {
    param(
        [string]$ScriptRoot,
        [string]$ConfigPath
    )

    $defaultsPath = Join-Path -Path $ScriptRoot -ChildPath "config.defaults.toml"
    $defaultsConfig = @{}
    $repoConfig = @{}
    $config = @{}
    if (Test-Path -LiteralPath $defaultsPath) {
        $defaultsConfig = ConvertFrom-SimpleToml -Path $defaultsPath
        $config = $defaultsConfig
    }

    $resolvedConfigPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $resolvedConfigPath = Resolve-PathFromBase -BasePath (Get-Location).Path -Value $ConfigPath
        if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
            throw ("Runtime config file was not found: {0}" -f $resolvedConfigPath)
        }

        $repoConfig = ConvertFrom-SimpleToml -Path $resolvedConfigPath
        $config = Merge-Hashtable -Base $config -Overlay $repoConfig
    }

    return [pscustomobject]@{
        Config = $config
        DefaultsConfig = $defaultsConfig
        RepoConfig = $repoConfig
        ConfigPath = $resolvedConfigPath
        DefaultsPath = $defaultsPath
    }
}


function Test-ExactRepoRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $false
    }

    $normalized = ([string]$Path).Trim().Replace("\", "/")
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    if (
        $normalized.StartsWith("/") -or
        $normalized.StartsWith("./") -or
        $normalized.StartsWith("../") -or
        $normalized.Contains("/../") -or
        $normalized.Contains("/./") -or
        $normalized -match '[\*\?\[\]]'
    ) {
        return $false
    }

    return $normalized -notlike ".git/*" -and $normalized -ne ".git"
}

function Resolve-AdmittedChangedPaths {
    param(
        [string[]]$ExplicitPaths,
        $PromptRecord
    )

    $candidatePaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(Normalize-RepoRelativePathList -Paths $ExplicitPaths)) {
        if (-not $candidatePaths.Contains($path)) {
            [void]$candidatePaths.Add($path)
        }
    }
    foreach ($path in @(Get-ObjectPropertyValue -Object $PromptRecord -Name "MutationAdmissionPaths" -DefaultValue @())) {
        $normalized = @(Normalize-RepoRelativePathList -Paths @($path))
        foreach ($entry in $normalized) {
            if (-not $candidatePaths.Contains($entry)) {
                [void]$candidatePaths.Add($entry)
            }
        }
    }

    $resolved = @($candidatePaths.ToArray())
    $invalidPaths = @($resolved | Where-Object { -not (Test-ExactRepoRelativePath -Path $_) })
    if ($invalidPaths.Count -gt 0) {
        throw ("Mutation admission requires exact repo-relative paths. Invalid entries: {0}" -f ($invalidPaths -join ", "))
    }

    return $resolved
}

function Resolve-CanonicalRoot {
    param(
        [string]$Path,
        $ExecutionContract
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Canonical workspace root path is required."
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw ("Canonical workspace root must be an explicit absolute path. Found: {0}" -f $Path)
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        throw ("Canonical workspace root does not exist: {0}" -f $resolvedPath)
    }

    $expectedLeafName = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $ExecutionContract -Name "canonicalRoot" -DefaultValue $null) -Name "expectedLeafName" -DefaultValue "ATLAS")
    if (-not [string]::IsNullOrWhiteSpace($expectedLeafName) -and ([System.IO.Path]::GetFileName($resolvedPath) -ine $expectedLeafName)) {
        throw ("Canonical workspace root must end with '{0}'. Found: {1}" -f $expectedLeafName, $resolvedPath)
    }

    $canonicalRootConfig = Get-ObjectPropertyValue -Object $ExecutionContract -Name "canonicalRoot" -DefaultValue $null
    $gitDirectory = Join-Path -Path $resolvedPath -ChildPath ".git"
    $requireGitDirectory = ConvertTo-RunnerBoolean -Value (Get-ObjectPropertyValue -Object $canonicalRootConfig -Name "requireGitDirectory" -DefaultValue $true) -DefaultValue $true
    $gitEntryExists = Test-Path -LiteralPath $gitDirectory
    $gitEntryIsDirectory = Test-Path -LiteralPath $gitDirectory -PathType Container
    $script:CanonicalRootValidationState = [ordered]@{
        requestedPath = $Path
        resolvedPath = $resolvedPath
        expectedLeafName = $expectedLeafName
        requireGitDirectory = $requireGitDirectory
        gitEntryPath = $gitDirectory
        gitEntryExists = $gitEntryExists
        gitEntryIsDirectory = $gitEntryIsDirectory
        reasonCode = $null
    }
    if ($requireGitDirectory -and -not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        $script:CanonicalRootValidationState.reasonCode = "canonical_workspace_git_directory_required"
        throw "canonical_workspace_git_directory_required"
    }

    if (-not $gitEntryExists) {
        throw ("Canonical workspace root is not a git repository: {0}" -f $resolvedPath)
    }

    $topLevelResult = Invoke-Git -Arguments @("rev-parse", "--show-toplevel") -WorkingDirectory $resolvedPath
    Assert-CommandSucceeded -Result $topLevelResult -Description "git rev-parse --show-toplevel"
    $topLevel = [System.IO.Path]::GetFullPath($topLevelResult.StdOut.Trim())
    if ($topLevel -ne $resolvedPath) {
        throw ("Canonical workspace root must be the repository toplevel. Resolved {0} to {1}." -f $resolvedPath, $topLevel)
    }

    $script:CanonicalRootCommonGitDirectory = Resolve-GitPathOutput -WorkingDirectory $resolvedPath -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir") -Description "git rev-parse --path-format=absolute --git-common-dir"

    return $resolvedPath
}

function Get-CanonicalPathMetadata {
    param(
        [string]$RepoRoot,
        [string]$RelativePath
    )

    $absolutePath = [System.IO.Path]::GetFullPath((Join-Path -Path $RepoRoot -ChildPath $RelativePath))
    $repoRootWithSeparator = $RepoRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    if ($absolutePath -ne $RepoRoot -and -not $absolutePath.StartsWith($repoRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Path escapes canonical workspace root: {0}" -f $RelativePath)
    }

    $exists = Test-Path -LiteralPath $absolutePath
    $isDirectory = $false
    $isReparsePoint = $false
    $pathType = "missing"
    if ($exists) {
        $item = Get-Item -LiteralPath $absolutePath -Force
        $attributes = [System.IO.FileAttributes]$item.Attributes
        $isDirectory = [bool]($attributes -band [System.IO.FileAttributes]::Directory)
        $isReparsePoint = [bool]($attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isDirectory) {
            $pathType = if ($isReparsePoint) { "directory-reparse-point" } else { "directory" }
        }
        else {
            $pathType = if ($isReparsePoint) { "file-reparse-point" } else { "file" }
        }
    }

    return [pscustomobject]@{
        relativePath = $RelativePath.Replace("\", "/")
        absolutePath = $absolutePath
        exists = $exists
        isDirectory = $isDirectory
        isReparsePoint = $isReparsePoint
        pathType = $pathType
    }
}

function Test-CanonicalPathEquality {
    param(
        [string]$LeftPath,
        [string]$RightPath
    )

    if ([string]::IsNullOrWhiteSpace($LeftPath) -or [string]::IsNullOrWhiteSpace($RightPath)) {
        return $false
    }

    $comparison = if (Test-WindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $left = [System.IO.Path]::GetFullPath($LeftPath).TrimEnd("\", "/")
    $right = [System.IO.Path]::GetFullPath($RightPath).TrimEnd("\", "/")
    return $left.Equals($right, $comparison)
}

function Test-CanonicalPathDescendant {
    param(
        [string]$Path,
        [string]$ParentPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($ParentPath)) {
        return $false
    }

    $comparison = if (Test-WindowsPlatform) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $resolvedParent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd("\", "/")
    if ($resolvedPath.Equals($resolvedParent, $comparison)) {
        return $false
    }

    $parentPrefix = $resolvedParent + [System.IO.Path]::DirectorySeparatorChar
    return $resolvedPath.StartsWith($parentPrefix, $comparison)
}

function ConvertTo-DigestRelativePath {
    param([string]$RelativePath)

    $normalized = ([string]$RelativePath).Replace("\", "/").Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    return $normalized.Trim("/")
}

function Join-DigestRelativePath {
    param(
        [string]$BasePath,
        [string]$ChildName
    )

    $normalizedBasePath = ConvertTo-DigestRelativePath -RelativePath $BasePath
    $normalizedChildName = ([string]$ChildName).Replace("\", "/").Trim("/")
    if ([string]::IsNullOrWhiteSpace($normalizedBasePath)) {
        return $normalizedChildName
    }

    return "{0}/{1}" -f $normalizedBasePath, $normalizedChildName
}

function Add-HashText {
    param(
        $Hash,
        [string]$Text
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$Text)
    $Hash.AppendData($bytes)
}

function Add-HashBytesFromFile {
    param(
        $Hash,
        [string]$Path
    )

    $buffer = New-Object byte[] 81920
    $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        while (($bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $Hash.AppendData($buffer, 0, $bytesRead)
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

function ConvertTo-Sha256DigestString {
    param([byte[]]$HashBytes)

    return "sha256:{0}" -f ([System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLowerInvariant())
}

function Get-TextDigest {
    param([AllowNull()][string]$Text)

    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        Add-HashText -Hash $hash -Text ([string]$Text)
        return ConvertTo-Sha256DigestString -HashBytes $hash.GetHashAndReset()
    }
    finally {
        $hash.Dispose()
    }
}

function Resolve-GitPathOutput {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments,
        [string]$Description
    )

    $result = Invoke-Git -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -ne 0) {
        $errorText = if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { $result.StdErr.Trim() } else { $result.StdOut.Trim() }
        throw ("{0} failed for {1}: {2}" -f $Description, $WorkingDirectory, $errorText)
    }

    $value = $result.StdOut.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw ("{0} returned an empty path for {1}." -f $Description, $WorkingDirectory)
    }

    return [System.IO.Path]::GetFullPath($value)
}

function Resolve-GitFileTargetPath {
    param([string]$GitFilePath)

    $lines = @(
        (Get-Content -LiteralPath $GitFilePath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($lines.Count -ne 1) {
        throw ("Ambiguous gitfile contents: {0}" -f $GitFilePath)
    }

    $line = [string]$lines[0]
    if (-not $line.StartsWith("gitdir:", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Invalid gitfile contents: {0}" -f $GitFilePath)
    }

    $targetText = $line.Substring(7).Trim()
    if ([string]::IsNullOrWhiteSpace($targetText)) {
        throw ("Gitfile target is empty: {0}" -f $GitFilePath)
    }

    if ([System.IO.Path]::IsPathRooted($targetText)) {
        return [System.IO.Path]::GetFullPath($targetText)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Path $GitFilePath -Parent) -ChildPath $targetText))
}

function Get-RegisteredWorktreeVolatileObservation {
    param([string]$WorkingDirectory)

    $headResult = Invoke-Git -Arguments @("rev-parse", "HEAD") -WorkingDirectory $WorkingDirectory
    if ($headResult.ExitCode -ne 0) {
        $errorText = if (-not [string]::IsNullOrWhiteSpace($headResult.StdErr)) { $headResult.StdErr.Trim() } else { $headResult.StdOut.Trim() }
        throw ("git rev-parse HEAD failed for {0}: {1}" -f $WorkingDirectory, $errorText)
    }

    $statusResult = Invoke-Git -Arguments @("status", "--porcelain=v1", "--branch", "--untracked-files=all") -WorkingDirectory $WorkingDirectory
    if ($statusResult.ExitCode -ne 0) {
        $errorText = if (-not [string]::IsNullOrWhiteSpace($statusResult.StdErr)) { $statusResult.StdErr.Trim() } else { $statusResult.StdOut.Trim() }
        throw ("git status --porcelain=v1 --branch --untracked-files=all failed for {0}: {1}" -f $WorkingDirectory, $errorText)
    }

    $statusText = ($statusResult.StdOut -replace "`r`n", "`n").TrimEnd("`n")
    return [pscustomobject]@{
        headCommit = $headResult.StdOut.Trim()
        statusDigest = Get-TextDigest -Text $statusText
    }
}

function Test-RegisteredWorktreeIdentityMatch {
    param(
        $LeftIdentity,
        $RightIdentity
    )

    if ($null -eq $LeftIdentity -or $null -eq $RightIdentity) {
        return $false
    }

    foreach ($fieldName in @("canonicalWorktreePath", "gitfileTarget", "linkedWorktreeGitDirectory", "ownerCommonGitDirectory")) {
        $leftValue = [string](Get-ObjectPropertyValue -Object $LeftIdentity -Name $fieldName -DefaultValue "")
        $rightValue = [string](Get-ObjectPropertyValue -Object $RightIdentity -Name $fieldName -DefaultValue "")
        if (-not (Test-CanonicalPathEquality -LeftPath $leftValue -RightPath $rightValue)) {
            return $false
        }
    }

    return $true
}

function Resolve-MutableRegisteredWorktreeCandidate {
    param($PathMetadata)

    $gitEntryPath = Join-Path -Path $PathMetadata.absolutePath -ChildPath ".git"
    if (-not (Test-Path -LiteralPath $gitEntryPath)) {
        return [pscustomobject]@{
            isCandidate = $false
            isValid = $false
            errorReason = $null
            record = $null
        }
    }

    if (Test-Path -LiteralPath $gitEntryPath -PathType Container) {
        return [pscustomobject]@{
            isCandidate = $false
            isValid = $false
            errorReason = $null
            record = $null
        }
    }

    try {
        $gitfileTarget = Resolve-GitFileTargetPath -GitFilePath $gitEntryPath
        if (-not (Test-Path -LiteralPath $gitfileTarget -PathType Container)) {
            throw ("Gitfile target does not exist: {0}" -f $gitfileTarget)
        }

        $resolvedGitDirectory = Resolve-GitPathOutput -WorkingDirectory $PathMetadata.absolutePath -Arguments @("rev-parse", "--absolute-git-dir") -Description "git rev-parse --absolute-git-dir"
        $ownerCommonGitDirectory = Resolve-GitPathOutput -WorkingDirectory $PathMetadata.absolutePath -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir") -Description "git rev-parse --path-format=absolute --git-common-dir"
        $resolvedWorktreePath = Resolve-GitPathOutput -WorkingDirectory $PathMetadata.absolutePath -Arguments @("rev-parse", "--show-toplevel") -Description "git rev-parse --show-toplevel"

        if (-not (Test-Path -LiteralPath $resolvedGitDirectory -PathType Container)) {
            throw ("Resolved linked-worktree gitdir does not exist: {0}" -f $resolvedGitDirectory)
        }
        if (-not (Test-Path -LiteralPath $ownerCommonGitDirectory -PathType Container)) {
            throw ("Owner common Git directory does not exist: {0}" -f $ownerCommonGitDirectory)
        }
        if (-not (Test-CanonicalPathEquality -LeftPath $resolvedWorktreePath -RightPath $PathMetadata.absolutePath)) {
            throw ("Registered worktree path mismatch: {0}" -f $resolvedWorktreePath)
        }
        if (-not (Test-CanonicalPathEquality -LeftPath $gitfileTarget -RightPath $resolvedGitDirectory)) {
            throw ("Gitfile target mismatch: {0}" -f $gitfileTarget)
        }

        $linkedWorktreeRoot = Join-Path -Path $ownerCommonGitDirectory -ChildPath "worktrees"
        if (-not (Test-CanonicalPathDescendant -Path $resolvedGitDirectory -ParentPath $linkedWorktreeRoot)) {
            throw ("Resolved linked-worktree gitdir is not beneath owner worktrees: {0}" -f $resolvedGitDirectory)
        }
        if (Test-CanonicalPathEquality -LeftPath $ownerCommonGitDirectory -RightPath $script:CanonicalRootCommonGitDirectory) {
            throw ("Registered worktree is owned by the canonical root repository: {0}" -f $ownerCommonGitDirectory)
        }

        $registrationIdentity = [ordered]@{
            canonicalWorktreePath = $resolvedWorktreePath
            gitfileTarget = $gitfileTarget
            linkedWorktreeGitDirectory = $resolvedGitDirectory
            ownerCommonGitDirectory = $ownerCommonGitDirectory
        }

        return [pscustomobject]@{
            isCandidate = $true
            isValid = $true
            errorReason = $null
            record = [pscustomobject]@{
                source = "registered-worktree-identity"
                preservationKind = "mutable_registered_worktree"
                digest = Get-TextDigest -Text (($registrationIdentity | ConvertTo-Json -Compress))
                registrationIdentity = [pscustomobject]$registrationIdentity
                registrationError = $null
                volatileObservation = Get-RegisteredWorktreeVolatileObservation -WorkingDirectory $PathMetadata.absolutePath
                contentDriftObserved = $false
            }
        }
    }
    catch {
        return [pscustomobject]@{
            isCandidate = $true
            isValid = $false
            errorReason = $_.Exception.Message
            record = $null
        }
    }
}

function Add-DirectoryDigestEntries {
    param(
        $Hash,
        [string]$DirectoryPath,
        [string]$RelativePath
    )

    $childPaths = @([System.IO.Directory]::EnumerateFileSystemEntries($DirectoryPath))
    [System.Array]::Sort($childPaths, [System.StringComparer]::Ordinal)

    foreach ($childPath in $childPaths) {
        $childItem = Get-Item -LiteralPath $childPath -Force
        $attributes = [System.IO.FileAttributes]$childItem.Attributes
        $isDirectory = [bool]($attributes -band [System.IO.FileAttributes]::Directory)
        $isReparsePoint = [bool]($attributes -band [System.IO.FileAttributes]::ReparsePoint)
        $entryType = if ($isDirectory) {
            if ($isReparsePoint) { "directory-reparse-point" } else { "directory" }
        }
        else {
            if ($isReparsePoint) { "file-reparse-point" } else { "file" }
        }
        $entryRelativePath = Join-DigestRelativePath -BasePath $RelativePath -ChildName $childItem.Name
        $contentLength = if ($isDirectory) { 0L } else { [int64]$childItem.Length }

        Add-HashText -Hash $Hash -Text ("entry`0path-length:{0}`0path:{1}`0type:{2}`0content-length:{3}`0" -f $entryRelativePath.Length, $entryRelativePath, $entryType, $contentLength)
        if (-not $isDirectory) {
            Add-HashBytesFromFile -Hash $Hash -Path $childItem.FullName
        }
        Add-HashText -Hash $Hash -Text "`n"

        # Reparse-point directories are fingerprinted as entries but never descended into.
        if ($isDirectory -and -not $isReparsePoint) {
            Add-DirectoryDigestEntries -Hash $Hash -DirectoryPath $childItem.FullName -RelativePath $entryRelativePath
        }
    }
}

function Get-WorkingTreeFileDigest {
    param([string]$AbsolutePath)

    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        Add-HashBytesFromFile -Hash $hash -Path $AbsolutePath
        return ConvertTo-Sha256DigestString -HashBytes $hash.GetHashAndReset()
    }
    finally {
        $hash.Dispose()
    }
}

function Get-WorkingTreeDirectoryDigest {
    param(
        [string]$AbsolutePath,
        [string]$RelativePath,
        [bool]$IsReparsePoint = $false
    )

    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $directoryRelativePath = ConvertTo-DigestRelativePath -RelativePath $RelativePath
        $rootEntryType = if ($IsReparsePoint) { "directory-reparse-point" } else { "directory" }
        Add-HashText -Hash $hash -Text ("entry`0path-length:{0}`0path:{1}`0type:{2}`0content-length:{3}`0`n" -f $directoryRelativePath.Length, $directoryRelativePath, $rootEntryType, 0)
        if (-not $IsReparsePoint) {
            Add-DirectoryDigestEntries -Hash $hash -DirectoryPath $AbsolutePath -RelativePath $directoryRelativePath
        }
        return ConvertTo-Sha256DigestString -HashBytes $hash.GetHashAndReset()
    }
    finally {
        $hash.Dispose()
    }
}

function Resolve-HeadObjectDigest {
    param(
        [string]$WorkingDirectory,
        [string]$RelativePath
    )

    $headPath = ConvertTo-DigestRelativePath -RelativePath $RelativePath
    if ([string]::IsNullOrWhiteSpace($headPath)) {
        return $null
    }

    $objectSpec = "HEAD:{0}" -f $headPath
    $objectTypeResult = Invoke-Git -Arguments @("cat-file", "-t", $objectSpec) -WorkingDirectory $WorkingDirectory
    if ($objectTypeResult.ExitCode -ne 0) {
        return $null
    }

    $objectIdResult = Invoke-Git -Arguments @("rev-parse", $objectSpec) -WorkingDirectory $WorkingDirectory
    if ($objectIdResult.ExitCode -ne 0) {
        return $null
    }

    $objectType = $objectTypeResult.StdOut.Trim()
    $source = switch ($objectType) {
        "blob" { "head-blob" }
        "tree" { "head-tree" }
        default { "head-{0}" -f $objectType }
    }

    return [pscustomobject]@{
        source = $source
        digest = "git:{0}" -f $objectIdResult.StdOut.Trim()
    }
}

function Resolve-DigestValue {
    param(
        [string]$WorkingDirectory,
        $PathMetadata,
        [string]$StatusCode,
        [string]$SnapshotPhase = "initial"
    )

    if ($PathMetadata.exists) {
        if ($PathMetadata.isDirectory) {
            if ($StatusCode -eq "??") {
                $registeredWorktreeCandidate = Resolve-MutableRegisteredWorktreeCandidate -PathMetadata $PathMetadata
                if ($registeredWorktreeCandidate.isCandidate) {
                    if ($registeredWorktreeCandidate.isValid) {
                        return $registeredWorktreeCandidate.record
                    }

                    if ($SnapshotPhase -eq "initial") {
                        throw ("Pre-existing dirty path cannot be classified as mutable_registered_worktree: {0}. {1}" -f $PathMetadata.relativePath, $registeredWorktreeCandidate.errorReason)
                    }

                    return [pscustomobject]@{
                        source = "registered-worktree-identity"
                        preservationKind = "mutable_registered_worktree"
                        digest = $null
                        registrationIdentity = $null
                        registrationError = $registeredWorktreeCandidate.errorReason
                        volatileObservation = $null
                        contentDriftObserved = $false
                    }
                }
            }

            return [pscustomobject]@{
                source = "working-tree-directory"
                digest = Get-WorkingTreeDirectoryDigest -AbsolutePath $PathMetadata.absolutePath -RelativePath $PathMetadata.relativePath -IsReparsePoint $PathMetadata.isReparsePoint
                preservationKind = "protected_ordinary_dirt"
                registrationIdentity = $null
                registrationError = $null
                volatileObservation = $null
                contentDriftObserved = $false
            }
        }

        return [pscustomobject]@{
            source = "working-tree-file"
            digest = Get-WorkingTreeFileDigest -AbsolutePath $PathMetadata.absolutePath
            preservationKind = "protected_ordinary_dirt"
            registrationIdentity = $null
            registrationError = $null
            volatileObservation = $null
            contentDriftObserved = $false
        }
    }

    $headDigest = Resolve-HeadObjectDigest -WorkingDirectory $WorkingDirectory -RelativePath $PathMetadata.relativePath
    if ($null -ne $headDigest) {
        $headDigest | Add-Member -NotePropertyName preservationKind -NotePropertyValue "protected_ordinary_dirt"
        $headDigest | Add-Member -NotePropertyName registrationIdentity -NotePropertyValue $null
        $headDigest | Add-Member -NotePropertyName registrationError -NotePropertyValue $null
        $headDigest | Add-Member -NotePropertyName volatileObservation -NotePropertyValue $null
        $headDigest | Add-Member -NotePropertyName contentDriftObserved -NotePropertyValue $false
        return $headDigest
    }

    return [pscustomobject]@{
        source = "missing"
        digest = $null
        preservationKind = "protected_ordinary_dirt"
        registrationIdentity = $null
        registrationError = $null
        volatileObservation = $null
        contentDriftObserved = $false
    }
}

function Get-DirtySnapshot {
    param(
        [string]$WorkingDirectory,
        [string]$SnapshotPhase = "initial"
    )

    $statusResult = Invoke-Git -Arguments @("status", "--porcelain=v1", "--untracked-files=all") -WorkingDirectory $WorkingDirectory
    Assert-CommandSucceeded -Result $statusResult -Description "git status --porcelain=v1 --untracked-files=all"

    $entries = New-Object System.Collections.Generic.List[object]
    $map = @{}
    foreach ($line in ($statusResult.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $statusCode = if ($line.Length -ge 2) { $line.Substring(0, 2) } else { $line }
        $pathText = if ($line.Length -ge 4) { $line.Substring(3).Trim() } else { "" }
        if ($pathText.Contains(" -> ")) {
            $pathText = ($pathText -split " -> ", 2)[1].Trim()
        }

        $relativePath = $pathText.Replace("\", "/")
        $pathMetadata = Get-CanonicalPathMetadata -RepoRoot $WorkingDirectory -RelativePath $relativePath
        $digestRecord = Resolve-DigestValue -WorkingDirectory $WorkingDirectory -PathMetadata $pathMetadata -StatusCode $statusCode -SnapshotPhase $SnapshotPhase
        $entry = [pscustomobject]@{
            path = $relativePath
            status = $statusCode
            indexStatus = $statusCode.Substring(0, 1)
            worktreeStatus = $statusCode.Substring(1, 1)
            exists = $pathMetadata.exists
            preservationKind = $digestRecord.preservationKind
            digestSource = $digestRecord.source
            digest = $digestRecord.digest
            registrationIdentity = $digestRecord.registrationIdentity
            registrationError = $digestRecord.registrationError
            volatileObservation = $digestRecord.volatileObservation
            contentDriftObserved = [bool]$digestRecord.contentDriftObserved
        }
        $entries.Add($entry) | Out-Null
        $map[$relativePath] = $entry
    }

    return [pscustomobject]@{
        entries = @($entries.ToArray())
        byPath = $map
    }
}

function Filter-DirtySnapshot {
    param(
        $Snapshot,
        [string[]]$ExactPaths,
        [string[]]$Prefixes
    )

    $entries = @(
        $Snapshot.entries |
        Where-Object { -not (Test-InternalArtifactPath -Path ([string]$_.path) -ExactPaths $ExactPaths -Prefixes $Prefixes) }
    )
    $map = @{}
    foreach ($entry in $entries) {
        $map[[string]$entry.path] = $entry
    }

    return [pscustomobject]@{
        entries = $entries
        byPath = $map
    }
}

function Compare-DirtySnapshot {
    param(
        $InitialSnapshot,
        $CurrentSnapshot,
        [string[]]$AdmittedPaths
    )

    $violations = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($InitialSnapshot.entries)) {
        if ($entry.path -in $AdmittedPaths) {
            continue
        }

        $currentEntry = Get-ObjectPropertyValue -Object $CurrentSnapshot.byPath -Name $entry.path -DefaultValue $null
        if ($null -eq $currentEntry) {
            [void]$violations.Add(("Pre-existing dirty path changed unexpectedly: {0} became clean or disappeared." -f $entry.path))
            continue
        }

        if ([string]$entry.preservationKind -ne [string]$currentEntry.preservationKind) {
            [void]$violations.Add(("Pre-existing dirty path changed unexpectedly: {0}" -f $entry.path))
            continue
        }

        if ([string]$entry.preservationKind -eq "mutable_registered_worktree") {
            if (-not [string]::IsNullOrWhiteSpace([string]$currentEntry.registrationError)) {
                [void]$violations.Add(("Pre-existing dirty path changed unexpectedly: {0}" -f $entry.path))
                continue
            }

            if (
                [string]$entry.status -ne [string]$currentEntry.status -or
                -not (Test-RegisteredWorktreeIdentityMatch -LeftIdentity $entry.registrationIdentity -RightIdentity $currentEntry.registrationIdentity)
            ) {
                [void]$violations.Add(("Pre-existing dirty path changed unexpectedly: {0}" -f $entry.path))
                continue
            }

            $currentEntry.contentDriftObserved = (
                [string](Get-ObjectPropertyValue -Object $entry.volatileObservation -Name "headCommit" -DefaultValue "") -ne
                [string](Get-ObjectPropertyValue -Object $currentEntry.volatileObservation -Name "headCommit" -DefaultValue "")
            ) -or (
                [string](Get-ObjectPropertyValue -Object $entry.volatileObservation -Name "statusDigest" -DefaultValue "") -ne
                [string](Get-ObjectPropertyValue -Object $currentEntry.volatileObservation -Name "statusDigest" -DefaultValue "")
            )
            continue
        }

        if (
            [string]$entry.status -ne [string]$currentEntry.status -or
            [string]$entry.digestSource -ne [string]$currentEntry.digestSource -or
            [string]$entry.digest -ne [string]$currentEntry.digest
        ) {
            [void]$violations.Add(("Pre-existing dirty path changed unexpectedly: {0}" -f $entry.path))
        }
    }

    return @($violations.ToArray())
}

function Resolve-TaskChangedPaths {
    param(
        $InitialSnapshot,
        $CurrentSnapshot
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($CurrentSnapshot.entries)) {
        if (-not $InitialSnapshot.byPath.ContainsKey([string]$entry.path)) {
            [void]$paths.Add([string]$entry.path)
        }
    }

    return @($paths.ToArray())
}

function Get-RepoRelativePath {
    param(
        [string]$RepoRoot,
        [string]$AbsolutePath
    )

    if ([string]::IsNullOrWhiteSpace($AbsolutePath)) {
        return $null
    }

    $resolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    $resolvedAbsolutePath = [System.IO.Path]::GetFullPath($AbsolutePath)
    $repoUri = New-Object System.Uri($resolvedRepoRoot)
    $pathUri = New-Object System.Uri($resolvedAbsolutePath)
    $relativeUri = $repoUri.MakeRelativeUri($pathUri)
    return ([System.Uri]::UnescapeDataString($relativeUri.ToString())).Replace("\", "/")
}

function Test-InternalArtifactPath {
    param(
        [string]$Path,
        [string[]]$ExactPaths,
        [string[]]$Prefixes
    )

    $normalizedPath = ([string]$Path).Replace("\", "/")
    if ($normalizedPath -in $ExactPaths) {
        return $true
    }

    foreach ($prefix in $Prefixes) {
        if (-not [string]::IsNullOrWhiteSpace($prefix) -and $normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-AnyInitialStagedDirt {
    param($Snapshot)

    $stagedPaths = @(
        $Snapshot.entries |
        Where-Object { [string]$_.indexStatus -ne " " -and [string]$_.indexStatus -ne "?" } |
        ForEach-Object { [string]$_.path }
    )
    return @($stagedPaths)
}

function Get-LockProcessState {
    param($LockRecord)

    $owner = Get-ObjectPropertyValue -Object $LockRecord -Name "owner" -DefaultValue $null
    if ($null -eq $owner) {
        return "unknown"
    }

    $machine = [string](Get-ObjectPropertyValue -Object $owner -Name "machine" -DefaultValue "")
    $processId = [int](Get-ObjectPropertyValue -Object $owner -Name "process_id" -DefaultValue 0)
    if ([string]::IsNullOrWhiteSpace($machine) -or $machine -ine $env:COMPUTERNAME -or $processId -le 0) {
        return "unknown"
    }

    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        if ($null -ne $process) {
            return "alive"
        }
    }
    catch {
        return "exited"
    }

    return "unknown"
}

function Acquire-CanonicalWriterLock {
    param(
        [string]$LockPath,
        [string]$CanonicalRoot,
        [string]$PromptPath,
        [string]$RunId,
        [int]$StaleAfterMinutes
    )

    $staleDiagnostic = $null
    while ($true) {
        $lockRecord = [ordered]@{
            contract = "atlas.stack.canonical_workspace_lock.v1"
            run_id = $RunId
            canonical_root = $CanonicalRoot
            prompt_path = $PromptPath
            acquired_at = (Get-Date).ToUniversalTime().ToString("o")
            stale_after_minutes = $StaleAfterMinutes
            owner = [ordered]@{
                machine = $env:COMPUTERNAME
                user = $env:USERNAME
                process_id = $PID
                process_name = "powershell"
                script_path = $PSCommandPath
            }
        }

        try {
            $directory = Split-Path -Parent $LockPath
            if (-not [string]::IsNullOrWhiteSpace($directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }

            $fileStream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $writer = New-Object System.IO.StreamWriter($fileStream, [System.Text.UTF8Encoding]::new($false))
                try {
                    $writer.Write((($lockRecord | ConvertTo-Json -Depth 8) + "`r`n"))
                    $writer.Flush()
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $fileStream.Dispose()
            }

            return [pscustomobject]@{
                acquired = $true
                path = $LockPath
                record = [pscustomobject]$lockRecord
                staleDiagnostic = $staleDiagnostic
            }
        }
        catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $LockPath)) {
                continue
            }

            $existingLock = Read-JsonFile -Path $LockPath
            $processState = Get-LockProcessState -LockRecord $existingLock
            $acquiredAtText = [string](Get-ObjectPropertyValue -Object $existingLock -Name "acquired_at" -DefaultValue "")
            $acquiredAt = $null
            $lockAgeMinutes = $null
            if (-not [string]::IsNullOrWhiteSpace($acquiredAtText)) {
                try {
                    $acquiredAt = [datetime]::Parse($acquiredAtText, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    $lockAgeMinutes = [math]::Round((((Get-Date).ToUniversalTime()) - $acquiredAt.ToUniversalTime()).TotalMinutes, 3)
                }
                catch {
                    $acquiredAt = $null
                }
            }

            $isStale = $false
            if ($null -ne $lockAgeMinutes -and $lockAgeMinutes -ge $StaleAfterMinutes -and $processState -ne "alive") {
                $isStale = $true
            }

            if ($isStale) {
                $staleSuffix = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
                $stalePath = Join-Path -Path (Split-Path -Parent $LockPath) -ChildPath ("atlas-workspace-writer.stale-{0}.json" -f $staleSuffix)
                Move-Item -LiteralPath $LockPath -Destination $stalePath -Force
                $staleDiagnostic = [pscustomobject]@{
                    staleLockPath = $stalePath
                    previousLockPath = $LockPath
                    previousLock = $existingLock
                    previousProcessState = $processState
                    previousLockAgeMinutes = $lockAgeMinutes
                }
                continue
            }

            $owner = Get-ObjectPropertyValue -Object $existingLock -Name "owner" -DefaultValue $null
            $ownerMachine = [string](Get-ObjectPropertyValue -Object $owner -Name "machine" -DefaultValue "unknown")
            $ownerUser = [string](Get-ObjectPropertyValue -Object $owner -Name "user" -DefaultValue "unknown")
            $ownerProcessId = [string](Get-ObjectPropertyValue -Object $owner -Name "process_id" -DefaultValue "unknown")
            throw ("Canonical workspace writer lock is already held by {0}\{1} pid {2} at {3}. ProcessState={4}; StaleAfterMinutes={5}." -f $ownerMachine, $ownerUser, $ownerProcessId, $LockPath, $processState, $StaleAfterMinutes)
        }
    }
}

function Release-CanonicalWriterLock {
    param(
        [string]$LockPath,
        [string]$RunId
    )

    if (-not (Test-Path -LiteralPath $LockPath)) {
        return [pscustomobject]@{
            released = $false
            reason = "lock_missing"
        }
    }

    $currentLock = Read-JsonFile -Path $LockPath
    $currentRunId = [string](Get-ObjectPropertyValue -Object $currentLock -Name "run_id" -DefaultValue "")
    if ($currentRunId -ne $RunId) {
        return [pscustomobject]@{
            released = $false
            reason = "lock_owner_changed"
        }
    }

    Remove-Item -LiteralPath $LockPath -Force
    return [pscustomobject]@{
        released = $true
        reason = $null
    }
}

$status = "setup_failed"
$logDirectory = $null
$manifestPath = $null
$summaryPath = $null
$codexStdOutPath = $null
$codexStdErrPath = $null
$archivePath = $null
$runId = $null
$runtimeConfig = $null
$executionContract = $null
$runtimePolicy = $null
$promptRecord = $null
$repoRoot = $null
$commitSha = $null
$commitMessage = $null
$effectiveSandboxMode = $null
$verifyRecords = @()
$commitMetadataPolicy = $null
$commitMetadataArtifactRecord = $null
$commitMetadataArtifactTracked = $false
$commitMetadataArtifactRemoved = $false
$specToDiffPolicy = $null
$specToDiffArtifactRecord = $null
$specToDiffArtifactTracked = $false
$specToDiffArtifactRemoved = $false
$specToDiffFailureReason = $null
$currentDirtySnapshot = $null
$initialDirtySnapshot = $null
$dirtyPreservationViolations = @()
$taskChangedPaths = @()
$admittedChangedPaths = @()
$mutationAdmissionRecord = $null
$lockState = $null
$lockRelease = $null
$lockPath = $null
$lockDirectory = $null
$archiveDirectory = $null
$codexCommandRecord = $null
$codexCommandValue = $null
$executionClass = "canonical_workspace"
$lockStaleAfterMinutes = 30
$localLandingRecord = $null
$specToDiffRecord = $null
$atlasContractsV2 = $null
$atlasContractsV2ReceiptValidation = $null
$atlasContractsV2FailureReason = $null
$atlasContractsV2PreflightFailureReason = $null
$atlasContractsV2Branch = $null
$workerGitState = $null

function Write-CanonicalManifest {
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        return
    }

    $manifest = [ordered]@{
        schemaVersion = "1.0"
        runId = $runId
        status = $status
        executionClass = $executionClass
        promptPath = $PromptPath
        promptTitle = if ($null -ne $promptRecord) { $promptRecord.Title } else { $null }
        canonicalRoot = $repoRoot
        canonicalRootValidation = $script:CanonicalRootValidationState
        runtimeConfigPath = if ($null -ne $runtimeConfig) { $runtimeConfig.ConfigPath } else { $null }
        codexCommand = $codexCommandRecord
        runtimePolicy = Get-RuntimePolicyReceipt -RuntimePolicy $runtimePolicy
        atlasContractsV2 = Get-AtlasContractsV2Surface -Producer $atlasContractsV2 -TerminalStatus $status -ReceiptValidation $atlasContractsV2ReceiptValidation -PreflightFailureReason $atlasContractsV2PreflightFailureReason
        mutationAdmission = if ($null -ne $mutationAdmissionRecord) { $mutationAdmissionRecord } else { $null }
        dirtyInventory = [ordered]@{
            initial = if ($null -ne $initialDirtySnapshot) { @($initialDirtySnapshot.entries) } else { @() }
            final = if ($null -ne $currentDirtySnapshot) { @($currentDirtySnapshot.entries) } else { @() }
            preservationViolations = @($dirtyPreservationViolations)
        }
        changedPaths = @($taskChangedPaths)
        workerGitState = $workerGitState
        verification = @($verifyRecords)
        commit = [ordered]@{
            enabled = $null -ne $commitMetadataPolicy
            message = $commitMessage
        }
        commitSha = $commitSha
        lock = [ordered]@{
            path = $lockPath
            acquired = if ($null -ne $lockState) { [bool]$lockState.acquired } else { $false }
            record = if ($null -ne $lockState) { $lockState.record } else { $null }
            staleDiagnostic = if ($null -ne $lockState) { $lockState.staleDiagnostic } else { $null }
            released = if ($null -ne $lockRelease) { [bool]$lockRelease.released } else { $false }
            releaseReason = if ($null -ne $lockRelease) { $lockRelease.reason } else { $null }
        }
        specToDiff = if ($null -ne $specToDiffRecord) {
            [ordered]@{
                enabled = [bool]$specToDiffRecord.enabled
                validationPassed = [bool]$specToDiffRecord.isValid
                blockingReasons = @($specToDiffRecord.blockingReasons)
                criteria = @($specToDiffRecord.criteria)
                expectedChangedPathMatches = @($specToDiffRecord.expectedChangedPathMatches)
                expectedUnchangedPathViolations = @($specToDiffRecord.expectedUnchangedPathViolations)
                justifiedExpectedUnchangedPaths = @($specToDiffRecord.justifiedExpectedUnchangedPaths)
            }
        }
        else {
            $null
        }
        effectivePolicies = [ordered]@{
            verificationSkipped = [bool]$SkipVerification.IsPresent
            noCommit = [bool]$NoCommit.IsPresent
            autoCommitEnabled = if ($null -ne $executionContract) { ConvertTo-RunnerBoolean -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "autoCommitPolicy" -DefaultValue $null) -Name "enabled" -DefaultValue $true) -DefaultValue $true } else { $true }
            sandboxMode = $effectiveSandboxMode
            pushMode = if ($null -ne $executionContract) { [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "pushPolicy" -DefaultValue $null) -Name "mode" -DefaultValue "") } else { $null }
        }
        localLanding = $localLandingRecord
        workerArtifacts = [ordered]@{
            context = $null
            running = $null
            completion = $null
            merge_request = $null
        }
    }

    Write-TextFile -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 12) + "`r`n")
}

try {
    $runtimeConfig = Import-CanonicalRuntimeConfiguration -ScriptRoot $PSScriptRoot -ConfigPath $RuntimeConfigPath
    $executionClassPath = Resolve-PathFromBase -BasePath (Get-Location).Path -Value $ExecutionClassPath
    if (-not (Test-Path -LiteralPath $executionClassPath)) {
        throw ("Execution class file was not found: {0}" -f $executionClassPath)
    }
    $executionContract = Get-Content -LiteralPath $executionClassPath -Raw | ConvertFrom-Json
    $executionClass = [string](Get-ObjectPropertyValue -Object $executionContract -Name "executionClass" -DefaultValue "canonical_workspace")

    $repoRoot = Resolve-CanonicalRoot -Path $CanonicalRootPath -ExecutionContract $executionContract
    Set-Location -LiteralPath $repoRoot
    $promptRecord = Parse-PromptFile -Path $PromptPath
    $admittedChangedPaths = Resolve-AdmittedChangedPaths -ExplicitPaths $AdmittedChangedPath -PromptRecord $promptRecord
    $mutationAdmissionRecord = [ordered]@{
        defaultMode = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "mutationAdmission" -DefaultValue $null) -Name "defaultMode" -DefaultValue "read-only")
        admittedPaths = @($admittedChangedPaths)
        exactPathRequired = [bool](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "mutationAdmission" -DefaultValue $null) -Name "requireExactPathMatch" -DefaultValue $true)
        unexpectedTaskChangedPaths = @()
    }

    $archiveDirectory = Resolve-PathFromBase -BasePath $repoRoot -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "artifacts" -DefaultValue $null) -Name "archiveDir" -DefaultValue ".codex/archive"))
    $logRoot = Resolve-PathFromBase -BasePath $repoRoot -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "artifacts" -DefaultValue $null) -Name "logsDir" -DefaultValue ".codex/logs"))
    $lockDirectory = Resolve-PathFromBase -BasePath $repoRoot -Value ([string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "artifacts" -DefaultValue $null) -Name "lockDir" -DefaultValue ".codex/locks"))
    $lockFileName = [string](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "lock" -DefaultValue $null) -Name "fileName" -DefaultValue "atlas-workspace-writer.lock.json")
    $lockStaleAfterMinutes = [int](Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "lock" -DefaultValue $null) -Name "staleAfterMinutes" -DefaultValue 30)
    $lockPath = Join-Path -Path $lockDirectory -ChildPath $lockFileName
    foreach ($artifactDirectory in @($archiveDirectory, $logRoot, $lockDirectory)) {
        if (-not [string]::IsNullOrWhiteSpace($artifactDirectory)) {
            New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
        }
    }

    $runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ") + "-" + (ConvertTo-Slug -Value $promptRecord.Title)
    $logDirectory = Join-Path -Path $logRoot -ChildPath $runId
    $manifestPath = Join-Path -Path $logDirectory -ChildPath "run.json"
    $summaryPath = Join-Path -Path $logDirectory -ChildPath "final-summary.md"
    $codexStdOutPath = Join-Path -Path $logDirectory -ChildPath "codex.stdout.log"
    $codexStdErrPath = Join-Path -Path $logDirectory -ChildPath "codex.stderr.log"
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

    $codexCommandRecord = Resolve-CodexCommand -ExplicitCodexCommand $CodexCommand -Config $runtimeConfig.Config -BasePath $repoRoot
    if (-not [bool](Get-ObjectPropertyValue -Object $codexCommandRecord -Name "isNativeExecutable" -DefaultValue $false)) {
        $status = "codex_command_resolution_failed"
        throw (Get-CodexCommandResolutionFailureMessage -ResolutionRecord $codexCommandRecord)
    }
    $codexCommandValue = [string](Get-ObjectPropertyValue -Object $codexCommandRecord -Name "resolvedNativePath" -DefaultValue "")

    $runtimePolicy = Resolve-StackRuntimePolicy `
        -Config $runtimeConfig.Config `
        -RepoConfig $runtimeConfig.RepoConfig `
        -DefaultsConfig $runtimeConfig.DefaultsConfig `
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
    Write-CanonicalManifest

    $commitMetadataPolicy = Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "autoCommitPolicy" -DefaultValue $null) -Name "commitMetadata" -DefaultValue $null
    if ($null -eq $commitMetadataPolicy) {
        throw "Canonical workspace execution class must declare autoCommitPolicy.commitMetadata."
    }
    $specToDiffPolicy = Get-SpecToDiffPromptPolicy -PromptRecord $promptRecord

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
        "- Do not stage, commit, amend, merge, rebase, reset, switch branches, check out another branch, or move Git refs. The runner exclusively owns Git state transitions.",
        "- Do not push. Push remains manual-only."
    ) -join "`r`n"
    $effectivePrompt = $effectivePrompt + "`r`n`r`n" + $commitContractInstructions

    if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        $effectivePrompt = $effectivePrompt + "`r`n`r`n" + (Get-SpecToDiffInstructionBlock -Policy $specToDiffPolicy)
    }

    Write-TextFile -Path (Join-Path -Path $logDirectory -ChildPath "effective.prompt.md") -Content $effectivePrompt
    $commitMetadataArtifactPath = Resolve-PathFromBase -BasePath $repoRoot -Value ([string]$commitMetadataPolicy.artifactPath)
    $specToDiffArtifactPath = if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) { Resolve-PathFromBase -BasePath $repoRoot -Value ([string]$specToDiffPolicy.artifactPath) } else { $null }
    $internalArtifactExactPaths = @(Normalize-RepoRelativePathList -Paths @(
        (Get-RepoRelativePath -RepoRoot $repoRoot -AbsolutePath $lockPath),
        (Get-RepoRelativePath -RepoRoot $repoRoot -AbsolutePath $commitMetadataArtifactPath),
        (Get-RepoRelativePath -RepoRoot $repoRoot -AbsolutePath $specToDiffArtifactPath)
    ))
    $logDirectoryRelativePath = Get-RepoRelativePath -RepoRoot $repoRoot -AbsolutePath $logDirectory
    $lockDirectoryRelativePath = Get-RepoRelativePath -RepoRoot $repoRoot -AbsolutePath $lockDirectory
    $internalArtifactPathPrefixes = @()
    if (-not [string]::IsNullOrWhiteSpace($logDirectoryRelativePath)) {
        $internalArtifactPathPrefixes += "{0}/" -f $logDirectoryRelativePath.TrimEnd("/")
    }
    if (-not [string]::IsNullOrWhiteSpace($lockDirectoryRelativePath)) {
        $internalArtifactPathPrefixes += "{0}/" -f $lockDirectoryRelativePath.TrimEnd("/")
    }

    $verificationCommands = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object (Get-ObjectPropertyValue -Object $executionContract -Name "verification" -DefaultValue $null) -Name "defaultCommands" -DefaultValue @()))
    if (@($promptRecord.Verify).Count -gt 0) {
        $verificationCommands = @($promptRecord.Verify)
    }

    $initialDirtySnapshot = Filter-DirtySnapshot -Snapshot (Get-DirtySnapshot -WorkingDirectory $repoRoot -SnapshotPhase "initial") -ExactPaths $internalArtifactExactPaths -Prefixes $internalArtifactPathPrefixes
    $preExistingStagedPaths = @(Test-AnyInitialStagedDirt -Snapshot $initialDirtySnapshot)
    if ($preExistingStagedPaths.Count -gt 0) {
        $status = "mutation_admission_failed"
        throw ("Canonical workspace writer requires an unstaged baseline before mutation admission. Pre-existing staged paths: {0}" -f ($preExistingStagedPaths -join ", "))
    }

    foreach ($admittedPath in $admittedChangedPaths) {
        if ($initialDirtySnapshot.byPath.ContainsKey($admittedPath)) {
            $status = "mutation_admission_failed"
            throw ("Admitted task-owned path must start clean in the canonical workspace: {0}" -f $admittedPath)
        }
    }

    $lockState = Acquire-CanonicalWriterLock -LockPath $lockPath -CanonicalRoot $repoRoot -PromptPath $PromptPath -RunId $runId -StaleAfterMinutes $lockStaleAfterMinutes
    $status = "prepared"
    Write-CanonicalManifest

    foreach ($runtimeNote in @($runtimePolicy.warnings)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$runtimeNote)) {
            Write-RunnerMessage -Message ([string]$runtimeNote) -Level "WARN"
        }
    }

    $branchResult = Invoke-Git -Arguments @("branch", "--show-current") -WorkingDirectory $repoRoot
    if ($branchResult.ExitCode -eq 0) { $atlasContractsV2Branch = $branchResult.StdOut.Trim() }
    $workerGitState = New-WorkerGitStateGuard -WorkingDirectory $repoRoot -TaskRef "HEAD"
    # The canonical execution class uses the same producer gate as repo tasks.
    # It remains after writer-lock acquisition but before any Codex invocation.
    $atlasContractsV2 = New-AtlasContractsV2Producer `
        -AtlasRoot $repoRoot `
        -LogDirectory $logDirectory `
        -RunId $runId `
        -PromptRecord $promptRecord `
        -RuntimePolicy $runtimePolicy `
        -ExecutionClass $executionClass `
        -Branch $atlasContractsV2Branch `
        -WorkspaceRoot $repoRoot `
        -Worktree $null `
        -WorkerId ("canonical-worker-{0}" -f $runId) `
        -CanonicalWorkspace `
        -CanonicalWriterResource $lockPath `
        -RecoveryCheckpoint $manifestPath `
        -AllowedPaths @($admittedChangedPaths) `
        -ForbiddenPaths @(".git/**") `
        -VerificationCommands @($verificationCommands)
    $effectivePrompt = $effectivePrompt + "`r`n`r`n" + (Get-AtlasContractsV2WorkerInstructions -Producer $atlasContractsV2)
    Write-TextFile -Path (Join-Path -Path $logDirectory -ChildPath "effective.prompt.md") -Content $effectivePrompt
    Write-CanonicalManifest

    $personality = [string](Get-ConfigValue -Config $runtimeConfig.Config -Path @("personality") -DefaultValue "")
    $codexInvocation = New-CodexInvocationPlan `
        -RuntimePolicy $runtimePolicy `
        -SummaryPath $summaryPath `
        -WorktreePath $repoRoot `
        -Personality $personality
    $effectiveSandboxMode = $codexInvocation.legacySandboxMode
    Write-CanonicalManifest

    Write-RunnerMessage -Message ("Running canonical workspace writer against {0}" -f $repoRoot)
    $codexResult = Invoke-ProcessCapture -FilePath $codexCommandValue -ArgumentList @($codexInvocation.arguments) -WorkingDirectory $codexInvocation.workingDirectory -StandardInputText $effectivePrompt
    Write-TextFile -Path $codexStdOutPath -Content $codexResult.StdOut
    Write-TextFile -Path $codexStdErrPath -Content $codexResult.StdErr
    if ($codexResult.ExitCode -ne 0) {
        $status = "codex_failed"
        throw ("Codex exec failed with exit code {0}." -f $codexResult.ExitCode)
    }

    $workerGitState = Complete-WorkerGitStateGuard -InitialState $workerGitState -WorkingDirectory $repoRoot
    if (@($workerGitState.violations).Count -gt 0) {
        $status = "worker_git_state_failed"
        throw ("{0}: {1}" -f $workerGitState.failureCode, ($workerGitState.violations -join ", "))
    }

    $commitMetadataArtifactRecord = Read-CommitMetadataArtifact -Path $commitMetadataArtifactPath
    if ($null -ne $commitMetadataArtifactRecord) {
        $commitMetadataRawPath = Join-Path -Path $logDirectory -ChildPath "commit-meta.raw.json"
        Write-TextFile -Path $commitMetadataRawPath -Content $commitMetadataArtifactRecord.rawContent
        $commitMetadataArtifactTracked = Test-GitPathTracked -Path ([string]$commitMetadataPolicy.artifactPath) -WorkingDirectory $repoRoot
        if (-not $commitMetadataArtifactTracked) {
            Remove-Item -LiteralPath $commitMetadataArtifactPath -Force
            $commitMetadataArtifactRemoved = $true
        }
    }

    if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        $specToDiffArtifactRecord = Read-SpecToDiffArtifact -Path $specToDiffArtifactPath
        if ($null -ne $specToDiffArtifactRecord) {
            $specToDiffRawPath = Join-Path -Path $logDirectory -ChildPath "spec-to-diff.raw.json"
            Write-TextFile -Path $specToDiffRawPath -Content $specToDiffArtifactRecord.rawContent
            $specToDiffArtifactTracked = Test-GitPathTracked -Path ([string]$specToDiffPolicy.artifactPath) -WorkingDirectory $repoRoot
            if (-not $specToDiffArtifactTracked) {
                Remove-Item -LiteralPath $specToDiffArtifactPath -Force
                $specToDiffArtifactRemoved = $true
            }
        }
    }

    $verificationDirectory = Join-Path -Path $logDirectory -ChildPath "verification"
    New-Item -ItemType Directory -Path $verificationDirectory -Force | Out-Null
    if (-not $SkipVerification.IsPresent) {
        $verifyIndex = 0
        foreach ($verificationCommand in $verificationCommands) {
            $verifyIndex += 1
            Write-RunnerMessage -Message ("Running verification command {0}: {1}" -f $verifyIndex, $verificationCommand)
            $verificationResult = Invoke-ShellCommand -Command $verificationCommand -WorkingDirectory $repoRoot
            $verifyStdOutPath = Join-Path -Path $verificationDirectory -ChildPath ("verify-{0:00}.stdout.log" -f $verifyIndex)
            $verifyStdErrPath = Join-Path -Path $verificationDirectory -ChildPath ("verify-{0:00}.stderr.log" -f $verifyIndex)
            Write-TextFile -Path $verifyStdOutPath -Content $verificationResult.StdOut
            Write-TextFile -Path $verifyStdErrPath -Content $verificationResult.StdErr
            $verifyRecords += [pscustomobject]@{
                command = $verificationCommand
                exitCode = $verificationResult.ExitCode
                stdoutPath = $verifyStdOutPath
                stderrPath = $verifyStdErrPath
            }
            if ($verificationResult.ExitCode -ne 0) {
                $status = "verification_failed"
                throw ("Verification command failed: {0}" -f $verificationCommand)
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

    $currentDirtySnapshot = Filter-DirtySnapshot -Snapshot (Get-DirtySnapshot -WorkingDirectory $repoRoot -SnapshotPhase "final") -ExactPaths $internalArtifactExactPaths -Prefixes $internalArtifactPathPrefixes
    $dirtyPreservationViolations = @(Compare-DirtySnapshot -InitialSnapshot $initialDirtySnapshot -CurrentSnapshot $currentDirtySnapshot -AdmittedPaths $admittedChangedPaths)
    if ($dirtyPreservationViolations.Count -gt 0) {
        $status = "dirty_preservation_failed"
        throw $dirtyPreservationViolations[0]
    }

    $taskChangedPaths = @(
        Resolve-TaskChangedPaths -InitialSnapshot $initialDirtySnapshot -CurrentSnapshot $currentDirtySnapshot |
        Where-Object { -not (Test-InternalArtifactPath -Path $_ -ExactPaths $internalArtifactExactPaths -Prefixes $internalArtifactPathPrefixes) }
    )
    $unexpectedTaskChangedPaths = @($taskChangedPaths | Where-Object { $_ -notin $admittedChangedPaths })
    $mutationAdmissionRecord.unexpectedTaskChangedPaths = @($unexpectedTaskChangedPaths)
    if ($unexpectedTaskChangedPaths.Count -gt 0) {
        $status = "mutation_admission_failed"
        throw ("Canonical workspace writer detected unadmitted task-owned changes: {0}" -f ($unexpectedTaskChangedPaths -join ", "))
    }

    if (@($admittedChangedPaths).Count -eq 0 -and @($taskChangedPaths).Count -gt 0) {
        $status = "mutation_admission_failed"
        throw ("Canonical workspace writer is read-only by default. Explicitly admit exact changed paths before mutation. Observed: {0}" -f ($taskChangedPaths -join ", "))
    }

    if (@($taskChangedPaths).Count -eq 0) {
        $status = "success"
        Write-CanonicalManifest
        return
    }

    $specToDiffRecord = if ($null -ne $specToDiffPolicy -and $specToDiffPolicy.enabled) {
        Test-SpecToDiffCompletionProof `
            -PromptRecord $promptRecord `
            -ArtifactRecord $specToDiffArtifactRecord `
            -ChangedPaths $taskChangedPaths `
            -WorkingDirectory $repoRoot
    }
    else {
        $null
    }
    if ($null -ne $specToDiffRecord) {
        $specToDiffValidationPath = Join-Path -Path $logDirectory -ChildPath "spec-to-diff.validation.json"
        Write-TextFile -Path $specToDiffValidationPath -Content (($specToDiffRecord | ConvertTo-Json -Depth 8) + "`r`n")
        if (-not $specToDiffRecord.isValid) {
            $status = "spec_to_diff_failed"
            $specToDiffFailureReason = if ($specToDiffRecord.blockingReasons.Count -gt 0) { [string]$specToDiffRecord.blockingReasons[0] } else { "Spec-to-diff validation failed." }
            throw ("Spec-to-diff verification gate failed: {0}" -f $specToDiffFailureReason)
        }
    }

    $resolvedCommit = Resolve-CommitMetadata -PromptRecord $promptRecord -ArtifactRecord $commitMetadataArtifactRecord -CommitPolicy $commitMetadataPolicy -ChangedPaths $taskChangedPaths -RepoId ([string]$executionContract.repoId)
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

    $autoCommitPolicy = Get-ObjectPropertyValue -Object $executionContract -Name "autoCommitPolicy" -DefaultValue $null
    $autoCommitEnabled = -not $NoCommit.IsPresent -and (ConvertTo-RunnerBoolean -Value (Get-ObjectPropertyValue -Object $autoCommitPolicy -Name "enabled" -DefaultValue $true) -DefaultValue $true)
    if ($autoCommitEnabled) {
        Write-RunnerMessage -Message "Staging exact admitted canonical workspace paths"
        $stagePaths = @($taskChangedPaths | Where-Object { $_ -in $admittedChangedPaths })
        $addArguments = @("add", "--") + $stagePaths
        $addResult = Invoke-Git -Arguments $addArguments -WorkingDirectory $repoRoot
        Assert-CommandSucceeded -Result $addResult -Description "git add -- <exact paths>"

        $cachedResult = Invoke-Git -Arguments @("diff", "--cached", "--name-only", "--relative") -WorkingDirectory $repoRoot
        Assert-CommandSucceeded -Result $cachedResult -Description "git diff --cached --name-only"
        $cachedPaths = @(Normalize-RepoRelativePathList -Paths ($cachedResult.StdOut -split "`r?`n"))
        $unexpectedStaged = @($cachedPaths | Where-Object { $_ -notin $stagePaths })
        $missingStaged = @($stagePaths | Where-Object { $_ -notin $cachedPaths })
        if ($unexpectedStaged.Count -gt 0 -or $missingStaged.Count -gt 0) {
            $status = "staging_failed"
            $problems = @()
            if ($unexpectedStaged.Count -gt 0) {
                $problems += ("unexpected staged paths: {0}" -f ($unexpectedStaged -join ", "))
            }
            if ($missingStaged.Count -gt 0) {
                $problems += ("missing staged paths: {0}" -f ($missingStaged -join ", "))
            }
            throw ("Exact staging contract failed: {0}" -f ($problems -join "; "))
        }

        $gitEnvironment = @{}
        $authorName = [string](Get-ConfigValue -Config $runtimeConfig.Config -Path @("git", "author_name") -DefaultValue "")
        $authorEmail = [string](Get-ConfigValue -Config $runtimeConfig.Config -Path @("git", "author_email") -DefaultValue "")
        if (-not [string]::IsNullOrWhiteSpace($authorName)) {
            $gitEnvironment["GIT_AUTHOR_NAME"] = $authorName
            $gitEnvironment["GIT_COMMITTER_NAME"] = $authorName
        }
        if (-not [string]::IsNullOrWhiteSpace($authorEmail)) {
            $gitEnvironment["GIT_AUTHOR_EMAIL"] = $authorEmail
            $gitEnvironment["GIT_COMMITTER_EMAIL"] = $authorEmail
        }

        $commitResult = Invoke-Git -Arguments @("commit", "-m", $commitMessage) -WorkingDirectory $repoRoot -Environment $gitEnvironment
        if ($commitResult.ExitCode -ne 0) {
            $status = "commit_failed"
            throw ("git commit failed. {0}" -f $commitResult.StdErr.Trim())
        }

        $shaResult = Invoke-Git -Arguments @("rev-parse", "HEAD") -WorkingDirectory $repoRoot
        Assert-CommandSucceeded -Result $shaResult -Description "git rev-parse HEAD"
        $commitSha = $shaResult.StdOut.Trim()
    }

    $status = "success"
}
catch {
    $atlasContractsV2FailureReason = $_.Exception.Message
    if ($atlasContractsV2FailureReason -like "atlas_contracts_v2_*") { $atlasContractsV2PreflightFailureReason = $atlasContractsV2FailureReason }
    if ($status -eq "prepared") {
        $status = "failed"
    }
    Write-RunnerMessage -Message $_.Exception.Message -Level "ERROR"
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-RunnerMessage -Message $_.ScriptStackTrace.Trim() -Level "ERROR"
    }
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($PromptPath) -and -not [string]::IsNullOrWhiteSpace($archiveDirectory) -and (Test-Path -LiteralPath $PromptPath)) {
        try {
            $archiveSlug = ConvertTo-Slug -Value ([System.IO.Path]::GetFileNameWithoutExtension($PromptPath))
            $archivePath = New-ArchivePath -ArchiveDirectory $archiveDirectory -Slug $archiveSlug -Status $status -Extension ([System.IO.Path]::GetExtension($PromptPath))
            Move-Item -LiteralPath $PromptPath -Destination $archivePath -Force
        }
        catch {
            Write-RunnerMessage -Message ("Failed to archive prompt: {0}" -f $_.Exception.Message) -Level "WARN"
            if ($status -eq "success") {
                $status = "archive_failed"
            }
        }
    }

    if ($null -ne $lockState) {
        try {
            $lockRelease = Release-CanonicalWriterLock -LockPath $lockPath -RunId $runId
        }
        catch {
            $lockRelease = [pscustomobject]@{
                released = $false
                reason = ("release_failed: {0}" -f $_.Exception.Message)
            }
        }
    }

    if ($null -ne $atlasContractsV2) {
        $leaseReleaseProven = $status -in @("success", "success_no_changes") -and $null -ne $lockRelease -and [bool]$lockRelease.released
        if ($status -in @("success", "success_no_changes") -and -not $leaseReleaseProven) {
            $status = "worker_lease_recovery_required"
            $atlasContractsV2FailureReason = "Canonical writer lock release could not be proven."
        }
        try {
            $atlasContractsV2ReceiptValidation = Write-AtlasContractsV2TerminalReceipt `
                -Producer $atlasContractsV2 `
                -RunnerStatus $status `
                -ChangedPaths @($taskChangedPaths) `
                -CommitSha $commitSha `
                -RuntimePolicy $runtimePolicy `
                -VerificationCommands @($verificationCommands) `
                -VerificationRecords @($verifyRecords) `
                -Branch $atlasContractsV2Branch `
                -Worktree $null `
                -Reason $atlasContractsV2FailureReason `
                -EvidenceRefs @($codexStdOutPath, $codexStdErrPath, $summaryPath, $manifestPath) `
                -LeaseReleaseProven $leaseReleaseProven `
                -LeaseRecoveryCheckpoint $manifestPath
        }
        catch {
            $atlasContractsV2FailureReason = $_.Exception.Message
            $atlasContractsV2ReceiptValidation = [pscustomobject]@{ ok = $false; reasonCode = $atlasContractsV2FailureReason }
            $status = "atlas_contracts_v2_receipt_validation_failed"
        }
        if (-not [bool]$atlasContractsV2ReceiptValidation.ok -and $status -in @("success", "success_no_changes")) {
            $status = "atlas_contracts_v2_receipt_validation_failed"
        }
    }

    Write-CanonicalManifest
}

exit (Get-StatusExitCode -Status $status)
