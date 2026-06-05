import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import { runReceiptPackageCommand } from "./receipt-package.mjs";

function createCurrentState(overrides = {}) {
  return [
    "# Current State",
    "",
    "- `AI Repetition-to-Automation Pipeline` now has one automation-candidate threshold packet:",
    `  - the first real supporting dependency is now \`${overrides.supportingLane ?? "_stack Readiness"}\``,
    `  - the next active AI-pipeline packet is now \`${overrides.nextPackage ?? "_stack stack receipt package first-implementation worker packet 1"}\``,
    "",
    `- \`${overrides.supportingLane ?? "_stack Readiness"}\` is now also the direct supporting dependency for \`receipt skeleton drafts\``
  ].join("\n");
}

function createMarkers(lines = {}) {
  const frontPage = lines.frontPage || [
    "- `_stack` Readiness: `87%`"
  ];
  const supporting = lines.supporting || [
    "- AI Repetition-to-Automation Pipeline: `30%`"
  ];

  return [
    "# Lanes And Markers",
    "",
    "## Active Front-Page Marker Table",
    ...frontPage,
    "",
    "## Supporting Open Markers",
    ...supporting
  ].join("\n");
}

function createSystemMap(nextPackage = "_stack stack receipt package first-implementation worker packet 1") {
  return [
    "# Current System Map / Graph",
    "",
    "| Lane / surface | Owner | Source of truth | Current status | Blocker | Next package |",
    "| --- | --- | --- | --- | --- | --- |",
    `| ATLAS systems lane | ATLAS root plus \`_stack\` and Playbook boundaries | ATLAS docs | active governance lane now routes into \`AI Repetition-to-Automation Pipeline\` | bridge blocker remains external | \`${nextPackage}\` |`
  ].join("\n");
}

function createRestartGuide(nextPackage = "_stack stack receipt package first-implementation worker packet 1") {
  return [
    "# Restart And Handoff Guide",
    "",
    "## Current Recommended Next Packages",
    "",
    `- the exact next ATLAS-side lane package is now \`${nextPackage}\``
  ].join("\n");
}

function createReceipt(nextPacketLines) {
  return [
    "# Receipt",
    "",
    "## Exact Next Packet",
    "",
    ...nextPacketLines.map((line) => `- \`${line}\``)
  ].join("\n");
}

async function withWorkspace(files) {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "stack-receipt-package-"));
  for (const [relativePath, content] of Object.entries(files)) {
    const absolutePath = path.join(workspaceRoot, relativePath);
    await fs.mkdir(path.dirname(absolutePath), { recursive: true });
    await fs.writeFile(absolutePath, content, "utf8");
  }
  return workspaceRoot;
}

function assertExactKeys(actual, expected) {
  assert.deepEqual(Object.keys(actual).sort(), [...expected].sort());
}

