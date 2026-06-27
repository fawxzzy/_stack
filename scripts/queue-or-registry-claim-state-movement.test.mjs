import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryClaimStateMovementCommand
} from "./queue-or-registry-claim-state-movement.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for claim-state tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(callback) {
  const supportRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-claim-state-movement-")
  );
  const fixtureName = path.basename(supportRoot);
  const relativeSupportRoot = path.relative(workspaceRoot, supportRoot).replaceAll("\\", "/");
  const pendingQueueRootRef = `repos/_stack/queue/pending/${fixtureName}`;
  const pendingQueueRootPath = path.join(workspaceRoot, pendingQueueRootRef);
  const pendingQueueDropRef = `${pendingQueueRootRef}/20260613-claim-drop.md`;
  const pendingQueueDropPath = path.join(workspaceRoot, pendingQueueDropRef);
  const claimedQueueRootRef = `repos/_stack/queue/claimed/${fixtureName}`;
  const claimedQueueRootPath = path.join(workspaceRoot, claimedQueueRootRef);
  const claimedQueueDropPath = path.join(claimedQueueRootPath, "20260613-claim-drop.md");
  const workerAssignmentRef = `${relativeSupportRoot}/worker.assignment.json`;
  const workerAssignmentPath = path.join(workspaceRoot, workerAssignmentRef);
  const workerRunningStatusRef = `${relativeSupportRoot}/worker.status.running.json`;
  const workerRunningStatusPath = path.join(workspaceRoot, workerRunningStatusRef);

  try {
    await fs.mkdir(supportRoot, { recursive: true });
    await fs.mkdir(pendingQueueRootPath, { recursive: true });

    return await callback({
      supportRoot,
      pendingQueueDropRef,
      pendingQueueDropPath,
      claimedQueueRootRef,
      claimedQueueRootPath,
      claimedQueueDropPath,
      workerAssignmentRef,
      workerAssignmentPath,
      workerRunningStatusRef,
      workerRunningStatusPath
    });
  } finally {
    await fs.rm(supportRoot, { recursive: true, force: true });
    await fs.rm(pendingQueueRootPath, { recursive: true, force: true });
    await fs.rm(claimedQueueRootPath, { recursive: true, force: true });
  }
}

function pendingQueueDropMarkdown(stackLockDigest, overrides = {}) {
  const {
    toolId = "read_only_scan",
    registryDigest = "sha256:claim-state-test"
  } = overrides;

  return [
    "Title: Queue claim-state test",
    "Branch: queue-claim-state-test",
    "HandoffRefs: tmp/execution-bridge-report.json",
    "QueryTerms: queue claim, movement",
    "TaskTags: queue, claim, movement",
    `Stack Lock Digest: ${stackLockDigest}`,
    `Tool Id: ${toolId}`,
    `Registry Digest: ${registryDigest}`,
    "",
    "Objective",
    "Move one explicit pending queue drop into one bounded claimed queue home.",
    "",
    "Verification",
    "- node --test scripts/queue-or-registry-claim-state-movement.test.mjs"
  ].join("\n");
}

function workerAssignment(stackLockDigest, overrides = {}) {
  return {
    contract_version: "atlas.worker.assignment.v1",
    assignment_id: "assignment-claim-state-001",
    worker_id: "worker-claim-state-001",
    task_id: "queue-or-registry-claim-state-movement",
    stack_lock_digest: stackLockDigest,
    allowed_globs: ["repos/_stack/**"],
    forbidden_globs: ["secrets/**"],
    input_handoff_refs: ["tmp/execution-bridge-report.json"],
    expected_outputs: ["repos/_stack/queue/claimed/example/20260613-claim-drop.md"],
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:claim-state-test",
    ...overrides
  };
}

function workerRunningStatus(stackLockDigest, overrides = {}) {
  return {
    contract_version: "atlas.worker.status.v1",
    worker_id: "worker-claim-state-001",
    assignment_id: "assignment-claim-state-001",
    state: "running",
    heartbeat_at: "2026-06-13T23:30:00Z",
    touched_ranges: [],
    output_refs: [],
    blocked_reason: null,
    merge_request_ref: null,
    stack_lock_digest: stackLockDigest,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:claim-state-test",
    ...overrides
  };
}

