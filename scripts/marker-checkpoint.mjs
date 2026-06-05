#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack marker checkpoint";
const AUTHORITATIVE_REF = "docs/atlas-book/02-lanes-and-markers.md";
const RESTART_REFS = Object.freeze([
  "docs/atlas-book/01-current-state.md",
  "docs/atlas-book/11-system-map-graph.md",
  "docs/atlas-book/12-restart-and-handoff-guide.md"
]);

const ROUTING_NOTES = Object.freeze({
  checkpointOnly: "package checkpoint only and continue",
  checkpointPlusContext: "package checkpoint plus exact restart context and continue",
  invalidInput: "fix invocation and rerun before packaging",
  sourceMissing: "restore required marker or restart surfaces before packaging",
  sourceContradiction: "repair authoritative marker truth before packaging",
  laneUnavailable: "fix lane selection or reroute before packaging",
  checkpointContextUnavailable:
    "package checkpoint only and route to one bounded restart-surface or cited-receipt reconciliation packet"
});

const FAILURE_CODES = new Set([
  "invalid-input",
  "source-missing",
  "source-contradiction",
  "lane-unavailable",
  "checkpoint-context-unavailable"
]);

const SCOPES = new Set(["front-page", "lane"]);
const CONTEXT_STATUSES = new Set(["not-requested", "agreed", "unavailable"]);
const REPORT_MODES = new Set(["checkpoint-only", "checkpoint-plus-context"]);
const CONTEXT_UNAVAILABLE_REASONS = new Set(["restart-context-not-frozen"]);

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function stripBom(value) {
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value;
}

function stripInlineMarkdown(value) {
  return value.replaceAll("`", "").replaceAll("*", "").replaceAll("_", "_").trim();
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

function normalizeLaneName(value) {
  return stripInlineMarkdown(value)
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function unique(values) {
  return [...new Set(values)];
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

  return lines.slice(startIndex, endIndex).join("\n").trim();
}

function parseMarkerSection(sectionBlock) {
  if (!isNonEmptyString(sectionBlock)) {
    return [];
  }

  const lines = sectionBlock.split(/\r?\n/);
  const heading = lines[0].trim();
  const markers = [];

  for (const line of lines.slice(1)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("- ")) {
      continue;
    }

    const markerMatch = trimmed.match(/^- (.+?):\s+`?([^`]+?)`?\s*$/);
    if (!markerMatch) {
      continue;
    }

    const displayName = stripInlineMarkdown(markerMatch[1]).replace(/\s+/g, " ").trim();
    markers.push({
      heading,
      rawLine: trimmed,
      displayName,
      normalizedName: normalizeLaneName(displayName),
      value: markerMatch[2].trim()
    });
  }

  return markers;
}

function extractSingleMatch(text, patterns) {
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match) {
      return stripInlineMarkdown(match[1]).replace(/\s+/g, " ").trim();
    }
  }

  return null;
}

function extractSystemMapRow(text) {
  const line = text
    .split(/\r?\n/)
    .find((candidate) => candidate.includes("| ATLAS systems lane |"));

  if (!line) {
    return null;
  }

  const cells = line
    .split("|")
    .map((cell) => cell.trim())
    .filter((cell) => cell.length > 0);

  if (cells.length < 6) {
    return null;
  }

  return {
    currentStatus: cells[3],
    nextPackage: stripInlineMarkdown(cells[5]).replace(/\s+/g, " ").trim()
  };
}

function parseRestartSurface(ref, text) {
  const systemMapRow = extractSystemMapRow(text);

  return {
    ref,
    activeLane: extractSingleMatch(text, [
      /^-\s+`([^`]+)` now has one automation-candidate threshold packet:/im,
      /current immediate control-plane family is `([^`]+)`/i,
      /selects `([^`]+)` as the immediate ATLAS-side lane/i,
      /active governance lane now routes .*? into `([^`]+)`/i,
      /the active immediate family is still `([^`]+)`/i
    ]),
    supportingLane: extractSingleMatch(text, [
      /`([^`]+)` is now the current supporting lane for both admitted families/i,
      /the first real supporting dependency is now `([^`]+)`/i,
      /the only admitted support lane is `([^`]+)`/i,
      /`([^`]+)` is now the only admitted support lane/i,
      /`([^`]+)` now supports both admitted families/i
    ]),
    nextPackage: systemMapRow?.nextPackage || extractSingleMatch(text, [
      /the next active AI-pipeline packet is now `([^`]+)`/i,
      /the exact next ATLAS-side lane package is now `([^`]+)`/i,
      /and the exact next packet becomes `([^`]+)`/i
    ])
  };
}

