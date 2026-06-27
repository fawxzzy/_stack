#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry worker-artifact-emission";
const SOURCE_COMMAND_ID = "stack queue-or-registry broader-execution-behavior";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_WORKER_ARTIFACT_EMISSION_WORKSPACE_ROOT";
const POWERSHELL_ENV = "STACK_QUEUE_OR_REGISTRY_WORKER_ARTIFACT_EMISSION_POWERSHELL";
const BRIDGE_SCRIPT_REF = "repos/_stack/ops/stack/Invoke-QueueOrRegistryWorkerArtifactEmission.ps1";
const STACK_LOCK_REF = "stack.lock.yaml";
const STACK_LOG_DIR_PREFIX = "repos/_stack/.codex/logs/";

const INTENT_CONFIG = Object.freeze({
  assignment: {
    emittedFileName: "worker.assignment.json",
    emittedContractVersion: "atlas.worker.assignment.v1",
    resultClass: "assignment-artifact-emitted",
    routingNote: "explicit assignment artifact emitted only; no worker dispatch is implied",
    payloadKey: "assignment_artifact"
  },
  "status-running": {
    emittedFileName: "worker.status.running.json",
    emittedContractVersion: "atlas.worker.status.v1",
    expectedState: "running",
    resultClass: "running-status-artifact-emitted",
    routingNote: "explicit running status artifact emitted only; no execution bridge claim is implied",
    payloadKey: "running_status_artifact"
  },
  "status-completed": {
    emittedFileName: "worker.status.completed.json",
    emittedContractVersion: "atlas.worker.status.v1",
    expectedState: "completed",
    resultClass: "completed-status-artifact-emitted",
    routingNote:
      "explicit completed status artifact emitted only; no execution-completed, merge-closed, or resume-completed claim is implied",
    payloadKey: "completed_status_artifact"
  }
});

const ADMITTED_INTENTS = new Set(Object.keys(INTENT_CONFIG));
const ADMITTED_SOURCE_RESULT_CLASSES = new Set([
  "draft-scaffold-rendered",
  "candidate-entry-valid",
  "candidate-entry-invalid",
  "status-summary-rendered"
]);
const FAILURE_CODES = new Set([
  "invalid-source-report",
  "invalid-artifact-input",
  "unsupported-intent",
  "invalid-log-dir",
  "lineage-mismatch",
  "builder-failed",
  "malformed-artifact-output"
]);
const TOUCHED_RANGE_OPS = new Set(["add", "modify", "delete", "rename", "scan"]);

const ROUTING_NOTES = Object.freeze({
  invalidSourceReport: "repair the explicit source report before worker-artifact emission",
  invalidArtifactInput: "repair the explicit artifact input before worker-artifact emission",
  unsupportedIntent: "use one admitted intent only: assignment, status-running, or status-completed",
  invalidLogDir: "repair the repo-local Codex log-directory input before worker-artifact emission",
  lineageMismatch: "repair the explicit lineage mismatch before wider orchestration claims",
  builderFailed: "repair the admitted _stack worker-artifact builder before wider orchestration claims",
  malformedBuilderOutput: "repair the admitted _stack worker-artifact output contract before wider orchestration claims"
});

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function normalizeRelativePath(value) {
  return value.trim().replaceAll("\\", "/");
}

function normalizeOptionalString(value) {
  return typeof value === "string" ? value : value == null ? null : String(value);
}

function hasOnlyAllowedKeys(value, allowedKeys) {
  if (!isRecord(value)) {
    return false;
  }

  return Object.keys(value).every((key) => allowedKeys.has(key));
}

function isStringArray(value) {
  return Array.isArray(value) && value.every((item) => isNonEmptyString(item));
}

function isNullableString(value) {
  return value === null || value === undefined || isNonEmptyString(value);
}

function isPositiveInteger(value) {
  return Number.isInteger(value) && value >= 1;
}

