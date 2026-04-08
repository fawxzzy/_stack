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

    $lines = Get-Content -LiteralPath $Path
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

    if ([string]::IsNullOrWhiteSpace($metadata.Title)) {
        $firstContentLine = $lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if ($null -ne $firstContentLine -and $firstContentLine -match '^#\s+(?<title>.+)$') {
            $metadata.Title = $Matches.title.Trim()
        }
    }

    $title = if ($metadata.ContainsKey("Title")) { $metadata["Title"] } else { $null }
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
