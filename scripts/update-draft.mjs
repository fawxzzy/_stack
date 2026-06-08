#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack update draft";
const ADMITTED_REPO = "repos/fawxzzy-fitness";
const PACKAGE_STATUS = "downstream-consumption-only";
const PACKAGE_FIELDS = Object.freeze([
  "repo identity",
  "proof and ledger refs",
  "deployment metadata slots already present in proof basis",
  "shipped-evidence or release-note slots already present in ledger basis",
  "downstream-consumption-only label"
]);

const ROUTING_NOTES = Object.freeze({
  packageReady: "package downstream-consumption only from exact proof and ledger basis",
  packageReadyPlusContext:
    "package downstream-consumption only from exact proof and ledger basis plus one same-story context",
  receiptContextIgnored:
    "package downstream-consumption only from exact proof and ledger basis and ignore inadmissible receipt context",
  invalidInput: "fix invocation and rerun before packaging",
  repoUnadmitted: "keep helper scoped to the admitted Fitness release-to-update class",
  proofMissing: "cite one exact admitted owner proof basis before packaging",
  ledgerMissing: "cite one exact admitted owner ledger basis before packaging",
  proofLedgerContradiction: "reconcile owner proof and ledger truth before packaging",
  packageBasisUnavailable: "restore one exact same-story proof-plus-ledger basis before packaging"
});

const FAILURE_CODES = new Set([
  "invalid-input",
  "repo-unadmitted",
  "proof-missing",
  "ledger-missing",
  "proof-ledger-contradiction",
  "package-basis-unavailable"
]);

const FAILURE_SCOPES = new Set([
  "input",
  "repo-target",
  "proof-basis",
  "ledger-basis",
  "proof-ledger-story",
  "package-basis"
]);

const PACKAGE_MODES = new Set(["package-ready", "package-ready-plus-context"]);
const CONTEXT_STATUSES = new Set(["not-requested", "agreed", "ignored-as-inadmissible"]);
const CONTEXT_FALLBACK_REASONS = new Set([
  "receipt-context-conflicts-with-proof-ledger-story",
  "receipt-context-not-same-story",
  "receipt-context-missing-bounded-context-note"
]);

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

function normalizeWhitespace(value) {
  return value.replace(/\s+/g, " ").trim();
}

function normalizeUrl(value) {
  return value.trim().replace(/\/+$/, "");
}

function normalizeRepo(value) {
  return normalizeRelativePath(value).toLowerCase();
}

function extractMarkdownSection(text, heading) {
  const lines = text.split(/\r?\n/);
  const target = `## ${heading}`;
  const startIndex = lines.findIndex((line) => line.trim() === target);
  if (startIndex === -1) {
    return null;
  }

  let endIndex = lines.length;
  for (let index = startIndex + 1; index < lines.length; index += 1) {
    if (/^##\s+/.test(lines[index])) {
      endIndex = index;
      break;
    }
  }

  return lines.slice(startIndex + 1, endIndex).join("\n").trim();
}

function extractFirstListOrParagraph(sectionText) {
  if (!isNonEmptyString(sectionText)) {
    return null;
  }

  for (const rawLine of sectionText.split(/\r?\n/)) {
    const trimmed = rawLine.trim();
    if (!trimmed) {
      continue;
    }

    if (trimmed.startsWith("- ")) {
      return normalizeWhitespace(trimmed.slice(2));
    }

    return normalizeWhitespace(trimmed);
  }

  return null;
}

function extractBulletMap(sectionText) {
  const map = new Map();
  if (!isNonEmptyString(sectionText)) {
    return map;
  }

  for (const rawLine of sectionText.split(/\r?\n/)) {
    const trimmed = rawLine.trim();
    const match = trimmed.match(/^- ([^:]+):\s*(.+)$/);
    if (!match) {
      continue;
    }

    map.set(match[1].trim().toLowerCase(), match[2].trim().replace(/^`|`$/g, ""));
  }

  return map;
}

function extractListSection(sectionText) {
  if (!isNonEmptyString(sectionText)) {
    return [];
  }

  return sectionText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("- "))
    .map((line) => normalizeWhitespace(line.slice(2)));
}

function contradictionNote(scope, conflictingRefs, summaryConsequence) {
  return {
    contradiction_scope: scope,
    conflicting_refs: [...conflictingRefs],
    summary_consequence: summaryConsequence
  };
}

