Set-StrictMode -Version Latest

function Write-RunnerMessage {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host ("[{0}] [{1}] {2}" -f $timestamp, $Level, $Message)
}

function Expand-ConfigString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $expanded = $Value.Replace("${HOME}", $HOME)
    return [Environment]::ExpandEnvironmentVariables($expanded)
}

function ConvertFrom-TomlScalar {
    param([string]$Value)

    $trimmed = $Value.Trim()
    if ($trimmed -match '^(true|false)$') {
        return [System.Boolean]::Parse($Matches[1])
    }

    if ($trimmed -match '^-?\d+$') {
        return [int]$trimmed
    }

    if ($trimmed -match '^"(.*)"$') {
        return ($Matches[1] -replace '\\"', '"')
    }

    return $trimmed
}

function ConvertFrom-SimpleToml {
    param([string]$Path)

    $root = @{}
    $current = $root

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -match '^\[(?<section>[A-Za-z0-9_.-]+)\]$') {
            $current = $root
            foreach ($part in $Matches.section.Split(".")) {
                if (-not $current.ContainsKey($part)) {
                    $current[$part] = @{}
                }
                $current = $current[$part]
            }
            continue
        }

        if ($trimmed -match '^(?<key>[A-Za-z0-9_.-]+)\s*=\s*(?<value>.+)$') {
            $current[$Matches.key] = ConvertFrom-TomlScalar -Value $Matches.value
        }
    }

    return $root
}

function Merge-Hashtable {
    param(
        [hashtable]$Base,
        [hashtable]$Overlay
    )

    $merged = @{}
    foreach ($key in $Base.Keys) {
        $merged[$key] = $Base[$key]
    }

    foreach ($key in $Overlay.Keys) {
        if (
            $merged.ContainsKey($key) -and
            $merged[$key] -is [hashtable] -and
            $Overlay[$key] -is [hashtable]
        ) {
            $merged[$key] = Merge-Hashtable -Base $merged[$key] -Overlay $Overlay[$key]
        }
        else {
            $merged[$key] = $Overlay[$key]
        }
    }

    return $merged
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string[]]$Path,
        $DefaultValue = $null
    )

    $current = $Config
    foreach ($part in $Path) {
        if ($current -isnot [hashtable] -or -not $current.ContainsKey($part)) {
            return $DefaultValue
        }
        $current = $current[$part]
    }

    if ($null -eq $current) {
        return $DefaultValue
    }

    return $current
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }

        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Resolve-PathFromBase {
    param(
        [string]$BasePath,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $expanded = Expand-ConfigString -Value $Value
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $expanded))
}

function Resolve-RepoPath {
    param(
        [string]$Root,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $expanded = Expand-ConfigString -Value $Value
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath $expanded))
}

function Import-StackCodexConfiguration {
    param(
        [string]$ScriptRoot,
        [string]$ConfigPath = "",
        [string]$RepoRoot = "",
        [string]$AdapterPath = ""
    )

    $defaultsPath = Join-Path -Path $ScriptRoot -ChildPath "config.defaults.toml"
    $config = @{}
    if (Test-Path -LiteralPath $defaultsPath) {
        $config = ConvertFrom-SimpleToml -Path $defaultsPath
    }

    $resolvedConfigPath = $null
    $configBasePath = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $resolvedConfigPath = Resolve-PathFromBase -BasePath (Get-Location).Path -Value $ConfigPath
        if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
            throw ("Config file was not found: {0}" -f $resolvedConfigPath)
        }

        $configBasePath = Split-Path -Parent $resolvedConfigPath
        $repoConfig = ConvertFrom-SimpleToml -Path $resolvedConfigPath
        $config = Merge-Hashtable -Base $config -Overlay $repoConfig
    }

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = [string](Get-ConfigValue -Config $config -Path @("repo_root") -DefaultValue "")
    }
    if ([string]::IsNullOrWhiteSpace($AdapterPath)) {
        $AdapterPath = [string](Get-ConfigValue -Config $config -Path @("adapter_path") -DefaultValue "")
    }

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw "Repo root is required. Provide -RepoRoot or set repo_root in the config file."
    }
    if ([string]::IsNullOrWhiteSpace($AdapterPath)) {
        throw "Adapter path is required. Provide -AdapterPath or set adapter_path in the config file."
    }

    $resolvedRepoRoot = Resolve-PathFromBase -BasePath $configBasePath -Value $RepoRoot
    $resolvedAdapterPath = Resolve-PathFromBase -BasePath $configBasePath -Value $AdapterPath

    if (-not (Test-Path -LiteralPath $resolvedRepoRoot)) {
        throw ("Repo root does not exist: {0}" -f $resolvedRepoRoot)
    }
    if (-not (Test-Path -LiteralPath $resolvedAdapterPath)) {
        throw ("Adapter file does not exist: {0}" -f $resolvedAdapterPath)
    }

    return [pscustomobject]@{
        Config = $config
        ConfigPath = $resolvedConfigPath
        ConfigBasePath = $configBasePath
        RepoRoot = (Resolve-Path -LiteralPath $resolvedRepoRoot).Path
        AdapterPath = (Resolve-Path -LiteralPath $resolvedAdapterPath).Path
        DefaultsPath = $defaultsPath
    }
}

