import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import {
  runQueueOrRegistryBroaderExecutionBehaviorCommand
} from "./queue-or-registry-broader-execution-behavior.mjs";

const workspaceRoot = path.resolve("..", "..");

async function withFixtureFiles(files, callback) {
  const tempRoot = await fs.mkdtemp(
    path.join(workspaceRoot, "tmp", "stack-broader-execution-behavior-")
  );

  try {
    for (const [relativePath, content] of Object.entries(files)) {
      const absolutePath = path.join(tempRoot, relativePath);
      await fs.mkdir(path.dirname(absolutePath), { recursive: true });
      await fs.writeFile(absolutePath, content, "utf8");
    }

    const relativeRoot = path.relative(workspaceRoot, tempRoot).replaceAll("\\", "/");
    return await callback({ tempRoot, relativeRoot });
  } finally {
    await fs.rm(tempRoot, { recursive: true, force: true });
  }
}

function validCandidateEntry() {
  return {
    entry_id: "queue-or-registry-wrapper-001",
    lane_name: "AI Long-Run Batch Orchestration",
    job_scope: "Implement explicit-input broader execution behavior wrapper",
    owner_repo: "_stack",
    target_branch_or_worktree: "main",
    allowed_write_scope: [
      "repos/_stack/scripts/**",
      "repos/_stack/docs/**"
    ],
    checkpoint_surface: "repos/_stack/README.md",
    verification_gate: "pnpm run stack:queue-or-registry:broader-execution-behavior:test",
    closeout_artifact: "repos/_stack/receipts/example-closeout.md",
    park_or_escalation_rule: "stop if the wrapper leaves the admitted explicit-input boundary",
    protected_surface_exclusions: [
      "repos/fawxzzy-fitness",
      "archive/",
      "deploy/publication",
      ".env",
      "secrets"
    ],
    status: "proposed",
    created_from_receipt: "docs/ops/_STACK-READINESS-PASS-139.md",
    last_reconciled_receipt: "docs/ops/_STACK-READINESS-PASS-139.md"
  };
}

function assertExactKeys(actual, expected) {
  assert.deepEqual(Object.keys(actual).sort(), [...expected].sort());
}

test("draft-entry success renders one bounded scaffold report through the admitted helper", async () => {
  await withFixtureFiles(
    {
      "draft.json": JSON.stringify({
        entry_id: "draft-wrapper-001",
        lane_name: "AI Long-Run Batch Orchestration"
      }, null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
        "--format",
        "json",
        "--mode",
        "draft-entry",
        "--input",
        `${relativeRoot}/draft.json`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.command, "stack queue-or-registry broader-execution-behavior");
      assert.equal(result.report.mode, "draft-entry");
      assert.equal(result.report.normalized_input_ref, `${relativeRoot}/draft.json`);
      assert.equal(result.report.source_helper_ref, "ops/atlas/draft_entry_scaffold.py");
      assert.equal(result.report.result_class, "draft-scaffold-rendered");
      assert.equal(
        result.report.routing_note,
        "complete required candidate-entry fields before validator input"
      );
      assert.ok("draft_entry_scaffold" in result.report.payload);
      assert.ok(
        result.report.payload.draft_entry_scaffold.missing_required_fields.includes("job_scope")
      );
      assertExactKeys(result.report, [
        "command",
        "mode",
        "normalized_input_ref",
        "source_helper_ref",
        "result_class",
        "routing_note",
        "payload"
      ]);
    }
  );
});

test("validate-entry success reports candidate-entry-valid for one explicit candidate object", async () => {
  await withFixtureFiles(
    {
      "valid.json": JSON.stringify(validCandidateEntry(), null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
        "--format",
        "json",
        "--mode",
        "validate-entry",
        "--input",
        `${relativeRoot}/valid.json`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.mode, "validate-entry");
      assert.equal(result.report.source_helper_ref, "ops/atlas/batch_entry_validator.py");
      assert.equal(result.report.result_class, "candidate-entry-valid");
      assert.equal(
        result.report.routing_note,
        "candidate entry is valid for explicit local handoff packaging only"
      );
      assert.equal(result.report.payload.validation_result.result, "valid");
    }
  );
});

test("validate-entry invalid result stays bounded and does not collapse into helper failure", async () => {
  await withFixtureFiles(
    {
      "invalid.json": JSON.stringify({
        entry_id: "invalid-wrapper-001"
      }, null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
        "--format",
        "json",
        "--mode",
        "validate-entry",
        "--input",
        `${relativeRoot}/invalid.json`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.result_class, "candidate-entry-invalid");
      assert.equal(
        result.report.routing_note,
        "repair candidate entry boundary or field failures before wider execution claims"
      );
      assert.equal(result.report.payload.validation_result.result, "invalid-missing-field");
      assert.ok(
        result.report.payload.validation_result.missing_fields.includes("lane_name")
      );
    }
  );
});

