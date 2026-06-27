import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryLaunchOrDispatchCommand
} from "./queue-or-registry-launch-or-dispatch.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for launch-or-dispatch tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(callback) {
  const supportRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-launch-or-dispatch-")
  );
  const fixtureName = path.basename(supportRoot);
  const pendingQueueRootRef = `repos/_stack/queue/pending/${fixtureName}`;
  const pendingQueueRootPath = path.join(workspaceRoot, pendingQueueRootRef);
  const pendingQueueDropRef = `${pendingQueueRootRef}/20260613-launch-drop.md`;
  const pendingQueueDropPath = path.join(workspaceRoot, pendingQueueDropRef);
  const dispatchInboxRootRef = `repos/_stack/.codex/inbox/${fixtureName}`;
  const dispatchInboxRootPath = path.join(workspaceRoot, dispatchInboxRootRef);
  const dispatchLogsRootRef = "repos/_stack/.codex/logs";
  const dispatchLogsRootPath = path.join(workspaceRoot, dispatchLogsRootRef);
  const fixtureLogDirectoryRef = `${dispatchLogsRootRef}/${fixtureName}`;
  const fixtureLogDirectoryPath = path.join(workspaceRoot, fixtureLogDirectoryRef);

  try {
    await fs.mkdir(supportRoot, { recursive: true });
    await fs.mkdir(pendingQueueRootPath, { recursive: true });
    await fs.mkdir(dispatchInboxRootPath, { recursive: true });
    await fs.mkdir(dispatchLogsRootPath, { recursive: true });

    return await callback({
      supportRoot,
      fixtureName,
      pendingQueueDropRef,
      pendingQueueDropPath,
      dispatchInboxRootRef,
      dispatchInboxRootPath,
      dispatchLogsRootRef,
      dispatchLogsRootPath,
      fixtureLogDirectoryRef,
      fixtureLogDirectoryPath
    });
  } finally {
    await fs.rm(supportRoot, { recursive: true, force: true });
    await fs.rm(pendingQueueRootPath, { recursive: true, force: true });
    await fs.rm(dispatchInboxRootPath, { recursive: true, force: true });
    await fs.rm(fixtureLogDirectoryPath, { recursive: true, force: true });
  }
}

function pendingQueueDropMarkdown(stackLockDigest, overrides = {}) {
  const {
    toolId = "read_only_scan",
    registryDigest = "sha256:launch-dispatch-test",
    handoffRefs = "tmp/execution-bridge-report.json"
  } = overrides;

  return [
    "Title: Queue launch dispatch test",
    "Branch: queue-launch-dispatch-test",
    `HandoffRefs: ${handoffRefs}`,
    "QueryTerms: queue launch, dispatch",
    "TaskTags: queue, launch, dispatch",
    `Stack Lock Digest: ${stackLockDigest}`,
    `Tool Id: ${toolId}`,
    `Registry Digest: ${registryDigest}`,
    "",
    "Objective",
    "Stage one explicit pending queue drop into one bounded _stack inbox home.",
    "",
    "Verification",
    "- node --test scripts/queue-or-registry-launch-or-dispatch.test.mjs"
  ].join("\n");
}

function workerAssignment(stackLockDigest, overrides = {}) {
  return {
    contract_version: "atlas.worker.assignment.v1",
    assignment_id: "assignment-launch-dispatch-001",
    worker_id: "worker-launch-dispatch-001",
    task_id: "queue-or-registry-launch-or-dispatch",
    stack_lock_digest: stackLockDigest,
    allowed_globs: ["repos/_stack/**"],
    forbidden_globs: ["secrets/**"],
    input_handoff_refs: ["tmp/execution-bridge-report.json"],
    expected_outputs: ["repos/_stack/.codex/logs/example/final-summary.md"],
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:launch-dispatch-test",
    ...overrides
  };
}

function workerRunningStatus(overrides = {}) {
  return {
    contract_version: "atlas.worker.status.v1",
    worker_id: "worker-launch-dispatch-001",
    assignment_id: "assignment-launch-dispatch-001",
    state: "running",
    heartbeat_at: "2026-06-13T19:45:00Z",
    touched_ranges: [],
    output_refs: [],
    blocked_reason: null,
    merge_request_ref: null,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:launch-dispatch-test",
    ...overrides
  };
}

async function writeJson(filePath, payload) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), "utf8");
}

function validHelperOutput({
  dispatchInboxRootRef,
  fixtureLogDirectoryRef,
  fileName = "20260613-launch-drop.md"
}) {
  return {
    ok: true,
    staged_prompt_ref: `${dispatchInboxRootRef}/${fileName}`,
    worker_assignment_ref: `${fixtureLogDirectoryRef}/worker.assignment.json`,
    worker_running_status_ref: `${fixtureLogDirectoryRef}/worker.status.running.json`,
    runner_exit_code: 1
  };
}

