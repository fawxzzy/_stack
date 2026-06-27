import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { runPacketValidation, validateGatewayPacket } from "./data-gateway-packet-validator.mjs";

function toPosixAbsolute(...segments) {
  return path.resolve(...segments).replace(/\\/g, "/");
}

function toFileUrl(...segments) {
  return new URL(`file:///${toPosixAbsolute(...segments)}`).href;
}

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

test("valid packet passes field validation", () => {
  const result = validateGatewayPacket(buildValidPacket());

  assert.equal(result.ok, true);
  assert.deepEqual(result.errors, []);
});

test("missing required field fails validation", () => {
  const packet = buildValidPacket();
  delete packet.packet_purpose;

  const result = validateGatewayPacket(packet);

  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /packet_purpose must be a non-empty string/);
});

test("malformed field value fails validation", () => {
  const result = validateGatewayPacket(buildValidPacket({
    sensitivity_label: "secret-ish"
  }));

  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /sensitivity_label must be one of/);
});

test("absolute packet refs fail validation", () => {
  const result = validateGatewayPacket(buildValidPacket({
    source_provenance: {
      owner_surface: toPosixAbsolute("..", "fawxzzy-fitness"),
      source_type: "export",
      source_refs: [toPosixAbsolute("..", "..", "runtime", "exports", "example.json")],
      captured_at: "2026-05-27T00:00:00Z",
      capture_method: "local-script"
    },
    receipt_or_proof_ref: toFileUrl("..", "..", "docs", "ops", "example.md")
  }));

  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /source_provenance\.owner_surface must not be absolute or protocol-qualified/);
  assert.match(result.errors.join("\n"), /source_provenance\.source_refs\[0\] must not be absolute or protocol-qualified/);
  assert.match(result.errors.join("\n"), /receipt_or_proof_ref must not be absolute or protocol-qualified/);
});

test("non-normalized packet refs fail validation", () => {
  const result = validateGatewayPacket(buildValidPacket({
    source_provenance: {
      owner_surface: "repos/../repos/fawxzzy-fitness",
      source_type: "export",
      source_refs: ["runtime/../runtime/exports/example.json"],
      captured_at: "2026-05-27T00:00:00Z",
      capture_method: "local-script"
    },
    receipt_or_proof_ref: "./docs/ops/example.md"
  }));

  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /source_provenance\.owner_surface must be a normalized ATLAS-root-relative path without dot segments/);
  assert.match(result.errors.join("\n"), /source_provenance\.source_refs\[0\] must be a normalized ATLAS-root-relative path without dot segments/);
  assert.match(result.errors.join("\n"), /receipt_or_proof_ref must be a normalized ATLAS-root-relative path without dot segments/);
});

test("validator can read an explicit packet file path", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-validator-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const result = await runPacketValidation(packetPath);

  assert.equal(result.ok, true);
  await fs.rm(tempDir, { recursive: true, force: true });
});
