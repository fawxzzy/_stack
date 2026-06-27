#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry merge-request-artifact-behavior";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_MERGE_REQUEST_ARTIFACT_BEHAVIOR_WORKSPACE_ROOT";
const POWERSHELL_ENV = "STACK_QUEUE_OR_REGISTRY_MERGE_REQUEST_ARTIFACT_BEHAVIOR_POWERSHELL";
const BRIDGE_SCRIPT_REF = "repos/_stack/ops/stack/Invoke-QueueOrRegistryMergeRequestArtifactBehavior.ps1";
const STACK_LOCK_REF = "stack.lock.yaml";
const STACK_LOG_DIR_PREFIX = "repos/_stack/.codex/logs/";
const SOURCE_REPORT_VERSION = "atlas.cortex.supervisor.report.v1";
const EMITTED_CONTRACT_VERSION = "atlas.worker.merge-request.v1";
const EMITTED_FILE_NAME = "worker.merge-request.json";
const RESULT_CLASS = "merge-request-artifact-emitted";
const ROUTING_NOTE =
  "explicit merge-request artifact emitted only; no paused-status, merger-assignment, or resume-ready claim is implied";
const FAILURE_CODES = new Set([
  "invalid-source-report",
  "invalid-artifact-input",
  "invalid-log-dir",
  "lineage-mismatch",
  "builder-failed",
  "malformed-artifact-output"
]);
const OVERLAP_TYPES = new Set(["line_overlap", "file_digest_drift"]);
const RANGE_OPS = new Set(["add", "modify", "delete", "rename", "scan"]);

