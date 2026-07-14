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

function Get-SpecToDiffInstructionBlockText {
    param([string]$PromptText)

    if ([string]::IsNullOrWhiteSpace($PromptText)) {
        return $null
    }

    $normalized = $PromptText -replace "`r`n", "`n"
    $start = $normalized.IndexOf("Spec-to-diff completion contract:")
    if ($start -lt 0) {
        return $null
    }

    $tail = $normalized.Substring($start)
    $end = $tail.Length
    foreach ($terminator in @("`n`nAtlas Contracts v2 preflight contract:", "`n`nVerified no-change contract:")) {
        $index = $tail.IndexOf($terminator)
        if ($index -ge 0 -and $index -lt $end) {
            $end = $index
        }
    }

    return $tail.Substring(0, $end).Trim()
}

function Assert-CleanSpecToDiffInstructionBlock {
    param(
        [string]$Block,
        [string]$Context,
        [string[]]$ExpectedCriterionIds,
        [int]$ExpectedNoneDeclaredCount = 0
    )

    Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($Block)) -Message ("{0} did not include a spec-to-diff instruction block." -f $Context)
    Assert-Condition -Condition (-not $Block.Contains("System.Object[]")) -Message ("{0} rendered System.Object[] in the spec-to-diff instruction block." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("Expected changed paths:"))).Count -eq 1) -Message ("{0} repeated the Expected changed paths heading." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("Expected unchanged paths:"))).Count -eq 1) -Message ("{0} repeated the Expected unchanged paths heading." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("Blocked / skipped reporting rules:"))).Count -eq 1) -Message ("{0} repeated the blocked/skipped heading." -f $Context)
    Assert-Condition -Condition (([regex]::Matches($Block, [regex]::Escape("- none declared"))).Count -eq $ExpectedNoneDeclaredCount) -Message ("{0} rendered the wrong count of '- none declared' lines." -f $Context)
    foreach ($criterionId in @($ExpectedCriterionIds)) {
        Assert-Condition -Condition ($Block.Contains("- {0}:" -f $criterionId)) -Message ("{0} did not include criterion id {1}." -f $Context, $criterionId)
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
    $fakeCodexExePath = Join-Path -Path $ToolRoot -ChildPath "fake-codex.exe"
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    $fakeCodexJs = @'
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
const wrapperPath = process.env.FAKE_CODEX_WRAPPER_PATH ?? "";

if (args[0] === "--version") {
  process.stdout.write(`codex-cli 0.144.1-canonical-fixture ${path.basename(wrapperPath || "unknown")}\n`);
  process.exit(0);
}

let summaryPath = null;
let repoRoot = null;
let requestedModel = null;
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "-m") { requestedModel = args[index + 1] ?? null; index += 1; continue; }
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
if (prompt.includes("ATLAS_MODEL_CAPABILITY_ACCEPTED")) {
  if (String(requestedModel ?? "").includes("unsupported")) {
    process.stdout.write('{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The model is not supported when using Codex."}}\n');
    process.exit(1);
  }
  fs.writeFileSync(summaryPath, "Fake Codex accepted the model capability probe.\n", "utf8");
  process.stdout.write('{"status":"accepted"}\n');
  process.exit(0);
}
const archiveRoot = path.join(repoRoot, ".codex", "archive");
const locksRoot = path.join(repoRoot, ".codex", "locks");
const logsRoot = path.join(repoRoot, ".codex", "logs");
if (!fs.existsSync(archiveRoot)) {
  process.stderr.write("Canonical writer did not create the archive directory before Codex execution.\n");
  process.exit(29);
}
if (!fs.existsSync(locksRoot)) {
  process.stderr.write("Canonical writer did not create the lock directory before Codex execution.\n");
  process.exit(30);
}
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
if (!manifest.codexCommand || !manifest.codexCommand.resolvedNativePath) {
  process.stderr.write("Canonical writer did not receipt the resolved Codex command before execution.\n");
  process.exit(36);
}
if (!manifest.runtimePolicy || !manifest.runtimePolicy.requested || !manifest.runtimePolicy.resolved || !manifest.runtimePolicy.sources) {
  process.stderr.write("Canonical writer did not receipt runtimePolicy before execution.\n");
  process.exit(33);
}
if (!manifest.runtimePolicy.model_capability || manifest.runtimePolicy.model_capability.status !== "accepted") {
  process.stderr.write("Canonical writer did not receipt an accepted model capability probe before execution.\n");
  process.exit(40);
}
if (path.resolve(manifest.codexCommand.resolvedNativePath) !== path.resolve(wrapperPath)) {
  process.stderr.write(`Canonical writer receipted ${manifest.codexCommand.resolvedNativePath} but executed ${wrapperPath}.\n`);
  process.exit(37);
}
if (!String(manifest.runtimePolicy.codex_version ?? manifest.runtimePolicy.resolved?.codex_version ?? "").includes(path.basename(wrapperPath))) {
  process.stderr.write("Canonical writer did not use the executed native binary for runtime-policy CLI receipt.\n");
  process.exit(38);
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

const promptRenderingFixture = prompt.includes("renders machine-readable prompt sections exactly");
const admittedProofLines = promptRenderingFixture
  ? ["prompt parser repair proof A", "prompt parser repair proof B"]
  : ["canonical workspace proof"];
const registeredWorktreeRelativePath = "mutable-owner-worktree";
const registeredWorktreePath = path.join(repoRoot, registeredWorktreeRelativePath);
const runGit = (cwd, args) => {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (typeof result.stdout === "string" && result.stdout.length > 0) {
    process.stdout.write(result.stdout);
  }
  if (typeof result.stderr === "string" && result.stderr.length > 0) {
    process.stderr.write(result.stderr);
  }
  if ((result.status ?? 1) !== 0) {
    process.exit(result.status ?? 1);
  }
  return (result.stdout ?? "").trim();
};
const requireRegisteredWorktree = () => {
  if (!fs.existsSync(registeredWorktreePath)) {
    process.stderr.write(`Missing registered worktree fixture at ${registeredWorktreePath}.\n`);
    process.exit(39);
  }
  return registeredWorktreePath;
};
const mutateRegisteredWorktree = () => {
  const worktreePath = requireRegisteredWorktree();
  fs.appendFileSync(path.join(worktreePath, "owner.txt"), "owner drift\n", "utf8");
  runGit(worktreePath, ["add", "owner.txt"]);
  runGit(worktreePath, ["commit", "--quiet", "-m", "owner worktree drift"]);
  fs.writeFileSync(path.join(worktreePath, "volatile.txt"), "volatile drift\n", "utf8");
};
const deleteRegisteredWorktreeGitfile = () => {
  const worktreePath = requireRegisteredWorktree();
  fs.rmSync(path.join(worktreePath, ".git"), { force: true });
};
const retargetRegisteredWorktreeGitfile = () => {
  const worktreePath = requireRegisteredWorktree();
  const alternateGitDirectory = path.join(worktreePath, ".alt-gitdir");
  fs.mkdirSync(alternateGitDirectory, { recursive: true });
  fs.writeFileSync(path.join(worktreePath, ".git"), `gitdir: ${alternateGitDirectory.replace(/\\\\/g, "/")}\n`, "utf8");
};
const writeTaskFile = () => {
  fs.mkdirSync(path.join(repoRoot, "docs"), { recursive: true });
  fs.appendFileSync(path.join(repoRoot, "docs", "task.md"), `${admittedProofLines.join("\n")}\n`, "utf8");
};
const writeArtifacts = () => {
  fs.mkdirSync(path.join(repoRoot, ".codex"), { recursive: true });
  fs.writeFileSync(path.join(repoRoot, ".codex", "commit-meta.json"), '{"type":"feat","scope":"atlas-workspace","summary":"record canonical writer proof"}\n', "utf8");
  fs.writeFileSync(path.join(repoRoot, ".codex", "spec-to-diff-proof.json"), `${JSON.stringify({
    contract_version: "atlas.stack.spec_to_diff.v1",
    criteria: promptRenderingFixture
      ? [
          {
            criterion_id: "ac-01",
            status: "satisfied",
            changed_paths: ["docs/task.md"],
            diff_evidence: ["prompt parser repair proof A"],
            note: "Fake Codex completed criterion ac-01."
          },
          {
            criterion_id: "ac-02",
            status: "satisfied",
            changed_paths: ["docs/task.md"],
            diff_evidence: ["prompt parser repair proof B"],
            note: "Fake Codex completed criterion ac-02."
          }
        ]
      : [
          {
            criterion_id: "ac-01",
            status: "satisfied",
            changed_paths: ["docs/task.md"],
            diff_evidence: ["canonical workspace proof"],
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

if (prompt.includes("Scenario: worker-commit")) {
  writeTaskFile();
  runGit(repoRoot, ["add", "--", "docs/task.md"]);
  runGit(repoRoot, ["commit", "--quiet", "-m", "fixture worker commit"]);
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

if (prompt.includes("Scenario: mutate-registered-worktree")) {
  writeTaskFile();
  mutateRegisteredWorktree();
  writeArtifacts();
}

if (prompt.includes("Scenario: delete-registered-worktree-gitfile")) {
  writeTaskFile();
  deleteRegisteredWorktreeGitfile();
  writeArtifacts();
}

if (prompt.includes("Scenario: retarget-registered-worktree-gitfile")) {
  writeTaskFile();
  retargetRegisteredWorktreeGitfile();
  writeArtifacts();
}

fs.writeFileSync(path.join(latestLogDirectory, "fake-codex.execution.json"), `${JSON.stringify({
  wrapperPath,
  summaryPath,
  repoRoot,
  args
}, null, 2)}\n`, "utf8");
fs.writeFileSync(summaryPath, "Fake Codex completed the canonical workspace fixture.\n", "utf8");
process.stdout.write('{"status":"ok"}\n');
'@
    $wrapperSource = @'
using System;
using System.Diagnostics;
using System.IO;

public static class FakeCodexLauncher
{
    public static int Main(string[] args)
    {
        var nodePath = Environment.GetEnvironmentVariable("FAKE_CODEX_NODE_PATH");
        var scriptPath = Environment.GetEnvironmentVariable("FAKE_CODEX_SCRIPT_PATH");
        if (string.IsNullOrWhiteSpace(nodePath) || string.IsNullOrWhiteSpace(scriptPath))
        {
            Console.Error.WriteLine("FAKE_CODEX_NODE_PATH and FAKE_CODEX_SCRIPT_PATH are required.");
            return 93;
        }

        var startInfo = new ProcessStartInfo();
        startInfo.FileName = nodePath;
        startInfo.Arguments = Quote(scriptPath) + BuildArguments(args);
        startInfo.UseShellExecute = false;
        startInfo.RedirectStandardInput = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;
        startInfo.CreateNoWindow = true;
        startInfo.EnvironmentVariables["FAKE_CODEX_WRAPPER_PATH"] = Process.GetCurrentProcess().MainModule.FileName;

        using (var process = new Process())
        {
            process.StartInfo = startInfo;
            process.Start();

            var stdin = Console.IsInputRedirected ? Console.In.ReadToEnd() : string.Empty;
            process.StandardInput.Write(stdin);
            process.StandardInput.Close();

            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();

            if (!string.IsNullOrEmpty(stdout))
            {
                Console.Out.Write(stdout);
            }
            if (!string.IsNullOrEmpty(stderr))
            {
                Console.Error.Write(stderr);
            }

            return process.ExitCode;
        }
    }

    private static string BuildArguments(string[] args)
    {
        if (args == null || args.Length == 0)
        {
            return string.Empty;
        }

        var parts = new string[args.Length];
        for (var i = 0; i < args.Length; i++)
        {
            parts[i] = Quote(args[i]);
        }

        return " " + string.Join(" ", parts);
    }

    private static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return value;
        }

        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
}
'@
    [System.IO.File]::WriteAllText($fakeCodexJsPath, $fakeCodexJs.TrimStart("`r", "`n") + "`r`n")
    Add-Type -TypeDefinition $wrapperSource -Language CSharp -OutputAssembly $fakeCodexExePath -OutputType ConsoleApplication | Out-Null

    return [pscustomobject]@{
        CommandPath = $fakeCodexExePath
        NativeCommandPath = $fakeCodexExePath
        NodePath = $nodePath
        ScriptPath = $fakeCodexJsPath
        PathEntry = $ToolRoot
    }
}

function New-FixtureRepo {
    param(
        [string]$BaseRoot,
        [string]$Name = "ATLAS",
        [switch]$SkipArchiveDirectory
    )

    $repoRoot = Join-Path -Path $BaseRoot -ChildPath $Name
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    $fixtureDirectories = @(".codex\exports", ".codex\inbox", ".codex\logs", ".codex\locks", "docs")
    if (-not $SkipArchiveDirectory.IsPresent) {
        $fixtureDirectories = @(".codex\archive") + $fixtureDirectories
    }
    foreach ($relativePath in $fixtureDirectories) {
        New-Item -ItemType Directory -Path (Join-Path -Path $repoRoot -ChildPath $relativePath) -Force | Out-Null
    }

    # Fixture-only Atlas CLI: canonical execution must discover the command
    # under its resolved root instead of using an owner-side validator engine.
    $validatorDirectory = Join-Path -Path $repoRoot -ChildPath "packages\atlas-contracts\scripts"
    New-Item -ItemType Directory -Path $validatorDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path -Path $validatorDirectory -ChildPath "validate-artifact.mjs"), @'
const args = process.argv.slice(2);
const schema = args[args.indexOf("--schema") + 1] ?? null;
const artifact = args[args.indexOf("--artifact") + 1] ?? null;
if (!schema || !artifact) { console.log(JSON.stringify({ ok: false, code: "MISSING_INPUT", schema: null, artifact, errors: ["fixture input missing"] })); process.exit(4); }
console.log(JSON.stringify({ ok: true, code: "VALID", schema: { id: schema, file: "fixture" }, artifact, errors: [] }));
'@)

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

function Test-EquivalentPath {
    param(
        [string]$LeftPath,
        [string]$RightPath
    )

    if ([string]::IsNullOrWhiteSpace($LeftPath) -or [string]::IsNullOrWhiteSpace($RightPath)) {
        return $false
    }

    return [System.IO.Path]::GetFullPath($LeftPath).TrimEnd("\", "/").Equals(
        [System.IO.Path]::GetFullPath($RightPath).TrimEnd("\", "/"),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function New-MutableRegisteredWorktreeFixture {
    param(
        [string]$BaseRoot,
        [string]$RepoRoot,
        [string]$RelativePath = "mutable-owner-worktree"
    )

    $ownerRepoRoot = Join-Path -Path $BaseRoot -ChildPath "owner-repo"
    $worktreeRoot = Join-Path -Path $RepoRoot -ChildPath $RelativePath
    New-Item -ItemType Directory -Path $ownerRepoRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path -Path $ownerRepoRoot -ChildPath "owner-seed.txt"), "owner seed`r`n")

    [void](Invoke-GitChecked -WorkingDirectory $ownerRepoRoot -Arguments @("init", "--quiet"))
    [void](Invoke-GitChecked -WorkingDirectory $ownerRepoRoot -Arguments @("config", "user.name", "Owner Repo Fixture"))
    [void](Invoke-GitChecked -WorkingDirectory $ownerRepoRoot -Arguments @("config", "user.email", "owner-repo-fixture@local"))
    [void](Invoke-GitChecked -WorkingDirectory $ownerRepoRoot -Arguments @("add", "."))
    [void](Invoke-GitChecked -WorkingDirectory $ownerRepoRoot -Arguments @("commit", "--quiet", "-m", "owner baseline"))
    [void](Invoke-GitChecked -WorkingDirectory $ownerRepoRoot -Arguments @("branch", "-M", "main"))
    [void](Invoke-GitChecked -WorkingDirectory $ownerRepoRoot -Arguments @("worktree", "add", "--quiet", $worktreeRoot, "-b", "mutable-owner-worktree-branch"))

    [System.IO.File]::WriteAllText((Join-Path -Path $worktreeRoot -ChildPath "owner.txt"), "owner baseline`r`n")
    [void](Invoke-GitChecked -WorkingDirectory $worktreeRoot -Arguments @("add", "owner.txt"))
    [void](Invoke-GitChecked -WorkingDirectory $worktreeRoot -Arguments @("commit", "--quiet", "-m", "owner worktree baseline"))

    $statusResult = Invoke-GitChecked -WorkingDirectory $RepoRoot -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    $expectedStatusLine = "?? {0}/" -f $RelativePath.Replace("\", "/").Trim("/")
    Assert-Condition -Condition (($statusResult.StdOut -split "`r?`n") -contains $expectedStatusLine) -Message ("Mutable registered worktree fixture did not produce the expected outer dirt shape. Expected `{0}`. Observed: {1}" -f $expectedStatusLine, $statusResult.StdOut.Trim())

    $gitFilePath = Join-Path -Path $worktreeRoot -ChildPath ".git"
    $gitFileTarget = ((Get-Content -LiteralPath $gitFilePath -Raw).Trim() -replace '^gitdir:\s*', '')
    if (-not [System.IO.Path]::IsPathRooted($gitFileTarget)) {
        $gitFileTarget = [System.IO.Path]::GetFullPath((Join-Path -Path $worktreeRoot -ChildPath $gitFileTarget))
    }

    return [pscustomobject]@{
        RelativePath = $RelativePath.Replace("\", "/").Trim("/")
        StatusPath = $expectedStatusLine.Substring(3)
        WorktreePath = $worktreeRoot
        GitFilePath = $gitFilePath
        GitFileTarget = $gitFileTarget
        LinkedWorktreeGitDirectory = (Invoke-GitChecked -WorkingDirectory $worktreeRoot -Arguments @("rev-parse", "--absolute-git-dir")).StdOut.Trim()
        OwnerCommonGitDirectory = (Invoke-GitChecked -WorkingDirectory $worktreeRoot -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir")).StdOut.Trim()
        CanonicalWorktreePath = (Invoke-GitChecked -WorkingDirectory $worktreeRoot -Arguments @("rev-parse", "--show-toplevel")).StdOut.Trim()
        HeadCommit = (Invoke-GitChecked -WorkingDirectory $worktreeRoot -Arguments @("rev-parse", "HEAD")).StdOut.Trim()
        OwnerFilePath = Join-Path -Path $worktreeRoot -ChildPath "owner.txt"
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

function New-RuntimeConfigFile {
    param(
        [string]$BaseRoot,
        [string]$FileName,
        [string]$WindowsCodexCommand
    )

    $configPath = Join-Path -Path $BaseRoot -ChildPath $FileName
    $normalizedWindowsCodexCommand = $WindowsCodexCommand.Replace("\", "/")
    $content = @(
        "[windows]",
        ('codex_command = "{0}"' -f $normalizedWindowsCodexCommand),
        ""
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($configPath, $content)
    return $configPath
}

function Invoke-CanonicalWriterFixture {
    param(
        [string]$RunnerPath,
        [string]$RepoRoot,
        [string]$PromptPath,
        $FakeCodex,
        $GitWrapper,
        [string]$CanonicalRootOverride = "",
        [string]$RuntimeConfigPath = ".\ops\codex\repos\stack\config.toml",
        [AllowNull()]
        [string]$CodexCommandOverride = $null,
        [string[]]$AdditionalArguments = @()
    )

    $powershellExe = Join-Path -Path $PSHOME -ChildPath "powershell.exe"
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        $powershellExe = "powershell.exe"
    }

    $environment = @{
        PATH = "{0};{1};{2}" -f $GitWrapper.PathEntry, $FakeCodex.PathEntry, $env:PATH
        REAL_GIT = $GitWrapper.RealGit
        GIT_WRAPPER_LOG_PATH = $GitWrapper.LogPath
        STACK_GIT_COMMAND = (Join-Path -Path $GitWrapper.PathEntry -ChildPath "git.cmd")
        FAKE_CODEX_NODE_PATH = $FakeCodex.NodePath
        FAKE_CODEX_SCRIPT_PATH = $FakeCodex.ScriptPath
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $RunnerPath,
        "-PromptPath", $PromptPath,
        "-CanonicalRootPath", $(if ([string]::IsNullOrWhiteSpace($CanonicalRootOverride)) { $RepoRoot } else { $CanonicalRootOverride }),
        "-RuntimeConfigPath", $RuntimeConfigPath,
        "-ExecutionClassPath", ".\ops\codex\execution-classes\atlas-workspace.writer.json"
    ) + $AdditionalArguments
    if ($PSBoundParameters.ContainsKey("CodexCommandOverride") -and -not [string]::IsNullOrWhiteSpace($CodexCommandOverride)) {
        $arguments += @("-CodexCommand", $CodexCommandOverride)
    }

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
    $executionRecord = $null
    if ($null -ne $latestLogDirectory) {
        $executionRecordPath = Join-Path -Path $latestLogDirectory.FullName -ChildPath "fake-codex.execution.json"
        if (Test-Path -LiteralPath $executionRecordPath) {
            $executionRecord = Get-Content -LiteralPath $executionRecordPath -Raw | ConvertFrom-Json
        }
    }

    return [pscustomobject]@{
        Result = $result
        Manifest = $manifest
        LogDirectory = if ($null -ne $latestLogDirectory) { $latestLogDirectory.FullName } else { $null }
        ExecutionRecord = $executionRecord
    }
}

$fixtureRoot = $null
$originalAppData = $env:APPDATA

try {
    $fixtureRoot = New-TempFixtureRoot
    $env:APPDATA = Join-Path -Path $fixtureRoot -ChildPath "appdata"
    $toolRoot = Join-Path -Path $fixtureRoot -ChildPath "tools"
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    $gitWrapper = New-GitWrapperTooling -ToolRoot $toolRoot
    $fakeCodex = New-FakeCodexTooling -ToolRoot $toolRoot
    $runnerPath = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-CodexCanonicalWorkspaceTask.ps1")).Path
    $runnerSource = Get-Content -LiteralPath $runnerPath -Raw
    $commonRunnerSource = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "CodexRunner.Common.ps1") -Raw
    Assert-Condition -Condition $runnerSource.Contains('Complete-WorkerGitStateGuard') -Message "Canonical workspace runner must fail closed when a worker moves Git HEAD."
    Assert-Condition -Condition $runnerSource.Contains('worker_git_state_failed') -Message "Canonical workspace runner must preserve the worker Git-state failure classification."
    Assert-Condition -Condition $commonRunnerSource.Contains('worker_git_head_mutation_detected') -Message "Shared runner must expose a stable worker Git-head mutation failure code."

    $invalidRoot = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "invalid-root-parent") -Name "wrong-root"
    $invalidPrompt = New-PromptFile -RepoRoot $invalidRoot -FileName "invalid-root.md" -Content @"
Title: Invalid root

Objective:
Prove canonical root validation.
"@
    $invalidRootRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $invalidRoot -PromptPath $invalidPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CanonicalRootOverride $invalidRoot -CodexCommandOverride $fakeCodex.CommandPath
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
    $realGitDirectoryRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $realGitDirectoryRepo -PromptPath $realGitDirectoryPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($realGitDirectoryRun.Result.ExitCode -eq 0) -Message ("Real .git directory fixture failed. StdOut: {0} StdErr: {1}" -f $realGitDirectoryRun.Result.StdOut, $realGitDirectoryRun.Result.StdErr)
    Assert-Condition -Condition ($null -ne $realGitDirectoryRun.Manifest) -Message "Real .git directory fixture did not produce run.json."
    Assert-Condition -Condition ([string]$realGitDirectoryRun.Manifest.status -eq "success") -Message "Real .git directory fixture did not report success."
    Assert-Condition -Condition ([string]$realGitDirectoryRun.Manifest.codexCommand.source -eq "explicit-arg") -Message "Explicit -CodexCommand fixture did not take precedence over configured windows.codex_command."
    Assert-Condition -Condition ([string]$realGitDirectoryRun.Manifest.codexCommand.resolvedNativePath -eq $fakeCodex.CommandPath) -Message "Explicit -CodexCommand fixture did not receipt the resolved native executable."
    Assert-Condition -Condition ([bool]$realGitDirectoryRun.Manifest.canonicalRootValidation.gitEntryExists) -Message "Real .git directory fixture did not receipt the canonical .git entry."
    Assert-Condition -Condition ([bool]$realGitDirectoryRun.Manifest.canonicalRootValidation.gitEntryIsDirectory) -Message "Real .git directory fixture did not prove the canonical .git entry is a directory."
    Assert-Condition -Condition ([string]::IsNullOrWhiteSpace([string]$realGitDirectoryRun.Manifest.canonicalRootValidation.reasonCode)) -Message "Real .git directory fixture unexpectedly receipted a canonical git-directory failure code."

    $workerCommitRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "worker-commit")
    $workerCommitPrompt = New-PromptFile -RepoRoot $workerCommitRepo -FileName "worker-commit.md" -Content @"
Title: Worker commit guard

Objective:
Prove the canonical writer rejects worker-controlled commits.

Scenario: worker-commit
"@
    $workerCommitRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $workerCommitRepo -PromptPath $workerCommitPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($workerCommitRun.Result.ExitCode -eq 18) -Message "Canonical worker-commit fixture must fail closed with exit code 18."
    Assert-Condition -Condition ([string]$workerCommitRun.Manifest.status -eq "worker_git_state_failed") -Message "Canonical worker-commit fixture did not preserve the Git-state failure classification."
    Assert-Condition -Condition ([string]$workerCommitRun.Manifest.workerGitState.failureCode -eq "worker_git_head_mutation_detected") -Message "Canonical worker-commit fixture did not receipt the stable failure code."
    Assert-Condition -Condition ("worker_task_head_mutation_detected" -in @($workerCommitRun.Manifest.workerGitState.violations)) -Message "Canonical worker-commit fixture did not identify the task HEAD mutation."

    $unsupportedModelRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "unsupported-model")
    $unsupportedModelPrompt = New-PromptFile -RepoRoot $unsupportedModelRepo -FileName "unsupported-model.md" -Content @"
Title: Unsupported model

Objective:
Prove the canonical writer distinguishes unsupported_model from probe_failed.
"@
    $unsupportedModelRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $unsupportedModelRepo -PromptPath $unsupportedModelPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath -AdditionalArguments @("-Model", "unsupported-fixture")
    Assert-Condition -Condition ($unsupportedModelRun.Result.ExitCode -ne 0) -Message "Canonical unsupported_model fixture unexpectedly succeeded."
    Assert-Condition -Condition ([string]$unsupportedModelRun.Manifest.status -eq "runtime_policy_blocked") -Message "Canonical unsupported_model fixture did not stop before execution."
    Assert-Condition -Condition ([string]$unsupportedModelRun.Manifest.runtimePolicy.model_capability.status -eq "unsupported_model") -Message "Canonical fixture did not classify the clear unsupported-model response."

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
    $linkedWorktreeGitFileRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $linkedWorktreeGitFileRoot -PromptPath $linkedWorktreeGitFilePrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    $linkedWorktreeGitFileOutput = $linkedWorktreeGitFileRun.Result.StdOut + $linkedWorktreeGitFileRun.Result.StdErr
    Assert-Condition -Condition ($linkedWorktreeGitFileRun.Result.ExitCode -ne 0) -Message "Linked-worktree .git file fixture unexpectedly succeeded."
    Assert-Condition -Condition ($linkedWorktreeGitFileOutput -match "canonical_workspace_git_directory_required") -Message "Linked-worktree .git file fixture did not preserve the canonical_workspace_git_directory_required failure code."

    $configuredNativeCommandPath = Join-Path -Path $env:APPDATA -ChildPath "npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe"
    New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($configuredNativeCommandPath)) -Force | Out-Null
    Copy-Item -LiteralPath $fakeCodex.CommandPath -Destination $configuredNativeCommandPath -Force
    $configuredRequestedPath = "%APPDATA%/npm/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe"
    $configuredRuntimeConfigPath = New-RuntimeConfigFile -BaseRoot $fixtureRoot -FileName "configured-runtime-config.toml" -WindowsCodexCommand $configuredRequestedPath
    $configuredCommandRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "configured-command")
    $configuredCommandPrompt = New-PromptFile -RepoRoot $configuredCommandRepo -FileName "configured-command.md" -Content @"
Title: Configured native command
Verify: git diff --check

Objective:
Prove the canonical writer resolves the configured native executable without -CodexCommand.

Scenario: no-op
"@
    $configuredCommandRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $configuredCommandRepo -PromptPath $configuredCommandPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -RuntimeConfigPath $configuredRuntimeConfigPath
    Assert-Condition -Condition ($configuredCommandRun.Result.ExitCode -eq 0) -Message ("Configured native command fixture failed. StdOut: {0} StdErr: {1}" -f $configuredCommandRun.Result.StdOut, $configuredCommandRun.Result.StdErr)
    Assert-Condition -Condition ([string]$configuredCommandRun.Manifest.codexCommand.source -eq "runtime-config/windows.codex_command") -Message "Configured native command fixture did not receipt runtime-config/windows.codex_command as the source."
    Assert-Condition -Condition ([string]$configuredCommandRun.Manifest.codexCommand.requestedPath -eq $configuredRequestedPath) -Message "Configured %APPDATA% fixture did not receipt requestedPath."
    Assert-Condition -Condition ([string]$configuredCommandRun.Manifest.codexCommand.expandedPath -eq $configuredNativeCommandPath) -Message "Configured %APPDATA% fixture did not receipt expandedPath."
    Assert-Condition -Condition ([string]$configuredCommandRun.Manifest.codexCommand.resolvedNativePath -eq $configuredNativeCommandPath) -Message "Configured native command fixture did not receipt resolvedNativePath."
    Assert-Condition -Condition ($null -ne $configuredCommandRun.ExecutionRecord) -Message "Configured native command fixture did not record the executed fake Codex binary."
    Assert-Condition -Condition ([string]$configuredCommandRun.ExecutionRecord.wrapperPath -eq $configuredNativeCommandPath) -Message "Configured native command fixture did not execute the configured native executable."
    Assert-Condition -Condition ([string]$configuredCommandRun.Manifest.runtimePolicy.codex_version -match "codex-cli 0\.144\.1-canonical-fixture codex\.exe") -Message "Configured native command fixture did not receipt the configured native executable version in runtime policy."

    $pathFallbackNativeCommandPath = Join-Path -Path $toolRoot -ChildPath "codex.exe"
    $pathFallbackShimPath = Join-Path -Path $toolRoot -ChildPath "codex.ps1"
    Copy-Item -LiteralPath $fakeCodex.CommandPath -Destination $pathFallbackNativeCommandPath -Force
    [System.IO.File]::WriteAllText($pathFallbackShimPath, "throw 'codex.ps1 shim should never be executed by the canonical writer.'`r`n")
    $pathFallbackRuntimeConfigPath = New-RuntimeConfigFile -BaseRoot $fixtureRoot -FileName "path-fallback-runtime-config.toml" -WindowsCodexCommand ""
    $pathFallbackRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "path-fallback")
    $pathFallbackPrompt = New-PromptFile -RepoRoot $pathFallbackRepo -FileName "path-fallback.md" -Content @"
Title: PATH native fallback
Verify: git diff --check

Objective:
Prove the canonical writer prefers codex.exe over a PowerShell shim on PATH.

Scenario: no-op
"@
    $pathFallbackRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $pathFallbackRepo -PromptPath $pathFallbackPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -RuntimeConfigPath $pathFallbackRuntimeConfigPath
    Assert-Condition -Condition ($pathFallbackRun.Result.ExitCode -eq 0) -Message ("PATH native fallback fixture failed. StdOut: {0} StdErr: {1}" -f $pathFallbackRun.Result.StdOut, $pathFallbackRun.Result.StdErr)
    Assert-Condition -Condition ([string]$pathFallbackRun.Manifest.codexCommand.source -eq "path-fallback") -Message "PATH native fallback fixture did not receipt path-fallback as the source."
    Assert-Condition -Condition ([string]$pathFallbackRun.Manifest.codexCommand.path -eq $pathFallbackNativeCommandPath) -Message "PATH native fallback fixture did not resolve codex.exe."
    Assert-Condition -Condition ($null -ne $pathFallbackRun.ExecutionRecord) -Message "PATH native fallback fixture did not record the executed fake Codex binary."
    Assert-Condition -Condition ([string]$pathFallbackRun.ExecutionRecord.wrapperPath -eq $pathFallbackNativeCommandPath) -Message "PATH native fallback fixture did not execute codex.exe."
    Assert-Condition -Condition ([string]$pathFallbackRun.Manifest.runtimePolicy.codex_version -match "codex\.exe") -Message "PATH native fallback fixture did not receipt codex.exe in runtime policy."

    $missingNativeExplicitRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "missing-native-explicit")
    $missingNativeExplicitPrompt = New-PromptFile -RepoRoot $missingNativeExplicitRepo -FileName "missing-native-explicit.md" -Content @"
Title: Missing native explicit command

Objective:
Prove the canonical writer fails closed when an explicit native executable path is missing.
"@
    $missingNativeExplicitPath = Join-Path -Path $toolRoot -ChildPath "missing-codex.exe"
    $missingNativeExplicitRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $missingNativeExplicitRepo -PromptPath $missingNativeExplicitPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $missingNativeExplicitPath
    $missingNativeExplicitOutput = $missingNativeExplicitRun.Result.StdOut + $missingNativeExplicitRun.Result.StdErr
    Assert-Condition -Condition ($missingNativeExplicitRun.Result.ExitCode -ne 0) -Message "Missing native explicit fixture unexpectedly succeeded."
    Assert-Condition -Condition ([string]$missingNativeExplicitRun.Manifest.status -eq "codex_command_resolution_failed") -Message "Missing native explicit fixture did not fail with codex_command_resolution_failed."
    Assert-Condition -Condition ([string]$missingNativeExplicitRun.Manifest.codexCommand.reasonCode -eq "codex_native_executable_not_found") -Message "Missing native explicit fixture did not receipt the stable not-found reason code."
    Assert-Condition -Condition ($missingNativeExplicitOutput -match "codex_native_executable_not_found") -Message "Missing native explicit fixture did not report the stable not-found reason code."

    $scriptOnlyExplicitPath = Join-Path -Path $toolRoot -ChildPath "script-only-codex.ps1"
    [System.IO.File]::WriteAllText($scriptOnlyExplicitPath, "Write-Host 'script shim should never execute'`r`n")
    $scriptOnlyExplicitRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "script-only-explicit")
    $scriptOnlyExplicitPrompt = New-PromptFile -RepoRoot $scriptOnlyExplicitRepo -FileName "script-only-explicit.md" -Content @"
Title: Script-only explicit command

Objective:
Prove the canonical writer rejects explicit PowerShell shims before execution.
"@
    $scriptOnlyExplicitRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $scriptOnlyExplicitRepo -PromptPath $scriptOnlyExplicitPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $scriptOnlyExplicitPath
    $scriptOnlyExplicitOutput = $scriptOnlyExplicitRun.Result.StdOut + $scriptOnlyExplicitRun.Result.StdErr
    Assert-Condition -Condition ($scriptOnlyExplicitRun.Result.ExitCode -ne 0) -Message "Script-only explicit fixture unexpectedly succeeded."
    Assert-Condition -Condition ([string]$scriptOnlyExplicitRun.Manifest.status -eq "codex_command_resolution_failed") -Message "Script-only explicit fixture did not fail with codex_command_resolution_failed."
    Assert-Condition -Condition ([string]$scriptOnlyExplicitRun.Manifest.codexCommand.reasonCode -eq "codex_native_executable_required") -Message "Script-only explicit fixture did not receipt the stable native-required reason code."
    Assert-Condition -Condition ($scriptOnlyExplicitOutput -match "codex_native_executable_required") -Message "Script-only explicit fixture did not report the stable native-required reason code."

    $readOnlyRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "read-only")
    $readOnlyPrompt = New-PromptFile -RepoRoot $readOnlyRepo -FileName "read-only.md" -Content @"
Title: Read only default
Verify: git diff --check

Objective:
Prove the canonical writer is read-only by default.

Scenario: mutate-admitted
"@
    $readOnlyRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $readOnlyRepo -PromptPath $readOnlyPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
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
    $successRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $mutationRepo -PromptPath $successPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($successRun.Result.ExitCode -eq 0) -Message ("Canonical writer success fixture failed. StdOut: {0} StdErr: {1} ManifestStatus: {2}" -f $successRun.Result.StdOut, $successRun.Result.StdErr, $(if ($null -ne $successRun.Manifest) { $successRun.Manifest.status } else { "<missing>" }))
    Assert-Condition -Condition ($null -ne $successRun.Manifest) -Message "Canonical writer success fixture did not produce run.json."
    Assert-Condition -Condition ([string]$successRun.Manifest.status -eq "success") -Message "Canonical writer success fixture did not record success."
    Assert-Condition -Condition ([string]$successRun.Manifest.executionClass -eq "canonical_workspace") -Message "Canonical writer success fixture did not receipt the canonical_workspace execution class."
    Assert-Condition -Condition ([string]$successRun.Manifest.atlasContractsV2.status.preflight -eq "validated") -Message "Canonical writer must validate Atlas Contracts v2 facts before fake Codex execution."
    Assert-Condition -Condition ([bool]$successRun.Manifest.atlasContractsV2.validation.executionReceipt.ok) -Message "Canonical writer must validate the terminal Atlas Contracts v2 receipt."
    foreach ($artifactName in @("componentManifest", "jobEnvelope", "contextPacket", "approvalRecord", "evidenceBundle", "executionReceipt")) {
        Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace([string]$successRun.Manifest.atlasContractsV2.artifactPaths.$artifactName) -and (Test-Path -LiteralPath ([string]$successRun.Manifest.atlasContractsV2.artifactPaths.$artifactName))) -Message ("Canonical writer must expose the Atlas Contracts v2 {0} artifact." -f $artifactName)
    }
    foreach ($artifactName in @("componentManifest", "jobEnvelope", "contextPacket", "approvalRecord", "evidenceBundle")) {
        Assert-Condition -Condition ([bool]$successRun.Manifest.atlasContractsV2.validation.$artifactName.ok) -Message ("Canonical writer must validate the Atlas Contracts v2 {0}." -f $artifactName)
    }
    $canonicalExecutionReceipt = Get-Content -LiteralPath ([string]$successRun.Manifest.atlasContractsV2.artifactPaths.executionReceipt) -Raw | ConvertFrom-Json
    $canonicalContextPacket = Get-Content -LiteralPath ([string]$successRun.Manifest.atlasContractsV2.artifactPaths.contextPacket) -Raw | ConvertFrom-Json
    $canonicalApprovalRecord = Get-Content -LiteralPath ([string]$successRun.Manifest.atlasContractsV2.artifactPaths.approvalRecord) -Raw | ConvertFrom-Json
    $canonicalEvidenceBundle = Get-Content -LiteralPath ([string]$successRun.Manifest.atlasContractsV2.artifactPaths.evidenceBundle) -Raw | ConvertFrom-Json
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$canonicalExecutionReceipt.correlations.worktree) -RightPath $mutationRepo) -Message "Canonical writer must receipt the canonical root as its primary-worktree identity."
    Assert-Condition -Condition ([string]$canonicalContextPacket.job_id -eq [string]$canonicalExecutionReceipt.job_id -and [string]$canonicalApprovalRecord.job_id -eq [string]$canonicalExecutionReceipt.job_id -and [string]$canonicalEvidenceBundle.job_id -eq [string]$canonicalExecutionReceipt.job_id) -Message "Canonical writer artifacts must retain a shared job correlation."
    Assert-Condition -Condition ([string]$canonicalApprovalRecord.decision -eq "rejected") -Message "Canonical writer must retain denied external authority even with full local capability."
    Assert-Condition -Condition ([string]$successRun.Manifest.atlasContractsV2.validation.componentManifest.cliPath -match "packages[\\/]atlas-contracts[\\/]scripts[\\/]validate-artifact\.mjs$") -Message "Canonical writer must invoke its resolved Atlas validator CLI."
    Assert-Condition -Condition ([string]$successRun.Manifest.codexCommand.source -eq "explicit-arg") -Message "Canonical writer success fixture did not preserve the explicit fake-native executable source."
    Assert-Condition -Condition ([string]$successRun.Manifest.codexCommand.path -eq $fakeCodex.CommandPath) -Message "Canonical writer success fixture did not receipt the explicit fake-native executable path."
    Assert-Condition -Condition ([string]$successRun.Manifest.runtimePolicy.sources.permissions.sandbox_mode -match "prompt-metadata") -Message "Canonical writer success fixture did not receipt prompt metadata as the sandbox source."
    Assert-Condition -Condition ([string]$successRun.Manifest.runtimePolicy.resolved.permissions.sandbox_mode -eq "danger-full-access") -Message "Canonical writer success fixture did not resolve the legacy sandbox posture."
    Assert-Condition -Condition ($null -eq $successRun.Manifest.runtimePolicy.resolved.permissions.permission_profile) -Message "Canonical writer success fixture should not keep a modern permission profile active when the prompt requested a legacy sandbox."
    Assert-Condition -Condition ([string]$successRun.Manifest.runtimePolicy.codex_version -match "fake-codex\.exe") -Message "Canonical writer success fixture did not receipt the explicit fake-native executable in runtime policy."
    Assert-Condition -Condition ($null -ne $successRun.ExecutionRecord) -Message "Canonical writer success fixture did not record the executed fake-native executable."
    Assert-Condition -Condition ([string]$successRun.ExecutionRecord.wrapperPath -eq $fakeCodex.CommandPath) -Message "Canonical writer success fixture did not execute the explicit fake-native executable."
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

    $renderingRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "prompt-rendering")
    $renderingPrompt = New-PromptFile -RepoRoot $renderingRepo -FileName "prompt-rendering.md" -Content @"
Title: Spec-to-diff prompt rendering fixture
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove the canonical writer renders machine-readable prompt sections exactly.

Acceptance Criteria:
- [ac-01] Preserve the first declared criterion id in the rendered block.
- Preserve the generated second criterion id in the rendered block.

## Notes
This explanatory paragraph must not become ac-03.

## Verification
- git diff --check

## Deliver back
```yaml
stack_spec_to_diff_prompt_parser_repair_receipt:
  next_packet: Atlas Root Lock Refresh Then DiscordOS Projection Consumer
```

Scenario: mutate-admitted
"@
    $renderingPromptRecord = Parse-PromptFile -Path $renderingPrompt
    $renderingExpectedBlock = Get-SpecToDiffInstructionBlock -Policy (Get-SpecToDiffPromptPolicy -PromptRecord $renderingPromptRecord)
    $renderingRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $renderingRepo -PromptPath $renderingPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($renderingRun.Result.ExitCode -eq 0) -Message ("Canonical writer prompt-rendering fixture failed. StdOut: {0} StdErr: {1}" -f $renderingRun.Result.StdOut, $renderingRun.Result.StdErr)
    Assert-Condition -Condition ($null -ne $renderingRun.Manifest) -Message "Canonical writer prompt-rendering fixture did not produce run.json."
    Assert-Condition -Condition ([string]$renderingRun.Manifest.status -eq "success") -Message ("Canonical writer prompt-rendering fixture expected success but found '{0}'." -f [string]$renderingRun.Manifest.status)
    $renderingEffectivePrompt = Get-Content -LiteralPath (Join-Path -Path $renderingRun.LogDirectory -ChildPath "effective.prompt.md") -Raw
    $renderingActualBlock = Get-SpecToDiffInstructionBlockText -PromptText $renderingEffectivePrompt
    Assert-Condition -Condition (((($renderingActualBlock -replace "`r`n", "`n").Trim()) -eq (($renderingExpectedBlock -replace "`r`n", "`n").Trim()))) -Message "Canonical writer prompt-rendering fixture did not emit the exact shared spec-to-diff instruction block."
    Assert-CleanSpecToDiffInstructionBlock -Block $renderingActualBlock -Context "Canonical writer prompt-rendering fixture" -ExpectedCriterionIds @("ac-01", "ac-02") -ExpectedNoneDeclaredCount 3
    Assert-Condition -Condition (-not $renderingActualBlock.Contains("ac-03")) -Message "Canonical writer prompt-rendering fixture incorrectly rendered ac-03."

    $archiveCreationRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "archive-creation") -SkipArchiveDirectory
    $archiveCreationPrompt = New-PromptFile -RepoRoot $archiveCreationRepo -FileName "archive-creation.md" -Content @"
Title: Archive creation
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove the canonical writer creates the archive directory and archives the prompt when it was absent at run start.

Scenario: mutate-admitted

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $archiveCreationPromptPath = $archiveCreationPrompt
    $archiveCreationRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $archiveCreationRepo -PromptPath $archiveCreationPromptPath -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($archiveCreationRun.Result.ExitCode -eq 0) -Message ("Archive creation fixture failed. StdOut: {0} StdErr: {1}" -f $archiveCreationRun.Result.StdOut, $archiveCreationRun.Result.StdErr)
    Assert-Condition -Condition (Test-Path -LiteralPath (Join-Path -Path $archiveCreationRepo -ChildPath ".codex\archive") -PathType Container) -Message "Archive creation fixture did not create the archive directory."
    Assert-Condition -Condition (-not (Test-Path -LiteralPath $archiveCreationPromptPath)) -Message "Archive creation fixture did not archive the prompt out of .codex/inbox."
    $archivedPromptFiles = @(Get-ChildItem -LiteralPath (Join-Path -Path $archiveCreationRepo -ChildPath ".codex\archive") -File)
    Assert-Condition -Condition ($archivedPromptFiles.Count -eq 1) -Message "Archive creation fixture did not create exactly one archived prompt."
    Assert-Condition -Condition ([string]$archivedPromptFiles[0].Extension -eq ".md") -Message "Archive creation fixture did not preserve the prompt extension during archival."

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
    $nestedDirectoryRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $nestedDirectoryRepo -PromptPath $nestedDirectoryPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
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

    $registeredWorktreeRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "registered-worktree")
    $registeredWorktreeFixture = New-MutableRegisteredWorktreeFixture -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "registered-worktree-owner") -RepoRoot $registeredWorktreeRepo
    $registeredWorktreePrompt = New-PromptFile -RepoRoot $registeredWorktreeRepo -FileName "registered-worktree.md" -Content @"
Title: Registered owner worktree preservation
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove registered owner-worktree identity is preserved while volatile content and HEAD drift are allowed.

Scenario: mutate-registered-worktree

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $registeredWorktreeRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $registeredWorktreeRepo -PromptPath $registeredWorktreePrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($registeredWorktreeRun.Result.ExitCode -eq 0) -Message ("Registered-worktree preservation fixture failed. StdOut: {0} StdErr: {1} ManifestStatus: {2}" -f $registeredWorktreeRun.Result.StdOut, $registeredWorktreeRun.Result.StdErr, $(if ($null -ne $registeredWorktreeRun.Manifest) { $registeredWorktreeRun.Manifest.status } else { "<missing>" }))
    Assert-Condition -Condition ($null -ne $registeredWorktreeRun.Manifest) -Message "Registered-worktree preservation fixture did not produce run.json."
    Assert-Condition -Condition ([string]$registeredWorktreeRun.Manifest.status -eq "success") -Message "Registered-worktree preservation fixture did not record success."
    $registeredInitialEntry = @($registeredWorktreeRun.Manifest.dirtyInventory.initial | Where-Object { $_.path -eq $registeredWorktreeFixture.StatusPath })
    $registeredFinalEntry = @($registeredWorktreeRun.Manifest.dirtyInventory.final | Where-Object { $_.path -eq $registeredWorktreeFixture.StatusPath })
    Assert-Condition -Condition ($registeredInitialEntry.Count -eq 1 -and $registeredFinalEntry.Count -eq 1) -Message "Registered-worktree preservation fixture did not receipt both worktree snapshots."
    Assert-Condition -Condition ([string]$registeredInitialEntry[0].preservationKind -eq "mutable_registered_worktree") -Message "Registered-worktree preservation fixture did not classify the initial dirt as mutable_registered_worktree."
    Assert-Condition -Condition ([string]$registeredFinalEntry[0].preservationKind -eq "mutable_registered_worktree") -Message "Registered-worktree preservation fixture did not keep mutable_registered_worktree classification on the final snapshot."
    Assert-Condition -Condition ([string]$registeredInitialEntry[0].digestSource -eq "registered-worktree-identity") -Message "Registered-worktree preservation fixture did not receipt registered-worktree-identity as the digest source."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredInitialEntry[0].registrationIdentity.canonicalWorktreePath) -RightPath $registeredWorktreeFixture.CanonicalWorktreePath) -Message "Registered-worktree preservation fixture did not receipt canonicalWorktreePath."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredInitialEntry[0].registrationIdentity.gitfileTarget) -RightPath $registeredWorktreeFixture.GitFileTarget) -Message "Registered-worktree preservation fixture did not receipt gitfileTarget."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredInitialEntry[0].registrationIdentity.linkedWorktreeGitDirectory) -RightPath $registeredWorktreeFixture.LinkedWorktreeGitDirectory) -Message "Registered-worktree preservation fixture did not receipt linkedWorktreeGitDirectory."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredInitialEntry[0].registrationIdentity.ownerCommonGitDirectory) -RightPath $registeredWorktreeFixture.OwnerCommonGitDirectory) -Message "Registered-worktree preservation fixture did not receipt ownerCommonGitDirectory."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredFinalEntry[0].registrationIdentity.canonicalWorktreePath) -RightPath ([string]$registeredInitialEntry[0].registrationIdentity.canonicalWorktreePath)) -Message "Registered-worktree preservation fixture changed canonicalWorktreePath unexpectedly."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredFinalEntry[0].registrationIdentity.gitfileTarget) -RightPath ([string]$registeredInitialEntry[0].registrationIdentity.gitfileTarget)) -Message "Registered-worktree preservation fixture changed gitfileTarget unexpectedly."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredFinalEntry[0].registrationIdentity.linkedWorktreeGitDirectory) -RightPath ([string]$registeredInitialEntry[0].registrationIdentity.linkedWorktreeGitDirectory)) -Message "Registered-worktree preservation fixture changed linkedWorktreeGitDirectory unexpectedly."
    Assert-Condition -Condition (Test-EquivalentPath -LeftPath ([string]$registeredFinalEntry[0].registrationIdentity.ownerCommonGitDirectory) -RightPath ([string]$registeredInitialEntry[0].registrationIdentity.ownerCommonGitDirectory)) -Message "Registered-worktree preservation fixture changed ownerCommonGitDirectory unexpectedly."
    Assert-Condition -Condition ([bool]$registeredFinalEntry[0].contentDriftObserved) -Message "Registered-worktree preservation fixture did not receipt contentDriftObserved."
    Assert-Condition -Condition ([string]$registeredFinalEntry[0].volatileObservation.headCommit -ne [string]$registeredInitialEntry[0].volatileObservation.headCommit) -Message "Registered-worktree preservation fixture did not observe HEAD drift."
    Assert-Condition -Condition (@($registeredWorktreeRun.Manifest.dirtyInventory.preservationViolations).Count -eq 0) -Message "Registered-worktree preservation fixture unexpectedly reported dirty-preservation violations."
    $registeredStatusAfter = Invoke-GitChecked -WorkingDirectory $registeredWorktreeRepo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    Assert-Condition -Condition (($registeredStatusAfter.StdOut -split "`r?`n") -contains ("?? {0}" -f $registeredWorktreeFixture.StatusPath)) -Message "Registered-worktree preservation fixture did not keep the outer dirt line intact."
    $registeredAddCommandLogs = @((Get-Content -LiteralPath $gitWrapper.LogPath | ForEach-Object { $_ | ConvertFrom-Json }) | Where-Object { $_.args[0] -eq "add" })
    Assert-Condition -Condition (@($registeredAddCommandLogs | Where-Object { $_.args -contains $registeredWorktreeFixture.RelativePath -or $_.args -contains $registeredWorktreeFixture.StatusPath }).Count -eq 0) -Message "Registered-worktree preservation fixture staged owner-worktree content."
    $registeredHead = Invoke-GitChecked -WorkingDirectory $registeredWorktreeRepo -Arguments @("show", "--name-only", "--format=%B", "HEAD")
    Assert-Condition -Condition (($registeredHead.StdOut -split "`r?`n") -contains "docs/task.md") -Message "Registered-worktree preservation fixture commit did not include docs/task.md."
    Assert-Condition -Condition (($registeredHead.StdOut -split "`r?`n") -notcontains $registeredWorktreeFixture.RelativePath) -Message "Registered-worktree preservation fixture commit included owner-worktree content."

    $registeredWorktreeDeleteRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "registered-worktree-delete")
    $registeredWorktreeDeleteFixture = New-MutableRegisteredWorktreeFixture -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "registered-worktree-delete-owner") -RepoRoot $registeredWorktreeDeleteRepo
    $registeredWorktreeDeletePrompt = New-PromptFile -RepoRoot $registeredWorktreeDeleteRepo -FileName "registered-worktree-delete.md" -Content @"
Title: Registered owner worktree gitfile deletion
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove registered owner-worktree gitfile deletion fails closed.

Scenario: delete-registered-worktree-gitfile

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $registeredWorktreeDeleteRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $registeredWorktreeDeleteRepo -PromptPath $registeredWorktreeDeletePrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($registeredWorktreeDeleteRun.Result.ExitCode -ne 0) -Message "Registered-worktree gitfile deletion fixture unexpectedly succeeded."
    Assert-Condition -Condition ($null -ne $registeredWorktreeDeleteRun.Manifest) -Message "Registered-worktree gitfile deletion fixture did not produce run.json."
    Assert-Condition -Condition ([string]$registeredWorktreeDeleteRun.Manifest.status -eq "dirty_preservation_failed") -Message "Registered-worktree gitfile deletion fixture did not fail with dirty_preservation_failed."
    Assert-Condition -Condition (@($registeredWorktreeDeleteRun.Manifest.dirtyInventory.preservationViolations | Where-Object { $_ -match [regex]::Escape($registeredWorktreeDeleteFixture.StatusPath) }).Count -gt 0) -Message "Registered-worktree gitfile deletion fixture did not receipt a preservation violation for the worktree."

    $registeredWorktreeRetargetRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "registered-worktree-retarget")
    $registeredWorktreeRetargetFixture = New-MutableRegisteredWorktreeFixture -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "registered-worktree-retarget-owner") -RepoRoot $registeredWorktreeRetargetRepo
    $registeredWorktreeRetargetPrompt = New-PromptFile -RepoRoot $registeredWorktreeRetargetRepo -FileName "registered-worktree-retarget.md" -Content @"
Title: Registered owner worktree gitfile retarget
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove registered owner-worktree gitfile retargeting fails closed.

Scenario: retarget-registered-worktree-gitfile

Acceptance Criteria:
- [ac-01] Update docs/task.md with canonical workspace proof.

Expected Changed Paths:
- docs/task.md
"@
    $registeredWorktreeRetargetRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $registeredWorktreeRetargetRepo -PromptPath $registeredWorktreeRetargetPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($registeredWorktreeRetargetRun.Result.ExitCode -ne 0) -Message "Registered-worktree gitfile retarget fixture unexpectedly succeeded."
    Assert-Condition -Condition ($null -ne $registeredWorktreeRetargetRun.Manifest) -Message "Registered-worktree gitfile retarget fixture did not produce run.json."
    Assert-Condition -Condition ([string]$registeredWorktreeRetargetRun.Manifest.status -ne "success") -Message "Registered-worktree gitfile retarget fixture did not fail closed."

    $unadmittedRepo = New-FixtureRepo -BaseRoot (Join-Path -Path $fixtureRoot -ChildPath "unadmitted")
    $unadmittedPrompt = New-PromptFile -RepoRoot $unadmittedRepo -FileName "unadmitted.md" -Content @"
Title: Unadmitted mutation
Mutation Admission Path: docs/task.md
Verify: git diff --check

Objective:
Prove exact mutation admission.

Scenario: mutate-unadmitted
"@
    $unadmittedRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $unadmittedRepo -PromptPath $unadmittedPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
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
    $dirtRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $dirtRepo -PromptPath $dirtPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
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
    $nestedDirectoryDriftRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $nestedDirectoryDriftRepo -PromptPath $nestedDirectoryDriftPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($nestedDirectoryDriftRun.Result.ExitCode -ne 0) -Message "Nested-directory drift fixture unexpectedly succeeded."
    Assert-Condition -Condition ($null -ne $nestedDirectoryDriftRun.Manifest) -Message "Nested-directory drift fixture did not produce run.json."
    Assert-Condition -Condition ([string]$nestedDirectoryDriftRun.Manifest.status -eq "dirty_preservation_failed") -Message "Nested-directory drift fixture did not fail with dirty_preservation_failed."
    $nestedDriftInitialEntry = @($nestedDirectoryDriftRun.Manifest.dirtyInventory.initial | Where-Object { $_.path -eq $nestedDirectoryDriftFixture.StatusPath })
    $nestedDriftFinalEntry = @($nestedDirectoryDriftRun.Manifest.dirtyInventory.final | Where-Object { $_.path -eq $nestedDirectoryDriftFixture.StatusPath })
    Assert-Condition -Condition ($nestedDriftInitialEntry.Count -eq 1 -and $nestedDriftFinalEntry.Count -eq 1) -Message "Nested-directory drift fixture did not receipt both the initial and final nested directory snapshots."
    Assert-Condition -Condition ([string]$nestedDriftInitialEntry[0].digestSource -eq "working-tree-directory") -Message "Nested-directory drift fixture did not receipt working-tree-directory on the initial snapshot."
    Assert-Condition -Condition ([string]$nestedDriftFinalEntry[0].digestSource -eq "working-tree-directory") -Message "Nested-directory drift fixture did not receipt working-tree-directory on the final snapshot."
    Assert-Condition -Condition ([string]$nestedDriftInitialEntry[0].digest -ne [string]$nestedDriftFinalEntry[0].digest) -Message "Nested-directory drift fixture did not prove ordinary untracked directory drift remains fail-closed."
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
    $contentionRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $contentionRepo -PromptPath $contentionPrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
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
    $staleRun = Invoke-CanonicalWriterFixture -RunnerPath $runnerPath -RepoRoot $staleRepo -PromptPath $stalePrompt -FakeCodex $fakeCodex -GitWrapper $gitWrapper -CodexCommandOverride $fakeCodex.CommandPath
    Assert-Condition -Condition ($staleRun.Result.ExitCode -eq 0) -Message ("Stale lock fixture failed. StdOut: {0} StdErr: {1} ManifestStatus: {2}" -f $staleRun.Result.StdOut, $staleRun.Result.StdErr, $(if ($null -ne $staleRun.Manifest) { $staleRun.Manifest.status } else { "<missing>" }))
    Assert-Condition -Condition ($null -ne $staleRun.Manifest) -Message "Stale lock fixture did not produce run.json."
    Assert-Condition -Condition ($null -ne $staleRun.Manifest.lock.staleDiagnostic) -Message "Stale lock fixture did not receipt stale-lock diagnostics."
    Assert-Condition -Condition ([string]$staleRun.Manifest.lock.staleDiagnostic.previousProcessState -eq "exited") -Message "Stale lock fixture did not record the exited stale-lock owner state."
    Assert-Condition -Condition (Test-Path -LiteralPath ([string]$staleRun.Manifest.lock.staleDiagnostic.staleLockPath)) -Message "Stale lock fixture did not preserve the stale lock diagnostic file."
}
finally {
    $env:APPDATA = $originalAppData
    if (-not [string]::IsNullOrWhiteSpace($fixtureRoot) -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Host "Validated canonical Atlas workspace writer."
