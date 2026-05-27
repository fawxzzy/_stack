import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { emitDryRunPacket } from "./data-gateway-packet-emitter.mjs";
import { reviewDryRunPacket } from "./data-gateway-packet-review.mjs";

function buildValidPacket(overrides = {}) {
  return {
    packet_purpose: "supabase-review",
    packet_schema_version: "ldg.packet.v1",
    downstream_target_class: "human-review",
    sensitivity_label: "sensitive",
    source_provenance: {
      owner_surface: "repos/fawxzzy-fitness",
      source_type: "export",
      source_refs: ["runtime/exports/example.json"],
      captured_at: "2026-05-27T00:00:00Z",
      capture_method: "local-script"
    },
    transformation_record: {
      normalized: true,
      validated: true,
      redacted: true,
      sensitivity_classified: true,
      deduped: true,
      extracted: true,
      notes: ["row scope narrowed locally"]
    },
    validation_result: "pass",
    redaction_status: "applied",
    dedupe_status: "applied",
    minimal_useful_payload: {
      approved_rows: ["candidate-01", "candidate-02"]
    },
    export_exclusion_summary: {
      omitted_classes: ["raw-emails", "token-material"],
      reason: "minimum-necessary"
    },
    receipt_or_proof_ref: "docs/ops/example.md",
    ...overrides
  };
}

async function emitReviewablePacket(tempDir, overrides = {}) {
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket(overrides)), "utf8");

  return emitDryRunPacket({
    inputPath: packetPath,
    lane: "supabase-review",
    artifactRoot: tempDir,
    emittedAt: new Date("2026-05-27T12:34:56.000Z")
  });
}

test("valid emitted packet can enter local review", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-review-"));
  const emitted = await emitReviewablePacket(tempDir);

  assert.equal(emitted.ok, true);

  const result = await reviewDryRunPacket({
    artifactDir: emitted.artifactDir,
    reviewer: "zac",
    disposition: "approved",
    reviewerNote: "minimum payload looks clean"
  });

  assert.equal(result.ok, true);
  const artifactNames = (await fs.readdir(emitted.artifactDir)).sort();
  assert.deepEqual(artifactNames, [
    "packet-metadata.json",
    "packet-review-metadata.json",
    "packet-review.md",
    "packet-summary.md",
    "packet.json"
  ]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("review disposition is recorded locally", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-review-"));
  const emitted = await emitReviewablePacket(tempDir);

  const result = await reviewDryRunPacket({
    artifactDir: emitted.artifactDir,
    reviewer: "operator-1",
    disposition: "needs-revision",
    reviewerNote: "payload needs tighter row scope"
  });

  assert.equal(result.ok, true);

  const metadata = JSON.parse(await fs.readFile(result.reviewArtifacts.metadata, "utf8"));
  assert.equal(metadata.reviewer, "operator-1");
  assert.equal(metadata.disposition, "needs-revision");
  assert.equal(metadata.reviewer_note, "payload needs tighter row scope");

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("review artifacts preserve the no-send invariant", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-review-"));
  const emitted = await emitReviewablePacket(tempDir);

  const result = await reviewDryRunPacket({
    artifactDir: emitted.artifactDir,
    reviewer: "zac",
    disposition: "no-decision"
  });

  assert.equal(result.ok, true);

  const metadata = JSON.parse(await fs.readFile(result.reviewArtifacts.metadata, "utf8"));
  assert.deepEqual(metadata.no_send_attestation, {
    downstream_send_performed: false,
    downstream_execution_performed: false,
    remote_target_selected: false,
    automatic_handoff_authorized: false
  });

  const summary = await fs.readFile(result.reviewArtifacts.review, "utf8");
  assert.match(summary, /no downstream send performed/i);
  assert.match(summary, /approval does not imply automatic transport or execution/i);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("invalid or missing packet artifacts fail safely", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-review-"));
  const artifactDir = path.join(tempDir, "missing-artifacts");
  await fs.mkdir(artifactDir, { recursive: true });

  const result = await reviewDryRunPacket({
    artifactDir,
    reviewer: "zac",
    disposition: "approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.wroteArtifacts, false);
  assert.match(result.errors.join("\n"), /Missing required artifact/);

  await fs.rm(tempDir, { recursive: true, force: true });
});
