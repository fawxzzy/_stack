import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryExecutionBridgeArtifactsCommand
} from "./queue-or-registry-execution-bridge-artifacts.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for execution-bridge tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(files, callback) {
  const fixtureRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-execution-bridge-artifacts-")
  );
  const receiptDirName = path.basename(fixtureRoot);
  const receiptOutputRootRef = `runtime/lifeline/worker-execution/${receiptDirName}`;
  const receiptOutputRootPath = path.join(workspaceRoot, receiptOutputRootRef);

  try {
    for (const [relativePath, content] of Object.entries(files)) {
      const absolutePath = path.join(fixtureRoot, relativePath);
      await fs.mkdir(path.dirname(absolutePath), { recursive: true });
      await fs.writeFile(absolutePath, content, "utf8");
    }

    const relativeRoot = path.relative(workspaceRoot, fixtureRoot).replaceAll("\\", "/");
    return await callback({
      fixtureRoot,
      relativeRoot,
      receiptOutputRootRef,
      receiptOutputRootPath
    });
  } finally {
    await fs.rm(fixtureRoot, { recursive: true, force: true });
    await fs.rm(receiptOutputRootPath, { recursive: true, force: true });
  }
}

function workerAssignment(stackLockDigest) {
  return {
    contract_version: "atlas.worker.assignment.v1",
    assignment_id: "assignment-execution-bridge-001",
    worker_id: "worker-execution-bridge-001",
    task_id: "queue-or-registry-execution-bridge",
    stack_lock_digest: stackLockDigest,
    allowed_globs: ["repos/_stack/**"],
    forbidden_globs: ["secrets/**"],
    input_handoff_refs: ["docs/ops/_STACK-READINESS-STACK-QUEUE-OR-REGISTRY-EXECUTION-BRIDGE-ARTIFACTS-FIRST-IMPLEMENTATION-SLICE-AND-PROOF-MATRIX-ADMISSION-PASS-161-2026-06-13.md"],
    expected_outputs: ["runtime/lifeline/worker-execution/assignment-execution-bridge-001/receipt.json"],
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:execution-bridge-test"
  };
}

function workerStatus() {
  return {
    contract_version: "atlas.worker.status.v1",
    worker_id: "worker-execution-bridge-001",
    assignment_id: "assignment-execution-bridge-001",
    state: "completed",
    heartbeat_at: "2026-06-13T18:30:00Z",
    touched_ranges: [],
    output_refs: ["repos/_stack/.codex/logs/example/final-summary.md"],
    blocked_reason: null,
    merge_request_ref: null,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:execution-bridge-test"
  };
}

function capabilityProfile() {
  return {
    contract_version: "atlas.capability.profile.v1",
    capability_profile_id: "capability-profile-execution-bridge-001",
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:execution-bridge-test",
    allowed_operations: ["read_only_scan"]
  };
}

function request(stackLockDigest, overrides = {}) {
  return {
    contract_version: "atlas.privileged-action.request.v1",
    request_id: "request-execution-bridge-001",
    requested_at: "2026-06-13T18:31:00Z",
    worker_id: "worker-execution-bridge-001",
    assignment_id: "assignment-execution-bridge-001",
    stack_lock_digest: stackLockDigest,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:execution-bridge-test",
    automation_level: "request_action",
    source_refs: ["tmp/request-source.md"],
    action: {
      summary: "Exercise the execution bridge.",
      operation: "read_only_scan",
      command: ["node", "--version"],
      cwd: "."
    },
    requested_capability: {
      contract_version: "atlas.capability.profile.v1",
      capability_profile_id: "capability-profile-execution-bridge-001"
    },
    dry_run_output: "Deterministic fixture output.",
    justification: "Exercise the bounded execution bridge.",
    ...overrides
  };
}