function ConvertTo-RunnerBoolean {
    param(
        $Value,
        [bool]$DefaultValue = $false
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    if ($Value -is [bool]) {
        return $Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $DefaultValue
    }

    switch ($text.Trim().ToLowerInvariant()) {
        "1" { return $true }
        "true" { return $true }
        "yes" { return $true }
        "on" { return $true }
        "0" { return $false }
        "false" { return $false }
        "no" { return $false }
        "off" { return $false }
        default { return $DefaultValue }
    }
}

function ConvertTo-Slug {
    param([string]$Value)

    $text = [string]$Value
    $text = $text.ToLowerInvariant()
    $text = [regex]::Replace($text, "refs/heads/", "")
    $text = $text.Replace("/", "-")
    $text = [regex]::Replace($text, "[^a-z0-9]+", "-")
    $text = $text.Trim("-")
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "task"
    }
    return $text
}

function Get-PromptMetadataValue {
    param(
        [hashtable]$Metadata,
        [string]$Key
    )

    if ($null -eq $Metadata -or [string]::IsNullOrWhiteSpace($Key)) {
        return $null
    }

    if ($Metadata.ContainsKey($Key)) {
        return [string]$Metadata[$Key]
    }

    return $null
}

function Get-NextPromptContentLine {
    param(
        [string[]]$Lines,
        [int]$StartIndex
    )

    if ($null -eq $Lines) {
        return $null
    }

    for ($index = $StartIndex; $index -lt $Lines.Count; $index++) {
        $trimmed = $Lines[$index].Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($trimmed -match '^(?:#{1,6}\s+)?[A-Za-z][A-Za-z0-9 -]*:\s*$') {
            return $null
        }

        if ($trimmed -match '^#{1,6}\s+') {
            return $null
        }

        if ($trimmed -match '^(?:[-*+]\s+|\d+\.\s+)(?<value>.+)$') {
            return $Matches.value.Trim()
        }

        return $trimmed
    }

    return $null
}

function Resolve-PromptTitle {
    param(
        [hashtable]$Metadata,
        [string[]]$Lines,
        [string]$Path
    )

    $explicitTitle = Get-PromptMetadataValue -Metadata $Metadata -Key "Title"
    if (-not [string]::IsNullOrWhiteSpace($explicitTitle)) {
        return $explicitTitle.Trim()
    }

    if ($null -ne $Lines) {
        foreach ($line in $Lines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^#{1,6}\s+(?<title>.+)$') {
                return $Matches.title.Trim()
            }
        }

        for ($index = 0; $index -lt $Lines.Count; $index++) {
            $trimmed = $Lines[$index].Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            if ($trimmed -match '^(?:#{1,6}\s*)?Objective\s*:\s*(?<value>.*)$') {
                $objectiveTitle = $Matches.value.Trim()
                if (-not [string]::IsNullOrWhiteSpace($objectiveTitle)) {
                    return $objectiveTitle
                }

                $nextObjectiveLine = Get-NextPromptContentLine -Lines $Lines -StartIndex ($index + 1)
                if (-not [string]::IsNullOrWhiteSpace($nextObjectiveLine)) {
                    return $nextObjectiveLine
                }
            }

            if ($trimmed -match '^(?:#{1,6}\s*)?Objective\s*$') {
                $nextObjectiveLine = Get-NextPromptContentLine -Lines $Lines -StartIndex ($index + 1)
                if (-not [string]::IsNullOrWhiteSpace($nextObjectiveLine)) {
                    return $nextObjectiveLine
                }
            }
        }
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ($raw | ConvertFrom-Json)
}

function ConvertTo-StringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ })
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { [string]$_ })
    }

    return @([string]$Value)
}

