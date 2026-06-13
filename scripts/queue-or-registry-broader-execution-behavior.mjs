#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const COMMAND_ID = "stack queue-or-registry broader-execution-behavior";
const WORKSPACE_ROOT_ENV = "STACK_QUEUE_OR_REGISTRY_BROADER_EXECUTION_BEHAVIOR_WORKSPACE_ROOT";
const PYTHON_ENV = "STACK_QUEUE_OR_REGISTRY_BROADER_EXECUTION_BEHAVIOR_PYTHON";

const MODE_CONFIG = Object.freeze({
  "draft-entry": {
    helperRef: "ops/atlas/draft_entry_scaffold.py",
    payloadKey: "draft_entry_scaffold"
  },
  "validate-entry": {
    helperRef: "ops/atlas/batch_entry_validator.py",
    payloadKey: "validation_result"
  },
  "summarize-status": {
    helperRef: "ops/atlas/entry_status_summary_renderer.py",
    payloadKey: "entry_status_summary"
  }
});

const ADMITTED_MODES = new Set(Object.keys(MODE_CONFIG));
const FAILURE_CODES = new Set([
  "invalid-input",
  "unsupported-mode",
  "helper-failed",
  "malformed-helper-output"
]);
const VALIDATOR_RESULTS = new Set([
  "valid",
  "invalid-input",
  "invalid-missing-field",
  "invalid-status",
  "invalid-optional-field",
  "invalid-owner-boundary",
  "invalid-target-boundary",
  "invalid-protected-surface-exclusion"
]);

const ROUTING_NOTES = Object.freeze({
  draftNeedsFields: "complete required candidate-entry fields before validator input",
  validCandidate: "candidate entry is valid for explicit local handoff packaging only",
  repairCandidate: "repair candidate entry boundary or field failures before wider execution claims",
  reviewSummary: "review explicit local summary only; no launch or queue behavior is implied",
  invalidInput: "repair the explicit local input payload before broader execution behavior packaging",
  unsupportedMode: "use one admitted mode only: draft-entry, validate-entry, or summarize-status",
  helperFailed: "repair the admitted ATLAS helper execution before broader execution behavior claims",
  malformedHelperOutput: "repair the admitted ATLAS helper output contract before broader execution behavior claims"
});

