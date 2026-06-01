#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const COMMAND_NAME = "_stack vercel-health";
const COMMAND_SCOPE = "awareness-only first implementation slice";

const ADMITTED_EVIDENCE_CLASSES = new Set([
  "authoritative-receipt",
  "restart-mirror",
  "linkage-metadata",
  "vercel-inventory-metadata",
  "deploy-boundary-evidence",
  "approval-gated-receipt"
]);

const DERIVATIVE_ONLY_EVIDENCE_CLASSES = new Set([
  "restart-mirror"
]);

const APPROVAL_GATED_EVIDENCE_CLASSES = new Set([
  "approval-gated-receipt"
]);

const FORBIDDEN_EVIDENCE_CLASSES = new Set([
  "secret",
  "protected-live-state",
  "runtime-proof",
  "discord-publication-state",
  "owner-draft",
  "simulated-truth"
]);

const FRESHNESS_LABELS = new Set([
  "fresh",
  "stale",
  "incomplete",
  "approval-gated"
]);

const POSTURE_LABELS = new Set([
  "supports",
  "contradicts",
  "approval-gated"
]);

const INPUT_CLASS_LABELS = new Set([
  "synthetic-report-shape-fixture",
  "receipt-derived-static-fixture",
  "read-only-metadata-snapshot",
  "degraded-case-freshness-fixture",
  "static-admitted-input"
]);

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function normalizeStringArray(value, label, errors) {
  if (value === undefined) {
    return [];
  }

  if (!Array.isArray(value)) {
    errors.push(`${label} must be an array when provided.`);
    return [];
  }

  return value.flatMap((entry, index) => {
    if (!isNonEmptyString(entry)) {
      errors.push(`${label}[${index}] must be a non-empty string.`);
      return [];
    }

    return [entry.trim()];
  });
}

function ensureIsoDate(value, label, errors) {
  if (!isNonEmptyString(value)) {
    errors.push(`${label} must be a non-empty ISO timestamp.`);
    return null;
  }

  const normalized = value.trim();
  if (Number.isNaN(Date.parse(normalized))) {
    errors.push(`${label} must be a valid ISO timestamp.`);
    return null;
  }

  return normalized;
}

function validateEvidenceEntry(entry, index, errors) {
  if (!isRecord(entry)) {
    errors.push(`evidence[${index}] must be an object.`);
    return null;
  }

  const inputClass = isNonEmptyString(entry.input_class) ? entry.input_class.trim() : null;
  if (!inputClass) {
    errors.push(`evidence[${index}].input_class is required.`);
  } else if (!INPUT_CLASS_LABELS.has(inputClass)) {
    errors.push(`evidence[${index}].input_class is not admitted for the first slice.`);
  }

  const evidenceClass = isNonEmptyString(entry.evidence_class) ? entry.evidence_class.trim() : null;
  if (!evidenceClass) {
    errors.push(`evidence[${index}].evidence_class is required.`);
  }

  const sourceClass = isNonEmptyString(entry.source_class) ? entry.source_class.trim() : null;
  if (!sourceClass) {
    errors.push(`evidence[${index}].source_class is required.`);
  }

  const sourceRefs = normalizeStringArray(entry.source_refs, `evidence[${index}].source_refs`, errors);
  const capturedAt = ensureIsoDate(entry.captured_at, `evidence[${index}].captured_at`, errors);

  const freshnessLabel = isNonEmptyString(entry.freshness_label) ? entry.freshness_label.trim() : null;
  if (!freshnessLabel) {
    errors.push(`evidence[${index}].freshness_label is required.`);
  } else if (!FRESHNESS_LABELS.has(freshnessLabel)) {
    errors.push(`evidence[${index}].freshness_label is invalid.`);
  }

  const truthLimitNote = isNonEmptyString(entry.truth_limit_note) ? entry.truth_limit_note.trim() : null;
  if (!truthLimitNote) {
    errors.push(`evidence[${index}].truth_limit_note is required.`);
  }

  const posture = isNonEmptyString(entry.posture) ? entry.posture.trim() : "supports";
  if (!POSTURE_LABELS.has(posture)) {
    errors.push(`evidence[${index}].posture is invalid.`);
  }

  const summary = isNonEmptyString(entry.summary) ? entry.summary.trim() : null;
  const contradictionReconcilable = entry.contradiction_reconcilable;
  if (posture === "contradicts" && typeof contradictionReconcilable !== "boolean") {
    errors.push(`evidence[${index}].contradiction_reconcilable must be boolean when posture is contradicts.`);
  }

  return {
    input_class: inputClass,
    evidence_class: evidenceClass,
    source_class: sourceClass,
    source_refs: sourceRefs,
    captured_at: capturedAt,
    freshness_label: freshnessLabel,
    truth_limit_note: truthLimitNote,
    posture,
    summary,
    contradiction_reconcilable: contradictionReconcilable === true
  };
}

