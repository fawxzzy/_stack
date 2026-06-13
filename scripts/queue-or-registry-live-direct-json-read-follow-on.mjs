#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry live-direct-json-read-follow-on";
const CLASSIFIER_REF = "ops/atlas/runtime_state_execution_ready_transition_semantics.py";
const DIRECT_JSON_READ_STATUS = "readable-direct-json-candidate";

const ROUTING_NOTES = Object.freeze({
  success: "package one bounded direct-json-read report and continue",
  invalidInput: "fix candidate path input and rerun before live direct-json-read packaging",
  classifierFailed: "repair authoritative classifier execution or output before live direct-json-read claims",
  unsupportedTransition:
    "route to one bounded direct-json-read contradiction packet before queue-or-registry meaning claims",
  artifactMissing:
    "route to one bounded direct-json-read contradiction packet before queue-or-registry meaning claims",
  artifactMalformed:
    "route to one bounded direct-json-read contradiction packet before queue-or-registry meaning claims"
});

const FAILURE_CODES = new Set([
  "invalid-input",
  "classifier-failed",
  "unsupported-transition",
  "artifact-missing",
  "artifact-malformed"
]);

const DIRECT_BLOCKED_DECISIONS = new Set([
  "admitted-queue-home-live-direct-json-read-blocked-before-execution",
  "admitted-registry-home-live-direct-json-read-blocked-before-execution"
]);

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function normalizeRelativePath(value) {
  return value.trim().replaceAll("\\", "/");
}

function isRelativePath(value) {
  if (!isNonEmptyString(value)) {
    return false;
  }

  if (path.isAbsolute(value)) {
    return false;
  }

  return !normalizeRelativePath(value).startsWith("../");
}

function buildFailure({ failureCode, failureScope, message, routingNote }) {
  if (!FAILURE_CODES.has(failureCode)) {
    throw new Error(`Unsupported failure code: ${failureCode}`);
  }

  return {
    command: COMMAND_ID,
    failure_code: failureCode,
    failure_scope: failureScope,
    message,
    routing_note: routingNote
  };
}

