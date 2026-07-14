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

    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        if ($Object.PSObject.Methods.Name -contains "ContainsKey" -and $Object.ContainsKey($Name)) {
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
    $defaultsConfig = @{}
    $repoConfig = @{}
    if (Test-Path -LiteralPath $defaultsPath) {
        $defaultsConfig = ConvertFrom-SimpleToml -Path $defaultsPath
        $config = $defaultsConfig
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
        DefaultsConfig = $defaultsConfig
        RepoConfig = $repoConfig
        ConfigPath = $resolvedConfigPath
        ConfigBasePath = $configBasePath
        RepoRoot = (Resolve-Path -LiteralPath $resolvedRepoRoot).Path
        AdapterPath = (Resolve-Path -LiteralPath $resolvedAdapterPath).Path
        DefaultsPath = $defaultsPath
    }
}

function Test-WindowsPlatform { return $env:OS -eq "Windows_NT" }

function Test-CodexCommandPathLike {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and ([System.IO.Path]::IsPathRooted($Value) -or $Value.Contains("\\") -or $Value.Contains("/") -or $Value.StartsWith("."))
}

function Test-WindowsNativeExecutablePath {
    param([string]$Path)
    return -not [string]::IsNullOrWhiteSpace($Path) -and (@(".exe", ".com") -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant())
}

function New-CodexCommandResolutionRecord {
    param([string]$Source, [string]$RequestedPath)
    return [ordered]@{ source = $Source; requestedPath = $RequestedPath; expandedPath = $null; resolvedNativePath = $null; codex_version = $null; requestedValue = $RequestedPath; expandedValue = $null; path = $null; resolutionMethod = $null; isNativeExecutable = $false; reasonCode = $null; searchedCommands = @() }
}

function Set-CodexCommandVersion {
    param($ResolutionRecord, [string]$CodexVersion)
    if ($null -ne $ResolutionRecord) { $ResolutionRecord.codex_version = if ([string]::IsNullOrWhiteSpace($CodexVersion)) { $null } else { $CodexVersion } }
    return $ResolutionRecord
}

function Resolve-WindowsCodexCommandCandidate {
    param([string]$RequestedPath, [string]$Source, [string]$BasePath)
    $record = New-CodexCommandResolutionRecord -Source $Source -RequestedPath $RequestedPath
    $expandedPath = Expand-ConfigString -Value $RequestedPath
    $record.expandedPath = if (Test-CodexCommandPathLike -Value $expandedPath) { Resolve-PathFromBase -BasePath $BasePath -Value $expandedPath } else { $expandedPath }
    $record.expandedValue = $record.expandedPath
    if ([string]::IsNullOrWhiteSpace($record.expandedPath)) { $record.reasonCode = "codex_native_executable_not_found"; return [pscustomobject]$record }
    if (Test-CodexCommandPathLike -Value $record.expandedPath) {
        $record.resolvedNativePath = $record.expandedPath; $record.path = $record.resolvedNativePath; $record.resolutionMethod = "literal-path"
        if (-not (Test-Path -LiteralPath $record.resolvedNativePath -PathType Leaf)) { $record.reasonCode = "codex_native_executable_not_found"; return [pscustomobject]$record }
        if (-not (Test-WindowsNativeExecutablePath -Path $record.resolvedNativePath)) { $record.reasonCode = "codex_native_executable_required"; return [pscustomobject]$record }
        $record.isNativeExecutable = $true; return [pscustomobject]$record
    }
    $extension = [System.IO.Path]::GetExtension($record.expandedPath)
    if (-not [string]::IsNullOrWhiteSpace($extension) -and -not (Test-WindowsNativeExecutablePath -Path $record.expandedPath)) { $record.reasonCode = "codex_native_executable_required"; return [pscustomobject]$record }
    foreach ($name in $(if ([string]::IsNullOrWhiteSpace($extension)) { @(("{0}.exe" -f $record.expandedPath), $record.expandedPath) } else { @($record.expandedPath) })) {
        $record.searchedCommands = @($record.searchedCommands + $name); $candidate = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $candidate) { continue }
        $record.resolvedNativePath = [string]$candidate.Source; $record.path = $record.resolvedNativePath; $record.resolutionMethod = "path-search:$name"
        if (Test-WindowsNativeExecutablePath -Path $record.resolvedNativePath) { $record.isNativeExecutable = $true; return [pscustomobject]$record }
        $record.reasonCode = "codex_native_executable_required"
    }
    if ([string]::IsNullOrWhiteSpace($record.reasonCode)) { $record.reasonCode = "codex_native_executable_not_found" }
    return [pscustomobject]$record
}

function Resolve-CodexCommand {
    param([string]$ExplicitCodexCommand, [hashtable]$Config, [string]$BasePath)
    $requested = if (-not [string]::IsNullOrWhiteSpace($ExplicitCodexCommand)) { $ExplicitCodexCommand } else { [string](Get-ConfigValue -Config $Config -Path @("windows", "codex_command") -DefaultValue "") }
    $source = if (-not [string]::IsNullOrWhiteSpace($ExplicitCodexCommand)) { "explicit-arg" } elseif (-not [string]::IsNullOrWhiteSpace($requested)) { "runtime-config/windows.codex_command" } else { "path-fallback" }
    if ([string]::IsNullOrWhiteSpace($requested)) { $requested = "codex" }
    return Resolve-WindowsCodexCommandCandidate -RequestedPath $requested -Source $source -BasePath $BasePath
}

function Get-CodexCommandResolutionFailureMessage {
    param($ResolutionRecord)
    $reason = [string](Get-ObjectPropertyValue -Object $ResolutionRecord -Name "reasonCode" -DefaultValue "codex_native_executable_not_found")
    $source = [string](Get-ObjectPropertyValue -Object $ResolutionRecord -Name "source" -DefaultValue "unknown")
    $requested = [string](Get-ObjectPropertyValue -Object $ResolutionRecord -Name "requestedPath" -DefaultValue "")
    return ("{0}: Codex command must resolve to an existing native Windows executable before runtime-policy probing or execution. Source={1}; requested='{2}'" -f $reason, $source, $requested)
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

function ConvertTo-StrictPromptBoolean {
    param(
        $Value,
        [bool]$DefaultValue = $false,
        [string]$Name = "boolean metadata"
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $DefaultValue
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    switch (([string]$Value).Trim().ToLowerInvariant()) {
        "true" { return $true }
        "false" { return $false }
        default { throw ("{0} must be true or false." -f $Name) }
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

        if (Test-PromptSectionHeadingLine -Line $trimmed) {
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

function Read-SpecToDiffArtifact {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            path = $Path
            rawContent = $raw
            parseError = "Spec-to-diff completion artifact is empty."
            payload = $null
        }
    }

    try {
        $payload = $raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            path = $Path
            rawContent = $raw
            parseError = $_.Exception.Message
            payload = $null
        }
    }

    return [pscustomobject]@{
        path = $Path
        rawContent = $raw
        parseError = $null
        payload = $payload
    }
}

function Read-NoChangeProofArtifact {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ path = $Path; rawContent = $raw; parseError = "Verified no-change proof artifact is empty."; payload = $null }
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($raw) -gt 65536) {
        return [pscustomobject]@{ path = $Path; rawContent = $raw; parseError = "Verified no-change proof artifact exceeds the 64 KiB bound."; payload = $null }
    }

    try { $payload = $raw | ConvertFrom-Json }
    catch { return [pscustomobject]@{ path = $Path; rawContent = $raw; parseError = $_.Exception.Message; payload = $null } }

    return [pscustomobject]@{ path = $Path; rawContent = $raw; parseError = $null; payload = $payload }
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

function Normalize-PromptSectionName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $trimmed = $Value.Trim()
    $trimmed = $trimmed -replace '^#{1,6}\s*', ''
    $trimmed = $trimmed.Trim()
    while ($trimmed.EndsWith(":")) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1).Trim()
    }

    return (($trimmed -replace "[^A-Za-z0-9]", "").ToLowerInvariant())
}

function Test-PromptSectionHeadingLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    $trimmed = $Line.Trim()
    return (
        $trimmed -match '^#{1,6}\s+\S.*$' -or
        $trimmed -match '^[A-Za-z][A-Za-z0-9 /-]*:\s*$'
    )
}

function Get-PromptBodySections {
    param([string]$Body)

    $recognizedSections = @(
        "objective",
        "context",
        "constraints",
        "acceptancecriteria",
        "expectedchangedpaths",
        "expectedunchangedpaths",
        "blockedskippedreportingrules",
        "verification",
        "pauseresumemerge",
        "deliverback",
        "requiredoutcome",
        "primaryfile",
        "implementationscope",
        "likelyfiles",
        "mandatoryinheritedcontract",
        "noexecutionguard",
        "stopandreturntriggers"
    )

    $sections = @{}
    if ([string]::IsNullOrWhiteSpace($Body)) {
        return $sections
    }

    $currentSection = $null
    $fenceMarker = $null
    foreach ($line in ($Body -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^(?<marker>`{3,}|~{3,})') {
            $marker = $Matches.marker.Substring(0, 1)
            if ($null -eq $fenceMarker) {
                $fenceMarker = $marker
            }
            elseif ($fenceMarker -eq $marker) {
                $fenceMarker = $null
            }
            if ($null -ne $currentSection) {
                [void]$sections[$currentSection].Add($line)
            }
            continue
        }

        if ($null -ne $fenceMarker) {
            if ($null -ne $currentSection) {
                [void]$sections[$currentSection].Add($line)
            }
            continue
        }

        $normalizedHeader = Normalize-PromptSectionName -Value $line
        if (Test-PromptSectionHeadingLine -Line $line) {
            if ($recognizedSections -contains $normalizedHeader) {
                $currentSection = $normalizedHeader
                if (-not $sections.ContainsKey($currentSection)) {
                    $sections[$currentSection] = New-Object System.Collections.Generic.List[string]
                }
            }
            else {
                $currentSection = $null
            }
            continue
        }

        if ($null -ne $currentSection) {
            [void]$sections[$currentSection].Add($line)
        }
    }

    $result = @{}
    foreach ($key in $sections.Keys) {
        $result[$key] = @($sections[$key].ToArray())
    }

    return $result
}

function Convert-PromptSectionLinesToItems {
    param([string[]]$Lines)

    $items = New-Object System.Collections.Generic.List[string]
    $current = ""
    $fenceMarker = $null

    foreach ($line in @($Lines)) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^(?<marker>`{3,}|~{3,})') {
            $marker = $Matches.marker.Substring(0, 1)
            if ($null -eq $fenceMarker) {
                $fenceMarker = $marker
            }
            elseif ($fenceMarker -eq $marker) {
                $fenceMarker = $null
            }
            continue
        }

        if ($null -ne $fenceMarker) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                [void]$items.Add($current.Trim())
                $current = ""
            }
            continue
        }

        if ($trimmed -match '^(?:[-*+]\s*|\d+\.\s*)$') {
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                [void]$items.Add($current.Trim())
                $current = ""
            }
            continue
        }

        if ($trimmed -match '^(?:[-*+]\s+|\d+\.\s+)(?<value>.+)$') {
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                [void]$items.Add($current.Trim())
            }
            $current = $Matches.value.Trim()
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $current = "{0} {1}" -f $current, $trimmed
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($current)) {
        [void]$items.Add($current.Trim())
    }

    return @($items.ToArray())
}

