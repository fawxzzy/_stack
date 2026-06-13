import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import { runQueueOrRegistryLiveDirectJsonReadFollowOnCommand } from "./queue-or-registry-live-direct-json-read-follow-on.mjs";

function createClassifierPayload(overrides = {}) {
  return {
    normalized_candidate_path: "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json",
    destination_class: "queue-home",
    execution_transition_class: "blocked-pending-live-direct-json-read",
    decision: "admitted-queue-home-live-direct-json-read-blocked-before-execution",
    ...overrides
  };
}

async function withWorkspace(files) {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "stack-queue-or-registry-live-direct-json-read-"));
  for (const [relativePath, content] of Object.entries(files)) {
    const absolutePath = path.join(workspaceRoot, relativePath);
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

test("queue-home direct-json success reports top-level object keys", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json":
      JSON.stringify({ ready: false, reason: "blocked" })
  });

  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.command, "stack queue-or-registry live-direct-json-read-follow-on");
  assert.equal(result.report.direct_json_read_status, "readable-direct-json-candidate");
  assert.equal(result.report.artifact_value_kind, "object");
  assert.deepEqual(result.report.artifact_top_level_keys, ["ready", "reason"]);
  assertExactKeys(result.report, [
    "command",
    "classifier_ref",
    "normalized_candidate_path",
    "destination_class",
    "execution_transition_class",
    "direct_json_read_status",
    "artifact_value_kind",
    "artifact_top_level_keys",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("registry-home direct-json success reports array", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate.json":
      JSON.stringify([{ id: 1 }, { id: 2 }])
  });

  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate.json"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload({
      normalized_candidate_path: "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate.json",
      destination_class: "registry-home",
      decision: "admitted-registry-home-live-direct-json-read-blocked-before-execution"
    }))
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.artifact_value_kind, "array");
  assert.deepEqual(result.report.artifact_top_level_keys, []);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("direct-json success reports scalar", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json": "true"
  });

  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.artifact_value_kind, "scalar");
  assert.deepEqual(result.report.artifact_top_level_keys, []);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("unsupported classifier transition fails closed", async () => {
  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    runClassifier: () => successRunner(createClassifierPayload({
      execution_transition_class: "blocked-pending-live-directory-read",
      decision: "admitted-queue-home-live-directory-read-blocked-before-execution"
    }))
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "unsupported-transition");
  assert.equal(result.report.failure_scope, "transition");
});

test("missing candidate file returns artifact-missing", async () => {
  const workspaceRoot = await withWorkspace({});

  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "artifact-missing");
  assert.equal(result.report.failure_scope, "artifact");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("malformed candidate file returns artifact-malformed", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json": "{"
  });

  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    workspaceRoot,
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "artifact-malformed");
  assert.equal(result.report.failure_scope, "artifact");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("invalid absolute path input fails before classifier execution", async () => {
  let runnerCalls = 0;
  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "C:\\outside\\candidate.json"
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

test("classifier execution failure never substitutes a read result", async () => {
  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    runClassifier: failureRunner
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "classifier-failed");
  assert.equal(result.report.failure_scope, "classifier");
});

test("text output preserves the bounded direct-json-read contract", async () => {
  const workspaceRoot = await withWorkspace({
    "ops/atlas/runtime_state_execution_ready_transition_semantics.py": [
      "import json",
      "print(json.dumps({",
      "  'normalized_candidate_path': 'runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json',",
      "  'destination_class': 'queue-home',",
      "  'execution_transition_class': 'blocked-pending-live-direct-json-read',",
      "  'decision': 'admitted-queue-home-live-direct-json-read-blocked-before-execution'",
      "}))"
    ].join("\n"),
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json":
      JSON.stringify({ ready: false, reason: "blocked" })
  });

  const scriptPath = path.resolve("scripts/queue-or-registry-live-direct-json-read-follow-on.mjs");
  const child = spawn(process.execPath, [
    scriptPath,
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      STACK_QUEUE_OR_REGISTRY_LIVE_DIRECT_JSON_READ_FOLLOW_ON_WORKSPACE_ROOT: workspaceRoot,
      STACK_QUEUE_OR_REGISTRY_LIVE_DIRECT_JSON_READ_FOLLOW_ON_PYTHON: "python"
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
  assert.match(stdout, /normalized_candidate_path=runtime\/state\/ai-long-run-batch-orchestration\/queue-or-registry\/queue-home\/candidate.json/);
  assert.match(stdout, /direct_json_read_status=readable-direct-json-candidate/);
  assert.match(stdout, /artifact_value_kind=object/);
  assert.match(stdout, /artifact_top_level_keys=\["ready","reason"\]/);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});
