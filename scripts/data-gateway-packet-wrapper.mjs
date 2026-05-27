import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { emitDryRunPacket } from "./data-gateway-packet-emitter.mjs";
import { runPacketValidation } from "./data-gateway-packet-validator.mjs";

const WRAPPER_MODES = new Set(["validate-only", "emit-dry-run"]);
const REJECTED_FLAGS = new Set([
  "--artifact-dir",
  "--reviewer",
  "--disposition",
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
    "",
    "Thin Local Data Gateway wrapper over the existing local helper family.",
    "Package 1 supports validate-only and emit-dry-run only.",
    "No send, transport, target selection, or downstream execution is performed."
  ].join("\n");
}

function buildSummaryBase({ lane, mode, sourcePath }) {
  return {
    ok: false,
    lane,
    mode,
    sourcePath,
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

  for (const flag of REJECTED_FLAGS) {
    if (args.includes(flag)) {
      return {
        ok: false,
        errors: [`${flag} is not admitted in wrapper package 1.`]
      };
    }
  }

  const laneIndex = args.indexOf("--lane");
  const modeIndex = args.indexOf("--mode");
  const sourceIndex = args.indexOf("--source");
  const artifactRootIndex = args.indexOf("--artifact-root");

  if (laneIndex === -1 || !args[laneIndex + 1]) {
    return {
      ok: false,
      errors: ["Missing required --lane <lane> argument."]
    };
  }

  if (modeIndex === -1 || !args[modeIndex + 1]) {
    return {
      ok: false,
      errors: ["Missing required --mode <validate-only|emit-dry-run> argument."]
    };
  }

  if (sourceIndex === -1 || !args[sourceIndex + 1]) {
    return {
      ok: false,
      errors: ["Missing required --source <local-path> argument."]
    };
  }

  const lane = args[laneIndex + 1];
  const mode = args[modeIndex + 1];
  const sourcePath = path.resolve(process.cwd(), args[sourceIndex + 1]);
  const artifactRoot = artifactRootIndex !== -1 && args[artifactRootIndex + 1]
    ? path.resolve(process.cwd(), args[artifactRootIndex + 1])
    : undefined;

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

  return {
    ok: true,
    lane,
    mode,
    sourcePath,
    artifactRoot
  };
}

export async function runPacketWrapper({ lane, mode, sourcePath, artifactRoot }) {
  const summary = buildSummaryBase({
    lane,
    mode,
    sourcePath: path.resolve(sourcePath)
  });

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