function Normalize-PromptPathPatternItem {
    param([string]$Item)

    $trimmed = ([string]$Item).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $trimmed
    }

    if ($trimmed -match '^(?<fence>`+)(?<content>.*)\k<fence>$') {
        return $Matches.content
    }

    return $trimmed
}

function ConvertTo-NormalizedPromptPathPatternArray {
    param($Value)

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(ConvertTo-StringArray -Value $Value)) {
        $normalized = (Normalize-PromptPathPatternItem -Item ([string]$entry)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            [void]$items.Add($normalized)
        }
    }

    return @($items.ToArray())
}

function ConvertTo-TrimmedPromptItemArray {
    param($Value)

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(ConvertTo-StringArray -Value $Value)) {
        $trimmed = ([string]$entry).Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            [void]$items.Add($trimmed)
        }
    }

    return @($items.ToArray())
}

function Format-PromptBulletLines {
    param(
        $Entries,
        [string]$EmptyLine = "- none declared"
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(ConvertTo-TrimmedPromptItemArray -Value $Entries)) {
        [void]$lines.Add("- {0}" -f $entry)
    }

    if ($lines.Count -eq 0) {
        [void]$lines.Add($EmptyLine)
    }

    return @($lines.ToArray())
}

function Convert-PromptAcceptanceCriteria {
    param([string[]]$Items)

    $criteria = New-Object System.Collections.Generic.List[object]
    $seenIds = New-Object System.Collections.Generic.HashSet[string]
    $counter = 0

    foreach ($item in @($Items)) {
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $counter += 1
        $text = $text.Trim()
        $criterionId = $null
        if ($text -match '^\[(?<id>[A-Za-z0-9._-]+)\]\s*(?<value>.+)$') {
            $candidateId = [string]$Matches.id
            if (-not [string]::IsNullOrWhiteSpace($candidateId)) {
                $criterionId = $candidateId.Trim().ToLowerInvariant()
                $text = $Matches.value.Trim()
            }
        }

        if ([string]::IsNullOrWhiteSpace($criterionId)) {
            $criterionId = ("ac-{0:00}" -f $counter)
        }

        while ($seenIds.Contains($criterionId)) {
            $counter += 1
            $criterionId = ("ac-{0:00}" -f $counter)
        }
        [void]$seenIds.Add($criterionId)

        [void]$criteria.Add([pscustomobject]@{
            id = $criterionId
            text = $text
        })
    }

    return @($criteria.ToArray())
}

function Parse-PromptFile {
    param([string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    $metadata = @{
        Verify = New-Object System.Collections.Generic.List[string]
        HandoffRefs = New-Object System.Collections.Generic.List[string]
        PausedHandoffRefs = New-Object System.Collections.Generic.List[string]
        MergeRequestRefs = New-Object System.Collections.Generic.List[string]
        QueryTerms = New-Object System.Collections.Generic.List[string]
        TaskTags = New-Object System.Collections.Generic.List[string]
        MutationAdmissionPaths = New-Object System.Collections.Generic.List[string]
        NoChangeAssertionIds = New-Object System.Collections.Generic.List[string]
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
            "handoffref" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.HandoffRefs.Add($value)
                }
            }
            "handoffrefs" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) {
                            [void]$metadata.HandoffRefs.Add($trimmedEntry)
                        }
                    }
                }
            }
            "pausedhandoffref" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.PausedHandoffRefs.Add($value)
                }
            }
            "pausedhandoffrefs" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) {
                            [void]$metadata.PausedHandoffRefs.Add($trimmedEntry)
                        }
                    }
                }
            }
            "mergerequestref" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.MergeRequestRefs.Add($value)
                }
            }
            "mergerequestrefs" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) {
                            [void]$metadata.MergeRequestRefs.Add($trimmedEntry)
                        }
                    }
                }
            }
            "queryterm" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.QueryTerms.Add($value)
                }
            }
            "queryterms" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) {
                            [void]$metadata.QueryTerms.Add($trimmedEntry)
                        }
                    }
                }
            }
            "mutationadmissionpath" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.MutationAdmissionPaths.Add($value)
                }
            }
            "mutationadmissionpaths" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) {
                            [void]$metadata.MutationAdmissionPaths.Add($trimmedEntry)
                        }
                    }
                }
            }
            "allownochanges" { $metadata.AllowNoChanges = $value }
            "nochangeproofpath" { $metadata.NoChangeProofPath = $value }
            "nochangeassertionids" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) { [void]$metadata.NoChangeAssertionIds.Add($trimmedEntry) }
                    }
                }
            }
            "admittedchangedpath" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.MutationAdmissionPaths.Add($value)
                }
            }
            "admittedchangedpaths" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) {
                            [void]$metadata.MutationAdmissionPaths.Add($trimmedEntry)
                        }
                    }
                }
            }
            "tasktag" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    [void]$metadata.TaskTags.Add($value)
                }
            }
            "tasktags" {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    foreach ($entry in ($value -split ',')) {
                        $trimmedEntry = $entry.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedEntry)) {
                            [void]$metadata.TaskTags.Add($trimmedEntry)
                        }
                    }
                }
            }
            "docsupdatenote" { $metadata.DocsUpdateNote = $value }
            "exportpatch" { $metadata.ExportPatch = $value }
            "exportbundle" { $metadata.ExportBundle = $value }
            "runtimemodel" { $metadata.RuntimeModel = $value }
            "runtimereasoning" { $metadata.RuntimeReasoning = $value }
            "runtimespeed" { $metadata.RuntimeSpeed = $value }
            "runtimepermissions" { $metadata.RuntimePermissions = $value }
            "runtimepermissionprofile" { $metadata.RuntimePermissionProfile = $value }
            "runtimesandboxmode" { $metadata.RuntimeSandboxMode = $value }
            "runtimeapproval" { $metadata.RuntimeApproval = $value }
            "runtimeapprovalpolicy" { $metadata.RuntimeApproval = $value }
            "runtimewebsearch" { $metadata.RuntimeWebSearch = $value }
            "runtimewebsearchmode" { $metadata.RuntimeWebSearch = $value }
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

    $bodySections = Get-PromptBodySections -Body $body
    $acceptanceCriteria = @()
    if ($bodySections.ContainsKey("acceptancecriteria")) {
        $acceptanceCriteria = Convert-PromptAcceptanceCriteria -Items (Convert-PromptSectionLinesToItems -Lines $bodySections["acceptancecriteria"])
    }
    $expectedChangedPaths = if ($bodySections.ContainsKey("expectedchangedpaths")) {
        @(ConvertTo-NormalizedPromptPathPatternArray -Value (Convert-PromptSectionLinesToItems -Lines $bodySections["expectedchangedpaths"]))
    }
    else {
        @()
    }
    $expectedUnchangedPaths = if ($bodySections.ContainsKey("expectedunchangedpaths")) {
        @(ConvertTo-NormalizedPromptPathPatternArray -Value (Convert-PromptSectionLinesToItems -Lines $bodySections["expectedunchangedpaths"]))
    }
    else {
        @()
    }
    $blockedSkippedRules = if ($bodySections.ContainsKey("blockedskippedreportingrules")) {
        @(Convert-PromptSectionLinesToItems -Lines $bodySections["blockedskippedreportingrules"])
    }
    else {
        @()
    }

    $title = Resolve-PromptTitle -Metadata $metadata -Lines $lines -Path $Path
    $branchSlug = if ($metadata.ContainsKey("BranchSlug")) { $metadata["BranchSlug"] } else { $null }
    $commitMessage = if ($metadata.ContainsKey("CommitMessage")) { $metadata["CommitMessage"] } else { $null }
    $docsUpdateNote = if ($metadata.ContainsKey("DocsUpdateNote")) { $metadata["DocsUpdateNote"] } else { $null }
    $exportPatch = if ($metadata.ContainsKey("ExportPatch")) { $metadata["ExportPatch"] } else { $null }
    $exportBundle = if ($metadata.ContainsKey("ExportBundle")) { $metadata["ExportBundle"] } else { $null }
    $runtimeModel = if ($metadata.ContainsKey("RuntimeModel")) { $metadata["RuntimeModel"] } else { $null }
    $runtimeReasoning = if ($metadata.ContainsKey("RuntimeReasoning")) { $metadata["RuntimeReasoning"] } else { $null }
    $runtimeSpeed = if ($metadata.ContainsKey("RuntimeSpeed")) { $metadata["RuntimeSpeed"] } else { $null }
    $runtimePermissions = if ($metadata.ContainsKey("RuntimePermissions")) { $metadata["RuntimePermissions"] } else { $null }
    $runtimePermissionProfile = if ($metadata.ContainsKey("RuntimePermissionProfile")) { $metadata["RuntimePermissionProfile"] } else { $null }
    $runtimeSandboxMode = if ($metadata.ContainsKey("RuntimeSandboxMode")) { $metadata["RuntimeSandboxMode"] } else { $null }
    $runtimeApproval = if ($metadata.ContainsKey("RuntimeApproval")) { $metadata["RuntimeApproval"] } else { $null }
    $runtimeWebSearch = if ($metadata.ContainsKey("RuntimeWebSearch")) { $metadata["RuntimeWebSearch"] } else { $null }
    $allowNoChangesRaw = if ($metadata.ContainsKey("AllowNoChanges")) { $metadata["AllowNoChanges"] } else { $null }
    $allowNoChanges = ConvertTo-StrictPromptBoolean -Value $allowNoChangesRaw -DefaultValue $false -Name "Allow No Changes"
    $noChangeProofPath = if ($metadata.ContainsKey("NoChangeProofPath")) { $metadata["NoChangeProofPath"] } else { $null }

    return [pscustomobject]@{
        Title = $title
        BranchSlug = $branchSlug
        CommitMessage = $commitMessage
        Verify = @($metadata.Verify.ToArray())
        HandoffRefs = @($metadata.HandoffRefs.ToArray())
        PausedHandoffRefs = @($metadata.PausedHandoffRefs.ToArray())
        MergeRequestRefs = @($metadata.MergeRequestRefs.ToArray())
        QueryTerms = @($metadata.QueryTerms.ToArray())
        TaskTags = @($metadata.TaskTags.ToArray())
        MutationAdmissionPaths = @(Normalize-RepoRelativePathList -Paths @($metadata.MutationAdmissionPaths.ToArray()))
        AllowNoChanges = $allowNoChanges
        NoChangeProofPath = $noChangeProofPath
        NoChangeAssertionIds = @(Normalize-RepoRelativePathList -Paths @($metadata.NoChangeAssertionIds.ToArray()))
        DocsUpdateNote = $docsUpdateNote
        ExportPatch = $exportPatch
        ExportBundle = $exportBundle
        RuntimeModel = $runtimeModel
        RuntimeReasoning = $runtimeReasoning
        RuntimeSpeed = $runtimeSpeed
        RuntimePermissions = $runtimePermissions
        RuntimePermissionProfile = $runtimePermissionProfile
        RuntimeSandboxMode = $runtimeSandboxMode
        RuntimeApproval = $runtimeApproval
        RuntimeWebSearch = $runtimeWebSearch
        AcceptanceCriteria = @($acceptanceCriteria)
        ExpectedChangedPaths = @($expectedChangedPaths)
        ExpectedUnchangedPaths = @($expectedUnchangedPaths)
        BlockedSkippedRules = @($blockedSkippedRules)
        Body = $body
        RawContent = $rawContent
    }
}

