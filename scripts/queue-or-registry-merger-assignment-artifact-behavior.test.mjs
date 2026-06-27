import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand
} from "./queue-or-registry-merger-assignment-artifact-behavior.mjs";
import {
  runQueueOrRegistryPausedStatusArtifactBehaviorCommand
} from "./queue-or-registry-paused-status-artifact-behavior.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for merger-assignment wrapper tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(files, callback) {
  const fixtureRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-merger-assignment-artifact-")
  );

  try {
    for (const [relativePath, content] of Object.entries(files)) {
      const absolutePath = path.join(fixtureRoot, relativePath);
      await fs.mkdir(path.dirname(absolutePath), { recursive: true });
      await fs.writeFile(absolutePath, content, "utf8");
    }

    const relativeRoot = path.relative(workspaceRoot, fixtureRoot).replaceAll("\\", "/");
    return await callback({ relativeRoot });
  } finally {
    await fs.rm(fixtureRoot, { recursive: true, force: true });
  }
}

function assignment(workerId, assignmentId, stackLockDigest, handoffRef) {
  return {
    contract_version: "atlas.worker.assignment.v1",
    assignment_id: assignmentId,
    worker_id: workerId,
    task_id: `task-${workerId}`,
    stack_lock_digest: stackLockDigest,
    allowed_globs: ["repos/_stack/**"],
    forbidden_globs: ["secrets/**"],
    input_handoff_refs: [handoffRef],
    expected_outputs: [`${workerId}.json`],
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:merger-assignment-wrapper-test"
  };
}

function runningStatus(workerId, assignmentId, stackLockDigest, outputRef, pathRef) {
  return {
    contract_version: "atlas.worker.status.v1",
    worker_id: workerId,
    assignment_id: assignmentId,
    state: "running",
    heartbeat_at: "2026-06-14T01:30:00Z",
    touched_ranges: [
      {
        repo_path: ".",
        repo_commit: "stack@sha256:merger-assignment-wrapper-test",
        file_digest_before: "sha256:paused-before",
        path: pathRef,
        start_line: 10,
        end_line: 20,
        op: "modify"
      }
    ],
    output_refs: [outputRef],
    blocked_reason: null,
    merge_request_ref: null,
    stack_lock_digest: stackLockDigest,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:merger-assignment-wrapper-test"
  };
}

function mergeRequest(stackLockDigest) {
  return {
    contract_version: "atlas.worker.merge-request.v1",
    merge_request_id: "merge-request-merger-assignment-wrapper-001",
    stack_lock_digest: stackLockDigest,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:merger-assignment-wrapper-test",
    conflicting_workers: ["worker-paused-a", "worker-paused-b"],
    overlaps: [
      {
        repo_path: ".",
        path: "docs/codex-orchestration.md",
        overlap_type: "line_overlap",
        file_digest_before: "sha256:paused-before",
        conflicting_ranges: [
          {
            worker_id: "worker-paused-a",
            start_line: 10,
            end_line: 18,
            op: "modify"
          },
          {
            worker_id: "worker-paused-b",
            start_line: 14,
            end_line: 22,
            op: "modify"
          }
        ],
        reason: "Same file, overlapping line ranges, same file_digest_before."
      }
    ],
    paused_handoff_refs: [
      "repos/_stack/.codex/logs/worker-a/handoff.json",
      "repos/_stack/.codex/logs/worker-b/handoff.json"
    ],
    merge_worker_handoff: {
      worker_id: "pending-merge-worker",
      assignment_id: "assignment-merge-request-merger-assignment-wrapper-001",
      task_id: "merge-merge-request-merger-assignment-wrapper-001",
      handoff_ref: "runtime/cortex/supervisor/merge-request-merger-assignment-wrapper-001.merge-handoff.json",
      tool_id: "read_only_scan",
      extension_id: null,
      registry_digest: "sha256:merger-assignment-wrapper-test"
    },
    notes: "Read-only Cortex supervisor emitted this merge request from worker status and assignment artifacts only."
  };
}

async function seedPausedStatuses(relativeRoot) {
  const result = await runQueueOrRegistryPausedStatusArtifactBehaviorCommand([
    "--format",
    "json",
    "--merge-request",
    `${relativeRoot}/merge-request.json`,
    "--artifact-search-root",
    `${relativeRoot}/artifacts`
  ], {
    workspaceRoot
  });
  assert.equal(result.ok, true, "paused-status seeding must succeed before merger-assignment tests.");
}

test("success emits merger assignment artifacts after paused statuses exist", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "artifacts/assignment-a.json": JSON.stringify(
        assignment("worker-paused-a", "assignment-paused-a", stackLockDigest, "handoff://paused/a"),
        null,
        2
      ),
      "artifacts/assignment-b.json": JSON.stringify(
        assignment("worker-paused-b", "assignment-paused-b", stackLockDigest, "handoff://paused/b"),
        null,
        2
      ),
      "artifacts/status-a.json": JSON.stringify(
        runningStatus("worker-paused-a", "assignment-paused-a", stackLockDigest, "handoff://paused/a", "docs/codex-orchestration.md"),
        null,
        2
      ),
      "artifacts/status-b.json": JSON.stringify(
        runningStatus("worker-paused-b", "assignment-paused-b", stackLockDigest, "handoff://paused/b", "docs/codex-orchestration.md"),
        null,
        2
      ),
      "merge-request.json": JSON.stringify(mergeRequest(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      await seedPausedStatuses(relativeRoot);

      const result = await runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand([
        "--format",
        "json",
        "--merge-request",
        `${relativeRoot}/merge-request.json`,
        "--artifact-search-root",
        `${relativeRoot}/artifacts`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.result_class, "merger-assignment-artifacts-emitted");
      assert.equal(result.report.stack_lock_digest, stackLockDigest);
      assert.equal(
        result.report.routing_note,
        "explicit merger worker assignment artifacts emitted only from existing paused worker status artifacts; no resume-ready claim is implied"
      );

      const mergeAssignment = JSON.parse(
        await fs.readFile(path.join(workspaceRoot, result.report.merge_assignment_ref), "utf8")
      );
      assert.equal(mergeAssignment.contract_version, "atlas.worker.assignment.v1");
      assert.equal(mergeAssignment.worker_id, "pending-merge-worker");

      const mergePromptText = await fs.readFile(path.join(workspaceRoot, result.report.merge_prompt_ref), "utf8");
      assert.match(mergePromptText, /Resolve merge request/);

      const mergeContext = JSON.parse(
        await fs.readFile(path.join(workspaceRoot, result.report.merge_context_ref), "utf8")
      );
      assert.equal(
        mergeContext.assignment?.assignment_id,
        "assignment-merge-request-merger-assignment-wrapper-001"
      );
    }
  );
});