function buildConsensus(surfaces, fieldName) {
  const observed = surfaces
    .map((surface) => ({
      ref: surface.ref,
      value: surface[fieldName]
    }))
    .filter((entry) => isNonEmptyString(entry.value));

  if (observed.length === 0) {
    return {
      status: "missing",
      refs: []
    };
  }

  const normalizedValues = unique(observed.map((entry) => normalizeLaneName(entry.value)));
  if (normalizedValues.length > 1) {
    return {
      status: "contradiction",
      refs: observed.map((entry) => entry.ref),
      values: observed.map((entry) => entry.value)
    };
  }

  if (observed.length !== surfaces.length) {
    return {
      status: "missing",
      refs: observed.map((entry) => entry.ref),
      value: observed[0].value
    };
  }

  return {
    status: "agreed",
    refs: observed.map((entry) => entry.ref),
    value: observed[0].value
  };
}

function buildFailure({
  failureCode,
  failureScope,
  message,
  routingNote,
  checkpoint,
  authoritativeRef,
  supportingRefs,
  contradictionNote
}) {
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

  if (failureCode === "checkpoint-context-unavailable") {
    if (checkpoint) {
      report.checkpoint = checkpoint;
    }

    if (authoritativeRef) {
      report.authoritative_ref = authoritativeRef;
    }

    if (supportingRefs) {
      report.supporting_refs = [...supportingRefs];
    }

    if (contradictionNote) {
      report.contradiction_note = contradictionNote;
    }
  }

  return report;
}

function buildSuccess({
  scope,
  checkpoint,
  contextStatus,
  reportMode,
  supportingRefs,
  routingNote,
  lane,
  supportingPosture,
  nextPackage,
  receiptContext,
  contextUnavailableReason
}) {
  if (!SCOPES.has(scope)) {
    throw new Error(`Unsupported scope: ${scope}`);
  }

  if (!CONTEXT_STATUSES.has(contextStatus)) {
    throw new Error(`Unsupported context status: ${contextStatus}`);
  }

  if (!REPORT_MODES.has(reportMode)) {
    throw new Error(`Unsupported report mode: ${reportMode}`);
  }

  if (contextUnavailableReason && !CONTEXT_UNAVAILABLE_REASONS.has(contextUnavailableReason)) {
    throw new Error(`Unsupported context unavailable reason: ${contextUnavailableReason}`);
  }

  const report = {
    command: COMMAND_ID,
    scope,
    checkpoint,
    authoritative_ref: AUTHORITATIVE_REF,
    context_status: contextStatus,
    report_mode: reportMode,
    supporting_refs: [...supportingRefs],
    routing_note: routingNote
  };

  if (lane) {
    report.lane = lane;
  }

  if (supportingPosture) {
    report.supporting_posture = supportingPosture;
  }

  if (nextPackage) {
    report.next_package = nextPackage;
  }

  if (receiptContext) {
    report.receipt_context = receiptContext;
  }

  if (contextUnavailableReason) {
    report.context_unavailable_reason = contextUnavailableReason;
  }

  return report;
}