const ROUTING_NOTES = Object.freeze({
  invalidSourceReport: "repair the explicit supervisor report before merge-request artifact emission",
  invalidArtifactInput: "repair the explicit merge-request artifact input before wider orchestration claims",
  invalidLogDir: "repair the repo-local Codex log-directory input before merge-request artifact emission",
  lineageMismatch: "repair the explicit overlap-or-drift lineage mismatch before wider orchestration claims",
  builderFailed: "repair the admitted _stack merge-request builder before wider orchestration claims",
  malformedBuilderOutput: "repair the admitted _stack merge-request output contract before wider orchestration claims"
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

function isStringArray(value, { minLength = 0 } = {}) {
  return Array.isArray(value) && value.length >= minLength && value.every((item) => isNonEmptyString(item));
}

function isPositiveInteger(value) {
  return Number.isInteger(value) && value >= 1;
}

function isNullableString(value) {
  return value === null || value === undefined || isNonEmptyString(value);
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
  normalizedSourceReportRef,
  normalizedArtifactInputRef,
  normalizedLogDirRef,
  emittedArtifactRef,
  stackLockDigest,
  payload
}) {
  return {
    command: COMMAND_ID,
    normalized_source_report_ref: normalizedSourceReportRef,
    normalized_artifact_input_ref: normalizedArtifactInputRef,
    normalized_log_dir_ref: normalizedLogDirRef,
    emitted_artifact_ref: emittedArtifactRef,
    emitted_contract_version: EMITTED_CONTRACT_VERSION,
    stack_lock_digest: stackLockDigest,
    result_class: RESULT_CLASS,
    routing_note: ROUTING_NOTE,
    payload: {
      merge_request_artifact: payload
    }
  };
}

function renderText(result) {
  if (result.ok) {
    return [
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

function validateGovernedFieldShape(payload, scopeLabel) {
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
      message: `${scopeLabel} must provide both tool_id and registry_digest when governed lineage is present.`
    };
  }

  return { ok: true };
}

function isConflictRange(value) {
  const allowedKeys = new Set([
    "worker_id",
    "start_line",
    "end_line",
    "op"
  ]);

  return (
    hasOnlyAllowedKeys(value, allowedKeys)
    && isNonEmptyString(value.worker_id)
    && isPositiveInteger(value.start_line)
    && isPositiveInteger(value.end_line)
    && value.end_line >= value.start_line
    && isNonEmptyString(value.op)
    && RANGE_OPS.has(value.op)
  );
}

function isOverlap(value) {
  const allowedKeys = new Set([
    "repo_path",
    "path",
    "overlap_type",
    "file_digest_before",
    "conflicting_ranges",
    "reason"
  ]);

  return (
    hasOnlyAllowedKeys(value, allowedKeys)
    && isNonEmptyString(value.repo_path)
    && isNonEmptyString(value.path)
    && isNonEmptyString(value.overlap_type)
    && OVERLAP_TYPES.has(value.overlap_type)
    && isNonEmptyString(value.file_digest_before)
    && Array.isArray(value.conflicting_ranges)
    && value.conflicting_ranges.length >= 2
    && value.conflicting_ranges.every((item) => isConflictRange(item))
    && isNonEmptyString(value.reason)
  );
}

function validateMergeWorkerHandoff(payload, topLevelGoverned) {
  const allowedKeys = new Set([
    "worker_id",
    "assignment_id",
    "task_id",
    "handoff_ref",
    "tool_id",
    "extension_id",
    "registry_digest"
  ]);

  if (
    !hasOnlyAllowedKeys(payload, allowedKeys)
    || !isNonEmptyString(payload.worker_id)
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.task_id)
    || !isNonEmptyString(payload.handoff_ref)
  ) {
    return {
      ok: false,
      message: "merge_worker_handoff must contain only the admitted merge-worker handoff fields."
    };
  }

  const governedShape = validateGovernedFieldShape(payload, "merge_worker_handoff");
  if (!governedShape.ok) {
    return governedShape;
  }

  if (topLevelGoverned.hasAny && (
    !isNonEmptyString(payload.tool_id)
    || !isNonEmptyString(payload.registry_digest)
    || normalizeOptionalString(payload.tool_id) !== topLevelGoverned.toolId
    || normalizeOptionalString(payload.extension_id) !== topLevelGoverned.extensionId
    || normalizeOptionalString(payload.registry_digest) !== topLevelGoverned.registryDigest
  )) {
    return {
      ok: false,
      message: "merge_worker_handoff governed lineage must match the top-level governed merge-request lineage."
    };
  }

  return { ok: true };
}

function validateSourceReport(payload) {
  if (
    !isRecord(payload)
    || payload.schema_version !== SOURCE_REPORT_VERSION
    || !isNonEmptyString(payload.stack_lock_digest)
    || !Array.isArray(payload.merge_requests)
  ) {
    return {
      ok: false,
      message: "The explicit source report is not an admitted atlas.cortex.supervisor.report.v1 report."
    };
  }

  return { ok: true, report: payload };
}

function validateArtifactInput(payload) {
  const allowedKeys = new Set([
    "merge_request_id",
    "stack_lock_digest",
    "conflicting_workers",
    "overlaps",
    "paused_handoff_refs",
    "merge_worker_handoff",
    "tool_id",
    "extension_id",
    "registry_digest",
    "notes"
  ]);

  if (
    !hasOnlyAllowedKeys(payload, allowedKeys)
    || !isNonEmptyString(payload.merge_request_id)
    || !isNonEmptyString(payload.stack_lock_digest)
    || !isStringArray(payload.conflicting_workers, { minLength: 2 })
    || !Array.isArray(payload.overlaps)
    || payload.overlaps.length < 1
    || !payload.overlaps.every((item) => isOverlap(item))
    || !isStringArray(payload.paused_handoff_refs, { minLength: 1 })
    || !isRecord(payload.merge_worker_handoff)
    || !isNullableString(payload.notes)
  ) {
    return {
      ok: false,
      message: "merge-request artifact input must contain only the admitted merge-request contract fields."
    };
  }

  const governedShape = validateGovernedFieldShape(payload, "merge-request artifact input");
  if (!governedShape.ok) {
    return governedShape;
  }

  const topLevelGoverned = {
    hasAny: normalizeOptionalString(payload.tool_id) !== null
      || normalizeOptionalString(payload.extension_id) !== null
      || normalizeOptionalString(payload.registry_digest) !== null,
    toolId: normalizeOptionalString(payload.tool_id),
    extensionId: normalizeOptionalString(payload.extension_id),
    registryDigest: normalizeOptionalString(payload.registry_digest)
  };

  return validateMergeWorkerHandoff(payload.merge_worker_handoff, topLevelGoverned);
}

function canonicalize(value) {
  if (Array.isArray(value)) {
    return value.map((item) => canonicalize(item));
  }

  if (isRecord(value)) {
    return Object.keys(value)
      .sort()
      .reduce((result, key) => {
        result[key] = canonicalize(value[key]);
        return result;
      }, {});
  }

  return value;
}

function comparableMergeRequest(payload) {
  return canonicalize({
    merge_request_id: payload.merge_request_id,
    stack_lock_digest: payload.stack_lock_digest,
    tool_id: normalizeOptionalString(payload.tool_id),
    extension_id: normalizeOptionalString(payload.extension_id),
    registry_digest: normalizeOptionalString(payload.registry_digest),
    conflicting_workers: payload.conflicting_workers,
    overlaps: payload.overlaps,
    paused_handoff_refs: payload.paused_handoff_refs,
    merge_worker_handoff: payload.merge_worker_handoff
  });
}

function valuesMatch(left, right) {
  if (left == null || right == null) {
    return true;
  }

  return String(left) === String(right);
}

function findMatchingSourceMergeRequest(sourceReport, artifactInput) {
  const expectedComparable = JSON.stringify(comparableMergeRequest(artifactInput));

  for (const candidate of sourceReport.merge_requests) {
    if (!isRecord(candidate) || candidate.contract_version !== EMITTED_CONTRACT_VERSION) {
      continue;
    }

    if (!valuesMatch(candidate.merge_request_id, artifactInput.merge_request_id)) {
      continue;
    }

    if (JSON.stringify(comparableMergeRequest(candidate)) === expectedComparable) {
      return candidate;
    }
  }

  return null;
}

function validateLineage({ sourceReport, artifactInput, stackLockDigest }) {
  if (!valuesMatch(sourceReport.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The source report stack_lock_digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(artifactInput.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The merge-request artifact input stack_lock_digest contradicts the current workspace lock digest."
    };
  }

  if (!findMatchingSourceMergeRequest(sourceReport, artifactInput)) {
    return {
      ok: false,
      message: "The explicit source report does not admit one matching merge-request candidate for the provided overlap-or-drift payload."
    };
  }

  return { ok: true };
}

async function defaultRunBridge({ workspaceRoot, artifactInputPath, logDirPath }) {
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
      message: "The admitted _stack merge-request builder failed before emission could complete."
    };
  }

  let payload;
  try {
    payload = JSON.parse(bridgeResult.stdout);
  } catch {
    return {
      ok: false,
      kind: "malformed-artifact-output",
      message: "The admitted _stack merge-request builder emitted non-json output."
    };
  }

  if (
    !isRecord(payload)
    || !isNonEmptyString(payload.emitted_artifact_ref)
    || payload.emitted_contract_version !== EMITTED_CONTRACT_VERSION
    || !isRecord(payload.payload)
  ) {
    return {
      ok: false,
      kind: "malformed-artifact-output",
      message: "The admitted _stack merge-request builder omitted the expected artifact output surface."
    };
  }

  return { ok: true, payload };
}

