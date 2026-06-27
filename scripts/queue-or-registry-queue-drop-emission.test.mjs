import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryQueueDropEmissionCommand
} from "./queue-or-registry-queue-drop-emission.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for queue-drop tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(files, callback) {
  const fixtureRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-queue-drop-emission-")
  );
  const pendingQueueRootName = path.basename(fixtureRoot);
  const pendingQueueRootRef = `repos/_stack/queue/pending/${pendingQueueRootName}`;
  const pendingQueueRootPath = path.join(workspaceRoot, pendingQueueRootRef);

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
      pendingQueueRootRef,
      pendingQueueRootPath
    });
  } finally {
    await fs.rm(fixtureRoot, { recursive: true, force: true });
    await fs.rm(pendingQueueRootPath, { recursive: true, force: true });
  }
}

function validExecutionBridgeReport(stackLockDigest) {
  return {
    ok: true,
    report: {
      command: "stack queue-or-registry execution-bridge-artifacts",
      normalized_worker_assignment_ref: "tmp/worker-assignment.json",
      normalized_worker_status_ref: "tmp/worker-status.json",
      normalized_capability_profile_ref: "tmp/capability-profile.json",
      normalized_request_ref: "tmp/request.json",
      normalized_approval_receipt_ref: "tmp/approval.json",
      normalized_receipt_output_root_ref: "runtime/lifeline/worker-execution/fixture-root",
      receipt_ref: "runtime/lifeline/worker-execution/fixture-root/receipt.json",
      worker_status_update_ref: "tmp/worker.status.execution.json",
      bridge_record_ref: "tmp/worker.execution.json",
      stack_lock_digest: stackLockDigest,
      result_class: "execution-bridge-succeeded",
      routing_note: "explicit receipt-backed execution bridge succeeded; no queue or dispatch behavior is implied",
      payload: {
        execution_bridge_artifact: {
          worker_id: "worker-queue-drop-001",
          assignment_id: "assignment-queue-drop-001",
          stack_lock_digest: stackLockDigest,
          request_ref: "tmp/request.json",
          approval_receipt_ref: "tmp/approval.json",
          capability_profile_ref: "tmp/capability-profile.json",
          receipt_ref: "runtime/lifeline/worker-execution/fixture-root/receipt.json",
          worker_status_update_ref: "tmp/worker.status.execution.json",
          bridge_record_ref: "tmp/worker.execution.json",
          tool_id: "read_only_scan",
          extension_id: null,
          registry_digest: "sha256:queue-drop-test",
          result: "succeeded",
          approval_status: "approved",
          execution_mode: "read_only_scan",
          lifeline_exit_code: 0
        }
      }
    }
  };
}

function queueDropInput(stackLockDigest, overrides = {}) {
  return {
    drop_file_name: "20260613-queue-drop-test.md",
    markdown_body: [
      "Task Class: operator-workflow",
      "Target: stack",
      "Working Directory: repos/_stack",
      "Allowed Edit Surface:",
      "- repos/_stack/**",
      "",
      "Objective",
      "Emit one bounded pending queue drop.",
      "",
      "Verification",
      "- node --test scripts/queue-or-registry-queue-drop-emission.test.mjs"
    ].join("\n"),
    stack_lock_digest: stackLockDigest,
    source_artifact_refs: [
      "tmp/execution-bridge-report.json",
      "docs/ops/_STACK-READINESS-STACK-QUEUE-OR-REGISTRY-QUEUE-DROP-EMISSION-FIRST-IMPLEMENTATION-SLICE-AND-PROOF-MATRIX-ADMISSION-PASS-173-2026-06-13.md"
    ],
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:queue-drop-test",
    ...overrides
  };
}

function assertRequiredSuccessFields(report) {
  for (const field of [
    "command",
    "normalized_execution_bridge_report_ref",
    "normalized_queue_drop_input_ref",
    "normalized_pending_queue_root_ref",
    "emitted_queue_drop_ref",
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
    "normalized_execution_bridge_report_ref",
    "normalized_queue_drop_input_ref",
    "normalized_pending_queue_root_ref",
    "emitted_queue_drop_ref",
    "stack_lock_digest",
    "result_class",
    "payload"
  ]) {
    assert.equal(Object.hasOwn(report, field), false, `failure report must omit ${field}`);
  }
}

