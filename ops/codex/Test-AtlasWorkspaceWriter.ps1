Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1")

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [hashtable]$Environment = @{}
    )

    $result = Invoke-Git -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment
    if ($result.ExitCode -ne 0) {
        $errorText = if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { $result.StdErr.Trim() } else { $result.StdOut.Trim() }
        throw ("git {0} failed in {1}: {2}" -f ($Arguments -join " "), $WorkingDirectory, $errorText)
    }

    return $result
}

function New-TempFixtureRoot {
    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("atlas-workspace-writer-{0}" -f ([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function New-GitWrapperTooling {
    param([string]$ToolRoot)

    $realGit = (Get-Command git -ErrorAction Stop).Source
    $logPath = Join-Path -Path $ToolRoot -ChildPath "git-commands.jsonl"
    $wrapperJsPath = Join-Path -Path $ToolRoot -ChildPath "git-wrapper.mjs"
    $wrapperCmdPath = Join-Path -Path $ToolRoot -ChildPath "git.cmd"

    $wrapperJs = @'
import fs from "node:fs";
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
const logPath = process.env.GIT_WRAPPER_LOG_PATH;
const realGit = process.env.REAL_GIT;

if (!realGit) {
  process.stderr.write("REAL_GIT is required.\n");
  process.exit(92);
}

if (logPath) {
  fs.appendFileSync(logPath, `${JSON.stringify({ args })}\n`, "utf8");
}

if (args[0] === "push" || args[0] === "worktree") {
  process.stderr.write(`Forbidden git subcommand in canonical workspace fixture: ${args[0]}\n`);
  process.exit(91);
}

const result = spawnSync(realGit, args, { encoding: "utf8" });
if (typeof result.stdout === "string" && result.stdout.length > 0) {
  process.stdout.write(result.stdout);
}
if (typeof result.stderr === "string" && result.stderr.length > 0) {
  process.stderr.write(result.stderr);
}
process.exit(result.status ?? 1);
'@
    [System.IO.File]::WriteAllText($wrapperJsPath, $wrapperJs.TrimStart("`r", "`n") + "`r`n")
    [System.IO.File]::WriteAllText($wrapperCmdPath, "@echo off`r`nnode ""%~dp0git-wrapper.mjs"" %*`r`n")

    return [pscustomobject]@{
        PathEntry = $ToolRoot
        LogPath = $logPath
        RealGit = $realGit
    }
}

function New-FakeCodexTooling {
    param([string]$ToolRoot)

    $fakeCodexJsPath = Join-Path -Path $ToolRoot -ChildPath "fake-codex.mjs"
    $fakeCodexCmdPath = Join-Path -Path $ToolRoot -ChildPath "fake-codex.cmd"
    $fakeCodexJs = @'
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);

if (args[0] === "--version") {
  process.stdout.write("codex-cli 0.142.5-canonical-fixture\n");
  process.exit(0);
}

if (args[0] === "debug" && args[1] === "models") {
  process.stdout.write(JSON.stringify({
    models: [
      { slug: "gpt-5.4", additional_speed_tiers: ["fast"] },
      { slug: "gpt-5.4-mini", additional_speed_tiers: [] }
    ]
  }));
  process.exit(0);
}

let summaryPath = null;
let repoRoot = null;
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "-o") {
    summaryPath = args[index + 1] ?? null;
    index += 1;
    continue;
  }
  if (args[index] === "-C") {
    repoRoot = args[index + 1] ?? null;
    index += 1;
  }
}

if (!summaryPath || !repoRoot) {
  process.stderr.write("Fake Codex did not receive both -o and -C.\n");
  process.exit(1);
}

const prompt = fs.readFileSync(0, "utf8");
const logsRoot = path.join(repoRoot, ".codex", "logs");
const logDirectories = fs.existsSync(logsRoot)
  ? fs.readdirSync(logsRoot, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort()
  : [];
if (logDirectories.length === 0) {
  process.stderr.write("Canonical writer did not create a log directory before Codex execution.\n");
  process.exit(31);
}

const latestLogDirectory = path.join(logsRoot, logDirectories[logDirectories.length - 1]);
const manifestPath = path.join(latestLogDirectory, "run.json");
if (!fs.existsSync(manifestPath)) {
  process.stderr.write("Canonical writer did not create run.json before Codex execution.\n");
  process.exit(32);
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
if (!manifest.runtimePolicy || !manifest.runtimePolicy.requested || !manifest.runtimePolicy.resolved || !manifest.runtimePolicy.sources) {
  process.stderr.write("Canonical writer did not receipt runtimePolicy before execution.\n");
  process.exit(33);
}

if (prompt.includes("Scenario: runtime-policy-legacy")) {
  if (manifest.runtimePolicy.resolved.permissions.sandbox_mode !== "danger-full-access") {
    process.stderr.write("Canonical writer did not resolve the legacy sandbox posture.\n");
    process.exit(34);
  }
  if (!String(manifest.runtimePolicy.sources.permissions.sandbox_mode).includes("prompt-metadata")) {
    process.stderr.write("Canonical writer did not receipt prompt metadata as the sandbox source.\n");
    process.exit(35);
  }
}

const admittedProofText = "canonical workspace proof";
const writeTaskFile = () => {
  fs.mkdirSync(path.join(repoRoot, "docs"), { recursive: true });
  fs.appendFileSync(path.join(repoRoot, "docs", "task.md"), `${admittedProofText}\n`, "utf8");
};
const writeArtifacts = () => {
  fs.mkdirSync(path.join(repoRoot, ".codex"), { recursive: true });
  fs.writeFileSync(path.join(repoRoot, ".codex", "commit-meta.json"), '{"type":"feat","scope":"atlas-workspace","summary":"record canonical writer proof"}\n', "utf8");
  fs.writeFileSync(path.join(repoRoot, ".codex", "spec-to-diff-proof.json"), `${JSON.stringify({
    contract_version: "atlas.stack.spec_to_diff.v1",
    criteria: [
      {
        criterion_id: "ac-01",
        status: "satisfied",
        changed_paths: ["docs/task.md"],
        diff_evidence: [admittedProofText],
        note: "Fake Codex updated the admitted path."
      }
    ],
    unchanged_path_justifications: []
  }, null, 2)}\n`, "utf8");
};

if (prompt.includes("Scenario: mutate-admitted") || prompt.includes("Scenario: runtime-policy-legacy")) {
  writeTaskFile();
  writeArtifacts();
}

if (prompt.includes("Scenario: mutate-unadmitted")) {
  writeTaskFile();
  fs.appendFileSync(path.join(repoRoot, "docs", "unadmitted.md"), "unadmitted mutation\n", "utf8");
  writeArtifacts();
}

if (prompt.includes("Scenario: touch-preexisting-dirt")) {
  writeTaskFile();
  fs.appendFileSync(path.join(repoRoot, "docs", "operator-note.md"), "operator dirt drift\n", "utf8");
  writeArtifacts();
}

if (prompt.includes("Scenario: mutate-preexisting-directory-path")) {
  writeTaskFile();
  fs.writeFileSync(path.join(repoRoot, "d", "new-drift.txt"), "nested directory path drift\n", "utf8");
  writeArtifacts();
}

fs.writeFileSync(summaryPath, "Fake Codex completed the canonical workspace fixture.\n", "utf8");
process.stdout.write('{"status":"ok"}\n');
'@
    [System.IO.File]::WriteAllText($fakeCodexJsPath, $fakeCodexJs.TrimStart("`r", "`n") + "`r`n")
    [System.IO.File]::WriteAllText($fakeCodexCmdPath, "@echo off`r`nnode ""%~dp0fake-codex.mjs"" %*`r`n")

    return [pscustomobject]@{
        CommandPath = $fakeCodexCmdPath
    }
}

function New-FixtureRepo {
    param(
        [string]$BaseRoot,
        [string]$Name = "ATLAS"
    )

    $repoRoot = Join-Path -Path $BaseRoot -ChildPath $Name
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    foreach ($relativePath in @(".codex\archive", ".codex\exports", ".codex\inbox", ".codex\logs", ".codex\locks", "docs")) {
        New-Item -ItemType Directory -Path (Join-Path -Path $repoRoot -ChildPath $relativePath) -Force | Out-Null
    }

    [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "README.md"), "Fixture root.`r`n")
    [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "docs\task.md"), "baseline`r`n")
    [System.IO.File]::WriteAllText((Join-Path -Path $repoRoot -ChildPath "docs\operator-note.md"), "operator baseline`r`n")

    [void](Invoke-GitChecked -WorkingDirectory $repoRoot -Arguments @("init", "--quiet"))
    [void](Invoke-GitChecked -WorkingDirectory $repoRoot -Arguments @("config", "user.name", "Atlas Workspace Fixture"))
    [void](Invoke-GitChecked -WorkingDirectory $repoRoot -Arguments @("config", "user.email", "atlas-workspace-fixture@local"))
    [void](Invoke-GitChecked -WorkingDirectory $repoRoot -Arguments @("add", "."))
    [void](Invoke-GitChecked -WorkingDirectory $repoRoot -Arguments @("commit", "--quiet", "-m", "fixture baseline"))
    [void](Invoke-GitChecked -WorkingDirectory $repoRoot -Arguments @("branch", "-M", "main"))

    return $repoRoot
}

function New-NestedRepoDirtyDirectory {
    param(
        [string]$RepoRoot,
        [string]$RelativePath = "d"
    )

    $nestedRepoRoot = Join-Path -Path $RepoRoot -ChildPath $RelativePath
    New-Item -ItemType Directory -Path $nestedRepoRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path -Path $nestedRepoRoot -ChildPath "inner.txt"), "nested baseline`r`n")

    [void](Invoke-GitChecked -WorkingDirectory $nestedRepoRoot -Arguments @("init", "--quiet"))
    [void](Invoke-GitChecked -WorkingDirectory $nestedRepoRoot -Arguments @("config", "user.name", "Nested Repo Fixture"))
    [void](Invoke-GitChecked -WorkingDirectory $nestedRepoRoot -Arguments @("config", "user.email", "nested-repo-fixture@local"))
    [void](Invoke-GitChecked -WorkingDirectory $nestedRepoRoot -Arguments @("add", "."))
    [void](Invoke-GitChecked -WorkingDirectory $nestedRepoRoot -Arguments @("commit", "--quiet", "-m", "nested baseline"))
    [void](Invoke-GitChecked -WorkingDirectory $nestedRepoRoot -Arguments @("branch", "-M", "main"))

    $statusResult = Invoke-GitChecked -WorkingDirectory $RepoRoot -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    $expectedStatusLine = "?? {0}/" -f $RelativePath.Replace("\", "/").Trim("/")
    Assert-Condition -Condition (($statusResult.StdOut -split "`r?`n") -contains $expectedStatusLine) -Message ("Nested repo fixture did not produce the expected outer dirt shape. Expected `{0}`. Observed: {1}" -f $expectedStatusLine, $statusResult.StdOut.Trim())

    return [pscustomobject]@{
        RelativePath = $RelativePath.Replace("\", "/").Trim("/")
        StatusPath = $expectedStatusLine.Substring(3)
        RootPath = $nestedRepoRoot
        InnerFilePath = Join-Path -Path $nestedRepoRoot -ChildPath "inner.txt"
    }
}

function New-PromptFile {
    param(
        [string]$RepoRoot,
        [string]$FileName,
        [string]$Content
    )

    $promptPath = Join-Path -Path $RepoRoot -ChildPath (".codex\inbox\{0}" -f $FileName)
    [System.IO.File]::WriteAllText($promptPath, $Content.TrimStart("`r", "`n") + "`r`n")
    return $promptPath
}

function Invoke-CanonicalWriterFixture {
    param(
        [string]$RunnerPath,
        [string]$RepoRoot,
        [string]$PromptPath,
        [string]$FakeCodexPath,
        $GitWrapper,
        [string]$CanonicalRootOverride = "",
        [string[]]$AdditionalArguments = @()
    )

    $powershellExe = Join-Path -Path $PSHOME -ChildPath "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        $powershellExe = "powershell.exe"
    }

    $environment = @{
        PATH = "{0};{1}" -f $GitWrapper.PathEntry, $env:PATH
        REAL_GIT = $GitWrapper.RealGit
        GIT_WRAPPER_LOG_PATH = $GitWrapper.LogPath
        STACK_GIT_COMMAND = (Join-Path -Path $GitWrapper.PathEntry -ChildPath "git.cmd")
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $RunnerPath,
        "-PromptPath", $PromptPath,
        "-CanonicalRootPath", $(if ([string]::IsNullOrWhiteSpace($CanonicalRootOverride)) { $RepoRoot } else { $CanonicalRootOverride }),
        "-RuntimeConfigPath", ".\ops\codex\repos\stack\config.toml",
        "-ExecutionClassPath", ".\ops\codex\execution-classes\atlas-workspace.writer.json",
        "-CodexCommand", $FakeCodexPath
    ) + $AdditionalArguments

    $result = Invoke-ProcessCapture -FilePath $powershellExe -ArgumentList $arguments -WorkingDirectory (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "..\..")).Path -Environment $environment
    $latestLogDirectory = Get-ChildItem -LiteralPath (Join-Path -Path $RepoRoot -ChildPath ".codex\logs") -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -Last 1
    $manifest = $null
    if ($null -ne $latestLogDirectory) {
        $manifestPath = Join-Path -Path $latestLogDirectory.FullName -ChildPath "run.json"
        if (Test-Path -LiteralPath $manifestPath) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
    }

    return [pscustomobject]@{
        Result = $result
        Manifest = $manifest
        LogDirectory = if ($null -ne $latestLogDirectory) { $latestLogDirectory.FullName } else { $null }
    }
}

