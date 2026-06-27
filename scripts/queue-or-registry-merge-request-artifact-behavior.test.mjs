import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryMergeRequestArtifactBehaviorCommand
} from "./queue-or-registry-merge-request-artifact-behavior.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for merge-request wrapper tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(files, callback) {
  const fixtureRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-merge-request-artifact-")
  );
  const logDirName = path.basename(fixtureRoot);
  const logDirRef = `repos/_stack/.codex/logs/${logDirName}`;
  const logDirPath = path.join(workspaceRoot, logDirRef);

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
      logDirRef,
      logDirPath
    });
  } finally {
    await fs.rm(fixtureRoot, { recursive: true, force: true });
    await fs.rm(logDirPath, { recursive: true, force: true });
  }
}

function mergeRequestInput(stackLockDigest, overrides = {}) {
  return {
    merge_request_id: "merge-request-wrapper-test-001",
    stack_lock_digest: stackLockDigest,
    tool_id: "read_only_scan",
    extension_id: null,
    registry_digest: "sha256:merge-request-wrapper-test",
    conflicting_workers: [
      "worker-merge-a",
      "worker-merge-b"
    ],
    overlaps: [
      {
        repo_path: ".",
        path: "docs/codex-orchestration.md",
        overlap_type: "line_overlap",
        file_digest_before: "sha256:merge-before",
        conflicting_ranges: [
          {
            worker_id: "worker-merge-a",
            start_line: 10,
            end_line: 18,
            op: "modify"
          },
          {
            worker_id: "worker-merge-b",
            start_line: 14,
            end_line: 22,
            op: "modify"
          }
        ],
        reason: "Same file, overlapping line ranges, same file_digest_before."
      }
    ],
    paused_handoff_refs: [
      "repos/_stack/.codex/logs/run-a/handoff-a.json",
      "repos/_stack/.codex/logs/run-b/handoff-b.json"
    ],
    merge_worker_handoff: {
      worker_id: "pending-merge-worker",
      assignment_id: "assignment-merge-request-wrapper-test-001",
      task_id: "merge-merge-request-wrapper-test-001",
      handoff_ref: "runtime/cortex/supervisor/merge-request-wrapper-test-001.merge-handoff.json",
      tool_id: "read_only_scan",
      extension_id: null,
      registry_digest: "sha256:merge-request-wrapper-test"
    },
    notes: "Read-only Cortex supervisor emitted this merge request from worker status and assignment artifacts only.",
    ...overrides
  };
}

function sourceMergeRequestCandidate(artifactInput) {
  return {
    contract_version: "atlas.worker.merge-request.v1",
    ...artifactInput
  };
}

function validSourceReport(stackLockDigest, artifactInput) {
  return {
    schema_version: "atlas.cortex.supervisor.report.v1",
    stack_lock_digest: stackLockDigest,
    status_count: 2,
    valid_status_count: 2,
    invalid_statuses: [],
    forbidden_scope_violations: [],
    merge_requests: [
      sourceMergeRequestCandidate(artifactInput)
    ]
  };
}

test("success emits one bounded worker.merge-request artifact through the admitted builder", async () => {
  const stackLockDigest = await readStackLockDigest();
  const artifactInput = mergeRequestInput(stackLockDigest);
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(stackLockDigest, artifactInput), null, 2),
      "artifact-input.json": JSON.stringify(artifactInput, null, 2)
    },
    async ({ relativeRoot, logDirRef, logDirPath }) => {
      const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand([
        "--format",
        "json",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.command, "stack queue-or-registry merge-request-artifact-behavior");
      assert.equal(result.report.normalized_log_dir_ref, logDirRef);
      assert.equal(result.report.emitted_artifact_ref, `${logDirRef}/worker.merge-request.json`);
      assert.equal(result.report.emitted_contract_version, "atlas.worker.merge-request.v1");
      assert.equal(result.report.result_class, "merge-request-artifact-emitted");
      assert.equal(
        result.report.routing_note,
        "explicit merge-request artifact emitted only; no paused-status, merger-assignment, or resume-ready claim is implied"
      );
      assert.equal(result.report.stack_lock_digest, stackLockDigest);
      assert.equal(result.report.payload.merge_request_artifact.merge_request_id, artifactInput.merge_request_id);

      const emittedArtifact = JSON.parse(
        await fs.readFile(path.join(logDirPath, "worker.merge-request.json"), "utf8")
      );
      assert.equal(emittedArtifact.contract_version, "atlas.worker.merge-request.v1");
      assert.equal(emittedArtifact.merge_request_id, artifactInput.merge_request_id);
      assert.equal(emittedArtifact.conflicting_workers.length, 2);
    }
  );
});

