#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack validate";
const ROUTING_NOTES = Object.freeze({
  snapshotOnly: "package current snapshot only and continue",
  snapshotPlusDelta: "package current snapshot plus exact count delta and continue",
  invalidInput: "fix invocation and rerun before packaging",
  validatorFailed: "route to validator-failure triage before summary claims",
  artifactMissing: "rerun or repair latest artifact production before summary claims",
  artifactContradiction: "route to one bounded root-only contradiction reconciliation packet",
  deltaBaselineUnavailable:
    "package current snapshot only and open one bounded baseline-citation repair packet only if delta wording is still required"
});

const FAILURE_CODES = new Set([
  "invalid-input",
  "validator-failed",
  "artifact-missing",
  "artifact-contradiction"
]);

const SUMMARY_MODES = new Set(["snapshot-only", "snapshot-plus-delta"]);
const DELTA_STATUSES = new Set(["not-requested", "computed", "unavailable"]);

const CURRENT_ARTIFACT_REFS = Object.freeze([
  "runtime/receipts/validation/stack-validation.latest.md",
  "runtime/receipts/validation/stack-validation.latest.json"
]);

const BASELINE_UNAVAILABLE_REASONS = new Set([
  "baseline-path-missing",
  "baseline-tuple-missing"
]);

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function stripBom(value) {
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value;
}

function normalizeRelativePath(value) {
  return value.trim().replaceAll("\\", "/");
}

function isRelativePath(value) {
  if (!isNonEmptyString(value)) {
    return false;
  }

  if (path.isAbsolute(value)) {
    return false;
  }

  return !normalizeRelativePath(value).startsWith("../");
}

function parseSnapshotTupleLine(text) {
  const match = text.match(/critical=(\d+)\s+error=(\d+)\s+warning=(\d+)\s+info=(\d+)/i);
  if (!match) {
    return null;
  }

  return {
    critical: Number.parseInt(match[1], 10),
    error: Number.parseInt(match[2], 10),
    warning: Number.parseInt(match[3], 10),
    info: Number.parseInt(match[4], 10)
  };
}

function parseMarkdownSnapshot(text) {
  const critical = text.match(/-\s+Critical:\s+(\d+)/i);
  const error = text.match(/-\s+Error:\s+(\d+)/i);
  const warning = text.match(/-\s+Warning:\s+(\d+)/i);
  const info = text.match(/-\s+Info:\s+(\d+)/i);

  if (!critical || !error || !warning || !info) {
    return null;
  }

  return {
    critical: Number.parseInt(critical[1], 10),
    error: Number.parseInt(error[1], 10),
    warning: Number.parseInt(warning[1], 10),
    info: Number.parseInt(info[1], 10)
  };
}

function parseJsonSnapshot(payload) {
  if (!isRecord(payload) || !isRecord(payload.summary)) {
    return null;
  }

  const summary = payload.summary;
  const keys = ["critical", "error", "warning", "info"];
  for (const key of keys) {
    if (!Number.isInteger(summary[key])) {
      return null;
    }
  }

  return {
    critical: summary.critical,
    error: summary.error,
    warning: summary.warning,
    info: summary.info
  };
}

function snapshotsMatch(left, right) {
  return left.critical === right.critical
    && left.error === right.error
    && left.warning === right.warning
    && left.info === right.info;
}

function buildDelta(current, baseline) {
  return {
    critical: current.critical - baseline.critical,
    error: current.error - baseline.error,
    warning: current.warning - baseline.warning,
    info: current.info - baseline.info
  };
}

function extractBaselineTuples(text) {
  const matches = [...text.matchAll(/critical=(\d+)\s+error=(\d+)\s+warning=(\d+)\s+info=(\d+)/gi)];
  const tuples = matches.map((match) => ({
    critical: Number.parseInt(match[1], 10),
    error: Number.parseInt(match[2], 10),
    warning: Number.parseInt(match[3], 10),
    info: Number.parseInt(match[4], 10)
  }));

  const unique = [];
  const seen = new Set();
  for (const tuple of tuples) {
    const key = JSON.stringify(tuple);
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    unique.push(tuple);
  }

  return unique;
}