function Test-FileSettled {
    param(
        [string]$Path,
        [int]$Seconds
    )

    if ($Seconds -le 0) {
        return $true
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $first = Get-Item -LiteralPath $Path
    Start-Sleep -Seconds $Seconds
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $second = Get-Item -LiteralPath $Path
    return $first.Length -eq $second.Length -and $first.LastWriteTimeUtc -eq $second.LastWriteTimeUtc
}

function Get-PendingPromptFiles {
    param([string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Directory -Filter *.md -File |
        Where-Object { $_.Name -ne "README.md" } |
        Sort-Object Name)
}

function Parse-PromptFile {
    param([string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    $metadata = @{
        Verify = New-Object System.Collections.Generic.List[string]
    }

    $bodyStartIndex = 0
    $parsedMetadata = $false

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) {
            $bodyStartIndex = $index + 1
            $parsedMetadata = $index -gt 0
            break
        }

        if ($line -notmatch '^(?<key>[A-Za-z][A-Za-z0-9 -]*):\s*(?<value>.*)$') {
            $bodyStartIndex = 0
            $parsedMetadata = $false
            break
        }

        $normalizedKey = ($Matches.key -replace "[^A-Za-z0-9]", "").ToLowerInvariant()
        $value = $Matches.value.Trim()
        switch ($normalizedKey) {
            "title" { $metadata.Title = $value }
            "branch" { $metadata.BranchSlug = $value }
            "branchslug" { $metadata.BranchSlug = $value }
            "commit" { $metadata.CommitMessage = $value }
            "commitmessage" { $metadata.CommitMessage = $value }
            "verify" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.Verify.Add($value)
                }
            }
            "docsupdatenote" { $metadata.DocsUpdateNote = $value }
            "exportpatch" { $metadata.ExportPatch = $value }
            "exportbundle" { $metadata.ExportBundle = $value }
            default { }
        }

        $bodyStartIndex = $index + 1
        $parsedMetadata = $true
    }

    $bodyLines = if ($bodyStartIndex -lt $lines.Count) { $lines[$bodyStartIndex..($lines.Count - 1)] } else { @() }
    $body = ($bodyLines -join "`r`n").Trim()
    $rawContent = [System.IO.File]::ReadAllText($Path)

    if (-not $parsedMetadata) {
        $body = $rawContent.Trim()
    }

    $title = Resolve-PromptTitle -Metadata $metadata -Lines $lines -Path $Path
    $branchSlug = if ($metadata.ContainsKey("BranchSlug")) { $metadata["BranchSlug"] } else { $null }
    $commitMessage = if ($metadata.ContainsKey("CommitMessage")) { $metadata["CommitMessage"] } else { $null }
    $docsUpdateNote = if ($metadata.ContainsKey("DocsUpdateNote")) { $metadata["DocsUpdateNote"] } else { $null }
    $exportPatch = if ($metadata.ContainsKey("ExportPatch")) { $metadata["ExportPatch"] } else { $null }
    $exportBundle = if ($metadata.ContainsKey("ExportBundle")) { $metadata["ExportBundle"] } else { $null }

    return [pscustomobject]@{
        Title = $title
        BranchSlug = $branchSlug
        CommitMessage = $commitMessage
        Verify = @($metadata.Verify.ToArray())
        DocsUpdateNote = $docsUpdateNote
        ExportPatch = $exportPatch
        ExportBundle = $exportBundle
        Body = $body
        RawContent = $rawContent
    }
}

function Get-CommitMetadataPolicy {
    param(
        $AutoCommitPolicy,
        [string]$RepoId
    )

    $commitMetadata = if ($null -ne $AutoCommitPolicy -and $null -ne $AutoCommitPolicy.commitMetadata) {
        $AutoCommitPolicy.commitMetadata
    }
    else {
        [pscustomobject]@{}
    }

    $artifactPath = [string](Get-ObjectPropertyValue -Object $commitMetadata -Name "artifactPath" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($artifactPath)) {
        $artifactPath = ".codex/commit-meta.json"
    }

    $allowedTypes = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $commitMetadata -Name "allowedTypes"))
    if ($allowedTypes.Count -eq 0) {
        $allowedTypes = @("feat", "fix", "docs", "refactor", "test", "chore")
    }
    $allowedTypes = @(
        $allowedTypes |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )

    $rejectedSummaries = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $commitMetadata -Name "rejectedSummaries"))
    if ($rejectedSummaries.Count -eq 0) {
        $rejectedSummaries = @("update", "done", "fixes", "misc changes")
    }
    $rejectedSummaries = @(
        $rejectedSummaries |
        ForEach-Object { Normalize-CommitSummaryToken -Value ([string]$_) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )

    $fallbackScope = Normalize-CommitScope -Value ([string](Get-ObjectPropertyValue -Object $commitMetadata -Name "fallbackScope" -DefaultValue ""))
    if ([string]::IsNullOrWhiteSpace($fallbackScope)) {
        $fallbackScope = Normalize-CommitScope -Value $RepoId
    }
    if ([string]::IsNullOrWhiteSpace($fallbackScope)) {
        $fallbackScope = "codex"
    }

    return [pscustomobject]@{
        artifactPath = $artifactPath
        allowedTypes = @($allowedTypes)
        rejectedSummaries = @($rejectedSummaries)
        fallbackScope = $fallbackScope
    }
}

