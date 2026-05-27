import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { loadPacketFromFile, validateGatewayPacket } from "./data-gateway-packet-validator.mjs";

const REVIEW_DISPOSITIONS = new Set(["approved", "rejected", "needs-revision", "no-decision"]);

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function assertFalseFlag(value, fieldName, errors) {
  if (value !== false) {
    errors.push(`${fieldName} must remain false.`);
  }
}

function validateEmittedMetadata(metadata, errors) {
  if (!isRecord(metadata)) {
    errors.push("packet-metadata.json must be a JSON object.");
    return;
  }

  if (metadata.emit_mode !== "dry-run") {
    errors.push("packet-metadata.json emit_mode must remain dry-run.");
  }

  assertFalseFlag(metadata.downstream_send_performed, "packet-metadata.json downstream_send_performed", errors);

  if (!isNonEmptyString(metadata.packet_id)) {
    errors.push("packet-metadata.json packet_id must be a non-empty string.");
  }

  if (!isNonEmptyString(metadata.lane)) {
    errors.push("packet-metadata.json lane must be a non-empty string.");
  }

  if (!isRecord(metadata.artifacts)) {
    errors.push("packet-metadata.json artifacts must be an object.");
    return;
  }

  for (const fieldName of ["packet", "summary", "metadata"]) {
    if (!isNonEmptyString(metadata.artifacts[fieldName])) {
      errors.push(`packet-metadata.json artifacts.${fieldName} must be a non-empty string.`);
    }
  }
}

function validateReviewMetadata(reviewMetadata, emittedMetadata, errors) {
  if (!isRecord(reviewMetadata)) {
    errors.push("packet-review-metadata.json must be a JSON object.");
    return;
  }

  if (reviewMetadata.review_mode !== "local-only") {
    errors.push("packet-review-metadata.json review_mode must remain local-only.");
  }

  if (!isNonEmptyString(reviewMetadata.packet_id)) {
    errors.push("packet-review-metadata.json packet_id must be a non-empty string.");
  } else if (reviewMetadata.packet_id !== emittedMetadata.packet_id) {
    errors.push("packet-review-metadata.json packet_id must match packet-metadata.json packet_id.");
  }

  if (!isNonEmptyString(reviewMetadata.lane)) {
    errors.push("packet-review-metadata.json lane must be a non-empty string.");
  } else if (reviewMetadata.lane !== emittedMetadata.lane) {
    errors.push("packet-review-metadata.json lane must match packet-metadata.json lane.");
  }

  if (!isNonEmptyString(reviewMetadata.reviewer)) {
    errors.push("packet-review-metadata.json reviewer must be a non-empty string.");
  }

  if (!isNonEmptyString(reviewMetadata.reviewed_at)) {
    errors.push("packet-review-metadata.json reviewed_at must be a non-empty string.");
  }

  if (!isNonEmptyString(reviewMetadata.disposition)) {
    errors.push("packet-review-metadata.json disposition must be a non-empty string.");
  } else if (!REVIEW_DISPOSITIONS.has(reviewMetadata.disposition)) {
    errors.push(`packet-review-metadata.json disposition must be one of: ${Array.from(REVIEW_DISPOSITIONS).join(", ")}.`);
  }

  if (reviewMetadata.packet_validation_result !== "pass") {
    errors.push("packet-review-metadata.json packet_validation_result must remain pass.");
  }

  if (!isRecord(reviewMetadata.no_send_attestation)) {
    errors.push("packet-review-metadata.json no_send_attestation must be an object.");
  } else {
    assertFalseFlag(
      reviewMetadata.no_send_attestation.downstream_send_performed,
      "packet-review-metadata.json no_send_attestation.downstream_send_performed",
      errors
    );
    assertFalseFlag(
      reviewMetadata.no_send_attestation.downstream_execution_performed,
      "packet-review-metadata.json no_send_attestation.downstream_execution_performed",
      errors
    );
    assertFalseFlag(
      reviewMetadata.no_send_attestation.remote_target_selected,
      "packet-review-metadata.json no_send_attestation.remote_target_selected",
      errors
    );
    assertFalseFlag(
      reviewMetadata.no_send_attestation.automatic_handoff_authorized,
      "packet-review-metadata.json no_send_attestation.automatic_handoff_authorized",
      errors
    );
  }
}