function buildFailure({ failureCode, failureScope, message, routingNote, contradictionNotePayload }) {
  if (!FAILURE_CODES.has(failureCode)) {
    throw new Error(`Unsupported failure code: ${failureCode}`);
  }

  if (!FAILURE_SCOPES.has(failureScope)) {
    throw new Error(`Unsupported failure scope: ${failureScope}`);
  }

  const report = {
    command: COMMAND_ID,
    failure_code: failureCode,
    failure_scope: failureScope,
    message,
    routing_note: routingNote
  };

  if (contradictionNotePayload) {
    report.contradiction_note = contradictionNotePayload;
  }

  return report;
}

function buildSuccess({
  repo,
  packageMode,
  proofRef,
  ledgerRef,
  contextStatus,
  routingNote,
  receiptContext,
  deploymentMetadata,
  ledgerNotes,
  contextNote,
  contextFallbackReason,
  contradictionNotePayload
}) {
  if (!PACKAGE_MODES.has(packageMode)) {
    throw new Error(`Unsupported package mode: ${packageMode}`);
  }

  if (!CONTEXT_STATUSES.has(contextStatus)) {
    throw new Error(`Unsupported context status: ${contextStatus}`);
  }

  if (contextFallbackReason && !CONTEXT_FALLBACK_REASONS.has(contextFallbackReason)) {
    throw new Error(`Unsupported context fallback reason: ${contextFallbackReason}`);
  }

  const report = {
    command: COMMAND_ID,
    repo,
    package_mode: packageMode,
    package_status: PACKAGE_STATUS,
    proof_ref: proofRef,
    ledger_ref: ledgerRef,
    package_fields: [...PACKAGE_FIELDS],
    context_status: contextStatus,
    routing_note: routingNote
  };

  if (receiptContext) {
    report.receipt_context = receiptContext;
  }

  if (deploymentMetadata && Object.keys(deploymentMetadata).length > 0) {
    report.deployment_metadata = deploymentMetadata;
  }

  if (ledgerNotes && Object.keys(ledgerNotes).length > 0) {
    report.ledger_notes = ledgerNotes;
  }

  if (contextNote) {
    report.context_note = contextNote;
  }

  if (contextFallbackReason) {
    report.context_fallback_reason = contextFallbackReason;
  }

  if (contradictionNotePayload) {
    report.contradiction_note = contradictionNotePayload;
  }

  return report;
}

function parseArgs(argv) {
  const args = [...argv];
  const parsed = {
    format: "text",
    repo: undefined,
    proofRef: undefined,
    ledgerRef: undefined,
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

    if (token === "--repo") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--repo requires one admitted repo path.");
      } else {
        parsed.repo = value.trim();
      }
      index += 1;
      continue;
    }

    if (token === "--proof-ref") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--proof-ref requires one bounded relative path.");
      } else {
        parsed.proofRef = value.trim();
      }
      index += 1;
      continue;
    }

    if (token === "--ledger-ref") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--ledger-ref requires one bounded relative path.");
      } else {
        parsed.ledgerRef = value.trim();
      }
      index += 1;
      continue;
    }

    if (token === "--receipt-context") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--receipt-context requires one bounded relative path.");
      } else {
        parsed.receiptContext = value.trim();
      }
      index += 1;
      continue;
    }

    errors.push(`Unsupported argument: ${token}`);
  }

  if (!isNonEmptyString(parsed.repo)) {
    errors.push("--repo is required.");
  }

  if (!isNonEmptyString(parsed.proofRef)) {
    errors.push("--proof-ref is required.");
  }

  if (!isNonEmptyString(parsed.ledgerRef)) {
    errors.push("--ledger-ref is required.");
  }

  if (parsed.repo && !isRelativePath(parsed.repo)) {
    errors.push("--repo must be a relative repo path.");
  }

  if (parsed.proofRef && !isRelativePath(parsed.proofRef)) {
    errors.push("--proof-ref must be a bounded relative path.");
  }

  if (parsed.ledgerRef && !isRelativePath(parsed.ledgerRef)) {
    errors.push("--ledger-ref must be a bounded relative path.");
  }

  if (parsed.receiptContext && !isRelativePath(parsed.receiptContext)) {
    errors.push("--receipt-context must be a bounded relative path.");
  }

  return errors.length > 0 ? { ok: false, errors } : { ok: true, args: parsed };
}

