#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack receipt package";
const AUTHORITATIVE_REFS = Object.freeze([
  "docs/atlas-book/01-current-state.md",
  "docs/atlas-book/02-lanes-and-markers.md"
]);
const RESTART_REFS = Object.freeze([
  "docs/atlas-book/11-system-map-graph.md",
  "docs/atlas-book/12-restart-and-handoff-guide.md"
]);
const PACKAGE_FIELDS = Object.freeze([
  "title and metadata slots",
  "objective and scope slots",
  "source-surface slots",
  "verification, marker-decision, and next-package slots",
  "stop-condition notes"
]);

const ROUTING_NOTES = Object.freeze({
  placeholder: "package draft-only skeleton with placeholders and continue",
  plusContext: "package draft-only skeleton plus exact agreed context and continue",
  invalidInput: "fix invocation and rerun before packaging",
  sourceMissing: "restore required lane or marker surfaces before packaging",
  sourceContradiction: "repair authoritative lane or marker truth before packaging",
  laneUnavailable: "fix lane selection or reroute before packaging",
  receiptBasisUnavailable:
    "package draft-only skeleton with placeholders and route to one bounded restart-surface or cited-receipt reconciliation packet only if filled context is still required"
});

const FAILURE_CODES = new Set([
  "invalid-input",
  "source-missing",
  "source-contradiction",
  "lane-unavailable",
  "receipt-basis-unavailable"
]);

const PACKAGE_MODES = new Set([
  "draft-skeleton-with-placeholders",
  "draft-skeleton-plus-context"
]);

const CONTEXT_STATUSES = new Set([
  "agreed",
  "placeholder-fallback"
]);

const CONTEXT_FALLBACK_REASONS = new Set([
  "restart-context-not-frozen",
  "receipt-context-not-admitted"
]);

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function stripBom(value) {
  return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value;
}

function stripInlineMarkdown(value) {
  return value.replaceAll("`", "").replaceAll("*", "").trim();
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
      rawLine: trimmed,
      displayName,
      normalizedName: normalizeLaneName(displayName),
      value: markerMatch[2].trim()
    });
  }

  return markers;
}

function extractUniqueMatches(text, patterns) {
  const values = [];
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) {
      values.push(stripInlineMarkdown(match[1]).replace(/\s+/g, " ").trim());
    }
  }

  return unique(values.filter((value) => isNonEmptyString(value)));
}

function extractCurrentStateBasis(text) {
  const activeLanes = extractUniqueMatches(text, [
    /^-\s+`([^`]+)` now has one automation-candidate threshold packet:/gim
  ]);
  const supportingLanes = extractUniqueMatches(text, [
    /the first real supporting dependency is now `([^`]+)`/gim,
    /`([^`]+)` is now also the direct supporting dependency for `receipt skeleton drafts`/gim,
    /`([^`]+)` is now the direct supporting dependency for `receipt skeleton drafts`/gim
  ]);

  return {
    activeLanes,
    supportingLanes
  };
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
    nextPackage: stripInlineMarkdown(cells[5]).replace(/\s+/g, " ").trim()
  };
}