function Get-LocalLandingPolicy {
    param($Policy)

    $mode = [string](Get-ObjectPropertyValue -Object $Policy -Name "mode" -DefaultValue "disabled")
    if ([string]::IsNullOrWhiteSpace($mode)) {
        $mode = "disabled"
    }
    $mode = $mode.Trim().ToLowerInvariant()

    switch ($mode) {
        "disabled" { }
        "ff-only" { }
        default { throw ("Unsupported local landing mode: {0}" -f $mode) }
    }

    $targetBranch = [string](Get-ObjectPropertyValue -Object $Policy -Name "targetBranch" -DefaultValue "main")
    if ([string]::IsNullOrWhiteSpace($targetBranch)) {
        $targetBranch = "main"
    }

    return [pscustomobject]@{
        mode = $mode
        targetBranch = $targetBranch.Trim()
    }
}

function Normalize-CommitScope {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = $Value.Trim().ToLowerInvariant()
    $text = $text.Replace("_", "-").Replace("/", "-")
    $text = [regex]::Replace($text, "[^a-z0-9-]+", "-")
    $text = [regex]::Replace($text, "-{2,}", "-")
    $text = $text.Trim("-")
    return $text
}

function Normalize-CommitSummaryText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = [regex]::Replace($Value.Trim(), "\s+", " ")
    $text = $text.Trim(" ", ".", ";", ":", "-", "_")
    if ($text.Length -eq 0) {
        return $null
    }

    if ($text.Length -gt 1) {
        $text = [char]::ToLowerInvariant($text[0]) + $text.Substring(1)
    }
    else {
        $text = $text.ToLowerInvariant()
    }

    return $text
}

function Normalize-CommitSummaryToken {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $token = $Value.Trim().ToLowerInvariant()
    $token = [regex]::Replace($token, "[^a-z0-9]+", " ")
    $token = [regex]::Replace($token, "\s+", " ").Trim()
    return $token
}

function Parse-CommitMessageText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = $Value.Trim()
    if ($text -notmatch '^(?<type>[A-Za-z]+)(\((?<scope>[A-Za-z0-9_./-]+)\))?:\s*(?<summary>.+)$') {
        return $null
    }

    return [pscustomobject]@{
        type = $Matches.type
        scope = $Matches.scope
        summary = $Matches.summary
    }
}