function Get-NoChangePromptPolicy {
    param($PromptRecord)

    $allowed = $false
    if ($null -ne $PromptRecord -and $PromptRecord.PSObject.Properties.Name -contains "AllowNoChanges") { $allowed = [bool]$PromptRecord.AllowNoChanges }
    $proofPath = if ($null -ne $PromptRecord -and $PromptRecord.PSObject.Properties.Name -contains "NoChangeProofPath") { [string]$PromptRecord.NoChangeProofPath } else { "" }
    $assertionIds = if ($null -ne $PromptRecord -and $PromptRecord.PSObject.Properties.Name -contains "NoChangeAssertionIds") { @(Normalize-RepoRelativePathList -Paths @($PromptRecord.NoChangeAssertionIds)) } else { @() }
    $result = [ordered]@{ allowed = $allowed; proofPath = $proofPath; declaredAssertionIds = @($assertionIds); admissionValid = $true; blockingReasons = @() }
    if (-not $allowed) { return [pscustomobject]$result }

    if ($assertionIds.Count -eq 0) { $result.admissionValid = $false; $result.blockingReasons += "Allow No Changes requires at least one No-Change Assertion IDs value." }
    if (@($assertionIds | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' }).Count -gt 0) { $result.admissionValid = $false; $result.blockingReasons += "No-Change Assertion IDs must be stable IDs containing only letters, digits, dot, underscore, or hyphen." }
    if (@($assertionIds | Select-Object -Unique).Count -ne $assertionIds.Count) { $result.admissionValid = $false; $result.blockingReasons += "No-Change Assertion IDs must not contain duplicates." }
    $normalizedProofPath = $proofPath.Trim().Replace("\\", "/")
    if ([string]::IsNullOrWhiteSpace($normalizedProofPath) -or [System.IO.Path]::IsPathRooted($proofPath) -or -not $normalizedProofPath.StartsWith(".codex/") -or $normalizedProofPath -match '(^|/)\.\.(/|$)' -or $normalizedProofPath -eq ".codex/") { $result.admissionValid = $false; $result.blockingReasons += "Allow No Changes requires a safe repo-relative No-Change Proof Path under .codex/." }
    if (@($PromptRecord.AcceptanceCriteria).Count -ne 0) { $result.admissionValid = $false; $result.blockingReasons += "Allow No Changes cannot be combined with acceptance criteria." }
    if (@($PromptRecord.ExpectedChangedPaths).Count -ne 0) { $result.admissionValid = $false; $result.blockingReasons += "Allow No Changes cannot declare expected changed paths." }
    if (@($PromptRecord.MutationAdmissionPaths).Count -ne 0) { $result.admissionValid = $false; $result.blockingReasons += "Allow No Changes cannot declare mutation admission paths." }
    $result.proofPath = $normalizedProofPath
    return [pscustomobject]$result
}

function Test-NoChangeCompletionProof {
    param($Policy, $ArtifactRecord)

    $result = [ordered]@{ isValid = $true; blockingReasons = @(); summary = $null; provenAssertionIds = @() }
    if ($null -eq $ArtifactRecord) { $result.isValid = $false; $result.blockingReasons += "Verified no-change proof artifact is required."; return [pscustomobject]$result }
    if (-not [string]::IsNullOrWhiteSpace([string]$ArtifactRecord.parseError)) { $result.isValid = $false; $result.blockingReasons += ("Verified no-change proof artifact could not be parsed: {0}" -f $ArtifactRecord.parseError); return [pscustomobject]$result }
    $payload = $ArtifactRecord.payload
    if ($null -eq $payload) { $result.isValid = $false; $result.blockingReasons += "Verified no-change proof artifact payload is missing."; return [pscustomobject]$result }
    if ([string](Get-ObjectPropertyValue -Object $payload -Name "schemaVersion" -DefaultValue "") -ne "1.0") { $result.isValid = $false; $result.blockingReasons += "Verified no-change proof must declare schemaVersion=1.0." }
    if ([string](Get-ObjectPropertyValue -Object $payload -Name "status" -DefaultValue "") -ne "passed") { $result.isValid = $false; $result.blockingReasons += "Verified no-change proof top-level status must be passed." }
    $summary = [string](Get-ObjectPropertyValue -Object $payload -Name "summary" -DefaultValue "")
    if ([string]::IsNullOrWhiteSpace($summary) -or [System.Text.Encoding]::UTF8.GetByteCount($summary) -gt 2048) { $result.isValid = $false; $result.blockingReasons += "Verified no-change proof summary must be non-empty and at most 2 KiB." } else { $result.summary = $summary }
    $hasBlockersProperty = $payload.PSObject.Properties.Name -contains "blockers"
    $blockers = @(Get-ObjectPropertyValue -Object $payload -Name "blockers" -DefaultValue @())
    if (-not $hasBlockersProperty -or $blockers.Count -ne 0) { $result.isValid = $false; $result.blockingReasons += "Verified no-change proof blockers must be an empty array." }
    $assertions = @(Get-ObjectPropertyValue -Object $payload -Name "assertions" -DefaultValue @())
    $byId = @{}
    foreach ($assertion in $assertions) {
        $id = [string](Get-ObjectPropertyValue -Object $assertion -Name "id" -DefaultValue "")
        if ([string]::IsNullOrWhiteSpace($id)) { $result.isValid = $false; $result.blockingReasons += "Each verified no-change assertion must declare id."; continue }
        if ($byId.ContainsKey($id)) { $result.isValid = $false; $result.blockingReasons += ("Verified no-change proof contains duplicate assertion '{0}'." -f $id); continue }
        $byId[$id] = $assertion
    }
    foreach ($id in $byId.Keys) { if ($id -notin @($Policy.declaredAssertionIds)) { $result.isValid = $false; $result.blockingReasons += ("Verified no-change proof contains unknown assertion '{0}'." -f $id) } }
    foreach ($id in @($Policy.declaredAssertionIds)) {
        if (-not $byId.ContainsKey($id)) { $result.isValid = $false; $result.blockingReasons += ("Verified no-change proof is missing declared assertion '{0}'." -f $id); continue }
        $assertion = $byId[$id]
        if ([string](Get-ObjectPropertyValue -Object $assertion -Name "status" -DefaultValue "") -ne "passed") { $result.isValid = $false; $result.blockingReasons += ("Verified no-change assertion '{0}' must have status passed." -f $id) }
        $evidence = Get-ObjectPropertyValue -Object $assertion -Name "evidence" -DefaultValue $null
        if ($null -eq $evidence -or [System.Text.Encoding]::UTF8.GetByteCount(($evidence | ConvertTo-Json -Compress -Depth 12)) -gt 8192) { $result.isValid = $false; $result.blockingReasons += ("Verified no-change assertion '{0}' evidence must be present and at most 8 KiB." -f $id) }
        $result.provenAssertionIds += $id
    }
    return [pscustomobject]$result
}

function Get-SpecToDiffPromptPolicy {
    param($PromptRecord)

    [object[]]$criteria = if ($null -ne $PromptRecord -and $PromptRecord.PSObject.Properties.Name -contains "AcceptanceCriteria") {
        @($PromptRecord.AcceptanceCriteria)
    }
    else {
        @()
    }
    [object[]]$expectedChangedPaths = if ($null -ne $PromptRecord -and $PromptRecord.PSObject.Properties.Name -contains "ExpectedChangedPaths") {
        @($PromptRecord.ExpectedChangedPaths)
    }
    else {
        @()
    }
    [object[]]$expectedUnchangedPaths = if ($null -ne $PromptRecord -and $PromptRecord.PSObject.Properties.Name -contains "ExpectedUnchangedPaths") {
        @($PromptRecord.ExpectedUnchangedPaths)
    }
    else {
        @()
    }
    [object[]]$blockedSkippedRules = if ($null -ne $PromptRecord -and $PromptRecord.PSObject.Properties.Name -contains "BlockedSkippedRules") {
        @($PromptRecord.BlockedSkippedRules)
    }
    else {
        @()
    }

    $criteriaList = @($criteria)
    $expectedChangedPathList = @(ConvertTo-TrimmedPromptItemArray -Value $expectedChangedPaths)
    $expectedUnchangedPathList = @(ConvertTo-TrimmedPromptItemArray -Value $expectedUnchangedPaths)
    $blockedSkippedRuleList = @(ConvertTo-TrimmedPromptItemArray -Value $blockedSkippedRules)
    $criteriaEnabled = ($criteriaList | Measure-Object).Count -gt 0

    return [pscustomobject]@{
        enabled = $criteriaEnabled
        artifactPath = ".codex/spec-to-diff-proof.json"
        acceptanceCriteria = $criteriaList
        expectedChangedPaths = $expectedChangedPathList
        expectedUnchangedPaths = $expectedUnchangedPathList
        blockedSkippedRules = $blockedSkippedRuleList
    }
}

function Get-SpecToDiffInstructionBlock {
    param($Policy)

    if ($null -eq $Policy -or -not [bool]$Policy.enabled) {
        return ""
    }

    $criterionLines = @(
        $Policy.acceptanceCriteria |
        ForEach-Object { "- {0}: {1}" -f [string]$_.id, [string]$_.text }
    )

    return (@(
        "Spec-to-diff completion contract:",
        ("- This prompt declares acceptance criteria, so write UTF-8 JSON to `{0}`." -f $Policy.artifactPath),
        "- Use exactly this shape:",
        '- {"contract_version":"atlas.stack.spec_to_diff.v1","criteria":[{"criterion_id":"ac-01","status":"satisfied","changed_paths":["docs/example.md"],"diff_evidence":["literal diff snippet"],"note":"optional note"}],"unchanged_path_justifications":[{"path":"docs/example.md","justification":"why the expected unchanged path changed","criterion_ids":["ac-01"]}]}',
        "- Emit one criteria entry for every acceptance criterion id listed below.",
        "- Allowed criterion statuses: satisfied, skipped, failed, blocked.",
        "- For satisfied criteria, changed_paths must list the actual changed repo-relative files and diff_evidence must quote short literal snippets that appear in the final diff or newly added file content.",
        "- Do not mark a criterion satisfied unless it is provable from the final diff.",
        "- If any criterion cannot be completed or proven, mark it blocked, skipped, or failed and explain why in note.",
        "- If an expected unchanged path changes, add an unchanged_path_justifications entry with an explicit reason.",
        "- Before returning control to the runner, run `pnpm run codex:spec-to-diff:preflight` and correct the proof artifact until the command exits successfully.",
        "Acceptance criteria ids:",
        ($criterionLines -join "`r`n"),
        "Expected changed paths:",
        ((Format-PromptBulletLines -Entries $Policy.expectedChangedPaths) -join "`r`n"),
        "Expected unchanged paths:",
        ((Format-PromptBulletLines -Entries $Policy.expectedUnchangedPaths) -join "`r`n"),
        "Blocked / skipped reporting rules:",
        ((Format-PromptBulletLines -Entries $Policy.blockedSkippedRules) -join "`r`n")
    ) -join "`r`n")
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

function Normalize-RunnerOptionalString {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text.Trim()
}

function Normalize-RuntimeSpeedMode {
    param($Value)

    $text = Normalize-RunnerOptionalString -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    switch ($text.Trim().ToLowerInvariant()) {
        "standard" { return "standard" }
        "normal" { return "standard" }
        "default" { return "standard" }
        "fast" { return "fast" }
        default { throw ("Unsupported runtime speed mode: {0}" -f $text) }
    }
}

function Normalize-RuntimePermissionMode {
    param($Value)

    $text = Normalize-RunnerOptionalString -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    switch (($text.Trim().ToLowerInvariant()).Replace("_", "-")) {
        "full-access" { return "full-access" }
        "fullaccess" { return "full-access" }
        "workspace-write" { return "workspace-write" }
        "workspacewrite" { return "workspace-write" }
        "read-only" { return "read-only" }
        "readonly" { return "read-only" }
        "custom" { return "custom" }
        default { throw ("Unsupported runtime permissions mode: {0}" -f $text) }
    }
}

function Normalize-RuntimeWebSearchMode {
    param($Value)

    $text = Normalize-RunnerOptionalString -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    switch ($text.Trim().ToLowerInvariant()) {
        "disabled" { return "disabled" }
        "off" { return "disabled" }
        "false" { return "disabled" }
        "none" { return "disabled" }
        "live" { return "live" }
        "enabled" { return "live" }
        "on" { return "live" }
        "true" { return "live" }
        default { throw ("Unsupported runtime web-search mode: {0}" -f $text) }
    }
}

function Normalize-RuntimePermissionProfile {
    param($Value)

    return Normalize-RunnerOptionalString -Value $Value
}

function Normalize-RuntimeSandboxMode {
    param($Value)

    $text = Normalize-RunnerOptionalString -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text.Trim().ToLowerInvariant()
}

function Get-RuntimePolicyConfigLayer {
    param([hashtable]$Config)

    return [pscustomobject]@{
        model = Normalize-RunnerOptionalString -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "model") -DefaultValue (Get-ConfigValue -Config $Config -Path @("model") -DefaultValue $null))
        reasoning = Normalize-RunnerOptionalString -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "reasoning") -DefaultValue (Get-ConfigValue -Config $Config -Path @("model_reasoning_effort") -DefaultValue $null))
        speed = Normalize-RuntimeSpeedMode -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "speed") -DefaultValue $null)
        permissions = Normalize-RuntimePermissionMode -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "permissions") -DefaultValue $null)
        permission_profile = Normalize-RuntimePermissionProfile -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "permission_profile") -DefaultValue $null)
        sandbox_mode = Normalize-RuntimeSandboxMode -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "sandbox_mode") -DefaultValue (Get-ConfigValue -Config $Config -Path @("windows", "sandbox") -DefaultValue $null))
        approval = Normalize-RunnerOptionalString -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "approval") -DefaultValue (Get-ConfigValue -Config $Config -Path @("windows", "approval_policy") -DefaultValue $null))
        web_search = Normalize-RuntimeWebSearchMode -Value (Get-ConfigValue -Config $Config -Path @("runtime_policy", "web_search") -DefaultValue $null)
    }
}

