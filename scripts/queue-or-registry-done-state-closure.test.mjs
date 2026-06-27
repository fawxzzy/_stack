import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryDoneStateClosureCommand
} from "./queue-or-registry-done-state-closure.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for done-state tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(callback) {
  const supportRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-done-state-closure-")
  );
  const fixtureName = path.basename(supportRoot);
  const relativeSupportRoot = path.relative(workspaceRoot, supportRoot).replaceAll("\\", "/");
  const claimedQueueRootRef = `repos/_stack/queue/claimed/${fixtureName}`;
  const claimedQueueRootPath = path.join(workspaceRoot, claimedQueueRootRef);
  const claimedQueueDropRef = `${claimedQueueRootRef}/20260613-done-drop.md`;
  const claimedQueueDropPath = path.join(workspaceRoot, claimedQueueDropRef);
  const doneQueueRootRef = `repos/_stack/queue/done/${fixtureName}`;
  const doneQueueRootPath = path.join(workspaceRoot, doneQueueRootRef);
  const doneQueueDropPath = path.join(doneQueueRootPath, "20260613-done-drop.md");
  const workerAssignmentRef = `${relativeSupportRoot}/worker.assignment.json`;
  const workerAssignmentPath = path.join(workspaceRoot, workerAssignmentRef);
  const workerCompletedStatusRef = `${relativeSupportRoot}/worker.status.completed.json`;
  const workerCompletedStatusPath = path.join(workspaceRoot, workerCompletedStatusRef);

  try {
    await fs.mkdir(supportRoot, { recursive: true });
    await fs.mkdir(claimedQueueRootPath, { recursive: true });

    return await callback({
      supportRoot,
      claimedQueueDropRef,
      claimedQueueDropPath,
      doneQueueRootRef,
      doneQueueRootPath,
      doneQueueDropPath,
      workerAssignmentRef,
      workerAssignmentPath,
      workerCompletedStatusRef,
      workerCompletedStatusPath
    });
  } finally {
    await fs.rm(supportRoot, { recursive: true, force: true });
    await fs.rm(claimedQueueRootPath, { recursive: true, force: true });
    await fs.rm(doneQueueRootPath, { recursive: true, force: true });
  }
}

function claimedQueueDropMarkdown(stackLockDigest, overrides = {}) {
  const {
    toolId = "read_only_scan",
    registryDigest = "sha256:done-state-test"
  } = overrides;

  return [
    "Title: Queue done-state test",
    "Branch: queue-done-state-test",
    "HandoffRefs: tmp/claim-movement-report.json",
    "QueryTerms: queue done, closure",
    "TaskTags: queue, done, closure",
    `Stack Lock Digest: ${stackLockDigest}`,
    `Tool Id: ${toolId}`,
    `Registry Digest: ${registryDigest}`,
    "",
    "Objective",
    "Move one explicit claimed queue drop into one bounded done queue home.",
    "",
    "Verification",
    "- node --test scripts/queue-or-registry-done-state-closure.test.mjs"
  ].join("\n");
}

function workerAssignment(stackLockDigest, overrides = {}) {
  return {
    contract_version: "atlas.worker.assignment.v1",
    assignment_id: "assignment-done-state-001",
    worker_id: "worker-done-state-001",
    task_id: "queue-or-registry-done-state-closure",
    stack_lock_digest: stackLockDigest,
    allowed_globs: ["repos/_stack/**"],
    forbidden_globs: ["secrets/**"],
    input_handoff_refs: ["tmp/claim-movement-report.json"],
    expected_outputs: ["repos/_stack/queue/done/example/20260613-done-drop.md"],
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:done-state-test",
    ...overrides
  };
}

