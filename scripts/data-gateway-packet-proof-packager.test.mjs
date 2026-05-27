import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { emitDryRunPacket } from "./data-gateway-packet-emitter.mjs";
import { packageReviewedPacketProof } from "./data-gateway-packet-proof-packager.mjs";
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
      approved_rows: ["SECRET_PAYLOAD_MARKER"]
    },
    export_exclusion_summary: {
      omitted_classes: ["raw-emails", "token-material"],
      reason: "minimum-necessary"
    },
    receipt_or_proof_ref: "docs/ops/example.md",
    ...overrides
  };
}

async function emitReviewedPacket(tempDir, { reviewerNote = "SECRET_REVIEW_NOTE" } = {}) {
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const emitted = await emitDryRunPacket({
    inputPath: packetPath,
    lane: "supabase-review",
    artifactRoot: tempDir,
    emittedAt: new Date("2026-05-27T12:34:56.000Z")
  });

  assert.equal(emitted.ok, true);

  const reviewed = await reviewDryRunPacket({
    artifactDir: emitted.artifactDir,
    reviewer: "zac",
    disposition: "approved",
    reviewerNote
  });

  assert.equal(reviewed.ok, true);
  return emitted.artifactDir;
}

test("reviewed packet can be packaged into a local proof bundle", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-proof-"));
  const artifactDir = await emitReviewedPacket(tempDir);

  const result = await packageReviewedPacketProof({
    artifactDir
  });

  assert.equal(result.ok, true);
  const artifactNames = (await fs.readdir(artifactDir)).sort();
  assert.deepEqual(artifactNames, [
    "packet-metadata.json",
    "packet-review-metadata.json",
    "packet-review.md",
    "packet-summary.md",
    "packet.json",
    "proof-metadata.json",
    "proof-summary.md"
  ]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("unreviewed packet fails safely", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-proof-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const emitted = await emitDryRunPacket({
    inputPath: packetPath,
    lane: "supabase-review",
    artifactRoot: tempDir,
    emittedAt: new Date("2026-05-27T12:34:56.000Z")
  });

  assert.equal(emitted.ok, true);

  const result = await packageReviewedPacketProof({
    artifactDir: emitted.artifactDir
  });

  assert.equal(result.ok, false);
  assert.equal(result.wroteArtifacts, false);
  assert.match(result.errors.join("\n"), /Missing required artifact: packet-review\.md/);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("proof bundle remains local-only and no-send", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-proof-"));
  const artifactDir = await emitReviewedPacket(tempDir);

  const result = await packageReviewedPacketProof({
    artifactDir
  });

  assert.equal(result.ok, true);

  const metadata = JSON.parse(await fs.readFile(result.proofArtifacts.metadata, "utf8"));
  assert.equal(metadata.local_only, true);
  assert.deepEqual(metadata.no_send_attestation, {
    downstream_send_performed: false,
    downstream_execution_performed: false,
    remote_target_selected: false,
    automatic_handoff_authorized: false
  });
  assert.ok(Object.values(metadata.source_artifact_references).every((filePath) => filePath.startsWith(artifactDir)));
  assert.ok(Object.values(metadata.generated_proof_artifacts).every((filePath) => filePath.startsWith(artifactDir)));

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("proof bundle preserves references without raw payload expansion", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-proof-"));
  const artifactDir = await emitReviewedPacket(tempDir, {
    reviewerNote: "SECRET_REVIEW_NOTE"
  });

  const result = await packageReviewedPacketProof({
    artifactDir
  });

  assert.equal(result.ok, true);

  const proofSummary = await fs.readFile(result.proofArtifacts.summary, "utf8");
  const proofMetadata = await fs.readFile(result.proofArtifacts.metadata, "utf8");

  assert.doesNotMatch(proofSummary, /SECRET_PAYLOAD_MARKER/);
  assert.doesNotMatch(proofSummary, /SECRET_REVIEW_NOTE/);
  assert.doesNotMatch(proofMetadata, /SECRET_PAYLOAD_MARKER/);
  assert.doesNotMatch(proofMetadata, /SECRET_REVIEW_NOTE/);
  assert.match(proofMetadata, /source_artifact_references/);

  await fs.rm(tempDir, { recursive: true, force: true });
});