function Resolve-RuntimePolicyField {
    param(
        [object[]]$Candidates,
        [string]$Name
    )

    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) {
            continue
        }

        $value = Get-ObjectPropertyValue -Object $candidate -Name "value" -DefaultValue $null
        if ($null -eq $value) {
            continue
        }

        if ($value -is [string] -and [string]::IsNullOrWhiteSpace([string]$value)) {
            continue
        }

        $source = [string](Get-ObjectPropertyValue -Object $candidate -Name "source" -DefaultValue "")
        return [pscustomobject]@{
            name = $Name
            value = $value
            source = if ([string]::IsNullOrWhiteSpace($source)) { $null } else { $source }
        }
    }

    return [pscustomobject]@{
        name = $Name
        value = $null
        source = $null
    }
}

function Get-RunnerPermissionModeFromMechanism {
    param(
        [string]$PermissionProfile,
        [string]$SandboxMode
    )

    $normalizedPermissionProfile = Normalize-RuntimePermissionProfile -Value $PermissionProfile
    if (-not [string]::IsNullOrWhiteSpace($normalizedPermissionProfile)) {
        switch ($normalizedPermissionProfile) {
            ":danger-full-access" { return "full-access" }
            default { return "custom" }
        }
    }

    $normalizedSandboxMode = Normalize-RuntimeSandboxMode -Value $SandboxMode
    switch ($normalizedSandboxMode) {
        "danger-full-access" { return "full-access" }
        "workspace-write" { return "workspace-write" }
        "read-only" { return "read-only" }
        default { return $null }
    }
}

function Get-CodexRuntimeHostDirectory {
    $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "atlas-codex-runtime-host"
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    return $path
}

function Get-CodexCliContext {
    param([string]$CodexCommand)

    $hostDirectory = Get-CodexRuntimeHostDirectory
    $versionResult = Invoke-ProcessCapture -FilePath $CodexCommand -ArgumentList @("--version") -WorkingDirectory $hostDirectory
    $version = $null
    if ($versionResult.ExitCode -eq 0) {
        [object[]]$versionOutput = @(
            $versionResult.StdOut.Trim(),
            $versionResult.StdErr.Trim() |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First 1
        )
        if ($versionOutput.Count -gt 0) {
            $version = [string]$versionOutput[0]
        }
    }

    return [pscustomobject]@{
        codexVersion = $version
        hostDirectory = $hostDirectory
    }
}

function Get-RuntimePolicySourcePrecedence {
    param([string]$Source)

    switch ([string]$Source) {
        "explicit-arg" { return 4 }
        "prompt-metadata" { return 3 }
        "repo-config" { return 2 }
        "shared-default" { return 1 }
        default { return 0 }
    }
}