async function writeJson(filePath, payload) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), "utf8");
}

function assertRequiredSuccessFields(report) {
  for (const field of [
    "command",
    "normalized_pending_queue_drop_ref",
    "normalized_worker_assignment_ref",
    "normalized_worker_running_status_ref",
    "normalized_claimed_queue_root_ref",
    "claimed_queue_drop_ref",
    "stack_lock_digest",
    "result_class",
    "routing_note",
    "payload"
  ]) {
    assert.ok(Object.hasOwn(report, field), `success report must include ${field}`);
  }
}

function assertSuccessOnlyFieldsAbsentOnFailure(report) {
  for (const field of [
    "normalized_pending_queue_drop_ref",
    "normalized_worker_assignment_ref",
    "normalized_worker_running_status_ref",
    "normalized_claimed_queue_root_ref",
    "claimed_queue_drop_ref",
    "stack_lock_digest",
    "result_class",
    "payload"
  ]) {
    assert.equal(Object.hasOwn(report, field), false, `failure report must omit ${field}`);
  }
}

test("success moves one explicit pending drop into one bounded claimed queue home", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    claimedQueueDropPath,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, true);
    assertRequiredSuccessFields(result.report);
    assert.equal(result.report.command, "stack queue-or-registry claim-state movement");
    assert.equal(result.report.normalized_pending_queue_drop_ref, pendingQueueDropRef);
    assert.equal(result.report.normalized_claimed_queue_root_ref, claimedQueueRootRef);
    assert.equal(
      result.report.claimed_queue_drop_ref,
      `${claimedQueueRootRef}/20260613-claim-drop.md`
    );
    assert.equal(result.report.result_class, "claim-moved");
    assert.equal(
      result.report.routing_note,
      "explicit pending drop moved to claimed only for one active worker; no completion or done-state advancement is implied"
    );
    assert.equal(result.report.payload.claim_movement_artifact.worker_id, "worker-claim-state-001");
    assert.equal(result.report.payload.claim_movement_artifact.assignment_id, "assignment-claim-state-001");

    await assert.rejects(fs.access(pendingQueueDropPath));
    const claimedMarkdown = await fs.readFile(claimedQueueDropPath, "utf8");
    assert.match(claimedMarkdown, /Queue claim-state test/);
  });
});