$fixtureRoot = $null

try {
    $fixtureRoot = New-TempFixtureRoot
    $toolRoot = Join-Path -Path $fixtureRoot -ChildPath "tools"
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    $gitWrapper = New-GitWrapperTooling -ToolRoot $toolRoot
    $fakeCodex = New-FakeCodexTooling -ToolRoot $toolRoot
    $runnerPath = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexCanonicalWorkspaceTask.ps1")).Path

    $invalidRoot = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "invalid-root-parent") -Name "wrong-root"
    $invalidPrompt = New-PromptFile -RepoRoot $invalidRoot -FileName "invalid-root.md" -Content @"
Title: Invalid root

Objective:
Prove canonical root validation.
"@
    $invalidRootRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $invalidRoot -PromptPath $invalidPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper -CanonicalRootOverride $invalidRoot
    Assert-Condition -Condition ($invalidRootRun.Result.ExitCode -ne 0) -Message "Canonical root validation fixture unexpectedly succeeded."
    Assert-Condition -Condition (($invalidRootRun.Result.StdOut + $invalidRootRun.Result.StdErr) -match "must end with 'ATLAS'") -Message "Canonical root validation fixture did not report the explicit ATLAS leaf-name requirement."

    $realGitDirectoryRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "real-git-directory")
    $realGitDirectoryPrompt = New-PromptFile -RepoRoot $realGitDirectoryRepo -FileName "real-git-directory.md" -Content @"