function formatProofSummary({ packet, proofMetadata }) {
  return [
    "# Local Data Gateway Proof Bundle",
    "",
    `- packet id: \`${proofMetadata.packet_id}\``,
    `- lane: \`${proofMetadata.lane}\``,
    `- packaged at: \`${proofMetadata.packaged_at}\``,
    `- proof mode: \`${proofMetadata.proof_mode}\``,
    `- local-only: \`${String(proofMetadata.local_only)}\``,
    `- packet purpose: \`${packet.packet_purpose}\``,
    `- schema version: \`${packet.packet_schema_version}\``,
    `- sensitivity label: \`${packet.sensitivity_label}\``,
    `- downstream target class: \`${packet.downstream_target_class}\``,
    `- validation result snapshot: \`${proofMetadata.packet_snapshot.validation_result}\``,
    `- review disposition snapshot: \`${proofMetadata.review_snapshot.disposition}\``,
    `- reviewer: \`${proofMetadata.review_snapshot.reviewer}\``,
    `- reviewed at: \`${proofMetadata.review_snapshot.reviewed_at}\``,
    `- reviewer note present: \`${String(proofMetadata.review_snapshot.reviewer_note_present)}\``,
    "",
    "## Source Artifact References",
    "",
    `- packet: \`${proofMetadata.source_artifact_references.packet}\``,
    `- packet summary: \`${proofMetadata.source_artifact_references.packet_summary}\``,
    `- packet metadata: \`${proofMetadata.source_artifact_references.packet_metadata}\``,
    `- review summary: \`${proofMetadata.source_artifact_references.review_summary}\``,
    `- review metadata: \`${proofMetadata.source_artifact_references.review_metadata}\``,
    "",
    "## No-Send Attestation",
    "",
    "- no downstream send performed",
    "- no downstream execution performed",
    "- no remote target selected",
    "- no automatic handoff authorized",
    "",
    "## Generated Proof Bundle",
    "",
    "- `proof-summary.md`",
    "- `proof-metadata.json`",
    "",
    "## Deferred",
    "",
    "- downstream send boundary",
    "- transport/sync/post behavior",
    "- model/API/SaaS invocation",
    "- lane-specific execution automation"
  ].join("\n");
}