function buildFailure({ failureCode, failureScope, message, routingNote, contradictionNote }) {
  if (!FAILURE_CODES.has(failureCode)) {
    throw new Error(`Unsupported failure code: ${failureCode}`);
  }

  const report = {
    command: COMMAND_ID,
    failure_code: failureCode,
    failure_scope: failureScope,
    message,
    routing_note: routingNote
  };

  if (contradictionNote) {
    report.contradiction_note = contradictionNote;
  }

  return report;
}

function buildSuccess({
  snapshot,
  deltaStatus,
  summaryMode,
  routingNote,
  baselineRef,
  delta,
  receiptContext,
  deltaUnavailableReason
}) {
  if (!SUMMARY_MODES.has(summaryMode)) {
    throw new Error(`Unsupported summary mode: ${summaryMode}`);
  }

  if (!DELTA_STATUSES.has(deltaStatus)) {
    throw new Error(`Unsupported delta status: ${deltaStatus}`);
  }

  const report = {
    command: COMMAND_ID,
    snapshot,
    artifact_refs: [...CURRENT_ARTIFACT_REFS],
    delta_status: deltaStatus,
    summary_mode: summaryMode,
    routing_note: routingNote
  };

  if (baselineRef) {
    report.baseline_ref = baselineRef;
  }

  if (delta) {
    report.delta = delta;
  }

  if (receiptContext) {
    report.receipt_context = receiptContext;
  }

  if (deltaUnavailableReason) {
    report.delta_unavailable_reason = deltaUnavailableReason;
  }

  return report;
}

function formatSnapshot(snapshot) {
  return `critical=${snapshot.critical} error=${snapshot.error} warning=${snapshot.warning} info=${snapshot.info}`;
}

function formatDeltaLine(baselineRef, delta) {
  const values = formatSnapshot(delta);
  return `delta_from=${baselineRef} ${values}`;
}

function renderText(result) {
  if (result.ok) {
    const lines = [
      formatSnapshot(result.report.snapshot),
      `artifact_refs=${CURRENT_ARTIFACT_REFS.join(", ")}`
    ];

    if (result.report.delta_status === "computed") {
      lines.push(formatDeltaLine(result.report.baseline_ref, result.report.delta));
    }

    lines.push(`routing_note=${result.report.routing_note}`);
    return `${lines.join("\n")}\n`;
  }

  const lines = [
    `failure_code=${result.report.failure_code}`,
    `message=${result.report.message}`,
    `routing_note=${result.report.routing_note}`
  ];
  return `${lines.join("\n")}\n`;
}

async function defaultReadText(filePath) {
  return stripBom(await fs.readFile(filePath, "utf8"));
}

async function defaultReadJson(filePath) {
  return JSON.parse(await defaultReadText(filePath));
}

