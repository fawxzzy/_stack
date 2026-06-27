#!/usr/bin/env node

import { access, mkdir, readFile, rename } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry claim-state movement";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_CLAIM_STATE_MOVEMENT_WORKSPACE_ROOT";
const STACK_LOCK_REF = "stack.lock.yaml";
const PENDING_QUEUE_PREFIX = "repos/_stack/queue/pending";
const CLAIMED_QUEUE_ROOT_PREFIX = "repos/_stack/queue/claimed";
const SUCCESS_RESULT_CLASS = "claim-moved";
const SUCCESS_ROUTING_NOTE =
  "explicit pending drop moved to claimed only for one active worker; no completion or done-state advancement is implied";
const FAILURE_ROUTING_NOTE =
  "repair explicit claim-state lineage, active-worker agreement, or claimed-home routing before wider orchestration claims";
const FAILURE_CODES = new Set([
  "invalid-pending-queue-drop",
  "invalid-worker-assignment",
  "invalid-worker-running-status",
  "invalid-claimed-queue-root",
  "lineage-mismatch",
  "active-worker-mismatch",
  "claim-move-failed",
  "malformed-claim-output"
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
  normalizedPendingQueueDropRef,
  normalizedWorkerAssignmentRef,
  normalizedWorkerRunningStatusRef,
  normalizedClaimedQueueRootRef,
  claimedQueueDropRef,
  stackLockDigest,
  claimMovementArtifact
}) {
  return {
    command: COMMAND_ID,
    normalized_pending_queue_drop_ref: normalizedPendingQueueDropRef,
    normalized_worker_assignment_ref: normalizedWorkerAssignmentRef,
    normalized_worker_running_status_ref: normalizedWorkerRunningStatusRef,
    normalized_claimed_queue_root_ref: normalizedClaimedQueueRootRef,
    claimed_queue_drop_ref: claimedQueueDropRef,
    stack_lock_digest: stackLockDigest,
    result_class: SUCCESS_RESULT_CLASS,
    routing_note: SUCCESS_ROUTING_NOTE,
    payload: {
      claim_movement_artifact: claimMovementArtifact
    }
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_pending_queue_drop_ref=${result.report.normalized_pending_queue_drop_ref}`,
      `normalized_worker_assignment_ref=${result.report.normalized_worker_assignment_ref}`,
      `normalized_worker_running_status_ref=${result.report.normalized_worker_running_status_ref}`,
      `normalized_claimed_queue_root_ref=${result.report.normalized_claimed_queue_root_ref}`,
      `claimed_queue_drop_ref=${result.report.claimed_queue_drop_ref}`,
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
    pendingQueueDropPath: undefined,
    workerAssignmentPath: undefined,
    workerRunningStatusPath: undefined,
    claimedQueueRootPath: undefined
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

    if (token === "--pending-queue-drop") {
      parsed.pendingQueueDropPath = args[index + 1];
      if (!parsed.pendingQueueDropPath) {
        errors.push("--pending-queue-drop requires one bounded relative markdown path.");
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

    if (token === "--worker-running-status") {
      parsed.workerRunningStatusPath = args[index + 1];
      if (!parsed.workerRunningStatusPath) {
        errors.push("--worker-running-status requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--claimed-queue-root") {
      parsed.claimedQueueRootPath = args[index + 1];
      if (!parsed.claimedQueueRootPath) {
        errors.push("--claimed-queue-root requires one bounded relative claimed queue root.");
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

function resolvePendingQueueDropPath(workspaceRoot, rawPath) {
  const resolved = resolveWorkspaceFilePath(workspaceRoot, rawPath, "--pending-queue-drop", "md");
  if (!resolved.ok) {
    return resolved;
  }

  if (
    !resolved.normalizedRef.startsWith(`${PENDING_QUEUE_PREFIX}/`)
    && resolved.normalizedRef !== `${PENDING_QUEUE_PREFIX}.md`
  ) {
    return {
      ok: false,
      message: "--pending-queue-drop must stay within repos/_stack/queue/pending/."
    };
  }

  return resolved;
}

function resolveClaimedQueueRootPath(workspaceRoot, rawPath) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: "--claimed-queue-root requires one bounded relative claimed queue root." };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: "--claimed-queue-root must be a bounded relative claimed queue root." };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = normalizeRelativePath(path.relative(workspaceRoot, absolutePath));
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: "--claimed-queue-root must stay within the workspace root." };
  }

  if (
    relativeFromRoot !== CLAIMED_QUEUE_ROOT_PREFIX
    && !relativeFromRoot.startsWith(`${CLAIMED_QUEUE_ROOT_PREFIX}/`)
  ) {
    return {
      ok: false,
      message: "--claimed-queue-root must stay within repos/_stack/queue/claimed/."
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

function validatePendingQueueDrop(markdownText) {
  if (!isNonEmptyString(markdownText)) {
    return {
      ok: false,
      message: "The explicit pending queue drop must be a non-empty Markdown prompt."
    };
  }

  const metadata = parseMetadataHeaders(markdownText);
  const stackLockDigest = metadata.stacklockdigest ?? metadata.stacklock ?? null;
  if (!isNonEmptyString(stackLockDigest)) {
    return {
      ok: false,
      message: "The explicit pending queue drop must declare one current stack lock digest."
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

function validateWorkerRunningStatus(payload) {
  if (
    !isRecord(payload)
    || payload.contract_version !== "atlas.worker.status.v1"
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.worker_id)
    || payload.state !== "running"
    || !isNonEmptyString(payload.heartbeat_at)
  ) {
    return {
      ok: false,
      message: "The explicit worker running-status must satisfy the admitted atlas.worker.status.v1 running contract."
    };
  }

  return { ok: true };
}

function validateClaimLineage({
  pendingQueueMetadata,
  workerAssignment,
  workerRunningStatus,
  stackLockDigest
}) {
  if (!valuesMatch(pendingQueueMetadata.stackLockDigest, stackLockDigest)) {
    return {
      ok: false,
      message: "The pending queue drop stack lock digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(workerAssignment.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The explicit worker assignment stack lock digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(workerRunningStatus.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The explicit worker running-status stack lock digest contradicts the current workspace lock digest."
    };
  }

  for (const field of ["tool_id", "extension_id", "registry_digest"]) {
    if (!valuesMatch(workerAssignment[field], workerRunningStatus[field])) {
      return {
        ok: false,
        message: `The explicit active-worker artifacts do not agree on ${field}.`
      };
    }

    const pendingValue =
      field === "tool_id"
        ? pendingQueueMetadata.toolId
        : field === "extension_id"
          ? pendingQueueMetadata.extensionId
          : pendingQueueMetadata.registryDigest;

    if (!valuesMatch(pendingValue, workerAssignment[field])) {
      return {
        ok: false,
        message: `The pending queue drop and explicit active-worker artifacts do not agree on ${field}.`
      };
    }
  }

  return { ok: true };
}

function validateActiveWorker({ workerAssignment, workerRunningStatus }) {
  if (!valuesMatch(workerAssignment.worker_id, workerRunningStatus.worker_id)) {
    return {
      ok: false,
      message: "The explicit worker assignment and running-status do not agree on worker_id."
    };
  }

  if (!valuesMatch(workerAssignment.assignment_id, workerRunningStatus.assignment_id)) {
    return {
      ok: false,
      message: "The explicit worker assignment and running-status do not agree on assignment_id."
    };
  }

  return { ok: true };
}

async function defaultMoveClaim({
  workspaceRoot,
  normalizedPendingQueueDropRef,
  pendingQueueDropPath,
  normalizedWorkerAssignmentRef,
  normalizedWorkerRunningStatusRef,
  normalizedClaimedQueueRootRef,
  claimedQueueRootPath,
  pendingQueueDropFileName,
  workerAssignment
}) {
  const claimedQueueDropPath = path.join(claimedQueueRootPath, pendingQueueDropFileName);
  const claimedQueueDropRef = `${normalizedClaimedQueueRootRef}/${pendingQueueDropFileName}`;

  try {
    await mkdir(claimedQueueRootPath, { recursive: true });
    try {
      await access(claimedQueueDropPath);
      return {
        ok: false,
        message: "The bounded claimed queue target is already occupied."
      };
    } catch (error) {
      if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) {
        return {
          ok: false,
          message: "The bounded claimed queue target could not be inspected."
        };
      }
    }

    await rename(pendingQueueDropPath, claimedQueueDropPath);
  } catch {
    return {
      ok: false,
      message: "The bounded claim-state move could not move the pending queue drop into the admitted claimed queue home."
    };
  }

  return {
    ok: true,
    payload: {
      claimed_queue_drop_ref: normalizeRelativePath(path.relative(workspaceRoot, claimedQueueDropPath)),
      claim_movement_artifact: {
        drop_file_name: pendingQueueDropFileName,
        worker_id: workerAssignment.worker_id,
        assignment_id: workerAssignment.assignment_id,
        source_artifact_refs: [
          normalizedPendingQueueDropRef,
          normalizedWorkerAssignmentRef,
          normalizedWorkerRunningStatusRef
        ],
        tool_id: normalizeOptionalString(workerAssignment.tool_id),
        extension_id: normalizeOptionalString(workerAssignment.extension_id),
        registry_digest: normalizeOptionalString(workerAssignment.registry_digest)
      }
    }
  };
}

function parseClaimMoveResult(moveResult) {
  if (!moveResult?.ok) {
    return {
      ok: false,
      kind: "claim-move-failed",
      message: "The bounded claim-state move failed before usable claimed-queue output was produced."
    };
  }

  const payload = moveResult.payload;
  if (
    !isRecord(payload)
    || !isNonEmptyString(payload.claimed_queue_drop_ref)
    || !isRecord(payload.claim_movement_artifact)
    || !isNonEmptyString(payload.claim_movement_artifact.drop_file_name)
    || !isNonEmptyString(payload.claim_movement_artifact.worker_id)
    || !isNonEmptyString(payload.claim_movement_artifact.assignment_id)
    || !isStringArray(payload.claim_movement_artifact.source_artifact_refs)
  ) {
    return {
      ok: false,
      kind: "malformed-claim-output",
      message: "The bounded claim-state move emitted an unusable claim-output contract."
    };
  }

  return { ok: true, payload };
}

export async function runQueueOrRegistryClaimStateMovementCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-pending-queue-drop",
        failureScope: "arguments",
        message: parsed.errors.join(" ")
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const readText = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));
  const {
    pendingQueueDropPath,
    workerAssignmentPath,
    workerRunningStatusPath,
    claimedQueueRootPath
  } = parsed.args;

  const resolvedPendingQueueDrop = resolvePendingQueueDropPath(workspaceRoot, pendingQueueDropPath);
  if (!resolvedPendingQueueDrop.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-pending-queue-drop",
        failureScope: "pending-queue-drop",
        message: resolvedPendingQueueDrop.message
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

  const resolvedWorkerRunningStatus = resolveWorkspaceFilePath(
    workspaceRoot,
    workerRunningStatusPath,
    "--worker-running-status",
    "json"
  );
  if (!resolvedWorkerRunningStatus.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-running-status",
        failureScope: "worker-running-status",
        message: resolvedWorkerRunningStatus.message
      })
    };
  }

  const resolvedClaimedQueueRoot = resolveClaimedQueueRootPath(workspaceRoot, claimedQueueRootPath);
  if (!resolvedClaimedQueueRoot.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-claimed-queue-root",
        failureScope: "claimed-queue-root",
        message: resolvedClaimedQueueRoot.message
      })
    };
  }

  const pendingQueueDropFile = await loadTextFile(resolvedPendingQueueDrop.absolutePath, readText);
  if (!pendingQueueDropFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-pending-queue-drop",
        failureScope: "pending-queue-drop",
        message: pendingQueueDropFile.message
      })
    };
  }

  const pendingQueueValidation = validatePendingQueueDrop(pendingQueueDropFile.text);
  if (!pendingQueueValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-pending-queue-drop",
        failureScope: "pending-queue-drop",
        message: pendingQueueValidation.message
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

  const workerRunningStatusFile = await loadJsonFile(resolvedWorkerRunningStatus.absolutePath, readText);
  if (!workerRunningStatusFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-running-status",
        failureScope: "worker-running-status",
        message: workerRunningStatusFile.message
      })
    };
  }

  const runningValidation = validateWorkerRunningStatus(workerRunningStatusFile.payload);
  if (!runningValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-running-status",
        failureScope: "worker-running-status",
        message: runningValidation.message
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

  const lineageValidation = validateClaimLineage({
    pendingQueueMetadata: pendingQueueValidation.metadata,
    workerAssignment: workerAssignmentFile.payload,
    workerRunningStatus: workerRunningStatusFile.payload,
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

  const activeWorkerValidation = validateActiveWorker({
    workerAssignment: workerAssignmentFile.payload,
    workerRunningStatus: workerRunningStatusFile.payload
  });
  if (!activeWorkerValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "active-worker-mismatch",
        failureScope: "active-worker",
        message: activeWorkerValidation.message
      })
    };
  }

  const moveClaim = dependencies.moveClaim || defaultMoveClaim;
  const moveResult = await moveClaim({
    workspaceRoot,
    normalizedPendingQueueDropRef: resolvedPendingQueueDrop.normalizedRef,
    pendingQueueDropPath: resolvedPendingQueueDrop.absolutePath,
    normalizedWorkerAssignmentRef: resolvedWorkerAssignment.normalizedRef,
    normalizedWorkerRunningStatusRef: resolvedWorkerRunningStatus.normalizedRef,
    normalizedClaimedQueueRootRef: resolvedClaimedQueueRoot.normalizedRef,
    claimedQueueRootPath: resolvedClaimedQueueRoot.absolutePath,
    pendingQueueDropFileName: path.posix.basename(resolvedPendingQueueDrop.normalizedRef),
    workerAssignment: workerAssignmentFile.payload
  });
  const parsedMoveResult = parseClaimMoveResult(moveResult);
  if (!parsedMoveResult.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: parsedMoveResult.kind,
        failureScope: "claim-output",
        message: parsedMoveResult.message
      })
    };
  }

  const expectedClaimedQueueDropRef =
    `${resolvedClaimedQueueRoot.normalizedRef}/${path.posix.basename(resolvedPendingQueueDrop.normalizedRef)}`;
  if (parsedMoveResult.payload.claimed_queue_drop_ref !== expectedClaimedQueueDropRef) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-claim-output",
        failureScope: "claim-output",
        message: "The bounded claim-state move emitted an unexpected claimed queue-drop ref."
      })
    };
  }

  return {
    ok: true,
    report: buildSuccess({
      normalizedPendingQueueDropRef: resolvedPendingQueueDrop.normalizedRef,
      normalizedWorkerAssignmentRef: resolvedWorkerAssignment.normalizedRef,
      normalizedWorkerRunningStatusRef: resolvedWorkerRunningStatus.normalizedRef,
      normalizedClaimedQueueRootRef: resolvedClaimedQueueRoot.normalizedRef,
      claimedQueueDropRef: parsedMoveResult.payload.claimed_queue_drop_ref,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      claimMovementArtifact: parsedMoveResult.payload.claim_movement_artifact
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --pending-queue-drop <relative-markdown-path> --worker-assignment <relative-json-path> --worker-running-status <relative-json-path> --claimed-queue-root <relative-queue-root> [--format text|json]`,
    "",
    "Moves one explicit pending queue drop into one bounded claimed queue home for one already-running worker only.",
    "No-completion guard: this packet may admit future implementation of one explicit claim-state-movement wrapper input parser, one root-relative ref normalization layer for pending-queue-drop or worker-assignment or worker-running-status or claimed-queue-root refs, one bounded pending-to-claimed move into the admitted claimed queue home, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or active-worker-mismatch or invalid-claimed-queue-root or claim-move-failed or malformed-claim-output handler, but it may not inspect ambient queue or historical worker state, move files into done queue homes, claim worker completion or verification success or commit success, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted claimed queue home, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryClaimStateMovementCommand(argv);
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
