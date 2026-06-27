#!/usr/bin/env node

import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry merger-assignment-artifact-behavior";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_MERGER_ASSIGNMENT_ARTIFACT_BEHAVIOR_WORKSPACE_ROOT";
const POWERSHELL_ENV = "STACK_QUEUE_OR_REGISTRY_MERGER_ASSIGNMENT_ARTIFACT_BEHAVIOR_POWERSHELL";
const BRIDGE_SCRIPT_REF = "repos/_stack/ops/stack/Invoke-QueueOrRegistryMergerAssignmentArtifactBehavior.ps1";
const STACK_LOCK_REF = "stack.lock.yaml";
const MERGE_REQUEST_CONTRACT_VERSION = "atlas.worker.merge-request.v1";
const RESULT_CLASS = "merger-assignment-artifacts-emitted";
const ROUTING_NOTE =
  "explicit merger worker assignment artifacts emitted only from existing paused worker status artifacts; no resume-ready claim is implied";
const FAILURE_CODES = new Set([
  "invalid-merge-request",
  "invalid-artifact-search-root",
  "lineage-mismatch",
  "builder-failed",
  "malformed-merger-output"
]);
const OVERLAP_TYPES = new Set(["line_overlap", "file_digest_drift"]);
const RANGE_OPS = new Set(["add", "modify", "delete", "rename", "scan"]);