export function validateVercelHealthBundle(bundle) {
  const errors = [];

  if (!isRecord(bundle)) {
    return {
      ok: false,
      errors: ["Input bundle must be a JSON object."]
    };
  }

  const evidence = Array.isArray(bundle.evidence) ? bundle.evidence : null;
  if (!evidence) {
    errors.push("Input bundle must include an evidence array.");
  }

  const missingEvidenceClasses = normalizeStringArray(bundle.missing_evidence_classes, "missing_evidence_classes", errors);
  const normalizedEvidence = evidence
    ? evidence.map((entry, index) => validateEvidenceEntry(entry, index, errors)).filter(Boolean)
    : [];

  return {
    ok: errors.length === 0,
    errors,
    bundle: {
      scope: isNonEmptyString(bundle.scope) ? bundle.scope.trim() : COMMAND_SCOPE,
      missing_evidence_classes: missingEvidenceClasses,
      evidence: normalizedEvidence
    }
  };
}

function summarizeFreshness(entries) {
  if (entries.some((entry) => entry.freshness_label === "approval-gated")) {
    return "approval-gated";
  }
  if (entries.some((entry) => entry.freshness_label === "incomplete")) {
    return "incomplete";
  }
  if (entries.some((entry) => entry.freshness_label === "stale")) {
    return "stale";
  }
  return "fresh";
}

function uniqueEvidenceClasses(entries) {
  return [...new Set(entries.map((entry) => entry.evidence_class))];
}

function uniqueRefs(entries) {
  return [...new Set(entries.flatMap((entry) => entry.source_refs))];
}

function buildContradictionNote(contradictions, healthClass) {
  if (contradictions.length === 0) {
    return undefined;
  }

  const contradictionClass = contradictions.every((entry) => entry.contradiction_reconcilable)
    ? "reconcilable"
    : "non-reconcilable";

  return {
    contradiction_class: contradictionClass,
    conflicting_evidence_classes: uniqueEvidenceClasses(contradictions),
    conflicting_refs: uniqueRefs(contradictions),
    decisive_boundary: healthClass === "blocked"
      ? "owner-side or approval-gated truth is still required"
      : "root can reconcile using admitted evidence only",
    required_follow_on: healthClass === "blocked"
      ? "route to blocked clarification or worker stop-and-return"
      : "route to bounded reconciliation packet"
  };
}

function buildReasons({
  forbiddenEntries,
  approvalGatedEntries,
  contradictions,
  staleEntries,
  incompleteEntries,
  missingEvidenceClasses,
  admittedEntries
}) {
  const reasons = [];

  if (forbiddenEntries.length > 0) {
    reasons.push("unsupported-or-forbidden-input");
  }
  if (approvalGatedEntries.length > 0) {
    reasons.push("approval-gated-unknown");
  }
  if (missingEvidenceClasses.length > 0) {
    reasons.push("missing-required-evidence");
  }
  if (contradictions.some((entry) => !entry.contradiction_reconcilable)) {
    reasons.push("non-reconcilable-contradiction");
  } else if (contradictions.length > 0) {
    reasons.push("reconcilable-contradiction");
  }
  if (incompleteEntries.length > 0) {
    reasons.push("incomplete-admitted-evidence");
  }
  if (staleEntries.length > 0) {
    reasons.push("stale-admitted-evidence");
  }
  if (admittedEntries.length === 0) {
    reasons.push("no-admitted-evidence");
  }

  return reasons;
}