function getWorkspaceRoot() {
  if (isNonEmptyString(process.env.STACK_UPDATE_DRAFT_WORKSPACE_ROOT)) {
    return path.resolve(process.env.STACK_UPDATE_DRAFT_WORKSPACE_ROOT);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

async function defaultReadText(filePath) {
  const text = await fs.readFile(filePath, "utf8");
  return stripBom(text);
}

function parseReleaseNote(text) {
  const versionMatch = text.match(/^#\s+Fitness Release:\s+(.+)$/m);
  const releaseFactsSection = extractMarkdownSection(text, "Release Facts");
  const releaseFacts = extractBulletMap(releaseFactsSection);
  const summary = extractFirstListOrParagraph(extractMarkdownSection(text, "Summary"));

  const proof = {
    version: versionMatch ? normalizeWhitespace(versionMatch[1]) : null,
    app: releaseFacts.get("app") || null,
    environment: releaseFacts.get("environment") || null,
    branch: releaseFacts.get("branch") || null,
    commit: releaseFacts.get("commit") || null,
    previousCommit: releaseFacts.get("previous commit") || null,
    deployedAt: releaseFacts.get("deployed at") || null,
    productionUrl: releaseFacts.get("production url") || null,
    deploymentUrl: releaseFacts.get("deployment url") || null,
    summary
  };

  if (
    !isNonEmptyString(proof.version) ||
    !isNonEmptyString(proof.app) ||
    !isNonEmptyString(proof.environment) ||
    !isNonEmptyString(proof.branch) ||
    !isNonEmptyString(proof.commit) ||
    !isNonEmptyString(proof.deployedAt)
  ) {
    return null;
  }

  return proof;
}

function parseJsonLines(text) {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

function hasOwnString(value, key) {
  return Object.prototype.hasOwnProperty.call(value, key) && isNonEmptyString(value[key]);
}

function selectLedgerEntry(entries, proof) {
  const byVersion = entries.filter((entry) => hasOwnString(entry, "version") && entry.version === proof.version);
  const exact = byVersion.find((entry) => hasOwnString(entry, "commit") && entry.commit === proof.commit);
  if (exact) {
    return exact;
  }

  if (byVersion.length === 1) {
    return byVersion[0];
  }

  const byCommit = entries.filter((entry) => hasOwnString(entry, "commit") && entry.commit === proof.commit);
  if (byCommit.length === 1) {
    return byCommit[0];
  }

  return null;
}

function compareProofAndLedger(proof, ledgerEntry) {
  if (proof.version !== ledgerEntry.version || proof.app !== ledgerEntry.app) {
    return {
      scope: "release-story",
      message: "The cited proof and ledger basis do not describe one exact release story."
    };
  }

  if (normalizeWhitespace(proof.environment).toLowerCase() !== normalizeWhitespace(ledgerEntry.environment).toLowerCase()) {
    return {
      scope: "production-posture",
      message: "The cited proof and ledger basis disagree on production posture."
    };
  }

  if (
    proof.commit !== ledgerEntry.commit ||
    normalizeWhitespace(proof.branch) !== normalizeWhitespace(ledgerEntry.branch) ||
    (
      isNonEmptyString(proof.productionUrl) &&
      isNonEmptyString(ledgerEntry.prodUrl) &&
      normalizeUrl(proof.productionUrl) !== normalizeUrl(ledgerEntry.prodUrl)
    )
  ) {
    return {
      scope: "commit-or-target",
      message: "The cited proof and ledger basis disagree on commit or deployment target."
    };
  }

  return null;
}

function buildDeploymentMetadata(proof) {
  const metadata = {
    version: proof.version,
    app: proof.app,
    environment: proof.environment,
    branch: proof.branch,
    commit: proof.commit,
    deployed_at: proof.deployedAt
  };

  if (isNonEmptyString(proof.previousCommit)) {
    metadata.previous_commit = proof.previousCommit;
  }

  if (isNonEmptyString(proof.productionUrl)) {
    metadata.production_url = proof.productionUrl;
  }

  if (isNonEmptyString(proof.deploymentUrl)) {
    metadata.deployment_url = proof.deploymentUrl;
  }

  if (isNonEmptyString(proof.summary)) {
    metadata.summary = proof.summary;
  }

  return metadata;
}

function buildLedgerNotes(entry) {
  const notes = {
    version: entry.version
  };

  if (Array.isArray(entry.lanes) && entry.lanes.length > 0) {
    notes.lanes = [...entry.lanes];
  }

  if (Array.isArray(entry.userFacingChanges) && entry.userFacingChanges.length > 0) {
    notes.user_facing_changes = [...entry.userFacingChanges];
  }

  if (Array.isArray(entry.internalChanges) && entry.internalChanges.length > 0) {
    notes.internal_changes = [...entry.internalChanges];
  }

  if (Array.isArray(entry.verification) && entry.verification.length > 0) {
    notes.verification = [...entry.verification];
  }

  if (Array.isArray(entry.artifacts) && entry.artifacts.length > 0) {
    notes.artifacts = [...entry.artifacts];
  }

  if (Array.isArray(entry.knownGaps) && entry.knownGaps.length > 0) {
    notes.known_gaps = [...entry.knownGaps];
  }

  return notes;
}

async function loadProofBasis({ workspaceRoot, proofRef, readText }) {
  const filePath = path.join(workspaceRoot, normalizeRelativePath(proofRef));
  let text;
  try {
    text = await readText(filePath);
  } catch {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "proof-missing",
        failureScope: "proof-basis",
        message: "The cited owner proof basis is missing.",
        routingNote: ROUTING_NOTES.proofMissing
      })
    };
  }

  const proof = parseReleaseNote(text);
  if (!proof) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "package-basis-unavailable",
        failureScope: "proof-basis",
        message: "The cited owner proof basis does not expose the admitted release facts.",
        routingNote: ROUTING_NOTES.packageBasisUnavailable
      })
    };
  }

  return {
    ok: true,
    proof
  };
}