function isTouchedRange(value) {
  return (
    isRecord(value)
    && isNonEmptyString(value.repo_path)
    && isNonEmptyString(value.repo_commit)
    && isNonEmptyString(value.file_digest_before)
    && isNonEmptyString(value.path)
    && isPositiveInteger(value.start_line)
    && isPositiveInteger(value.end_line)
    && value.end_line >= value.start_line
    && isNonEmptyString(value.op)
    && TOUCHED_RANGE_OPS.has(value.op)
  );
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
  intent,
  normalizedSourceReportRef,
  normalizedArtifactInputRef,
  normalizedLogDirRef,
  emittedArtifactRef,
  emittedContractVersion,
  stackLockDigest,
  resultClass,
  routingNote,
  payload
}) {
  return {
    command: COMMAND_ID,
    intent,
    normalized_source_report_ref: normalizedSourceReportRef,
    normalized_artifact_input_ref: normalizedArtifactInputRef,
    normalized_log_dir_ref: normalizedLogDirRef,
    emitted_artifact_ref: emittedArtifactRef,
    emitted_contract_version: emittedContractVersion,
    stack_lock_digest: stackLockDigest,
    result_class: resultClass,
    routing_note: routingNote,
    payload
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `intent=${result.report.intent}`,
      `normalized_source_report_ref=${result.report.normalized_source_report_ref}`,
      `normalized_artifact_input_ref=${result.report.normalized_artifact_input_ref}`,
      `normalized_log_dir_ref=${result.report.normalized_log_dir_ref}`,
      `emitted_artifact_ref=${result.report.emitted_artifact_ref}`,
      `emitted_contract_version=${result.report.emitted_contract_version}`,
      `stack_lock_digest=${result.report.stack_lock_digest}`,
      `result_class=${result.report.result_class}`,
      `routing_note=${result.report.routing_note}`,
      `payload=${JSON.stringify(result.report.payload)}`
    ].join("\n") + "\n";
  }

  return [
    `failure_code=${result.report.failure_code}`,
    `failure_scope=${result.report.failure_scope}`,
    `message=${result.report.message}`,
    `routing_note=${result.report.routing_note}`
  ].join("\n") + "\n";
}

function parseArgs(argv) {
  const args = [...argv];
  const parsed = {
    format: "text",
    intent: undefined,
    sourceReportPath: undefined,
    artifactInputPath: undefined,
    logDirPath: undefined
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

    if (token === "--intent") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--intent requires one admitted intent.");
      } else {
        parsed.intent = value;
      }
      index += 1;
      continue;
    }

    if (token === "--source-report") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--source-report requires one bounded relative json path.");
      } else {
        parsed.sourceReportPath = value;
      }
      index += 1;
      continue;
    }

    if (token === "--artifact-input") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--artifact-input requires one bounded relative json path.");
      } else {
        parsed.artifactInputPath = value;
      }
      index += 1;
      continue;
    }

    if (token === "--log-dir") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--log-dir requires one bounded relative repo-local Codex log directory.");
      } else {
        parsed.logDirPath = value;
      }
      index += 1;
      continue;
    }

    errors.push(`Unsupported argument: ${token}`);
  }

  return {
    ok: errors.length === 0,
    errors,
    args: parsed
  };
}

function getWorkspaceRoot() {
  if (isNonEmptyString(process.env[WORKSPACE_ROOT_ENV])) {
    return path.resolve(process.env[WORKSPACE_ROOT_ENV]);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(scriptDir, "..", "..", "..");
}

function resolveWorkspaceJsonPath(workspaceRoot, rawPath, label) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: `${label} requires one bounded relative json path.` };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: `${label} must be a bounded relative json path.` };
  }

  if (!normalizedRef.endsWith(".json")) {
    return { ok: false, message: `${label} must point to one explicit local json file.` };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = path.relative(workspaceRoot, absolutePath);
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: `${label} must stay within the workspace root.` };
  }

  return {
    ok: true,
    normalizedRef: normalizeRelativePath(relativeFromRoot),
    absolutePath
  };
}