const ROUTING_NOTES = Object.freeze({
  invalidMergeRequest: "repair the explicit merge-request artifact before merger-assignment emission",
  invalidArtifactSearchRoot: "repair the explicit artifact-search-root before merger-assignment emission",
  lineageMismatch: "repair the explicit merge-request lineage mismatch before wider orchestration claims",
  builderFailed: "repair the admitted _stack merger-assignment consumer before wider orchestration claims",
  malformedMergerOutput: "repair the admitted _stack merger-assignment output contract before wider orchestration claims"
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
  normalizedMergeRequestRef,
  normalizedArtifactSearchRootRef,
  mergeAssignmentRef,
  mergePromptRef,
  mergeContextRef,
  stackLockDigest,
  payload
}) {
  return {
    command: COMMAND_ID,
    normalized_merge_request_ref: normalizedMergeRequestRef,
    normalized_artifact_search_root_ref: normalizedArtifactSearchRootRef,
    merge_assignment_ref: mergeAssignmentRef,
    merge_prompt_ref: mergePromptRef,
    merge_context_ref: mergeContextRef,
    stack_lock_digest: stackLockDigest,
    result_class: RESULT_CLASS,
    routing_note: ROUTING_NOTE,
    payload: {
      merger_assignment_artifacts: payload
    }
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_merge_request_ref=${result.report.normalized_merge_request_ref}`,
      `normalized_artifact_search_root_ref=${result.report.normalized_artifact_search_root_ref}`,
      `merge_assignment_ref=${result.report.merge_assignment_ref}`,
      `merge_prompt_ref=${result.report.merge_prompt_ref}`,
      `merge_context_ref=${result.report.merge_context_ref}`,
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
    mergeRequestPath: undefined,
    artifactSearchRootPath: undefined
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

    if (token === "--merge-request") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--merge-request requires one bounded relative json path.");
      } else {
        parsed.mergeRequestPath = value;
      }
      index += 1;
      continue;
    }

    if (token === "--artifact-search-root") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--artifact-search-root requires one bounded relative directory path.");
      } else {
        parsed.artifactSearchRootPath = value;
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

async function resolveArtifactSearchRootPath(workspaceRoot, rawPath) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: "--artifact-search-root requires one bounded relative directory path." };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: "--artifact-search-root must be a bounded relative directory path." };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = normalizeRelativePath(path.relative(workspaceRoot, absolutePath));
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: "--artifact-search-root must stay within the workspace root." };
  }

  let stats;
  try {
    stats = await stat(absolutePath);
  } catch {
    return { ok: false, message: "--artifact-search-root must point to one existing local directory." };
  }

  if (!stats.isDirectory()) {
    return { ok: false, message: "--artifact-search-root must point to one existing local directory." };
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
  const allowedKeys = new Set(["worker_id", "start_line", "end_line", "op"]);

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

function validateMergeWorkerHandoff(payload) {
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

  return validateGovernedFieldShape(payload, "merge_worker_handoff");
}

function validateMergeRequest(payload) {
  const allowedKeys = new Set([
    "contract_version",
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
    || payload.contract_version !== MERGE_REQUEST_CONTRACT_VERSION
    || !isNonEmptyString(payload.merge_request_id)
    || !isNonEmptyString(payload.stack_lock_digest)
    || !isStringArray(payload.conflicting_workers, { minLength: 2 })
    || !Array.isArray(payload.overlaps)
    || payload.overlaps.length < 1
    || !payload.overlaps.every((item) => isOverlap(item))
    || !isStringArray(payload.paused_handoff_refs, { minLength: 1 })
    || !isRecord(payload.merge_worker_handoff)
  ) {
    return {
      ok: false,
      message: "The explicit merge-request artifact must satisfy atlas.worker.merge-request.v1."
    };
  }

  const governedShape = validateGovernedFieldShape(payload, "merge-request artifact");
  if (!governedShape.ok) {
    return governedShape;
  }

  return validateMergeWorkerHandoff(payload.merge_worker_handoff);
}

function validateLineage({ mergeRequest, stackLockDigest }) {
  if (mergeRequest.stack_lock_digest !== stackLockDigest) {
    return {
      ok: false,
      message: "The merge-request artifact stack_lock_digest contradicts the current workspace lock digest."
    };
  }

  return { ok: true };
}

async function defaultRunBridge({ workspaceRoot, mergeRequestPath, artifactSearchRoot }) {
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
        "-MergeRequestPath",
        mergeRequestPath,
        "-ArtifactSearchRoot",
        artifactSearchRoot
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
      message: "The admitted _stack merger-assignment consumer failed before emission could complete."
    };
  }

  let payload;
  try {
    payload = JSON.parse(bridgeResult.stdout);
  } catch {
    return {
      ok: false,
      kind: "malformed-merger-output",
      message: "The admitted _stack merger-assignment consumer emitted non-json output."
    };
  }

  if (
    !isRecord(payload)
    || !isNonEmptyString(payload.merge_assignment_ref)
    || !isNonEmptyString(payload.merge_prompt_ref)
    || !isNonEmptyString(payload.merge_context_ref)
    || !isRecord(payload.payload)
    || !Array.isArray(payload.payload.pause_status_refs)
    || payload.payload.pause_status_refs.length < 1
  ) {
    return {
      ok: false,
      kind: "malformed-merger-output",
      message: "The admitted _stack merger-assignment consumer omitted the expected merger-assignment output surface."
    };
  }

  return { ok: true, payload };
}

export async function runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-merge-request",
        failureScope: "merge-request",
        message: parsed.errors.join(" "),
        routingNote: ROUTING_NOTES.invalidMergeRequest
      })
    };
  }

  const { mergeRequestPath, artifactSearchRootPath } = parsed.args;
  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const readText = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));

  const resolvedMergeRequest = resolveWorkspaceJsonPath(workspaceRoot, mergeRequestPath, "--merge-request");
  if (!resolvedMergeRequest.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-merge-request",
        failureScope: "merge-request",
        message: resolvedMergeRequest.message,
        routingNote: ROUTING_NOTES.invalidMergeRequest
      })
    };
  }

  const resolvedArtifactSearchRoot = await resolveArtifactSearchRootPath(workspaceRoot, artifactSearchRootPath);
  if (!resolvedArtifactSearchRoot.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-artifact-search-root",
        failureScope: "artifact-search-root",
        message: resolvedArtifactSearchRoot.message,
        routingNote: ROUTING_NOTES.invalidArtifactSearchRoot
      })
    };
  }

  const mergeRequestFile = await loadJsonFile(resolvedMergeRequest.absolutePath, readText);
  if (!mergeRequestFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-merge-request",
        failureScope: "merge-request",
        message: mergeRequestFile.message,
        routingNote: ROUTING_NOTES.invalidMergeRequest
      })
    };
  }

  const mergeRequestValidation = validateMergeRequest(mergeRequestFile.payload);
  if (!mergeRequestValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-merge-request",
        failureScope: "merge-request",
        message: mergeRequestValidation.message,
        routingNote: ROUTING_NOTES.invalidMergeRequest
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
    mergeRequest: mergeRequestFile.payload,
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
    mergeRequestPath: resolvedMergeRequest.absolutePath,
    artifactSearchRoot: resolvedArtifactSearchRoot.absolutePath
  });
  const parsedBridge = parseBridgeOutput(bridgeResult);
  if (!parsedBridge.ok) {
    const failureCode = parsedBridge.kind === "builder-failed" ? "builder-failed" : "malformed-merger-output";
    const routingNote =
      parsedBridge.kind === "builder-failed" ? ROUTING_NOTES.builderFailed : ROUTING_NOTES.malformedMergerOutput;
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

  return {
    ok: true,
    report: buildSuccess({
      normalizedMergeRequestRef: resolvedMergeRequest.normalizedRef,
      normalizedArtifactSearchRootRef: resolvedArtifactSearchRoot.normalizedRef,
      mergeAssignmentRef: parsedBridge.payload.merge_assignment_ref,
      mergePromptRef: parsedBridge.payload.merge_prompt_ref,
      mergeContextRef: parsedBridge.payload.merge_context_ref,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      payload: parsedBridge.payload.payload
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --merge-request <relative-json-path> --artifact-search-root <relative-directory> [--format text|json]`,
    "",
    "Emits merger worker assignment artifacts for one explicit merge request only after paused statuses already exist.",
    "No-resume guard: this packet may admit future implementation of one explicit merger-assignment wrapper input parser, one root-relative path normalization layer for merge-request or artifact-search-root refs, one exact merge-request validator, one admitted _stack merger-assignment consumer invocation only, one bounded merger-assignment report renderer, and one fail-closed invalid-merge-request or lineage-mismatch or invalid-artifact-search-root handler, but it may not emit resume-context artifacts, consume merger outputs into merge completion, inspect broader queue history, mutate atlas-book or lock surfaces, mutate owner-repo surfaces outside the admitted assignment/prompt/context homes, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryMergerAssignmentArtifactBehaviorCommand(argv);
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