function approvalReceipt(stackLockDigest, overrides = {}) {
  return {
    contract_version: "atlas.approval.receipt.v1",
    approval_receipt_id: "approval-execution-bridge-001",
    request_id: "request-execution-bridge-001",
    worker_id: "worker-execution-bridge-001",
    assignment_id: "assignment-execution-bridge-001",
    stack_lock_digest: stackLockDigest,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:execution-bridge-test",
    automation_level: "approved_action",
    approver: {
      kind: "system",
      name: "execution-bridge-test"
    },
    approval_status: "approved",
    granted_scope: {
      contract_version: "atlas.capability.profile.v1",
      capability_profile_id: "capability-profile-execution-bridge-001"
    },
    expiry_at: "2099-12-31T23:59:59Z",
    request_digest: "sha256:fixture-request",
    issued_at: "2026-06-13T18:32:00Z",
    ...overrides
  };
}

function validBridgePayload({ stackLockDigest, receiptOutputRootRef, result }) {
  return {
    worker_id: "worker-execution-bridge-001",
    assignment_id: "assignment-execution-bridge-001",
    stack_lock_digest: stackLockDigest,
    request_ref: "tmp/request.json",
    approval_receipt_ref: "tmp/approval.json",
    capability_profile_ref: "tmp/capability.json",
    receipt_ref: `${receiptOutputRootRef}/receipt.json`,
    worker_status_update_ref: "tmp/worker.status.execution.receipt-execution-bridge-001.json",
    bridge_record_ref: "tmp/worker.execution.receipt-execution-bridge-001.json",
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:execution-bridge-test",
    result,
    approval_status: result === "blocked" ? "rejected" : "approved",
    execution_mode: "read_only_scan",
    lifeline_exit_code: result === "failed" ? 1 : 0
  };
}

function assertRequiredSuccessFields(report) {
  for (const field of [
    "command",
    "normalized_worker_assignment_ref",
    "normalized_worker_status_ref",
    "normalized_capability_profile_ref",
    "normalized_request_ref",
    "normalized_approval_receipt_ref",
    "normalized_receipt_output_root_ref",
    "receipt_ref",
    "worker_status_update_ref",
    "bridge_record_ref",
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
    "normalized_worker_assignment_ref",
    "normalized_worker_status_ref",
    "normalized_capability_profile_ref",
    "normalized_request_ref",
    "normalized_approval_receipt_ref",
    "normalized_receipt_output_root_ref",
    "receipt_ref",
    "worker_status_update_ref",
    "bridge_record_ref",
    "stack_lock_digest",
    "result_class",
    "payload"
  ]) {
    assert.equal(Object.hasOwn(report, field), false, `failure report must omit ${field}`);
  }
}

async function runValidCommand(runBridge, overrides = {}) {
  const stackLockDigest = await readStackLockDigest();
  return withFixtureEnvironment(
    {
      "worker-assignment.json": JSON.stringify(workerAssignment(stackLockDigest), null, 2),
      "worker-status.json": JSON.stringify(workerStatus(), null, 2),
      "capability-profile.json": JSON.stringify(capabilityProfile(), null, 2),
      "request.json": JSON.stringify(request(stackLockDigest, overrides.request), null, 2),
      "approval.json": JSON.stringify(approvalReceipt(stackLockDigest, overrides.approval), null, 2)
    },
    async ({ relativeRoot, receiptOutputRootRef }) =>
      runQueueOrRegistryExecutionBridgeArtifactsCommand([
        "--format",
        "json",
        "--worker-assignment",
        `${relativeRoot}/worker-assignment.json`,
        "--worker-status",
        `${relativeRoot}/worker-status.json`,
        "--capability-profile",
        `${relativeRoot}/capability-profile.json`,
        "--request",
        `${relativeRoot}/request.json`,
        "--approval-receipt",
        `${relativeRoot}/approval.json`,
        "--receipt-output-root",
        receiptOutputRootRef
      ], {
        workspaceRoot,
        runBridge: () => runBridge({ stackLockDigest, receiptOutputRootRef })
      })
  );
}