function resolveLogDirPath(workspaceRoot, rawPath) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: "--log-dir requires one bounded relative repo-local Codex log directory." };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: "--log-dir must be a bounded relative repo-local Codex log directory." };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = normalizeRelativePath(path.relative(workspaceRoot, absolutePath));
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: "--log-dir must stay within the workspace root." };
  }

  if (!relativeFromRoot.startsWith(STACK_LOG_DIR_PREFIX)) {
    return {
      ok: false,
      message: "--log-dir must stay within repos/_stack/.codex/logs/."
    };
  }

  return {
    ok: true,
    normalizedRef: relativeFromRoot,
    absolutePath
  };
}

async function loadJsonFile(filePath, readText) {
  let inputText;
  try {
    inputText = await readText(filePath);
  } catch (error) {
    const message =
      error && typeof error === "object" && "code" in error && error.code === "ENOENT"
        ? "The explicit local json file does not exist."
        : "The explicit local json file could not be loaded.";
    return { ok: false, message };
  }

  try {
    return {
      ok: true,
      payload: JSON.parse(inputText)
    };
  } catch {
    return { ok: false, message: "The explicit local json file is not valid json." };
  }
}

async function loadStackLockDigest(workspaceRoot, readText) {
  const stackLockPath = path.join(workspaceRoot, STACK_LOCK_REF);
  let stackLockText;
  try {
    stackLockText = await readText(stackLockPath);
  } catch {
    return { ok: false, message: "stack.lock.yaml could not be loaded from the workspace root." };
  }

  const match = stackLockText.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  if (!match || !isNonEmptyString(match[1])) {
    return { ok: false, message: "stack.lock.yaml does not declare a usable lock_digest." };
  }

  return { ok: true, stackLockDigest: match[1].trim() };
}

function normalizeSourceReportEnvelope(payload) {
  if (isRecord(payload) && payload.ok === true && isRecord(payload.report)) {
    return payload.report;
  }

  if (isRecord(payload)) {
    return payload;
  }

  return null;
}

function validateSourceReport(payload) {
  const report = normalizeSourceReportEnvelope(payload);
  if (
    !isRecord(report)
    || report.command !== SOURCE_COMMAND_ID
    || !isNonEmptyString(report.result_class)
    || !ADMITTED_SOURCE_RESULT_CLASSES.has(report.result_class)
  ) {
    return {
      ok: false,
      message: "The explicit source report is not an admitted queue-or-registry wrapper report."
    };
  }

  return { ok: true, report };
}

function validateGovernedFieldShape(payload) {
  const toolId = normalizeOptionalString(payload.tool_id);
  const extensionId = normalizeOptionalString(payload.extension_id);
  const registryDigest = normalizeOptionalString(payload.registry_digest);
  const hasAnyGovernedField = toolId !== null || extensionId !== null || registryDigest !== null;

  if (!hasAnyGovernedField) {
    return { ok: true };
  }

  if (!isNonEmptyString(toolId) || !isNonEmptyString(registryDigest)) {
    return {
      ok: false,
      message: "Governed artifact input must provide both tool_id and registry_digest when governed lineage is present."
    };
  }

  return { ok: true };
}

function validateAssignmentInput(payload) {
  const allowedKeys = new Set([
    "assignment_id",
    "worker_id",
    "task_id",
    "stack_lock_digest",
    "allowed_globs",
    "forbidden_globs",
    "input_handoff_refs",
    "expected_outputs",
    "tool_id",
    "extension_id",
    "registry_digest",
    "notes"
  ]);

  if (
    !hasOnlyAllowedKeys(payload, allowedKeys)
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.worker_id)
    || !isNonEmptyString(payload.task_id)
    || !isNonEmptyString(payload.stack_lock_digest)
    || !isStringArray(payload.allowed_globs)
    || !isStringArray(payload.forbidden_globs)
    || !isStringArray(payload.input_handoff_refs)
    || !isStringArray(payload.expected_outputs)
    || !isNullableString(payload.notes)
  ) {
    return {
      ok: false,
      message: "assignment artifact input must contain only the admitted assignment contract fields."
    };
  }

  return validateGovernedFieldShape(payload);
}