test("summarize-status success renders one bounded ordered handoff summary", async () => {
  await withFixtureFiles(
    {
      "summary.json": JSON.stringify([
        {
          route: "not-validator-ready",
          scaffold_payload: {
            candidate_entry: {
              entry_id: "summary-wrapper-001",
              status: "proposed"
            },
            missing_required_fields: ["lane_name", "job_scope"],
            validator_readiness_note:
              "scaffold contains unresolved required fields and is not yet validator-ready"
          }
        },
        {
          route: "validator-input-ready",
          candidate_entry: {
            entry_id: "summary-wrapper-002",
            status: "proposed"
          }
        }
      ], null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
        "--format",
        "json",
        "--mode",
        "summarize-status",
        "--input",
        `${relativeRoot}/summary.json`
      ], {
        workspaceRoot
      });

      assert.equal(result.ok, true);
      assert.equal(result.report.source_helper_ref, "ops/atlas/entry_status_summary_renderer.py");
      assert.equal(result.report.result_class, "status-summary-rendered");
      assert.equal(
        result.report.routing_note,
        "review explicit local summary only; no launch or queue behavior is implied"
      );
      assert.equal(result.report.payload.entry_status_summary.entry_count, 2);
      assert.equal(result.report.payload.entry_status_summary.readiness_counts["not-validator-ready"], 1);
      assert.equal(result.report.payload.entry_status_summary.readiness_counts["validator-input-ready"], 1);
    }
  );
});

test("unsupported mode fails closed", async () => {
  const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
    "--format",
    "json",
    "--mode",
    "launch-worker",
    "--input",
    "tmp/unsupported.json"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "unsupported-mode");
  assert.equal(result.report.failure_scope, "mode");
});

test("malformed explicit input fails before helper execution", async () => {
  let helperCalls = 0;
  await withFixtureFiles(
    {
      "malformed.json": "{"
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
        "--format",
        "json",
        "--mode",
        "draft-entry",
        "--input",
        `${relativeRoot}/malformed.json`
      ], {
        workspaceRoot,
        runHelper: async () => {
          helperCalls += 1;
          return { ok: true, exitCode: 0, stdout: "{}", stderr: "" };
        }
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "invalid-input");
      assert.equal(result.report.failure_scope, "input");
      assert.equal(helperCalls, 0);
      assert.match(result.report.message, /not valid json/i);
    }
  );
});

test("helper execution failure reports helper-failed", async () => {
  await withFixtureFiles(
    {
      "draft.json": JSON.stringify({
        entry_id: "helper-failed-001"
      }, null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
        "--format",
        "json",
        "--mode",
        "draft-entry",
        "--input",
        `${relativeRoot}/draft.json`
      ], {
        workspaceRoot,
        runHelper: async () => ({
          ok: false,
          exitCode: 1,
          stdout: "",
          stderr: "bridge failed"
        })
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "helper-failed");
      assert.equal(result.report.failure_scope, "helper");
    }
  );
});

test("malformed helper output fails closed", async () => {
  await withFixtureFiles(
    {
      "summary.json": JSON.stringify([
        {
          route: "validator-input-ready",
          candidate_entry: {
            entry_id: "helper-malformed-001",
            status: "proposed"
          }
        }
      ], null, 2)
    },
    async ({ relativeRoot }) => {
      const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand([
        "--format",
        "json",
        "--mode",
        "summarize-status",
        "--input",
        `${relativeRoot}/summary.json`
      ], {
        workspaceRoot,
        runHelper: async () => ({
          ok: true,
          exitCode: 0,
          stdout: JSON.stringify({ entries: [] }),
          stderr: ""
        })
      });

      assert.equal(result.ok, false);
      assert.equal(result.report.failure_code, "malformed-helper-output");
      assert.equal(result.report.failure_scope, "helper");
    }
  );
});

test("text output preserves the bounded broader-execution-behavior contract", async () => {
  await withFixtureFiles(
    {
      "valid.json": JSON.stringify(validCandidateEntry(), null, 2)
    },
    async ({ relativeRoot }) => {
      const scriptPath = path.resolve("scripts/queue-or-registry-broader-execution-behavior.mjs");
      const child = spawn(process.execPath, [
        scriptPath,
        "--mode",
        "validate-entry",
        "--input",
        `${relativeRoot}/valid.json`
      ], {
        cwd: path.resolve("."),
        env: {
          ...process.env,
          STACK_QUEUE_OR_REGISTRY_BROADER_EXECUTION_BEHAVIOR_WORKSPACE_ROOT: workspaceRoot,
          STACK_QUEUE_OR_REGISTRY_BROADER_EXECUTION_BEHAVIOR_PYTHON: "python"
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
      assert.match(stdout, /mode=validate-entry/);
      assert.match(stdout, /source_helper_ref=ops\/atlas\/batch_entry_validator\.py/);
      assert.match(stdout, /result_class=candidate-entry-valid/);
    }
  );
});