test("succeeded bridge maps to the bounded success contract", async () => {
  const result = await runValidCommand(({ stackLockDigest, receiptOutputRootRef }) => ({
    ok: true,
    exitCode: 0,
    stdout: JSON.stringify(validBridgePayload({
      stackLockDigest,
      receiptOutputRootRef,
      result: "succeeded"
    })),
    stderr: ""
  }));

  assert.equal(result.ok, true);
  assertRequiredSuccessFields(result.report);
  assert.equal(result.report.command, "stack queue-or-registry execution-bridge-artifacts");
  assert.equal(result.report.result_class, "execution-bridge-succeeded");
  assert.equal(
    result.report.routing_note,
    "explicit receipt-backed execution bridge succeeded; no queue or dispatch behavior is implied"
  );
  assert.equal(result.report.payload.execution_bridge_artifact.result, "succeeded");
});

test("blocked bridge maps to the bounded blocked contract", async () => {
  const result = await runValidCommand(({ stackLockDigest, receiptOutputRootRef }) => ({
    ok: true,
    exitCode: 0,
    stdout: JSON.stringify(validBridgePayload({
      stackLockDigest,
      receiptOutputRootRef,
      result: "blocked"
    })),
    stderr: ""
  }));

  assert.equal(result.ok, true);
  assert.equal(result.report.result_class, "execution-bridge-blocked");
  assert.equal(
    result.report.routing_note,
    "explicit receipt-backed execution bridge blocked; treat approval or receipt blocker as execution truth only"
  );
  assert.equal(result.report.payload.execution_bridge_artifact.result, "blocked");
});

test("failed bridge maps to the bounded failed contract", async () => {
  const result = await runValidCommand(({ stackLockDigest, receiptOutputRootRef }) => ({
    ok: true,
    exitCode: 0,
    stdout: JSON.stringify(validBridgePayload({
      stackLockDigest,
      receiptOutputRootRef,
      result: "failed"
    })),
    stderr: ""
  }));

  assert.equal(result.ok, true);
  assert.equal(result.report.result_class, "execution-bridge-failed");
  assert.equal(
    result.report.routing_note,
    "explicit receipt-backed execution bridge failed; repair the receipt-backed execution chain before wider orchestration claims"
  );
  assert.equal(result.report.payload.execution_bridge_artifact.result, "failed");
});

