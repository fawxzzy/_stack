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

function validateReviewMetadata(metadata, errors) {
  if (!isRecord(metadata)) {
    errors.push("packet-metadata.json must be a JSON object.");
    return;
  }

  if (metadata.emit_mode !== "dry-run") {
    errors.push("packet-metadata.json emit_mode must remain dry-run.");
  }

  if (metadata.downstream_send_performed !== false) {
    errors.push("packet-metadata.json downstream_send_performed must remain false.");
  }

  if (!isNonEmptyString(metadata.packet_id)) {
    errors.push("packet-metadata.json packet_id must be a non-empty string.");
  }

  if (!isNonEmptyString(metadata.lane)) {
    errors.push("packet-metadata.json lane must be a non-empty string.");
  }
}

function formatReviewSummary({ packet, reviewMetadata }) {
  const noteLine = isNonEmptyString(reviewMetadata.reviewer_note)
    ? `- reviewer note: ${reviewMetadata.reviewer_note}`
    : "- reviewer note: none";

  return [
    "# Local Data Gateway Packet Review",
    "",
    `- packet id: \`${reviewMetadata.packet_id}\``,
    `- lane: \`${reviewMetadata.lane}\``,
    `- reviewed at: \`${reviewMetadata.reviewed_at}\``,
    `- reviewer: \`${reviewMetadata.reviewer}\``,
    `- disposition: \`${reviewMetadata.disposition}\``,
    noteLine,
    `- packet purpose: \`${packet.packet_purpose}\``,
    `- schema version: \`${packet.packet_schema_version}\``,
    `- sensitivity label: \`${packet.sensitivity_label}\``,
    `- downstream target class: \`${packet.downstream_target_class}\``,
    `- packet validation result: \`${reviewMetadata.packet_validation_result}\``,
    "",
    "## No-Send Attestation",
    "",
    "- no downstream send performed",
    "- no downstream execution performed",
    "- no remote target selected",
    "- approval does not imply automatic transport or execution",
    "",
    "## Reviewed Artifacts",
    "",
    `- \`packet.json\``,
    `- \`packet-summary.md\``,
    `- \`packet-metadata.json\``,
    "",
    "## Deferred",
    "",
    "- downstream send boundary",
    "- transport/sync/post behavior",
    "- model/API/SaaS invocation",
    "- lane-specific execution automation"
  ].join("\n");
}

export async function reviewDryRunPacket({
  artifactDir,
  reviewer,
  disposition,
  reviewerNote = "",
  reviewedAt = new Date()
}) {
  const errors = [];

  if (!isNonEmptyString(artifactDir)) {
    errors.push("artifactDir is required.");
  }

  if (!isNonEmptyString(reviewer)) {
    errors.push("reviewer is required.");
  }

  if (!isNonEmptyString(disposition)) {
    errors.push("disposition is required.");
  } else if (!REVIEW_DISPOSITIONS.has(disposition)) {
    errors.push(`disposition must be one of: ${Array.from(REVIEW_DISPOSITIONS).join(", ")}.`);
  }

  if (errors.length > 0) {
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

  for (const requiredPath of [packetPath, summaryPath, metadataPath]) {
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
  validateReviewMetadata(emittedMetadata, errors);

  if (errors.length > 0) {
    return {
      ok: false,
      errors,
      artifactDir: resolvedArtifactDir,
      wroteArtifacts: false
    };
  }

  const reviewMetadata = {
    packet_id: emittedMetadata.packet_id,
    lane: emittedMetadata.lane,
    review_mode: "local-only",
    reviewed_at: reviewedAt.toISOString(),
    reviewer,
    disposition,
    reviewer_note: isNonEmptyString(reviewerNote) ? reviewerNote.trim() : null,
    packet_validation_result: "pass",
    no_send_attestation: {
      downstream_send_performed: false,
      downstream_execution_performed: false,
      remote_target_selected: false,
      automatic_handoff_authorized: false
    },
    reviewed_artifacts: {
      packet: packetPath,
      summary: summaryPath,
      metadata: metadataPath
    },
    generated_review_artifacts: {
      review: reviewPath,
      metadata: reviewMetadataPath
    },
    constraints: [
      "review only",
      "no downstream send",
      "no downstream execution",
      "approval does not imply automatic transport"
    ]
  };

  await fs.writeFile(reviewPath, `${formatReviewSummary({ packet, reviewMetadata })}\n`, "utf8");
  await fs.writeFile(reviewMetadataPath, `${JSON.stringify(reviewMetadata, null, 2)}\n`, "utf8");

  return {
    ok: true,
    errors: [],
    artifactDir: resolvedArtifactDir,
    reviewArtifacts: {
      review: reviewPath,
      metadata: reviewMetadataPath
    },
    reviewMetadata
  };
}

function formatUsage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --artifact-dir <dir> --reviewer <label> --disposition <approved|rejected|needs-revision|no-decision> [--note <text>]`,
    "",
    "Records a Local Data Gateway local-only review decision for a previously emitted packet.",
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
  const reviewerIndex = args.indexOf("--reviewer");
  const dispositionIndex = args.indexOf("--disposition");
  const noteIndex = args.indexOf("--note");

  if (artifactDirIndex === -1 || !args[artifactDirIndex + 1]) {
    console.error("Missing required --artifact-dir <dir> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  if (reviewerIndex === -1 || !args[reviewerIndex + 1]) {
    console.error("Missing required --reviewer <label> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  if (dispositionIndex === -1 || !args[dispositionIndex + 1]) {
    console.error("Missing required --disposition <value> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  try {
    const result = await reviewDryRunPacket({
      artifactDir: args[artifactDirIndex + 1],
      reviewer: args[reviewerIndex + 1],
      disposition: args[dispositionIndex + 1],
      reviewerNote: noteIndex !== -1 && args[noteIndex + 1] ? args[noteIndex + 1] : ""
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
      reviewArtifacts: result.reviewArtifacts,
      noSendAttestation: result.reviewMetadata.no_send_attestation,
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
