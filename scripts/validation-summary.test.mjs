import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { spawn } from "node:child_process";
import { runValidationSummaryCommand } from "./validation-summary.mjs";

function createSnapshot(overrides = {}) {
  return {
    critical: 0,
    error: 0,
    warning: 494,
    info: 0,
    ...overrides
  };
}

function createJsonPayload(snapshot = createSnapshot()) {
  return {
    summary: snapshot
  };
}

function createMarkdownPayload(snapshot = createSnapshot()) {
  return [
    "# ATLAS Stack Validation Report",
    "",
    "## Summary",
    "",
    `- Critical: ${snapshot.critical}`,
    `- Error: ${snapshot.error}`,
    `- Warning: ${snapshot.warning}`,
    `- Info: ${snapshot.info}`
  ].join("\n");
}

async function withWorkspace(files) {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "stack-validation-summary-"));
  for (const [relativePath, content] of Object.entries(files)) {
    const absolutePath = path.join(workspaceRoot, relativePath);
    await fs.mkdir(path.dirname(absolutePath), { recursive: true });
    await fs.writeFile(absolutePath, content, "utf8");
  }
  return workspaceRoot;
}

function successRunner() {
  return Promise.resolve({ ok: true, exitCode: 0, stdout: "", stderr: "" });
}

function failureRunner() {
  return Promise.resolve({ ok: false, exitCode: 1, stdout: "", stderr: "validator failed" });
}

function assertExactKeys(actual, expected) {
  assert.deepEqual(Object.keys(actual).sort(), [...expected].sort());
}

