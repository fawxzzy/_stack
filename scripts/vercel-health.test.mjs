import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { spawn } from "node:child_process";
import { evaluateVercelHealth } from "./vercel-health.mjs";

const REQUIRED_REPORT_FIELDS = [
  "command",
  "scope",
  "health_class",
  "summary",
  "evidence_classes_used",
  "freshness_posture",
  "reason_set",
  "routing_note",
  "evidence_refs"
];

const OPTIONAL_REPORT_FIELDS = [
  "stale_evidence",
  "missing_evidence",
  "approval_gated_unknowns",
  "contradiction_note",
  "reconciliation_note"
];

function buildEvidence(overrides = {}) {
  return {
    input_class: "static-admitted-input",
    evidence_class: "authoritative-receipt",
    source_class: "receipt",
    source_refs: ["receipts/example.md"],
    captured_at: "2026-05-30T00:00:00.000Z",
    freshness_label: "fresh",
    truth_limit_note: "Static admitted input replay only; not live runtime truth.",
    posture: "supports",
    summary: "Canonical receipt supports the current awareness posture.",
    ...overrides
  };
}

function assertRequiredReportFields(report) {
  for (const field of REQUIRED_REPORT_FIELDS) {
    assert.notEqual(report[field], undefined, `expected required report field ${field}`);
  }
}

function assertOptionalFieldsAbsent(report, fields = OPTIONAL_REPORT_FIELDS) {
  for (const field of fields) {
    assert.equal(field in report, false, `expected optional report field ${field} to be absent`);
  }
}