export async function runQueueOrRegistryMergeRequestArtifactBehaviorCommand(argv, dependencies = {}) {
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

  const { sourceReportPath, artifactInputPath, logDirPath } = parsed.args;
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

  const artifactInputValidation = validateArtifactInput(artifactInputFile.payload);
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
    sourceReport: sourceReport.report,
    artifactInput: artifactInputFile.payload,
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

  const expectedArtifactRef = `${resolvedLogDir.normalizedRef}/${EMITTED_FILE_NAME}`;
  if (parsedBridge.payload.emitted_artifact_ref !== expectedArtifactRef) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-artifact-output",
        failureScope: "builder",
        message: "The admitted _stack merge-request builder emitted an unexpected artifact ref.",
        routingNote: ROUTING_NOTES.malformedBuilderOutput
      })
    };
  }

  return {
    ok: true,
    report: buildSuccess({
      normalizedSourceReportRef: resolvedSourceReport.normalizedRef,
      normalizedArtifactInputRef: resolvedArtifactInput.normalizedRef,
      normalizedLogDirRef: resolvedLogDir.normalizedRef,
      emittedArtifactRef: parsedBridge.payload.emitted_artifact_ref,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      payload: parsedBridge.payload.payload
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --source-report <relative-json-path> --artifact-input <relative-json-path> --log-dir <relative-log-dir> [--format text|json]`,
    "",
    "Emits one explicit merge-request artifact into one admitted _stack repo-local Codex log directory only.",
    "No-pause/no-resume guard: this packet may admit future implementation of one explicit merge-request-artifact wrapper input parser, one root-relative path normalization layer for source-report or artifact-input or log-directory refs, one exact supervisor-report reconciliation step for one admitted overlap-or-drift payload only, one admitted _stack merge-request builder invocation layer only, one bounded single-artifact writer inside the target repo-local Codex log directory, one bounded wrapper report renderer, and one fail-closed invalid-source-report or lineage-mismatch or invalid-log-dir handler, but it may not inspect live queue history beyond the explicit source report, emit paused-worker status or merger-assignment or resume-context artifacts, consume merge requests into later pause or resume flows, launch or merge or pause or resume workers, mutate atlas-book or lock surfaces, mutate owner-repo surfaces outside the admitted log directory, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryMergeRequestArtifactBehaviorCommand(argv);
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
