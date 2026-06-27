#!/usr/bin/env node

import { access, mkdir, readFile, rename } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry done-state-closure";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_DONE_STATE_CLOSURE_WORKSPACE_ROOT";
const STACK_LOCK_REF = "stack.lock.yaml";
const CLAIMED_QUEUE_PREFIX = "repos/_stack/queue/claimed";
const DONE_QUEUE_ROOT_PREFIX = "repos/_stack/queue/done";
const SUCCESS_RESULT_CLASS = "done-closed";
const SUCCESS_ROUTING_NOTE =
  "explicit claimed drop moved to done only for one completed worker; no merge-closure, resume-closure, or publication proof is implied";
const FAILURE_ROUTING_NOTE =
  "repair explicit done-state lineage, completed-worker agreement, or done-home routing before wider orchestration claims";
const FAILURE_CODES = new Set([
  "invalid-claimed-queue-drop",
  "invalid-worker-assignment",
  "invalid-worker-completed-status",
  "invalid-done-queue-root",
  "lineage-mismatch",
  "completed-worker-mismatch",
  "done-close-failed",
  "malformed-done-output"
]);

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function isStringArray(value) {
  return Array.isArray(value) && value.every((item) => isNonEmptyString(item));
}

function normalizeRelativePath(value) {
  return value.trim().replaceAll("\\", "/");
}

function normalizeOptionalString(value) {
  return typeof value === "string" ? value : value == null ? null : String(value);
}

function valuesMatch(left, right) {
  if (left == null || right == null) {
    return true;
  }

  return String(left) === String(right);
}

function buildFailure({ failureCode, failureScope, message }) {
  if (!FAILURE_CODES.has(failureCode)) {
    throw new Error(`Unsupported failure code: ${failureCode}`);
  }

  return {
    command: COMMAND_ID,
    failure_code: failureCode,
    failure_scope: failureScope,
    message,
    routing_note: FAILURE_ROUTING_NOTE
  };
}