test("active lane with agreed restart context emits the bounded plus-context contract", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "AI Repetition-to-Automation Pipeline"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.command, "stack receipt package");
  assert.equal(result.report.lane, "AI Repetition-to-Automation Pipeline");
  assert.equal(result.report.package_mode, "draft-skeleton-plus-context");
  assert.equal(result.report.draft_status, "draft-only");
  assert.deepEqual(result.report.authoritative_refs, [
    "docs/atlas-book/01-current-state.md",
    "docs/atlas-book/02-lanes-and-markers.md"
  ]);
  assert.deepEqual(result.report.package_fields, [
    "title and metadata slots",
    "objective and scope slots",
    "source-surface slots",
    "verification, marker-decision, and next-package slots",
    "stop-condition notes"
  ]);
  assert.equal(result.report.context_status, "agreed");
  assert.equal(result.report.marker_percentage, "30%");
  assert.equal(result.report.supporting_posture, "immediate control-plane family");
  assert.equal(result.report.next_package, "_stack stack receipt package first-implementation worker packet 1");
  assert.equal(result.report.routing_note, "package draft-only skeleton plus exact agreed context and continue");
  assert.equal("receipt_context" in result.report, false);
  assert.equal("placeholder_fields" in result.report, false);
  assert.equal("context_fallback_reason" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "lane",
    "package_mode",
    "draft_status",
    "authoritative_refs",
    "package_fields",
    "context_status",
    "routing_note",
    "marker_percentage",
    "supporting_posture",
    "next_package"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("supporting lane with one agreeing cited receipt echoes the bounded receipt context", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(),
    "receipts/current-story.md": createReceipt(["_stack stack receipt package first-implementation worker packet 1"])
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/current-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.package_mode, "draft-skeleton-plus-context");
  assert.equal(result.report.context_status, "agreed");
  assert.equal(result.report.marker_percentage, "87%");
  assert.equal(result.report.supporting_posture, "direct supporting dependency for the selected receipt-skeleton subfamily");
  assert.equal(result.report.next_package, "_stack stack receipt package first-implementation worker packet 1");
  assert.equal(result.report.receipt_context, "receipts/current-story.md");
  assertExactKeys(result.report, [
    "command",
    "lane",
    "package_mode",
    "draft_status",
    "authoritative_refs",
    "package_fields",
    "context_status",
    "routing_note",
    "marker_percentage",
    "supporting_posture",
    "next_package",
    "receipt_context"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing restart next-package context stays inside the bounded placeholder-fallback success path", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(""),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide("")
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "AI Repetition-to-Automation Pipeline"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.package_mode, "draft-skeleton-with-placeholders");
  assert.equal(result.report.context_status, "placeholder-fallback");
  assert.equal(result.report.marker_percentage, "30%");
  assert.equal(result.report.supporting_posture, "immediate control-plane family");
  assert.deepEqual(result.report.placeholder_fields, ["next_package"]);
  assert.equal(result.report.context_fallback_reason, "restart-context-not-frozen");
  assert.equal("next_package" in result.report, false);
  assert.equal("receipt_context" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "lane",
    "package_mode",
    "draft_status",
    "authoritative_refs",
    "package_fields",
    "context_status",
    "routing_note",
    "marker_percentage",
    "supporting_posture",
    "placeholder_fields",
    "context_fallback_reason"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing authoritative lane source fails closed", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "AI Repetition-to-Automation Pipeline"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "source-missing");
  assert.equal(result.report.failure_scope, "authoritative-lane");
  assert.equal("lane" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("contradictory authoritative marker source fails closed", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers({
      supporting: [
        "- AI Repetition-to-Automation Pipeline: `30%`",
        "- AI Repetition-to-Automation Pipeline: `31%`"
      ]
    }),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "AI Repetition-to-Automation Pipeline"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "source-contradiction");
  assert.equal(result.report.failure_scope, "authoritative-marker");
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("lane unavailable fails closed without coercing a different lane story", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "Missing Lane"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "lane-unavailable");
  assert.equal(result.report.failure_scope, "requested-lane");
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("restart-surface contradiction fails closed through the bounded partial payload", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap("_stack stack receipt package first-implementation worker packet 1"),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide("_stack stack receipt package a competing packet")
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "AI Repetition-to-Automation Pipeline"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "receipt-basis-unavailable");
  assert.equal(result.report.failure_scope, "restart-context");
  assert.equal(result.report.lane, "AI Repetition-to-Automation Pipeline");
  assert.equal(result.report.draft_status, "draft-only");
  assert.deepEqual(result.report.authoritative_refs, [
    "docs/atlas-book/01-current-state.md",
    "docs/atlas-book/02-lanes-and-markers.md"
  ]);
  assert.deepEqual(result.report.placeholder_fields, ["next_package"]);
  assert.equal(result.report.contradiction_note.contradiction_scope, "restart-surfaces");
  assert.deepEqual(result.report.contradiction_note.conflicting_refs, [
    "docs/atlas-book/11-system-map-graph.md",
    "docs/atlas-book/12-restart-and-handoff-guide.md"
  ]);
  assert.equal(result.report.contradiction_note.summary_consequence, "no-next-package");
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "lane",
    "draft_status",
    "authoritative_refs",
    "placeholder_fields",
    "contradiction_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("stale cited receipt fails closed through the bounded receipt-basis path", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(),
    "receipts/stale-story.md": createReceipt(["older packet that is no longer current"])
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/stale-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "receipt-basis-unavailable");
  assert.equal(result.report.failure_scope, "receipt-context");
  assert.deepEqual(result.report.placeholder_fields, ["receipt_context"]);
  assert.equal(result.report.contradiction_note.contradiction_scope, "receipt-context");
  assert.deepEqual(result.report.contradiction_note.conflicting_refs, [
    "receipts/stale-story.md",
    "docs/atlas-book/11-system-map-graph.md",
    "docs/atlas-book/12-restart-and-handoff-guide.md"
  ]);
  assert.equal(result.report.contradiction_note.summary_consequence, "no-next-package");
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "lane",
    "draft_status",
    "authoritative_refs",
    "placeholder_fields",
    "contradiction_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing cited receipt path fails closed through the bounded receipt-basis path without contradiction payload", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/missing-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "receipt-basis-unavailable");
  assert.equal(result.report.failure_scope, "receipt-context");
  assert.deepEqual(result.report.placeholder_fields, ["receipt_context"]);
  assert.equal("contradiction_note" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "lane",
    "draft_status",
    "authoritative_refs",
    "placeholder_fields"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("receipt context using exact next package heading stays admitted when the same-story packet agrees", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(),
    "receipts/package-story.md": [
      "# Receipt",
      "",
      "## Exact Next Package",
      "",
      "- `_stack stack receipt package first-implementation worker packet 1`"
    ].join("\n")
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/package-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.package_mode, "draft-skeleton-plus-context");
  assert.equal(result.report.receipt_context, "receipts/package-story.md");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("receipt context requested without one exact agreeing restart context stays inside the bounded partial payload", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(""),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(""),
    "receipts/unusable-story.md": createReceipt(["_stack stack receipt package first-implementation worker packet 1"])
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/unusable-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "receipt-basis-unavailable");
  assert.equal(result.report.failure_scope, "restart-context");
  assert.deepEqual(result.report.placeholder_fields, ["next_package", "receipt_context"]);
  assert.equal("contradiction_note" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "lane",
    "draft_status",
    "authoritative_refs",
    "placeholder_fields"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("receipt context using a bare exact next package line stays admitted when the same-story packet agrees", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(),
    "receipts/bare-package-story.md": [
      "# Receipt",
      "",
      "## Exact Next Package",
      "",
      "`_stack stack receipt package first-implementation worker packet 1`"
    ].join("\n")
  });

  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/bare-package-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.package_mode, "draft-skeleton-plus-context");
  assert.equal(result.report.receipt_context, "receipts/bare-package-story.md");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("unsupported input fails before any file loading", async () => {
  const result = await runReceiptPackageCommand([
    "--format",
    "yaml"
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(result.report.failure_scope, "input");
  assert.match(result.report.message, /--format must be text or json\./);
  assert.match(result.report.message, /--lane is required\./);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);
});

test("receipt-context path discipline fails before file loading", async () => {
  const result = await runReceiptPackageCommand([
    "--format",
    "json",
    "--lane",
    "AI Repetition-to-Automation Pipeline",
    "--receipt-context",
    "C:\\outside\\receipt.md"
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(result.report.failure_scope, "input");
  assert.match(result.report.message, /--receipt-context must be a bounded relative path\./);
});

test("text output preserves the bounded draft-plus-context contract", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/02-lanes-and-markers.md": createMarkers(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const scriptPath = path.resolve("scripts/receipt-package.mjs");
  const child = spawn(process.execPath, [
    scriptPath,
    "--lane",
    "AI Repetition-to-Automation Pipeline"
  ], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      STACK_RECEIPT_PACKAGE_WORKSPACE_ROOT: workspaceRoot
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
  assert.match(stdout, /draft_status=draft-only/);
  assert.match(stdout, /lane=AI Repetition-to-Automation Pipeline/);
  assert.match(stdout, /marker_percentage=30%/);
  assert.match(stdout, /next_package=_stack stack receipt package first-implementation worker packet 1/);
  assert.match(stdout, /routing_note=package draft-only skeleton plus exact agreed context and continue/);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});