function parseArgs(argv) {
  const args = [...argv];
  const parsed = {
    format: "text",
    scope: undefined,
    lane: undefined,
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

    if (token === "--scope") {
      const value = args[index + 1];
      if (!value || !SCOPES.has(value)) {
        errors.push("--scope must be front-page or lane.");
      } else {
        parsed.scope = value;
      }
      index += 1;
      continue;
    }

    if (token === "--lane") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--lane requires a marker or lane name.");
      } else {
        parsed.lane = value.trim();
      }
      index += 1;
      continue;
    }

    if (token === "--receipt-context") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--receipt-context requires a bounded relative path.");
      } else {
        parsed.receiptContext = value;
      }
      index += 1;
      continue;
    }

    errors.push(`Unsupported argument: ${token}`);
  }

  if (!parsed.scope) {
    errors.push("--scope is required.");
  }

  if (parsed.scope === "lane" && !isNonEmptyString(parsed.lane)) {
    errors.push("--lane is required when --scope lane is used.");
  }

  if (parsed.scope === "front-page" && parsed.lane) {
    errors.push("--lane may only be used when --scope lane is selected.");
  }

  if (parsed.receiptContext !== undefined && !isRelativePath(parsed.receiptContext)) {
    errors.push("--receipt-context must be a bounded relative path.");
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
  if (isNonEmptyString(process.env.STACK_MARKER_CHECKPOINT_WORKSPACE_ROOT)) {
    return path.resolve(process.env.STACK_MARKER_CHECKPOINT_WORKSPACE_ROOT);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

async function defaultReadText(filePath) {
  return stripBom(await fs.readFile(filePath, "utf8"));
}

async function loadAuthoritativeCheckpoint({ workspaceRoot, scope, lane, readText }) {
  const filePath = path.join(workspaceRoot, AUTHORITATIVE_REF);

  let text;
  try {
    text = await readText(filePath);
  } catch {
    return {
      ok: false,
      type: "missing"
    };
  }

  const frontPageSection = extractMarkdownSection(text, "Active Front-Page Marker Table");
  const supportingSection = extractMarkdownSection(text, "Supporting Open Markers");

  if (!frontPageSection) {
    return {
      ok: false,
      type: "missing"
    };
  }

  const frontPageMarkers = parseMarkerSection(frontPageSection);
  const supportingMarkers = parseMarkerSection(supportingSection);

  if (frontPageMarkers.length === 0) {
    return {
      ok: false,
      type: "missing"
    };
  }

  const duplicateFrontPageNames = frontPageMarkers.map((marker) => marker.normalizedName);
  if (unique(duplicateFrontPageNames).length !== duplicateFrontPageNames.length) {
    return {
      ok: false,
      type: "contradiction"
    };
  }

  if (scope === "front-page") {
    return {
      ok: true,
      checkpoint: frontPageSection.trim()
    };
  }

  const requestedLane = normalizeLaneName(lane);
  const matches = [...frontPageMarkers, ...supportingMarkers]
    .filter((marker) => marker.normalizedName === requestedLane);

  if (matches.length === 0) {
    return {
      ok: false,
      type: "lane-unavailable"
    };
  }

  if (matches.length > 1) {
    const uniqueValues = unique(matches.map((match) => `${match.heading}|${match.rawLine}`));
    if (uniqueValues.length > 1) {
      return {
        ok: false,
        type: "contradiction"
      };
    }
  }

  const match = matches[0];

  return {
    ok: true,
    checkpoint: `${match.heading}\n${match.rawLine}`,
    lane: match.displayName
  };
}

async function loadRestartSurfaces({ workspaceRoot, readText }) {
  const surfaces = [];

  for (const ref of RESTART_REFS) {
    const filePath = path.join(workspaceRoot, ref);
    let text;
    try {
      text = await readText(filePath);
    } catch {
      return {
        ok: false,
        type: "missing"
      };
    }

    surfaces.push(parseRestartSurface(ref, text));
  }

  return {
    ok: true,
    surfaces
  };
}

function contradictionNote(scope, conflictingRefs, summaryConsequence = "checkpoint-only") {
  return {
    contradiction_scope: scope,
    conflicting_refs: [...conflictingRefs],
    summary_consequence: summaryConsequence
  };
}

function buildRestartContextResult({ scope, lane, checkpoint, restartSurfaces }) {
  const activeLane = buildConsensus(restartSurfaces, "activeLane");
  const supportingLane = buildConsensus(restartSurfaces, "supportingLane");
  const nextPackage = buildConsensus(restartSurfaces, "nextPackage");

  const normalizedRequestedLane = lane ? normalizeLaneName(lane) : null;

  if (scope === "front-page") {
    if (activeLane.status === "agreed" && nextPackage.status === "agreed") {
      return {
        ok: true,
        contextStatus: "agreed",
        reportMode: "checkpoint-only",
        supportingRefs: RESTART_REFS
      };
    }

    return {
      ok: true,
      contextStatus: "unavailable",
      reportMode: "checkpoint-only",
      supportingRefs: RESTART_REFS,
      contextUnavailableReason: "restart-context-not-frozen"
    };
  }

  if (nextPackage.status === "contradiction") {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "checkpoint-context-unavailable",
        failureScope: "restart-context",
        message: "The restart surfaces do not resolve to one exact next package.",
        routingNote: ROUTING_NOTES.checkpointContextUnavailable,
        checkpoint,
        authoritativeRef: AUTHORITATIVE_REF,
        supportingRefs: RESTART_REFS,
        contradictionNote: contradictionNote("restart-surfaces", nextPackage.refs)
      })
    };
  }

  if (activeLane.status === "contradiction") {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "checkpoint-context-unavailable",
        failureScope: "restart-context",
        message: "The restart surfaces do not resolve to one exact lane posture.",
        routingNote: ROUTING_NOTES.checkpointContextUnavailable,
        checkpoint,
        authoritativeRef: AUTHORITATIVE_REF,
        supportingRefs: RESTART_REFS,
        contradictionNote: contradictionNote("restart-surfaces", activeLane.refs)
      })
    };
  }

  if (supportingLane.status === "contradiction") {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "checkpoint-context-unavailable",
        failureScope: "restart-context",
        message: "The restart surfaces do not resolve to one exact supporting posture.",
        routingNote: ROUTING_NOTES.checkpointContextUnavailable,
        checkpoint,
        authoritativeRef: AUTHORITATIVE_REF,
        supportingRefs: RESTART_REFS,
        contradictionNote: contradictionNote("restart-surfaces", supportingLane.refs)
      })
    };
  }

  if (activeLane.status === "agreed" && normalizeLaneName(activeLane.value) === normalizedRequestedLane) {
    if (nextPackage.status === "agreed") {
      return {
        ok: true,
        contextStatus: "agreed",
        reportMode: "checkpoint-plus-context",
        supportingRefs: RESTART_REFS,
        supportingPosture: "immediate control-plane family",
        nextPackage: nextPackage.value
      };
    }

    return {
      ok: true,
      contextStatus: "unavailable",
      reportMode: "checkpoint-only",
      supportingRefs: RESTART_REFS,
      contextUnavailableReason: "restart-context-not-frozen"
    };
  }

  if (supportingLane.status === "agreed" && normalizeLaneName(supportingLane.value) === normalizedRequestedLane) {
    if (nextPackage.status === "agreed") {
      return {
        ok: true,
        contextStatus: "agreed",
        reportMode: "checkpoint-plus-context",
        supportingRefs: RESTART_REFS,
        supportingPosture: "current supporting lane for both admitted families",
        nextPackage: nextPackage.value
      };
    }

    return {
      ok: true,
      contextStatus: "unavailable",
      reportMode: "checkpoint-only",
      supportingRefs: RESTART_REFS,
      contextUnavailableReason: "restart-context-not-frozen"
    };
  }

  return {
    ok: true,
    contextStatus: "unavailable",
    reportMode: "checkpoint-only",
    supportingRefs: RESTART_REFS,
    contextUnavailableReason: "restart-context-not-frozen"
  };
}

