#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry queue-drop-emission";
const SOURCE_COMMAND_ID = "stack queue-or-registry execution-bridge-artifacts";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_QUEUE_DROP_EMISSION_WORKSPACE_ROOT";
const STACK_LOCK_REF = "stack.lock.yaml";
const PENDING_QUEUE_ROOT_PREFIX = "repos/_stack/queue/pending";
const SUCCESS_RESULT_CLASS = "queue-drop-emitted";
const SUCCESS_ROUTING_NOTE = "explicit queue drop emitted to pending only; no claim or dispatch behavior is implied";
const FAILURE_ROUTING_NOTE = "repair explicit queue-drop contracts or lineage before wider orchestration claims";
const ADMITTED_SOURCE_RESULT_CLASSES = new Set([
  "execution-bridge-succeeded",
  "execution-bridge-blocked",
  "execution-bridge-failed"
]);
const FAILURE_CODES = new Set([
  "invalid-execution-bridge-report",
  "invalid-queue-drop-input",
  "invalid-pending-queue-root",
  "lineage-mismatch",
  "queue-drop-write-failed",
  "malformed-queue-drop-output"
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

function hasOnlyAllowedKeys(value, allowedKeys) {
  if (!isRecord(value)) {
    return false;
  }

  return Object.keys(value).every((key) => allowedKeys.has(key));
}

function isStringArray(value) {
  return Array.isArray(value) && value.every((item) => isNonEmptyString(item));
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
  normalizedExecutionBridgeReportRef,
  normalizedQueueDropInputRef,
  normalizedPendingQueueRootRef,
  emittedQueueDropRef,
  stackLockDigest,
  queueDropArtifact
}) {
  return {
    command: COMMAND_ID,
    normalized_execution_bridge_report_ref: normalizedExecutionBridgeReportRef,
    normalized_queue_drop_input_ref: normalizedQueueDropInputRef,
    normalized_pending_queue_root_ref: normalizedPendingQueueRootRef,
    emitted_queue_drop_ref: emittedQueueDropRef,
    stack_lock_digest: stackLockDigest,
    result_class: SUCCESS_RESULT_CLASS,
    routing_note: SUCCESS_ROUTING_NOTE,
    payload: {
      queue_drop_artifact: queueDropArtifact
    }
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `normalized_execution_bridge_report_ref=${result.report.normalized_execution_bridge_report_ref}`,
      `normalized_queue_drop_input_ref=${result.report.normalized_queue_drop_input_ref}`,
      `normalized_pending_queue_root_ref=${result.report.normalized_pending_queue_root_ref}`,
      `emitted_queue_drop_ref=${result.report.emitted_queue_drop_ref}`,
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
    executionBridgeReportPath: undefined,
    queueDropInputPath: undefined,
    pendingQueueRootPath: undefined
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

    if (token === "--execution-bridge-report") {
      parsed.executionBridgeReportPath = args[index + 1];
      if (!parsed.executionBridgeReportPath) {
        errors.push("--execution-bridge-report requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--queue-drop-input") {
      parsed.queueDropInputPath = args[index + 1];
      if (!parsed.queueDropInputPath) {
        errors.push("--queue-drop-input requires one bounded relative json path.");
      }
      index += 1;
      continue;
    }

    if (token === "--pending-queue-root") {
      parsed.pendingQueueRootPath = args[index + 1];
      if (!parsed.pendingQueueRootPath) {
        errors.push("--pending-queue-root requires one bounded relative queue root.");
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

function resolvePendingQueueRootPath(workspaceRoot, rawPath) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: "--pending-queue-root requires one bounded relative queue root." };
  }

  const normalizedRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedRef)) {
    return { ok: false, message: "--pending-queue-root must be a bounded relative queue root." };
  }

  const absolutePath = path.resolve(workspaceRoot, normalizedRef);
  const relativeFromRoot = normalizeRelativePath(path.relative(workspaceRoot, absolutePath));
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: "--pending-queue-root must stay within the workspace root." };
  }

  if (
    relativeFromRoot !== PENDING_QUEUE_ROOT_PREFIX
    && !relativeFromRoot.startsWith(`${PENDING_QUEUE_ROOT_PREFIX}/`)
  ) {
    return {
      ok: false,
      message: "--pending-queue-root must stay within repos/_stack/queue/pending/."
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

function extractExecutionBridgeArtifact(report) {
  if (isRecord(report?.payload) && isRecord(report.payload.execution_bridge_artifact)) {
    return report.payload.execution_bridge_artifact;
  }

  return null;
}

function validateExecutionBridgeReport(payload) {
  const report = normalizeSourceReportEnvelope(payload);
  const executionBridgeArtifact = extractExecutionBridgeArtifact(report);

  if (
    !isRecord(report)
    || report.command !== SOURCE_COMMAND_ID
    || !isNonEmptyString(report.result_class)
    || !ADMITTED_SOURCE_RESULT_CLASSES.has(report.result_class)
    || !isNonEmptyString(report.stack_lock_digest)
    || !executionBridgeArtifact
  ) {
    return {
      ok: false,
      message: "The explicit execution-bridge report is not an admitted queue-or-registry execution-bridge wrapper report."
    };
  }

  return {
    ok: true,
    report,
    executionBridgeArtifact
  };
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
      message: "Governed queue-drop input must provide both tool_id and registry_digest when governed lineage is present."
    };
  }

  return { ok: true };
}

function validateDropFileName(value) {
  if (!isNonEmptyString(value)) {
    return {
      ok: false,
      message: "The explicit queue-drop input must provide one Markdown drop_file_name."
    };
  }

  const normalizedValue = value.trim();
  if (normalizedValue !== path.posix.basename(normalizedValue) || normalizedValue.includes("\\") || path.isAbsolute(normalizedValue)) {
    return {
      ok: false,
      message: "drop_file_name must stay one local Markdown filename only."
    };
  }

  if (!normalizedValue.endsWith(".md")) {
    return {
      ok: false,
      message: "drop_file_name must point to one local Markdown file."
    };
  }

  return { ok: true };
}

function validateQueueDropInput(payload) {
  const allowedKeys = new Set([
    "drop_file_name",
    "markdown_body",
    "stack_lock_digest",
    "source_artifact_refs",
    "tool_id",
    "extension_id",
    "registry_digest"
  ]);

  if (
    !hasOnlyAllowedKeys(payload, allowedKeys)
    || !isNonEmptyString(payload.stack_lock_digest)
    || !isNonEmptyString(payload.markdown_body)
    || !isStringArray(payload.source_artifact_refs)
  ) {
    return {
      ok: false,
      message: "The explicit queue-drop input must contain only the admitted queue-drop contract fields."
    };
  }

  const fileNameValidation = validateDropFileName(payload.drop_file_name);
  if (!fileNameValidation.ok) {
    return fileNameValidation;
  }

  return validateGovernedFieldShape(payload);
}

function validateLineage({ executionBridgeReport, executionBridgeArtifact, queueDropInput, stackLockDigest }) {
  if (!valuesMatch(executionBridgeReport.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The execution-bridge report stack_lock_digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(queueDropInput.stack_lock_digest, stackLockDigest)) {
    return {
      ok: false,
      message: "The queue-drop input stack_lock_digest contradicts the current workspace lock digest."
    };
  }

  if (!valuesMatch(executionBridgeReport.stack_lock_digest, queueDropInput.stack_lock_digest)) {
    return {
      ok: false,
      message: "The execution-bridge report and queue-drop input do not agree on stack_lock_digest."
    };
  }

  for (const field of ["tool_id", "extension_id", "registry_digest"]) {
    if (!valuesMatch(executionBridgeArtifact[field], queueDropInput[field])) {
      return {
        ok: false,
        message: `The execution-bridge report and queue-drop input do not agree on ${field}.`
      };
    }
  }

  return { ok: true };
}

async function defaultWriteQueueDrop({
  workspaceRoot,
  normalizedPendingQueueRootRef,
  pendingQueueRootPath,
  dropFileName,
  markdownBody,
  sourceArtifactRefs,
  toolId,
  extensionId,
  registryDigest
}) {
  const emittedQueueDropPath = path.join(pendingQueueRootPath, dropFileName);
  const emittedQueueDropRef = `${normalizedPendingQueueRootRef}/${dropFileName}`;

  try {
    await mkdir(pendingQueueRootPath, { recursive: true });
    await writeFile(emittedQueueDropPath, markdownBody, {
      encoding: "utf8",
      flag: "wx"
    });
  } catch {
    return {
      ok: false,
      message: "The bounded pending queue writer could not emit the queue drop."
    };
  }

  return {
    ok: true,
    payload: {
      emitted_queue_drop_ref: normalizeRelativePath(path.relative(workspaceRoot, emittedQueueDropPath)),
      queue_drop_artifact: {
        drop_file_name: dropFileName,
        source_artifact_refs: sourceArtifactRefs,
        tool_id: toolId,
        extension_id: extensionId,
        registry_digest: registryDigest
      }
    }
  };
}

function parseQueueDropWriteResult(writeResult) {
  if (!writeResult?.ok) {
    return {
      ok: false,
      kind: "queue-drop-write-failed",
      message: "The bounded pending queue writer failed before the queue drop could be emitted."
    };
  }

  const payload = writeResult.payload;
  if (
    !isRecord(payload)
    || !isNonEmptyString(payload.emitted_queue_drop_ref)
    || !isRecord(payload.queue_drop_artifact)
    || !isNonEmptyString(payload.queue_drop_artifact.drop_file_name)
    || !isStringArray(payload.queue_drop_artifact.source_artifact_refs)
  ) {
    return {
      ok: false,
      kind: "malformed-queue-drop-output",
      message: "The bounded pending queue writer emitted an unusable queue-drop output contract."
    };
  }

  return { ok: true, payload };
}

export async function runQueueOrRegistryQueueDropEmissionCommand(argv, dependencies = {}) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-queue-drop-input",
        failureScope: "arguments",
        message: parsed.errors.join(" ")
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const readText = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));
  const {
    executionBridgeReportPath,
    queueDropInputPath,
    pendingQueueRootPath
  } = parsed.args;

  const resolvedExecutionBridgeReport = resolveWorkspaceJsonPath(
    workspaceRoot,
    executionBridgeReportPath,
    "--execution-bridge-report"
  );
  if (!resolvedExecutionBridgeReport.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-execution-bridge-report",
        failureScope: "execution-bridge-report",
        message: resolvedExecutionBridgeReport.message
      })
    };
  }

  const resolvedQueueDropInput = resolveWorkspaceJsonPath(workspaceRoot, queueDropInputPath, "--queue-drop-input");
  if (!resolvedQueueDropInput.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-queue-drop-input",
        failureScope: "queue-drop-input",
        message: resolvedQueueDropInput.message
      })
    };
  }

  const resolvedPendingQueueRoot = resolvePendingQueueRootPath(workspaceRoot, pendingQueueRootPath);
  if (!resolvedPendingQueueRoot.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-pending-queue-root",
        failureScope: "pending-queue-root",
        message: resolvedPendingQueueRoot.message
      })
    };
  }

  const executionBridgeReportFile = await loadJsonFile(resolvedExecutionBridgeReport.absolutePath, readText);
  if (!executionBridgeReportFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-execution-bridge-report",
        failureScope: "execution-bridge-report",
        message: executionBridgeReportFile.message
      })
    };
  }

  const executionBridgeReport = validateExecutionBridgeReport(executionBridgeReportFile.payload);
  if (!executionBridgeReport.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-execution-bridge-report",
        failureScope: "execution-bridge-report",
        message: executionBridgeReport.message
      })
    };
  }

  const queueDropInputFile = await loadJsonFile(resolvedQueueDropInput.absolutePath, readText);
  if (!queueDropInputFile.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-queue-drop-input",
        failureScope: "queue-drop-input",
        message: queueDropInputFile.message
      })
    };
  }

  const queueDropInputValidation = validateQueueDropInput(queueDropInputFile.payload);
  if (!queueDropInputValidation.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-queue-drop-input",
        failureScope: "queue-drop-input",
        message: queueDropInputValidation.message
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
    executionBridgeReport: executionBridgeReport.report,
    executionBridgeArtifact: executionBridgeReport.executionBridgeArtifact,
    queueDropInput: queueDropInputFile.payload,
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

  const writeQueueDrop = dependencies.writeQueueDrop || defaultWriteQueueDrop;
  const writeResult = await writeQueueDrop({
    workspaceRoot,
    normalizedPendingQueueRootRef: resolvedPendingQueueRoot.normalizedRef,
    pendingQueueRootPath: resolvedPendingQueueRoot.absolutePath,
    dropFileName: queueDropInputFile.payload.drop_file_name,
    markdownBody: queueDropInputFile.payload.markdown_body,
    sourceArtifactRefs: queueDropInputFile.payload.source_artifact_refs,
    toolId: normalizeOptionalString(queueDropInputFile.payload.tool_id),
    extensionId: normalizeOptionalString(queueDropInputFile.payload.extension_id),
    registryDigest: normalizeOptionalString(queueDropInputFile.payload.registry_digest)
  });
  const parsedWriteResult = parseQueueDropWriteResult(writeResult);
  if (!parsedWriteResult.ok) {
    const failureCode =
      parsedWriteResult.kind === "queue-drop-write-failed"
        ? "queue-drop-write-failed"
        : "malformed-queue-drop-output";
    return {
      ok: false,
      report: buildFailure({
        failureCode,
        failureScope: "queue-drop-output",
        message: parsedWriteResult.message
      })
    };
  }

  const expectedQueueDropRef = `${resolvedPendingQueueRoot.normalizedRef}/${queueDropInputFile.payload.drop_file_name}`;
  if (parsedWriteResult.payload.emitted_queue_drop_ref !== expectedQueueDropRef) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-queue-drop-output",
        failureScope: "queue-drop-output",
        message: "The bounded pending queue writer emitted an unexpected queue-drop ref."
      })
    };
  }

  return {
    ok: true,
    report: buildSuccess({
      normalizedExecutionBridgeReportRef: resolvedExecutionBridgeReport.normalizedRef,
      normalizedQueueDropInputRef: resolvedQueueDropInput.normalizedRef,
      normalizedPendingQueueRootRef: resolvedPendingQueueRoot.normalizedRef,
      emittedQueueDropRef: parsedWriteResult.payload.emitted_queue_drop_ref,
      stackLockDigest: stackLockDigestResult.stackLockDigest,
      queueDropArtifact: parsedWriteResult.payload.queue_drop_artifact
    })
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --execution-bridge-report <relative-json-path> --queue-drop-input <relative-json-path> --pending-queue-root <relative-queue-root> [--format text|json]`,
    "",
    "Emits one explicit Markdown queue drop into one admitted pending queue home only.",
    "No-launch guard: this packet may admit future implementation of one explicit queue-drop-emission wrapper input parser, one root-relative ref normalization layer for execution-bridge-report or queue-drop-input or pending-queue-root refs, one bounded pending-queue writer only, one bounded wrapper report renderer, and one fail-closed lineage-mismatch or invalid-pending-queue-root or queue-drop-write-failed handler, but it may not inspect live queue or registry state, move files into claimed or done queue homes, launch or dispatch workers, invoke merge or pause or resume flows, mutate owner-repo surfaces outside the admitted pending queue home, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryQueueDropEmissionCommand(argv);
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