function workerCompletedStatus(stackLockDigest, overrides = {}) {
  return {
    contract_version: "atlas.worker.status.v1",
    worker_id: "worker-done-state-001",
    assignment_id: "assignment-done-state-001",
    state: "completed",
    heartbeat_at: "2026-06-13T23:40:00Z",
    touched_ranges: [
      {
        repo_path: ".",
        repo_commit: "stack@sha256:done-state",
        file_digest_before: "sha256:before",
        path: "scripts/queue-or-registry-done-state-closure.mjs",
        start_line: 1,
        end_line: 5,
        op: "modify"
      }
    ],
    output_refs: ["tmp/claim-movement-report.json"],
    blocked_reason: null,
    merge_request_ref: null,
    stack_lock_digest: stackLockDigest,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:done-state-test",
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
    "normalized_claimed_queue_drop_ref",
    "normalized_worker_assignment_ref",
    "normalized_worker_completed_status_ref",
    "normalized_done_queue_root_ref",
    "done_queue_drop_ref",
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
    "normalized_claimed_queue_drop_ref",
    "normalized_worker_assignment_ref",
    "normalized_worker_completed_status_ref",
    "normalized_done_queue_root_ref",
    "done_queue_drop_ref",
    "stack_lock_digest",
    "result_class",
    "payload"
  ]) {
    assert.equal(Object.hasOwn(report, field), false, `failure report must omit ${field}`);
  }
}

test("success moves one explicit claimed drop into one bounded done queue home", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    doneQueueDropPath,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, true);
    assertRequiredSuccessFields(result.report);
    assert.equal(result.report.command, "stack queue-or-registry done-state-closure");
    assert.equal(result.report.normalized_claimed_queue_drop_ref, claimedQueueDropRef);
    assert.equal(result.report.normalized_done_queue_root_ref, doneQueueRootRef);
    assert.equal(
      result.report.done_queue_drop_ref,
      `${doneQueueRootRef}/20260613-done-drop.md`
    );
    assert.equal(result.report.result_class, "done-closed");
    assert.equal(
      result.report.routing_note,
      "explicit claimed drop moved to done only for one completed worker; no merge-closure, resume-closure, or publication proof is implied"
    );
    assert.equal(result.report.payload.done_state_closure_artifact.worker_id, "worker-done-state-001");
    assert.equal(result.report.payload.done_state_closure_artifact.assignment_id, "assignment-done-state-001");

    await assert.rejects(fs.access(claimedQueueDropPath));
    const doneMarkdown = await fs.readFile(doneQueueDropPath, "utf8");
    assert.match(doneMarkdown, /Queue done-state test/);
  });
});