function buildSuccess({
  normalizedCandidatePath,
  destinationClass,
  executionTransitionClass,
  artifactValueKind,
  artifactTopLevelKeys
}) {
  return {
    command: COMMAND_ID,
    classifier_ref: CLASSIFIER_REF,
    normalized_candidate_path: normalizedCandidatePath,
    destination_class: destinationClass,
    execution_transition_class: executionTransitionClass,
    direct_json_read_status: DIRECT_JSON_READ_STATUS,
    artifact_value_kind: artifactValueKind,
    artifact_top_level_keys: artifactTopLevelKeys,
    routing_note: ROUTING_NOTES.success
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_candidate_path=${result.report.normalized_candidate_path}`,
      `destination_class=${result.report.destination_class}`,
      `execution_transition_class=${result.report.execution_transition_class}`,
      `direct_json_read_status=${result.report.direct_json_read_status}`,
      `artifact_value_kind=${result.report.artifact_value_kind}`,
      `artifact_top_level_keys=${JSON.stringify(result.report.artifact_top_level_keys)}`,
      `classifier_ref=${result.report.classifier_ref}`,
      `routing_note=${result.report.routing_note}`
    ].join("\n") + "\n";
  }

  return [
    `failure_code=${result.report.failure_code}`,
    `message=${result.report.message}`,
    `routing_note=${result.report.routing_note}`
  ].join("\n") + "\n";
}

function parseArgs(argv) {
  const args = [...argv];
  const parsed = {
    format: "text",
    candidatePath: undefined
  };
  const errors = [];

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];

    if (token === "--format") {
      const value = args[index + 1];
      if (!value || (value !== "text" && value !== "json")) {
        errors.push("--format must be text or json.");
      } else {
        parsed.format = value;
      }
      index += 1;
      continue;
    }

    if (token === "--candidate-path") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--candidate-path requires a bounded relative path.");
      } else {
        parsed.candidatePath = value;
      }
      index += 1;
      continue;
    }

    errors.push(`Unsupported argument: ${token}`);
  }

  if (!isRelativePath(parsed.candidatePath)) {
    errors.push("--candidate-path must be a bounded relative path.");
  }

  if (parsed.candidatePath) {
    parsed.candidatePath = normalizeRelativePath(parsed.candidatePath);
  }

  return {
    ok: errors.length === 0,
    errors,
    args: parsed
  };
}

function getWorkspaceRoot() {
  if (isNonEmptyString(process.env.STACK_QUEUE_OR_REGISTRY_LIVE_DIRECT_JSON_READ_FOLLOW_ON_WORKSPACE_ROOT)) {
    return path.resolve(process.env.STACK_QUEUE_OR_REGISTRY_LIVE_DIRECT_JSON_READ_FOLLOW_ON_WORKSPACE_ROOT);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

async function defaultRunClassifier({ workspaceRoot, candidatePath }) {
  const classifierPath = path.join(workspaceRoot, CLASSIFIER_REF);
  const pythonCommand =
    process.env.STACK_QUEUE_OR_REGISTRY_LIVE_DIRECT_JSON_READ_FOLLOW_ON_PYTHON || "python";
  const payload = JSON.stringify({ candidate_path: candidatePath });

  return new Promise((resolve) => {
    const child = spawn(pythonCommand, [classifierPath, "--json", payload], {
      cwd: workspaceRoot,
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });

    child.on("error", (error) => {
      resolve({
        ok: false,
        exitCode: 1,
        stdout,
        stderr,
        error: error instanceof Error ? error.message : String(error)
      });
    });

    child.on("close", (exitCode) => {
      if (exitCode !== 0) {
        resolve({
          ok: false,
          exitCode: exitCode ?? 1,
          stdout,
          stderr
        });
        return;
      }

      let parsedPayload;
      try {
        parsedPayload = JSON.parse(stdout);
      } catch {
        resolve({
          ok: false,
          exitCode: exitCode ?? 1,
          stdout,
          stderr
        });
        return;
      }

      resolve({
        ok: true,
        exitCode: exitCode ?? 0,
        stdout,
        stderr,
        payload: parsedPayload
      });
    });
  });
}

function mapClassifierPayload(payload) {
  if (!isRecord(payload)) {
    return null;
  }

  const normalizedCandidatePath = payload.normalized_candidate_path;
  const destinationClass = payload.destination_class;
  const executionTransitionClass = payload.execution_transition_class;
  const decision = payload.decision;

  if (
    !isNonEmptyString(normalizedCandidatePath)
    || !isNonEmptyString(destinationClass)
    || !isNonEmptyString(executionTransitionClass)
    || !isNonEmptyString(decision)
  ) {
    return null;
  }

  return {
    normalizedCandidatePath,
    destinationClass,
    executionTransitionClass,
    decision
  };
}

function resolveCandidateArtifactPath(workspaceRoot, normalizedCandidatePath) {
  if (!isRelativePath(normalizedCandidatePath) || !normalizedCandidatePath.endsWith(".json")) {
    return null;
  }

  const resolvedPath = path.resolve(workspaceRoot, normalizedCandidatePath);
  const relative = path.relative(workspaceRoot, resolvedPath);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    return null;
  }

  return resolvedPath;
}

function classifyArtifactValue(value) {
  if (Array.isArray(value)) {
    return {
      artifactValueKind: "array",
      artifactTopLevelKeys: []
    };
  }

  if (isRecord(value)) {
    return {
      artifactValueKind: "object",
      artifactTopLevelKeys: Object.keys(value)
    };
  }

  return {
    artifactValueKind: "scalar",
    artifactTopLevelKeys: []
  };
}

export async function runQueueOrRegistryLiveDirectJsonReadFollowOnCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-input",
        failureScope: "input",
        message: parsed.errors.join(" "),
        routingNote: ROUTING_NOTES.invalidInput
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const runClassifier = dependencies.runClassifier || defaultRunClassifier;
  const fileReader = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));
  const classifierResult = await runClassifier({
    workspaceRoot,
    candidatePath: parsed.args.candidatePath
  });

  if (!classifierResult.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "classifier-failed",
        failureScope: "classifier",
        message: "The authoritative execution-transition classifier failed before live direct-json-read claims were admitted.",
        routingNote: ROUTING_NOTES.classifierFailed
      })
    };
  }

  const mapped = mapClassifierPayload(classifierResult.payload);
  if (!mapped) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "classifier-failed",
        failureScope: "classifier",
        message: "The authoritative execution-transition classifier emitted unsupported or malformed direct-json-read output.",
        routingNote: ROUTING_NOTES.classifierFailed
      })
    };
  }

  if (
    mapped.executionTransitionClass !== "blocked-pending-live-direct-json-read"
    || !DIRECT_BLOCKED_DECISIONS.has(mapped.decision)
  ) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "unsupported-transition",
        failureScope: "transition",
        message: "The authoritative execution-transition classifier did not preserve the admitted blocked direct-json-read posture.",
        routingNote: ROUTING_NOTES.unsupportedTransition
      })
    };
  }

  const artifactPath = resolveCandidateArtifactPath(workspaceRoot, mapped.normalizedCandidatePath);
  if (!artifactPath) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "unsupported-transition",
        failureScope: "transition",
        message: "The classifier-preserved candidate path is not a bounded json-file artifact.",
        routingNote: ROUTING_NOTES.unsupportedTransition
      })
    };
  }

  let artifactText;
  try {
    artifactText = await fileReader(artifactPath);
  } catch (error) {
    const message =
      error && typeof error === "object" && "code" in error && error.code === "ENOENT"
        ? "The admitted direct-json-read candidate file does not exist."
        : "The admitted direct-json-read candidate could not be loaded.";

    return {
      ok: false,
      report: buildFailure({
        failureCode: "artifact-missing",
        failureScope: "artifact",
        message,
        routingNote: ROUTING_NOTES.artifactMissing
      })
    };
  }

  let artifactPayload;
  try {
    artifactPayload = JSON.parse(artifactText);
  } catch {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "artifact-malformed",
        failureScope: "artifact",
        message: "The admitted direct-json-read candidate is not valid json.",
        routingNote: ROUTING_NOTES.artifactMalformed
      })
    };
  }

  const valueClassification = classifyArtifactValue(artifactPayload);
  return {
    ok: true,
    report: buildSuccess({
      normalizedCandidatePath: mapped.normalizedCandidatePath,
      destinationClass: mapped.destinationClass,
      executionTransitionClass: mapped.executionTransitionClass,
      artifactValueKind: valueClassification.artifactValueKind,
      artifactTopLevelKeys: valueClassification.artifactTopLevelKeys
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --candidate-path <relative-path> [--format text|json]`,
    "",
    "Invokes the authoritative ATLAS execution-transition classifier for one retained-state candidate and performs one bounded direct-json file read only when the candidate remains in the admitted blocked direct-json-read posture.",
    "No-mutation guard: this packet may admit candidate-path parsing, authoritative classifier invocation, one exact utf-8 json-file read at the same normalized path, shallow top-level value classification, and bounded success or contradiction rendering, but it may not scan directories, infer queue or registry meaning from content, emit queue drops, mutate receipts/book surfaces or owner repos, or launch or resume workers."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryLiveDirectJsonReadFollowOnCommand(argv);
  const parsed = parseArgs(argv);
  const format = parsed.ok ? parsed.args.format : "json";

  if (format === "json") {
    console.log(JSON.stringify(result, null, 2));
  } else {
    process.stdout.write(renderText(result));
  }

  return result.ok ? 0 : 1;
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  const exitCode = await main(process.argv.slice(2));
  process.exit(exitCode);
}
