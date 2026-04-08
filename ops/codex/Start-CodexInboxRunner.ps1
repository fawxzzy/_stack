param(
    [string]$ConfigPath = "",
    [string]$RepoRoot = "",
    [string]$AdapterPath = "",
    [string]$InboxDir = "",
    [int]$PollIntervalSeconds = 0,
    [int]$SettleSeconds = -1,
    [string]$CodexCommand = "",
    [string]$SandboxMode = "",
    [switch]$RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")

$resolvedConfig = Import-StackCodexConfiguration -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath -RepoRoot $RepoRoot -AdapterPath $AdapterPath
$config = $resolvedConfig.Config
$repoRoot = $resolvedConfig.RepoRoot
$resolvedAdapterPath = $resolvedConfig.AdapterPath
$adapterContract = Read-JsonFile -Path $resolvedAdapterPath

if ($null -eq $adapterContract) {
    throw ("Adapter contract is empty or unreadable: {0}" -f $resolvedAdapterPath)
}

if ([string]::IsNullOrWhiteSpace($InboxDir)) {
    $InboxDir = Resolve-RepoPath -Root $repoRoot -Value ([string]$adapterContract.artifacts.inboxDir)
}
if ([string]::IsNullOrWhiteSpace($InboxDir)) {
    throw "Adapter contract must declare artifacts.inboxDir."
}
if ($PollIntervalSeconds -le 0) {
    $PollIntervalSeconds = [int](Get-ConfigValue -Config $config -Path @("runner", "poll_interval_seconds") -DefaultValue 5)
}
if ($SettleSeconds -lt 0) {
    $SettleSeconds = [int](Get-ConfigValue -Config $config -Path @("runner", "settle_seconds") -DefaultValue 2)
}

if (-not (Test-Path -LiteralPath $InboxDir)) {
    New-Item -ItemType Directory -Path $InboxDir -Force | Out-Null
}

$taskScript = Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexRepoTask.ps1"
$powershellExe = Join-Path -Path $PSHOME -ChildPath "powershell.exe"
if (-not (Test-Path -LiteralPath $powershellExe)) {
    $powershellExe = "powershell.exe"
}

$sawFailure = $false

do {
    $pending = @(Get-PendingPromptFiles -Directory $InboxDir)
    if ($pending.Count -eq 0) {
        if ($RunOnce.IsPresent) {
            break
        }

        Write-RunnerMessage -Message ("No prompts pending in {0}; sleeping for {1}s" -f $InboxDir, $PollIntervalSeconds)
        Start-Sleep -Seconds $PollIntervalSeconds
        continue
    }

    foreach ($prompt in $pending) {
        if (-not (Test-FileSettled -Path $prompt.FullName -Seconds $SettleSeconds)) {
            Write-RunnerMessage -Message ("Skipping unsettled prompt {0}" -f $prompt.Name)
            continue
        }

        Write-RunnerMessage -Message ("Dispatching prompt {0}" -f $prompt.Name)
        $taskArguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $taskScript,
            "-PromptPath", $prompt.FullName,
            "-RepoRoot", $repoRoot,
            "-AdapterPath", $resolvedAdapterPath
        )
        if (-not [string]::IsNullOrWhiteSpace($resolvedConfig.ConfigPath)) {
            $taskArguments += @("-ConfigPath", $resolvedConfig.ConfigPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($CodexCommand)) {
            $taskArguments += @("-CodexCommand", $CodexCommand)
        }
        if (-not [string]::IsNullOrWhiteSpace($SandboxMode)) {
            $taskArguments += @("-SandboxMode", $SandboxMode)
        }

        & $powershellExe @taskArguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $sawFailure = $true
            Write-RunnerMessage -Message ("Prompt {0} failed with exit code {1}" -f $prompt.Name, $exitCode) -Level "ERROR"
        }
        else {
            Write-RunnerMessage -Message ("Prompt {0} completed successfully" -f $prompt.Name)
        }
    }

    if (-not $RunOnce.IsPresent) {
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
while (-not $RunOnce.IsPresent)

if ($sawFailure) {
    exit 1
}

exit 0