async function defaultRunValidator({ workspaceRoot }) {
  const validatorPath = path.join(workspaceRoot, "ops", "validation", "validate_stack.py");
  const pythonCommand = process.env.STACK_VALIDATION_SUMMARY_PYTHON || "python";

  return new Promise((resolve) => {
    const child = spawn(pythonCommand, [validatorPath], {
      cwd: workspaceRoot,
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

    child.on("error", (error) => {
      resolve({
        ok: false,
        exitCode: 1,
        stdout,
        stderr,
        error: error instanceof Error ? error.message : String(error)
      });
    });

    child.on("close", (exitCode) => {
      resolve({
        ok: exitCode === 0,
        exitCode: exitCode ?? 1,
        stdout,
        stderr
      });
    });
  });
}

function parseArgs(argv) {
  const args = [...argv];
  const parsed = {
    format: "text",
    deltaFrom: "none",
    receiptContext: undefined
  };
  const errors = [];

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === "--format") {
      const value = args[index + 1];
      if (!value || (value !== "text" && value !== "json")) {
        errors.push("--format must be text or json.");
      } else {
        parsed.format = value;
      }
      index += 1;
      continue;
    }

    if (token === "--delta-from") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--delta-from requires none or a relative receipt path.");
      } else {
        parsed.deltaFrom = value;
      }
      index += 1;
      continue;
    }

    if (token === "--receipt-context") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--receipt-context requires a relative path.");
      } else {
        parsed.receiptContext = value;
      }
      index += 1;
      continue;
    }

    errors.push(`Unsupported argument: ${token}`);
  }

  if (parsed.deltaFrom !== "none" && !isRelativePath(parsed.deltaFrom)) {
    errors.push("--delta-from must be none or a relative receipt path.");
  }

  if (parsed.receiptContext !== undefined && !isRelativePath(parsed.receiptContext)) {
    errors.push("--receipt-context must be a bounded relative path.");
  }

  if (parsed.deltaFrom !== "none") {
    parsed.deltaFrom = normalizeRelativePath(parsed.deltaFrom);
  }

  if (parsed.receiptContext) {
    parsed.receiptContext = normalizeRelativePath(parsed.receiptContext);
  }

  return {
    ok: errors.length === 0,
    errors,
    args: parsed
  };
}

function getWorkspaceRoot() {
  if (isNonEmptyString(process.env.STACK_VALIDATION_SUMMARY_WORKSPACE_ROOT)) {
    return path.resolve(process.env.STACK_VALIDATION_SUMMARY_WORKSPACE_ROOT);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

function contradictionNote(scope, conflictingRefs) {
  return {
    contradiction_scope: scope,
    conflicting_refs: conflictingRefs,
    summary_consequence: "no-summary"
  };
}

async function loadCurrentSnapshot({ workspaceRoot, readText, readJson }) {
  const markdownPath = path.join(workspaceRoot, CURRENT_ARTIFACT_REFS[0]);
  const jsonPath = path.join(workspaceRoot, CURRENT_ARTIFACT_REFS[1]);

  let markdownRaw;
  let jsonPayload;
  try {
    [markdownRaw, jsonPayload] = await Promise.all([
      readText(markdownPath),
      readJson(jsonPath)
    ]);
  } catch {
    return {
      ok: false,
      reason: "missing-or-unreadable"
    };
  }

  const markdownSnapshot = parseMarkdownSnapshot(markdownRaw);
  const jsonSnapshot = parseJsonSnapshot(jsonPayload);

  if (!markdownSnapshot || !jsonSnapshot) {
    return {
      ok: false,
      reason: "malformed"
    };
  }

  if (!snapshotsMatch(markdownSnapshot, jsonSnapshot)) {
    return {
      ok: false,
      reason: "contradiction",
      markdownSnapshot,
      jsonSnapshot
    };
  }

  return {
    ok: true,
    snapshot: jsonSnapshot
  };
}

async function loadBaselineTuple({ workspaceRoot, baselineRef, readText }) {
  const baselinePath = path.join(workspaceRoot, baselineRef);
  let receiptText;

  try {
    receiptText = await readText(baselinePath);
  } catch {
    return {
      ok: true,
      status: "unavailable",
      reason: "baseline-path-missing"
    };
  }

  const tuples = extractBaselineTuples(receiptText);
  if (tuples.length === 0) {
    return {
      ok: true,
      status: "unavailable",
      reason: "baseline-tuple-missing"
    };
  }

  if (tuples.length > 1) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "artifact-contradiction",
        failureScope: "baseline",
        message: "The cited baseline receipt contains conflicting validator tuples.",
        routingNote: ROUTING_NOTES.artifactContradiction,
        contradictionNote: contradictionNote("baseline", [baselineRef])
      })
    };
  }

  return {
    ok: true,
    status: "computed",
    tuple: tuples[0]
  };
}