test("invalid worker assignment fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "worker-assignment.json": JSON.stringify({ contract_version: "wrong" }, null, 2),
      "worker-status.json": JSON.stringify(workerStatus(), null, 2),
      "capability-profile.json": JSON.stringify(capabilityProfile(), null, 2),
      "request.json": JSON.stringify(request(stackLockDigest), null, 2),
      "approval.json": JSON.stringify(approvalReceipt(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, receiptOutputRootRef }) => {
      const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand([
        "--format",
        "json",
        "--worker-assignment",
        `${relativeRoot}/worker-assignment.json`,
        "--worker-status",
        `${relativeRoot}/worker-status.json`,
        "--capability-profile",
        `${relativeRoot}/capability-profile.json`,
        "--request",
        `${relativeRoot}/request.json`,
        "--approval-receipt",
        `${relativeRoot}/approval.json`,
        "--receipt-output-root",
        receiptOutputRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-worker-assignment");
      assert.equal(result.report.failure_scope, "worker-assignment");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("invalid worker status fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "worker-assignment.json": JSON.stringify(workerAssignment(stackLockDigest), null, 2),
      "worker-status.json": JSON.stringify({ contract_version: "atlas.worker.status.v1" }, null, 2),
      "capability-profile.json": JSON.stringify(capabilityProfile(), null, 2),
      "request.json": JSON.stringify(request(stackLockDigest), null, 2),
      "approval.json": JSON.stringify(approvalReceipt(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, receiptOutputRootRef }) => {
      const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand([
        "--format",
        "json",
        "--worker-assignment",
        `${relativeRoot}/worker-assignment.json`,
        "--worker-status",
        `${relativeRoot}/worker-status.json`,
        "--capability-profile",
        `${relativeRoot}/capability-profile.json`,
        "--request",
        `${relativeRoot}/request.json`,
        "--approval-receipt",
        `${relativeRoot}/approval.json`,
        "--receipt-output-root",
        receiptOutputRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-worker-status");
      assert.equal(result.report.failure_scope, "worker-status");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("invalid capability profile fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "worker-assignment.json": JSON.stringify(workerAssignment(stackLockDigest), null, 2),
      "worker-status.json": JSON.stringify(workerStatus(), null, 2),
      "capability-profile.json": JSON.stringify({ contract_version: "atlas.capability.profile.v1" }, null, 2),
      "request.json": JSON.stringify(request(stackLockDigest), null, 2),
      "approval.json": JSON.stringify(approvalReceipt(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, receiptOutputRootRef }) => {
      const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand([
        "--format",
        "json",
        "--worker-assignment",
        `${relativeRoot}/worker-assignment.json`,
        "--worker-status",
        `${relativeRoot}/worker-status.json`,
        "--capability-profile",
        `${relativeRoot}/capability-profile.json`,
        "--request",
        `${relativeRoot}/request.json`,
        "--approval-receipt",
        `${relativeRoot}/approval.json`,
        "--receipt-output-root",
        receiptOutputRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-capability-profile");
      assert.equal(result.report.failure_scope, "capability-profile");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("invalid request fails closed when the action widens beyond the admitted execution operations", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "worker-assignment.json": JSON.stringify(workerAssignment(stackLockDigest), null, 2),
      "worker-status.json": JSON.stringify(workerStatus(), null, 2),
      "capability-profile.json": JSON.stringify(capabilityProfile(), null, 2),
      "request.json": JSON.stringify(request(stackLockDigest, {
        action: {
          summary: "Widen the execution surface.",
          operation: "launch_worker",
          command: ["node", "--version"],
          cwd: "."
        }
      }), null, 2),
      "approval.json": JSON.stringify(approvalReceipt(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, receiptOutputRootRef }) => {
      const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand([
        "--format",
        "json",
        "--worker-assignment",
        `${relativeRoot}/worker-assignment.json`,
        "--worker-status",
        `${relativeRoot}/worker-status.json`,
        "--capability-profile",
        `${relativeRoot}/capability-profile.json`,
        "--request",
        `${relativeRoot}/request.json`,
        "--approval-receipt",
        `${relativeRoot}/approval.json`,
        "--receipt-output-root",
        receiptOutputRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-request");
      assert.equal(result.report.failure_scope, "request");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("invalid approval receipt fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "worker-assignment.json": JSON.stringify(workerAssignment(stackLockDigest), null, 2),
      "worker-status.json": JSON.stringify(workerStatus(), null, 2),
      "capability-profile.json": JSON.stringify(capabilityProfile(), null, 2),
      "request.json": JSON.stringify(request(stackLockDigest), null, 2),
      "approval.json": JSON.stringify({ contract_version: "atlas.approval.receipt.v1" }, null, 2)
    },
    async ({ relativeRoot, receiptOutputRootRef }) => {
      const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand([
        "--format",
        "json",
        "--worker-assignment",
        `${relativeRoot}/worker-assignment.json`,
        "--worker-status",
        `${relativeRoot}/worker-status.json`,
        "--capability-profile",
        `${relativeRoot}/capability-profile.json`,
        "--request",
        `${relativeRoot}/request.json`,
        "--approval-receipt",
        `${relativeRoot}/approval.json`,
        "--receipt-output-root",
        receiptOutputRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-approval-receipt");
      assert.equal(result.report.failure_scope, "approval-receipt");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("lineage mismatch fails closed", async () => {
  const result = await runValidCommand(
    ({ stackLockDigest, receiptOutputRootRef }) => ({
      ok: true,
      exitCode: 0,
      stdout: JSON.stringify(validBridgePayload({
        stackLockDigest,
        receiptOutputRootRef,
        result: "succeeded"
      })),
      stderr: ""
    }),
    {
      request: {
        assignment_id: "assignment-execution-bridge-999"
      }
    }
  );

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "lineage-mismatch");
  assert.equal(result.report.failure_scope, "lineage");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("invalid receipt output root fails when the path leaves the admitted receipt boundary", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "worker-assignment.json": JSON.stringify(workerAssignment(stackLockDigest), null, 2),
      "worker-status.json": JSON.stringify(workerStatus(), null, 2),
      "capability-profile.json": JSON.stringify(capabilityProfile(), null, 2),
      "request.json": JSON.stringify(request(stackLockDigest), null, 2),
      "approval.json": JSON.stringify(approvalReceipt(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand([
        "--format",
        "json",
        "--worker-assignment",
        `${relativeRoot}/worker-assignment.json`,
        "--worker-status",
        `${relativeRoot}/worker-status.json`,
        "--capability-profile",
        `${relativeRoot}/capability-profile.json`,
        "--request",
        `${relativeRoot}/request.json`,
        "--approval-receipt",
        `${relativeRoot}/approval.json`,
        "--receipt-output-root",
        `${relativeRoot}/not-allowed`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-receipt-output-root");
      assert.equal(result.report.failure_scope, "receipt-output-root");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("absolute worker-assignment path fails before any file loading", async () => {
  const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand([
    "--format",
    "json",
    "--worker-assignment",
    path.resolve("tmp", "worker-assignment.json"),
    "--worker-status",
    "tmp/worker-status.json",
    "--capability-profile",
    "tmp/capability-profile.json",
    "--request",
    "tmp/request.json",
    "--approval-receipt",
    "tmp/approval.json",
    "--receipt-output-root",
    "runtime/lifeline/worker-execution/test-root"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-worker-assignment");
  assert.equal(result.report.failure_scope, "worker-assignment");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("bridge failure reports bridge-failed", async () => {
  const result = await runValidCommand(() => ({
    ok: false,
    exitCode: 1,
    stdout: "",
    stderr: "bridge failed"
  }));

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "bridge-failed");
  assert.equal(result.report.failure_scope, "bridge");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("malformed bridge output fails closed", async () => {
  const result = await runValidCommand(() => ({
    ok: true,
    exitCode: 0,
    stdout: JSON.stringify({ receipt_ref: "runtime/lifeline/worker-execution/test/receipt.json" }),
    stderr: ""
  }));

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "malformed-bridge-output");
  assert.equal(result.report.failure_scope, "bridge");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("bridge output that contradicts the current stack lock digest fails closed", async () => {
  const result = await runValidCommand(({ receiptOutputRootRef }) => ({
    ok: true,
    exitCode: 0,
    stdout: JSON.stringify(validBridgePayload({
      stackLockDigest: "sha256:wrong-lock",
      receiptOutputRootRef,
      result: "succeeded"
    })),
    stderr: ""
  }));

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "malformed-bridge-output");
  assert.equal(result.report.failure_scope, "bridge");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("text output preserves the bounded failure contract without requiring a live bridge", async () => {
  await withFixtureEnvironment({}, async ({ relativeRoot, receiptOutputRootRef }) => {
    const scriptPath = path.resolve("scripts/queue-or-registry-execution-bridge-artifacts.mjs");
    const child = spawn(process.execPath, [
      scriptPath,
      "--worker-assignment",
      `${relativeRoot}/missing-worker-assignment.json`,
      "--worker-status",
      `${relativeRoot}/missing-worker-status.json`,
      "--capability-profile",
      `${relativeRoot}/missing-capability-profile.json`,
      "--request",
      `${relativeRoot}/missing-request.json`,
      "--approval-receipt",
      `${relativeRoot}/missing-approval.json`,
      "--receipt-output-root",
      receiptOutputRootRef
    ], {
      cwd: path.resolve("."),
      env: {
        ...process.env,
        STACK_QUEUE_OR_REGISTRY_EXECUTION_BRIDGE_ARTIFACTS_WORKSPACE_ROOT: workspaceRoot
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

    assert.equal(exitCode, 1, stderr);
    assert.match(stdout, /failure_code=invalid-worker-assignment/);
    assert.match(stdout, /failure_scope=worker-assignment/);
  });
});
