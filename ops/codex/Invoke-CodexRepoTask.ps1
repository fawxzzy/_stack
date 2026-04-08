param(
    [Parameter(Mandatory = $true)]
    [string]$PromptPath,
    [string]$ConfigPath = "",
    [string]$RepoRoot = "",
    [string]$AdapterPath = "",
    [string]$CodexCommand = "",
    [string]$SandboxMode = "",
    [switch]$KeepWorktree,
    [switch]$SkipVerification,
    [switch]$NoCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")

$status = "setup_failed"
$archivePath = $null
$manifestPath = $null
$logDirectory = $null
$runId = $null
$branchName = $null
$worktreePath = $null
$commitSha = $null
$exportErrors = @()
$verifyRecords = @()
$promptRecord = $null
$config = @{}
$baseRef = "origin/main"
$codexStdOutPath = $null
$codexStdErrPath = $null
$summaryPath = $null
$archiveDirectory = $null
$effectiveVerifyCommands = @()
$verificationSource = "prompt"
$effectiveSandboxMode = $null
$changedPaths = @()
$mutationScopeViolations = @()
$verifyBootstrapRecords = @()
$adapterContract = $null
$adapterContractPath = $null
$autoCommitEnabled = $true
$pushPolicy = $null
$autoCommitPolicy = $null
$exportsDirectory = $null
$repoRoot = $null
$resolvedConfig = $null

try {
    $PromptPath = (Resolve-Path -LiteralPath $PromptPath).Path
    $resolvedConfig = Import-StackCodexConfiguration -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath -RepoRoot $RepoRoot -AdapterPath $AdapterPath
    $config = $resolvedConfig.Config
    $repoRoot = $resolvedConfig.RepoRoot
    $adapterContractPath = $resolvedConfig.AdapterPath
    $adapterContract = Read-JsonFile -Path $adapterContractPath

    if ($null -eq $adapterContract) {
        throw ("Adapter contract is empty or unreadable: {0}" -f $adapterContractPath)
    }

    $baseRef = [string]$adapterContract.execution.baseRef
    if ([string]::IsNullOrWhiteSpace($baseRef)) {
        $baseRef = "origin/main"
    }

    $branchPrefix = [string]$adapterContract.execution.branchPrefix
    if ([string]::IsNullOrWhiteSpace($branchPrefix)) {
        $branchPrefix = "codex/"
    }

    $fetchOrigin = ConvertTo-RunnerBoolean -Value $adapterContract.execution.fetchOrigin -DefaultValue $false
    $cleanupWorktreeOnSuccess = -not $KeepWorktree.IsPresent -and (ConvertTo-RunnerBoolean -Value $adapterContract.execution.cleanupWorktreeOnSuccess -DefaultValue $false)

    $autoCommitPolicy = if ($null -ne $adapterContract.autoCommitPolicy) { $adapterContract.autoCommitPolicy } else { [pscustomobject]@{} }
    $pushPolicy = if ($null -ne $adapterContract.pushPolicy) { $adapterContract.pushPolicy } else { [pscustomobject]@{} }
    $autoCommitEnabled = -not $NoCommit.IsPresent -and (ConvertTo-RunnerBoolean -Value $autoCommitPolicy.enabled -DefaultValue $true)

    $inboxDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.inboxDir)
    $archiveDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.archiveDir)
    $logsDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.logsDir)
    $worktreeRoot = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.worktreeRoot)
    $exportsDirectory = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.exportsDir)

    foreach ($directory in @($inboxDirectory, $archiveDirectory, $logsDirectory, $worktreeRoot, $exportsDirectory)) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            throw "Adapter contract is missing one or more artifact paths."
        }

        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    $promptRecord = Parse-PromptFile -Path $PromptPath
    $effectiveVerifyCommands = @($promptRecord.Verify)
    if ($effectiveVerifyCommands.Count -eq 0 -and $null -ne $adapterContract.verify) {
        $effectiveVerifyCommands = ConvertTo-StringArray -Value $adapterContract.verify.defaultCommands
        if ($effectiveVerifyCommands.Count -gt 0) {
            $verificationSource = "adapter-default"
        }
    }

    $slugSeed = $promptRecord.BranchSlug
    if ([string]::IsNullOrWhiteSpace($slugSeed)) {
        $slugSeed = $promptRecord.Title
    }
    if ([string]::IsNullOrWhiteSpace($slugSeed)) {
        $slugSeed = [System.IO.Path]::GetFileNameWithoutExtension($PromptPath)
    }

    $rootSlug = ConvertTo-Slug -Value $slugSeed
    $taskName = Get-UniqueTaskName -RootSlug $rootSlug -BranchPrefix $branchPrefix -WorktreeRoot $worktreeRoot -WorkingDirectory $repoRoot
    $branchName = $taskName.BranchName
    $worktreePath = $taskName.WorktreePath
    $runId = "{0}-{1}" -f ((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")), $taskName.Slug
    $logDirectory = Join-Path -Path $logsDirectory -ChildPath $runId
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $manifestPath = Join-Path -Path $logDirectory -ChildPath "run.json"

    Write-RunnerMessage -Message ("Preparing task {0} from {1}" -f $taskName.Slug, $PromptPath)
    Copy-Item -LiteralPath $PromptPath -Destination (Join-Path -Path $logDirectory -ChildPath "input.prompt.md")

    if ([string]::IsNullOrWhiteSpace($promptRecord.Body)) {
        throw "Prompt body is empty."
    }

    $codexCommandValue = $CodexCommand
    if ([string]::IsNullOrWhiteSpace($codexCommandValue)) {
        $codexCommandValue = [string](Get-ConfigValue -Config $config -Path @("windows", "codex_command") -DefaultValue "codex")
    }
    $codexCommandValue = Expand-ConfigString -Value $codexCommandValue
    if (-not (Test-Path -LiteralPath $codexCommandValue)) {
        throw ("Codex command was not found: {0}" -f $codexCommandValue)
    }

    if ($fetchOrigin) {
        Write-RunnerMessage -Message ("Fetching {0} before worktree creation" -f $baseRef)
        $fetchArguments = @("fetch", "--quiet")
        if ($baseRef -match '^origin/(?<branch>.+)$') {
            $fetchArguments += @("origin", $Matches.branch)
        }
        else {
            $fetchArguments += @("origin")
        }

        $fetchResult = Invoke-Git -Arguments $fetchArguments -WorkingDirectory $repoRoot
        Assert-CommandSucceeded -Result $fetchResult -Description ("git {0}" -f ($fetchArguments -join " "))
    }

    if (-not (Test-GitRefExists -RefName $baseRef -WorkingDirectory $repoRoot)) {
        throw ("Base ref does not exist locally: {0}" -f $baseRef)
    }

    Write-RunnerMessage -Message ("Creating worktree {0} on branch {1} from {2}" -f $worktreePath, $branchName, $baseRef)
    $worktreeResult = Invoke-Git -Arguments @("worktree", "add", "-b", $branchName, $worktreePath, $baseRef) -WorkingDirectory $repoRoot
    Assert-CommandSucceeded -Result $worktreeResult -Description "git worktree add"

    $summaryPath = Join-Path -Path $logDirectory -ChildPath "final-summary.md"
    $codexStdOutPath = Join-Path -Path $logDirectory -ChildPath "codex.stdout.log"
    $codexStdErrPath = Join-Path -Path $logDirectory -ChildPath "codex.stderr.log"
    $effectivePrompt = $promptRecord.Body.Trim()
    if (-not [string]::IsNullOrWhiteSpace($promptRecord.DocsUpdateNote)) {
        $effectivePrompt = $effectivePrompt + "`r`n`r`nDocs update note: " + $promptRecord.DocsUpdateNote.Trim()
    }
    Write-TextFile -Path (Join-Path -Path $logDirectory -ChildPath "effective.prompt.md") -Content $effectivePrompt

    $codexArgs = New-Object System.Collections.Generic.List[string]
    $approvalPolicy = [string](Get-ConfigValue -Config $config -Path @("windows", "approval_policy") -DefaultValue "never")
    if (-not [string]::IsNullOrWhiteSpace($approvalPolicy)) {
        [void]$codexArgs.Add("-a")
        [void]$codexArgs.Add($approvalPolicy)
    }

    $model = [string](Get-ConfigValue -Config $config -Path @("model") -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($model)) {
        [void]$codexArgs.Add("-m")
        [void]$codexArgs.Add($model)
    }

    $reasoningEffort = [string](Get-ConfigValue -Config $config -Path @("model_reasoning_effort") -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($reasoningEffort)) {
        [void]$codexArgs.Add("-c")
        [void]$codexArgs.Add(('model_reasoning_effort="{0}"' -f $reasoningEffort))
    }

    $personality = [string](Get-ConfigValue -Config $config -Path @("personality") -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($personality)) {
        [void]$codexArgs.Add("-c")
        [void]$codexArgs.Add(('personality="{0}"' -f $personality))
    }

    [void]$codexArgs.Add("exec")
    [void]$codexArgs.Add("--json")
    [void]$codexArgs.Add("-o")
    [void]$codexArgs.Add($summaryPath)
    [void]$codexArgs.Add("-C")
    [void]$codexArgs.Add($worktreePath)

    $effectiveSandboxMode = $SandboxMode
    if ([string]::IsNullOrWhiteSpace($effectiveSandboxMode)) {
        $effectiveSandboxMode = [string]$adapterContract.execution.defaultSandbox
    }
    if ([string]::IsNullOrWhiteSpace($effectiveSandboxMode)) {
        $effectiveSandboxMode = [string](Get-ConfigValue -Config $config -Path @("windows", "sandbox") -DefaultValue "workspace-write")
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveSandboxMode)) {
        [void]$codexArgs.Add("-s")
        [void]$codexArgs.Add($effectiveSandboxMode)
    }

    [void]$codexArgs.Add("-")

    Write-RunnerMessage -Message "Running Codex in non-interactive mode"
    $codexResult = Invoke-ProcessCapture -FilePath $codexCommandValue -ArgumentList @($codexArgs.ToArray()) -WorkingDirectory $repoRoot -StandardInputText $effectivePrompt
    Write-TextFile -Path $codexStdOutPath -Content $codexResult.StdOut
    Write-TextFile -Path $codexStdErrPath -Content $codexResult.StdErr

    if ($codexResult.ExitCode -ne 0) {
        $status = "codex_failed"
        throw ("Codex exec failed with exit code {0}." -f $codexResult.ExitCode)
    }

    $verificationDirectory = Join-Path -Path $logDirectory -ChildPath "verification"
    New-Item -ItemType Directory -Path $verificationDirectory -Force | Out-Null
    if (-not $SkipVerification.IsPresent) {
        $bootstrapIndex = 0
        if ($null -ne $adapterContract.verify) {
            foreach ($bootstrapCommand in (ConvertTo-StringArray -Value $adapterContract.verify.bootstrapCommands)) {
                $bootstrapIndex += 1
                Write-RunnerMessage -Message ("Running verification bootstrap {0}: {1}" -f $bootstrapIndex, $bootstrapCommand)
                $bootstrapResult = Invoke-ShellCommand -Command $bootstrapCommand -WorkingDirectory $worktreePath
                $bootstrapStdOutPath = Join-Path -Path $verificationDirectory -ChildPath ("bootstrap-{0:00}.stdout.log" -f $bootstrapIndex)
                $bootstrapStdErrPath = Join-Path -Path $verificationDirectory -ChildPath ("bootstrap-{0:00}.stderr.log" -f $bootstrapIndex)
                Write-TextFile -Path $bootstrapStdOutPath -Content $bootstrapResult.StdOut
                Write-TextFile -Path $bootstrapStdErrPath -Content $bootstrapResult.StdErr

                $bootstrapRecord = [ordered]@{
                    command = $bootstrapCommand
                    exitCode = $bootstrapResult.ExitCode
                    stdoutPath = $bootstrapStdOutPath
                    stderrPath = $bootstrapStdErrPath
                }
                $verifyBootstrapRecords += [pscustomobject]$bootstrapRecord

                if ($bootstrapResult.ExitCode -ne 0) {
                    $status = "verification_failed"
                    throw ("Verification bootstrap failed: {0}" -f $bootstrapCommand)
                }
            }
        }

        $verifyIndex = 0
        foreach ($verificationCommand in $effectiveVerifyCommands) {
            $verifyIndex += 1
            Write-RunnerMessage -Message ("Running verification command {0}: {1}" -f $verifyIndex, $verificationCommand)
            $verificationResult = Invoke-ShellCommand -Command $verificationCommand -WorkingDirectory $worktreePath
            $verifyStdOutPath = Join-Path -Path $verificationDirectory -ChildPath ("verify-{0:00}.stdout.log" -f $verifyIndex)
            $verifyStdErrPath = Join-Path -Path $verificationDirectory -ChildPath ("verify-{0:00}.stderr.log" -f $verifyIndex)
            Write-TextFile -Path $verifyStdOutPath -Content $verificationResult.StdOut
            Write-TextFile -Path $verifyStdErrPath -Content $verificationResult.StdErr

            $record = [ordered]@{
                command = $verificationCommand
                exitCode = $verificationResult.ExitCode
                stdoutPath = $verifyStdOutPath
                stderrPath = $verifyStdErrPath
            }
            $verifyRecords += [pscustomobject]$record

            if ($verificationResult.ExitCode -ne 0) {
                $status = "verification_failed"
                throw ("Verification command failed: {0}" -f $verificationCommand)
            }
        }
    }

    $statusResult = Invoke-Git -Arguments @("status", "--porcelain") -WorkingDirectory $worktreePath
    Assert-CommandSucceeded -Result $statusResult -Description "git status --porcelain"
    if ([string]::IsNullOrWhiteSpace($statusResult.StdOut)) {
        $status = "no_changes"
        throw "Codex completed without producing repository changes."
    }

    $changedPaths = @(Get-ChangedPaths -WorkingDirectory $worktreePath)
    $allowedMutationSurfaces = ConvertTo-StringArray -Value $adapterContract.allowedMutationSurfaces
    if ($allowedMutationSurfaces.Count -gt 0) {
        $mutationScopeViolations = @(
            $changedPaths |
            Where-Object { -not (Test-PathMatchesAllowedSurface -Path $_ -AllowedPatterns $allowedMutationSurfaces) }
        )
        if ($mutationScopeViolations.Count -gt 0) {
            $status = "mutation_scope_failed"
            throw ("Changed files exceeded repo adapter mutation scope: {0}" -f ($mutationScopeViolations -join ", "))
        }
    }

    if ($autoCommitEnabled) {
        Write-RunnerMessage -Message "Staging and committing task changes"
        $addResult = Invoke-Git -Arguments @("add", "-A") -WorkingDirectory $worktreePath
        Assert-CommandSucceeded -Result $addResult -Description "git add -A"

        $commitMessage = $promptRecord.CommitMessage
        if ([string]::IsNullOrWhiteSpace($commitMessage)) {
            $commitMessage = "chore: codex inbox task {0}" -f $taskName.Slug
        }

        $gitEnvironment = @{}
        $authorName = [string](Get-ConfigValue -Config $config -Path @("git", "author_name") -DefaultValue "")
        $authorEmail = [string](Get-ConfigValue -Config $config -Path @("git", "author_email") -DefaultValue "")
        if (-not [string]::IsNullOrWhiteSpace($authorName)) {
            $gitEnvironment["GIT_AUTHOR_NAME"] = $authorName
            $gitEnvironment["GIT_COMMITTER_NAME"] = $authorName
        }
        if (-not [string]::IsNullOrWhiteSpace($authorEmail)) {
            $gitEnvironment["GIT_AUTHOR_EMAIL"] = $authorEmail
            $gitEnvironment["GIT_COMMITTER_EMAIL"] = $authorEmail
        }

        $commitResult = Invoke-Git -Arguments @("commit", "-m", $commitMessage) -WorkingDirectory $worktreePath -Environment $gitEnvironment
        if ($commitResult.ExitCode -ne 0) {
            $status = "commit_failed"
            throw ("git commit failed. {0}" -f $commitResult.StdErr.Trim())
        }

        $shaResult = Invoke-Git -Arguments @("rev-parse", "HEAD") -WorkingDirectory $worktreePath
        Assert-CommandSucceeded -Result $shaResult -Description "git rev-parse HEAD"
        $commitSha = $shaResult.StdOut.Trim()
    }

    $exportPatch = ConvertTo-RunnerBoolean -Value (Get-ConfigValue -Config $config -Path @("exports", "patch") -DefaultValue $true) -DefaultValue $true
    $exportBundle = ConvertTo-RunnerBoolean -Value (Get-ConfigValue -Config $config -Path @("exports", "bundle") -DefaultValue $false)
    if ($null -ne $adapterContract.exports) {
        $exportPatch = ConvertTo-RunnerBoolean -Value $adapterContract.exports.patch -DefaultValue $exportPatch
        $exportBundle = ConvertTo-RunnerBoolean -Value $adapterContract.exports.bundle -DefaultValue $exportBundle
    }
    if ($null -ne $promptRecord.ExportPatch) {
        $exportPatch = ConvertTo-RunnerBoolean -Value $promptRecord.ExportPatch -DefaultValue $exportPatch
    }
    if ($null -ne $promptRecord.ExportBundle) {
        $exportBundle = ConvertTo-RunnerBoolean -Value $promptRecord.ExportBundle -DefaultValue $exportBundle
    }

    if ($commitSha) {
        $formatPatchBaseRef = [string]$adapterContract.exports.formatPatchBaseRef
        if ([string]::IsNullOrWhiteSpace($formatPatchBaseRef)) {
            $formatPatchBaseRef = $baseRef
        }

        if ($exportPatch) {
            $patchPath = Join-Path -Path $exportsDirectory -ChildPath ("{0}.patch" -f $runId)
            $patchResult = Invoke-Git -Arguments @("format-patch", "--stdout", ("{0}..HEAD" -f $formatPatchBaseRef)) -WorkingDirectory $worktreePath
            if ($patchResult.ExitCode -eq 0) {
                Write-TextFile -Path $patchPath -Content $patchResult.StdOut
            }
            else {
                $exportErrors += ("Patch export failed: {0}" -f $patchResult.StdErr.Trim())
            }
        }

        if ($exportBundle) {
            $bundlePath = Join-Path -Path $exportsDirectory -ChildPath ("{0}.bundle" -f $runId)
            $bundleResult = Invoke-Git -Arguments @("bundle", "create", $bundlePath, "HEAD", ("^{0}" -f $baseRef)) -WorkingDirectory $worktreePath
            if ($bundleResult.ExitCode -ne 0) {
                $exportErrors += ("Bundle export failed: {0}" -f $bundleResult.StdErr.Trim())
            }
        }
    }

    $status = "success"

    if ($cleanupWorktreeOnSuccess) {
        Write-RunnerMessage -Message ("Removing successful worktree {0}" -f $worktreePath)
        $removeResult = Invoke-Git -Arguments @("worktree", "remove", $worktreePath) -WorkingDirectory $repoRoot
        Assert-CommandSucceeded -Result $removeResult -Description "git worktree remove"
        $worktreePath = $null
    }
}
catch {
    Write-RunnerMessage -Message $_.Exception.Message -Level "ERROR"
}
finally {
    if ($null -ne $promptRecord) {
        try {
            $archiveSlug = ConvertTo-Slug -Value ([System.IO.Path]::GetFileNameWithoutExtension($PromptPath))
            $archivePath = New-ArchivePath -ArchiveDirectory $archiveDirectory -Slug $archiveSlug -Status $status -Extension ([System.IO.Path]::GetExtension($PromptPath))
            Move-Item -LiteralPath $PromptPath -Destination $archivePath -Force
        }
        catch {
            Write-RunnerMessage -Message ("Failed to archive prompt: {0}" -f $_.Exception.Message) -Level "ERROR"
            if ($status -eq "success") {
                $status = "archive_failed"
            }
        }
    }

    if ($null -ne $logDirectory) {
        $manifest = [ordered]@{
            runId = $runId
            status = $status
            repoRoot = $repoRoot
            configPath = if ($null -ne $resolvedConfig) { $resolvedConfig.ConfigPath } else { $null }
            defaultsPath = if ($null -ne $resolvedConfig) { $resolvedConfig.DefaultsPath } else { $null }
            promptPath = $PromptPath
            archivePath = $archivePath
            branchName = $branchName
            baseRef = $baseRef
            worktreePath = $worktreePath
            commitSha = $commitSha
            sandboxMode = $effectiveSandboxMode
            logs = [ordered]@{
                directory = $logDirectory
                manifest = $manifestPath
                codexStdOut = $codexStdOutPath
                codexStdErr = $codexStdErrPath
                finalSummary = $summaryPath
            }
            verification = @($verifyRecords)
            verificationBootstrap = @($verifyBootstrapRecords)
            verificationSource = $verificationSource
            changedPaths = @($changedPaths)
            mutationScopeViolations = @($mutationScopeViolations)
            exportErrors = @($exportErrors)
            docsUpdateNote = if ($null -ne $promptRecord) { $promptRecord.DocsUpdateNote } else { $null }
            repoAdapter = [ordered]@{
                path = $adapterContractPath
                kind = $adapterContract.kind
                schemaVersion = $adapterContract.schemaVersion
                repoId = $adapterContract.repoId
                description = $adapterContract.description
                allowedMutationSurfaces = @(ConvertTo-StringArray -Value $adapterContract.allowedMutationSurfaces)
                docsUpdateRules = @(ConvertTo-StringArray -Value $adapterContract.docsUpdateRules)
                bootstrapVerifyCommands = if ($null -ne $adapterContract.verify) { @(ConvertTo-StringArray -Value $adapterContract.verify.bootstrapCommands) } else { @() }
                defaultVerifyCommands = if ($null -ne $adapterContract.verify) { @(ConvertTo-StringArray -Value $adapterContract.verify.defaultCommands) } else { @() }
                artifacts = $adapterContract.artifacts
                pushPolicy = $pushPolicy
                autoCommitPolicy = $autoCommitPolicy
                exports = $adapterContract.exports
                execution = $adapterContract.execution
            }
            effectivePolicies = [ordered]@{
                autoCommitEnabled = $autoCommitEnabled
                pushMode = if ($null -ne $pushPolicy) { $pushPolicy.mode } else { $null }
                skipPush = if ($null -ne $pushPolicy) { $pushPolicy.skipPush } else { $null }
            }
        }

        Write-TextFile -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 8) + "`r`n")
    }
}

exit (Get-StatusExitCode -Status $status)