Title: Real git directory
Verify: git diff --check

Objective:
Prove the canonical writer accepts a real .git directory.

Scenario: no-op
"@
    $realGitDirectoryRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $realGitDirectoryRepo -PromptPath $realGitDirectoryPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($realGitDirectoryRun.Result.ExitCode -eq 0) -Message ("Real .git directory fixture failed. StdOut: {0} StdErr: {1}" -f $realGitDirectoryRun.Result.StdOut, $realGitDirectoryRun.Result.StdErr)
    Assert-Condition -Condition ($null -ne $realGitDirectoryRun.Manifest) -Message "Real .git directory fixture did not produce run.json."
    Assert-Condition -Condition ([string]$realGitDirectoryRun.Manifest.status -eq "success") -Message "Real .git directory fixture did not report success."
    Assert-Condition -Condition ([bool]$realGitDirectoryRun.Manifest.canonicalRootValidation.gitEntryExists) -Message "Real .git directory fixture did not receipt the canonical .git entry."
    Assert-Condition -Condition ([bool]$realGitDirectoryRun.Manifest.canonicalRootValidation.gitEntryIsDirectory) -Message "Real .git directory fixture did not prove the canonical .git entry is a directory."
    Assert-Condition -Condition ([string]::IsNullOrWhiteSpace([string]$realGitDirectoryRun.Manifest.canonicalRootValidation.reasonCode)) -Message "Real .git directory fixture unexpectedly receipted a canonical git-directory failure code."

    $linkedWorktreeGitFileRoot = Join-Path -Path $fixtureRoot -ChildPath "linked-worktree-gitfile\ATLAS"
    foreach ($relativePath in @(".codex\inbox", "docs")) {
        New-Item -ItemType Directory -Path (Join-Path -Path $linkedWorktreeGitFileRoot -ChildPath $relativePath) -Force | Out-Null
    }
    [System.IO.File]::WriteAllText((Join-Path -Path $linkedWorktreeGitFileRoot -ChildPath ".git"), "gitdir: C:/linked/worktree/.git/worktrees/atlas`r`n")
    [System.IO.File]::WriteAllText((Join-Path -Path $linkedWorktreeGitFileRoot -ChildPath "README.md"), "Linked worktree gitfile fixture.`r`n")
    $linkedWorktreeGitFilePrompt = New-PromptFile -RepoRoot $linkedWorktreeGitFileRoot -FileName "linked-worktree-gitfile.md" -Content @"