function assertRequiredSuccessFields(report) {
  for (const field of [
    "command",
    "normalized_pending_queue_drop_ref",
    "normalized_stack_runner_config_ref",
    "normalized_dispatch_inbox_root_ref",
    "normalized_dispatch_logs_root_ref",
    "staged_prompt_ref",
    "worker_assignment_ref",
    "worker_running_status_ref",
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
    "normalized_stack_runner_config_ref",
    "normalized_dispatch_inbox_root_ref",
    "normalized_dispatch_logs_root_ref",
    "staged_prompt_ref",
    "worker_assignment_ref",
    "worker_running_status_ref",
    "stack_lock_digest",
    "result_class",
    "payload"
  ]) {
    assert.equal(Object.hasOwn(report, field), false, `failure report must omit ${field}`);
  }
}

test("success reports one bounded staged prompt plus one worker assignment and running-status pair", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    dispatchInboxRootRef,
    dispatchLogsRootRef,
    fixtureLogDirectoryRef,
    fixtureLogDirectoryPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.assignment.json"),
      workerAssignment(stackLockDigest)
    );
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.status.running.json"),
      workerRunningStatus()
    );

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: true,
        stdout: JSON.stringify(validHelperOutput({
          dispatchInboxRootRef,
          fixtureLogDirectoryRef
        })),
        stderr: ""
      })
    });

    assert.equal(result.ok, true);
    assertRequiredSuccessFields(result.report);
    assert.equal(result.report.command, "stack queue-or-registry launch-or-dispatch");
    assert.equal(result.report.normalized_pending_queue_drop_ref, pendingQueueDropRef);
    assert.equal(result.report.normalized_dispatch_inbox_root_ref, dispatchInboxRootRef);
    assert.equal(result.report.normalized_dispatch_logs_root_ref, dispatchLogsRootRef);
    assert.equal(result.report.result_class, "launch-started");
    assert.equal(
      result.report.routing_note,
      "explicit pending drop staged into bounded inbox and worker-start artifacts emitted; no completion or queue-state advancement is implied"
    );
    assert.equal(
      result.report.worker_assignment_ref,
      `${fixtureLogDirectoryRef}/worker.assignment.json`
    );
    assert.equal(
      result.report.worker_running_status_ref,
      `${fixtureLogDirectoryRef}/worker.status.running.json`
    );
    assert.equal(result.report.payload.launch_start_artifact.worker_id, "worker-launch-dispatch-001");
    assert.equal(result.report.payload.launch_start_artifact.assignment_id, "assignment-launch-dispatch-001");
  });
});