const PYTHON_BRIDGE = `
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
mode = sys.argv[2]
input_path = Path(sys.argv[3]).resolve()

if str(root) not in sys.path:
    sys.path.insert(0, str(root))

try:
    if mode == "draft-entry":
        from ops.atlas.draft_entry_scaffold import run_scaffold
        payload = run_scaffold(input_path=input_path).to_payload()
    elif mode == "validate-entry":
        from ops.atlas.batch_entry_validator import run_validator
        payload = run_validator(input_path=input_path, root=root).to_payload()
    elif mode == "summarize-status":
        from ops.atlas.entry_status_summary_renderer import run_summary
        payload = run_summary(input_path=input_path).to_payload()
    else:
        raise RuntimeError(f"unsupported mode bridge request: {mode}")
except Exception as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)

print(json.dumps(payload))
`;

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function normalizeRelativePath(value) {
  return value.trim().replaceAll("\\", "/");
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

function buildSuccess({ mode, normalizedInputRef, sourceHelperRef, resultClass, routingNote, payload }) {
  return {
    command: COMMAND_ID,
    mode,
    normalized_input_ref: normalizedInputRef,
    source_helper_ref: sourceHelperRef,
    result_class: resultClass,
    routing_note: routingNote,
    payload
  };
}

function renderText(result) {
  if (result.ok) {
    return [
      `mode=${result.report.mode}`,
      `normalized_input_ref=${result.report.normalized_input_ref}`,
      `source_helper_ref=${result.report.source_helper_ref}`,
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
    mode: undefined,
    inputPath: undefined
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

    if (token === "--mode") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--mode requires one admitted mode.");
      } else {
        parsed.mode = value;
      }
      index += 1;
      continue;
    }

    if (token === "--input") {
      const value = args[index + 1];
      if (!value) {
        errors.push("--input requires one bounded relative json path.");
      } else {
        parsed.inputPath = value;
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

function resolveInputPath(workspaceRoot, rawPath) {
  if (!isNonEmptyString(rawPath)) {
    return { ok: false, message: "--input requires one bounded relative json path." };
  }

  const normalizedInputRef = normalizeRelativePath(rawPath);
  if (path.isAbsolute(normalizedInputRef)) {
    return { ok: false, message: "--input must be a bounded relative json path." };
  }

  if (!normalizedInputRef.endsWith(".json")) {
    return { ok: false, message: "--input must point to one explicit local json file." };
  }

  const resolvedPath = path.resolve(workspaceRoot, normalizedInputRef);
  const relativeFromRoot = path.relative(workspaceRoot, resolvedPath);
  if (relativeFromRoot.startsWith("..") || path.isAbsolute(relativeFromRoot)) {
    return { ok: false, message: "--input must stay within the workspace root." };
  }

  return {
    ok: true,
    normalizedInputRef: normalizeRelativePath(relativeFromRoot),
    absolutePath: resolvedPath
  };
}

async function loadExplicitInput({ absolutePath, mode, readText }) {
  let inputText;
  try {
    inputText = await readText(absolutePath);
  } catch (error) {
    const message =
      error && typeof error === "object" && "code" in error && error.code === "ENOENT"
        ? "The explicit local input file does not exist."
        : "The explicit local input file could not be loaded.";
    return { ok: false, message };
  }

  let payload;
  try {
    payload = JSON.parse(inputText);
  } catch {
    return { ok: false, message: "The explicit local input file is not valid json." };
  }

  if (mode === "draft-entry" || mode === "validate-entry") {
    if (Array.isArray(payload) || !isRecord(payload)) {
      return { ok: false, message: `${mode} input must be one explicit json object.` };
    }
  }

  if (mode === "summarize-status") {
    if (!Array.isArray(payload) || payload.length === 0) {
      return { ok: false, message: "summarize-status input must be one non-empty ordered json list." };
    }
  }

  return { ok: true, payload };
}

async function defaultRunHelper({ workspaceRoot, mode, inputPath }) {
  const pythonCommand = process.env[PYTHON_ENV] || "python";

  return new Promise((resolve) => {
    const child = spawn(
      pythonCommand,
      ["-c", PYTHON_BRIDGE, workspaceRoot, mode, inputPath],
      {
        cwd: workspaceRoot,
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

function parseHelperOutput(helperResult) {
  if (!helperResult.ok) {
    return {
      ok: false,
      kind: "helper-failed",
      message: "The admitted ATLAS helper failed before broader execution behavior packaging could complete."
    };
  }

  let payload;
  try {
    payload = JSON.parse(helperResult.stdout);
  } catch {
    return {
      ok: false,
      kind: "malformed-helper-output",
      message: "The admitted ATLAS helper emitted non-json output."
    };
  }

  return { ok: true, payload };
}

function hasExactKeys(value, expectedKeys) {
  return (
    isRecord(value)
    && Object.keys(value).length === expectedKeys.length
    && expectedKeys.every((key) => Object.prototype.hasOwnProperty.call(value, key))
  );
}

function isStringArray(value) {
  return Array.isArray(value) && value.every((item) => isNonEmptyString(item));
}

function validateDraftHelperPayload(payload) {
  if (!hasExactKeys(payload, ["candidate_entry", "missing_required_fields", "validator_readiness_note"])) {
    return null;
  }

  if (
    !isRecord(payload.candidate_entry)
    || !isStringArray(payload.missing_required_fields)
    || !isNonEmptyString(payload.validator_readiness_note)
  ) {
    return null;
  }

  return buildSuccess({
    mode: "draft-entry",
    normalizedInputRef: null,
    sourceHelperRef: null,
    resultClass: "draft-scaffold-rendered",
    routingNote:
      payload.missing_required_fields.length > 0 ? ROUTING_NOTES.draftNeedsFields : ROUTING_NOTES.validCandidate,
    payload: {
      draft_entry_scaffold: payload
    }
  });
}

function validateValidationHelperPayload(payload) {
  if (!isRecord(payload) || !isNonEmptyString(payload.result) || !VALIDATOR_RESULTS.has(payload.result)) {
    return null;
  }

  const isValid = payload.result === "valid";
  return buildSuccess({
    mode: "validate-entry",
    normalizedInputRef: null,
    sourceHelperRef: null,
    resultClass: isValid ? "candidate-entry-valid" : "candidate-entry-invalid",
    routingNote: isValid ? ROUTING_NOTES.validCandidate : ROUTING_NOTES.repairCandidate,
    payload: {
      validation_result: payload
    }
  });
}

function validateSummaryEntry(entry) {
  return (
    isRecord(entry)
    && isNonEmptyString(entry.entry_id)
    && isNonEmptyString(entry.status)
    && isNonEmptyString(entry.readiness_route)
    && Number.isInteger(entry.missing_required_fields_count)
    && entry.missing_required_fields_count >= 0
  );
}

function isCountRecord(value) {
  return isRecord(value) && Object.values(value).every((count) => Number.isInteger(count) && count >= 0);
}

function validateSummaryHelperPayload(payload) {
  if (
    !hasExactKeys(payload, ["entries", "entry_count", "status_counts", "readiness_counts"])
    || !Array.isArray(payload.entries)
    || !payload.entries.every((entry) => validateSummaryEntry(entry))
    || !Number.isInteger(payload.entry_count)
    || payload.entry_count !== payload.entries.length
    || payload.entry_count < 1
    || !isCountRecord(payload.status_counts)
    || !isCountRecord(payload.readiness_counts)
  ) {
    return null;
  }

  return buildSuccess({
    mode: "summarize-status",
    normalizedInputRef: null,
    sourceHelperRef: null,
    resultClass: "status-summary-rendered",
    routingNote: ROUTING_NOTES.reviewSummary,
    payload: {
      entry_status_summary: payload
    }
  });
}

function mapHelperPayload(mode, payload) {
  if (mode === "draft-entry") {
    return validateDraftHelperPayload(payload);
  }
  if (mode === "validate-entry") {
    return validateValidationHelperPayload(payload);
  }
  if (mode === "summarize-status") {
    return validateSummaryHelperPayload(payload);
  }
  return null;
}

export async function runQueueOrRegistryBroaderExecutionBehaviorCommand(argv, dependencies = {}) {
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

  const { mode, inputPath } = parsed.args;
  if (!ADMITTED_MODES.has(mode)) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "unsupported-mode",
        failureScope: "mode",
        message: "Use one admitted mode only: draft-entry, validate-entry, or summarize-status.",
        routingNote: ROUTING_NOTES.unsupportedMode
      })
    };
  }

  const workspaceRoot = dependencies.workspaceRoot || getWorkspaceRoot();
  const resolvedInput = resolveInputPath(workspaceRoot, inputPath);
  if (!resolvedInput.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-input",
        failureScope: "input",
        message: resolvedInput.message,
        routingNote: ROUTING_NOTES.invalidInput
      })
    };
  }

  const readText = dependencies.readText || ((filePath) => readFile(filePath, "utf8"));
  const explicitInput = await loadExplicitInput({
    absolutePath: resolvedInput.absolutePath,
    mode,
    readText
  });
  if (!explicitInput.ok) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "invalid-input",
        failureScope: "input",
        message: explicitInput.message,
        routingNote: ROUTING_NOTES.invalidInput
      })
    };
  }

  const helperConfig = MODE_CONFIG[mode];
  const runHelper = dependencies.runHelper || defaultRunHelper;
  const helperResult = await runHelper({
    workspaceRoot,
    mode,
    inputPath: resolvedInput.absolutePath,
    helperRef: helperConfig.helperRef
  });
  const parsedHelper = parseHelperOutput(helperResult);
  if (!parsedHelper.ok) {
    const failureCode = parsedHelper.kind === "helper-failed" ? "helper-failed" : "malformed-helper-output";
    const routingNote =
      parsedHelper.kind === "helper-failed" ? ROUTING_NOTES.helperFailed : ROUTING_NOTES.malformedHelperOutput;
    return {
      ok: false,
      report: buildFailure({
        failureCode,
        failureScope: "helper",
        message: parsedHelper.message,
        routingNote
      })
    };
  }

  const successReport = mapHelperPayload(mode, parsedHelper.payload);
  if (!successReport) {
    return {
      ok: false,
      report: buildFailure({
        failureCode: "malformed-helper-output",
        failureScope: "helper",
        message: "The admitted ATLAS helper omitted or malformed the expected top-level output surface.",
        routingNote: ROUTING_NOTES.malformedHelperOutput
      })
    };
  }

  successReport.normalized_input_ref = resolvedInput.normalizedInputRef;
  successReport.source_helper_ref = helperConfig.helperRef;
  return {
    ok: true,
    report: successReport
  };
}

function usage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --mode <draft-entry|validate-entry|summarize-status> --input <relative-json-path> [--format text|json]`,
    "",
    "Packages one bounded broader-execution-behavior report from one explicit local JSON input by delegating to one admitted ATLAS helper only.",
    "No-execution guard: this packet may admit future implementation of one explicit broader-execution-behavior wrapper input parser, one root-relative path normalization layer, one exact mode dispatcher for draft-entry, validate-entry, and summarize-status, one delegated helper invocation layer for admitted ATLAS root helpers only, one bounded wrapper report renderer, and one fail-closed unsupported-mode or helper-failure handler, but it may not inspect live queue or registry state, emit queue drops or worker artifacts, launch or resume or merge workers, mutate markers or receipts or owner repos, or imply lifecycle advancement, deploy readiness, or publication proof."
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const result = await runQueueOrRegistryBroaderExecutionBehaviorCommand(argv);
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
