import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { buildProjectBoardOwnerExport, renderProjectBoardOwnerExport, runProjectBoardOwnerExport } from "../scripts/export-project-board-owner.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const registryPath = path.join(root, "queue/owner-work-registry.json");
const registryBytes = fs.readFileSync(registryPath);
const registry = JSON.parse(registryBytes.toString("utf8"));

test("publishes an explicit ready-empty owner export", () => {
  const output = buildProjectBoardOwnerExport(registry, registryBytes);
  assert.equal(output.cards.length, 0);
  assert.equal(output.extensions.owner_queue_state, "ready-empty");
  assert.equal(output.extensions.atlas_candidates_admitted, false);
  assert.equal(output.extensions.discord_mutation_authorized, false);
});

test("maps a future owner-admitted record without changing current truth", () => {
  const candidate = structuredClone(registry);
  candidate.state = "active";
  candidate.stateReason = "One owner record admitted for fixture proof.";
  candidate.workItems = [{
    id: "STK-101",
    title: "Fixture owner task",
    status: "ready",
    goal: "Prove future owner records map through the shared board contract.",
    type: "automation",
    priority: null,
    dependencies: [],
    acceptanceCriteria: ["The fixture maps to Ready without Discord mutation."],
    evidence: ["queue/README.md"]
  }];
  const output = buildProjectBoardOwnerExport(candidate, Buffer.from(JSON.stringify(candidate)));
  assert.equal(output.cards.length, 1);
  assert.equal(output.cards[0].record.card_id, "STK-101");
  assert.equal(output.cards[0].record.lifecycle, "ready");
  assert.equal(output.cards[0].record.owner, "_stack");
});

test("enforces ready-empty semantics and unknown priority", () => {
  const inconsistent = structuredClone(registry);
  inconsistent.state = "active";
  assert.throws(() => buildProjectBoardOwnerExport(inconsistent, Buffer.from(JSON.stringify(inconsistent))), /must declare ready-empty/);

  const prioritized = structuredClone(registry);
  prioritized.state = "active";
  prioritized.workItems = [{
    id: "STK-101", title: "Fixture", status: "planned", goal: "Fixture", type: "automation",
    priority: "high", dependencies: [], acceptanceCriteria: ["Fixture"], evidence: []
  }];
  assert.throws(() => buildProjectBoardOwnerExport(prioritized, Buffer.from(JSON.stringify(prioritized))), /priority must remain null/);
});

test("normalizes CRLF before hashing", () => {
  const normalized = registryBytes.toString("utf8").replace(/\r\n?/g, "\n");
  const lf = buildProjectBoardOwnerExport(registry, Buffer.from(normalized));
  const crlf = buildProjectBoardOwnerExport(registry, Buffer.from(normalized.replace(/\n/g, "\r\n")));
  assert.equal(lf.source_revision, crlf.source_revision);
});

test("check mode detects output drift", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "stack-owner-export-"));
  try {
    fs.mkdirSync(path.join(tempRoot, "queue"), { recursive: true });
    fs.copyFileSync(registryPath, path.join(tempRoot, "queue/owner-work-registry.json"));
    runProjectBoardOwnerExport([], tempRoot);
    assert.doesNotThrow(() => runProjectBoardOwnerExport(["--check"], tempRoot));
    const outputPath = path.join(tempRoot, "exports/stack.project-board.owner-export.v1.json");
    fs.writeFileSync(outputPath, fs.readFileSync(outputPath, "utf8").replace(/\n/g, "\r\n"));
    assert.doesNotThrow(() => runProjectBoardOwnerExport(["--check"], tempRoot));
    fs.writeFileSync(outputPath, "{}\n");
    assert.throws(() => runProjectBoardOwnerExport(["--check"], tempRoot), /is stale/);
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("committed export matches deterministic rendering", () => {
  assert.equal(
    fs.readFileSync(path.join(root, "exports/stack.project-board.owner-export.v1.json"), "utf8").replace(/\r\n?/g, "\n"),
    renderProjectBoardOwnerExport(root).replace(/\r\n?/g, "\n")
  );
});
