#!/usr/bin/env node

import { readdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry live-directory-read-follow-on";
const CLASSIFIER_REF = "ops/atlas/runtime_state_execution_ready_transition_semantics.py";
const DIRECTORY_READ_STATUS = "readable-directory-candidate";

const ROUTING_NOTES = Object.freeze({
  success: "package one bounded directory-read report and continue",
  invalidInput: "fix candidate path input and rerun before live directory-read packaging",
  classifierFailed: "repair authoritative classifier execution or output before live directory-read claims",
  unsupportedTransition:
    "route to one bounded directory-read contradiction packet before queue-or-registry meaning claims",
  artifactMissing:
    "route to one bounded directory-read contradiction packet before queue-or-registry meaning claims",
  artifactNotDirectory:
    "route to one bounded directory-read contradiction packet before queue-or-registry meaning claims"
});

const FAILURE_CODES = new Set([
  "invalid-input",
  "classifier-failed",
  "unsupported-transition",
  "artifact-missing",
  "artifact-not-directory"
]);

const DIRECTORY_BLOCKED_DECISIONS = new Set([
  "admitted-queue-home-live-directory-read-blocked-before-execution",
  "admitted-registry-home-live-directory-read-blocked-before-execution"
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
  childEntryNames
}) {
  return {
    command: COMMAND_ID,
    classifier_ref: CLASSIFIER_REF,
    normalized_candidate_path: normalizedCandidatePath,
    destination_class: destinationClass,
    execution_transition_class: executionTransitionClass,
    directory_read_status: DIRECTORY_READ_STATUS,
    child_entry_count: childEntryNames.length,
    child_entry_names: childEntryNames,
    routing_note: ROUTING_NOTES.success
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_candidate_path=${result.report.normalized_candidate_path}`,
      `destination_class=${result.report.destination_class}`,
      `execution_transition_class=${result.report.execution_transition_class}`,
      `directory_read_status=${result.report.directory_read_status}`,
      `child_entry_count=${result.report.child_entry_count}`,
      `child_entry_names=${JSON.stringify(result.report.child_entry_names)}`,
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
  if (isNonEmptyString(process.env.STACK_QUEUE_OR_REGISTRY_LIVE_DIRECTORY_READ_FOLLOW_ON_WORKSPACE_ROOT)) {
    return path.resolve(process.env.STACK_QUEUE_OR_REGISTRY_LIVE_DIRECTORY_READ_FOLLOW_ON_WORKSPACE_ROOT);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

async function defaultRunClassifier({ workspaceRoot, candidatePath }) {
  const classifierPath = path.join(workspaceRoot, CLASSIFIER_REF);
  const pythonCommand =
    process.env.STACK_QUEUE_OR_REGISTRY_LIVE_DIRECTORY_READ_FOLLOW_ON_PYTHON || "python";
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
  if (!isRelativePath(normalizedCandidatePath) || !normalizedCandidatePath.endsWith("/")) {
    return null;
  }

  const resolvedPath = path.resolve(workspaceRoot, normalizedCandidatePath);
  const relative = path.relative(workspaceRoot, resolvedPath);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    return null;
  }

  return resolvedPath;
}

export async function runQueueOrRegistryLiveDirectoryReadFollowOnCommand(argv, dependencies = {}) {
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
  const directoryReader = dependencies.readDirectory || ((filePath) => readdir(filePath, { withFileTypes: true }));
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
        message: "The authoritative execution-transition classifier failed before live directory-read claims were admitted.",
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
        message: "The authoritative execution-transition classifier emitted unsupported or malformed directory-read output.",
        routingNote: ROUTING_NOTES.classifierFailed
      })
    };
  }

  if (
    mapped.executionTransitionClass !== "blocked-pending-live-directory-read"
    || !DIRECTORY_BLOCKED_DECISIONS.has(mapped.decision)
  ) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "unsupported-transition",
        failureScope: "transition",
        message: "The authoritative execution-transition classifier did not preserve the admitted blocked directory-read posture.",
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
        message: "The classifier-preserved candidate path is not a bounded directory artifact.",
        routingNote: ROUTING_NOTES.unsupportedTransition
      })
    };
  }

  let directoryEntries;
  try {
    directoryEntries = await directoryReader(artifactPath);
  } catch (error) {
    if (error && typeof error === "object" && "code" in error) {
      if (error.code === "ENOENT") {
        return {
          ok: false,
          report: buildFailure({
            failureCode: "artifact-missing",
            failureScope: "artifact",
            message: "The admitted directory-read candidate directory does not exist.",
            routingNote: ROUTING_NOTES.artifactMissing
          })
        };
      }

      if (error.code === "ENOTDIR") {
        return {
          ok: false,
          report: buildFailure({
            failureCode: "artifact-not-directory",
            failureScope: "artifact",
            message: "The admitted directory-read candidate exists but is not a directory.",
            routingNote: ROUTING_NOTES.artifactNotDirectory
          })
        };
      }
    }

    return {
      ok: false,
      report: buildFailure({
        failureCode: "artifact-missing",
        failureScope: "artifact",
        message: "The admitted directory-read candidate could not be loaded.",
        routingNote: ROUTING_NOTES.artifactMissing
      })
    };
  }

  const childEntryNames = directoryEntries
    .map((entry) => (typeof entry === "string" ? entry : entry.name))
    .sort((left, right) => left.localeCompare(right));

  return {
    ok: true,
    report: buildSuccess({
      normalizedCandidatePath: mapped.normalizedCandidatePath,
      destinationClass: mapped.destinationClass,
      executionTransitionClass: mapped.executionTransitionClass,
      childEntryNames
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --candidate-path <relative-path> [--format text|json]`,
    "",
    "Invokes the authoritative ATLAS execution-transition classifier for one retained-state candidate and performs one bounded shallow directory read only when the candidate remains in the admitted blocked directory-read posture.",
    "No-mutation guard: this packet may admit candidate-path parsing, authoritative classifier invocation, one exact shallow directory read at the same normalized path, shallow child-name reporting, and bounded success or contradiction rendering, but it may not recurse into descendants, infer queue or registry meaning from child names, emit queue drops, mutate receipts/book surfaces or owner repos, or launch or resume workers."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryLiveDirectoryReadFollowOnCommand(argv);
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