function validateStatusInput(payload, expectedState) {
  const allowedKeys = new Set([
    "worker_id",
    "assignment_id",
    "state",
    "heartbeat_at",
    "touched_ranges",
    "output_refs",
    "blocked_reason",
    "merge_request_ref",
    "stack_lock_digest",
    "tool_id",
    "extension_id",
    "registry_digest"
  ]);

  if (
    !hasOnlyAllowedKeys(payload, allowedKeys)
    || !isNonEmptyString(payload.worker_id)
    || !isNonEmptyString(payload.assignment_id)
    || payload.state !== expectedState
    || !isNonEmptyString(payload.heartbeat_at)
    || !Array.isArray(payload.touched_ranges)
    || !payload.touched_ranges.every((item) => isTouchedRange(item))
    || !Array.isArray(payload.output_refs)
    || !payload.output_refs.every((item) => isNonEmptyString(item))
    || !isNullableString(payload.blocked_reason)
    || !isNullableString(payload.merge_request_ref)
    || !(payload.stack_lock_digest === undefined || payload.stack_lock_digest === null || isNonEmptyString(payload.stack_lock_digest))
  ) {
    return {
      ok: false,
      message: `${expectedState} status artifact input must contain only the admitted status contract fields.`
    };
  }

  return validateGovernedFieldShape(payload);
}

function validateArtifactInput(intent, payload) {
  if (!isRecord(payload)) {
    return { ok: false, message: "The explicit artifact input must be one json object." };
  }

  if (intent === "assignment") {
    return validateAssignmentInput(payload);
  }

  const config = INTENT_CONFIG[intent];
  return validateStatusInput(payload, config.expectedState);
}

function valuesMatch(left, right) {
  if (left == null || right == null) {
    return true;
  }

  return String(left) === String(right);
}

function validateLineage({ intent, artifactInput, sourceReport, stackLockDigest }) {
  if (!valuesMatch(sourceReport.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The source report stack_lock_digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(artifactInput.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The artifact input stack_lock_digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(sourceReport.stack_lock_digest, artifactInput.stack_lock_digest)) {
    return {
      ok: false,
      message: "The source report and artifact input do not agree on stack_lock_digest."
    };
  }

  for (const field of ["tool_id", "extension_id", "registry_digest"]) {
    if (!valuesMatch(sourceReport[field], artifactInput[field])) {
      return {
        ok: false,
        message: `The source report and artifact input do not agree on ${field}.`
      };
    }
  }

  if (intent !== "assignment" && artifactInput.stack_lock_digest == null) {
    return { ok: true };
  }

  return { ok: true };
}

async function defaultRunBridge({ workspaceRoot, intent, artifactInputPath, logDirPath }) {
  const powershellCommand = process.env[POWERSHELL_ENV] || "powershell.exe";
  const bridgePath = path.join(workspaceRoot, BRIDGE_SCRIPT_REF);

  return new Promise((resolve) => {
    const child = spawn(
      powershellCommand,
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        bridgePath,
        "-WorkspaceRoot",
        workspaceRoot,
        "-Intent",
        intent,
        "-ArtifactInputPath",
        artifactInputPath,
        "-LogDirPath",
        logDirPath
      ],
      {
        cwd: path.join(workspaceRoot, "repos", "_stack"),
        stdio: ["ignore", "pipe", "pipe"]
      }
    );

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
      resolve({
        ok: exitCode === 0,
        exitCode: exitCode ?? 1,
        stdout,
        stderr
      });
    });
  });
}