test("invalid source report fails before builder execution", async () => {
  let bridgeCalls = 0;
  const stackLockDigest = await readStackLockDigest();
  const artifactInput = mergeRequestInput(stackLockDigest);
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify({ schema_version: "wrong-version" }, null, 2),
      "artifact-input.json": JSON.stringify(artifactInput, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand([
        "--format",
        "json",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot,
        runBridge: async () => {
          bridgeCalls += 1;
          return { ok: true, stdout: "{}", stderr: "" };
        }
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-source-report");
      assert.equal(bridgeCalls, 0);
    }
  );
});

test("invalid artifact input fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(stackLockDigest, mergeRequestInput(stackLockDigest)), null, 2),
      "artifact-input.json": JSON.stringify({ merge_request_id: "missing-fields" }, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand([
        "--format",
        "json",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-artifact-input");
      assert.equal(result.report.failure_scope, "artifact-input");
    }
  );
});

test("lineage mismatch fails when the source report does not admit the provided merge request", async () => {
  const stackLockDigest = await readStackLockDigest();
  const artifactInput = mergeRequestInput(stackLockDigest);
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(
        validSourceReport(stackLockDigest, mergeRequestInput(stackLockDigest, { registry_digest: "sha256:different" })),
        null,
        2
      ),
      "artifact-input.json": JSON.stringify(artifactInput, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand([
        "--format",
        "json",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "lineage-mismatch");
      assert.equal(result.report.failure_scope, "lineage");
    }
  );
});

test("invalid log dir fails when the path leaves the admitted _stack Codex log boundary", async () => {
  const stackLockDigest = await readStackLockDigest();
  const artifactInput = mergeRequestInput(stackLockDigest);
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(stackLockDigest, artifactInput), null, 2),
      "artifact-input.json": JSON.stringify(artifactInput, null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand([
        "--format",
        "json",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        `${relativeRoot}/not-allowed`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-log-dir");
      assert.equal(result.report.failure_scope, "log-dir");
    }
  );
});

test("builder failure reports builder-failed", async () => {
  const stackLockDigest = await readStackLockDigest();
  const artifactInput = mergeRequestInput(stackLockDigest);
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(stackLockDigest, artifactInput), null, 2),
      "artifact-input.json": JSON.stringify(artifactInput, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand([
        "--format",
        "json",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        logDirRef
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
      assert.equal(result.report.failure_scope, "builder");
    }
  );
});

test("malformed builder output fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  const artifactInput = mergeRequestInput(stackLockDigest);
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(stackLockDigest, artifactInput), null, 2),
      "artifact-input.json": JSON.stringify(artifactInput, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand([
        "--format",
        "json",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot,
        runBridge: async () => ({
          ok: true,
          exitCode: 0,
          stdout: JSON.stringify({ emitted_artifact_ref: "bad" }),
          stderr: ""
        })
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "malformed-artifact-output");
      assert.equal(result.report.failure_scope, "builder");
    }
  );
});

test("text output preserves the bounded merge-request success contract", async () => {
  const stackLockDigest = await readStackLockDigest();
  const artifactInput = mergeRequestInput(stackLockDigest);
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(stackLockDigest, artifactInput), null, 2),
      "artifact-input.json": JSON.stringify(artifactInput, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const scriptPath = path.resolve("scripts/queue-or-registry-merge-request-artifact-behavior.mjs");
      const child = spawn(process.execPath, [
        scriptPath,
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/artifact-input.json`,
        "--log-dir",
        logDirRef
      ], {
        cwd: path.resolve("."),
        env: {
          ...process.env,
          STACK_QUEUE_OR_REGISTRY_MERGE_REQUEST_ARTIFACT_BEHAVIOR_WORKSPACE_ROOT: workspaceRoot
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
      assert.match(stdout, /normalized_source_report_ref=tmp\/stack-merge-request-artifact-/);
      assert.match(stdout, /emitted_artifact_ref=repos\/_stack\/\.codex\/logs\//);
      assert.match(stdout, /result_class=merge-request-artifact-emitted/);
    }
  );
});