test("invalid claimed queue drop fails closed when the path leaves the admitted claimed queue boundary", async () => {
  const result = await runQueueOrRegistryDoneStateClosureCommand([
    "--format",
    "json",
    "--claimed-queue-drop",
    "tmp/not-allowed.md",
    "--worker-assignment",
    "tmp/worker.assignment.json",
    "--worker-completed-status",
    "tmp/worker.status.completed.json",
    "--done-queue-root",
    "repos/_stack/queue/done/test-root"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-claimed-queue-drop");
  assert.equal(result.report.failure_scope, "claimed-queue-drop");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("invalid worker assignment fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, { contract_version: "wrong-contract" });
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
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
  const result = await runQueueOrRegistryDoneStateClosureCommand([
    "--format",
    "json",
    "--claimed-queue-drop",
    "repos/_stack/queue/claimed/test/20260613-done-drop.md",
    "--worker-assignment",
    path.join(workspaceRoot, "tmp", "worker.assignment.json"),
    "--worker-completed-status",
    "tmp/worker.status.completed.json",
    "--done-queue-root",
    "repos/_stack/queue/done/test-root"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-worker-assignment");
  assert.equal(result.report.failure_scope, "worker-assignment");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("invalid worker completed-status fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(
      workerCompletedStatusPath,
      workerCompletedStatus(stackLockDigest, { state: "running" })
    );

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-worker-completed-status");
    assert.equal(result.report.failure_scope, "worker-completed-status");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("invalid done queue root fails when the path leaves the admitted done queue boundary", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      "tmp/not-allowed"
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-done-queue-root");
    assert.equal(result.report.failure_scope, "done-queue-root");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("lineage mismatch fails when the claimed drop contradicts governed lineage", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(
      claimedQueueDropPath,
      claimedQueueDropMarkdown(stackLockDigest, { registryDigest: "sha256:wrong-registry" }),
      "utf8"
    );
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "lineage-mismatch");
    assert.equal(result.report.failure_scope, "lineage");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("lineage mismatch fails when completed status contradicts the current stack lock digest", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(
      workerCompletedStatusPath,
      workerCompletedStatus(stackLockDigest, {
        stack_lock_digest: "sha256:contradictory-completed-status"
      })
    );

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "lineage-mismatch");
    assert.equal(result.report.failure_scope, "lineage");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("completed worker mismatch fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(
      workerCompletedStatusPath,
      workerCompletedStatus(stackLockDigest, { worker_id: "worker-done-state-999" })
    );

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "completed-worker-mismatch");
    assert.equal(result.report.failure_scope, "completed-worker");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("done close failure reports done-close-failed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    doneQueueRootPath,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));
    await fs.mkdir(path.dirname(doneQueueRootPath), { recursive: true });
    await fs.writeFile(doneQueueRootPath, "not-a-directory", "utf8");

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "done-close-failed");
    assert.equal(result.report.failure_scope, "done-output");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("malformed done output fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot,
      closeDone: async () => ({
        ok: true,
        payload: {
          done_queue_drop_ref: `${doneQueueRootRef}/wrong-name.md`,
          done_state_closure_artifact: {
            drop_file_name: "wrong-name.md",
            worker_id: "worker-done-state-001",
            assignment_id: "assignment-done-state-001",
            source_artifact_refs: [
              claimedQueueDropRef,
              workerAssignmentRef,
              workerCompletedStatusRef
            ]
          }
        }
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "malformed-done-output");
    assert.equal(result.report.failure_scope, "done-output");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("malformed done output fails closed when required done artifact fields are missing", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));

    const result = await runQueueOrRegistryDoneStateClosureCommand([
      "--format",
      "json",
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      workspaceRoot,
      closeDone: async () => ({
        ok: true,
        payload: {
          done_queue_drop_ref: `${doneQueueRootRef}/20260613-done-drop.md`,
          done_state_closure_artifact: {
            drop_file_name: "20260613-done-drop.md",
            worker_id: "worker-done-state-001",
            assignment_id: "assignment-done-state-001",
            source_artifact_refs: "not-an-array"
          }
        }
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "malformed-done-output");
    assert.equal(result.report.failure_scope, "done-output");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("text output preserves the bounded done-state success contract", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    claimedQueueDropRef,
    claimedQueueDropPath,
    doneQueueRootRef,
    workerAssignmentRef,
    workerAssignmentPath,
    workerCompletedStatusRef,
    workerCompletedStatusPath
  }) => {
    await fs.writeFile(claimedQueueDropPath, claimedQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(workerAssignmentPath, workerAssignment(stackLockDigest));
    await writeJson(workerCompletedStatusPath, workerCompletedStatus(stackLockDigest));

    const scriptPath = path.resolve("scripts/queue-or-registry-done-state-closure.mjs");
    const child = spawn(process.execPath, [
      scriptPath,
      "--claimed-queue-drop",
      claimedQueueDropRef,
      "--worker-assignment",
      workerAssignmentRef,
      "--worker-completed-status",
      workerCompletedStatusRef,
      "--done-queue-root",
      doneQueueRootRef
    ], {
      cwd: path.resolve("."),
      env: {
        ...process.env,
        STACK_QUEUE_OR_REGISTRY_DONE_STATE_CLOSURE_WORKSPACE_ROOT: workspaceRoot
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
    assert.match(stdout, /normalized_claimed_queue_drop_ref=repos\/_stack\/queue\/claimed\//);
    assert.match(stdout, /normalized_done_queue_root_ref=repos\/_stack\/queue\/done\//);
    assert.match(stdout, /done_queue_drop_ref=repos\/_stack\/queue\/done\//);
    assert.match(stdout, /result_class=done-closed/);
  });
});