test("invalid pending queue drop fails closed when the path leaves the admitted pending queue boundary", async () => {
  const result = await runQueueOrRegistryClaimStateMovementCommand([
    "--format",
    "json",
    "--pending-queue-drop",
    "tmp/not-allowed.md",
    "--worker-assignment",
    "tmp/worker.assignment.json",
    "--worker-running-status",
    "tmp/worker.status.running.json",
    "--claimed-queue-root",
    "repos/_stack/queue/claimed/test-root"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-pending-queue-drop");
  assert.equal(result.report.failure_scope, "pending-queue-drop");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("invalid worker assignment fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, { contract_version: "wrong-contract" });
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-worker-assignment");
    assert.equal(result.report.failure_scope, "worker-assignment");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("absolute worker assignment path fails closed before loading files", async () => {
  const result = await runQueueOrRegistryClaimStateMovementCommand([
    "--format",
    "json",
    "--pending-queue-drop",
    "repos/_stack/queue/pending/test/20260613-claim-drop.md",
    "--worker-assignment",
    path.join(workspaceRoot, "tmp", "worker.assignment.json"),
    "--worker-running-status",
    "tmp/worker.status.running.json",
    "--claimed-queue-root",
    "repos/_stack/queue/claimed/test-root"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-worker-assignment");
  assert.equal(result.report.failure_scope, "worker-assignment");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("invalid worker running-status fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(
      workerRunningStatusPath,
      workerRunningStatus(stackLockDigest, { state: "paused" })
    );

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-worker-running-status");
    assert.equal(result.report.failure_scope, "worker-running-status");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("invalid claimed queue root fails when the path leaves the admitted claimed queue boundary", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      "tmp/not-allowed"
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-claimed-queue-root");
    assert.equal(result.report.failure_scope, "claimed-queue-root");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("lineage mismatch fails when the pending drop contradicts governed lineage", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(
      pendingQueueDropPath,
      pendingQueueDropMarkdown(stackLockDigest, { registryDigest: "sha256:wrong-registry" }),
      "utf8"
    );
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "lineage-mismatch");
    assert.equal(result.report.failure_scope, "lineage");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("lineage mismatch fails when running status contradicts the current stack lock digest", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(
      workerRunningStatusPath,
      workerRunningStatus(stackLockDigest, {
        stack_lock_digest: "sha256:contradictory-running-status"
      })
    );

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "lineage-mismatch");
    assert.equal(result.report.failure_scope, "lineage");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("active worker mismatch fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(
      workerRunningStatusPath,
      workerRunningStatus(stackLockDigest, { worker_id: "worker-claim-state-999" })
    );

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "active-worker-mismatch");
    assert.equal(result.report.failure_scope, "active-worker");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("claim move failure reports claim-move-failed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    claimedQueueRootPath,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));
    await fs.mkdir(path.dirname(claimedQueueRootPath), { recursive: true });
    await fs.writeFile(claimedQueueRootPath, "not-a-directory", "utf8");

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "claim-move-failed");
    assert.equal(result.report.failure_scope, "claim-output");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("malformed claim output fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot,
      moveClaim: async () => ({
        ok: true,
        payload: {
          claimed_queue_drop_ref: `${claimedQueueRootRef}/wrong-name.md`,
          claim_movement_artifact: {
            drop_file_name: "wrong-name.md",
            worker_id: "worker-claim-state-001",
            assignment_id: "assignment-claim-state-001",
            source_artifact_refs: [
              pendingQueueDropRef,
              workerAssignmentRef,
              workerRunningStatusRef
            ]
          }
        }
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "malformed-claim-output");
    assert.equal(result.report.failure_scope, "claim-output");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("malformed claim output fails closed when required claim artifact fields are missing", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));

    const result = await runQueueOrRegistryClaimStateMovementCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      workspaceRoot,
      moveClaim: async () => ({
        ok: true,
        payload: {
          claimed_queue_drop_ref: `${claimedQueueRootRef}/20260613-claim-drop.md`,
          claim_movement_artifact: {
            drop_file_name: "20260613-claim-drop.md",
            worker_id: "worker-claim-state-001",
            assignment_id: "assignment-claim-state-001",
            source_artifact_refs: "not-an-array"
          }
        }
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "malformed-claim-output");
    assert.equal(result.report.failure_scope, "claim-output");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("text output preserves the bounded claim-state success contract", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    claimedQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerRunningStatusRef,
    workerRunningStatusPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerRunningStatusPath, workerRunningStatus(stackLockDigest));

    const scriptPath = path.resolve("scripts/queue-or-registry-claim-state-movement.mjs");
    const child = spawn(process.execPath, [
      scriptPath,
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-running-status",
      workerRunningStatusRef,
      "--claimed-queue-root",
      claimedQueueRootRef
    ], {
      cwd: path.resolve("."),
      env: {
        ...process.env,
        STACK_QUEUE_OR_REGISTRY_CLAIM_STATE_MOVEMENT_WORKSPACE_ROOT: workspaceRoot
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
    assert.match(stdout, /normalized_pending_queue_drop_ref=repos\/_stack\/queue\/pending\//);
    assert.match(stdout, /normalized_claimed_queue_root_ref=repos\/_stack\/queue\/claimed\//);
    assert.match(stdout, /claimed_queue_drop_ref=repos\/_stack\/queue\/claimed\//);
    assert.match(stdout, /result_class=claim-moved/);
  });
});