function Read-CommitMetadataArtifact {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $rawContent = Get-Content -LiteralPath $Path -Raw
    $result = [ordered]@{
        exists = $true
        path = $Path
        rawContent = $rawContent
        parseError = $null
        type = $null
        scope = $null
        summary = $null
    }

    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        $result.parseError = "Commit metadata artifact is empty."
        return [pscustomobject]$result
    }

    try {
        $json = $rawContent | ConvertFrom-Json
        $result.type = [string](Get-ObjectPropertyValue -Object $json -Name "type" -DefaultValue $null)
        $result.scope = [string](Get-ObjectPropertyValue -Object $json -Name "scope" -DefaultValue $null)
        $result.summary = [string](Get-ObjectPropertyValue -Object $json -Name "summary" -DefaultValue $null)
    }
    catch {
        $result.parseError = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Test-CommitMetadataCandidate {
    param(
        $Candidate,
        [string[]]$AllowedTypes,
        [string[]]$RejectedSummaries
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $normalizedType = if ($null -ne $Candidate -and $null -ne $Candidate.type) {
        ([string]$Candidate.type).Trim().ToLowerInvariant()
    }
    else {
        ""
    }
    $normalizedScope = if ($null -ne $Candidate -and $null -ne $Candidate.scope) {
        Normalize-CommitScope -Value ([string]$Candidate.scope)
    }
    else {
        $null
    }
    $normalizedSummary = if ($null -ne $Candidate -and $null -ne $Candidate.summary) {
        Normalize-CommitSummaryText -Value ([string]$Candidate.summary)
    }
    else {
        $null
    }
    $summaryToken = Normalize-CommitSummaryToken -Value $normalizedSummary

    if ([string]::IsNullOrWhiteSpace($normalizedType)) {
        [void]$errors.Add("Commit type is required.")
    }
    elseif ($AllowedTypes -notcontains $normalizedType) {
        [void]$errors.Add(("Commit type '{0}' is not allowed." -f $normalizedType))
    }

    if ([string]::IsNullOrWhiteSpace($normalizedScope)) {
        [void]$errors.Add("Commit scope is required.")
    }
    elseif ($normalizedScope -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        [void]$errors.Add(("Commit scope '{0}' is invalid." -f $normalizedScope))
    }

    if ([string]::IsNullOrWhiteSpace($normalizedSummary)) {
        [void]$errors.Add("Commit summary is required.")
    }
    else {
        $wordCount = @($summaryToken -split " " | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        if ($normalizedSummary.Length -lt 12) {
            [void]$errors.Add("Commit summary must be at least 12 characters.")
        }
        if ($wordCount -lt 2) {
            [void]$errors.Add("Commit summary must contain at least two words.")
        }
        if ($RejectedSummaries -contains $summaryToken) {
            [void]$errors.Add(("Commit summary '{0}' is too generic." -f $normalizedSummary))
        }
    }

    return [pscustomobject]@{
        isValid = $errors.Count -eq 0
        type = $normalizedType
        scope = $normalizedScope
        summary = $normalizedSummary
        message = if ($errors.Count -eq 0) { "{0}({1}): {2}" -f $normalizedType, $normalizedScope, $normalizedSummary } else { $null }
        errors = @($errors.ToArray())
    }
}

function Test-DocumentationLikePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalized = $Path.Replace("\", "/")
    return (
        $normalized -like "docs/*" -or
        $normalized -eq "README.md" -or
        $normalized -match '\.(md|mdx|txt|rst)$'
    )
}

function Test-TestLikePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalized = $Path.Replace("\", "/").ToLowerInvariant()
    return (
        $normalized -match '(^|/)(__tests__|tests?|specs?)(/|$)' -or
        $normalized -match '(\.|-)(test|spec)\.' -or
        $normalized -like "*.snap"
    )
}

function Test-ConfigLikePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalized = $Path.Replace("\", "/").ToLowerInvariant()
    return (
        $normalized -like ".codex/*" -or
        $normalized -like ".github/*" -or
        $normalized -like ".vscode/*" -or
        $normalized -match '(^|/)(package(-lock)?\.json|pnpm-lock\.yaml|tsconfig(\..+)?\.json|.+\.(json|toml|ya?ml|ini))$'
    )
}

function Get-FallbackCommitType {
    param(
        [string[]]$ChangedPaths,
        $PromptRecord
    )

    if ($ChangedPaths.Count -eq 0) {
        return "chore"
    }

    $docCount = @($ChangedPaths | Where-Object { Test-DocumentationLikePath -Path $_ }).Count
    $testCount = @($ChangedPaths | Where-Object { Test-TestLikePath -Path $_ }).Count
    $configCount = @($ChangedPaths | Where-Object { Test-ConfigLikePath -Path $_ }).Count

    if ($docCount -eq $ChangedPaths.Count) {
        return "docs"
    }
    if ($testCount -eq $ChangedPaths.Count) {
        return "test"
    }
    if ($configCount -eq $ChangedPaths.Count) {
        return "chore"
    }

    $promptText = @(
        if ($null -ne $PromptRecord) { $PromptRecord.Title }
        if ($null -ne $PromptRecord) { $PromptRecord.Body }
    ) -join " "
    $promptText = $promptText.ToLowerInvariant()

    if ($promptText -match '\brefactor(?:ing|ed)?\b') {
        return "refactor"
    }
    if ($promptText -match '\bfix(?:es|ed|ing)?\b|\bbug\b|\brepair(?:ed|ing)?\b') {
        return "fix"
    }
    if ($promptText -match '\btest(?:s|ing)?\b|\bcoverage\b' -and $testCount -gt 0) {
        return "test"
    }

    return "feat"
}

function Get-FallbackCommitArea {
    param(
        [string[]]$ChangedPaths,
        [string]$RepoId
    )

    if ($ChangedPaths.Count -eq 0) {
        return "{0} workflow" -f $RepoId
    }

    $normalizedPaths = @($ChangedPaths | ForEach-Object { $_.Replace("\", "/") })
    $joined = ($normalizedPaths -join " ").ToLowerInvariant()

    if (@($normalizedPaths | Where-Object { $_ -like "ops/codex/*" }).Count -gt 0) {
        return "shared codex runner"
    }
    if (@($normalizedPaths | Where-Object { $_ -like "ops/*" -or $_ -like "scripts/*" }).Count -gt 0) {
        return "workflow scripts"
    }
    if (@($normalizedPaths | Where-Object { Test-DocumentationLikePath -Path $_ }).Count -eq $normalizedPaths.Count) {
        if ($joined -match 'architecture|stack_overview|system_registry|ownership_boundaries|contract_map|workflow|promotion') {
            return "architecture planning docs"
        }
        if ($joined -match 'codex|orchestration|dispatcher|adapter') {
            return "shared runner docs"
        }
        return "operator docs"
    }
    if (@($normalizedPaths | Where-Object { $_ -like ".codex/*" }).Count -eq $normalizedPaths.Count) {
        return "codex runner artifacts"
    }
    if (@($normalizedPaths | Where-Object { Test-ConfigLikePath -Path $_ }).Count -eq $normalizedPaths.Count) {
        return "operator configuration"
    }

    return "{0} workflow" -f $RepoId
}

function New-FallbackCommitMetadata {
    param(
        [string[]]$ChangedPaths,
        $PromptRecord,
        $CommitPolicy,
        [string]$RepoId
    )

    $fallbackType = Get-FallbackCommitType -ChangedPaths $ChangedPaths -PromptRecord $PromptRecord
    $fallbackArea = Get-FallbackCommitArea -ChangedPaths $ChangedPaths -RepoId $RepoId
    $summaryCandidates = New-Object System.Collections.Generic.List[string]

    if ($null -ne $PromptRecord -and -not [string]::IsNullOrWhiteSpace($PromptRecord.Title)) {
        [void]$summaryCandidates.Add((Normalize-CommitSummaryText -Value $PromptRecord.Title))
    }

    switch ($fallbackType) {
        "docs" { [void]$summaryCandidates.Add(("update {0}" -f $fallbackArea)) }
        "test" { [void]$summaryCandidates.Add(("expand {0} coverage" -f $fallbackArea)) }
        "refactor" { [void]$summaryCandidates.Add(("refactor {0}" -f $fallbackArea)) }
        "fix" { [void]$summaryCandidates.Add(("fix {0} behavior" -f $fallbackArea)) }
        "chore" { [void]$summaryCandidates.Add(("update {0}" -f $fallbackArea)) }
        default { [void]$summaryCandidates.Add(("add {0} support" -f $fallbackArea)) }
    }

    [void]$summaryCandidates.Add(("update {0} workflow details" -f $CommitPolicy.fallbackScope))

    foreach ($summaryCandidate in $summaryCandidates) {
        if ([string]::IsNullOrWhiteSpace($summaryCandidate)) {
            continue
        }

        $candidate = [pscustomobject]@{
            type = $fallbackType
            scope = $CommitPolicy.fallbackScope
            summary = $summaryCandidate
        }
        $validation = Test-CommitMetadataCandidate -Candidate $candidate -AllowedTypes $CommitPolicy.allowedTypes -RejectedSummaries $CommitPolicy.rejectedSummaries
        if ($validation.isValid) {
            return [pscustomobject]@{
                source = "fallback"
                type = $validation.type
                scope = $validation.scope
                summary = $validation.summary
                message = $validation.message
                errors = @()
                fallbackType = $fallbackType
                fallbackArea = $fallbackArea
            }
        }
    }

    throw "Failed to generate fallback commit metadata."
}

function Resolve-CommitMetadata {
    param(
        $PromptRecord,
        $ArtifactRecord,
        $CommitPolicy,
        [string[]]$ChangedPaths,
        [string]$RepoId
    )

    $candidateErrors = New-Object System.Collections.Generic.List[object]

    if ($null -ne $ArtifactRecord) {
        if ([string]::IsNullOrWhiteSpace($ArtifactRecord.parseError)) {
            $artifactCandidate = [pscustomobject]@{
                type = $ArtifactRecord.type
                scope = $ArtifactRecord.scope
                summary = $ArtifactRecord.summary
            }
            $artifactValidation = Test-CommitMetadataCandidate -Candidate $artifactCandidate -AllowedTypes $CommitPolicy.allowedTypes -RejectedSummaries $CommitPolicy.rejectedSummaries
            if ($artifactValidation.isValid) {
                return [pscustomobject]@{
                    source = "artifact"
                    type = $artifactValidation.type
                    scope = $artifactValidation.scope
                    summary = $artifactValidation.summary
                    message = $artifactValidation.message
                    errors = @()
                    candidateErrors = @()
                }
            }

            [void]$candidateErrors.Add([pscustomobject]@{
                source = "artifact"
                errors = @($artifactValidation.errors)
            })
        }
        else {
            [void]$candidateErrors.Add([pscustomobject]@{
                source = "artifact"
                errors = @($ArtifactRecord.parseError)
            })
        }
    }

    $legacyCandidate = if ($null -ne $PromptRecord) { Parse-CommitMessageText -Value $PromptRecord.CommitMessage } else { $null }
    if ($null -ne $legacyCandidate) {
        $legacyValidation = Test-CommitMetadataCandidate -Candidate $legacyCandidate -AllowedTypes $CommitPolicy.allowedTypes -RejectedSummaries $CommitPolicy.rejectedSummaries
        if ($legacyValidation.isValid) {
            return [pscustomobject]@{
                source = "prompt"
                type = $legacyValidation.type
                scope = $legacyValidation.scope
                summary = $legacyValidation.summary
                message = $legacyValidation.message
                errors = @()
                candidateErrors = @($candidateErrors.ToArray())
            }
        }

        [void]$candidateErrors.Add([pscustomobject]@{
            source = "prompt"
            errors = @($legacyValidation.errors)
        })
    }

    $fallback = New-FallbackCommitMetadata -ChangedPaths $ChangedPaths -PromptRecord $PromptRecord -CommitPolicy $CommitPolicy -RepoId $RepoId
    $fallback | Add-Member -NotePropertyName candidateErrors -NotePropertyValue @($candidateErrors.ToArray())
    return $fallback
}

function Quote-Argument {
    param([string]$Argument)

    if ($null -eq $Argument -or $Argument -eq "") {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [AllowNull()]
        [string]$StandardInputText = $null
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (($ArgumentList | ForEach-Object { Quote-Argument -Argument ([string]$_) }) -join " ")
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInputText
    $startInfo.CreateNoWindow = $true

    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.EnvironmentVariables[$entry.Key] = [string]$entry.Value
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        $started = $process.Start()
        if (-not $started) {
            throw ("Failed to start process: {0}" -f $FilePath)
        }

        if ($null -ne $StandardInputText) {
            $process.StandardInput.Write($StandardInputText)
            $process.StandardInput.Close()
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdoutTask.Wait()
        $stderrTask.Wait()

        return [pscustomobject]@{
            FilePath = $FilePath
            Arguments = $ArgumentList
            WorkingDirectory = $WorkingDirectory
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.Result
            StdErr = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{}
    )

    return Invoke-ProcessCapture -FilePath "git" -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment
}

function Get-GitCurrentBranch {
    param([string]$WorkingDirectory)

    $result = Invoke-Git -Arguments @("symbolic-ref", "--quiet", "--short", "HEAD") -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -ne 0) {
        return $null
    }

    return $result.StdOut.Trim()
}

function Test-GitWorkingTreeClean {
    param([string]$WorkingDirectory)

    $result = Invoke-Git -Arguments @("status", "--porcelain") -WorkingDirectory $WorkingDirectory
    Assert-CommandSucceeded -Result $result -Description "git status --porcelain"
    return [string]::IsNullOrWhiteSpace($result.StdOut)
}

function Test-GitAncestor {
    param(
        [string]$AncestorRef,
        [string]$DescendantRef,
        [string]$WorkingDirectory
    )

    $result = Invoke-Git -Arguments @("merge-base", "--is-ancestor", $AncestorRef, $DescendantRef) -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -eq 0) {
        return $true
    }
    if ($result.ExitCode -eq 1) {
        return $false
    }

    Assert-CommandSucceeded -Result $result -Description "git merge-base --is-ancestor"
    return $false
}

function Invoke-LocalBranchLanding {
    param(
        [string]$WorkingDirectory,
        [string]$TargetBranch,
        [string]$CommitSha,
        [string]$TaskBranch,
        [string]$Mode
    )

    $result = [ordered]@{
        mode = $Mode
        targetBranch = $TargetBranch
        taskBranch = $TaskBranch
        commitSha = $CommitSha
        landed_to_main = $false
        failureReason = $null
    }

    if ($Mode -eq "disabled") {
        $result.failureReason = "disabled_by_policy"
        return [pscustomobject]$result
    }

    $currentBranch = Get-GitCurrentBranch -WorkingDirectory $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($currentBranch) -or $currentBranch -ne $TargetBranch) {
        $result.failureReason = "repo_root_not_on_target_branch"
        return [pscustomobject]$result
    }

    if (-not (Test-GitWorkingTreeClean -WorkingDirectory $WorkingDirectory)) {
        $result.failureReason = "repo_root_dirty"
        return [pscustomobject]$result
    }

    $headResult = Invoke-Git -Arguments @("rev-parse", "HEAD") -WorkingDirectory $WorkingDirectory
    Assert-CommandSucceeded -Result $headResult -Description "git rev-parse HEAD"
    $headSha = $headResult.StdOut.Trim()

    if ($headSha -eq $CommitSha) {
        $result.landed_to_main = $true
        return [pscustomobject]$result
    }

    if (-not (Test-GitAncestor -AncestorRef $headSha -DescendantRef $CommitSha -WorkingDirectory $WorkingDirectory)) {
        $result.failureReason = "fast_forward_not_possible"
        return [pscustomobject]$result
    }

    $mergeResult = Invoke-Git -Arguments @("merge", "--ff-only", $CommitSha) -WorkingDirectory $WorkingDirectory
    if ($mergeResult.ExitCode -ne 0) {
        $mergeError = $mergeResult.StdErr.Trim()
        if ([string]::IsNullOrWhiteSpace($mergeError)) {
            $mergeError = $mergeResult.StdOut.Trim()
        }

        $result.failureReason = if ([string]::IsNullOrWhiteSpace($mergeError)) {
            "fast_forward_merge_failed"
        }
        else {
            "fast_forward_merge_failed: {0}" -f $mergeError
        }
        return [pscustomobject]$result
    }

    $result.landed_to_main = $true
    return [pscustomobject]$result
}

function Invoke-ShellCommand {
    param(
        [string]$Command,
        [string]$WorkingDirectory
    )

    return Invoke-ProcessCapture -FilePath "cmd.exe" -ArgumentList @("/d", "/s", "/c", $Command) -WorkingDirectory $WorkingDirectory
}

function Assert-CommandSucceeded {
    param(
        $Result,
        [string]$Description
    )

    if ($Result.ExitCode -ne 0) {
        $message = "{0} failed with exit code {1}." -f $Description, $Result.ExitCode
        if (-not [string]::IsNullOrWhiteSpace($Result.StdErr)) {
            $message = $message + " " + $Result.StdErr.Trim()
        }
        throw $message
    }
}

function Test-GitRefExists {
    param(
        [string]$RefName,
        [string]$WorkingDirectory
    )

    $result = Invoke-Git -Arguments @("rev-parse", "--verify", "--quiet", $RefName) -WorkingDirectory $WorkingDirectory
    return $result.ExitCode -eq 0
}

function Get-GitRefResolutionCandidates {
    param([string]$PreferredRef)

    $candidates = New-Object System.Collections.Generic.List[string]
    $resolvedPreferredRef = [string]$PreferredRef
    if ([string]::IsNullOrWhiteSpace($resolvedPreferredRef)) {
        $resolvedPreferredRef = "origin/main"
    }

    foreach ($candidate in @($resolvedPreferredRef, $(if ($resolvedPreferredRef -match '^origin/(?<branch>.+)$') { $Matches.branch }))) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $candidates.Contains($candidate)) {
            [void]$candidates.Add($candidate)
        }
    }

    return @($candidates.ToArray())
}

function Resolve-GitRef {
    param(
        [string]$PreferredRef,
        [string]$WorkingDirectory
    )

    $candidates = @(Get-GitRefResolutionCandidates -PreferredRef $PreferredRef)
    $configuredRef = if ($candidates.Count -gt 0) { $candidates[0] } else { "origin/main" }

    foreach ($candidate in $candidates) {
        if (Test-GitRefExists -RefName $candidate -WorkingDirectory $WorkingDirectory) {
            return [pscustomobject]@{
                configuredRef = $configuredRef
                resolvedRef = $candidate
                usedFallback = $candidate -ne $configuredRef
                candidates = @($candidates)
            }
        }
    }

    return [pscustomobject]@{
        configuredRef = $configuredRef
        resolvedRef = $null
        usedFallback = $false
        candidates = @($candidates)
    }
}

function Test-GitPathTracked {
    param(
        [string]$Path,
        [string]$WorkingDirectory
    )

    $result = Invoke-Git -Arguments @("ls-files", "--error-unmatch", "--", $Path) -WorkingDirectory $WorkingDirectory
    return $result.ExitCode -eq 0
}

function Get-UniqueTaskName {
    param(
        [string]$RootSlug,
        [string]$BranchPrefix,
        [string]$WorktreeRoot,
        [string]$WorkingDirectory
    )

    $candidate = $RootSlug
    $counter = 1
    while ($true) {
        $branchName = "{0}{1}" -f $BranchPrefix, $candidate
        $worktreePath = Join-Path -Path $WorktreeRoot -ChildPath $candidate
        $branchExists = Test-GitRefExists -RefName ("refs/heads/{0}" -f $branchName) -WorkingDirectory $WorkingDirectory
        if (-not $branchExists -and -not (Test-Path -LiteralPath $worktreePath)) {
            return [pscustomobject]@{
                Slug = $candidate
                BranchName = $branchName
                WorktreePath = $worktreePath
            }
        }

        $counter += 1
        $candidate = "{0}-{1}" -f $RootSlug, $counter
    }
}

function Get-ChangedPaths {
    param([string]$WorkingDirectory)

    $trackedResult = Invoke-Git -Arguments @("diff", "--name-only", "--relative", "HEAD") -WorkingDirectory $WorkingDirectory
    Assert-CommandSucceeded -Result $trackedResult -Description "git diff --name-only HEAD"

    $untrackedResult = Invoke-Git -Arguments @("ls-files", "--others", "--exclude-standard") -WorkingDirectory $WorkingDirectory
    Assert-CommandSucceeded -Result $untrackedResult -Description "git ls-files --others --exclude-standard"

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($trackedResult.StdOut, $untrackedResult.StdOut)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        foreach ($entry in ($line -split "`r?`n")) {
            $trimmed = $entry.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $paths.Contains($trimmed)) {
                [void]$paths.Add($trimmed)
            }
        }
    }

    return @($paths.ToArray())
}

function Test-PathMatchesAllowedSurface {
    param(
        [string]$Path,
        [string[]]$AllowedPatterns
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalizedPath = $Path.Replace("\", "/")
    foreach ($pattern in $AllowedPatterns) {
        $normalizedPattern = ([string]$pattern).Replace("\", "/")
        if ($normalizedPath -like $normalizedPattern) {
            return $true
        }
    }

    return $false
}

function Get-StatusExitCode {
    param([string]$Status)

    switch ($Status) {
        "success" { return 0 }
        "verification_failed" { return 11 }
        "codex_failed" { return 12 }
        "commit_failed" { return 13 }
        "no_changes" { return 14 }
        "archive_failed" { return 15 }
        "mutation_scope_failed" { return 16 }
        default { return 10 }
    }
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content)
}

function New-ArchivePath {
    param(
        [string]$ArchiveDirectory,
        [string]$Slug,
        [string]$Status,
        [string]$Extension
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $fileName = "{0}-{1}-{2}{3}" -f $timestamp, $Slug, $Status, $Extension
    return Join-Path -Path $ArchiveDirectory -ChildPath $fileName
}