export function evaluateVercelHealth(bundle) {
  const validation = validateVercelHealthBundle(bundle);
  if (!validation.ok) {
    return {
      ok: false,
      errors: validation.errors
    };
  }

  const normalizedBundle = validation.bundle;
  const allEntries = normalizedBundle.evidence;
  const admittedEntries = allEntries.filter((entry) => ADMITTED_EVIDENCE_CLASSES.has(entry.evidence_class));
  const forbiddenEntries = allEntries.filter(
    (entry) => FORBIDDEN_EVIDENCE_CLASSES.has(entry.evidence_class) || !ADMITTED_EVIDENCE_CLASSES.has(entry.evidence_class)
  );
  const approvalGatedEntries = admittedEntries.filter(
    (entry) => APPROVAL_GATED_EVIDENCE_CLASSES.has(entry.evidence_class) || entry.posture === "approval-gated" || entry.freshness_label === "approval-gated"
  );
  const contradictions = admittedEntries.filter((entry) => entry.posture === "contradicts");
  const staleEntries = admittedEntries.filter((entry) => entry.freshness_label === "stale");
  const incompleteEntries = admittedEntries.filter((entry) => entry.freshness_label === "incomplete");

  const reasons = buildReasons({
    forbiddenEntries,
    approvalGatedEntries,
    contradictions,
    staleEntries,
    incompleteEntries,
    missingEvidenceClasses: normalizedBundle.missing_evidence_classes,
    admittedEntries
  });

  let healthClass = "healthy";
  if (
    forbiddenEntries.length > 0 ||
    approvalGatedEntries.length > 0 ||
    normalizedBundle.missing_evidence_classes.length > 0 ||
    contradictions.some((entry) => !entry.contradiction_reconcilable) ||
    admittedEntries.length === 0
  ) {
    healthClass = "blocked";
  } else if (
    contradictions.length > 0 ||
    staleEntries.length > 0 ||
    incompleteEntries.length > 0
  ) {
    healthClass = "degraded";
  }

  const freshnessPosture = summarizeFreshness(admittedEntries);
  const evidenceRefs = uniqueRefs(admittedEntries);

  const report = {
    command: COMMAND_NAME,
    scope: normalizedBundle.scope,
    health_class: healthClass,
    summary: healthClass === "healthy"
      ? "Admitted evidence is fresh enough for awareness-only reporting."
      : healthClass === "degraded"
        ? "Admitted evidence is usable for awareness-only reporting, but freshness or contradiction limits prevent a healthy classification."
        : "The first slice must stop at a blocked posture because evidence is missing, approval-gated, unsupported, or non-reconcilably contradictory.",
    evidence_classes_used: uniqueEvidenceClasses(admittedEntries),
    freshness_posture: freshnessPosture,
    reason_set: reasons,
    routing_note: healthClass === "healthy"
      ? "package awareness and continue to the next admitted docs-only or worker packet"
      : healthClass === "degraded"
        ? "package degraded posture and route to one bounded clarification or reconciliation packet"
        : "package blocked posture and route to owner-side evidence, approval-gated inspection, or worker stop-and-return",
    evidence_refs: evidenceRefs
  };

  if (staleEntries.length > 0 || incompleteEntries.length > 0) {
    report.stale_evidence = [...staleEntries, ...incompleteEntries].map((entry) => ({
      evidence_class: entry.evidence_class,
      source_refs: entry.source_refs,
      freshness_label: entry.freshness_label
    }));
  }

  if (normalizedBundle.missing_evidence_classes.length > 0) {
    report.missing_evidence = normalizedBundle.missing_evidence_classes;
  }

  if (approvalGatedEntries.length > 0) {
    report.approval_gated_unknowns = approvalGatedEntries.map((entry) => ({
      evidence_class: entry.evidence_class,
      source_refs: entry.source_refs
    }));
  }

  const contradictionNote = buildContradictionNote(contradictions, healthClass);
  if (contradictionNote) {
    report.contradiction_note = contradictionNote;
  }

  if (contradictions.length > 0 && contradictions.every((entry) => entry.contradiction_reconcilable)) {
    report.reconciliation_note = "Contradictions remain inside degraded posture only because root can reconcile them from admitted evidence without live or protected access.";
  }

  return {
    ok: true,
    report,
    diagnostics: {
      derivative_only_evidence_classes_seen: uniqueEvidenceClasses(admittedEntries).filter((entry) => DERIVATIVE_ONLY_EVIDENCE_CLASSES.has(entry)),
      forbidden_evidence_classes_seen: uniqueEvidenceClasses(forbiddenEntries)
    }
  };
}

async function loadJson(filePath) {
  const raw = await fs.readFile(filePath, "utf8");
  const normalized = raw.charCodeAt(0) === 0xFEFF ? raw.slice(1) : raw;
  return JSON.parse(normalized);
}

function formatUsage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --input <bundle.json>`,
    "",
    "Evaluates an awareness-only _stack vercel-health evidence bundle.",
    "No-execution guard: this packet may implement awareness-only read, classification, and report rendering over already-admitted evidence classes, but it may not execute Vercel operations, mutate any surface, inspect protected live state, or imply deploy/runtime proof."
  ].join("\n");
}

async function main(argv) {
  const args = [...argv];

  if (args.includes("--help") || args.includes("-h")) {
    console.log(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const inputIndex = args.indexOf("--input");
  if (inputIndex === -1 || !args[inputIndex + 1]) {
    console.error("Missing required --input <bundle.json> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  try {
    const bundlePath = path.resolve(process.cwd(), args[inputIndex + 1]);
    const bundle = await loadJson(bundlePath);
    const result = evaluateVercelHealth(bundle);

    if (!result.ok) {
      console.error(JSON.stringify({
        ok: false,
        errors: result.errors
      }, null, 2));
      return 1;
    }

    console.log(JSON.stringify({
      ok: true,
      report: result.report,
      diagnostics: result.diagnostics
    }, null, 2));
    return 0;
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      errors: [error instanceof Error ? error.message : String(error)]
    }, null, 2));
    return 1;
  }
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  const exitCode = await main(process.argv.slice(2));
  process.exit(exitCode);
}