function Invoke-CodexModelCapabilityProbe {
    param([string]$CodexCommand, [string]$ProbeTargetPath, [string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model)) { return [pscustomobject]@{ requested_model = $null; effective_model = $null; status = "probe_failed"; note = "Model capability probe requires a requested model."; exit_code = $null } }
    if ([string]::IsNullOrWhiteSpace($CodexCommand) -or -not (Test-Path -LiteralPath $CodexCommand -PathType Leaf)) { return [pscustomobject]@{ requested_model = $Model; effective_model = $null; status = "unavailable"; note = "Resolved native Codex executable was unavailable before model capability probing."; exit_code = $null } }
    $probeDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-codex-model-probe-" + [guid]::NewGuid().ToString("N")); New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
    try {
        $result = Invoke-ProcessCapture -FilePath $CodexCommand -ArgumentList @("-a", "never", "-m", $Model, "-s", "read-only", "exec", "--json", "-o", (Join-Path $probeDirectory "summary.jsonl"), "-C", $ProbeTargetPath, "-") -WorkingDirectory $probeDirectory -StandardInputText "Reply with EXACTLY ATLAS_MODEL_CAPABILITY_ACCEPTED."
    }
    catch { $status = if ($_.Exception.Message -match "cannot find|could not find|failed to start") { "unavailable" } else { "probe_failed" }; return [pscustomobject]@{ requested_model = $Model; effective_model = $null; status = $status; note = $_.Exception.Message; exit_code = $null } }
    finally { if (Test-Path -LiteralPath $probeDirectory) { Remove-Item -LiteralPath $probeDirectory -Recurse -Force -ErrorAction SilentlyContinue } }
    if ($result.ExitCode -eq 0) { return [pscustomobject]@{ requested_model = $Model; effective_model = $Model; status = "accepted"; note = $null; exit_code = $result.ExitCode } }
    $output = @($result.StdOut, $result.StdErr) -join "`n"
    $status = if ($output.ToLowerInvariant() -match "model(?:\s+\S+)?\s+is not supported|unsupported model|model_not_supported") { "unsupported_model" } else { "probe_failed" }
    return [pscustomobject]@{ requested_model = $Model; effective_model = $null; status = $status; note = "Codex model capability probe failed with exit code $($result.ExitCode)."; exit_code = $result.ExitCode }
}

function Resolve-StackRuntimePolicy {
    param(
        [hashtable]$Config,
        [hashtable]$RepoConfig = $null,
        [hashtable]$DefaultsConfig = $null,
        $PromptRecord,
        $ExplicitPolicy,
        [string]$CodexCommand,
        $CliContext = $null,
        [string]$ProbeTargetPath = $null
    )

    $repoConfigPolicy = Get-RuntimePolicyConfigLayer -Config $(if ($null -ne $RepoConfig) { $RepoConfig } else { @{} })
    $sharedDefaultsPolicy = Get-RuntimePolicyConfigLayer -Config $(if ($null -ne $DefaultsConfig) { $DefaultsConfig } else { @{} })

    $promptPolicy = [pscustomobject]@{
        model = Normalize-RunnerOptionalString -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimeModel" -DefaultValue $null)
        reasoning = Normalize-RunnerOptionalString -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimeReasoning" -DefaultValue $null)
        speed = Normalize-RuntimeSpeedMode -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimeSpeed" -DefaultValue $null)
        permissions = Normalize-RuntimePermissionMode -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimePermissions" -DefaultValue $null)
        permission_profile = Normalize-RuntimePermissionProfile -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimePermissionProfile" -DefaultValue $null)
        sandbox_mode = Normalize-RuntimeSandboxMode -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimeSandboxMode" -DefaultValue $null)
        approval = Normalize-RunnerOptionalString -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimeApproval" -DefaultValue $null)
        web_search = Normalize-RuntimeWebSearchMode -Value (Get-ObjectPropertyValue -Object $PromptRecord -Name "RuntimeWebSearch" -DefaultValue $null)
    }

    $explicitResolved = [pscustomobject]@{
        model = Normalize-RunnerOptionalString -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "model" -DefaultValue $null)
        reasoning = Normalize-RunnerOptionalString -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "reasoning" -DefaultValue $null)
        speed = Normalize-RuntimeSpeedMode -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "speed" -DefaultValue $null)
        permissions = Normalize-RuntimePermissionMode -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "permissions" -DefaultValue $null)
        permission_profile = Normalize-RuntimePermissionProfile -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "permission_profile" -DefaultValue $null)
        sandbox_mode = Normalize-RuntimeSandboxMode -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "sandbox_mode" -DefaultValue $null)
        approval = Normalize-RunnerOptionalString -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "approval" -DefaultValue $null)
        web_search = Normalize-RuntimeWebSearchMode -Value (Get-ObjectPropertyValue -Object $ExplicitPolicy -Name "web_search" -DefaultValue $null)
    }

    $modelResult = Resolve-RuntimePolicyField -Name "model" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.model; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.model; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.model; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.model; source = "shared-default" }
    )
    $reasoningResult = Resolve-RuntimePolicyField -Name "reasoning" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.reasoning; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.reasoning; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.reasoning; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.reasoning; source = "shared-default" }
    )
    $speedResult = Resolve-RuntimePolicyField -Name "speed" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.speed; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.speed; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.speed; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.speed; source = "shared-default" }
    )
    $permissionsModeResult = Resolve-RuntimePolicyField -Name "permissions" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.permissions; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.permissions; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.permissions; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.permissions; source = "shared-default" }
    )
    $permissionProfileResult = Resolve-RuntimePolicyField -Name "permission_profile" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.permission_profile; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.permission_profile; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.permission_profile; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.permission_profile; source = "shared-default" }
    )
    $sandboxModeResult = Resolve-RuntimePolicyField -Name "sandbox_mode" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.sandbox_mode; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.sandbox_mode; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.sandbox_mode; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.sandbox_mode; source = "shared-default" }
    )
    $approvalResult = Resolve-RuntimePolicyField -Name "approval" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.approval; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.approval; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.approval; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.approval; source = "shared-default" }
    )
    $webSearchResult = Resolve-RuntimePolicyField -Name "web_search" -Candidates @(
        [pscustomobject]@{ value = $explicitResolved.web_search; source = "explicit-arg" },
        [pscustomobject]@{ value = $promptPolicy.web_search; source = "prompt-metadata" },
        [pscustomobject]@{ value = $repoConfigPolicy.web_search; source = "repo-config" },
        [pscustomobject]@{ value = $sharedDefaultsPolicy.web_search; source = "shared-default" }
    )

    $requestedPermissionProfile = $permissionProfileResult.value
    $requestedPermissionProfileSource = $permissionProfileResult.source
    $requestedSandboxMode = $sandboxModeResult.value
    $requestedSandboxSource = $sandboxModeResult.source
    $warnings = New-Object System.Collections.Generic.List[string]
    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($requestedPermissionProfile) -and -not [string]::IsNullOrWhiteSpace($requestedSandboxMode)) {
        $permissionProfileRank = Get-RuntimePolicySourcePrecedence -Source $requestedPermissionProfileSource
        $sandboxRank = Get-RuntimePolicySourcePrecedence -Source $requestedSandboxSource
        if ($permissionProfileRank -gt $sandboxRank) {
            [void]$warnings.Add(("Runtime policy suppressed lower-precedence legacy sandbox mode '{0}' from {1} because permission profile '{2}' came from {3}." -f $requestedSandboxMode, $requestedSandboxSource, $requestedPermissionProfile, $requestedPermissionProfileSource))
            $requestedSandboxMode = $null
            $requestedSandboxSource = $null
        }
        elseif ($sandboxRank -gt $permissionProfileRank) {
            [void]$warnings.Add(("Runtime policy suppressed lower-precedence permission profile '{0}' from {1} because legacy sandbox mode '{2}' came from {3}." -f $requestedPermissionProfile, $requestedPermissionProfileSource, $requestedSandboxMode, $requestedSandboxSource))
            $requestedPermissionProfile = $null
            $requestedPermissionProfileSource = $null
        }
        else {
            throw ("Runtime policy conflict: permission profile '{0}' and legacy sandbox mode '{1}' cannot be active together. Remove one mechanism." -f $requestedPermissionProfile, $requestedSandboxMode)
        }
    }

    $requestedPermissionMode = $permissionsModeResult.value
    $requestedPermissionModeSource = $permissionsModeResult.source
    if ([string]::IsNullOrWhiteSpace($requestedPermissionMode)) {
        $requestedPermissionMode = Get-RunnerPermissionModeFromMechanism -PermissionProfile $requestedPermissionProfile -SandboxMode $requestedSandboxMode
    }

    $mechanismMode = Get-RunnerPermissionModeFromMechanism -PermissionProfile $requestedPermissionProfile -SandboxMode $requestedSandboxMode
    if (
        -not [string]::IsNullOrWhiteSpace($permissionsModeResult.value) -and
        -not [string]::IsNullOrWhiteSpace($mechanismMode) -and
        $permissionsModeResult.value -ne "custom" -and
        $permissionsModeResult.value -ne $mechanismMode
    ) {
        $mechanismSource = if (-not [string]::IsNullOrWhiteSpace($requestedPermissionProfile)) { $requestedPermissionProfileSource } else { $requestedSandboxSource }
        $permissionsModeRank = Get-RuntimePolicySourcePrecedence -Source $permissionsModeResult.source
        $mechanismRank = Get-RuntimePolicySourcePrecedence -Source $mechanismSource
        if ($permissionsModeRank -gt $mechanismRank) {
            if (-not [string]::IsNullOrWhiteSpace($requestedPermissionProfile)) {
                [void]$warnings.Add(("Runtime policy suppressed lower-precedence permission profile '{0}' from {1} because permissions mode '{2}' came from {3}." -f $requestedPermissionProfile, $requestedPermissionProfileSource, $permissionsModeResult.value, $permissionsModeResult.source))
                $requestedPermissionProfile = $null
                $requestedPermissionProfileSource = $null
            }
            else {
                [void]$warnings.Add(("Runtime policy suppressed lower-precedence legacy sandbox mode '{0}' from {1} because permissions mode '{2}' came from {3}." -f $requestedSandboxMode, $requestedSandboxSource, $permissionsModeResult.value, $permissionsModeResult.source))
                $requestedSandboxMode = $null
                $requestedSandboxSource = $null
            }
        }
        elseif ($mechanismRank -gt $permissionsModeRank) {
            $mechanismLabel = if (-not [string]::IsNullOrWhiteSpace($requestedPermissionProfile)) { "permission profile" } else { "legacy sandbox mode" }
            $mechanismValue = if (-not [string]::IsNullOrWhiteSpace($requestedPermissionProfile)) { $requestedPermissionProfile } else { $requestedSandboxMode }
            [void]$warnings.Add(("Runtime policy suppressed lower-precedence permissions mode '{0}' from {1} because {2} '{3}' came from {4}." -f $permissionsModeResult.value, $permissionsModeResult.source, $mechanismLabel, $mechanismValue, $mechanismSource))
            $requestedPermissionMode = $mechanismMode
            $requestedPermissionModeSource = $mechanismSource
        }
        else {
            throw ("Runtime policy conflict: permissions mode '{0}' does not match the requested permission mechanism." -f $permissionsModeResult.value)
        }
    }

    $resolvedPermissionProfile = $requestedPermissionProfile
    $resolvedSandboxMode = $requestedSandboxMode
    $permissionsProfileSource = $requestedPermissionProfileSource
    $sandboxSource = $requestedSandboxSource
    if ([string]::IsNullOrWhiteSpace($resolvedPermissionProfile) -and [string]::IsNullOrWhiteSpace($resolvedSandboxMode)) {
        switch ($requestedPermissionMode) {
            "full-access" {
                $resolvedPermissionProfile = ":danger-full-access"
                $permissionsProfileSource = if ([string]::IsNullOrWhiteSpace($requestedPermissionModeSource)) { "derived-from-permissions" } else { "derived-from-$requestedPermissionModeSource" }
            }
            "workspace-write" {
                $resolvedSandboxMode = "workspace-write"
                $sandboxSource = if ([string]::IsNullOrWhiteSpace($requestedPermissionModeSource)) { "derived-from-permissions" } else { "derived-from-$requestedPermissionModeSource" }
            }
            "read-only" {
                $resolvedSandboxMode = "read-only"
                $sandboxSource = if ([string]::IsNullOrWhiteSpace($requestedPermissionModeSource)) { "derived-from-permissions" } else { "derived-from-$requestedPermissionModeSource" }
            }
        }
    }

    $resolvedPermissionMode = $requestedPermissionMode
    if ([string]::IsNullOrWhiteSpace($resolvedPermissionMode)) {
        $resolvedPermissionMode = Get-RunnerPermissionModeFromMechanism -PermissionProfile $resolvedPermissionProfile -SandboxMode $resolvedSandboxMode
    }

    $resolvedSpeed = if ([string]::IsNullOrWhiteSpace($speedResult.value)) { "standard" } else { [string]$speedResult.value }
    $speedSource = if ([string]::IsNullOrWhiteSpace($speedResult.source)) { "shared-default" } else { [string]$speedResult.source }
    if ($null -eq $CliContext -and -not [string]::IsNullOrWhiteSpace($CodexCommand)) {
        $CliContext = Get-CodexCliContext -CodexCommand $CodexCommand
    }

    $requestedModel = if ([string]::IsNullOrWhiteSpace($modelResult.value)) { $null } else { [string]$modelResult.value }
    $modelCapability = Invoke-CodexModelCapabilityProbe -CodexCommand $CodexCommand -ProbeTargetPath $(if ([string]::IsNullOrWhiteSpace($ProbeTargetPath)) { (Get-CodexRuntimeHostDirectory) } else { $ProbeTargetPath }) -Model $requestedModel
    $effectiveModel = [string](Get-ObjectPropertyValue -Object $modelCapability -Name "effective_model" -DefaultValue $null)
    if ([string](Get-ObjectPropertyValue -Object $modelCapability -Name "status" -DefaultValue "") -ne "accepted") {
        [void]$blockers.Add([string](Get-ObjectPropertyValue -Object $modelCapability -Name "note" -DefaultValue "Requested model did not pass capability probing."))
    }

    $resolvedApproval = if ([string]::IsNullOrWhiteSpace($approvalResult.value)) { "never" } else { [string]$approvalResult.value }
    $resolvedWebSearch = if ([string]::IsNullOrWhiteSpace($webSearchResult.value)) { "disabled" } else { [string]$webSearchResult.value }

    return [pscustomobject]@{
        requested = [ordered]@{
            model = $requestedModel
            reasoning = if ([string]::IsNullOrWhiteSpace($reasoningResult.value)) { $null } else { [string]$reasoningResult.value }
            speed = if ([string]::IsNullOrWhiteSpace($speedResult.value)) { "standard" } else { [string]$speedResult.value }
            permissions = [ordered]@{
                mode = $requestedPermissionMode
                permission_profile = if ([string]::IsNullOrWhiteSpace($requestedPermissionProfile)) { $null } else { [string]$requestedPermissionProfile }
                sandbox_mode = if ([string]::IsNullOrWhiteSpace($requestedSandboxMode)) { $null } else { [string]$requestedSandboxMode }
            }
        }
        resolved = [ordered]@{
            model = $effectiveModel
            reasoning = if ([string]::IsNullOrWhiteSpace($reasoningResult.value)) { $null } else { [string]$reasoningResult.value }
            speed = $resolvedSpeed
            permissions = [ordered]@{
                mode = $resolvedPermissionMode
                permission_profile = if ([string]::IsNullOrWhiteSpace($resolvedPermissionProfile)) { $null } else { [string]$resolvedPermissionProfile }
                sandbox_mode = if ([string]::IsNullOrWhiteSpace($resolvedSandboxMode)) { $null } else { [string]$resolvedSandboxMode }
            }
            approval = $resolvedApproval
            web_search = $resolvedWebSearch
            codex_version = [string](Get-ObjectPropertyValue -Object $CliContext -Name "codexVersion" -DefaultValue $null)
        }
        sources = [ordered]@{
            model = if ([string]::IsNullOrWhiteSpace($modelResult.source)) { "shared-default" } else { [string]$modelResult.source }
            reasoning = if ([string]::IsNullOrWhiteSpace($reasoningResult.source)) { "shared-default" } else { [string]$reasoningResult.source }
            speed = $speedSource
            permissions = [ordered]@{
                mode = if ([string]::IsNullOrWhiteSpace($requestedPermissionModeSource)) { $null } else { [string]$requestedPermissionModeSource }
                permission_profile = if ([string]::IsNullOrWhiteSpace($permissionsProfileSource)) { $null } else { [string]$permissionsProfileSource }
                sandbox_mode = if ([string]::IsNullOrWhiteSpace($sandboxSource)) { $null } else { [string]$sandboxSource }
            }
        }
        requested_model = $requestedModel
        effective_model = $effectiveModel
        model_capability = $modelCapability
        codex_version = [string](Get-ObjectPropertyValue -Object $CliContext -Name "codexVersion" -DefaultValue $null)
        warnings = @($warnings.ToArray())
        blockers = @($blockers.ToArray())
        cliContext = $CliContext
    }
}

