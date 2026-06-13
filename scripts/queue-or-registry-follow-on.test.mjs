import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import { runQueueOrRegistryFollowOnCommand } from "./queue-or-registry-follow-on.mjs";

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
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "stack-queue-or-registry-follow-on-"));
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

test("unresolved destination-root success preserves the bounded contract", async () => {
  const result = await runQueueOrRegistryFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/"
  ], {
    runClassifier: () => successRunner(createClassifierPayload({
      normalized_candidate_path: "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/",
      execution_transition_class: "none",
      decision: "queue-home-destination-root-still-unresolved"
    }))
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.command, "stack queue-or-registry follow-on");
  assert.equal(result.report.classifier_ref, "ops/atlas/runtime_state_execution_ready_transition_semantics.py");
  assert.equal(result.report.follow_on_status, "destination-root-still-unresolved");
  assert.equal(result.report.routing_note, "route to exact-child-path resolution before shared follow-on packaging");
  assertExactKeys(result.report, [
    "command",
    "classifier_ref",
    "normalized_candidate_path",
    "destination_class",
    "execution_transition_class",
    "follow_on_status",
    "routing_note"
  ]);
});

test("blocked direct-json-read success preserves the bounded contract", async () => {
  const result = await runQueueOrRegistryFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    runClassifier: () => successRunner(createClassifierPayload())
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.follow_on_status, "blocked-pending-live-direct-json-read");
  assert.equal(result.report.routing_note, "route to bounded live direct-json-read admission before shared follow-on progress");
});

test("blocked directory-read success preserves the bounded contract", async () => {
  const result = await runQueueOrRegistryFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate-dir/"
  ], {
    runClassifier: () => successRunner(createClassifierPayload({
      normalized_candidate_path: "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/registry-home/candidate-dir/",
      destination_class: "registry-home",
      execution_transition_class: "blocked-pending-live-directory-read",
      decision: "admitted-registry-home-live-directory-read-blocked-before-execution"
    }))
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.follow_on_status, "blocked-pending-live-directory-read");
  assert.equal(result.report.routing_note, "route to bounded live directory-read admission before shared follow-on progress");
});

test("non-admitted transition preserves the bounded stop-and-return contract", async () => {
  const result = await runQueueOrRegistryFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/"
  ], {
    runClassifier: () => successRunner(createClassifierPayload({
      normalized_candidate_path: "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/",
      destination_class: "none",
      execution_transition_class: "none",
      decision: "outside-admitted-neutral-family-root"
    }))
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.follow_on_status, "non-admitted-transition");
  assert.equal(result.report.routing_note, "stop and return; candidate is outside the admitted shared follow-on posture");
});

test("invalid input fails before classifier execution", async () => {
  let runnerCalls = 0;
  const result = await runQueueOrRegistryFollowOnCommand([
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
  assert.equal(result.report.failure_scope, "input");
  assert.equal(runnerCalls, 0);
  assert.match(result.report.message, /--candidate-path must be a bounded relative path\./);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);
});

test("classifier execution failure never substitutes a follow-on result", async () => {
  const result = await runQueueOrRegistryFollowOnCommand([
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
  assert.equal("normalized_candidate_path" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);
});

test("malformed classifier output fails closed", async () => {
  const result = await runQueueOrRegistryFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    runClassifier: () => successRunner({ decision: "admitted-queue-home-live-direct-json-read-blocked-before-execution" })
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "classifier-failed");
  assert.equal(result.report.failure_scope, "classifier");
});

test("unsupported classifier decision fails closed", async () => {
  const result = await runQueueOrRegistryFollowOnCommand([
    "--format",
    "json",
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    runClassifier: () => successRunner(createClassifierPayload({
      decision: "unexpected-new-decision"
    }))
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "classifier-failed");
  assert.equal(result.report.failure_scope, "classifier");
});

test("text output preserves the bounded blocked-direct-read contract", async () => {
  const workspaceRoot = await withWorkspace({
    "ops/atlas/runtime_state_execution_ready_transition_semantics.py": [
      "import json",
      "print(json.dumps({",
      "  'normalized_candidate_path': 'runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json',",
      "  'destination_class': 'queue-home',",
      "  'execution_transition_class': 'blocked-pending-live-direct-json-read',",
      "  'decision': 'admitted-queue-home-live-direct-json-read-blocked-before-execution'",
      "}))"
    ].join("\n")
  });

  const scriptPath = path.resolve("scripts/queue-or-registry-follow-on.mjs");
  const child = spawn(process.execPath, [
    scriptPath,
    "--candidate-path",
    "runtime/state/ai-long-run-batch-orchestration/queue-or-registry/queue-home/candidate.json"
  ], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      STACK_QUEUE_OR_REGISTRY_FOLLOW_ON_WORKSPACE_ROOT: workspaceRoot,
      STACK_QUEUE_OR_REGISTRY_FOLLOW_ON_PYTHON: "python"
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
  assert.match(stdout, /follow_on_status=blocked-pending-live-direct-json-read/);
  assert.match(stdout, /classifier_ref=ops\/atlas\/runtime_state_execution_ready_transition_semantics.py/);
  assert.match(stdout, /routing_note=route to bounded live direct-json-read admission before shared follow-on progress/);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});
