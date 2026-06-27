#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry execution-bridge-artifacts";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_EXECUTION_BRIDGE_ARTIFACTS_WORKSPACE_ROOT";
const POWERSHELL_ENV = "STACK_QUEUE_OR_REGISTRY_EXECUTION_BRIDGE_ARTIFACTS_POWERSHELL";
const BRIDGE_SCRIPT_REF = "repos/_stack/ops/stack/Invoke-QueueOrRegistryExecutionBridgeArtifacts.ps1";
const STACK_LOCK_REF = "stack.lock.yaml";
const RECEIPT_OUTPUT_ROOT_PREFIX = "runtime/lifeline/worker-execution/";

const BRIDGE_RESULT_CONFIG = Object.freeze({
  succeeded: {
    resultClass: "execution-bridge-succeeded",
    routingNote: "explicit receipt-backed execution bridge succeeded; no queue or dispatch behavior is implied"
  },
  blocked: {
    resultClass: "execution-bridge-blocked",
    routingNote: "explicit receipt-backed execution bridge blocked; treat approval or receipt blocker as execution truth only"
  },
  failed: {
    resultClass: "execution-bridge-failed",
    routingNote:
      "explicit receipt-backed execution bridge failed; repair the receipt-backed execution chain before wider orchestration claims"
  }
});

const BRIDGE_RESULTS = new Set(Object.keys(BRIDGE_RESULT_CONFIG));
const FAILURE_CODES = new Set([
  "invalid-worker-assignment",
  "invalid-worker-status",
  "invalid-capability-profile",
  "invalid-request",
  "invalid-approval-receipt",
  "invalid-receipt-output-root",
  "lineage-mismatch",
  "bridge-failed",
  "malformed-bridge-output"
]);
const REPAIR_ROUTING_NOTE = "repair explicit execution-bridge contracts or lineage before wider orchestration claims";

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

function isStringArray(value) {
  return Array.isArray(value) && value.every((item) => isNonEmptyString(item));
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
    routing_note: REPAIR_ROUTING_NOTE
  };
}