function parseRestartSurface(ref, text) {
  const systemMapRow = extractSystemMapRow(text);

  return {
    ref,
    nextPackage: systemMapRow?.nextPackage || extractSingleMatch(text, [
      /the exact next ATLAS-side lane package is now `([^`]+)`/i,
      /the next active AI-pipeline packet is now `([^`]+)`/i,
      /exact next packet(?: becomes| is now)? `([^`]+)`/i
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

function contradictionNote(scope, conflictingRefs, summaryConsequence = "placeholders-only") {
  return {
    contradiction_scope: scope,
    conflicting_refs: [...conflictingRefs],
    summary_consequence: summaryConsequence
  };
}

function buildFailure({
  failureCode,
  failureScope,
  message,
  routingNote,
  lane,
  authoritativeRefs,
  placeholderFields,
  contradictionNotePayload
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

  if (failureCode === "receipt-basis-unavailable") {
    if (lane) {
      report.lane = lane;
    }

    report.draft_status = "draft-only";
    report.authoritative_refs = authoritativeRefs ?? [...AUTHORITATIVE_REFS];
    report.placeholder_fields = [...placeholderFields];

    if (contradictionNotePayload) {
      report.contradiction_note = contradictionNotePayload;
    }
  }

  return report;
}

function buildSuccess({
  lane,
  packageMode,
  contextStatus,
  routingNote,
  markerPercentage,
  supportingPosture,
  nextPackage,
  receiptContext,
  placeholderFields,
  contextFallbackReason
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
    lane,
    package_mode: packageMode,
    draft_status: "draft-only",
    authoritative_refs: [...AUTHORITATIVE_REFS],
    package_fields: [...PACKAGE_FIELDS],
    context_status: contextStatus,
    routing_note: routingNote
  };

  if (markerPercentage) {
    report.marker_percentage = markerPercentage;
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

  if (placeholderFields) {
    report.placeholder_fields = [...placeholderFields];
  }

  if (contextFallbackReason) {
    report.context_fallback_reason = contextFallbackReason;
  }

  return report;
}

function parseArgs(argv) {
  const args = [...argv];
  const parsed = {
    format: "text",
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

    if (token === "--lane") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--lane requires a lane name.");
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

  if (!isNonEmptyString(parsed.lane)) {
    errors.push("--lane is required.");
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
  if (isNonEmptyString(process.env.STACK_RECEIPT_PACKAGE_WORKSPACE_ROOT)) {
    return path.resolve(process.env.STACK_RECEIPT_PACKAGE_WORKSPACE_ROOT);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

async function defaultReadText(filePath) {
  return stripBom(await fs.readFile(filePath, "utf8"));
}

async function loadAuthoritativeLaneBasis({ workspaceRoot, lane, readText }) {
  let currentStateText;
  let markersText;

  try {
    [currentStateText, markersText] = await Promise.all([
      readText(path.join(workspaceRoot, AUTHORITATIVE_REFS[0])),
      readText(path.join(workspaceRoot, AUTHORITATIVE_REFS[1]))
    ]);
  } catch {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-missing",
        failureScope: "authoritative-lane",
        message: "The authoritative lane or marker source is missing or malformed.",
        routingNote: ROUTING_NOTES.sourceMissing
      })
    };
  }

  const laneBasis = extractCurrentStateBasis(currentStateText);
  if (laneBasis.activeLanes.length !== 1) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: laneBasis.activeLanes.length === 0 ? "source-missing" : "source-contradiction",
        failureScope: "authoritative-lane",
        message: laneBasis.activeLanes.length === 0
          ? "The authoritative lane source is missing or malformed."
          : "The authoritative lane source does not resolve to one exact current lane story.",
        routingNote: laneBasis.activeLanes.length === 0
          ? ROUTING_NOTES.sourceMissing
          : ROUTING_NOTES.sourceContradiction
      })
    };
  }

  if (laneBasis.supportingLanes.length > 1) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-contradiction",
        failureScope: "authoritative-lane",
        message: "The authoritative lane source does not resolve to one exact supporting posture.",
        routingNote: ROUTING_NOTES.sourceContradiction
      })
    };
  }

  const frontPageSection = extractMarkdownSection(markersText, "Active Front-Page Marker Table");
  const supportingSection = extractMarkdownSection(markersText, "Supporting Open Markers");
  if (!frontPageSection && !supportingSection) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-missing",
        failureScope: "authoritative-marker",
        message: "The authoritative marker source is missing or malformed.",
        routingNote: ROUTING_NOTES.sourceMissing
      })
    };
  }

  const markers = [
    ...parseMarkerSection(frontPageSection),
    ...parseMarkerSection(supportingSection)
  ];
  if (markers.length === 0) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-missing",
        failureScope: "authoritative-marker",
        message: "The authoritative marker source is missing or malformed.",
        routingNote: ROUTING_NOTES.sourceMissing
      })
    };
  }

  const requestedLane = normalizeLaneName(lane);
  const markerMatches = markers.filter((marker) => marker.normalizedName === requestedLane);
  if (markerMatches.length > 1) {
    const values = unique(markerMatches.map((match) => match.rawLine));
    if (values.length > 1) {
      return {
        ok: false,
        report: buildFailure({
          failureCode: "source-contradiction",
          failureScope: "authoritative-marker",
          message: "The authoritative marker source does not resolve to one exact current marker value.",
          routingNote: ROUTING_NOTES.sourceContradiction
        })
      };
    }
  }

  const activeLane = laneBasis.activeLanes[0];
  const supportingLane = laneBasis.supportingLanes[0];

  let laneRole = null;
  let supportingPosture = null;
  if (normalizeLaneName(activeLane) === requestedLane) {
    laneRole = "active";
    supportingPosture = "immediate control-plane family";
  } else if (supportingLane && normalizeLaneName(supportingLane) === requestedLane) {
    laneRole = "supporting";
    supportingPosture = "direct supporting dependency for the selected receipt-skeleton subfamily";
  }

  if (!laneRole) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "lane-unavailable",
        failureScope: "requested-lane",
        message: "The requested lane is not present in the authoritative current lane story.",
        routingNote: ROUTING_NOTES.laneUnavailable
      })
    };
  }

  if (markerMatches.length === 0) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "source-contradiction",
        failureScope: "authoritative-marker",
        message: "The authoritative lane and marker sources do not agree on the current lane package basis.",
        routingNote: ROUTING_NOTES.sourceContradiction
      })
    };
  }

  return {
    ok: true,
    lane: markerMatches[0].displayName,
    laneRole,
    markerPercentage: markerMatches[0].value,
    supportingPosture
  };
}

async function loadRestartContext({ workspaceRoot, readText }) {
  const surfaces = [];

  for (const ref of RESTART_REFS) {
    const filePath = path.join(workspaceRoot, ref);
    let text;
    try {
      text = await readText(filePath);
    } catch {
      return {
        ok: false,
        status: "missing",
        refs: [ref]
      };
    }

    surfaces.push(parseRestartSurface(ref, text));
  }

  return {
    ok: true,
    nextPackage: buildConsensus(surfaces, "nextPackage")
  };
}

function extractReceiptNextPackages(text) {
  const values = [];
  for (const heading of ["Exact Next Packet", "Exact Next Package"]) {
    const section = extractMarkdownSection(text, heading);
    if (!section) {
      continue;
    }

    for (const match of section.matchAll(/^(?:-+\s+)?`([^`]+)`/gm)) {
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

async function validateReceiptContext({ workspaceRoot, receiptContext, expectedNextPackage, readText }) {
  const filePath = path.join(workspaceRoot, receiptContext);
  let text;

  try {
    text = await readText(filePath);
  } catch {
    return {
      ok: false,
      status: "missing"
    };
  }

  const nextPackages = extractReceiptNextPackages(text);
  if (nextPackages.length === 0) {
    return {
      ok: false,
      status: "missing"
    };
  }

  if (nextPackages.length > 1) {
    return {
      ok: false,
      status: "contradiction",
      refs: [receiptContext],
      summaryConsequence: "placeholders-only"
    };
  }

  if (normalizeLaneName(nextPackages[0]) !== normalizeLaneName(expectedNextPackage)) {
    return {
      ok: false,
      status: "contradiction",
      refs: [receiptContext, ...RESTART_REFS],
      summaryConsequence: "no-next-package"
    };
  }

  return {
    ok: true
  };
}

function renderPackageFields() {
  return PACKAGE_FIELDS.join("; ");
}

function renderText(result) {
  if (result.ok) {
    const lines = [
      `draft_status=${result.report.draft_status}`,
      `lane=${result.report.lane}`,
      `package_fields=${renderPackageFields()}`
    ];

    if (result.report.package_mode === "draft-skeleton-plus-context") {
      const contextParts = [];
      if (result.report.marker_percentage) {
        contextParts.push(`marker_percentage=${result.report.marker_percentage}`);
      }
      if (result.report.supporting_posture) {
        contextParts.push(`supporting_posture=${result.report.supporting_posture}`);
      }
      if (result.report.next_package) {
        contextParts.push(`next_package=${result.report.next_package}`);
      }
      if (result.report.receipt_context) {
        contextParts.push(`receipt_context=${result.report.receipt_context}`);
      }

      if (contextParts.length > 0) {
        lines.push(contextParts.join(" | "));
      }
    } else {
      const placeholderParts = [];
      if (Array.isArray(result.report.placeholder_fields)) {
        placeholderParts.push(`placeholder_fields=${result.report.placeholder_fields.join(", ")}`);
      }
      if (result.report.context_fallback_reason) {
        placeholderParts.push(`context_fallback_reason=${result.report.context_fallback_reason}`);
      }
      if (placeholderParts.length > 0) {
        lines.push(placeholderParts.join(" | "));
      }
    }

    lines.push(`refs=${[...AUTHORITATIVE_REFS, ...RESTART_REFS].join(", ")}`);
    lines.push(`routing_note=${result.report.routing_note}`);
    return `${lines.join("\n")}\n`;
  }

  const lines = [
    `failure_code=${result.report.failure_code}`,
    `message=${result.report.message}`
  ];

  if (result.report.failure_code === "receipt-basis-unavailable") {
    lines.push(`lane=${result.report.lane}`);
    lines.push(`draft_status=${result.report.draft_status}`);
    lines.push(`authoritative_refs=${result.report.authoritative_refs.join(", ")}`);
    lines.push(`placeholder_fields=${result.report.placeholder_fields.join(", ")}`);
    if (result.report.contradiction_note) {
      lines.push(`contradiction_scope=${result.report.contradiction_note.contradiction_scope}`);
      lines.push(`conflicting_refs=${result.report.contradiction_note.conflicting_refs.join(", ")}`);
      lines.push(`summary_consequence=${result.report.contradiction_note.summary_consequence}`);
    }
  }

  lines.push(`routing_note=${result.report.routing_note}`);
  return `${lines.join("\n")}\n`;
}

export async function runReceiptPackageCommand(argv, dependencies = {}) {
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

  const authoritative = await loadAuthoritativeLaneBasis({
    workspaceRoot,
    lane: parsed.args.lane,
    readText
  });
  if (!authoritative.ok) {
    return authoritative;
  }

  const restart = await loadRestartContext({ workspaceRoot, readText });
  if (!restart.ok || restart.nextPackage.status === "missing") {
    if (parsed.args.receiptContext) {
      return {
        ok: false,
        report: buildFailure({
          failureCode: "receipt-basis-unavailable",
          failureScope: "restart-context",
          message: "The restart surfaces do not support one exact next-package context for the requested lane story.",
          routingNote: ROUTING_NOTES.receiptBasisUnavailable,
          lane: authoritative.lane,
          placeholderFields: ["next_package", "receipt_context"]
        })
      };
    }

    return {
      ok: true,
      report: buildSuccess({
        lane: authoritative.lane,
        packageMode: "draft-skeleton-with-placeholders",
        contextStatus: "placeholder-fallback",
        routingNote: ROUTING_NOTES.placeholder,
        markerPercentage: authoritative.markerPercentage,
        supportingPosture: authoritative.supportingPosture,
        placeholderFields: ["next_package"],
        contextFallbackReason: "restart-context-not-frozen"
      })
    };
  }

  if (restart.nextPackage.status === "contradiction") {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "receipt-basis-unavailable",
        failureScope: "restart-context",
        message: "The restart surfaces do not resolve to one exact next package for the requested lane story.",
        routingNote: ROUTING_NOTES.receiptBasisUnavailable,
        lane: authoritative.lane,
        placeholderFields: parsed.args.receiptContext
          ? ["next_package", "receipt_context"]
          : ["next_package"],
        contradictionNotePayload: contradictionNote("restart-surfaces", restart.nextPackage.refs, "no-next-package")
      })
    };
  }

  if (parsed.args.receiptContext) {
    const receiptCheck = await validateReceiptContext({
      workspaceRoot,
      receiptContext: parsed.args.receiptContext,
      expectedNextPackage: restart.nextPackage.value,
      readText
    });

    if (!receiptCheck.ok) {
      return {
        ok: false,
        report: buildFailure({
          failureCode: "receipt-basis-unavailable",
          failureScope: "receipt-context",
          message: receiptCheck.status === "missing"
            ? "The cited receipt context is unavailable for exact same-story support."
            : "The cited receipt context conflicts with the current restart spine.",
          routingNote: ROUTING_NOTES.receiptBasisUnavailable,
          lane: authoritative.lane,
          placeholderFields: ["receipt_context"],
          contradictionNotePayload: receiptCheck.status === "contradiction"
            ? contradictionNote("receipt-context", receiptCheck.refs, receiptCheck.summaryConsequence)
            : undefined
        })
      };
    }
  }

  return {
    ok: true,
    report: buildSuccess({
      lane: authoritative.lane,
      packageMode: "draft-skeleton-plus-context",
      contextStatus: "agreed",
      routingNote: ROUTING_NOTES.plusContext,
      markerPercentage: authoritative.markerPercentage,
      supportingPosture: authoritative.supportingPosture,
      nextPackage: restart.nextPackage.value,
      receiptContext: parsed.args.receiptContext
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --lane <lane-name> [--format text|json] [--receipt-context <relative-path>]`,
    "",
    "Reads the authoritative ATLAS lane and marker surfaces, checks derivative restart-mirror agreement, optionally compares one cited same-story receipt, and emits the bounded receipt-package contract.",
    "No-execution guard: this packet may admit future implementation of authoritative lane read, authoritative marker read, derivative restart-mirror agreement checks, one cited-receipt comparison, contradiction classification, placeholder fallback, and draft-only receipt-package rendering for stack receipt package, but it may not mutate markers/receipts/book surfaces or owner repos, infer ratchet movement, synthesize next-package truth from uncited or conflicting sources, generate doctrine-routing output, or imply deploy/publication/owner-readiness proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runReceiptPackageCommand(argv);
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
