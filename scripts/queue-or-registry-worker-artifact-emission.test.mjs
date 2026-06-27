import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryWorkerArtifactEmissionCommand
} from "./queue-or-registry-worker-artifact-emission.mjs";

const workspaceRoot = path.resolve("..", "..");

async function readStackLockDigest() {
  const stackLockPath = path.join(workspaceRoot, "stack.lock.yaml");
  const stackLockText = await fs.readFile(stackLockPath, "utf8");
  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  assert.ok(match, "stack.lock.yaml must expose lock_digest for worker-artifact tests.");
  return match[1].trim();
}

async function withFixtureEnvironment(files, callback) {
  const fixtureRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-worker-artifact-emission-")
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

function validSourceReport() {
  return {
    ok: true,
    report: {
      command: "stack queue-or-registry broader-execution-behavior",
      mode: "validate-entry",
      normalized_input_ref: "tmp/valid.json",
      source_helper_ref: "ops/atlas/batch_entry_validator.py",
      result_class: "candidate-entry-valid",
      routing_note: "candidate entry is valid for explicit local handoff packaging only",
      payload: {
        validation_result: {
          result: "valid"
        }
      }
    }
  };
}

function assignmentInput(stackLockDigest) {
  return {
    assignment_id: "assignment-worker-artifact-001",
    worker_id: "worker-worker-artifact-001",
    task_id: "queue-or-registry-worker-artifact",
    stack_lock_digest: stackLockDigest,
    allowed_globs: [
      "repos/_stack/scripts/**",
      "repos/_stack/docs/**"
    ],
    forbidden_globs: [
      "secrets/**",
      "runtime/**"
    ],
    input_handoff_refs: [
      "docs/ops/_STACK-READINESS-STACK-QUEUE-OR-REGISTRY-WORKER-ARTIFACT-EMISSION-IMPLEMENTATION-READINESS-CLOSEOUT-AND-WORKER-ROUTING-PASS-151-2026-06-13.md"
    ],
    expected_outputs: [
      "worker.assignment.json"
    ]
  };
}

function statusInput({ state, stackLockDigest }) {
  return {
    worker_id: "worker-worker-artifact-001",
    assignment_id: "assignment-worker-artifact-001",
    state,
    heartbeat_at: "2026-06-13T17:30:00Z",
    touched_ranges: state === "completed"
      ? [
          {
            repo_path: ".",
            repo_commit: "stack@sha256:1234",
            file_digest_before: "sha256:abcd",
            path: "scripts/queue-or-registry-worker-artifact-emission.mjs",
            start_line: 1,
            end_line: 5,
            op: "modify"
          }
        ]
      : [],
    output_refs: state === "completed"
      ? ["repos/_stack/.codex/logs/example/run.json"]
      : [],
    blocked_reason: null,
    merge_request_ref: null,
    stack_lock_digest: stackLockDigest
  };
}

test("assignment success emits one bounded worker.assignment artifact through the admitted builder", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "assignment-input.json": JSON.stringify(assignmentInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, logDirRef, logDirPath }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.command, "stack queue-or-registry worker-artifact-emission");
      assert.equal(result.report.intent, "assignment");
      assert.equal(result.report.normalized_log_dir_ref, logDirRef);
      assert.equal(result.report.emitted_artifact_ref, `${logDirRef}/worker.assignment.json`);
      assert.equal(result.report.emitted_contract_version, "atlas.worker.assignment.v1");
      assert.equal(result.report.result_class, "assignment-artifact-emitted");
      assert.equal(
        result.report.routing_note,
        "explicit assignment artifact emitted only; no worker dispatch is implied"
      );
      assert.equal(result.report.stack_lock_digest, stackLockDigest);
      assert.equal(result.report.payload.assignment_artifact.assignment_id, "assignment-worker-artifact-001");

      const emittedArtifact = JSON.parse(
        await fs.readFile(path.join(logDirPath, "worker.assignment.json"), "utf8")
      );
      assert.equal(emittedArtifact.contract_version, "atlas.worker.assignment.v1");
      assert.equal(emittedArtifact.assignment_id, "assignment-worker-artifact-001");
    }
  );
});