Title: Linked worktree gitfile

Objective:
Prove the canonical writer rejects a linked-worktree .git file.
"@
    $linkedWorktreeGitFileRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $linkedWorktreeGitFileRoot -PromptPath $linkedWorktreeGitFilePrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    $linkedWorktreeGitFileOutput = $linkedWorktreeGitFileRun.Result.StdOut + $linkedWorktreeGitFileRun.Result.StdErr
    Assert-Condition -Condition ($linkedWorktreeGitFileRun.Result.ExitCode -ne 0) -Message "Linked-worktree .git file fixture unexpectedly succeeded."
    Assert-Condition -Condition ($linkedWorktreeGitFileOutput -match "canonical_workspace_git_directory_required") -Message "Linked-worktree .git file fixture did not preserve the canonical_workspace_git_directory_required failure code."

    $readOnlyRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "read-only")
    $readOnlyPrompt = New-PromptFile -RepoRoot $readOnlyRepo -FileName "read-only.md" -Content @"
Title: Read only default
Verify: git diff --check

Objective:
Prove the canonical writer is read-only by default.

Scenario: mutate-admitted
"@
    $readOnlyRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $readOnlyRepo -PromptPath $readOnlyPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($readOnlyRun.Result.ExitCode -ne 0) -Message "Read-only default fixture unexpectedly succeeded after mutation."
    Assert-Condition -Condition ($null -ne $readOnlyRun.Manifest) -Message ("Read-only default fixture did not produce run.json. StdOut: {0} StdErr: {1}" -f $readOnlyRun.Result.StdOut, $readOnlyRun.Result.StdErr)
    Assert-Condition -Condition ([string]$readOnlyRun.Manifest.status -eq "mutation_admission_failed") -Message ("Read-only default fixture did not fail with mutation_admission_failed. ManifestStatus: {0} StdOut: {1}" -f [string]$readOnlyRun.Manifest.status, $readOnlyRun.Result.StdOut)

    $mutationRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "mutation")
    [System.IO.File]::WriteAllText((Join-Path -Path $mutationRepo -ChildPath "docs\operator-note.md"), "operator dirt preserved`r`n")
    $successPrompt = New-PromptFile -RepoRoot $mutationRepo -FileName "success.md" -Content @"