async function loadLedgerBasis({ workspaceRoot, proofRef, ledgerRef, proof, readText }) {
  const filePath = path.join(workspaceRoot, normalizeRelativePath(ledgerRef));
  let text;
  try {
    text = await readText(filePath);
  } catch {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "ledger-missing",
        failureScope: "ledger-basis",
        message: "The cited owner ledger basis is missing.",
        routingNote: ROUTING_NOTES.ledgerMissing
      })
    };
  }

  let entries;
  try {
    entries = parseJsonLines(text);
  } catch {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "package-basis-unavailable",
        failureScope: "ledger-basis",
        message: "The cited owner ledger basis does not expose one admitted release entry.",
        routingNote: ROUTING_NOTES.packageBasisUnavailable
      })
    };
  }

  const selected = selectLedgerEntry(entries, proof);
  if (!selected) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "package-basis-unavailable",
        failureScope: "package-basis",
        message: "The cited proof and ledger basis do not resolve to one exact release story.",
        routingNote: ROUTING_NOTES.packageBasisUnavailable
      })
    };
  }

  if (
    !hasOwnString(selected, "version") ||
    !hasOwnString(selected, "app") ||
    !hasOwnString(selected, "environment") ||
    !hasOwnString(selected, "branch") ||
    !hasOwnString(selected, "commit")
  ) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "package-basis-unavailable",
        failureScope: "ledger-basis",
        message: "The cited owner ledger basis is missing admitted release fields.",
        routingNote: ROUTING_NOTES.packageBasisUnavailable
      })
    };
  }

  const contradiction = compareProofAndLedger(proof, selected);
  if (contradiction) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "proof-ledger-contradiction",
        failureScope: "proof-ledger-story",
        message: contradiction.message,
        routingNote: ROUTING_NOTES.proofLedgerContradiction,
        contradictionNotePayload: contradictionNote(
          contradiction.scope,
          [normalizeRelativePath(proofRef), normalizeRelativePath(ledgerRef)],
          "no-package"
        )
      })
    };
  }

  return {
    ok: true,
    ledgerEntry: selected
  };
}