test("status-running success emits one bounded worker.status.running artifact", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "running-input.json": JSON.stringify(statusInput({ state: "running", stackLockDigest }), null, 2)
    },
    async ({ relativeRoot, logDirRef, logDirPath }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "status-running",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/running-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.emitted_artifact_ref, `${logDirRef}/worker.status.running.json`);
      assert.equal(result.report.emitted_contract_version, "atlas.worker.status.v1");
      assert.equal(result.report.result_class, "running-status-artifact-emitted");
      assert.equal(result.report.payload.running_status_artifact.state, "running");

      const emittedArtifact = JSON.parse(
        await fs.readFile(path.join(logDirPath, "worker.status.running.json"), "utf8")
      );
      assert.equal(emittedArtifact.contract_version, "atlas.worker.status.v1");
      assert.equal(emittedArtifact.state, "running");
    }
  );
});

test("status-completed success emits one bounded worker.status.completed artifact", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "completed-input.json": JSON.stringify(statusInput({ state: "completed", stackLockDigest }), null, 2)
    },
    async ({ relativeRoot, logDirRef, logDirPath }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "status-completed",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/completed-input.json`,
        "--log-dir",
        logDirRef
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.emitted_artifact_ref, `${logDirRef}/worker.status.completed.json`);
      assert.equal(result.report.result_class, "completed-status-artifact-emitted");
      assert.equal(result.report.payload.completed_status_artifact.state, "completed");

      const emittedArtifact = JSON.parse(
        await fs.readFile(path.join(logDirPath, "worker.status.completed.json"), "utf8")
      );
      assert.equal(emittedArtifact.contract_version, "atlas.worker.status.v1");
      assert.equal(emittedArtifact.state, "completed");
      assert.equal(emittedArtifact.touched_ranges.length, 1);
    }
  );
});

test("unsupported intent fails closed", async () => {
  const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
    "--format",
    "json",
    "--intent",
    "launch-worker",
    "--source-report",
    "tmp/source-report.json",
    "--artifact-input",
    "tmp/artifact-input.json",
    "--log-dir",
    "repos/_stack/.codex/logs/invalid"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "unsupported-intent");
  assert.equal(result.report.failure_scope, "intent");
});

test("invalid source report fails before builder execution", async () => {
  let bridgeCalls = 0;
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify({ ok: true, report: { command: "wrong-command" } }, null, 2),
      "assignment-input.json": JSON.stringify(assignmentInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
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
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "assignment-input.json": JSON.stringify({ assignment_id: "missing-fields" }, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
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

test("lineage mismatch fails closed", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "assignment-input.json": JSON.stringify({
        ...assignmentInput(stackLockDigest),
        stack_lock_digest: "sha256:wrong-lock"
      }, null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
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
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "assignment-input.json": JSON.stringify(assignmentInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
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
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "assignment-input.json": JSON.stringify(assignmentInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
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
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "assignment-input.json": JSON.stringify(assignmentInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const result = await runQueueOrRegistryWorkerArtifactEmissionCommand([
        "--format",
        "json",
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
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

test("text output preserves the bounded worker-artifact-emission contract", async () => {
  const stackLockDigest = await readStackLockDigest();
  await withFixtureEnvironment(
    {
      "source-report.json": JSON.stringify(validSourceReport(), null, 2),
      "assignment-input.json": JSON.stringify(assignmentInput(stackLockDigest), null, 2)
    },
    async ({ relativeRoot, logDirRef }) => {
      const scriptPath = path.resolve("scripts/queue-or-registry-worker-artifact-emission.mjs");
      const child = spawn(process.execPath, [
        scriptPath,
        "--intent",
        "assignment",
        "--source-report",
        `${relativeRoot}/source-report.json`,
        "--artifact-input",
        `${relativeRoot}/assignment-input.json`,
        "--log-dir",
        logDirRef
      ], {
        cwd: path.resolve("."),
        env: {
          ...process.env,
          STACK_QUEUE_OR_REGISTRY_WORKER_ARTIFACT_EMISSION_WORKSPACE_ROOT: workspaceRoot
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
      assert.match(stdout, /intent=assignment/);
      assert.match(stdout, /emitted_artifact_ref=repos\/_stack\/\.codex\/logs\//);
      assert.match(stdout, /result_class=assignment-artifact-emitted/);
    }
  );
});
