import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import { runQueueOrRegistryLiveDirectoryReadFollowOnCommand } from "./queue-or-registry-live-directory-read-follow-on.mjs";

function createClassifierPayload(overrides = {}) {
  return {
    normalized_candidate_path: "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/",
    destination_class: "queue-home",
    execution_transition_class: "blocked-pending-live-directory-read",
    decision: "admitted-queue-home-live-directory-read-blocked-before-execution",
    ...overrides
  };
}

async function withWorkspace(files) {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "stack-queue-or-registry-live-directory-read-"));
  for (const [relativePath, content] of Object.entries(files)) {
    const absolutePath = path.join(workspaceRoot, relativePath);
    await fs.mkdir(path.dirname(absolutePath), { recursive: true });
    if (content === null) {
      await fs.mkdir(absolutePath, { recursive: true });
      continue;
    }
    await fs.mkdir(path.dirname(absolutePath), { recursive: true });
    await fs.writeFile(absolutePath, content, "utf8");
  }
  return workspaceRoot;
}

function successRunner(payload) {
  return Promise.resolve({
    ok: true,
    exitCode: 0,
    stdout: "",
    stderr: "",
    payload
  });
}

function failureRunner() {
  return Promise.resolve({
    ok: false,
    exitCode: 1,
    stdout: "",
    stderr: "classifier failed"
  });
}

function assertExactKeys(actual, expected) {
  assert.deepEqual(Object.keys(actual).sort(), [...expected].sort());
}

test("queue-home directory-read success reports shallow child names", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/alpha.json": "{}",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/beta": null
  });

  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.command, "stack queue-or-registry live-directory-read-follow-on");
  assert.equal(result.report.directory_read_status, "readable-directory-candidate");
  assert.equal(result.report.child_entry_count, 2);
  assert.deepEqual(result.report.child_entry_names, ["alpha.json", "beta"]);
  assertExactKeys(result.report, [
    "command",
    "classifier_ref",
    "normalized_candidate_path",
    "destination_class",
    "execution_transition_class",
    "directory_read_status",
    "child_entry_count",
    "child_entry_names",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("registry-home directory-read success reports empty directory", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate-dir": null
  });

  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate-dir/"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload({
      normalized_candidate_path: "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate-dir/",
      destination_class: "registry-home",
      decision: "admitted-registry-home-live-directory-read-blocked-before-execution"
    }))
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.child_entry_count, 0);
  assert.deepEqual(result.report.child_entry_names, []);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("unsupported classifier transition fails closed", async () => {
  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/"
  ], {
    runClassifier: () => successRunner(createClassifierPayload({
      execution_transition_class: "blocked-pending-live-direct-json-read",
      decision: "admitted-queue-home-live-direct-json-read-blocked-before-execution"
    }))
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "unsupported-transition");
  assert.equal(result.report.failure_scope, "transition");
});

test("missing candidate directory returns artifact-missing", async () => {
  const workspaceRoot = await withWorkspace({});

  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "artifact-missing");
  assert.equal(result.report.failure_scope, "artifact");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("file at candidate directory path returns artifact-not-directory", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir": "{}"
  });

  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "artifact-not-directory");
  assert.equal(result.report.failure_scope, "artifact");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("invalid absolute path input fails before classifier execution", async () => {
  let runnerCalls = 0;
  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "C:\\outside\\candidate-dir\\"
  ], {
    runClassifier: async () => {
      runnerCalls += 1;
      return successRunner(createClassifierPayload());
    }
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(runnerCalls, 0);
});

test("classifier execution failure never substitutes a directory result", async () => {
  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/"
  ], {
    runClassifier: failureRunner
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "classifier-failed");
  assert.equal(result.report.failure_scope, "classifier");
});

test("text output preserves the bounded directory-read contract", async () => {
  const workspaceRoot = await withWorkspace({
    "ops/atlas/runtime_state_execution_ready_transition_semantics.py": [
      "import json",
      "print(json.dumps({",
      "  'normalized_candidate_path': 'runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/',",
      "  'destination_class': 'queue-home',",
      "  'execution_transition_class': 'blocked-pending-live-directory-read',",
      "  'decision': 'admitted-queue-home-live-directory-read-blocked-before-execution'",
      "}))"
    ].join("\n"),
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/alpha.json": "{}",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/beta": null
  });

  const scriptPath = path.resolve("scripts/queue-or-registry-live-directory-read-follow-on.mjs");
  const child = spawn(process.execPath, [
    scriptPath,
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate-dir/"
  ], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      STACK_QUEUE_OR_REGISTRY_LIVE_DIRECTORY_READ_FOLLOW_ON_WORKSPACE_ROOT: workspaceRoot,
      STACK_QUEUE_OR_REGISTRY_LIVE_DIRECTORY_READ_FOLLOW_ON_PYTHON: "python"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let stdout = "";
  let stderr = "";

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });

  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });

  const exitCode = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });

  assert.equal(exitCode, 0, stderr);
  assert.match(stdout, /normalized_candidate_path=runtime\/state\/ai-long-run-batch-orchestration\/queue-or-registry\/queue-home\/candidate-dir\//);
  assert.match(stdout, /directory_read_status=readable-directory-candidate/);
  assert.match(stdout, /child_entry_count=2/);
  assert.match(stdout, /child_entry_names=\["alpha\.json","beta"\]/);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});