Title: Canonical writer success
Runtime Sandbox Mode: danger-full-access
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove the canonical workspace writer.

Scenario: runtime-policy-legacy

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $successRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $mutationRepo -PromptPath $successPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($successRun.Result.ExitCode -eq 0) -Message ("Canonical writer success fixture failed. StdOut: {0} StdErr: {1} ManifestStatus: {2}" -f $successRun.Result.StdOut, $successRun.Result.StdErr, $(if ($null -ne $successRun.Manifest) { $successRun.Manifest.status } else { "<missing>" }))
    Assert-Condition -Condition ($null -ne $successRun.Manifest) -Message "Canonical writer success fixture did not produce run.json."
    Assert-Condition -Condition ([string]$successRun.Manifest.status -eq "success") -Message "Canonical writer success fixture did not record success."
    Assert-Condition -Condition ([string]$successRun.Manifest.executionClass -eq "canonical_workspace") -Message "Canonical writer success fixture did not receipt the canonical_workspace execution class."
    Assert-Condition -Condition ([string]$successRun.Manifest.runtimePolicy.sources.permissions.sandbox_mode -match "prompt-metadata") -Message "Canonical writer success fixture did not receipt prompt metadata as the sandbox source."
    Assert-Condition -Condition ([string]$successRun.Manifest.runtimePolicy.resolved.permissions.sandbox_mode -eq "danger-full-access") -Message "Canonical writer success fixture did not resolve the legacy sandbox posture."
    Assert-Condition -Condition ($null -eq $successRun.Manifest.runtimePolicy.resolved.permissions.permission_profile) -Message "Canonical writer success fixture should not keep a modern permission profile active when the prompt requested a legacy sandbox."
    Assert-Condition -Condition ($successRun.Manifest.lock.acquired -and $successRun.Manifest.lock.released) -Message "Canonical writer success fixture did not record lock acquisition and release."
    Assert-Condition -Condition (@($successRun.Manifest.changedPaths) -contains "docs/task.md") -Message "Canonical writer success fixture did not record the admitted task-owned changed path."
    Assert-Condition -Condition (@($successRun.Manifest.dirtyInventory.initial | Where-Object { $_.path -eq "docs/operator-note.md" }).Count -eq 1) -Message "Canonical writer success fixture did not snapshot the pre-existing dirty path."
    Assert-Condition -Condition (@($successRun.Manifest.dirtyInventory.preservationViolations).Count -eq 0) -Message "Canonical writer success fixture unexpectedly reported dirty-preservation violations."
    Assert-Condition -Condition ((Get-Content -LiteralPath (Join-Path -Path $mutationRepo -ChildPath "docs\operator-note.md") -Raw) -eq "operator dirt preserved`r`n") -Message "Canonical writer success fixture did not preserve the pre-existing dirty file."
    $stagedLogLines = @(Get-Content -LiteralPath $gitWrapper.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Condition -Condition (@($stagedLogLines | Where-Object { $_.args[0] -eq "worktree" }).Count -eq 0) -Message "Canonical writer success fixture unexpectedly used git worktree."
    Assert-Condition -Condition (@($stagedLogLines | Where-Object { $_.args[0] -eq "push" }).Count -eq 0) -Message "Canonical writer success fixture unexpectedly used git push."
    $addCommandLogs = @($stagedLogLines | Where-Object { $_.args[0] -eq "add" })
    Assert-Condition -Condition (@($addCommandLogs | Where-Object { $_.args[1] -eq "--" -and $_.args[2] -eq "docs/task.md" -and $_.args.Count -eq 3 }).Count -ge 1) -Message ("Canonical writer success fixture did not stage only the exact admitted path. Observed add commands: {0}" -f (($addCommandLogs | ConvertTo-Json -Compress)))
    $successHead = Invoke-GitChecked -WorkingDirectory $mutationRepo -Arguments @("show", "--name-only", "--format=%B", "HEAD")
    Assert-Condition -Condition (($successHead.StdOut -split "`r?`n") -contains "docs/task.md") -Message "Canonical writer success fixture commit did not include docs/task.md."
    Assert-Condition -Condition (($successHead.StdOut -split "`r?`n") -notcontains "docs/operator-note.md") -Message "Canonical writer success fixture commit included pre-existing dirt."

    $nestedDirectoryRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "nested-directory")
    $nestedDirectoryFixture = New-NestedRepoDirtyDirectory -RepoRoot $nestedDirectoryRepo
    $nestedDirectoryPrompt = New-PromptFile -RepoRoot $nestedDirectoryRepo -FileName "nested-directory.md" -Content @"