function buildSuccess({
  normalizedWorkerAssignmentRef,
  normalizedWorkerStatusRef,
  normalizedCapabilityProfileRef,
  normalizedRequestRef,
  normalizedApprovalReceiptRef,
  normalizedReceiptOutputRootRef,
  receiptRef,
  workerStatusUpdateRef,
  bridgeRecordRef,
  stackLockDigest,
  resultClass,
  routingNote,
  executionBridgeArtifact
}) {
  return {
    command: COMMAND_ID,
    normalized_worker_assignment_ref: normalizedWorkerAssignmentRef,
    normalized_worker_status_ref: normalizedWorkerStatusRef,
    normalized_capability_profile_ref: normalizedCapabilityProfileRef,
    normalized_request_ref: normalizedRequestRef,
    normalized_approval_receipt_ref: normalizedApprovalReceiptRef,
    normalized_receipt_output_root_ref: normalizedReceiptOutputRootRef,
    receipt_ref: receiptRef,
    worker_status_update_ref: workerStatusUpdateRef,
    bridge_record_ref: bridgeRecordRef,
    stack_lock_digest: stackLockDigest,
    result_class: resultClass,
    routing_note: routingNote,
    payload: {
      execution_bridge_artifact: executionBridgeArtifact
    }
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_worker_assignment_ref=${result.report.normalized_worker_assignment_ref}`,
      `normalized_worker_status_ref=${result.report.normalized_worker_status_ref}`,
      `normalized_capability_profile_ref=${result.report.normalized_capability_profile_ref}`,
      `normalized_request_ref=${result.report.normalized_request_ref}`,
      `normalized_approval_receipt_ref=${result.report.normalized_approval_receipt_ref}`,
      `normalized_receipt_output_root_ref=${result.report.normalized_receipt_output_root_ref}`,
      `receipt_ref=${result.report.receipt_ref}`,
      `worker_status_update_ref=${result.report.worker_status_update_ref}`,
      `bridge_record_ref=${result.report.bridge_record_ref}`,
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
    workerAssignmentPath: undefined,
    workerStatusPath: undefined,
    capabilityProfilePath: undefined,
    requestPath: undefined,
    approvalReceiptPath: undefined,
    receiptOutputRootPath: undefined
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

    if (token === "--worker-assignment") {
      parsed.workerAssignmentPath = args[index + 1];
      if (!parsed.workerAssignmentPath) {
        errors.push("--worker-assignment requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--worker-status") {
      parsed.workerStatusPath = args[index + 1];
      if (!parsed.workerStatusPath) {
        errors.push("--worker-status requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--capability-profile") {
      parsed.capabilityProfilePath = args[index + 1];
      if (!parsed.capabilityProfilePath) {
        errors.push("--capability-profile requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--request") {
      parsed.requestPath = args[index + 1];
      if (!parsed.requestPath) {
        errors.push("--request requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--approval-receipt") {
      parsed.approvalReceiptPath = args[index + 1];
      if (!parsed.approvalReceiptPath) {
        errors.push("--approval-receipt requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--receipt-output-root") {
      parsed.receiptOutputRootPath = args[index + 1];
      if (!parsed.receiptOutputRootPath) {
        errors.push("--receipt-output-root requires one bounded relative output directory.");
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

function resolveReceiptOutputRootPath(workspaceRoot, rawPath) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: "--receipt-output-root requires one bounded relative output directory." };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: "--receipt-output-root must be a bounded relative output directory." };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = normalizeRelativePath(path.relative(workspaceRoot, absolutePath));
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: "--receipt-output-root must stay within the workspace root." };
  }

  if (!relativeFromRoot.startsWith(RECEIPT_OUTPUT_ROOT_PREFIX)) {
    return {
      ok: false,
      message: "--receipt-output-root must stay within runtime/lifeline/worker-execution/."
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

function validateWorkerStatus(payload) {
  if (
    !isRecord(payload)
    || payload.contract_version !== "atlas.worker.status.v1"
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.worker_id)
    || !isNonEmptyString(payload.state)
  ) {
    return {
      ok: false,
      message: "The explicit worker status must satisfy atlas.worker.status.v1."
    };
  }

  return { ok: true };
}

function validateCapabilityProfile(payload) {
  if (
    !isRecord(payload)
    || payload.contract_version !== "atlas.capability.profile.v1"
    || !isNonEmptyString(payload.capability_profile_id)
  ) {
    return {
      ok: false,
      message: "The explicit capability profile must satisfy atlas.capability.profile.v1."
    };
  }

  return { ok: true };
}

function validateRequest(payload) {
  if (
    !isRecord(payload)
    || payload.contract_version !== "atlas.privileged-action.request.v1"
    || !isNonEmptyString(payload.request_id)
    || !isNonEmptyString(payload.worker_id)
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.stack_lock_digest)
    || !isRecord(payload.requested_capability)
    || !isNonEmptyString(payload.requested_capability.capability_profile_id)
    || !isRecord(payload.action)
    || !isNonEmptyString(payload.action.operation)
  ) {
    return {
      ok: false,
      message: "The explicit privileged-action request must satisfy atlas.privileged-action.request.v1."
    };
  }

  const operation = payload.action.operation;
  if (operation !== "read_only_scan" && operation !== "scoped_write") {
    return {
      ok: false,
      message: "The explicit privileged-action request widens beyond the admitted execution operations."
    };
  }

  if (operation === "scoped_write" && !isNonEmptyString(payload.dry_run_output)) {
    return {
      ok: false,
      message: "The explicit scoped_write request must stay on the admitted dry-run path."
    };
  }

  return { ok: true };
}

function validateApprovalReceipt(payload) {
  if (
    !isRecord(payload)
    || payload.contract_version !== "atlas.approval.receipt.v1"
    || !isNonEmptyString(payload.request_id)
    || !isNonEmptyString(payload.worker_id)
    || !isNonEmptyString(payload.assignment_id)
    || !isNonEmptyString(payload.stack_lock_digest)
  ) {
    return {
      ok: false,
      message: "The explicit approval receipt must satisfy atlas.approval.receipt.v1."
    };
  }

  return { ok: true };
}

function valuesMatch(left, right) {
  if (left == null || right == null) {
    return true;
  }

  return String(left) === String(right);
}

function validateLineage({
  workerAssignment,
  workerStatus,
  capabilityProfile,
  request,
  approvalReceipt,
  stackLockDigest
}) {
  if (!valuesMatch(workerAssignment.worker_id, workerStatus.worker_id)) {
    return { ok: false, message: "The worker assignment and worker status do not agree on worker_id." };
  }
  if (!valuesMatch(workerAssignment.assignment_id, workerStatus.assignment_id)) {
    return { ok: false, message: "The worker assignment and worker status do not agree on assignment_id." };
  }
  if (!valuesMatch(workerAssignment.worker_id, request.worker_id)) {
    return { ok: false, message: "The worker assignment and privileged-action request do not agree on worker_id." };
  }
  if (!valuesMatch(workerAssignment.assignment_id, request.assignment_id)) {
    return { ok: false, message: "The worker assignment and privileged-action request do not agree on assignment_id." };
  }
  if (!valuesMatch(workerAssignment.worker_id, approvalReceipt.worker_id)) {
    return { ok: false, message: "The worker assignment and approval receipt do not agree on worker_id." };
  }
  if (!valuesMatch(workerAssignment.assignment_id, approvalReceipt.assignment_id)) {
    return { ok: false, message: "The worker assignment and approval receipt do not agree on assignment_id." };
  }
  if (!valuesMatch(request.request_id, approvalReceipt.request_id)) {
    return { ok: false, message: "The privileged-action request and approval receipt do not agree on request_id." };
  }
  if (!valuesMatch(request.requested_capability?.capability_profile_id, capabilityProfile.capability_profile_id)) {
    return {
      ok: false,
      message: "The privileged-action request does not match the explicit capability profile artifact."
    };
  }

  const observedLockDigests = [
    workerAssignment.stack_lock_digest,
    workerStatus.stack_lock_digest,
    request.stack_lock_digest,
    approvalReceipt.stack_lock_digest
  ];
  for (const observedLockDigest of observedLockDigests) {
    if (!valuesMatch(observedLockDigest, stackLockDigest)) {
      return {
        ok: false,
        message: "The explicit execution-bridge artifacts do not agree with the current workspace lock digest."
      };
    }
  }

  for (const field of ["tool_id", "extension_id", "registry_digest"]) {
    const values = [
      workerAssignment[field],
      workerStatus[field],
      request[field],
      approvalReceipt[field],
      capabilityProfile[field]
    ].filter((value) => value != null && value !== "");
    if (values.length > 1 && new Set(values.map((value) => String(value))).size > 1) {
      return {
        ok: false,
        message: `The explicit execution-bridge artifacts do not agree on ${field}.`
      };
    }
  }

  if (
    approvalReceipt.approval_status === "approved"
    && isRecord(approvalReceipt.granted_scope)
    && !valuesMatch(approvalReceipt.granted_scope.capability_profile_id, capabilityProfile.capability_profile_id)
  ) {
    return {
      ok: false,
      message: "The approval receipt does not preserve the admitted capability profile lineage."
    };
  }

  return { ok: true };
}

async function defaultRunBridge({
  workspaceRoot,
  workerAssignmentPath,
  workerStatusPath,
  capabilityProfilePath,
  requestPath,
  approvalReceiptPath,
  receiptOutputRootPath
}) {
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
        "-WorkerAssignmentPath",
        workerAssignmentPath,
        "-WorkerStatusPath",
        workerStatusPath,
        "-CapabilityProfilePath",
        capabilityProfilePath,
        "-RequestPath",
        requestPath,
        "-ApprovalReceiptPath",
        approvalReceiptPath,
        "-ReceiptOutputRootPath",
        receiptOutputRootPath
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
      kind: "bridge-failed",
      message: "The admitted _stack execution-bridge helper failed before usable receipt-backed output was produced."
    };
  }

  let payload;
  try {
    payload = JSON.parse(bridgeResult.stdout);
  } catch {
    return {
      ok: false,
      kind: "malformed-bridge-output",
      message: "The admitted _stack execution-bridge helper emitted non-json output."
    };
  }

  if (
    !isRecord(payload)
    || !isNonEmptyString(payload.receipt_ref)
    || !isNonEmptyString(payload.worker_status_update_ref)
    || !isNonEmptyString(payload.bridge_record_ref)
    || !isNonEmptyString(payload.stack_lock_digest)
    || !isNonEmptyString(payload.result)
    || !BRIDGE_RESULTS.has(payload.result)
  ) {
    return {
      ok: false,
      kind: "malformed-bridge-output",
      message: "The admitted _stack execution-bridge helper omitted the expected bridge output surface."
    };
  }

  return { ok: true, payload };
}

export async function runQueueOrRegistryExecutionBridgeArtifactsCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-assignment",
        failureScope: "arguments",
        message: parsed.errors.join(" ")
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const readText = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));
  const {
    workerAssignmentPath,
    workerStatusPath,
    capabilityProfilePath,
    requestPath,
    approvalReceiptPath,
    receiptOutputRootPath
  } = parsed.args;

  const resolvedWorkerAssignment = resolveWorkspaceJsonPath(
    workspaceRoot,
    workerAssignmentPath,
    "--worker-assignment"
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

  const resolvedWorkerStatus = resolveWorkspaceJsonPath(workspaceRoot, workerStatusPath, "--worker-status");
  if (!resolvedWorkerStatus.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-status",
        failureScope: "worker-status",
        message: resolvedWorkerStatus.message
      })
    };
  }

  const resolvedCapabilityProfile = resolveWorkspaceJsonPath(
    workspaceRoot,
    capabilityProfilePath,
    "--capability-profile"
  );
  if (!resolvedCapabilityProfile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-capability-profile",
        failureScope: "capability-profile",
        message: resolvedCapabilityProfile.message
      })
    };
  }

  const resolvedRequest = resolveWorkspaceJsonPath(workspaceRoot, requestPath, "--request");
  if (!resolvedRequest.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-request",
        failureScope: "request",
        message: resolvedRequest.message
      })
    };
  }

  const resolvedApprovalReceipt = resolveWorkspaceJsonPath(
    workspaceRoot,
    approvalReceiptPath,
    "--approval-receipt"
  );
  if (!resolvedApprovalReceipt.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-approval-receipt",
        failureScope: "approval-receipt",
        message: resolvedApprovalReceipt.message
      })
    };
  }

  const resolvedReceiptOutputRoot = resolveReceiptOutputRootPath(workspaceRoot, receiptOutputRootPath);
  if (!resolvedReceiptOutputRoot.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-receipt-output-root",
        failureScope: "receipt-output-root",
        message: resolvedReceiptOutputRoot.message
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
  const workerAssignmentValidation = validateWorkerAssignment(workerAssignmentFile.payload);
  if (!workerAssignmentValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-assignment",
        failureScope: "worker-assignment",
        message: workerAssignmentValidation.message
      })
    };
  }

  const workerStatusFile = await loadJsonFile(resolvedWorkerStatus.absolutePath, readText);
  if (!workerStatusFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-status",
        failureScope: "worker-status",
        message: workerStatusFile.message
      })
    };
  }
  const workerStatusValidation = validateWorkerStatus(workerStatusFile.payload);
  if (!workerStatusValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-worker-status",
        failureScope: "worker-status",
        message: workerStatusValidation.message
      })
    };
  }

  const capabilityProfileFile = await loadJsonFile(resolvedCapabilityProfile.absolutePath, readText);
  if (!capabilityProfileFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-capability-profile",
        failureScope: "capability-profile",
        message: capabilityProfileFile.message
      })
    };
  }
  const capabilityProfileValidation = validateCapabilityProfile(capabilityProfileFile.payload);
  if (!capabilityProfileValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-capability-profile",
        failureScope: "capability-profile",
        message: capabilityProfileValidation.message
      })
    };
  }

  const requestFile = await loadJsonFile(resolvedRequest.absolutePath, readText);
  if (!requestFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-request",
        failureScope: "request",
        message: requestFile.message
      })
    };
  }
  const requestValidation = validateRequest(requestFile.payload);
  if (!requestValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-request",
        failureScope: "request",
        message: requestValidation.message
      })
    };
  }

  const approvalReceiptFile = await loadJsonFile(resolvedApprovalReceipt.absolutePath, readText);
  if (!approvalReceiptFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-approval-receipt",
        failureScope: "approval-receipt",
        message: approvalReceiptFile.message
      })
    };
  }
  const approvalReceiptValidation = validateApprovalReceipt(approvalReceiptFile.payload);
  if (!approvalReceiptValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-approval-receipt",
        failureScope: "approval-receipt",
        message: approvalReceiptValidation.message
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

  const lineageValidation = validateLineage({
    workerAssignment: workerAssignmentFile.payload,
    workerStatus: workerStatusFile.payload,
    capabilityProfile: capabilityProfileFile.payload,
    request: requestFile.payload,
    approvalReceipt: approvalReceiptFile.payload,
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

  const runBridge = dependencies.runBridge || defaultRunBridge;
  const bridgeResult = await runBridge({
    workspaceRoot,
    workerAssignmentPath: resolvedWorkerAssignment.absolutePath,
    workerStatusPath: resolvedWorkerStatus.absolutePath,
    capabilityProfilePath: resolvedCapabilityProfile.absolutePath,
    requestPath: resolvedRequest.absolutePath,
    approvalReceiptPath: resolvedApprovalReceipt.absolutePath,
    receiptOutputRootPath: resolvedReceiptOutputRoot.absolutePath
  });

  const parsedBridge = parseBridgeOutput(bridgeResult);
  if (!parsedBridge.ok) {
    const failureCode = parsedBridge.kind === "bridge-failed" ? "bridge-failed" : "malformed-bridge-output";
    return {
      ok: false,
      report: buildFailure({
        failureCode,
        failureScope: "bridge",
        message: parsedBridge.message
      })
    };
  }

  if (!valuesMatch(parsedBridge.payload.stack_lock_digest, stackLockDigestResult.stackLockDigest)) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-bridge-output",
        failureScope: "bridge",
        message: "The admitted _stack execution-bridge helper contradicted the current workspace lock digest."
      })
    };
  }

  const config = BRIDGE_RESULT_CONFIG[parsedBridge.payload.result];
  return {
    ok: true,
    report: buildSuccess({
      normalizedWorkerAssignmentRef: resolvedWorkerAssignment.normalizedRef,
      normalizedWorkerStatusRef: resolvedWorkerStatus.normalizedRef,
      normalizedCapabilityProfileRef: resolvedCapabilityProfile.normalizedRef,
      normalizedRequestRef: resolvedRequest.normalizedRef,
      normalizedApprovalReceiptRef: resolvedApprovalReceipt.normalizedRef,
      normalizedReceiptOutputRootRef: resolvedReceiptOutputRoot.normalizedRef,
      receiptRef: parsedBridge.payload.receipt_ref,
      workerStatusUpdateRef: parsedBridge.payload.worker_status_update_ref,
      bridgeRecordRef: parsedBridge.payload.bridge_record_ref,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      resultClass: config.resultClass,
      routingNote: config.routingNote,
      executionBridgeArtifact: parsedBridge.payload
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --worker-assignment <relative-json-path> --worker-status <relative-json-path> --capability-profile <relative-json-path> --request <relative-json-path> --approval-receipt <relative-json-path> --receipt-output-root <relative-output-dir> [--format text|json]`,
    "",
    "Bridges one explicit receipt-backed worker execution through the admitted _stack helper only.",
    "No-dispatch guard: this packet may admit future implementation of one explicit execution-bridge-artifacts wrapper input parser, one root-relative ref normalization layer for worker-assignment or worker-status or capability-profile or request or approval-receipt or receipt-output-root refs, one admitted _stack execution-bridge helper invocation layer only, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or invalid-receipt-output-root or bridge-failure handler, but it may not inspect live queue or registry state, emit queue drops, mint capability or request or approval truth, launch or dispatch workers, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted execution-status update or bridge record or receipt-output root, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryExecutionBridgeArtifactsCommand(argv);
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