function extractReceiptNextPackages(text) {
  const values = [];
  const nextPacketSection = extractMarkdownSection(text, "Exact Next Packet");
  if (nextPacketSection) {
    for (const match of nextPacketSection.matchAll(/^-+\s+`([^`]+)`/gm)) {
      values.push(stripInlineMarkdown(match[1]).replace(/\s+/g, " ").trim());
    }
  }

  for (const pattern of [
    /the exact next ATLAS-side lane package is now `([^`]+)`/ig,
    /the next active AI-pipeline packet is now `([^`]+)`/ig,
    /exact next packet(?: becomes| is now)? `([^`]+)`/ig
  ]) {
    for (const match of text.matchAll(pattern)) {
      values.push(stripInlineMarkdown(match[1]).replace(/\s+/g, " ").trim());
    }
  }

  return unique(values);
}

async function validateReceiptContext({
  workspaceRoot,
  receiptContext,
  checkpoint,
  expectedNextPackage,
  readText
}) {
  const filePath = path.join(workspaceRoot, receiptContext);
  let text;

  try {
    text = await readText(filePath);
  } catch {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-missing",
        failureScope: "restart-context",
        message: "The cited receipt context is missing or malformed.",
        routingNote: ROUTING_NOTES.sourceMissing
      })
    };
  }

  const nextPackages = extractReceiptNextPackages(text);
  if (nextPackages.length === 0) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-missing",
        failureScope: "restart-context",
        message: "The cited receipt context is missing or malformed.",
        routingNote: ROUTING_NOTES.sourceMissing
      })
    };
  }

  if (nextPackages.length > 1) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "checkpoint-context-unavailable",
        failureScope: "restart-context",
        message: "The cited receipt context does not resolve to one exact next package.",
        routingNote: ROUTING_NOTES.checkpointContextUnavailable,
        checkpoint,
        authoritativeRef: AUTHORITATIVE_REF,
        supportingRefs: RESTART_REFS,
        contradictionNote: contradictionNote("receipt-context", [receiptContext])
      })
    };
  }

  if (normalizeLaneName(nextPackages[0]) !== normalizeLaneName(expectedNextPackage)) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "checkpoint-context-unavailable",
        failureScope: "restart-context",
        message: "The cited receipt context conflicts with the current restart spine.",
        routingNote: ROUTING_NOTES.checkpointContextUnavailable,
        checkpoint,
        authoritativeRef: AUTHORITATIVE_REF,
        supportingRefs: RESTART_REFS,
        contradictionNote: contradictionNote("receipt-context", [receiptContext, ...RESTART_REFS], "no-next-package")
      })
    };
  }

  return {
    ok: true
  };
}