test("fresh admitted evidence produces a healthy report", () => {
  const result = evaluateVercelHealth({
    evidence: [
      buildEvidence(),
      buildEvidence({
        evidence_class: "vercel-inventory-metadata",
        source_class: "inventory-snapshot",
        source_refs: ["data/vercel/project-snapshot.json"]
      })
    ]
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.health_class, "healthy");
  assert.deepEqual(result.report.reason_set, []);
  assert.equal(result.report.routing_note, "package awareness and continue to the next admitted docs-only or worker packet");
  assertRequiredReportFields(result.report);
  assertOptionalFieldsAbsent(result.report);
});

test("stale admitted evidence degrades the report", () => {
  const result = evaluateVercelHealth({
    evidence: [
      buildEvidence({
        evidence_class: "deploy-boundary-evidence",
        freshness_label: "stale",
        source_refs: ["receipts/deploy-boundary.md"]
      })
    ]
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.health_class, "degraded");
  assert.match(result.report.reason_set.join(","), /stale-admitted-evidence/);
  assert.equal(Array.isArray(result.report.stale_evidence), true);
  assertRequiredReportFields(result.report);
  assertOptionalFieldsAbsent(result.report, [
    "missing_evidence",
    "approval_gated_unknowns",
    "contradiction_note",
    "reconciliation_note"
  ]);
});

test("reconcilable contradiction stays degraded and records reconciliation", () => {
  const result = evaluateVercelHealth({
    evidence: [
      buildEvidence(),
      buildEvidence({
        evidence_class: "restart-mirror",
        source_class: "restart-surface",
        source_refs: ["docs/atlas-book/12-restart-and-handoff-guide.md"],
        posture: "contradicts",
        contradiction_reconcilable: true
      })
    ]
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.health_class, "degraded");
  assert.equal(result.report.contradiction_note.contradiction_class, "reconcilable");
  assert.match(result.report.reconciliation_note, /root can reconcile/i);
  assertRequiredReportFields(result.report);
  assertOptionalFieldsAbsent(result.report, [
    "stale_evidence",
    "missing_evidence",
    "approval_gated_unknowns"
  ]);
});

test("non-reconcilable contradiction blocks the report", () => {
  const result = evaluateVercelHealth({
    evidence: [
      buildEvidence(),
      buildEvidence({
        evidence_class: "restart-mirror",
        source_class: "restart-surface",
        source_refs: ["docs/atlas-book/11-system-map-graph.md"],
        posture: "contradicts",
        contradiction_reconcilable: false
      })
    ]
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.health_class, "blocked");
  assert.equal(result.report.contradiction_note.contradiction_class, "non-reconcilable");
  assertRequiredReportFields(result.report);
  assertOptionalFieldsAbsent(result.report, [
    "stale_evidence",
    "missing_evidence",
    "approval_gated_unknowns",
    "reconciliation_note"
  ]);
});

test("approval-gated or missing evidence blocks the report", () => {
  const result = evaluateVercelHealth({
    missing_evidence_classes: ["deploy-boundary-evidence"],
    evidence: [
      buildEvidence({
        evidence_class: "approval-gated-receipt",
        source_class: "approval-gated-receipt",
        freshness_label: "approval-gated",
        posture: "approval-gated",
        source_refs: ["receipts/approval-gated.md"]
      })
    ]
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.health_class, "blocked");
  assert.deepEqual(result.report.missing_evidence, ["deploy-boundary-evidence"]);
  assert.equal(result.report.approval_gated_unknowns.length, 1);
  assertRequiredReportFields(result.report);
  assertOptionalFieldsAbsent(result.report, [
    "stale_evidence",
    "contradiction_note",
    "reconciliation_note"
  ]);
});

test("forbidden evidence fails closed", () => {
  const result = evaluateVercelHealth({
    evidence: [
      buildEvidence({
        evidence_class: "protected-live-state",
        source_class: "live-api"
      })
    ]
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.health_class, "blocked");
  assert.match(result.report.reason_set.join(","), /unsupported-or-forbidden-input/);
  assertRequiredReportFields(result.report);
  assertOptionalFieldsAbsent(result.report, [
    "stale_evidence",
    "missing_evidence",
    "approval_gated_unknowns",
    "contradiction_note",
    "reconciliation_note"
  ]);
});

test("structurally unsupported bundle input fails closed before report rendering", () => {
  const result = evaluateVercelHealth({
    evidence: [
      buildEvidence({
        input_class: "pseudo-live-simulation"
      })
    ]
  });

  assert.equal(result.ok, false);
  assert.match(result.errors.join(","), /input_class is not admitted for the first slice/);
});

test("cli reads a bundle file and prints the report contract", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "stack-vercel-health-"));
  const bundlePath = path.join(tempDir, "bundle.json");
  await fs.writeFile(bundlePath, JSON.stringify({
    evidence: [
      buildEvidence(),
      buildEvidence({
        evidence_class: "linkage-metadata",
        source_class: "workspace-manifest",
        source_refs: ["workspace.manifest.json"]
      })
    ]
  }), "utf8");

  const scriptPath = path.resolve("scripts/vercel-health.mjs");
  const child = spawn(process.execPath, [scriptPath, "--input", bundlePath], {
    cwd: path.resolve("."),
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
  const payload = JSON.parse(stdout);
  assert.equal(payload.ok, true);
  assert.equal(payload.report.command, "_stack vercel-health");
  assert.equal(payload.report.health_class, "healthy");
  assertRequiredReportFields(payload.report);
  assertOptionalFieldsAbsent(payload.report);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("cli tolerates a UTF-8 BOM in local bundle files", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "stack-vercel-health-bom-"));
  const bundlePath = path.join(tempDir, "bundle.json");
  await fs.writeFile(
    bundlePath,
    `\uFEFF${JSON.stringify({ evidence: [buildEvidence()] })}`,
    "utf8"
  );

  const scriptPath = path.resolve("scripts/vercel-health.mjs");
  const child = spawn(process.execPath, [scriptPath, "--input", bundlePath], {
    cwd: path.resolve("."),
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
  const payload = JSON.parse(stdout);
  assert.equal(payload.ok, true);
  assert.equal(payload.report.health_class, "healthy");
  assertRequiredReportFields(payload.report);
  assertOptionalFieldsAbsent(payload.report);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("cli exits non-zero for structurally unsupported bundle input", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "stack-vercel-health-invalid-"));
  const bundlePath = path.join(tempDir, "bundle.json");
  await fs.writeFile(
    bundlePath,
    JSON.stringify({
      evidence: [
        buildEvidence({
          input_class: "pseudo-live-simulation"
        })
      ]
    }),
    "utf8"
  );

  const scriptPath = path.resolve("scripts/vercel-health.mjs");
  const child = spawn(process.execPath, [scriptPath, "--input", bundlePath], {
    cwd: path.resolve("."),
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

  assert.equal(exitCode, 1);
  assert.equal(stdout, "");
  const payload = JSON.parse(stderr);
  assert.equal(payload.ok, false);
  assert.match(payload.errors.join(","), /input_class is not admitted for the first slice/);

  await fs.rm(tempDir, { recursive: true, force: true });
});
