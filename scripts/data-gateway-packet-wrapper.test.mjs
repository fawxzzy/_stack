import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { emitDryRunPacket } from "./data-gateway-packet-emitter.mjs";
import { reviewDryRunPacket } from "./data-gateway-packet-review.mjs";
import { runPacketWrapper } from "./data-gateway-packet-wrapper.mjs";

const WORKFLOW_CASES = [
  {
    lane: "supabase-export-approval",
    packet: {
      packet_purpose: "supabase-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "export",
        source_refs: ["docs/ops/FITNESS-SUPABASE-PROFILE-DATA-HYGIENE-EXPORT-PACKET-1-2026-05-24.md"],
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
        notes: ["bounded approval rows only"]
      }
    }
  },
  {
    lane: "vercel-dependency-deletion-decision",
    packet: {
      packet_purpose: "vercel-review",
      source_provenance: {
        owner_surface: "repos/_stack",
        source_type: "receipt-chain",
        source_refs: ["docs/ops/VERCEL-HELPER-SURFACE-DELETION-DECISION-2026-05-25.md"],
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
        notes: ["candidate helper dependency scope only"]
      }
    }
  },
  {
    lane: "discordos-trust-boundary",
    packet: {
      packet_purpose: "discordos-boundary-handoff",
      source_provenance: {
        owner_surface: "repos/DiscordOS",
        source_type: "receipt-chain",
        source_refs: ["repos/DiscordOS/docs/ops/feedback-lookup-transport-neutral-externally-backed-live-provider-trust-boundary-package-16-2026-05-27.md"],
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
        notes: ["trust-boundary payload only"]
      }
    }
  }
];

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

async function emitReviewablePacket({ lane }) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const emitted = await emitDryRunPacket({
    inputPath: packetPath,
    lane,
    artifactRoot: tempDir
  });

  assert.equal(emitted.ok, true);

  return {
    tempDir,
    packetPath,
    emitted
  };
}

async function emitWorkflowPacket({ lane, packetOverrides }) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket(packetOverrides)), "utf8");

  const emitted = await emitDryRunPacket({
    inputPath: packetPath,
    lane,
    artifactRoot: tempDir
  });

  assert.equal(emitted.ok, true);

  return {
    tempDir,
    packetPath,
    emitted
  };
}

async function emitReviewedWorkflowPacket({ lane, packetOverrides }) {
  const emittedPacket = await emitWorkflowPacket({ lane, packetOverrides });
  const reviewed = await reviewDryRunPacket({
    artifactDir: emittedPacket.emitted.artifactDir,
    reviewer: "codex",
    disposition: "approved",
    reviewerNote: "local review complete"
  });

  assert.equal(reviewed.ok, true);

  return {
    ...emittedPacket,
    reviewed
  };
}