Title: Nested directory preservation
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove pre-existing nested-repo directory dirt is preserved by digest.

Scenario: mutate-admitted

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $nestedDirectoryRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $nestedDirectoryRepo -PromptPath $nestedDirectoryPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($nestedDirectoryRun.Result.ExitCode -eq 0) -Message ("Nested-directory preservation fixture failed. StdOut: {0} StdErr: {1} ManifestStatus: {2}" -f $nestedDirectoryRun.Result.StdOut, $nestedDirectoryRun.Result.StdErr, $(if ($null -ne $nestedDirectoryRun.Manifest) { $nestedDirectoryRun.Manifest.status } else { "<missing>" }))
    Assert-Condition -Condition ($null -ne $nestedDirectoryRun.Manifest) -Message "Nested-directory preservation fixture did not produce run.json."
    Assert-Condition -Condition ([string]$nestedDirectoryRun.Manifest.status -eq "success") -Message "Nested-directory preservation fixture did not record success."
    $nestedInitialEntry = @($nestedDirectoryRun.Manifest.dirtyInventory.initial | Where-Object { $_.path -eq $nestedDirectoryFixture.StatusPath })
    $nestedFinalEntry = @($nestedDirectoryRun.Manifest.dirtyInventory.final | Where-Object { $_.path -eq $nestedDirectoryFixture.StatusPath })
    Assert-Condition -Condition ($nestedInitialEntry.Count -eq 1) -Message "Nested-directory preservation fixture did not snapshot the pre-existing nested repo directory."
    Assert-Condition -Condition ($nestedFinalEntry.Count -eq 1) -Message "Nested-directory preservation fixture did not preserve the nested repo directory in the final snapshot."
    Assert-Condition -Condition ([string]$nestedInitialEntry[0].digestSource -eq "working-tree-directory") -Message "Nested-directory preservation fixture did not receipt working-tree-directory as the digest source."
    Assert-Condition -Condition ([string]$nestedFinalEntry[0].digestSource -eq "working-tree-directory") -Message "Nested-directory preservation fixture did not keep working-tree-directory as the final digest source."
    Assert-Condition -Condition ([string]$nestedInitialEntry[0].digest -match "^sha256:[0-9a-f]{64}$") -Message "Nested-directory preservation fixture did not receipt a deterministic directory digest."
    Assert-Condition -Condition ([string]$nestedInitialEntry[0].digest -eq [string]$nestedFinalEntry[0].digest) -Message "Nested-directory preservation fixture changed the nested repo directory digest even though the directory was untouched."
    Assert-Condition -Condition (@($nestedDirectoryRun.Manifest.dirtyInventory.preservationViolations).Count -eq 0) -Message "Nested-directory preservation fixture unexpectedly reported dirty-preservation violations."
    Assert-Condition -Condition ((Get-Content -LiteralPath $nestedDirectoryFixture.InnerFilePath -Raw) -eq "nested baseline`r`n") -Message "Nested-directory preservation fixture changed the nested repo contents."
    $nestedStatusAfter = Invoke-GitChecked -WorkingDirectory $nestedDirectoryRepo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    Assert-Condition -Condition (($nestedStatusAfter.StdOut -split "`r?`n") -contains ("?? {0}" -f $nestedDirectoryFixture.StatusPath)) -Message "Nested-directory preservation fixture did not keep the outer nested-repo dirt line intact."

    $unadmittedRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "unadmitted")
    $unadmittedPrompt = New-PromptFile -RepoRoot $unadmittedRepo -FileName "unadmitted.md" -Content @"
