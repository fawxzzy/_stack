import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { emitDryRunPacket } from "./data-gateway-packet-emitter.mjs";

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

test("valid packet emits local dry-run artifacts", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-emitter-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const result = await emitDryRunPacket({
    inputPath: packetPath,
    lane: "supabase-review",
    artifactRoot: tempDir,
    emittedAt: new Date("2026-05-27T12:34:56.000Z")
  });

  assert.equal(result.ok, true);
  assert.ok(result.artifactDir.startsWith(tempDir));

  const artifactNames = (await fs.readdir(result.artifactDir)).sort();
  assert.deepEqual(artifactNames, ["packet-metadata.json", "packet-summary.md", "packet.json"]);

  const emittedPacket = JSON.parse(await fs.readFile(result.artifacts.packet, "utf8"));
  assert.equal(emittedPacket.packet_purpose, "supabase-review");
  assert.equal(typeof emittedPacket.packet_id, "string");

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("invalid packet does not emit artifacts", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-emitter-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket();
  delete packet.packet_purpose;
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await emitDryRunPacket({
    inputPath: packetPath,
    lane: "supabase-review",
    artifactRoot: tempDir,
    emittedAt: new Date("2026-05-27T12:34:56.000Z")
  });

  assert.equal(result.ok, false);
  assert.equal(result.wroteArtifacts, false);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("emitted packet remains local artifact only with no-send metadata", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-emitter-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const result = await emitDryRunPacket({
    inputPath: packetPath,
    lane: "discordos-boundary-handoff",
    artifactRoot: tempDir,
    emittedAt: new Date("2026-05-27T12:34:56.000Z")
  });

  assert.equal(result.ok, true);

  const metadata = JSON.parse(await fs.readFile(result.artifacts.metadata, "utf8"));
  assert.equal(metadata.emit_mode, "dry-run");
  assert.equal(metadata.downstream_send_performed, false);
  assert.ok(metadata.artifact_dir.startsWith(tempDir));
  assert.ok(Object.values(metadata.artifacts).every((filePath) => filePath.startsWith(tempDir)));

  const summary = await fs.readFile(result.artifacts.summary, "utf8");
  assert.match(summary, /No downstream send performed/i);

  await fs.rm(tempDir, { recursive: true, force: true });
});
