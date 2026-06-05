import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { spawn } from "node:child_process";
import { runMarkerCheckpointCommand } from "./marker-checkpoint.mjs";

function createAuthoritativeMarkers(lines = {}) {
  const frontPage = lines.frontPage || [
    "- `_stack` Readiness: `87%`",
    "- `AI Repetition-to-Automation Pipeline`: `30%`"
  ];
  const supporting = lines.supporting || [
    "- `Core Pattern Convergence`: `43%`"
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

function createCurrentState(overrides = {}) {
  return [
    "# Current State",
    "",
    "- `AI Repetition-to-Automation Pipeline` now has one automation-candidate threshold packet:",
    `  - the first real supporting dependency is now \`${overrides.supportingLane ?? "_stack Readiness"}\``,
    `  - the next active AI-pipeline packet is now \`${overrides.nextPackage ?? "_stack stack marker checkpoint first-implementation worker packet 1"}\``
  ].join("\n");
}

function createSystemMap(overrides = {}) {
  return [
    "# Current System Map / Graph",
    "",
    "| Lane / surface | Owner | Source of truth | Current status | Blocker | Next package |",
    "| --- | --- | --- | --- | --- | --- |",
    `| ATLAS systems lane | ATLAS root plus \`_stack\` and Playbook boundaries | ATLAS docs | active governance lane now routes from the boundary-hardened Unified Workflow Convergence spine into \`${overrides.activeLane ?? "AI Repetition-to-Automation Pipeline"}\`; \`${overrides.supportingLane ?? "_stack Readiness"}\` now supports both admitted families while ratchet authority remains in ATLAS | bridge blocker remains external | \`${overrides.nextPackage ?? "_stack stack marker checkpoint first-implementation worker packet 1"}\` |`
  ].join("\n");
}

function createRestartGuide(overrides = {}) {
  return [
    "# Restart And Handoff Guide",
    "",
    "## Current Recommended Next Packages",
    "",
    `- root-bounded lane-selection after Unified Workflow Convergence boundary-hardened workflow spine pass 3 closeout is now durable and selects \`${overrides.activeLane ?? "AI Repetition-to-Automation Pipeline"}\` as the immediate ATLAS-side lane`,
    `- the only admitted support lane is \`${overrides.supportingLane ?? "_stack Readiness"}\``,
    `- the exact next ATLAS-side lane package is now \`${overrides.nextPackage ?? "_stack stack marker checkpoint first-implementation worker packet 1"}\``
  ].join("\n");
}

function createReceipt(nextPacket) {
  return [
    "# Receipt",
    "",
    "## Exact Next Packet",
    "",
    `- \`${nextPacket}\``
  ].join("\n");
}

async function withWorkspace(files) {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "stack-marker-checkpoint-"));
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

test("agreeing front-page checkpoint with no receipt context preserves the bounded success contract", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "front-page"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.command, "stack marker checkpoint");
  assert.equal(result.report.scope, "front-page");
  assert.match(result.report.checkpoint, /## Active Front-Page Marker Table/);
  assert.equal(result.report.authoritative_ref, "docs/atlas-book/02-lanes-and-markers.md");
  assert.equal(result.report.context_status, "agreed");
  assert.equal(result.report.report_mode, "checkpoint-only");
  assert.deepEqual(result.report.supporting_refs, [
    "docs/atlas-book/01-current-state.md",
    "docs/atlas-book/11-system-map-graph.md",
    "docs/atlas-book/12-restart-and-handoff-guide.md"
  ]);
  assert.equal(result.report.routing_note, "package checkpoint only and continue");
  assert.equal("lane" in result.report, false);
  assert.equal("next_package" in result.report, false);
  assert.equal("receipt_context" in result.report, false);
  assert.equal("context_unavailable_reason" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "scope",
    "checkpoint",
    "authoritative_ref",
    "context_status",
    "report_mode",
    "supporting_refs",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("agreeing lane-bounded checkpoint with restart-context agreement emits exact supporting posture and next package", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.scope, "lane");
  assert.equal(result.report.lane, "_stack Readiness");
  assert.equal(result.report.context_status, "agreed");
  assert.equal(result.report.report_mode, "checkpoint-plus-context");
  assert.equal(result.report.supporting_posture, "current supporting lane for both admitted families");
  assert.equal(result.report.next_package, "_stack stack marker checkpoint first-implementation worker packet 1");
  assert.equal("receipt_context" in result.report, false);
  assert.equal("context_unavailable_reason" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "scope",
    "checkpoint",
    "authoritative_ref",
    "context_status",
    "report_mode",
    "supporting_refs",
    "routing_note",
    "lane",
    "supporting_posture",
    "next_package"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("agreeing lane-bounded checkpoint with one same-story receipt echoes the bounded receipt context", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(),
    "receipts/current-story.md": createReceipt("_stack stack marker checkpoint first-implementation worker packet 1")
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/current-story.md"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.context_status, "agreed");
  assert.equal(result.report.report_mode, "checkpoint-plus-context");
  assert.equal(result.report.receipt_context, "receipts/current-story.md");
  assert.equal(result.report.next_package, "_stack stack marker checkpoint first-implementation worker packet 1");
  assertExactKeys(result.report, [
    "command",
    "scope",
    "checkpoint",
    "authoritative_ref",
    "context_status",
    "report_mode",
    "supporting_refs",
    "routing_note",
    "lane",
    "supporting_posture",
    "next_package",
    "receipt_context"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("clean checkpoint with restart-context unavailable stays inside the bounded checkpoint-only branch", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState({ nextPackage: "" }),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap({ nextPackage: "" }),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide({ nextPackage: "" })
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "Core Pattern Convergence"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, true);
  assert.equal(result.report.context_status, "unavailable");
  assert.equal(result.report.report_mode, "checkpoint-only");
  assert.equal(result.report.context_unavailable_reason, "restart-context-not-frozen");
  assert.equal("supporting_posture" in result.report, false);
  assert.equal("next_package" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "scope",
    "checkpoint",
    "authoritative_ref",
    "context_status",
    "report_mode",
    "supporting_refs",
    "routing_note",
    "lane",
    "context_unavailable_reason"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing or malformed marker source fails closed", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "front-page"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "source-missing");
  assert.equal(result.report.failure_scope, "authoritative-marker");
  assert.equal("checkpoint" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("contradictory marker source fails closed without packaging a checkpoint", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers({
      frontPage: [
        "- `_stack` Readiness: `87%`",
        "- `_stack` Readiness: `86%`"
      ]
    }),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "source-contradiction");
  assert.equal(result.report.failure_scope, "authoritative-marker");
  assert.equal("checkpoint" in result.report, false);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("lane unavailable fails closed without coercing a different lane", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "Missing Lane"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "lane-unavailable");
  assert.equal(result.report.failure_scope, "requested-lane");
  assert.equal("checkpoint" in result.report, false);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("contradictory or stale cited receipt fails closed through the partial checkpoint path", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(),
    "receipts/stale-story.md": createReceipt("older packet that is no longer current")
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/stale-story.md"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "checkpoint-context-unavailable");
  assert.equal(result.report.failure_scope, "restart-context");
  assert.match(result.report.checkpoint, /_stack/);
  assert.equal(result.report.authoritative_ref, "docs/atlas-book/02-lanes-and-markers.md");
  assert.deepEqual(result.report.supporting_refs, [
    "docs/atlas-book/01-current-state.md",
    "docs/atlas-book/11-system-map-graph.md",
    "docs/atlas-book/12-restart-and-handoff-guide.md"
  ]);
  assert.equal(result.report.contradiction_note.contradiction_scope, "receipt-context");
  assert.deepEqual(result.report.contradiction_note.conflicting_refs, [
    "receipts/stale-story.md",
    "docs/atlas-book/01-current-state.md",
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
    "checkpoint",
    "authoritative_ref",
    "supporting_refs",
    "contradiction_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("unsupported input fails before any file loading", async () => {
  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "cluster"
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(result.report.failure_scope, "input");
  assert.match(result.report.message, /--scope must be front-page or lane\./);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);
});

test("missing cited receipt path fails closed without partial checkpoint payload", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/missing-story.md"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "source-missing");
  assert.equal(result.report.failure_scope, "restart-context");
  assert.equal("checkpoint" in result.report, false);
  assert.equal("authoritative_ref" in result.report, false);
  assert.equal("supporting_refs" in result.report, false);
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

test("cited receipt with multiple next-packet claims fails closed through the bounded contradiction path", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide(),
    "receipts/contradictory-story.md": [
      "# Receipt",
      "",
      "## Exact Next Packet",
      "",
      "- `_stack stack marker checkpoint first-implementation worker packet 1`",
      "- `_stack stack marker checkpoint another competing packet`"
    ].join("\n")
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "receipts/contradictory-story.md"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "checkpoint-context-unavailable");
  assert.equal(result.report.failure_scope, "restart-context");
  assert.equal(result.report.contradiction_note.contradiction_scope, "receipt-context");
  assert.deepEqual(result.report.contradiction_note.conflicting_refs, [
    "receipts/contradictory-story.md"
  ]);
  assert.equal(result.report.contradiction_note.summary_consequence, "checkpoint-only");
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "checkpoint",
    "authoritative_ref",
    "supporting_refs",
    "contradiction_note"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("receipt-context path discipline fails before any file loading", async () => {
  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness",
    "--receipt-context",
    "C:\\outside\\receipt.md"
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(result.report.failure_scope, "input");
  assert.match(result.report.message, /--receipt-context must be a bounded relative path\./);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note"
  ]);
});

test("receipt context requested without one exact agreeing restart context stays inside the bounded partial-fallback failure shape", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers({
      frontPage: [
        "- `_stack` Readiness: `87%`"
      ],
      supporting: [
        "- `Core Pattern Convergence`: `43%`"
      ]
    }),
    "docs/atlas-book/01-current-state.md": createCurrentState({ nextPackage: "" }),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap({ nextPackage: "" }),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide({ nextPackage: "" }),
    "receipts/unusable-story.md": createReceipt("_stack stack marker checkpoint first-implementation worker packet 1")
  });

  const result = await runMarkerCheckpointCommand([
    "--format",
    "json",
    "--scope",
    "lane",
    "--lane",
    "Core Pattern Convergence",
    "--receipt-context",
    "receipts/unusable-story.md"
  ], {
    workspaceRoot
  });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "checkpoint-context-unavailable");
  assert.equal(result.report.failure_scope, "restart-context");
  assert.match(result.report.checkpoint, /Core Pattern Convergence/);
  assert.equal("contradiction_note" in result.report, false);
  assert.equal("next_package" in result.report, false);
  assert.equal("receipt_context" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "failure_code",
    "failure_scope",
    "message",
    "routing_note",
    "checkpoint",
    "authoritative_ref",
    "supporting_refs"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("text output preserves the bounded checkpoint-plus-context contract", async () => {
  const workspaceRoot = await withWorkspace({
    "docs/atlas-book/02-lanes-and-markers.md": createAuthoritativeMarkers(),
    "docs/atlas-book/01-current-state.md": createCurrentState(),
    "docs/atlas-book/11-system-map-graph.md": createSystemMap(),
    "docs/atlas-book/12-restart-and-handoff-guide.md": createRestartGuide()
  });

  const scriptPath = path.resolve("scripts/marker-checkpoint.mjs");
  const child = spawn(process.execPath, [
    scriptPath,
    "--scope",
    "lane",
    "--lane",
    "_stack Readiness"
  ], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      STACK_MARKER_CHECKPOINT_WORKSPACE_ROOT: workspaceRoot
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
  assert.match(stdout, /## Active Front-Page Marker Table/);
  assert.match(stdout, /supporting_posture=current supporting lane for both admitted families/);
  assert.match(stdout, /next_package=_stack stack marker checkpoint first-implementation worker packet 1/);
  assert.match(stdout, /routing_note=package checkpoint plus exact restart context and continue/);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});