test("success emits one bounded queue drop into the admitted pending queue root", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef, pendingQueueRootPath }) => {
      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assertRequiredSuccessFields(result.report);
      assert.equal(result.report.command, "stack queue-or-registry queue-drop-emission");
      assert.equal(result.report.normalized_pending_queue_root_ref, pendingQueueRootRef);
      assert.equal(
        result.report.emitted_queue_drop_ref,
        `${pendingQueueRootRef}/20260613-queue-drop-test.md`
      );
      assert.equal(result.report.result_class, "queue-drop-emitted");
      assert.equal(
        result.report.routing_note,
        "explicit queue drop emitted to pending only; no claim or dispatch behavior is implied"
      );
      assert.equal(
        result.report.payload.queue_drop_artifact.drop_file_name,
        "20260613-queue-drop-test.md"
      );

      const emittedMarkdown = await fs.readFile(
        path.join(pendingQueueRootPath, "20260613-queue-drop-test.md"),
        "utf8"
      );
      assert.match(emittedMarkdown, /Task Class: operator-workflow/);
      assert.match(emittedMarkdown, /Objective/);
    }
  );
});

test("invalid execution-bridge report fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify({ ok: true, report: { command: "wrong-command" } }, null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef }) => {
      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-execution-bridge-report");
      assert.equal(result.report.failure_scope, "execution-bridge-report");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("invalid queue-drop input fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest, {
        drop_file_name: "nested/not-allowed.md"
      }), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef }) => {
      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-queue-drop-input");
      assert.equal(result.report.failure_scope, "queue-drop-input");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("invalid pending queue root fails when the path leaves the admitted pending queue boundary", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        `${relativeRoot}/not-allowed`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-pending-queue-root");
      assert.equal(result.report.failure_scope, "pending-queue-root");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("absolute execution-bridge-report path fails before any file loading", async () => {
  const result = await runQueueOrRegistryQueueDropEmissionCommand([
    "--format",
    "json",
    "--execution-bridge-report",
    path.resolve("tmp", "execution-bridge-report.json"),
    "--queue-drop-input",
    "tmp/queue-drop-input.json",
    "--pending-queue-root",
    "repos/_stack/queue/pending/test-root"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-execution-bridge-report");
  assert.equal(result.report.failure_scope, "execution-bridge-report");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("lineage mismatch fails when the queue-drop input contradicts governed lineage", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest, {
        registry_digest: "sha256:wrong-registry"
      }), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef }) => {
      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "lineage-mismatch");
      assert.equal(result.report.failure_scope, "lineage");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("queue-drop write failure reports queue-drop-write-failed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef, pendingQueueRootPath }) => {
      await fs.mkdir(path.dirname(pendingQueueRootPath), { recursive: true });
      await fs.writeFile(pendingQueueRootPath, "not-a-directory", "utf8");

      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "queue-drop-write-failed");
      assert.equal(result.report.failure_scope, "queue-drop-output");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("malformed queue-drop output fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef }) => {
      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        workspaceRoot,
        writeQueueDrop: async () => ({
          ok: true,
          payload: {
            emitted_queue_drop_ref: `${pendingQueueRootRef}/wrong-name.md`,
            queue_drop_artifact: {
              drop_file_name: "wrong-name.md",
              source_artifact_refs: ["tmp/execution-bridge-report.json"]
            }
          }
        })
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "malformed-queue-drop-output");
      assert.equal(result.report.failure_scope, "queue-drop-output");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("writer output that omits the required queue-drop artifact contract fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef }) => {
      const result = await runQueueOrRegistryQueueDropEmissionCommand([
        "--format",
        "json",
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        workspaceRoot,
        writeQueueDrop: async () => ({
          ok: true,
          payload: {
            emitted_queue_drop_ref: `${pendingQueueRootRef}/20260613-queue-drop-test.md`
          }
        })
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "malformed-queue-drop-output");
      assert.equal(result.report.failure_scope, "queue-drop-output");
      assertSuccessOnlyFieldsAbsentOnFailure(result.report);
    }
  );
});

test("text output preserves the bounded queue-drop success contract", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "execution-bridge-report.json": JSON.stringify(validExecutionBridgeReport(stackLockDigest), null, 2),
      "queue-drop-input.json": JSON.stringify(queueDropInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, pendingQueueRootRef }) => {
      const scriptPath = path.resolve("scripts/queue-or-registry-queue-drop-emission.mjs");
      const child = spawn(process.execPath, [
        scriptPath,
        "--execution-bridge-report",
        `${relativeRoot}/execution-bridge-report.json`,
        "--queue-drop-input",
        `${relativeRoot}/queue-drop-input.json`,
        "--pending-queue-root",
        pendingQueueRootRef
      ], {
        cwd: path.resolve("."),
        env: {
          ...process.env,
          STACK_QUEUE_OR_REGISTRY_QUEUE_DROP_EMISSION_WORKSPACE_ROOT: workspaceRoot
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
      assert.match(stdout, /normalized_pending_queue_root_ref=repos\/_stack\/queue\/pending\//);
      assert.match(stdout, /result_class=queue-drop-emitted/);
      assert.match(stdout, /emitted_queue_drop_ref=repos\/_stack\/queue\/pending\//);
    }
  );
});