async function writePacketToTemp(packetOverrides = {}) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket(packetOverrides)), "utf8");

  return {
    tempDir,
    packetPath
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

test("review-only succeeds on the three admitted workflow classes and preserves no-send state", async () => {
  for (const workflowCase of WORKFLOW_CASES) {
    const { tempDir, emitted } = await emitWorkflowPacket({
      lane: workflowCase.lane,
      packetOverrides: workflowCase.packet
    });

    const result = await runPacketWrapper({
      lane: workflowCase.lane,
      mode: "review-only",
      artifactDir: emitted.artifactDir,
      reviewer: "codex",
      disposition: "approved",
      reviewerNote: "local review complete"
    });

    assert.equal(result.ok, true);
    assert.equal(result.wrapperStage, "review");
    assert.equal(result.validationState, "pass");
    assert.equal(result.reviewState, "recorded");
    assert.equal(result.reviewer, "codex");
    assert.equal(result.disposition, "approved");
    assert.equal(result.lane, workflowCase.lane);
    assert.equal(result.noSendAttestation.downstream_send_performed, false);
    assert.equal(result.noSendAttestation.automatic_handoff_authorized, false);
    assert.ok(result.reviewArtifacts.review.startsWith(tempDir));
    assert.ok(result.reviewArtifacts.metadata.startsWith(tempDir));

    const reviewMetadata = JSON.parse(await fs.readFile(result.reviewArtifacts.metadata, "utf8"));
    assert.equal(reviewMetadata.review_mode, "local-only");
    assert.equal(reviewMetadata.disposition, "approved");
    assert.equal(reviewMetadata.lane, workflowCase.lane);
    assert.equal(reviewMetadata.no_send_attestation.downstream_send_performed, false);

    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

test("review-only fails closed on missing packet prerequisites", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "review-only",
    artifactDir: tempDir,
    reviewer: "codex",
    disposition: "approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "review");
  assert.equal(result.reviewState, "fail");
  assert.match(result.errors.join("\n"), /Missing required artifact: packet\.json\./);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("review-only does not bypass primitive review checks", async () => {
  const { tempDir, emitted } = await emitReviewablePacket({
    lane: "discordos-feedback"
  });

  const metadata = JSON.parse(await fs.readFile(emitted.artifacts.metadata, "utf8"));
  metadata.emit_mode = "send";
  await fs.writeFile(emitted.artifacts.metadata, `${JSON.stringify(metadata, null, 2)}\n`, "utf8");

  const result = await runPacketWrapper({
    lane: "discordos-feedback",
    mode: "review-only",
    artifactDir: emitted.artifactDir,
    reviewer: "codex",
    disposition: "needs-revision"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "review");
  assert.equal(result.reviewState, "fail");
  assert.match(result.errors.join("\n"), /emit_mode must remain dry-run/);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("wrapper CLI rejects transport-shaped flags at the review-only entrypoint in package 2", async () => {
  const { tempDir, emitted } = await emitReviewablePacket({
    lane: "supabase-review"
  });

  const scriptPath = path.resolve("scripts/data-gateway-packet-wrapper.mjs");

  for (const flag of ["--target", "--secret", "--send"]) {
    const result = spawnSync(
      process.execPath,
      [
        scriptPath,
        "--lane", "supabase-review",
        "--mode", "review-only",
        "--artifact-dir", emitted.artifactDir,
        "--reviewer", "codex",
        "--disposition", "approved",
        flag, "example"
      ],
      {
        cwd: path.resolve("."),
        encoding: "utf8"
      }
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${flag} is not admitted in wrapper package 2`));
  }

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("proof-only succeeds on the three admitted workflow classes and preserves no-send state", async () => {
  for (const workflowCase of WORKFLOW_CASES) {
    const { tempDir, emitted } = await emitReviewedWorkflowPacket({
      lane: workflowCase.lane,
      packetOverrides: workflowCase.packet
    });

    const result = await runPacketWrapper({
      lane: workflowCase.lane,
      mode: "proof-only",
      artifactDir: emitted.artifactDir
    });

    assert.equal(result.ok, true);
    assert.equal(result.wrapperStage, "proof");
    assert.equal(result.validationState, "pass");
    assert.equal(result.reviewState, "approved");
    assert.equal(result.proofState, "packaged");
    assert.equal(result.lane, workflowCase.lane);
    assert.equal(result.noSendAttestation.downstream_send_performed, false);
    assert.equal(result.noSendAttestation.automatic_handoff_authorized, false);
    assert.ok(result.proofArtifacts.summary.startsWith(tempDir));
    assert.ok(result.proofArtifacts.metadata.startsWith(tempDir));

    const proofMetadata = JSON.parse(await fs.readFile(result.proofArtifacts.metadata, "utf8"));
    assert.equal(proofMetadata.proof_mode, "local-proof-only");
    assert.equal(proofMetadata.review_snapshot.disposition, "approved");
    assert.equal(proofMetadata.lane, workflowCase.lane);
    assert.equal(proofMetadata.no_send_attestation.downstream_send_performed, false);

    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

test("proof-only fails closed on missing reviewed packet prerequisites", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "proof-only",
    artifactDir: tempDir
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "proof");
  assert.equal(result.proofState, "fail");
  assert.match(result.errors.join("\n"), /Missing required artifact: packet\.json\./);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("proof-only does not bypass primitive proof-packager checks", async () => {
  const { tempDir, emitted } = await emitReviewedWorkflowPacket({
    lane: "discordos-feedback",
    packetOverrides: {
      packet_purpose: "discordos-boundary-handoff",
      source_provenance: {
        owner_surface: "repos/DiscordOS",
        source_type: "receipt-chain",
        source_refs: ["repos/DiscordOS/docs/ops/example.md"],
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
        notes: ["trust-boundary payload only"]
      }
    }
  });

  const reviewMetadataPath = path.join(emitted.artifactDir, "packet-review-metadata.json");
  const reviewMetadata = JSON.parse(await fs.readFile(reviewMetadataPath, "utf8"));
  reviewMetadata.disposition = "auto-approved";
  await fs.writeFile(reviewMetadataPath, `${JSON.stringify(reviewMetadata, null, 2)}\n`, "utf8");

  const result = await runPacketWrapper({
    lane: "discordos-feedback",
    mode: "proof-only",
    artifactDir: emitted.artifactDir
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "proof");
  assert.equal(result.proofState, "fail");
  assert.match(result.errors.join("\n"), /disposition must be one of/);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("wrapper CLI rejects transport-shaped flags at the proof-only entrypoint in package 3", async () => {
  const { tempDir, emitted } = await emitReviewedWorkflowPacket({
    lane: "supabase-review",
    packetOverrides: {
      packet_purpose: "supabase-review"
    }
  });

  const scriptPath = path.resolve("scripts/data-gateway-packet-wrapper.mjs");

  for (const flag of ["--target", "--secret", "--send"]) {
    const result = spawnSync(
      process.execPath,
      [
        scriptPath,
        "--lane", "supabase-review",
        "--mode", "proof-only",
        "--artifact-dir", emitted.artifactDir,
        flag, "example"
      ],
      {
        cwd: path.resolve("."),
        encoding: "utf8"
      }
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${flag} is not admitted in wrapper package 3`));
  }

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain succeeds on the three admitted workflow classes and stays receipt-ready local-only", async () => {
  for (const workflowCase of WORKFLOW_CASES) {
    const { tempDir, packetPath } = await writePacketToTemp(workflowCase.packet);

    const result = await runPacketWrapper({
      lane: workflowCase.lane,
      mode: "full-local-chain",
      sourcePath: packetPath,
      artifactRoot: tempDir,
      reviewer: "codex",
      disposition: "approved",
      reviewerNote: "full local chain complete"
    });

    assert.equal(result.ok, true);
    assert.equal(result.lane, workflowCase.lane);
    assert.equal(result.mode, "full-local-chain");
    assert.equal(result.wrapperStage, "proof");
    assert.equal(result.validationState, "pass");
    assert.equal(result.reviewState, "recorded");
    assert.equal(result.disposition, "approved");
    assert.equal(result.proofState, "packaged");
    assert.equal(typeof result.packetId, "string");
    assert.ok(result.packetId.length > 0);
    assert.equal(result.noSendAttestation.downstream_send_performed, false);
    assert.equal(result.noSendAttestation.downstream_execution_performed, false);
    assert.equal(result.noSendAttestation.remote_target_selected, false);
    assert.equal(result.noSendAttestation.automatic_handoff_authorized, false);
    assert.ok(result.artifactDir.startsWith(tempDir));
    assert.ok(result.emittedArtifacts.packet.startsWith(tempDir));
    assert.ok(result.emittedArtifacts.metadata.startsWith(tempDir));
    assert.ok(result.reviewArtifacts.review.startsWith(tempDir));
    assert.ok(result.reviewArtifacts.metadata.startsWith(tempDir));
    assert.ok(result.proofArtifacts.summary.startsWith(tempDir));
    assert.ok(result.proofArtifacts.metadata.startsWith(tempDir));
    assert.equal(path.dirname(result.emittedArtifacts.packet), result.artifactDir);
    assert.equal(path.dirname(result.reviewArtifacts.review), result.artifactDir);
    assert.equal(path.dirname(result.proofArtifacts.summary), result.artifactDir);

    const artifactNames = (await fs.readdir(result.artifactDir)).sort();
    assert.deepEqual(artifactNames, [
      "packet-metadata.json",
      "packet-review-metadata.json",
      "packet-review.md",
      "packet-summary.md",
      "packet.json",
      "proof-metadata.json",
      "proof-summary.md"
    ]);

    const proofMetadata = JSON.parse(await fs.readFile(result.proofArtifacts.metadata, "utf8"));
    assert.equal(proofMetadata.lane, workflowCase.lane);
    assert.equal(proofMetadata.proof_mode, "local-proof-only");
    assert.equal(proofMetadata.review_snapshot.disposition, "approved");
    assert.equal(proofMetadata.no_send_attestation.downstream_send_performed, false);

    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

test("full-local-chain fails at validation and stops before artifact emission", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket();
  delete packet.packet_purpose;
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: tempDir,
    reviewer: "codex",
    disposition: "approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "validate");
  assert.equal(result.validationState, "fail");
  assert.equal(result.artifactDir, null);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain fails at emit and stops before review or proof", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const blockedArtifactRoot = path.join(tempDir, "artifact-root-blocker");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");
  await fs.writeFile(blockedArtifactRoot, "blocked", "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: blockedArtifactRoot,
    reviewer: "codex",
    disposition: "approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "emit");
  assert.equal(result.validationState, "pass");
  assert.equal(result.reviewState, undefined);
  assert.equal(result.proofState, undefined);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries.sort(), ["artifact-root-blocker", "packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain fails at review and does not run proof", async () => {
  const { tempDir, packetPath } = await writePacketToTemp();

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: tempDir,
    reviewer: "codex",
    disposition: "auto-approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "review");
  assert.equal(result.validationState, "pass");
  assert.equal(result.reviewState, "fail");
  assert.ok(result.artifactDir.startsWith(tempDir));
  assert.ok(result.emittedArtifacts.packet.startsWith(tempDir));
  assert.equal(await fs.stat(path.join(result.artifactDir, "packet.json")).then(() => true, () => false), true);
  assert.equal(await fs.stat(path.join(result.artifactDir, "packet-review.md")).then(() => true, () => false), false);
  assert.equal(await fs.stat(path.join(result.artifactDir, "proof-summary.md")).then(() => true, () => false), false);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain fails at proof and does not downgrade primitive proof failure", async () => {
  const { tempDir, packetPath } = await writePacketToTemp();

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: tempDir,
    reviewer: "codex",
    disposition: "approved",
    stageHooks: {
      async afterReview({ artifactDir }) {
        const reviewMetadataPath = path.join(artifactDir, "packet-review-metadata.json");
        const reviewMetadata = JSON.parse(await fs.readFile(reviewMetadataPath, "utf8"));
        reviewMetadata.disposition = "auto-approved";
        await fs.writeFile(reviewMetadataPath, `${JSON.stringify(reviewMetadata, null, 2)}\n`, "utf8");
      }
    }
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "proof");
  assert.equal(result.validationState, "pass");
  assert.equal(result.reviewState, "recorded");
  assert.equal(result.proofState, "fail");
  assert.equal(await fs.stat(path.join(result.artifactDir, "packet-review.md")).then(() => true, () => false), true);
  assert.equal(await fs.stat(path.join(result.artifactDir, "proof-summary.md")).then(() => true, () => false), false);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("wrapper CLI rejects transport-shaped flags at the full-local-chain entrypoint in package 4", async () => {
  const { tempDir, packetPath } = await writePacketToTemp();
  const scriptPath = path.resolve("scripts/data-gateway-packet-wrapper.mjs");

  for (const flag of ["--target", "--secret", "--send"]) {
    const result = spawnSync(
      process.execPath,
      [
        scriptPath,
        "--lane", "supabase-review",
        "--mode", "full-local-chain",
        "--source", packetPath,
        "--artifact-root", tempDir,
        "--reviewer", "codex",
        "--disposition", "approved",
        flag, "example"
      ],
      {
        cwd: path.resolve("."),
        encoding: "utf8"
      }
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${flag} is not admitted in wrapper package 4`));
  }

  await fs.rm(tempDir, { recursive: true, force: true });
});
