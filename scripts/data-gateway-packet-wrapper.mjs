import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { emitDryRunPacket } from "./data-gateway-packet-emitter.mjs";
import { reviewDryRunPacket } from "./data-gateway-packet-review.mjs";
import { runPacketValidation } from "./data-gateway-packet-validator.mjs";

const WRAPPER_MODES = new Set(["validate-only", "emit-dry-run", "review-only"]);
const UNIVERSALLY_REJECTED_FLAGS = new Set([
  "--target",
  "--endpoint",
  "--remote-target",
  "--webhook",
  "--send",
  "--sync",
  "--submit",
  "--post",
  "--token",
  "--secret",
  "--model",
  "--provider"
]);

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function buildNoSendAttestation() {
  return {
    downstream_send_performed: false,
    downstream_execution_performed: false,
    remote_target_selected: false,
    automatic_handoff_authorized: false
  };
}

function buildUsage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --lane <lane> --mode <validate-only|emit-dry-run> --source <local-path> [--artifact-root <path>]`,
    `  node ${scriptName} --lane <lane> --mode review-only --artifact-dir <path> --reviewer <label> --disposition <approved|rejected|needs-revision|no-decision> [--note <text>]`,
    "",
    "Thin Local Data Gateway wrapper over the existing local helper family.",
    "Package 2 adds review-only over an existing emitted packet artifact directory.",
    "No send, transport, target selection, or downstream execution is performed."
  ].join("\n");
}

function buildSummaryBase({ lane, mode, sourcePath, artifactDir }) {
  return {
    ok: false,
    lane,
    mode,
    sourcePath: isNonEmptyString(sourcePath) ? path.resolve(sourcePath) : null,
    artifactDir: isNonEmptyString(artifactDir) ? path.resolve(artifactDir) : null,
    noSendAttestation: buildNoSendAttestation()
  };
}

function parseArgs(argv) {
  const args = [...argv];

  if (args.includes("--help") || args.includes("-h")) {
    return {
      help: true
    };
  }

  for (const flag of UNIVERSALLY_REJECTED_FLAGS) {
    if (args.includes(flag)) {
      return {
        ok: false,
        errors: [`${flag} is not admitted in wrapper package 2.`]
      };
    }
  }

  const laneIndex = args.indexOf("--lane");
  const modeIndex = args.indexOf("--mode");

  if (laneIndex === -1 || !args[laneIndex + 1]) {
    return {
      ok: false,
      errors: ["Missing required --lane <lane> argument."]
    };
  }

  if (modeIndex === -1 || !args[modeIndex + 1]) {
    return {
      ok: false,
      errors: ["Missing required --mode <validate-only|emit-dry-run|review-only> argument."]
    };
  }

  const lane = args[laneIndex + 1];
  const mode = args[modeIndex + 1];

  if (!isNonEmptyString(lane)) {
    return {
      ok: false,
      errors: ["--lane must be a non-empty string."]
    };
  }

  if (!WRAPPER_MODES.has(mode)) {
    return {
      ok: false,
      errors: [`--mode must be one of: ${Array.from(WRAPPER_MODES).join(", ")}.`]
    };
  }

  const sourceIndex = args.indexOf("--source");
  const artifactRootIndex = args.indexOf("--artifact-root");
  const artifactDirIndex = args.indexOf("--artifact-dir");
  const reviewerIndex = args.indexOf("--reviewer");
  const dispositionIndex = args.indexOf("--disposition");
  const noteIndex = args.indexOf("--note");

  if (mode === "review-only") {
    if (sourceIndex !== -1) {
      return {
        ok: false,
        errors: ["--source is not admitted in review-only mode."]
      };
    }

    if (artifactRootIndex !== -1) {
      return {
        ok: false,
        errors: ["--artifact-root is not admitted in review-only mode."]
      };
    }

    if (artifactDirIndex === -1 || !args[artifactDirIndex + 1]) {
      return {
        ok: false,
        errors: ["Missing required --artifact-dir <path> argument."]
      };
    }

    if (reviewerIndex === -1 || !args[reviewerIndex + 1]) {
      return {
        ok: false,
        errors: ["Missing required --reviewer <label> argument."]
      };
    }

    if (dispositionIndex === -1 || !args[dispositionIndex + 1]) {
      return {
        ok: false,
        errors: ["Missing required --disposition <value> argument."]
      };
    }

    return {
      ok: true,
      lane,
      mode,
      artifactDir: path.resolve(process.cwd(), args[artifactDirIndex + 1]),
      reviewer: args[reviewerIndex + 1],
      disposition: args[dispositionIndex + 1],
      reviewerNote: noteIndex !== -1 && args[noteIndex + 1] ? args[noteIndex + 1] : ""
    };
  }

  if (artifactDirIndex !== -1 || reviewerIndex !== -1 || dispositionIndex !== -1 || noteIndex !== -1) {
    return {
      ok: false,
      errors: ["Review-only arguments are not admitted outside review-only mode."]
    };
  }

  if (sourceIndex === -1 || !args[sourceIndex + 1]) {
    return {
      ok: false,
      errors: ["Missing required --source <local-path> argument."]
    };
  }

  return {
    ok: true,
    lane,
    mode,
    sourcePath: path.resolve(process.cwd(), args[sourceIndex + 1]),
    artifactRoot: artifactRootIndex !== -1 && args[artifactRootIndex + 1]
      ? path.resolve(process.cwd(), args[artifactRootIndex + 1])
      : undefined
  };
}

export async function runPacketWrapper({
  lane,
  mode,
  sourcePath,
  artifactRoot,
  artifactDir,
  reviewer,
  disposition,
  reviewerNote
}) {
  const summary = buildSummaryBase({
    lane,
    mode,
    sourcePath,
    artifactDir
  });

  if (mode === "review-only") {
    const reviewResult = await reviewDryRunPacket({
      artifactDir,
      reviewer,
      disposition,
      reviewerNote
    });

    if (!reviewResult.ok) {
      return {
        ...summary,
        artifactDir: reviewResult.artifactDir ?? summary.artifactDir,
        errors: reviewResult.errors,
        validationState: "not-run",
        reviewState: "fail",
        failureStage: "review"
      };
    }

    return {
      ...summary,
      ok: true,
      lane: reviewResult.reviewMetadata.lane,
      errors: [],
      artifactDir: reviewResult.artifactDir,
      packetId: reviewResult.reviewMetadata.packet_id,
      validationState: reviewResult.reviewMetadata.packet_validation_result,
      reviewState: "recorded",
      reviewer: reviewResult.reviewMetadata.reviewer,
      disposition: reviewResult.reviewMetadata.disposition,
      wrapperStage: "review",
      reviewArtifacts: reviewResult.reviewArtifacts,
      noSendAttestation: reviewResult.reviewMetadata.no_send_attestation
    };
  }

  const validation = await runPacketValidation(sourcePath);
  if (!validation.ok) {
    return {
      ...summary,
      errors: validation.errors,
      validationState: "fail",
      failureStage: "validate"
    };
  }

  if (mode === "validate-only") {
    return {
      ...summary,
      ok: true,
      errors: [],
      validationState: "pass",
      wrapperStage: "validate"
    };
  }

  const emitResult = await emitDryRunPacket({
    inputPath: sourcePath,
    lane,
    artifactRoot
  });

  if (!emitResult.ok) {
    return {
      ...summary,
      errors: emitResult.errors,
      validationState: "pass",
      failureStage: "emit"
    };
  }

  return {
    ...summary,
    ok: true,
    errors: [],
    validationState: "pass",
    wrapperStage: "emit",
    packetId: emitResult.packetId,
    artifactDir: emitResult.artifactDir,
    emittedArtifacts: emitResult.artifacts
  };
}

async function main(argv) {
  const parsed = parseArgs(argv);
  const scriptName = path.basename(fileURLToPath(import.meta.url));

  if (parsed.help) {
    console.log(buildUsage(scriptName));
    return 0;
  }

  if (!parsed.ok) {
    console.error(JSON.stringify({
      ok: false,
      errors: parsed.errors
    }, null, 2));
    console.error(buildUsage(scriptName));
    return 1;
  }

  try {
    const result = await runPacketWrapper(parsed);
    const output = {
      ...result
    };

    if (!result.ok) {
      console.error(JSON.stringify(output, null, 2));
      return 1;
    }

    console.log(JSON.stringify(output, null, 2));
    return 0;
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      errors: [error instanceof Error ? error.message : String(error)],
      noSendAttestation: buildNoSendAttestation()
    }, null, 2));
    return 1;
  }
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  const exitCode = await main(process.argv.slice(2));
  process.exit(exitCode);
}
