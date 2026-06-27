#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry launch-or-dispatch";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_LAUNCH_OR_DISPATCH_WORKSPACE_ROOT";
const POWERSHELL_ENV = "STACK_QUEUE_OR_REGISTRY_LAUNCH_OR_DISPATCH_POWERSHELL";
const HELPER_SCRIPT_REF = "repos/_stack/ops/stack/Invoke-QueueOrRegistryLaunchOrDispatch.ps1";
const STACK_LOCK_REF = "stack.lock.yaml";
const PENDING_QUEUE_PREFIX = "repos/_stack/queue/pending";
const STACK_RUNNER_CONFIG_REF = "repos/_stack/ops/codex/repos/stack/config.toml";
const DISPATCH_INBOX_ROOT_PREFIX = "repos/_stack/.codex/inbox";
const DISPATCH_LOGS_ROOT_PREFIX = "repos/_stack/.codex/logs";
const SUCCESS_RESULT_CLASS = "launch-started";
const SUCCESS_ROUTING_NOTE =
  "explicit pending drop staged into bounded inbox and worker-start artifacts emitted; no completion or queue-state advancement is implied";
const FAILURE_ROUTING_NOTE =
  "repair pending-drop lineage, staging roots, or worker-start artifacts before wider orchestration claims";
const FAILURE_CODES = new Set([
  "invalid-pending-queue-drop",
  "invalid-stack-runner-config",
  "invalid-dispatch-inbox-root",
  "invalid-dispatch-logs-root",
  "lineage-mismatch",
  "prompt-stage-write-failed",
  "launch-start-failed",
  "worker-start-artifacts-missing",
  "malformed-worker-start-output"
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
  normalizedStackRunnerConfigRef,
  normalizedDispatchInboxRootRef,
  normalizedDispatchLogsRootRef,
  stagedPromptRef,
  workerAssignmentRef,
  workerRunningStatusRef,
  stackLockDigest,
  launchStartArtifact
}) {
  return {
    command: COMMAND_ID,
    normalized_pending_queue_drop_ref: normalizedPendingQueueDropRef,
    normalized_stack_runner_config_ref: normalizedStackRunnerConfigRef,
    normalized_dispatch_inbox_root_ref: normalizedDispatchInboxRootRef,
    normalized_dispatch_logs_root_ref: normalizedDispatchLogsRootRef,
    staged_prompt_ref: stagedPromptRef,
    worker_assignment_ref: workerAssignmentRef,
    worker_running_status_ref: workerRunningStatusRef,
    stack_lock_digest: stackLockDigest,
    result_class: SUCCESS_RESULT_CLASS,
    routing_note: SUCCESS_ROUTING_NOTE,
    payload: {
      launch_start_artifact: launchStartArtifact
    }
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_pending_queue_drop_ref=${result.report.normalized_pending_queue_drop_ref}`,
      `normalized_stack_runner_config_ref=${result.report.normalized_stack_runner_config_ref}`,
      `normalized_dispatch_inbox_root_ref=${result.report.normalized_dispatch_inbox_root_ref}`,
      `normalized_dispatch_logs_root_ref=${result.report.normalized_dispatch_logs_root_ref}`,
      `staged_prompt_ref=${result.report.staged_prompt_ref}`,
      `worker_assignment_ref=${result.report.worker_assignment_ref}`,
      `worker_running_status_ref=${result.report.worker_running_status_ref}`,
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
    stackRunnerConfigPath: undefined,
    dispatchInboxRootPath: undefined,
    dispatchLogsRootPath: undefined
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

    if (token === "--stack-runner-config") {
      parsed.stackRunnerConfigPath = args[index + 1];
      if (!parsed.stackRunnerConfigPath) {
        errors.push("--stack-runner-config requires one bounded relative config path.");
      }
      index += 1;
      continue;
    }

    if (token === "--dispatch-inbox-root") {
      parsed.dispatchInboxRootPath = args[index + 1];
      if (!parsed.dispatchInboxRootPath) {
        errors.push("--dispatch-inbox-root requires one bounded relative inbox root.");
      }
      index += 1;
      continue;
    }

    if (token === "--dispatch-logs-root") {
      parsed.dispatchLogsRootPath = args[index + 1];
      if (!parsed.dispatchLogsRootPath) {
        errors.push("--dispatch-logs-root requires one bounded relative logs root.");
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

function resolveStackRunnerConfigPath(workspaceRoot, rawPath) {
  const resolved = resolveWorkspaceFilePath(workspaceRoot, rawPath, "--stack-runner-config", "toml");
  if (!resolved.ok) {
    return resolved;
  }

  if (resolved.normalizedRef !== STACK_RUNNER_CONFIG_REF) {
    return {
      ok: false,
      message: "--stack-runner-config must point to repos/_stack/ops/codex/repos/stack/config.toml."
    };
  }

  return resolved;
}

function resolveWorkspaceDirectoryPath(workspaceRoot, rawPath, label, admittedPrefix) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: `${label} requires one bounded relative directory path.` };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: `${label} must be a bounded relative directory path.` };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = normalizeRelativePath(path.relative(workspaceRoot, absolutePath));
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: `${label} must stay within the workspace root.` };
  }

  if (relativeFromRoot !== admittedPrefix && !relativeFromRoot.startsWith(`${admittedPrefix}/`)) {
    return {
      ok: false,
      message: `${label} must stay within ${admittedPrefix}/.`
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

function parseListMetadataValue(value) {
  if (!isNonEmptyString(value)) {
    return [];
  }

  return value
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
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
      registryDigest: normalizeOptionalString(metadata.registrydigest),
      sourceArtifactRefs: parseListMetadataValue(metadata.handoffrefs)
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
      message: "The emitted worker assignment does not satisfy atlas.worker.assignment.v1."
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
      message: "The emitted running status does not satisfy the admitted atlas.worker.status.v1 running contract."
    };
  }

  return { ok: true };
}

function validateWorkerStartLineage({
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
      message: "The emitted worker assignment stack lock digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(workerAssignment.worker_id, workerRunningStatus.worker_id)) {
    return {
      ok: false,
      message: "The emitted worker assignment and running status do not agree on worker_id."
    };
  }

  if (!valuesMatch(workerAssignment.assignment_id, workerRunningStatus.assignment_id)) {
    return {
      ok: false,
      message: "The emitted worker assignment and running status do not agree on assignment_id."
    };
  }

  for (const field of ["tool_id", "extension_id", "registry_digest"]) {
    if (!valuesMatch(workerAssignment[field], workerRunningStatus[field])) {
      return {
        ok: false,
        message: `The emitted worker-start artifacts do not agree on ${field}.`
      };
    }
    if (
      !valuesMatch(
        pendingQueueMetadata[
          field === "tool_id"
            ? "toolId"
            : field === "extension_id"
              ? "extensionId"
              : "registryDigest"
        ],
        workerAssignment[field]
      )
    ) {
      return {
        ok: false,
        message: `The pending queue drop and emitted worker-start artifacts do not agree on ${field}.`
      };
    }
  }

  return { ok: true };
}

async function defaultRunLaunchStart({
  workspaceRoot,
  pendingQueueDropPath,
  stackRunnerConfigPath,
  dispatchInboxRootPath,
  dispatchLogsRootPath
}) {
  const powershellCommand = process.env[POWERSHELL_ENV] || "powershell.exe";
  const helperPath = path.join(workspaceRoot, HELPER_SCRIPT_REF);

  return new Promise((resolve) => {
    const child = spawn(
      powershellCommand,
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        helperPath,
        "-WorkspaceRoot",
        workspaceRoot,
        "-PendingQueueDropPath",
        pendingQueueDropPath,
        "-StackRunnerConfigPath",
        stackRunnerConfigPath,
        "-DispatchInboxRootPath",
        dispatchInboxRootPath,
        "-DispatchLogsRootPath",
        dispatchLogsRootPath
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

function parseLaunchStartResult(launchResult) {
  let payload = null;
  if (isRecord(launchResult) && isRecord(launchResult.payload)) {
    payload = launchResult.payload;
  } else if (isRecord(launchResult) && isNonEmptyString(launchResult.stdout)) {
    try {
      payload = JSON.parse(launchResult.stdout);
    } catch {
      payload = null;
    }
  }

  if (!isRecord(payload)) {
    return {
      ok: false,
      kind: "launch-start-failed",
      message: "The admitted _stack launch-or-dispatch helper failed before usable worker-start output was produced."
    };
  }

  if (payload.ok === false) {
    const kind = isNonEmptyString(payload.kind) ? payload.kind : "launch-start-failed";
    if (!FAILURE_CODES.has(kind) || ![
      "prompt-stage-write-failed",
      "launch-start-failed",
      "worker-start-artifacts-missing",
      "malformed-worker-start-output"
    ].includes(kind)) {
      return {
        ok: false,
        kind: "malformed-worker-start-output",
        message: "The admitted _stack launch-or-dispatch helper emitted an unsupported failure contract."
      };
    }

    return {
      ok: false,
      kind,
      message: isNonEmptyString(payload.message)
        ? payload.message
        : "The admitted _stack launch-or-dispatch helper reported a bounded failure."
    };
  }

  if (
    payload.ok !== true
    || !isNonEmptyString(payload.staged_prompt_ref)
    || !isNonEmptyString(payload.worker_assignment_ref)
    || !isNonEmptyString(payload.worker_running_status_ref)
  ) {
    return {
      ok: false,
      kind: "malformed-worker-start-output",
      message: "The admitted _stack launch-or-dispatch helper omitted the expected worker-start output surface."
    };
  }

  return { ok: true, payload };
}

function buildLaunchStartArtifact({ pendingQueueMetadata, workerAssignment }) {
  return {
    staged_prompt_file_name: path.posix.basename(workerAssignment.input_handoff_refs?.[0] ?? "staged-prompt.md"),
    source_artifact_refs: pendingQueueMetadata.sourceArtifactRefs,
    worker_id: workerAssignment.worker_id,
    assignment_id: workerAssignment.assignment_id,
    tool_id: normalizeOptionalString(workerAssignment.tool_id),
    extension_id: normalizeOptionalString(workerAssignment.extension_id),
    registry_digest: normalizeOptionalString(workerAssignment.registry_digest)
  };
}

export async function runQueueOrRegistryLaunchOrDispatchCommand(argv, dependencies = {}) {
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
    stackRunnerConfigPath,
    dispatchInboxRootPath,
    dispatchLogsRootPath
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

  const resolvedStackRunnerConfig = resolveStackRunnerConfigPath(workspaceRoot, stackRunnerConfigPath);
  if (!resolvedStackRunnerConfig.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-stack-runner-config",
        failureScope: "stack-runner-config",
        message: resolvedStackRunnerConfig.message
      })
    };
  }

  const resolvedDispatchInboxRoot = resolveWorkspaceDirectoryPath(
    workspaceRoot,
    dispatchInboxRootPath,
    "--dispatch-inbox-root",
    DISPATCH_INBOX_ROOT_PREFIX
  );
  if (!resolvedDispatchInboxRoot.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-dispatch-inbox-root",
        failureScope: "dispatch-inbox-root",
        message: resolvedDispatchInboxRoot.message
      })
    };
  }

  const resolvedDispatchLogsRoot = resolveWorkspaceDirectoryPath(
    workspaceRoot,
    dispatchLogsRootPath,
    "--dispatch-logs-root",
    DISPATCH_LOGS_ROOT_PREFIX
  );
  if (!resolvedDispatchLogsRoot.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-dispatch-logs-root",
        failureScope: "dispatch-logs-root",
        message: resolvedDispatchLogsRoot.message
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

  if (!valuesMatch(pendingQueueValidation.metadata.stackLockDigest, stackLockDigestResult.stackLockDigest)) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "lineage-mismatch",
        failureScope: "lineage",
        message: "The pending queue drop stack lock digest contradicts the current workspace lock digest."
      })
    };
  }

  const runLaunchStart = dependencies.runLaunchStart || defaultRunLaunchStart;
  const launchResult = await runLaunchStart({
    workspaceRoot,
    pendingQueueDropPath: resolvedPendingQueueDrop.absolutePath,
    stackRunnerConfigPath: resolvedStackRunnerConfig.absolutePath,
    dispatchInboxRootPath: resolvedDispatchInboxRoot.absolutePath,
    dispatchLogsRootPath: resolvedDispatchLogsRoot.absolutePath
  });
  const parsedLaunchResult = parseLaunchStartResult(launchResult);
  if (!parsedLaunchResult.ok) {
    const failureCode = parsedLaunchResult.kind;
    const failureScope =
      failureCode === "prompt-stage-write-failed"
        ? "prompt-stage"
        : failureCode === "launch-start-failed"
          ? "launch-start"
          : "worker-start";
    return {
      ok: false,
      report: buildFailure({
        failureCode,
        failureScope,
        message: parsedLaunchResult.message
      })
    };
  }

  const stagedPromptResolved = resolveWorkspaceFilePath(
    workspaceRoot,
    parsedLaunchResult.payload.staged_prompt_ref,
    "staged_prompt_ref",
    "md"
  );
  const workerAssignmentResolved = resolveWorkspaceFilePath(
    workspaceRoot,
    parsedLaunchResult.payload.worker_assignment_ref,
    "worker_assignment_ref",
    "json"
  );
  const workerRunningStatusResolved = resolveWorkspaceFilePath(
    workspaceRoot,
    parsedLaunchResult.payload.worker_running_status_ref,
    "worker_running_status_ref",
    "json"
  );

  if (
    !stagedPromptResolved.ok
    || !stagedPromptResolved.normalizedRef.startsWith(`${resolvedDispatchInboxRoot.normalizedRef}/`)
    || !workerAssignmentResolved.ok
    || !workerAssignmentResolved.normalizedRef.startsWith(`${resolvedDispatchLogsRoot.normalizedRef}/`)
    || !workerRunningStatusResolved.ok
    || !workerRunningStatusResolved.normalizedRef.startsWith(`${resolvedDispatchLogsRoot.normalizedRef}/`)
  ) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-worker-start-output",
        failureScope: "worker-start",
        message: "The admitted _stack launch-or-dispatch helper emitted refs outside the admitted staged prompt or logs boundary."
      })
    };
  }

  const workerAssignmentFile = await loadJsonFile(workerAssignmentResolved.absolutePath, readText);
  if (!workerAssignmentFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "worker-start-artifacts-missing",
        failureScope: "worker-start",
        message: "The emitted worker assignment ref could not be loaded from the bounded logs root."
      })
    };
  }

  const workerRunningStatusFile = await loadJsonFile(workerRunningStatusResolved.absolutePath, readText);
  if (!workerRunningStatusFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "worker-start-artifacts-missing",
        failureScope: "worker-start",
        message: "The emitted worker running-status ref could not be loaded from the bounded logs root."
      })
    };
  }

  const assignmentValidation = validateWorkerAssignment(workerAssignmentFile.payload);
  if (!assignmentValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-worker-start-output",
        failureScope: "worker-start",
        message: assignmentValidation.message
      })
    };
  }

  const runningValidation = validateWorkerRunningStatus(workerRunningStatusFile.payload);
  if (!runningValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-worker-start-output",
        failureScope: "worker-start",
        message: runningValidation.message
      })
    };
  }

  const lineageValidation = validateWorkerStartLineage({
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

  return {
    ok: true,
    report: buildSuccess({
      normalizedPendingQueueDropRef: resolvedPendingQueueDrop.normalizedRef,
      normalizedStackRunnerConfigRef: resolvedStackRunnerConfig.normalizedRef,
      normalizedDispatchInboxRootRef: resolvedDispatchInboxRoot.normalizedRef,
      normalizedDispatchLogsRootRef: resolvedDispatchLogsRoot.normalizedRef,
      stagedPromptRef: stagedPromptResolved.normalizedRef,
      workerAssignmentRef: workerAssignmentResolved.normalizedRef,
      workerRunningStatusRef: workerRunningStatusResolved.normalizedRef,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      launchStartArtifact: buildLaunchStartArtifact({
        pendingQueueMetadata: pendingQueueValidation.metadata,
        workerAssignment: workerAssignmentFile.payload
      })
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --pending-queue-drop <relative-markdown-path> --stack-runner-config <relative-config-path> --dispatch-inbox-root <relative-inbox-root> --dispatch-logs-root <relative-logs-root> [--format text|json]`,
    "",
    "Stages one explicit pending queue drop into one bounded _stack inbox home and proves one worker-start seam only.",
    "No-completion guard: this packet may admit future implementation of one explicit launch-or-dispatch wrapper input parser, one root-relative ref normalization layer for pending-queue-drop or stack-runner-config or dispatch-inbox-root or dispatch-logs-root refs, one bounded prompt-copy staging write into the admitted repo-local inbox home, one bounded _stack runner start invocation, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or invalid-dispatch-inbox-root or invalid-dispatch-logs-root or prompt-stage-write-failed or worker-start-artifacts-missing handler, but it may not mutate or remove the original pending queue drop, move files into claimed or done queue homes, inspect ambient queue or inbox or historical log state, claim worker completion or verification success or commit success, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted _stack inbox and logs homes, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryLaunchOrDispatchCommand(argv);
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