Title: Unadmitted mutation
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove exact mutation admission.

Scenario: mutate-unadmitted
"@
    $unadmittedRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $unadmittedRepo -PromptPath $unadmittedPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($unadmittedRun.Result.ExitCode -ne 0) -Message "Unadmitted mutation fixture unexpectedly succeeded."
    Assert-Condition -Condition ($null -ne $unadmittedRun.Manifest) -Message "Unadmitted mutation fixture did not produce run.json."
    Assert-Condition -Condition ([string]$unadmittedRun.Manifest.status -eq "mutation_admission_failed") -Message "Unadmitted mutation fixture did not fail with mutation_admission_failed."
    Assert-Condition -Condition (@($unadmittedRun.Manifest.mutationAdmission.unexpectedTaskChangedPaths) -contains "docs/unadmitted.md") -Message "Unadmitted mutation fixture did not receipt the unexpected task-owned path."

    $dirtRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "dirt")
    [System.IO.File]::WriteAllText((Join-Path -Path $dirtRepo -ChildPath "docs\operator-note.md"), "operator dirt preserved`r`n")
    $dirtPrompt = New-PromptFile -RepoRoot $dirtRepo -FileName "dirt-drift.md" -Content @"
Title: Dirt drift
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove dirty path preservation.

Scenario: touch-preexisting-dirt
"@
    $dirtRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $dirtRepo -PromptPath $dirtPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($dirtRun.Result.ExitCode -ne 0) -Message "Dirty-preservation fixture unexpectedly succeeded."
    Assert-Condition -Condition ($null -ne $dirtRun.Manifest) -Message "Dirty-preservation fixture did not produce run.json."
    Assert-Condition -Condition ([string]$dirtRun.Manifest.status -eq "dirty_preservation_failed") -Message "Dirty-preservation fixture did not fail with dirty_preservation_failed."
    Assert-Condition -Condition (@($dirtRun.Manifest.dirtyInventory.preservationViolations).Count -gt 0) -Message "Dirty-preservation fixture did not receipt preservation violations."

    $nestedDirectoryDriftRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "nested-directory-drift")
    $nestedDirectoryDriftFixture = New-NestedRepoDirtyDirectory -RepoRoot $nestedDirectoryDriftRepo
    $nestedDirectoryDriftPrompt = New-PromptFile -RepoRoot $nestedDirectoryDriftRepo -FileName "nested-directory-drift.md" -Content @"
Title: Nested directory drift
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove nested-repo directory drift fails closed.

Scenario: mutate-preexisting-directory-path

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $nestedDirectoryDriftRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $nestedDirectoryDriftRepo -PromptPath $nestedDirectoryDriftPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($nestedDirectoryDriftRun.Result.ExitCode -ne 0) -Message "Nested-directory drift fixture unexpectedly succeeded."
    Assert-Condition -Condition ($null -ne $nestedDirectoryDriftRun.Manifest) -Message "Nested-directory drift fixture did not produce run.json."
    Assert-Condition -Condition ([string]$nestedDirectoryDriftRun.Manifest.status -eq "dirty_preservation_failed") -Message "Nested-directory drift fixture did not fail with dirty_preservation_failed."
    $nestedDriftInitialEntry = @($nestedDirectoryDriftRun.Manifest.dirtyInventory.initial | Where-Object { $_.path -eq $nestedDirectoryDriftFixture.StatusPath })
    $nestedDriftFinalEntry = @($nestedDirectoryDriftRun.Manifest.dirtyInventory.final | Where-Object { $_.path -eq $nestedDirectoryDriftFixture.StatusPath })
    Assert-Condition -Condition ($nestedDriftInitialEntry.Count -eq 1 -and $nestedDriftFinalEntry.Count -eq 1) -Message "Nested-directory drift fixture did not receipt both the initial and final nested directory snapshots."
    Assert-Condition -Condition ([string]$nestedDriftInitialEntry[0].digestSource -eq "working-tree-directory") -Message "Nested-directory drift fixture did not receipt working-tree-directory on the initial snapshot."
    Assert-Condition -Condition ([string]$nestedDriftFinalEntry[0].digestSource -eq "working-tree-directory") -Message "Nested-directory drift fixture did not receipt working-tree-directory on the final snapshot."
    Assert-Condition -Condition ([string]$nestedDriftInitialEntry[0].digest -ne [string]$nestedDriftFinalEntry[0].digest) -Message "Nested-directory drift fixture did not detect the nested directory fingerprint change."
    Assert-Condition -Condition (@($nestedDirectoryDriftRun.Manifest.dirtyInventory.preservationViolations | Where-Object { $_ -match [regex]::Escape($nestedDirectoryDriftFixture.StatusPath) }).Count -gt 0) -Message "Nested-directory drift fixture did not receipt a preservation violation for the nested repo directory."
    $nestedDriftStatusAfter = Invoke-GitChecked -WorkingDirectory $nestedDirectoryDriftRepo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    Assert-Condition -Condition (($nestedDriftStatusAfter.StdOut -split "`r?`n") -contains ("?? {0}" -f $nestedDirectoryDriftFixture.StatusPath)) -Message "Nested-directory drift fixture changed the outer nested-repo dirt line instead of relying on the directory digest."

    $contentionRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "contention")
    $contentionLockPath = Join-Path -Path $contentionRepo -ChildPath ".codex\locks\atlas-workspace-writer.lock.json"
    $liveLock = [ordered]@{
        contract = "atlas.stack.canonical_workspace_lock.v1"
        run_id = "live-lock"
        canonical_root = $contentionRepo
        prompt_path = "live"
        acquired_at = (Get-Date).ToUniversalTime().ToString("o")
        stale_after_minutes = 30
        owner = [ordered]@{
            machine = $env:COMPUTERNAME
            user = $env:USERNAME
            process_id = $PID
            process_name = "powershell"
            script_path = "fixture"
        }
    }
    [System.IO.File]::WriteAllText($contentionLockPath, (($liveLock | ConvertTo-Json -Depth 8) + "`r`n"))
    $contentionPrompt = New-PromptFile -RepoRoot $contentionRepo -FileName "contention.md" -Content @"