function Get-RuntimePolicyReceipt {
    param($RuntimePolicy)
    if ($null -eq $RuntimePolicy) { return $null }
    return [ordered]@{ requested = $RuntimePolicy.requested; resolved = $RuntimePolicy.resolved; sources = $RuntimePolicy.sources; requested_model = $RuntimePolicy.requested_model; effective_model = $RuntimePolicy.effective_model; model_capability = $RuntimePolicy.model_capability; codex_version = $RuntimePolicy.codex_version; warnings = @($RuntimePolicy.warnings); blockers = @($RuntimePolicy.blockers) }
}

function New-CodexInvocationPlan {
    param(
        $RuntimePolicy,
        [string]$SummaryPath,
        [string]$WorktreePath,
        [string]$Personality = ""
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $resolvedPolicy = if ($null -ne $RuntimePolicy) { $RuntimePolicy.resolved } else { $null }
    $resolvedPermissions = if ($null -ne $resolvedPolicy) { $resolvedPolicy.permissions } else { $null }

    $approval = [string](Get-ObjectPropertyValue -Object $resolvedPolicy -Name "approval" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($approval)) {
        [void]$arguments.Add("-a")
        [void]$arguments.Add($approval)
    }

    $model = [string](Get-ObjectPropertyValue -Object $resolvedPolicy -Name "model" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        [void]$arguments.Add("-m")
        [void]$arguments.Add($model)
    }

    $reasoning = [string](Get-ObjectPropertyValue -Object $resolvedPolicy -Name "reasoning" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($reasoning)) {
        [void]$arguments.Add("-c")
        [void]$arguments.Add(('model_reasoning_effort="{0}"' -f $reasoning))
    }

    $speed = [string](Get-ObjectPropertyValue -Object $resolvedPolicy -Name "speed" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($speed)) {
        [void]$arguments.Add("-c")
        [void]$arguments.Add(('service_tier="{0}"' -f $speed))
    }

    $webSearch = [string](Get-ObjectPropertyValue -Object $resolvedPolicy -Name "web_search" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($webSearch)) {
        [void]$arguments.Add("-c")
        [void]$arguments.Add(('web_search="{0}"' -f $webSearch))
    }

    if (-not [string]::IsNullOrWhiteSpace($Personality)) {
        [void]$arguments.Add("-c")
        [void]$arguments.Add(('personality="{0}"' -f $Personality))
    }

    $permissionProfile = [string](Get-ObjectPropertyValue -Object $resolvedPermissions -Name "permission_profile" -DefaultValue "")
    $sandboxMode = [string](Get-ObjectPropertyValue -Object $resolvedPermissions -Name "sandbox_mode" -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($permissionProfile)) {
        [void]$arguments.Add("-c")
        [void]$arguments.Add(('default_permissions="{0}"' -f $permissionProfile))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($sandboxMode)) {
        [void]$arguments.Add("-s")
        [void]$arguments.Add($sandboxMode)
    }

    [void]$arguments.Add("exec")
    [void]$arguments.Add("--json")
    [void]$arguments.Add("-o")
    [void]$arguments.Add($SummaryPath)
    [void]$arguments.Add("-C")
    [void]$arguments.Add($WorktreePath)
    [void]$arguments.Add("-")

    return [pscustomobject]@{
        arguments = @($arguments.ToArray())
        workingDirectory = Get-CodexRuntimeHostDirectory
        legacySandboxMode = if ([string]::IsNullOrWhiteSpace($sandboxMode)) { $null } else { $sandboxMode }
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

    $gitCommand = [Environment]::GetEnvironmentVariable("STACK_GIT_COMMAND")
    if ([string]::IsNullOrWhiteSpace($gitCommand)) {
        $gitCommand = "git"
    }

    return Invoke-ProcessCapture -FilePath $gitCommand -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment
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

function Get-GitRefSha {
    param(
        [string]$RefName,
        [string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RefName)) {
        return $null
    }

    $result = Invoke-Git -Arguments @("rev-parse", "--verify", "--quiet", $RefName) -WorkingDirectory $WorkingDirectory
    if ($result.ExitCode -ne 0) {
        return $null
    }

    return $result.StdOut.Trim()
}

function New-WorkerGitStateGuard {
    param(
        [string]$WorkingDirectory,
        [string]$TaskRef = "HEAD",
        [string]$LandingRef = ""
    )

    return [pscustomobject][ordered]@{
        failureCode = $null
        taskRef = $TaskRef
        taskInitialHead = Get-GitRefSha -RefName $TaskRef -WorkingDirectory $WorkingDirectory
        taskFinalHead = $null
        landingRef = if ([string]::IsNullOrWhiteSpace($LandingRef)) { $null } else { $LandingRef }
        landingInitialHead = Get-GitRefSha -RefName $LandingRef -WorkingDirectory $WorkingDirectory
        landingFinalHead = $null
        initialBranch = Get-GitCurrentBranch -WorkingDirectory $WorkingDirectory
        finalBranch = $null
        violations = @()
    }
}

function Complete-WorkerGitStateGuard {
    param(
        [Parameter(Mandatory = $true)]
        $InitialState,
        [string]$WorkingDirectory
    )

    $taskFinalHead = Get-GitRefSha -RefName ([string]$InitialState.taskRef) -WorkingDirectory $WorkingDirectory
    $landingFinalHead = Get-GitRefSha -RefName ([string]$InitialState.landingRef) -WorkingDirectory $WorkingDirectory
    $finalBranch = Get-GitCurrentBranch -WorkingDirectory $WorkingDirectory
    $violations = New-Object System.Collections.Generic.List[string]

    if ([string]$InitialState.taskInitialHead -ne [string]$taskFinalHead) {
        [void]$violations.Add("worker_task_head_mutation_detected")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$InitialState.landingRef) -and [string]$InitialState.landingInitialHead -ne [string]$landingFinalHead) {
        [void]$violations.Add("worker_landing_ref_mutation_detected")
    }
    if ([string]$InitialState.initialBranch -ne [string]$finalBranch) {
        [void]$violations.Add("worker_branch_switch_detected")
    }

    return [pscustomobject][ordered]@{
        failureCode = if ($violations.Count -gt 0) { "worker_git_head_mutation_detected" } else { $null }
        taskRef = [string]$InitialState.taskRef
        taskInitialHead = [string]$InitialState.taskInitialHead
        taskFinalHead = [string]$taskFinalHead
        landingRef = if ([string]::IsNullOrWhiteSpace([string]$InitialState.landingRef)) { $null } else { [string]$InitialState.landingRef }
        landingInitialHead = if ([string]::IsNullOrWhiteSpace([string]$InitialState.landingInitialHead)) { $null } else { [string]$InitialState.landingInitialHead }
        landingFinalHead = if ([string]::IsNullOrWhiteSpace([string]$landingFinalHead)) { $null } else { [string]$landingFinalHead }
        initialBranch = [string]$InitialState.initialBranch
        finalBranch = [string]$finalBranch
        violations = @($violations.ToArray())
    }
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
        [object]$WorktreeNameMaxLength = $null,
        [string]$WorkingDirectory
    )

    $candidate = $RootSlug
    $counter = 1
    while ($true) {
        $branchName = "{0}{1}" -f $BranchPrefix, $candidate
        $worktreeDirectoryName = Get-CompactWorktreeDirectoryName -Candidate $candidate -WorktreeNameMaxLength $WorktreeNameMaxLength
        $worktreePath = Join-Path -Path $WorktreeRoot -ChildPath $worktreeDirectoryName
        $branchExists = Test-GitRefExists -RefName ("refs/heads/{0}" -f $branchName) -WorkingDirectory $WorkingDirectory
        if (-not $branchExists -and -not (Test-Path -LiteralPath $worktreePath)) {
            return [pscustomobject]@{
                Slug = $candidate
                BranchName = $branchName
                WorktreeDirectoryName = $worktreeDirectoryName
                WorktreePath = $worktreePath
            }
        }

        $counter += 1
        $candidate = "{0}-{1}" -f $RootSlug, $counter
    }
}

function Get-CompactWorktreeDirectoryName {
    param(
        [string]$Candidate,
        [object]$WorktreeNameMaxLength = $null
    )

    if ($null -eq $WorktreeNameMaxLength -or $Candidate.Length -le [int]$WorktreeNameMaxLength) {
        return $Candidate
    }

    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hashAlgorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Candidate))
    }
    finally {
        $hashAlgorithm.Dispose()
    }

    $hashSuffix = ([System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant()).Substring(0, 8)
    $suffix = "-{0}" -f $hashSuffix
    $prefixLength = [int]$WorktreeNameMaxLength - $suffix.Length
    return "{0}{1}" -f $Candidate.Substring(0, $prefixLength), $suffix
}

