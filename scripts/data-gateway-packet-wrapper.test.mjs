import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { runPacketWrapper } from "./data-gateway-packet-wrapper.mjs";

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

test("validate-only succeeds for a valid packet without writing artifacts", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "validate-only",
    sourcePath: packetPath
  });

  assert.equal(result.ok, true);
  assert.equal(result.validationState, "pass");
  assert.equal(result.wrapperStage, "validate");
  assert.equal(result.noSendAttestation.downstream_send_performed, false);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("validate-only fails closed for an invalid packet", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket();
  delete packet.packet_purpose;
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "validate-only",
    sourcePath: packetPath
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "validate");
  assert.equal(result.validationState, "fail");
  assert.match(result.errors.join("\n"), /packet_purpose must be a non-empty string/);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("emit-dry-run succeeds only after validation and preserves no-send state", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const result = await runPacketWrapper({
    lane: "discordos-boundary-handoff",
    mode: "emit-dry-run",
    sourcePath: packetPath,
    artifactRoot: tempDir
  });

  assert.equal(result.ok, true);
  assert.equal(result.validationState, "pass");
  assert.equal(result.wrapperStage, "emit");
  assert.equal(result.noSendAttestation.remote_target_selected, false);
  assert.ok(result.artifactDir.startsWith(tempDir));
  assert.ok(Object.values(result.emittedArtifacts).every((filePath) => filePath.startsWith(tempDir)));

  const metadata = JSON.parse(await fs.readFile(result.emittedArtifacts.metadata, "utf8"));
  assert.equal(metadata.emit_mode, "dry-run");
  assert.equal(metadata.downstream_send_performed, false);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("emit-dry-run does not bypass primitive validation checks", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket({
    sensitivity_label: "secret-ish"
  });
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await runPacketWrapper({
    lane: "vercel-deletion-review",
    mode: "emit-dry-run",
    sourcePath: packetPath,
    artifactRoot: tempDir
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "validate");
  assert.equal(result.validationState, "fail");
  assert.match(result.errors.join("\n"), /sensitivity_label must be one of/);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("wrapper CLI rejects transport-shaped flags in package 1", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const scriptPath = path.resolve("scripts/data-gateway-packet-wrapper.mjs");
  const result = spawnSync(
    process.execPath,
    [scriptPath, "--lane", "supabase-review", "--mode", "validate-only", "--source", packetPath, "--target", "example"],
    {
      cwd: path.resolve("."),
      encoding: "utf8"
    }
  );

  assert.equal(result.status, 1);
  assert.match(result.stderr, /--target is not admitted in wrapper package 1/);

  await fs.rm(tempDir, { recursive: true, force: true });
});