function parseReceiptStory(text) {
  const commitMatch = text.match(/(?:^|\n)-\s*Commit:\s*`?([0-9a-f]{7,40})`?/i);
  const versionTitleMatch = text.match(/^#\s+Fitness Release:\s+(.+)$/m);
  const versionLineMatch = text.match(/(?:^|\n)-\s*(?:Version|Release(?: version)?):\s*`?([A-Za-z0-9._-]+)`?/i);

  const contextNote = [
    extractFirstListOrParagraph(extractMarkdownSection(text, "Deployment Context")),
    extractFirstListOrParagraph(extractMarkdownSection(text, "Context")),
    extractFirstListOrParagraph(extractMarkdownSection(text, "Summary")),
    extractFirstListOrParagraph(extractMarkdownSection(text, "Result")),
    extractFirstListOrParagraph(extractMarkdownSection(text, "Blocked State"))
  ].find((value) => isNonEmptyString(value)) || null;

  return {
    version: versionTitleMatch
      ? normalizeWhitespace(versionTitleMatch[1])
      : versionLineMatch
        ? normalizeWhitespace(versionLineMatch[1])
        : null,
    commit: commitMatch ? commitMatch[1] : null,
    contextNote
  };
}

async function evaluateReceiptContext({
  workspaceRoot,
  receiptContext,
  proofRef,
  ledgerRef,
  proof,
  readText
}) {
  const filePath = path.join(workspaceRoot, normalizeRelativePath(receiptContext));
  let text;
  try {
    text = await readText(filePath);
  } catch {
    return {
      status: "invalid-input"
    };
  }

  const receipt = parseReceiptStory(text);
  if (!isNonEmptyString(receipt.version) && !isNonEmptyString(receipt.commit)) {
    return {
      status: "ignored",
      contextFallbackReason: "receipt-context-not-same-story"
    };
  }

  if (
    (isNonEmptyString(receipt.version) && receipt.version !== proof.version) ||
    (isNonEmptyString(receipt.commit) && receipt.commit !== proof.commit)
  ) {
    return {
      status: "ignored",
      contextFallbackReason: "receipt-context-conflicts-with-proof-ledger-story",
      contradictionNotePayload: contradictionNote(
        "receipt-context",
        [
          normalizeRelativePath(proofRef),
          normalizeRelativePath(ledgerRef),
          normalizeRelativePath(receiptContext)
        ],
        "package-ready-without-context"
      )
    };
  }

  if (!isNonEmptyString(receipt.contextNote)) {
    return {
      status: "ignored",
      contextFallbackReason: "receipt-context-missing-bounded-context-note"
    };
  }

  return {
    status: "agreed",
    contextNote: receipt.contextNote
  };
}

function renderPackageFields() {
  return PACKAGE_FIELDS.join("; ");
}

function renderContextLine(report) {
  const parts = [];
  if (report.deployment_metadata) {
    const meta = [];
    if (report.deployment_metadata.version) {
      meta.push(`version=${report.deployment_metadata.version}`);
    }
    if (report.deployment_metadata.commit) {
      meta.push(`commit=${report.deployment_metadata.commit}`);
    }
    if (report.deployment_metadata.deployed_at) {
      meta.push(`deployed_at=${report.deployment_metadata.deployed_at}`);
    }
    if (report.deployment_metadata.deployment_url) {
      meta.push(`deployment_url=${report.deployment_metadata.deployment_url}`);
    }
    if (meta.length > 0) {
      parts.push(`deployment_metadata=${meta.join(", ")}`);
    }
  }

  if (report.ledger_notes) {
    const ledger = [];
    if (report.ledger_notes.version) {
      ledger.push(`version=${report.ledger_notes.version}`);
    }
    if (Array.isArray(report.ledger_notes.user_facing_changes)) {
      ledger.push(`user_facing_changes=${report.ledger_notes.user_facing_changes.length}`);
    }
    if (Array.isArray(report.ledger_notes.internal_changes)) {
      ledger.push(`internal_changes=${report.ledger_notes.internal_changes.length}`);
    }
    if (ledger.length > 0) {
      parts.push(`ledger_notes=${ledger.join(", ")}`);
    }
  }

  if (report.receipt_context) {
    parts.push(`receipt_context=${report.receipt_context}`);
  }

  if (report.context_note) {
    parts.push(`context_note=${report.context_note}`);
  }

  return parts.join(" | ");
}

function renderText(result) {
  if (result.ok) {
    const lines = [
      `package_status=${result.report.package_status}`,
      `repo=${result.report.repo}`,
      `proof_ref=${result.report.proof_ref} | ledger_ref=${result.report.ledger_ref}`,
      `package_fields=${renderPackageFields()}`
    ];

    if (result.report.package_mode === "package-ready-plus-context") {
      const contextLine = renderContextLine(result.report);
      if (isNonEmptyString(contextLine)) {
        lines.push(contextLine);
      }
    }

    lines.push(`routing_note=${result.report.routing_note}`);
    return `${lines.join("\n")}\n`;
  }

  const lines = [
    `failure_code=${result.report.failure_code}`,
    `message=${result.report.message}`
  ];

  if (result.report.contradiction_note) {
    lines.push(`contradiction_scope=${result.report.contradiction_note.contradiction_scope}`);
    lines.push(`conflicting_refs=${result.report.contradiction_note.conflicting_refs.join(", ")}`);
    lines.push(`summary_consequence=${result.report.contradiction_note.summary_consequence}`);
  }

  lines.push(`routing_note=${result.report.routing_note}`);
  return `${lines.join("\n")}\n`;
}

export async function runUpdateDraftCommand(argv, dependencies = {}) {
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
  const readText = dependencies.readText || defaultReadText;
  const repo = normalizeRelativePath(parsed.args.repo);

  if (normalizeRepo(repo) !== normalizeRepo(ADMITTED_REPO)) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "repo-unadmitted",
        failureScope: "repo-target",
        message: "The requested repo is outside the admitted Fitness release-to-update class.",
        routingNote: ROUTING_NOTES.repoUnadmitted
      })
    };
  }

  const proofResult = await loadProofBasis({
    workspaceRoot,
    proofRef: parsed.args.proofRef,
    readText
  });
  if (!proofResult.ok) {
    return proofResult;
  }

  const ledgerResult = await loadLedgerBasis({
    workspaceRoot,
    proofRef: parsed.args.proofRef,
    ledgerRef: parsed.args.ledgerRef,
    proof: proofResult.proof,
    readText
  });
  if (!ledgerResult.ok) {
    return ledgerResult;
  }

  const deploymentMetadata = buildDeploymentMetadata(proofResult.proof);
  const ledgerNotes = buildLedgerNotes(ledgerResult.ledgerEntry);

  if (!parsed.args.receiptContext) {
    return {
      ok: true,
      report: buildSuccess({
        repo,
        packageMode: "package-ready",
        proofRef: normalizeRelativePath(parsed.args.proofRef),
        ledgerRef: normalizeRelativePath(parsed.args.ledgerRef),
        contextStatus: "not-requested",
        routingNote: ROUTING_NOTES.packageReady,
        deploymentMetadata,
        ledgerNotes
      })
    };
  }

  const receiptResult = await evaluateReceiptContext({
    workspaceRoot,
    receiptContext: parsed.args.receiptContext,
    proofRef: parsed.args.proofRef,
    ledgerRef: parsed.args.ledgerRef,
    proof: proofResult.proof,
    readText
  });

  if (receiptResult.status === "invalid-input") {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-input",
        failureScope: "input",
        message: "The cited receipt context must resolve to one durable relative receipt path.",
        routingNote: ROUTING_NOTES.invalidInput
      })
    };
  }

  if (receiptResult.status === "ignored") {
    return {
      ok: true,
      report: buildSuccess({
        repo,
        packageMode: "package-ready",
        proofRef: normalizeRelativePath(parsed.args.proofRef),
        ledgerRef: normalizeRelativePath(parsed.args.ledgerRef),
        contextStatus: "ignored-as-inadmissible",
        routingNote: ROUTING_NOTES.receiptContextIgnored,
        receiptContext: normalizeRelativePath(parsed.args.receiptContext),
        deploymentMetadata,
        ledgerNotes,
        contextFallbackReason: receiptResult.contextFallbackReason,
        contradictionNotePayload: receiptResult.contradictionNotePayload
      })
    };
  }

  return {
    ok: true,
    report: buildSuccess({
      repo,
      packageMode: "package-ready-plus-context",
      proofRef: normalizeRelativePath(parsed.args.proofRef),
      ledgerRef: normalizeRelativePath(parsed.args.ledgerRef),
      contextStatus: "agreed",
      routingNote: ROUTING_NOTES.packageReadyPlusContext,
      receiptContext: normalizeRelativePath(parsed.args.receiptContext),
      deploymentMetadata,
      ledgerNotes,
      contextNote: receiptResult.contextNote
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --repo <relative-repo-path> --proof-ref <relative-path> --ledger-ref <relative-path> [--format text|json] [--receipt-context <relative-path>]`,
    "",
    "Reads one admitted Fitness repo target, one cited owner release note, one cited owner release ledger, optionally compares one same-story receipt context, and emits the bounded downstream-only update-draft package contract.",
    "No-execution guard: this packet may admit future implementation of admitted repo-target validation, one cited owner-proof load, one cited owner-ledger load, one optional cited-receipt comparison, contradiction classification, and downstream-only package rendering for stack update draft, but it may not mutate owner proof or ledger surfaces, mutate Discord or ATLAS surfaces, synthesize final wording, widen beyond the admitted Fitness release-to-update class, or imply deploy/publication/owner-readiness proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runUpdateDraftCommand(argv);
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