test("snapshot-only success preserves the required contract", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload())
  });

  const result = await runValidationSummaryCommand(["--format", "json"], {
    workspaceRoot,
    runValidator: successRunner
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.command, "stack validate");
  assert.deepEqual(result.report.snapshot, createSnapshot());
  assert.deepEqual(result.report.artifact_refs, [
    "runtime/receipts/validation/stack-validation.latest.md",
    "runtime/receipts/validation/stack-validation.latest.json"
  ]);
  assert.equal(result.report.delta_status, "not-requested");
  assert.equal(result.report.summary_mode, "snapshot-only");
  assert.equal(result.report.routing_note, "package current snapshot only and continue");
  assert.equal("baseline_ref" in result.report, false);
  assert.equal("delta" in result.report, false);
  assert.equal("delta_unavailable_reason" in result.report, false);
  assert.equal("receipt_context" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "snapshot",
    "artifact_refs",
    "delta_status",
    "summary_mode",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("one exact cited baseline produces snapshot-plus-delta success", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload()),
    "docs/ops/baseline-receipt.md": "- `critical=0 error=1 warning=500 info=0`\n"
  });

  const result = await runValidationSummaryCommand([
    "--format",
    "json",
    "--delta-from",
    "docs/ops/baseline-receipt.md",
    "--receipt-context",
    "docs/ops/current-receipt.md"
  ], {
    workspaceRoot,
    runValidator: successRunner
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.delta_status, "computed");
  assert.equal(result.report.summary_mode, "snapshot-plus-delta");
  assert.equal(result.report.baseline_ref, "docs/ops/baseline-receipt.md");
  assert.deepEqual(result.report.delta, {
    critical: 0,
    error: -1,
    warning: -6,
    info: 0
  });
  assert.equal(result.report.receipt_context, "docs/ops/current-receipt.md");
  assert.equal(result.report.routing_note, "package current snapshot plus exact count delta and continue");
  assert.equal("delta_unavailable_reason" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "snapshot",
    "artifact_refs",
    "delta_status",
    "summary_mode",
    "routing_note",
    "baseline_ref",
    "delta",
    "receipt_context"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing baseline path produces the snapshot-only unavailable branch", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload())
  });

  const result = await runValidationSummaryCommand([
    "--format",
    "json",
    "--delta-from",
    "docs/ops/missing-baseline.md"
  ], {
    workspaceRoot,
    runValidator: successRunner
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.delta_status, "unavailable");
  assert.equal(result.report.summary_mode, "snapshot-only");
  assert.equal(result.report.baseline_ref, "docs/ops/missing-baseline.md");
  assert.equal(result.report.delta_unavailable_reason, "baseline-path-missing");
  assert.equal(
    result.report.routing_note,
    "package current snapshot only and open one bounded baseline-citation repair packet only if delta wording is still required"
  );
  assert.equal("delta" in result.report, false);
  assert.equal("receipt_context" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "snapshot",
    "artifact_refs",
    "delta_status",
    "summary_mode",
    "routing_note",
    "baseline_ref",
    "delta_unavailable_reason"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing baseline tuple preserves the unavailable branch without fabricating delta fields", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload()),
    "docs/ops/baseline-without-tuple.md": "# No attributed validator tuple here\n"
  });

  const result = await runValidationSummaryCommand([
    "--format",
    "json",
    "--delta-from",
    "docs/ops/baseline-without-tuple.md"
  ], {
    workspaceRoot,
    runValidator: successRunner
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.delta_status, "unavailable");
  assert.equal(result.report.summary_mode, "snapshot-only");
  assert.equal(result.report.baseline_ref, "docs/ops/baseline-without-tuple.md");
  assert.equal(result.report.delta_unavailable_reason, "baseline-tuple-missing");
  assert.equal("delta" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "snapshot",
    "artifact_refs",
    "delta_status",
    "summary_mode",
    "routing_note",
    "baseline_ref",
    "delta_unavailable_reason"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("current artifact contradiction fails closed", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(createSnapshot({ warning: 494 })),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload(createSnapshot({ warning: 493 })))
  });

  const result = await runValidationSummaryCommand(["--format", "json"], {
    workspaceRoot,
    runValidator: successRunner
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "artifact-contradiction");
  assert.equal(result.report.failure_scope, "current-artifacts");
  assert.equal(result.report.contradiction_note.contradiction_scope, "current-artifacts");
  assert.deepEqual(result.report.contradiction_note.conflicting_refs, [
    "runtime/receipts/validation/stack-validation.latest.md",
    "runtime/receipts/validation/stack-validation.latest.json"
  ]);
  assert.equal(result.report.contradiction_note.summary_consequence, "no-summary");
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "contradiction_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("contradictory cited baseline fails closed", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload()),
    "docs/ops/contradictory-baseline.md": [
      "- `critical=0 error=0 warning=494 info=0`",
      "- `critical=0 error=1 warning=494 info=0`"
    ].join("\n")
  });

  const result = await runValidationSummaryCommand([
    "--format",
    "json",
    "--delta-from",
    "docs/ops/contradictory-baseline.md"
  ], {
    workspaceRoot,
    runValidator: successRunner
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "artifact-contradiction");
  assert.equal(result.report.failure_scope, "baseline");
  assert.equal(result.report.contradiction_note.contradiction_scope, "baseline");
  assert.deepEqual(result.report.contradiction_note.conflicting_refs, ["docs/ops/contradictory-baseline.md"]);
  assert.equal("snapshot" in result.report, false);
  assert.equal("artifact_refs" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "contradiction_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing or malformed current artifacts fail as artifact-missing", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload()
  });

  const result = await runValidationSummaryCommand(["--format", "json"], {
    workspaceRoot,
    runValidator: successRunner
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "artifact-missing");
  assert.equal(result.report.failure_scope, "current-artifacts");
  assert.equal("contradiction_note" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("validator failure never substitutes stale artifacts", async () => {
  const workspaceRoot = await withWorkspace({
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload())
  });

  const result = await runValidationSummaryCommand(["--format", "json"], {
    workspaceRoot,
    runValidator: failureRunner
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "validator-failed");
  assert.equal(result.report.failure_scope, "validator-execution");
  assert.equal("snapshot" in result.report, false);
  assert.equal("contradiction_note" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("unsupported input fails closed before execution", async () => {
  let runnerCalls = 0;
  const result = await runValidationSummaryCommand([
    "--format",
    "yaml"
  ], {
    runValidator: async () => {
      runnerCalls += 1;
      return successRunner();
    }
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(result.report.failure_scope, "input");
  assert.equal(runnerCalls, 0);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);
});

test("absolute or escaping input paths fail before validator execution", async () => {
  let runnerCalls = 0;
  const result = await runValidationSummaryCommand([
    "--format",
    "json",
    "--delta-from",
    "C:\\outside\\baseline.md",
    "--receipt-context",
    "../outside.md"
  ], {
    runValidator: async () => {
      runnerCalls += 1;
      return successRunner();
    }
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(result.report.failure_scope, "input");
  assert.match(result.report.message, /--delta-from must be none or a relative receipt path\./);
  assert.match(result.report.message, /--receipt-context must be a bounded relative path\./);
  assert.equal(runnerCalls, 0);
});

test("text output preserves the bounded snapshot-only contract", async () => {
  const workspaceRoot = await withWorkspace({
    "ops/validation/validate_stack.py": "print('ok')\n",
    "runtime/receipts/validation/stack-validation.latest.md": createMarkdownPayload(),
    "runtime/receipts/validation/stack-validation.latest.json": JSON.stringify(createJsonPayload())
  });

  const scriptPath = path.resolve("scripts/validation-summary.mjs");
  const child = spawn(process.execPath, [scriptPath], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      STACK_VALIDATION_SUMMARY_WORKSPACE_ROOT: workspaceRoot,
      STACK_VALIDATION_SUMMARY_PYTHON: "python"
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
  assert.match(stdout, /^critical=0 error=0 warning=494 info=0/m);
  assert.match(stdout, /artifact_refs=runtime\/receipts\/validation\/stack-validation.latest.md, runtime\/receipts\/validation\/stack-validation.latest.json/);
  assert.match(stdout, /routing_note=package current snapshot only and continue/);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});