function renderText(result) {
  if (result.ok) {
    const refs = [AUTHORITATIVE_REF, ...result.report.supporting_refs];
    const lines = [
      result.report.checkpoint,
      `refs=${refs.join(", ")}`
    ];

    if (result.report.report_mode === "checkpoint-plus-context") {
      const contextLines = [];
      if (result.report.supporting_posture) {
        contextLines.push(`supporting_posture=${result.report.supporting_posture}`);
      }

      if (result.report.next_package) {
        contextLines.push(`next_package=${result.report.next_package}`);
      }

      if (result.report.receipt_context) {
        contextLines.push(`receipt_context=${result.report.receipt_context}`);
      }

      return `${[
        result.report.checkpoint,
        ...contextLines,
        `refs=${refs.join(", ")}`,
        `routing_note=${result.report.routing_note}`
      ].join("\n")}\n`;
    }

    lines.push(`routing_note=${result.report.routing_note}`);
    return `${lines.join("\n")}\n`;
  }

  const lines = [
    `failure_code=${result.report.failure_code}`,
    `message=${result.report.message}`
  ];

  if (result.report.failure_code === "checkpoint-context-unavailable") {
    if (result.report.checkpoint) {
      lines.push(result.report.checkpoint);
    }

    if (result.report.authoritative_ref) {
      lines.push(`authoritative_ref=${result.report.authoritative_ref}`);
    }

    if (Array.isArray(result.report.supporting_refs)) {
      lines.push(`supporting_refs=${result.report.supporting_refs.join(", ")}`);
    }

    if (result.report.contradiction_note) {
      lines.push(`contradiction_scope=${result.report.contradiction_note.contradiction_scope}`);
      lines.push(`conflicting_refs=${result.report.contradiction_note.conflicting_refs.join(", ")}`);
      lines.push(`summary_consequence=${result.report.contradiction_note.summary_consequence}`);
    }
  }

  lines.push(`routing_note=${result.report.routing_note}`);
  return `${lines.join("\n")}\n`;
}