export async function packageReviewedPacketProof({
  artifactDir,
  packagedAt = new Date()
}) {
  const errors = [];

  if (!isNonEmptyString(artifactDir)) {
    errors.push("artifactDir is required.");
    return {
      ok: false,
      errors,
      wroteArtifacts: false
    };
  }

  const resolvedArtifactDir = path.resolve(artifactDir);
  const packetPath = path.join(resolvedArtifactDir, "packet.json");
  const summaryPath = path.join(resolvedArtifactDir, "packet-summary.md");
  const metadataPath = path.join(resolvedArtifactDir, "packet-metadata.json");
  const reviewPath = path.join(resolvedArtifactDir, "packet-review.md");
  const reviewMetadataPath = path.join(resolvedArtifactDir, "packet-review-metadata.json");
  const proofSummaryPath = path.join(resolvedArtifactDir, "proof-summary.md");
  const proofMetadataPath = path.join(resolvedArtifactDir, "proof-metadata.json");

  for (const requiredPath of [packetPath, summaryPath, metadataPath, reviewPath, reviewMetadataPath]) {
    try {
      const stat = await fs.stat(requiredPath);
      if (!stat.isFile()) {
        errors.push(`${path.basename(requiredPath)} must be a file.`);
      }
    } catch {
      errors.push(`Missing required artifact: ${path.basename(requiredPath)}.`);
    }
  }

  if (errors.length > 0) {
    return {
      ok: false,
      errors,
      artifactDir: resolvedArtifactDir,
      wroteArtifacts: false
    };
  }

  const packet = await loadPacketFromFile(packetPath);
  const validation = validateGatewayPacket(packet);
  if (!validation.ok) {
    return {
      ok: false,
      errors: validation.errors,
      artifactDir: resolvedArtifactDir,
      wroteArtifacts: false
    };
  }

  const emittedMetadata = JSON.parse(await fs.readFile(metadataPath, "utf8"));
  const reviewMetadata = JSON.parse(await fs.readFile(reviewMetadataPath, "utf8"));

  validateEmittedMetadata(emittedMetadata, errors);
  validateReviewMetadata(reviewMetadata, emittedMetadata, errors);

  if (errors.length > 0) {
    return {
      ok: false,
      errors,
      artifactDir: resolvedArtifactDir,
      wroteArtifacts: false
    };
  }

  const proofMetadata = {
    packet_id: emittedMetadata.packet_id,
    lane: emittedMetadata.lane,
    proof_mode: "local-proof-only",
    local_only: true,
    packaged_at: packagedAt.toISOString(),
    source_artifact_references: {
      packet: packetPath,
      packet_summary: summaryPath,
      packet_metadata: metadataPath,
      review_summary: reviewPath,
      review_metadata: reviewMetadataPath
    },
    generated_proof_artifacts: {
      summary: proofSummaryPath,
      metadata: proofMetadataPath
    },
    no_send_attestation: {
      downstream_send_performed: false,
      downstream_execution_performed: false,
      remote_target_selected: false,
      automatic_handoff_authorized: false
    },
    packet_snapshot: {
      packet_purpose: packet.packet_purpose,
      packet_schema_version: packet.packet_schema_version,
      sensitivity_label: packet.sensitivity_label,
      downstream_target_class: packet.downstream_target_class,
      validation_result: packet.validation_result,
      redaction_status: packet.redaction_status,
      dedupe_status: packet.dedupe_status,
      receipt_or_proof_ref: isNonEmptyString(packet.receipt_or_proof_ref) ? packet.receipt_or_proof_ref : null
    },
    review_snapshot: {
      review_mode: reviewMetadata.review_mode,
      reviewed_at: reviewMetadata.reviewed_at,
      reviewer: reviewMetadata.reviewer,
      disposition: reviewMetadata.disposition,
      reviewer_note_present: isNonEmptyString(reviewMetadata.reviewer_note),
      packet_validation_result: reviewMetadata.packet_validation_result
    }
  };

  await fs.writeFile(proofSummaryPath, `${formatProofSummary({ packet, proofMetadata })}\n`, "utf8");
  await fs.writeFile(proofMetadataPath, `${JSON.stringify(proofMetadata, null, 2)}\n`, "utf8");

  return {
    ok: true,
    errors: [],
    artifactDir: resolvedArtifactDir,
    proofArtifacts: {
      summary: proofSummaryPath,
      metadata: proofMetadataPath
    },
    proofMetadata
  };
}

function formatUsage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --artifact-dir <dir>`,
    "",
    "Packages a reviewed Local Data Gateway packet into a local-only proof bundle.",
    "No send, transport, model, API, SaaS, or downstream execution behavior is performed."
  ].join("\n");
}

async function main(argv) {
  const args = [...argv];

  if (args.includes("--help") || args.includes("-h")) {
    console.log(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const artifactDirIndex = args.indexOf("--artifact-dir");
  if (artifactDirIndex === -1 || !args[artifactDirIndex + 1]) {
    console.error("Missing required --artifact-dir <dir> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  try {
    const result = await packageReviewedPacketProof({
      artifactDir: args[artifactDirIndex + 1]
    });

    if (!result.ok) {
      console.error(JSON.stringify({
        ok: false,
        artifactDir: result.artifactDir ?? null,
        errors: result.errors
      }, null, 2));
      return 1;
    }

    console.log(JSON.stringify({
      ok: true,
      artifactDir: result.artifactDir,
      proofArtifacts: result.proofArtifacts,
      noSendAttestation: result.proofMetadata.no_send_attestation,
      errors: []
    }, null, 2));
    return 0;
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      errors: [error instanceof Error ? error.message : String(error)]
    }, null, 2));
    return 1;
  }
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  const exitCode = await main(process.argv.slice(2));
  process.exit(exitCode);
}