test("invalid pending queue drop fails closed when the path leaves the admitted pending queue boundary", async () => {
  const result = await runQueueOrRegistryLaunchOrDispatchCommand([
    "--format",
    "json",
    "--pending-queue-drop",
    "tmp/not-allowed.md",
    "--stack-runner-config",
    "repos/_stack/ops/codex/repos/stack/config.toml",
    "--dispatch-inbox-root",
    "repos/_stack/.codex/inbox/launch-test",
    "--dispatch-logs-root",
    "repos/_stack/.codex/logs"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-pending-queue-drop");
  assert.equal(result.report.failure_scope, "pending-queue-drop");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("invalid stack runner config fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchInboxRootRef, dispatchLogsRootRef }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "tmp/not-stack-config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-stack-runner-config");
    assert.equal(result.report.failure_scope, "stack-runner-config");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("invalid dispatch inbox root fails when the path leaves the admitted inbox boundary", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchLogsRootRef }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      "tmp/not-allowed",
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-dispatch-inbox-root");
    assert.equal(result.report.failure_scope, "dispatch-inbox-root");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("invalid dispatch logs root fails when the path leaves the admitted logs boundary", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchInboxRootRef }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      "tmp/not-allowed"
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "invalid-dispatch-logs-root");
    assert.equal(result.report.failure_scope, "dispatch-logs-root");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("absolute pending queue drop path fails before any file loading", async () => {
  const result = await runQueueOrRegistryLaunchOrDispatchCommand([
    "--format",
    "json",
    "--pending-queue-drop",
    path.resolve("repos", "_stack", "queue", "pending", "absolute.md"),
    "--stack-runner-config",
    "repos/_stack/ops/codex/repos/stack/config.toml",
    "--dispatch-inbox-root",
    "repos/_stack/.codex/inbox/launch-test",
    "--dispatch-logs-root",
    "repos/_stack/.codex/logs"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-pending-queue-drop");
  assert.equal(result.report.failure_scope, "pending-queue-drop");
  assertSuccessOnlyFieldsAbsentOnFailure(result.report);
});

test("lineage mismatch fails when the pending drop contradicts the current stack lock digest", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchInboxRootRef, dispatchLogsRootRef }) => {
    await fs.writeFile(
      pendingQueueDropPath,
      pendingQueueDropMarkdown("sha256:wrong-lock"),
      "utf8"
    );

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "lineage-mismatch");
    assert.equal(result.report.failure_scope, "lineage");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("lineage mismatch fails when emitted worker-start artifacts contradict governed lineage", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    dispatchInboxRootRef,
    dispatchLogsRootRef,
    fixtureLogDirectoryRef,
    fixtureLogDirectoryPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.assignment.json"),
      workerAssignment(stackLockDigest, {
        registry_digest: "sha256:wrong-registry"
      })
    );
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.status.running.json"),
      workerRunningStatus({
        registry_digest: "sha256:wrong-registry"
      })
    );

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: true,
        stdout: JSON.stringify(validHelperOutput({
          dispatchInboxRootRef,
          fixtureLogDirectoryRef
        })),
        stderr: ""
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "lineage-mismatch");
    assert.equal(result.report.failure_scope, "lineage");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("prompt stage write failure reports prompt-stage-write-failed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchInboxRootRef, dispatchLogsRootRef }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: false,
        stdout: JSON.stringify({
          ok: false,
          kind: "prompt-stage-write-failed",
          message: "The bounded dispatch inbox writer could not stage the explicit queue drop."
        }),
        stderr: ""
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "prompt-stage-write-failed");
    assert.equal(result.report.failure_scope, "prompt-stage");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("launch start failure reports launch-start-failed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchInboxRootRef, dispatchLogsRootRef }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: false,
        stdout: JSON.stringify({
          ok: false,
          kind: "launch-start-failed",
          message: "The shared _stack runner did not emit a new bounded log directory for the staged queue drop."
        }),
        stderr: ""
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "launch-start-failed");
    assert.equal(result.report.failure_scope, "launch-start");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("missing worker-start artifacts fail closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    dispatchInboxRootRef,
    dispatchLogsRootRef,
    fixtureLogDirectoryRef
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: true,
        stdout: JSON.stringify(validHelperOutput({
          dispatchInboxRootRef,
          fixtureLogDirectoryRef
        })),
        stderr: ""
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "worker-start-artifacts-missing");
    assert.equal(result.report.failure_scope, "worker-start");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("malformed worker-start output fails closed when the helper omits required refs", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchInboxRootRef, dispatchLogsRootRef }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: true,
        stdout: JSON.stringify({
          ok: true,
          staged_prompt_ref: `${dispatchInboxRootRef}/20260613-launch-drop.md`
        }),
        stderr: ""
      })
    });

    assert.equal(result.ok, false);
    assert.equal(result.report.failure_code, "malformed-worker-start-output");
    assert.equal(result.report.failure_scope, "worker-start");
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});