function parseBridgeOutput(bridgeResult) {
  if (!bridgeResult.ok) {
    return {
      ok: false,
      kind: "builder-failed",
      message: "The admitted _stack worker-artifact builder failed before emission could complete."
    };
  }

  let payload;
  try {
    payload = JSON.parse(bridgeResult.stdout);
  } catch {
    return {
      ok: false,
      kind: "malformed-artifact-output",
      message: "The admitted _stack worker-artifact builder emitted non-json output."
    };
  }

  if (
    !isRecord(payload)
    || !isNonEmptyString(payload.emitted_artifact_ref)
    || !isNonEmptyString(payload.emitted_contract_version)
    || !isRecord(payload.payload)
  ) {
    return {
      ok: false,
      kind: "malformed-artifact-output",
      message: "The admitted _stack worker-artifact builder omitted the expected artifact output surface."
    };
  }

  return { ok: true, payload };
}

export async function runQueueOrRegistryWorkerArtifactEmissionCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-artifact-input",
        failureScope: "artifact-input",
        message: parsed.errors.join(" "),
        routingNote: ROUTING_NOTES.invalidArtifactInput
      })
    };
  }

  const { intent, sourceReportPath, artifactInputPath, logDirPath } = parsed.args;
  if (!ADMITTED_INTENTS.has(intent)) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "unsupported-intent",
        failureScope: "intent",
        message: "Use one admitted intent only: assignment, status-running, or status-completed.",
        routingNote: ROUTING_NOTES.unsupportedIntent
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const readText = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));

  const resolvedSourceReport = resolveWorkspaceJsonPath(workspaceRoot, sourceReportPath, "--source-report");
  if (!resolvedSourceReport.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-source-report",
        failureScope: "source-report",
        message: resolvedSourceReport.message,
        routingNote: ROUTING_NOTES.invalidSourceReport
      })
    };
  }

  const resolvedArtifactInput = resolveWorkspaceJsonPath(workspaceRoot, artifactInputPath, "--artifact-input");
  if (!resolvedArtifactInput.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-artifact-input",
        failureScope: "artifact-input",
        message: resolvedArtifactInput.message,
        routingNote: ROUTING_NOTES.invalidArtifactInput
      })
    };
  }

  const resolvedLogDir = resolveLogDirPath(workspaceRoot, logDirPath);
  if (!resolvedLogDir.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-log-dir",
        failureScope: "log-dir",
        message: resolvedLogDir.message,
        routingNote: ROUTING_NOTES.invalidLogDir
      })
    };
  }

  const sourceReportFile = await loadJsonFile(resolvedSourceReport.absolutePath, readText);
  if (!sourceReportFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-source-report",
        failureScope: "source-report",
        message: sourceReportFile.message,
        routingNote: ROUTING_NOTES.invalidSourceReport
      })
    };
  }

  const sourceReport = validateSourceReport(sourceReportFile.payload);
  if (!sourceReport.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-source-report",
        failureScope: "source-report",
        message: sourceReport.message,
        routingNote: ROUTING_NOTES.invalidSourceReport
      })
    };
  }

  const artifactInputFile = await loadJsonFile(resolvedArtifactInput.absolutePath, readText);
  if (!artifactInputFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-artifact-input",
        failureScope: "artifact-input",
        message: artifactInputFile.message,
        routingNote: ROUTING_NOTES.invalidArtifactInput
      })
    };
  }

  const artifactInputValidation = validateArtifactInput(intent, artifactInputFile.payload);
  if (!artifactInputValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-artifact-input",
        failureScope: "artifact-input",
        message: artifactInputValidation.message,
        routingNote: ROUTING_NOTES.invalidArtifactInput
      })
    };
  }

  const stackLockDigestResult = await loadStackLockDigest(workspaceRoot, readText);
  if (!stackLockDigestResult.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "lineage-mismatch",
        failureScope: "lineage",
        message: stackLockDigestResult.message,
        routingNote: ROUTING_NOTES.lineageMismatch
      })
    };
  }

  const lineageValidation = validateLineage({
    intent,
    artifactInput: artifactInputFile.payload,
    sourceReport: sourceReport.report,
    stackLockDigest: stackLockDigestResult.stackLockDigest
  });
  if (!lineageValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "lineage-mismatch",
        failureScope: "lineage",
        message: lineageValidation.message,
        routingNote: ROUTING_NOTES.lineageMismatch
      })
    };
  }

  const runBridge = dependencies.runBridge || defaultRunBridge;
  const bridgeResult = await runBridge({
    workspaceRoot,
    intent,
    artifactInputPath: resolvedArtifactInput.absolutePath,
    logDirPath: resolvedLogDir.absolutePath
  });
  const parsedBridge = parseBridgeOutput(bridgeResult);
  if (!parsedBridge.ok) {
    const failureCode = parsedBridge.kind === "builder-failed" ? "builder-failed" : "malformed-artifact-output";
    const routingNote =
      parsedBridge.kind === "builder-failed" ? ROUTING_NOTES.builderFailed : ROUTING_NOTES.malformedBuilderOutput;
    return {
      ok: false,
      report: buildFailure({
        failureCode,
        failureScope: "builder",
        message: parsedBridge.message,
        routingNote
      })
    };
  }

  const config = INTENT_CONFIG[intent];
  if (parsedBridge.payload.emitted_contract_version !== config.emittedContractVersion) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-artifact-output",
        failureScope: "builder",
        message: "The admitted _stack worker-artifact builder emitted the wrong contract version.",
        routingNote: ROUTING_NOTES.malformedBuilderOutput
      })
    };
  }

  const expectedArtifactRef = `${resolvedLogDir.normalizedRef}/${config.emittedFileName}`;
  if (parsedBridge.payload.emitted_artifact_ref !== expectedArtifactRef) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-artifact-output",
        failureScope: "builder",
        message: "The admitted _stack worker-artifact builder emitted an unexpected artifact ref.",
        routingNote: ROUTING_NOTES.malformedBuilderOutput
      })
    };
  }

  return {
    ok: true,
    report: buildSuccess({
      intent,
      normalizedSourceReportRef: resolvedSourceReport.normalizedRef,
      normalizedArtifactInputRef: resolvedArtifactInput.normalizedRef,
      normalizedLogDirRef: resolvedLogDir.normalizedRef,
      emittedArtifactRef: parsedBridge.payload.emitted_artifact_ref,
      emittedContractVersion: parsedBridge.payload.emitted_contract_version,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      resultClass: config.resultClass,
      routingNote: config.routingNote,
      payload: {
        [config.payloadKey]: parsedBridge.payload.payload
      }
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --intent <assignment|status-running|status-completed> --source-report <relative-json-path> --artifact-input <relative-json-path> --log-dir <relative-log-dir> [--format text|json]`,
    "",
    "Emits one explicit-input worker artifact into one admitted _stack repo-local Codex log directory only.",
    "No-execution guard: this packet may admit future implementation of one explicit worker-artifact-emission wrapper input parser, one root-relative path normalization layer for source-report or artifact-input or log-directory refs, one exact intent dispatcher for assignment or status-running or status-completed, one admitted _stack worker-artifact builder invocation layer only, one bounded single-artifact writer inside the target repo-local Codex log directory, one bounded wrapper report renderer, and one fail-closed unsupported-intent or lineage-mismatch or invalid-log-dir handler, but it may not inspect live queue or registry state, emit queue drops, invoke Lifeline execution or supervisor merge flows, emit execution-bridge or merge-request or pause or merger-assignment or resume-context artifacts, launch or dispatch or merge or pause or resume workers, mutate atlas-book or lock surfaces, mutate owner-repo surfaces outside the admitted log directory, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryWorkerArtifactEmissionCommand(argv);
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