export async function runMarkerCheckpointCommand(argv, dependencies = {}) {
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

  const authoritative = await loadAuthoritativeCheckpoint({
    workspaceRoot,
    scope: parsed.args.scope,
    lane: parsed.args.lane,
    readText
  });

  if (!authoritative.ok) {
    if (authoritative.type === "lane-unavailable") {
      return {
        ok: false,
        report: buildFailure({
          failureCode: "lane-unavailable",
          failureScope: "requested-lane",
          message: "The requested lane is not present in the authoritative marker source.",
          routingNote: ROUTING_NOTES.laneUnavailable
        })
      };
    }

    return {
      ok: false,
      report: buildFailure({
        failureCode: authoritative.type === "contradiction" ? "source-contradiction" : "source-missing",
        failureScope: "authoritative-marker",
        message: authoritative.type === "contradiction"
          ? "The authoritative marker source does not resolve to one exact current checkpoint."
          : "The authoritative marker source is missing or malformed.",
        routingNote: authoritative.type === "contradiction"
          ? ROUTING_NOTES.sourceContradiction
          : ROUTING_NOTES.sourceMissing
      })
    };
  }

  const restart = await loadRestartSurfaces({ workspaceRoot, readText });
  if (!restart.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-missing",
        failureScope: "restart-context",
        message: "One or more required restart surfaces are missing or malformed.",
        routingNote: ROUTING_NOTES.sourceMissing
      })
    };
  }

  const restartContext = buildRestartContextResult({
    scope: parsed.args.scope,
    lane: authoritative.lane || parsed.args.lane,
    checkpoint: authoritative.checkpoint,
    restartSurfaces: restart.surfaces
  });

  if (!restartContext.ok) {
    return restartContext;
  }

  if (parsed.args.receiptContext) {
    if (restartContext.contextStatus !== "agreed" || !restartContext.nextPackage) {
      return {
        ok: false,
        report: buildFailure({
          failureCode: "checkpoint-context-unavailable",
          failureScope: "restart-context",
          message: "The cited receipt context cannot be admitted without one exact agreeing restart context.",
          routingNote: ROUTING_NOTES.checkpointContextUnavailable,
          checkpoint: authoritative.checkpoint,
          authoritativeRef: AUTHORITATIVE_REF,
          supportingRefs: RESTART_REFS
        })
      };
    }

    const receiptCheck = await validateReceiptContext({
      workspaceRoot,
      receiptContext: parsed.args.receiptContext,
      checkpoint: authoritative.checkpoint,
      expectedNextPackage: restartContext.nextPackage,
      readText
    });

    if (!receiptCheck.ok) {
      return receiptCheck;
    }
  }

  return {
    ok: true,
    report: buildSuccess({
      scope: parsed.args.scope,
      checkpoint: authoritative.checkpoint,
      contextStatus: restartContext.contextStatus,
      reportMode: restartContext.reportMode,
      supportingRefs: restartContext.supportingRefs,
      routingNote: restartContext.reportMode === "checkpoint-plus-context"
        ? ROUTING_NOTES.checkpointPlusContext
        : ROUTING_NOTES.checkpointOnly,
      lane: parsed.args.scope === "lane" ? authoritative.lane : undefined,
      supportingPosture: restartContext.supportingPosture,
      nextPackage: restartContext.nextPackage,
      receiptContext: parsed.args.receiptContext,
      contextUnavailableReason: restartContext.contextUnavailableReason
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --scope <front-page|lane> [--lane <marker-or-lane-name>] [--format text|json] [--receipt-context <relative-path>]`,
    "",
    "Reads the authoritative ATLAS marker table, checks derivative restart-surface agreement, optionally compares one cited same-story receipt, and emits the bounded marker-checkpoint contract.",
    "No-execution guard: this packet may admit future implementation of authoritative marker read, derivative restart-mirror agreement checks, one cited-receipt comparison, contradiction classification, and receipt-ready checkpoint rendering for stack marker checkpoint, but it may not mutate markers/receipts/book surfaces or owner repos, infer ratchet movement, synthesize next-package truth from uncited or conflicting sources, or imply deploy/publication/owner-readiness proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runMarkerCheckpointCommand(argv);
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