function Get-ValidatedWorktreeNameMaxLength {
    param($Execution)

    $configuredValue = Get-ObjectPropertyValue -Object $Execution -Name "worktreeNameMaxLength" -DefaultValue $null
    if ($null -eq $configuredValue) {
        return $null
    }

    $isInteger = (
        $configuredValue -is [System.SByte] -or
        $configuredValue -is [System.Byte] -or
        $configuredValue -is [System.Int16] -or
        $configuredValue -is [System.UInt16] -or
        $configuredValue -is [System.Int32] -or
        $configuredValue -is [System.UInt32] -or
        $configuredValue -is [System.Int64] -or
        $configuredValue -is [System.UInt64]
    )
    if (-not $isInteger -or $configuredValue -lt 12 -or $configuredValue -gt 128) {
        throw "Adapter execution.worktreeNameMaxLength must be an integer from 12 through 128."
    }

    return [int]$configuredValue
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

function Normalize-RepoRelativePathList {
    param([string[]]$Paths)

    $normalized = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $candidate = ([string]$path).Trim().Replace("\", "/")
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $normalized.Contains($candidate)) {
            [void]$normalized.Add($candidate)
        }
    }

    return @($normalized.ToArray())
}

function Get-SpecToDiffPathEvidenceMap {
    param(
        [string]$WorkingDirectory,
        [string[]]$ChangedPaths
    )

    $evidence = @{}
    foreach ($path in (Normalize-RepoRelativePathList -Paths $ChangedPaths)) {
        $diffText = ""
        if (Test-GitPathTracked -Path $path -WorkingDirectory $WorkingDirectory) {
            $diffResult = Invoke-Git -Arguments @("diff", "--relative", "HEAD", "--", $path) -WorkingDirectory $WorkingDirectory
            if ($diffResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($diffResult.StdOut)) {
                $diffText = $diffResult.StdOut
            }
        }

        if ([string]::IsNullOrWhiteSpace($diffText)) {
            $absolutePath = Join-Path -Path $WorkingDirectory -ChildPath $path
            if (Test-Path -LiteralPath $absolutePath) {
                $item = Get-Item -LiteralPath $absolutePath -ErrorAction Stop
                if (-not $item.PSIsContainer) {
                    $diffText = [System.IO.File]::ReadAllText($absolutePath)
                }
            }
        }

        $evidence[$path] = ($diffText -replace "`r`n", "`n")
    }

    return $evidence
}