export async function runValidationSummaryCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-input",
        failureScope: "input",
        message: parsed.errors.join(" "),
        routingNote: ROUTING_NOTES.invalidInput
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const runValidator = dependencies.runValidator || defaultRunValidator;
  const readText = dependencies.readText || defaultReadText;
  const readJson = dependencies.readJson || defaultReadJson;

  const validatorResult = await runValidator({ workspaceRoot });
  if (!validatorResult.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "validator-failed",
        failureScope: "validator-execution",
        message: "The stack validator failed before summary artifacts were admitted.",
        routingNote: ROUTING_NOTES.validatorFailed
      })
    };
  }

  const currentSnapshot = await loadCurrentSnapshot({ workspaceRoot, readText, readJson });
  if (!currentSnapshot.ok) {
    if (currentSnapshot.reason === "contradiction") {
      return {
        ok: false,
        report: buildFailure({
          failureCode: "artifact-contradiction",
          failureScope: "current-artifacts",
          message: "The latest validation artifacts disagree on the final count tuple.",
          routingNote: ROUTING_NOTES.artifactContradiction,
          contradictionNote: contradictionNote("current-artifacts", CURRENT_ARTIFACT_REFS)
        })
      };
    }

    return {
      ok: false,
      report: buildFailure({
        failureCode: "artifact-missing",
        failureScope: "current-artifacts",
        message: "The latest validation artifacts are missing or malformed.",
        routingNote: ROUTING_NOTES.artifactMissing
      })
    };
  }

  if (parsed.args.deltaFrom === "none") {
    return {
      ok: true,
      report: buildSuccess({
        snapshot: currentSnapshot.snapshot,
        deltaStatus: "not-requested",
        summaryMode: "snapshot-only",
        routingNote: ROUTING_NOTES.snapshotOnly,
        receiptContext: parsed.args.receiptContext
      })
    };
  }

  const baseline = await loadBaselineTuple({
    workspaceRoot,
    baselineRef: parsed.args.deltaFrom,
    readText
  });

  if (!baseline.ok) {
    return baseline;
  }

  if (baseline.status === "unavailable") {
    if (!BASELINE_UNAVAILABLE_REASONS.has(baseline.reason)) {
      throw new Error(`Unsupported baseline unavailable reason: ${baseline.reason}`);
    }

    return {
      ok: true,
      report: buildSuccess({
        snapshot: currentSnapshot.snapshot,
        deltaStatus: "unavailable",
        summaryMode: "snapshot-only",
        routingNote: ROUTING_NOTES.deltaBaselineUnavailable,
        baselineRef: parsed.args.deltaFrom,
        receiptContext: parsed.args.receiptContext,
        deltaUnavailableReason: baseline.reason
      })
    };
  }

  return {
    ok: true,
    report: buildSuccess({
      snapshot: currentSnapshot.snapshot,
      deltaStatus: "computed",
      summaryMode: "snapshot-plus-delta",
      routingNote: ROUTING_NOTES.snapshotPlusDelta,
      baselineRef: parsed.args.deltaFrom,
      receiptContext: parsed.args.receiptContext,
      delta: buildDelta(currentSnapshot.snapshot, baseline.tuple)
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} [--format text|json] [--delta-from none|<receipt-path>] [--receipt-context <relative-path>]`,
    "",
    "Runs the governed stack validator, loads the paired latest validation artifacts, optionally computes one cited baseline delta, and emits the bounded validation-summary contract.",
    "No-execution guard: this packet may admit future implementation of validator invocation, paired-artifact loading, one cited-baseline comparison, contradiction classification, and receipt-ready summary rendering for stack validate validation-summary, but it may not add any mutation beyond the validator's normal latest-artifact production, mutate markers/receipts/book surfaces or owner repos, suppress findings, or imply deploy/publication/owner-readiness proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runValidationSummaryCommand(argv);
  const parsed = parseArgs(argv);
  const format = parsed.ok ? parsed.args.format : "json";

  if (format === "json") {
    console.log(JSON.stringify(result, null, 2));
  } else {
    process.stdout.write(renderText(result));
  }

  return result.ok ? 0 : 1;
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  const exitCode = await main(process.argv.slice(2));
  process.exit(exitCode);
}