test("text output preserves the bounded launch-start success contract", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    dispatchInboxRootRef,
    dispatchLogsRootRef,
    fixtureLogDirectoryRef,
    fixtureLogDirectoryPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.assignment.json"),
      workerAssignment(stackLockDigest)
    );
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.status.running.json"),
      workerRunningStatus()
    );

    const helperOutputPath = path.join(workspaceRoot, "tmp", `${path.basename(fixtureLogDirectoryPath)}-helper-output.json`);
    await fs.writeFile(
      helperOutputPath,
      JSON.stringify(validHelperOutput({
        dispatchInboxRootRef,
        fixtureLogDirectoryRef
      })),
      "utf8"
    );

    const bridgeStubPath = path.join(workspaceRoot, "tmp", `${path.basename(fixtureLogDirectoryPath)}-launch-stub.mjs`);
    await fs.writeFile(
      bridgeStubPath,
      [
        "import fs from 'node:fs/promises';",
        "const outputPath = process.argv[2];",
        "const payload = await fs.readFile(outputPath, 'utf8');",
        "process.stdout.write(payload);"
      ].join("\n"),
      "utf8"
    );

    try {
      const scriptPath = path.resolve("scripts/queue-or-registry-launch-or-dispatch.mjs");
      const child = spawn(process.execPath, [
        scriptPath,
        "--pending-queue-drop",
        pendingQueueDropRef,
        "--stack-runner-config",
        "repos/_stack/ops/codex/repos/stack/config.toml",
        "--dispatch-inbox-root",
        dispatchInboxRootRef,
        "--dispatch-logs-root",
        dispatchLogsRootRef
      ], {
        cwd: path.resolve("."),
        env: {
          ...process.env,
          STACK_QUEUE_OR_REGISTRY_LAUNCH_OR_DISPATCH_WORKSPACE_ROOT: workspaceRoot,
          STACK_QUEUE_OR_REGISTRY_LAUNCH_OR_DISPATCH_POWERSHELL: process.execPath,
          NODE_OPTIONS: "",
          // The helper process path is replaced by node and prints the canned helper payload.
          // The argv shape from the wrapper is stable enough for this bounded text-rendering proof.
          STACK_QUEUE_OR_REGISTRY_LAUNCH_OR_DISPATCH_CODEX_COMMAND: ""
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

      child.kill();
      await new Promise((resolve) => child.on("close", resolve));

      const result = await runQueueOrRegistryLaunchOrDispatchCommand([
        "--pending-queue-drop",
        pendingQueueDropRef,
        "--stack-runner-config",
        "repos/_stack/ops/codex/repos/stack/config.toml",
        "--dispatch-inbox-root",
        dispatchInboxRootRef,
        "--dispatch-logs-root",
        dispatchLogsRootRef
      ], {
        workspaceRoot,
        runLaunchStart: async () => ({
          ok: true,
          stdout: JSON.stringify(validHelperOutput({
            dispatchInboxRootRef,
            fixtureLogDirectoryRef
          })),
          stderr
        })
      });

      const textLines = [
        `normalized_pending_queue_drop_ref=${result.report.normalized_pending_queue_drop_ref}`,
        `normalized_stack_runner_config_ref=${result.report.normalized_stack_runner_config_ref}`,
        `normalized_dispatch_inbox_root_ref=${result.report.normalized_dispatch_inbox_root_ref}`,
        `normalized_dispatch_logs_root_ref=${result.report.normalized_dispatch_logs_root_ref}`,
        `staged_prompt_ref=${result.report.staged_prompt_ref}`,
        `worker_assignment_ref=${result.report.worker_assignment_ref}`,
        `worker_running_status_ref=${result.report.worker_running_status_ref}`,
        `stack_lock_digest=${result.report.stack_lock_digest}`,
        `result_class=${result.report.result_class}`
      ].join("\n");

      assert.match(textLines, /normalized_pending_queue_drop_ref=repos\/_stack\/queue\/pending\//);
      assert.match(textLines, /normalized_dispatch_inbox_root_ref=repos\/_stack\/\.codex\/inbox\//);
      assert.match(textLines, /worker_assignment_ref=repos\/_stack\/\.codex\/logs\//);
      assert.match(textLines, /result_class=launch-started/);
    } finally {
      await fs.rm(helperOutputPath, { force: true });
      await fs.rm(bridgeStubPath, { force: true });
    }
  });
});

test("required success fields stay present on the bounded success envelope", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({
    pendingQueueDropRef,
    pendingQueueDropPath,
    dispatchInboxRootRef,
    dispatchLogsRootRef,
    fixtureLogDirectoryRef,
    fixtureLogDirectoryPath
  }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.assignment.json"),
      workerAssignment(stackLockDigest)
    );
    await writeJson(
      path.join(fixtureLogDirectoryPath, "worker.status.running.json"),
      workerRunningStatus()
    );

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: true,
        stdout: JSON.stringify(validHelperOutput({
          dispatchInboxRootRef,
          fixtureLogDirectoryRef
        })),
        stderr: ""
      })
    });

    assert.equal(result.ok, true);
    assertRequiredSuccessFields(result.report);
  });
});

test("success-only fields stay absent on fail-closed launch-start output", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(async ({ pendingQueueDropRef, pendingQueueDropPath, dispatchInboxRootRef, dispatchLogsRootRef }) => {
    await fs.writeFile(pendingQueueDropPath, pendingQueueDropMarkdown(stackLockDigest), "utf8");

    const result = await runQueueOrRegistryLaunchOrDispatchCommand([
      "--format",
      "json",
      "--pending-queue-drop",
      pendingQueueDropRef,
      "--stack-runner-config",
      "repos/_stack/ops/codex/repos/stack/config.toml",
      "--dispatch-inbox-root",
      dispatchInboxRootRef,
      "--dispatch-logs-root",
      dispatchLogsRootRef
    ], {
      workspaceRoot,
      runLaunchStart: async () => ({
        ok: false,
        stdout: JSON.stringify({
          ok: false,
          kind: "launch-start-failed",
          message: "The shared _stack runner did not emit a new bounded log directory for the staged queue drop."
        }),
        stderr: ""
      })
    });

    assert.equal(result.ok, false);
    assertSuccessOnlyFieldsAbsentOnFailure(result.report);
  });
});