Title: Lock contention

Objective:
Prove canonical writer lock contention.

Scenario: no-op
"@
    $contentionRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $contentionRepo -PromptPath $contentionPrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($contentionRun.Result.ExitCode -ne 0) -Message "Lock contention fixture unexpectedly succeeded."
    Assert-Condition -Condition (($contentionRun.Result.StdOut + $contentionRun.Result.StdErr) -match "lock is already held") -Message "Lock contention fixture did not report the live owner lock failure."

    $staleRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "stale")
    $staleLockPath = Join-Path -Path $staleRepo -ChildPath ".codex\locks\atlas-workspace-writer.lock.json"
    $staleLock = [ordered]@{
        contract = "atlas.stack.canonical_workspace_lock.v1"
        run_id = "stale-lock"
        canonical_root = $staleRepo
        prompt_path = "stale"
        acquired_at = (Get-Date).ToUniversalTime().AddHours(-2).ToString("o")
        stale_after_minutes = 30
        owner = [ordered]@{
            machine = $env:COMPUTERNAME
            user = $env:USERNAME
            process_id = 999999
            process_name = "powershell"
            script_path = "fixture"
        }
    }
    [System.IO.File]::WriteAllText($staleLockPath, (($staleLock | ConvertTo-Json -Depth 8) + "`r`n"))
    $stalePrompt = New-PromptFile -RepoRoot $staleRepo -FileName "stale.md" -Content @"
Title: Stale lock recovery
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove stale lock diagnostics.

Scenario: mutate-admitted

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $staleRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $staleRepo -PromptPath $stalePrompt -FakeCodexPath $fakeCodex.CommandPath -GitWrapper $gitWrapper
    Assert-Condition -Condition ($staleRun.Result.ExitCode -eq 0) -Message ("Stale lock fixture failed. StdOut: {0} StdErr: {1} ManifestStatus: {2}" -f $staleRun.Result.StdOut, $staleRun.Result.StdErr, $(if ($null -ne $staleRun.Manifest) { $staleRun.Manifest.status } else { "<missing>" }))
    Assert-Condition -Condition ($null -ne $staleRun.Manifest) -Message "Stale lock fixture did not produce run.json."
    Assert-Condition -Condition ($null -ne $staleRun.Manifest.lock.staleDiagnostic) -Message "Stale lock fixture did not receipt stale-lock diagnostics."
    Assert-Condition -Condition ([string]$staleRun.Manifest.lock.staleDiagnostic.previousProcessState -eq "exited") -Message "Stale lock fixture did not record the exited stale-lock owner state."
    Assert-Condition -Condition (Test-Path -LiteralPath ([string]$staleRun.Manifest.lock.staleDiagnostic.staleLockPath)) -Message "Stale lock fixture did not preserve the stale lock diagnostic file."
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($fixtureRoot) -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Host "Validated canonical Atlas workspace writer."