test("invalid merge request fails closed", async () => {
  await withFixtureEnvironment(
    {
      "artifacts/placeholder.json": JSON.stringify({}, null, 2),
      "merge-request.json": JSON.stringify({ contract_version: "wrong-contract" }, null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand([
        "--format",
        "json",
        "--merge-request",
        `${relativeRoot}/merge-request.json`,
        "--artifact-search-root",
        `${relativeRoot}/artifacts`
      ], { workspaceRoot });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-merge-request");
    }
  );
});

test("invalid artifact search root fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "merge-request.json": JSON.stringify(mergeRequest(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand([
        "--format",
        "json",
        "--merge-request",
        `${relativeRoot}/merge-request.json`,
        "--artifact-search-root",
        `${relativeRoot}/missing-artifacts`
      ], { workspaceRoot });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-artifact-search-root");
    }
  );
});

test("lineage mismatch fails closed", async () => {
  await withFixtureEnvironment(
    {
      "artifacts/placeholder.json": JSON.stringify({}, null, 2),
      "merge-request.json": JSON.stringify(mergeRequest("sha256:contradictory-merger-assignment-lock"), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand([
        "--format",
        "json",
        "--merge-request",
        `${relativeRoot}/merge-request.json`,
        "--artifact-search-root",
        `${relativeRoot}/artifacts`
      ], { workspaceRoot });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "lineage-mismatch");
    }
  );
});

test("builder failure reports builder-failed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "artifacts/placeholder.json": JSON.stringify({}, null, 2),
      "merge-request.json": JSON.stringify(mergeRequest(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand([
        "--format",
        "json",
        "--merge-request",
        `${relativeRoot}/merge-request.json`,
        "--artifact-search-root",
        `${relativeRoot}/artifacts`
      ], {
        workspaceRoot,
        runBridge: async () => ({
          ok: false,
          exitCode: 1,
          stdout: "",
          stderr: "bridge failed"
        })
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "builder-failed");
    }
  );
});

test("malformed builder output fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "artifacts/placeholder.json": JSON.stringify({}, null, 2),
      "merge-request.json": JSON.stringify(mergeRequest(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand([
        "--format",
        "json",
        "--merge-request",
        `${relativeRoot}/merge-request.json`,
        "--artifact-search-root",
        `${relativeRoot}/artifacts`
      ], {
        workspaceRoot,
        runBridge: async () => ({
          ok: true,
          exitCode: 0,
          stdout: JSON.stringify({ merge_assignment_ref: "foo" }),
          stderr: ""
        })
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "malformed-merger-output");
    }
  );
});

test("text output preserves the bounded merger-assignment success contract", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "artifacts/assignment-a.json": JSON.stringify(
        assignment("worker-paused-a", "assignment-paused-a", stackLockDigest, "handoff://paused/a"),
        null,
        2
      ),
      "artifacts/assignment-b.json": JSON.stringify(
        assignment("worker-paused-b", "assignment-paused-b", stackLockDigest, "handoff://paused/b"),
        null,
        2
      ),
      "artifacts/status-a.json": JSON.stringify(
        runningStatus("worker-paused-a", "assignment-paused-a", stackLockDigest, "handoff://paused/a", "docs/codex-orchestration.md"),
        null,
        2
      ),
      "artifacts/status-b.json": JSON.stringify(
        runningStatus("worker-paused-b", "assignment-paused-b", stackLockDigest, "handoff://paused/b", "docs/codex-orchestration.md"),
        null,
        2
      ),
      "merge-request.json": JSON.stringify(mergeRequest(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      await seedPausedStatuses(relativeRoot);

      const scriptPath = path.resolve("scripts/queue-or-registry-merger-assignment-artifact-behavior.mjs");
      const child = spawn(process.execPath, [
        scriptPath,
        "--merge-request",
        `${relativeRoot}/merge-request.json`,
        "--artifact-search-root",
        `${relativeRoot}/artifacts`
      ], {
        cwd: path.resolve("."),
        env: {
          ...process.env,
          STACK_QUEUE_OR_REGISTRY_MERGER_ASSIGNMENT_ARTIFACT_BEHAVIOR_WORKSPACE_ROOT: workspaceRoot
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
      assert.match(stdout, /normalized_merge_request_ref=tmp\/stack-merger-assignment-artifact-/);
      assert.match(stdout, /merge_assignment_ref=/);
      assert.match(stdout, /result_class=merger-assignment-artifacts-emitted/);
    }
  );
});
