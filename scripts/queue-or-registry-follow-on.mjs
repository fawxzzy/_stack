#!/usr/bin/env node

import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry follow-on";
const CLASSIFIER_REF = "ops/atlas/runtime_state_execution_ready_transition_semantics.py";

const ROUTING_NOTES = Object.freeze({
  unresolved: "route to exact-child-path resolution before shared follow-on packaging",
  directBlocked: "route to bounded live direct-json-read admission before shared follow-on progress",
  directoryBlocked: "route to bounded live directory-read admission before shared follow-on progress",
  nonAdmitted: "stop and return; candidate is outside the admitted shared follow-on posture",
  invalidInput: "fix candidate path input and rerun before packaging",
  classifierFailed: "repair authoritative classifier execution or output before shared follow-on claims"
});

const FAILURE_CODES = new Set(["invalid-input", "classifier-failed"]);
const FOLLOW_ON_STATUSES = new Set([
  "destination-root-still-unresolved",
  "blocked-pending-live-direct-json-read",
  "blocked-pending-live-directory-read",
  "non-admitted-transition"
]);

const UNRESOLVED_DECISIONS = new Set([
  "queue-home-destination-root-still-unresolved",
  "registry-home-destination-root-still-unresolved"
]);

const DIRECT_BLOCKED_DECISIONS = new Set([
  "admitted-queue-home-live-direct-json-read-blocked-before-execution",
  "admitted-registry-home-live-direct-json-read-blocked-before-execution"
]);

const DIRECTORY_BLOCKED_DECISIONS = new Set([
  "admitted-queue-home-live-directory-read-blocked-before-execution",
  "admitted-registry-home-live-directory-read-blocked-before-execution"
]);

const NON_ADMITTED_DECISIONS = new Set([
  "non-admitted-discovery-mode-execution-transition",
  "neutral-family-root-without-destination-class",
  "non-admitted-neutral-family-descendant",
  "outside-admitted-neutral-family-root"
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
  followOnStatus,
  routingNote
}) {
  if (!FOLLOW_ON_STATUSES.has(followOnStatus)) {
    throw new Error(`Unsupported follow-on status: ${followOnStatus}`);
  }

  return {
    command: COMMAND_ID,
    classifier_ref: CLASSIFIER_REF,
    normalized_candidate_path: normalizedCandidatePath,
    destination_class: destinationClass,
    execution_transition_class: executionTransitionClass,
    follow_on_status: followOnStatus,
    routing_note: routingNote
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_candidate_path=${result.report.normalized_candidate_path}`,
      `destination_class=${result.report.destination_class}`,
      `execution_transition_class=${result.report.execution_transition_class}`,
      `follow_on_status=${result.report.follow_on_status}`,
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
  if (isNonEmptyString(process.env.STACK_QUEUE_OR_REGISTRY_FOLLOW_ON_WORKSPACE_ROOT)) {
    return path.resolve(process.env.STACK_QUEUE_OR_REGISTRY_FOLLOW_ON_WORKSPACE_ROOT);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

async function defaultRunClassifier({ workspaceRoot, candidatePath }) {
  const classifierPath = path.join(workspaceRoot, CLASSIFIER_REF);
  const pythonCommand = process.env.STACK_QUEUE_OR_REGISTRY_FOLLOW_ON_PYTHON || "python";
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

  if (UNRESOLVED_DECISIONS.has(decision)) {
    return buildSuccess({
      normalizedCandidatePath,
      destinationClass,
      executionTransitionClass,
      followOnStatus: "destination-root-still-unresolved",
      routingNote: ROUTING_NOTES.unresolved
    });
  }

  if (DIRECT_BLOCKED_DECISIONS.has(decision)) {
    return buildSuccess({
      normalizedCandidatePath,
      destinationClass,
      executionTransitionClass,
      followOnStatus: "blocked-pending-live-direct-json-read",
      routingNote: ROUTING_NOTES.directBlocked
    });
  }

  if (DIRECTORY_BLOCKED_DECISIONS.has(decision)) {
    return buildSuccess({
      normalizedCandidatePath,
      destinationClass,
      executionTransitionClass,
      followOnStatus: "blocked-pending-live-directory-read",
      routingNote: ROUTING_NOTES.directoryBlocked
    });
  }

  if (NON_ADMITTED_DECISIONS.has(decision)) {
    return buildSuccess({
      normalizedCandidatePath,
      destinationClass,
      executionTransitionClass,
      followOnStatus: "non-admitted-transition",
      routingNote: ROUTING_NOTES.nonAdmitted
    });
  }

  return null;
}

export async function runQueueOrRegistryFollowOnCommand(argv, dependencies = {}) {
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
        message: "The authoritative execution-transition classifier failed before follow-on packaging was admitted.",
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
        message: "The authoritative execution-transition classifier emitted unsupported or malformed follow-on output.",
        routingNote: ROUTING_NOTES.classifierFailed
      })
    };
  }

  return {
    ok: true,
    report: mapped
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --candidate-path <relative-path> [--format text|json]`,
    "",
    "Invokes the authoritative ATLAS execution-transition classifier for one retained-state candidate and emits one bounded shared follow-on posture.",
    "No-execution guard: this packet may admit future implementation of candidate-path parsing, authoritative classifier invocation, bounded classifier-output loading, local status mapping, and receipt-ready follow-on rendering for stack queue-or-registry follow-on, but it may not perform live runtime-state reads, emit or mutate queue drops, launch or resume workers, mutate markers/receipts/book surfaces or owner repos, or imply deploy/publication/owner-readiness proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryFollowOnCommand(argv);
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