function buildSuccess({
  normalizedClaimedQueueDropRef,
  normalizedWorkerAssignmentRef,
  normalizedWorkerCompletedStatusRef,
  normalizedDoneQueueRootRef,
  doneQueueDropRef,
  stackLockDigest,
  doneStateClosureArtifact
}) {
  return {
    command: COMMAND_ID,
    normalized_claimed_queue_drop_ref: normalizedClaimedQueueDropRef,
    normalized_worker_assignment_ref: normalizedWorkerAssignmentRef,
    normalized_worker_completed_status_ref: normalizedWorkerCompletedStatusRef,
    normalized_done_queue_root_ref: normalizedDoneQueueRootRef,
    done_queue_drop_ref: doneQueueDropRef,
    stack_lock_digest: stackLockDigest,
    result_class: SUCCESS_RESULT_CLASS,
    routing_note: SUCCESS_ROUTING_NOTE,
    payload: {
      done_state_closure_artifact: doneStateClosureArtifact
    }
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_claimed_queue_drop_ref=${result.report.normalized_claimed_queue_drop_ref}`,
      `normalized_worker_assignment_ref=${result.report.normalized_worker_assignment_ref}`,
      `normalized_worker_completed_status_ref=${result.report.normalized_worker_completed_status_ref}`,
      `normalized_done_queue_root_ref=${result.report.normalized_done_queue_root_ref}`,
      `done_queue_drop_ref=${result.report.done_queue_drop_ref}`,
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
    claimedQueueDropPath: undefined,
    workerAssignmentPath: undefined,
    workerCompletedStatusPath: undefined,
    doneQueueRootPath: undefined
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

    if (token === "--claimed-queue-drop") {
      parsed.claimedQueueDropPath = args[index + 1];
      if (!parsed.claimedQueueDropPath) {
        errors.push("--claimed-queue-drop requires one bounded relative markdown path.");
      }
      index += 1;
      continue;
    }

    if (token === "--worker-assignment") {
      parsed.workerAssignmentPath = args[index + 1];
      if (!parsed.workerAssignmentPath) {
        errors.push("--worker-assignment requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--worker-completed-status") {
      parsed.workerCompletedStatusPath = args[index + 1];
      if (!parsed.workerCompletedStatusPath) {
        errors.push("--worker-completed-status requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--done-queue-root") {
      parsed.doneQueueRootPath = args[index + 1];
      if (!parsed.doneQueueRootPath) {
        errors.push("--done-queue-root requires one bounded relative done queue root.");
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

function resolveWorkspaceFilePath(workspaceRoot, rawPath, label, extension) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: `${label} requires one bounded relative ${extension} path.` };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: `${label} must be a bounded relative ${extension} path.` };
  }

  if (!normalizedRef.endsWith(`.${extension}`)) {
    return { ok: false, message: `${label} must point to one explicit local ${extension} file.` };
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

function resolveClaimedQueueDropPath(workspaceRoot, rawPath) {
  const resolved = resolveWorkspaceFilePath(workspaceRoot, rawPath, "--claimed-queue-drop", "md");
  if (!resolved.ok) {
    return resolved;
  }

  if (
    !resolved.normalizedRef.startsWith(`${CLAIMED_QUEUE_PREFIX}/`)
    && resolved.normalizedRef !== `${CLAIMED_QUEUE_PREFIX}.md`
  ) {
    return {
      ok: false,
      message: "--claimed-queue-drop must stay within repos/_stack/queue/claimed/."
    };
  }

  return resolved;
}

function resolveDoneQueueRootPath(workspaceRoot, rawPath) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: "--done-queue-root requires one bounded relative done queue root." };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: "--done-queue-root must be a bounded relative done queue root." };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = normalizeRelativePath(path.relative(workspaceRoot, absolutePath));
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: "--done-queue-root must stay within the workspace root." };
  }

  if (
    relativeFromRoot !== DONE_QUEUE_ROOT_PREFIX
    && !relativeFromRoot.startsWith(`${DONE_QUEUE_ROOT_PREFIX}/`)
  ) {
    return {
      ok: false,
      message: "--done-queue-root must stay within repos/_stack/queue/done/."
    };
  }

  return {
    ok: true,
    normalizedRef: relativeFromRoot,
    absolutePath
  };
}

async function loadTextFile(filePath, readText) {
  try {
    return {
      ok: true,
      text: await readText(filePath)
    };
  } catch (error) {
    const message =
      error && typeof error === "object" && "code" in error && error.code === "ENOENT"
        ? "The explicit local file does not exist."
        : "The explicit local file could not be loaded.";
    return { ok: false, message };
  }
}

async function loadJsonFile(filePath, readText) {
  const textResult = await loadTextFile(filePath, readText);
  if (!textResult.ok) {
    return textResult;
  }

  try {
    return {
      ok: true,
      payload: JSON.parse(textResult.text)
    };
  } catch {
    return { ok: false, message: "The explicit local json file is not valid json." };
  }
}

async function loadStackLockDigest(workspaceRoot, readText) {
  const stackLockPath = path.join(workspaceRoot, STACK_LOCK_REF);
  const stackLockText = await loadTextFile(stackLockPath, readText);
  if (!stackLockText.ok) {
    return { ok: false, message: "stack.lock.yaml could not be loaded from the workspace root." };
  }

  const match = stackLockText.text.match(/^\s*lock_digest:\s*"?([^"\r\n]+)"?\s*$/m);
  if (!match || !isNonEmptyString(match[1])) {
    return { ok: false, message: "stack.lock.yaml does not declare a usable lock_digest." };
  }

  return { ok: true, stackLockDigest: match[1].trim() };
}

function parseMetadataHeaders(markdownText) {
  const metadata = {};
  const lines = String(markdownText).split(/\r?\n/);

  for (const line of lines) {
    if (!line.trim()) {
      break;
    }

    const match = line.match(/^(?<key>[A-Za-z][A-Za-z0-9 -]*):\s*(?<value>.*)$/);
    if (!match) {
      break;
    }

    const normalizedKey = match.groups.key.replace(/[^A-Za-z0-9]/g, "").toLowerCase();
    metadata[normalizedKey] = match.groups.value.trim();
  }

  return metadata;
}

function validateClaimedQueueDrop(markdownText) {
  if (!isNonEmptyString(markdownText)) {
    return {
      ok: false,
      message: "The explicit claimed queue drop must be a non-empty Markdown prompt."
    };
  }

  const metadata = parseMetadataHeaders(markdownText);
  const stackLockDigest = metadata.stacklockdigest ?? metadata.stacklock ?? null;
  if (!isNonEmptyString(stackLockDigest)) {
    return {
      ok: false,
      message: "The explicit claimed queue drop must declare one current stack lock digest."
    };
  }

  return {
    ok: true,
    metadata: {
      stackLockDigest: stackLockDigest.trim(),
      toolId: normalizeOptionalString(metadata.toolid),
      extensionId: normalizeOptionalString(metadata.extensionid),
      registryDigest: normalizeOptionalString(metadata.registrydigest)
    }
  };
}

function validateWorkerAssignment(payload) {
  if (
    !isRecord(payload)
    || payload.contract_version !== "atlas.worker.assignment.v1"
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.worker_id)
    || !isNonEmptyString(payload.stack_lock_digest)
  ) {
    return {
      ok: false,
      message: "The explicit worker assignment must satisfy atlas.worker.assignment.v1."
    };
  }

  return { ok: true };
}

function validateWorkerCompletedStatus(payload) {
  if (
    !isRecord(payload)
    || payload.contract_version !== "atlas.worker.status.v1"
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.worker_id)
    || payload.state !== "completed"
    || !isNonEmptyString(payload.heartbeat_at)
    || !Array.isArray(payload.touched_ranges)
    || !Array.isArray(payload.output_refs)
  ) {
    return {
      ok: false,
      message: "The explicit worker completed-status must satisfy the admitted atlas.worker.status.v1 completed contract."
    };
  }

  return { ok: true };
}

function validateDoneLineage({
  claimedQueueMetadata,
  workerAssignment,
  workerCompletedStatus,
  stackLockDigest
}) {
  if (!valuesMatch(claimedQueueMetadata.stackLockDigest, stackLockDigest)) {
    return {
      ok: false,
      message: "The claimed queue drop stack lock digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(workerAssignment.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The explicit worker assignment stack lock digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(workerCompletedStatus.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The explicit worker completed-status stack lock digest contradicts the current workspace lock digest."
    };
  }

  for (const field of ["tool_id", "extension_id", "registry_digest"]) {
    if (!valuesMatch(workerAssignment[field], workerCompletedStatus[field])) {
      return {
        ok: false,
        message: `The explicit completed-worker artifacts do not agree on ${field}.`
      };
    }

    const claimedValue =
      field === "tool_id"
        ? claimedQueueMetadata.toolId
        : field === "extension_id"
          ? claimedQueueMetadata.extensionId
          : claimedQueueMetadata.registryDigest;

    if (!valuesMatch(claimedValue, workerAssignment[field])) {
      return {
        ok: false,
        message: `The claimed queue drop and explicit completed-worker artifacts do not agree on ${field}.`
      };
    }
  }

  return { ok: true };
}

function validateCompletedWorker({ workerAssignment, workerCompletedStatus }) {
  if (!valuesMatch(workerAssignment.worker_id, workerCompletedStatus.worker_id)) {
    return {
      ok: false,
      message: "The explicit worker assignment and completed-status do not agree on worker_id."
    };
  }

  if (!valuesMatch(workerAssignment.assignment_id, workerCompletedStatus.assignment_id)) {
    return {
      ok: false,
      message: "The explicit worker assignment and completed-status do not agree on assignment_id."
    };
  }

  return { ok: true };
}

async function defaultCloseDone({
  workspaceRoot,
  normalizedClaimedQueueDropRef,
  claimedQueueDropPath,
  normalizedWorkerAssignmentRef,
  normalizedWorkerCompletedStatusRef,
  normalizedDoneQueueRootRef,
  doneQueueRootPath,
  claimedQueueDropFileName,
  workerAssignment
}) {
  const doneQueueDropPath = path.join(doneQueueRootPath, claimedQueueDropFileName);

  try {
    await mkdir(doneQueueRootPath, { recursive: true });
    try {
      await access(doneQueueDropPath);
      return {
        ok: false,
        message: "The bounded done queue target is already occupied."
      };
    } catch (error) {
      if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) {
        return {
          ok: false,
          message: "The bounded done queue target could not be inspected."
        };
      }
    }

    await rename(claimedQueueDropPath, doneQueueDropPath);
  } catch {
    return {
      ok: false,
      message: "The bounded done-state closure could not move the claimed queue drop into the admitted done queue home."
    };
  }

  return {
    ok: true,
    payload: {
      done_queue_drop_ref: normalizeRelativePath(path.relative(workspaceRoot, doneQueueDropPath)),
      done_state_closure_artifact: {
        drop_file_name: claimedQueueDropFileName,
        worker_id: workerAssignment.worker_id,
        assignment_id: workerAssignment.assignment_id,
        source_artifact_refs: [
          normalizedClaimedQueueDropRef,
          normalizedWorkerAssignmentRef,
          normalizedWorkerCompletedStatusRef
        ],
        tool_id: normalizeOptionalString(workerAssignment.tool_id),
        extension_id: normalizeOptionalString(workerAssignment.extension_id),
        registry_digest: normalizeOptionalString(workerAssignment.registry_digest)
      }
    }
  };
}

function parseDoneCloseResult(closeResult) {
  if (!closeResult?.ok) {
    return {
      ok: false,
      kind: "done-close-failed",
      message: "The bounded done-state closure failed before usable done-queue output was produced."
    };
  }

  const payload = closeResult.payload;
  if (
    !isRecord(payload)
    || !isNonEmptyString(payload.done_queue_drop_ref)
    || !isRecord(payload.done_state_closure_artifact)
    || !isNonEmptyString(payload.done_state_closure_artifact.drop_file_name)
    || !isNonEmptyString(payload.done_state_closure_artifact.worker_id)
    || !isNonEmptyString(payload.done_state_closure_artifact.assignment_id)
    || !isStringArray(payload.done_state_closure_artifact.source_artifact_refs)
  ) {
    return {
      ok: false,
      kind: "malformed-done-output",
      message: "The bounded done-state closure emitted an unusable done-output contract."
    };
  }

  return { ok: true, payload };
}

export async function runQueueOrRegistryDoneStateClosureCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-claimed-queue-drop",
        failureScope: "arguments",
        message: parsed.errors.join(" ")
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const readText = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));
  const {
    claimedQueueDropPath,
    workerAssignmentPath,
    workerCompletedStatusPath,
    doneQueueRootPath
  } = parsed.args;

  const resolvedClaimedQueueDrop = resolveClaimedQueueDropPath(workspaceRoot, claimedQueueDropPath);
  if (!resolvedClaimedQueueDrop.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-claimed-queue-drop",
        failureScope: "claimed-queue-drop",
        message: resolvedClaimedQueueDrop.message
      })
    };
  }

  const resolvedWorkerAssignment = resolveWorkspaceFilePath(
    workspaceRoot,
    workerAssignmentPath,
    "--worker-assignment",
    "json"
  );
  if (!resolvedWorkerAssignment.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-assignment",
        failureScope: "worker-assignment",
        message: resolvedWorkerAssignment.message
      })
    };
  }

  const resolvedWorkerCompletedStatus = resolveWorkspaceFilePath(
    workspaceRoot,
    workerCompletedStatusPath,
    "--worker-completed-status",
    "json"
  );
  if (!resolvedWorkerCompletedStatus.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-completed-status",
        failureScope: "worker-completed-status",
        message: resolvedWorkerCompletedStatus.message
      })
    };
  }

  const resolvedDoneQueueRoot = resolveDoneQueueRootPath(workspaceRoot, doneQueueRootPath);
  if (!resolvedDoneQueueRoot.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-done-queue-root",
        failureScope: "done-queue-root",
        message: resolvedDoneQueueRoot.message
      })
    };
  }

  const claimedQueueDropFile = await loadTextFile(resolvedClaimedQueueDrop.absolutePath, readText);
  if (!claimedQueueDropFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-claimed-queue-drop",
        failureScope: "claimed-queue-drop",
        message: claimedQueueDropFile.message
      })
    };
  }

  const claimedQueueValidation = validateClaimedQueueDrop(claimedQueueDropFile.text);
  if (!claimedQueueValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-claimed-queue-drop",
        failureScope: "claimed-queue-drop",
        message: claimedQueueValidation.message
      })
    };
  }

  const workerAssignmentFile = await loadJsonFile(resolvedWorkerAssignment.absolutePath, readText);
  if (!workerAssignmentFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-assignment",
        failureScope: "worker-assignment",
        message: workerAssignmentFile.message
      })
    };
  }

  const assignmentValidation = validateWorkerAssignment(workerAssignmentFile.payload);
  if (!assignmentValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-assignment",
        failureScope: "worker-assignment",
        message: assignmentValidation.message
      })
    };
  }

  const workerCompletedStatusFile = await loadJsonFile(
    resolvedWorkerCompletedStatus.absolutePath,
    readText
  );
  if (!workerCompletedStatusFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-completed-status",
        failureScope: "worker-completed-status",
        message: workerCompletedStatusFile.message
      })
    };
  }

  const completedValidation = validateWorkerCompletedStatus(workerCompletedStatusFile.payload);
  if (!completedValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-completed-status",
        failureScope: "worker-completed-status",
        message: completedValidation.message
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
        message: stackLockDigestResult.message
      })
    };
  }

  const lineageValidation = validateDoneLineage({
    claimedQueueMetadata: claimedQueueValidation.metadata,
    workerAssignment: workerAssignmentFile.payload,
    workerCompletedStatus: workerCompletedStatusFile.payload,
    stackLockDigest: stackLockDigestResult.stackLockDigest
  });
  if (!lineageValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "lineage-mismatch",
        failureScope: "lineage",
        message: lineageValidation.message
      })
    };
  }

  const completedWorkerValidation = validateCompletedWorker({
    workerAssignment: workerAssignmentFile.payload,
    workerCompletedStatus: workerCompletedStatusFile.payload
  });
  if (!completedWorkerValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "completed-worker-mismatch",
        failureScope: "completed-worker",
        message: completedWorkerValidation.message
      })
    };
  }

  const closeDone = dependencies.closeDone || defaultCloseDone;
  const closeResult = await closeDone({
    workspaceRoot,
    normalizedClaimedQueueDropRef: resolvedClaimedQueueDrop.normalizedRef,
    claimedQueueDropPath: resolvedClaimedQueueDrop.absolutePath,
    normalizedWorkerAssignmentRef: resolvedWorkerAssignment.normalizedRef,
    normalizedWorkerCompletedStatusRef: resolvedWorkerCompletedStatus.normalizedRef,
    normalizedDoneQueueRootRef: resolvedDoneQueueRoot.normalizedRef,
    doneQueueRootPath: resolvedDoneQueueRoot.absolutePath,
    claimedQueueDropFileName: path.posix.basename(resolvedClaimedQueueDrop.normalizedRef),
    workerAssignment: workerAssignmentFile.payload
  });
  const parsedCloseResult = parseDoneCloseResult(closeResult);
  if (!parsedCloseResult.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: parsedCloseResult.kind,
        failureScope: "done-output",
        message: parsedCloseResult.message
      })
    };
  }

  const expectedDoneQueueDropRef =
    `${resolvedDoneQueueRoot.normalizedRef}/${path.posix.basename(resolvedClaimedQueueDrop.normalizedRef)}`;
  if (parsedCloseResult.payload.done_queue_drop_ref !== expectedDoneQueueDropRef) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-done-output",
        failureScope: "done-output",
        message: "The bounded done-state closure emitted an unexpected done queue-drop ref."
      })
    };
  }

  return {
    ok: true,
    report: buildSuccess({
      normalizedClaimedQueueDropRef: resolvedClaimedQueueDrop.normalizedRef,
      normalizedWorkerAssignmentRef: resolvedWorkerAssignment.normalizedRef,
      normalizedWorkerCompletedStatusRef: resolvedWorkerCompletedStatus.normalizedRef,
      normalizedDoneQueueRootRef: resolvedDoneQueueRoot.normalizedRef,
      doneQueueDropRef: parsedCloseResult.payload.done_queue_drop_ref,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      doneStateClosureArtifact: parsedCloseResult.payload.done_state_closure_artifact
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --claimed-queue-drop <relative-markdown-path> --worker-assignment <relative-json-path> --worker-completed-status <relative-json-path> --done-queue-root <relative-queue-root> [--format text|json]`,
    "",
    "Moves one explicit claimed queue drop into one bounded done queue home for one already-completed worker only.",
    "No-merge-close guard: this packet may admit future implementation of one explicit done-state-closure wrapper input parser, one root-relative ref normalization layer for claimed-queue-drop or worker-assignment or worker-completed-status or done-queue-root refs, one bounded claimed-to-done move into the admitted done queue home, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or completed-worker-mismatch or invalid-done-queue-root or done-close-failed or malformed-done-output handler, but it may not inspect ambient queue or historical worker state, claim merge closure or resume closure or execution success or verification success or commit success, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted done queue home, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryDoneStateClosureCommand(argv);
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