function Resolve-SpecToDiffRequestedChangedPaths {
    param(
        [string[]]$RequestedPaths,
        [string[]]$ActualChangedPaths
    )

    $actual = @(Normalize-RepoRelativePathList -Paths $ActualChangedPaths)
    $normalized = New-Object System.Collections.Generic.List[string]
    $blockingReasons = New-Object System.Collections.Generic.List[string]
    foreach ($requestedPath in @($RequestedPaths)) {
        if ([string]::IsNullOrWhiteSpace($requestedPath)) {
            [void]$blockingReasons.Add("Requested changed path must not be blank.")
            continue
        }

        $candidate = ([string]$requestedPath).Trim().Replace("\", "/")
        $segments = $candidate -split "/", -1
        $malformed = (
            [System.IO.Path]::IsPathRooted($candidate) -or
            $candidate.StartsWith("/") -or
            $candidate.Contains(":") -or
            $candidate.Contains("*") -or
            $candidate.Contains("?") -or
            @($segments | Where-Object { $_ -eq "" -or $_ -eq "." -or $_ -eq ".." }).Count -gt 0
        )
        if ($malformed) {
            [void]$blockingReasons.Add(("Requested changed path '{0}' is malformed or escapes the repository." -f $requestedPath))
            continue
        }
        if ($normalized.Contains($candidate)) {
            [void]$blockingReasons.Add(("Requested changed path '{0}' was supplied more than once." -f $candidate))
            continue
        }
        [void]$normalized.Add($candidate)
        if ($candidate -notin $actual) {
            [void]$blockingReasons.Add(("Requested changed path '{0}' is not present in the actual changed-path inventory." -f $candidate))
        }
    }

    return [pscustomobject]@{
        isValid = ($blockingReasons.Count -eq 0 -and $normalized.Count -gt 0)
        paths = @($normalized.ToArray())
        blockingReasons = @($blockingReasons.ToArray())
    }
}

function Test-SpecToDiffCompletionProof {
    param(
        $PromptRecord,
        $ArtifactRecord,
        [string[]]$ChangedPaths = @(),
        [string]$WorkingDirectory = "",
        [hashtable]$PathEvidenceMap = $null
    )

    $policy = Get-SpecToDiffPromptPolicy -PromptRecord $PromptRecord
    $normalizedChangedPaths = @(Normalize-RepoRelativePathList -Paths $ChangedPaths)
    $result = [ordered]@{
        enabled = [bool]$policy.enabled
        artifactPath = [string]$policy.artifactPath
        isValid = $true
        blockingReasons = @()
        changedPaths = @($normalizedChangedPaths)
        criteria = @()
        expectedChangedPathMatches = @()
        expectedUnchangedPathViolations = @()
        justifiedExpectedUnchangedPaths = @()
    }

    if (-not $policy.enabled) {
        return [pscustomobject]$result
    }

    if ($null -eq $ArtifactRecord) {
        $result.isValid = $false
        $result.blockingReasons = @("Spec-to-diff completion artifact is required when acceptance criteria are declared.")
        return [pscustomobject]$result
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$ArtifactRecord.parseError)) {
        $result.isValid = $false
        $result.blockingReasons = @("Spec-to-diff completion artifact could not be parsed: $($ArtifactRecord.parseError)")
        return [pscustomobject]$result
    }

    $payload = $ArtifactRecord.payload
    if ($null -eq $payload) {
        $result.isValid = $false
        $result.blockingReasons = @("Spec-to-diff completion artifact payload is missing.")
        return [pscustomobject]$result
    }

    $contractVersion = [string](Get-ObjectPropertyValue -Object $payload -Name "contract_version" -DefaultValue "")
    if ($contractVersion -ne "atlas.stack.spec_to_diff.v1") {
        $result.isValid = $false
        $result.blockingReasons += ("Spec-to-diff completion artifact must declare contract_version=atlas.stack.spec_to_diff.v1. Found '{0}'." -f $contractVersion)
    }

    $artifactCriteria = @(Get-ObjectPropertyValue -Object $payload -Name "criteria" -DefaultValue @())
    if ($artifactCriteria.Count -eq 0) {
        $result.isValid = $false
        $result.blockingReasons += "Spec-to-diff completion artifact must include one criterion entry per acceptance criterion."
    }

    $artifactCriteriaById = @{}
    foreach ($entry in $artifactCriteria) {
        $criterionId = [string](Get-ObjectPropertyValue -Object $entry -Name "criterion_id" -DefaultValue "")
        if ([string]::IsNullOrWhiteSpace($criterionId)) {
            $result.isValid = $false
            $result.blockingReasons += "Each spec-to-diff criterion entry must declare criterion_id."
            continue
        }

        if ($artifactCriteriaById.ContainsKey($criterionId)) {
            $result.isValid = $false
            $result.blockingReasons += ("Spec-to-diff completion artifact includes duplicate criterion_id '{0}'." -f $criterionId)
            continue
        }

        $artifactCriteriaById[$criterionId] = $entry
    }

    $knownCriterionIds = @($policy.acceptanceCriteria | ForEach-Object { [string]$_.id })
    foreach ($artifactCriterionId in $artifactCriteriaById.Keys) {
        if ($artifactCriterionId -notin $knownCriterionIds) {
            $result.isValid = $false
            $result.blockingReasons += ("Spec-to-diff completion artifact reported unknown criterion_id '{0}'." -f $artifactCriterionId)
        }
    }

    $evidenceMap = if ($null -ne $PathEvidenceMap) {
        $PathEvidenceMap
    }
    elseif (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        Get-SpecToDiffPathEvidenceMap -WorkingDirectory $WorkingDirectory -ChangedPaths $normalizedChangedPaths
    }
    else {
        @{}
    }

    foreach ($criterion in @($policy.acceptanceCriteria)) {
        $criterionId = [string]$criterion.id
        $entry = if ($artifactCriteriaById.ContainsKey($criterionId)) { $artifactCriteriaById[$criterionId] } else { $null }
        if ($null -eq $entry) {
            $result.isValid = $false
            $result.blockingReasons += ("Acceptance criterion '{0}' is missing from the completion artifact." -f $criterionId)
            continue
        }

        $status = [string](Get-ObjectPropertyValue -Object $entry -Name "status" -DefaultValue "")
        $status = $status.Trim().ToLowerInvariant()
        $entryChangedPaths = @(Normalize-RepoRelativePathList -Paths (ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $entry -Name "changed_paths" -DefaultValue @())))
        $diffEvidence = @(ConvertTo-StringArray -Value (Get-ObjectPropertyValue -Object $entry -Name "diff_evidence" -DefaultValue @()))
        $note = [string](Get-ObjectPropertyValue -Object $entry -Name "note" -DefaultValue "")

        $criterionRecord = [ordered]@{
            criterion_id = $criterionId
            criterion_text = [string]$criterion.text
            status = $status
            changed_paths = @($entryChangedPaths)
            diff_evidence = @($diffEvidence)
            note = $note
            proven = $false
        }

        if ($status -notin @("satisfied", "skipped", "failed", "blocked")) {
            $result.isValid = $false
            $result.blockingReasons += ("Criterion '{0}' reported invalid status '{1}'." -f $criterionId, $status)
            $result.criteria += [pscustomobject]$criterionRecord
            continue
        }

        if ($status -ne "satisfied") {
            if ([string]::IsNullOrWhiteSpace($note)) {
                $result.blockingReasons += ("Criterion '{0}' is {1} but does not include an explanatory note." -f $criterionId, $status)
            }
            else {
                $result.blockingReasons += ("Criterion '{0}' is {1}: {2}" -f $criterionId, $status, $note.Trim())
            }
            $result.isValid = $false
            $result.criteria += [pscustomobject]$criterionRecord
            continue
        }

        if ($entryChangedPaths.Count -eq 0) {
            $result.isValid = $false
            $result.blockingReasons += ("Criterion '{0}' is marked satisfied but does not list supporting changed_paths." -f $criterionId)
        }

        foreach ($path in $entryChangedPaths) {
            if ($path -notin $normalizedChangedPaths) {
                $result.isValid = $false
                $result.blockingReasons += ("Criterion '{0}' cites changed path '{1}' that is not present in the final diff." -f $criterionId, $path)
            }
        }

        if ($diffEvidence.Count -eq 0) {
            $result.isValid = $false
            $result.blockingReasons += ("Criterion '{0}' is marked satisfied but does not include diff_evidence." -f $criterionId)
        }

        $criterionProven = $true
        foreach ($evidence in $diffEvidence) {
            if ([string]::IsNullOrWhiteSpace($evidence)) {
                $criterionProven = $false
                $result.isValid = $false
                $result.blockingReasons += ("Criterion '{0}' includes blank diff_evidence." -f $criterionId)
                continue
            }

            $evidenceFound = $false
            foreach ($path in $entryChangedPaths) {
                $proofText = [string](Get-ObjectPropertyValue -Object $evidenceMap -Name $path -DefaultValue $null)
                if ([string]::IsNullOrWhiteSpace($proofText) -and $evidenceMap.ContainsKey($path)) {
                    $proofText = [string]$evidenceMap[$path]
                }
                if (-not [string]::IsNullOrWhiteSpace($proofText) -and $proofText.Contains([string]$evidence)) {
                    $evidenceFound = $true
                    break
                }
            }

            if (-not $evidenceFound) {
                $criterionProven = $false
                $result.isValid = $false
                $result.blockingReasons += ("Criterion '{0}' evidence '{1}' was not found in the final diff or file content for its declared paths." -f $criterionId, $evidence)
            }
        }

        if ($criterionProven -and $entryChangedPaths.Count -gt 0 -and $diffEvidence.Count -gt 0) {
            $criterionRecord.proven = $true
        }
        else {
            $criterionRecord.proven = $false
        }

        $result.criteria += [pscustomobject]$criterionRecord
    }

    foreach ($pattern in @($policy.expectedChangedPaths)) {
        $matchedPaths = @(
            $normalizedChangedPaths |
            Where-Object { Test-PathMatchesAllowedSurface -Path $_ -AllowedPatterns @([string]$pattern) }
        )
        $result.expectedChangedPathMatches += [pscustomobject]@{
            pattern = [string]$pattern
            matched_paths = @($matchedPaths)
        }
        if ($matchedPaths.Count -eq 0) {
            $result.isValid = $false
            $result.blockingReasons += ("Expected changed path pattern '{0}' was not present in the final diff." -f $pattern)
        }
    }

    $justifications = @(Get-ObjectPropertyValue -Object $payload -Name "unchanged_path_justifications" -DefaultValue @())
    foreach ($pattern in @($policy.expectedUnchangedPaths)) {
        $violatingPaths = @(
            $normalizedChangedPaths |
            Where-Object { Test-PathMatchesAllowedSurface -Path $_ -AllowedPatterns @([string]$pattern) }
        )
        if ($violatingPaths.Count -eq 0) {
            continue
        }

        foreach ($violatingPath in $violatingPaths) {
            $matchingJustificationCandidates = @(
                $justifications |
                Where-Object {
                    $justificationPath = [string](Get-ObjectPropertyValue -Object $_ -Name "path" -DefaultValue "")
                    Test-PathMatchesAllowedSurface -Path $violatingPath -AllowedPatterns @($justificationPath)
                } |
                Select-Object -First 1
            )
            $matchingJustification = if ($matchingJustificationCandidates.Count -gt 0) {
                $matchingJustificationCandidates[0]
            }
            else {
                $null
            }
            $justificationText = if ($null -ne $matchingJustification) {
                [string](Get-ObjectPropertyValue -Object $matchingJustification -Name "justification" -DefaultValue "")
            }
            else {
                ""
            }

            if ([string]::IsNullOrWhiteSpace($justificationText)) {
                $result.isValid = $false
                $result.blockingReasons += ("Expected unchanged path '{0}' changed without explicit justification." -f $violatingPath)
                $result.expectedUnchangedPathViolations += [pscustomobject]@{
                    path = $violatingPath
                    pattern = [string]$pattern
                    justification = $null
                }
                continue
            }

            $result.justifiedExpectedUnchangedPaths += [pscustomobject]@{
                path = $violatingPath
                pattern = [string]$pattern
                justification = $justificationText.Trim()
            }
        }
    }

    return [pscustomobject]$result
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
        "success_no_changes" { return 0 }
        "verification_failed" { return 11 }
        "codex_failed" { return 12 }
        "commit_failed" { return 13 }
        "no_changes" { return 14 }
        "archive_failed" { return 15 }
        "mutation_scope_failed" { return 16 }
        "spec_to_diff_failed" { return 17 }
        "worker_git_state_failed" { return 18 }
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
