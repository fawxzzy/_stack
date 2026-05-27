import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SENSITIVITY_LABELS = new Set(["public", "internal", "sensitive", "restricted"]);
const DOWNSTREAM_TARGET_CLASSES = new Set([
  "human-review",
  "model",
  "api",
  "saas-tool",
  "remote-database",
  "automation-helper",
  "cross-repo-handoff"
]);
const VALIDATION_RESULTS = new Set(["pass", "fail"]);
const REDACTION_STATUSES = new Set(["not_needed", "applied", "required_but_missing"]);
const DEDUPE_STATUSES = new Set(["not_needed", "applied", "required_but_missing"]);
const SOURCE_TYPES = new Set(["export", "receipt-chain", "command-output", "local-file-set"]);

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function validateEnumField(value, allowedValues, fieldName, errors) {
  if (!isNonEmptyString(value)) {
    errors.push(`${fieldName} must be a non-empty string.`);
    return;
  }

  if (!allowedValues.has(value)) {
    errors.push(`${fieldName} must be one of: ${Array.from(allowedValues).join(", ")}.`);
  }
}

function validatePacketSchemaVersion(value, errors) {
  if (!isNonEmptyString(value)) {
    errors.push("packet_schema_version must be a non-empty string.");
    return;
  }

  if (!/^ldg\.packet\.v\d+$/.test(value.trim())) {
    errors.push("packet_schema_version must match ldg.packet.v<number>.");
  }
}

function validateSourceProvenance(value, errors) {
  if (!isRecord(value)) {
    errors.push("source_provenance must be an object.");
    return;
  }

  if (!isNonEmptyString(value.owner_surface)) {
    errors.push("source_provenance.owner_surface must be a non-empty string.");
  }

  validateEnumField(value.source_type, SOURCE_TYPES, "source_provenance.source_type", errors);

  if (!Array.isArray(value.source_refs)) {
    errors.push("source_provenance.source_refs must be an array.");
  } else if (value.source_refs.some((item) => !isNonEmptyString(item))) {
    errors.push("source_provenance.source_refs entries must be non-empty strings.");
  }

  if (!isNonEmptyString(value.captured_at)) {
    errors.push("source_provenance.captured_at must be a non-empty string.");
  }

  if (!isNonEmptyString(value.capture_method)) {
    errors.push("source_provenance.capture_method must be a non-empty string.");
  }
}

function validateTransformationRecord(value, errors) {
  if (!isRecord(value)) {
    errors.push("transformation_record must be an object.");
    return;
  }

  const booleanFields = [
    "normalized",
    "validated",
    "redacted",
    "sensitivity_classified",
    "deduped",
    "extracted"
  ];

  for (const fieldName of booleanFields) {
    if (typeof value[fieldName] !== "boolean") {
      errors.push(`transformation_record.${fieldName} must be a boolean.`);
    }
  }

  if (!Array.isArray(value.notes)) {
    errors.push("transformation_record.notes must be an array.");
  } else if (value.notes.some((item) => !isNonEmptyString(item))) {
    errors.push("transformation_record.notes entries must be non-empty strings.");
  }
}

function validateMinimalUsefulPayload(value, errors) {
  if (value === undefined) {
    errors.push("minimal_useful_payload is required.");
    return;
  }

  if (value === null) {
    errors.push("minimal_useful_payload must not be null.");
  }
}

function validateOptionalExclusionSummary(value, errors) {
  if (value === undefined) {
    return;
  }

  if (!isRecord(value)) {
    errors.push("export_exclusion_summary must be an object when provided.");
    return;
  }

  if (!Array.isArray(value.omitted_classes)) {
    errors.push("export_exclusion_summary.omitted_classes must be an array.");
  } else if (value.omitted_classes.some((item) => !isNonEmptyString(item))) {
    errors.push("export_exclusion_summary.omitted_classes entries must be non-empty strings.");
  }

  if (!isNonEmptyString(value.reason)) {
    errors.push("export_exclusion_summary.reason must be a non-empty string.");
  }
}

function validateOptionalReceiptRef(value, errors) {
  if (value === undefined) {
    return;
  }

  if (!isNonEmptyString(value)) {
    errors.push("receipt_or_proof_ref must be a non-empty string when provided.");
  }
}

export function validateGatewayPacket(packet) {
  const errors = [];

  if (!isRecord(packet)) {
    return {
      ok: false,
      errors: ["Packet must be a JSON object."]
    };
  }

  if (!isNonEmptyString(packet.packet_purpose)) {
    errors.push("packet_purpose must be a non-empty string.");
  }

  validatePacketSchemaVersion(packet.packet_schema_version, errors);
  validateEnumField(packet.sensitivity_label, SENSITIVITY_LABELS, "sensitivity_label", errors);
  validateEnumField(packet.downstream_target_class, DOWNSTREAM_TARGET_CLASSES, "downstream_target_class", errors);
  validateSourceProvenance(packet.source_provenance, errors);
  validateTransformationRecord(packet.transformation_record, errors);
  validateEnumField(packet.validation_result, VALIDATION_RESULTS, "validation_result", errors);
  validateEnumField(packet.redaction_status, REDACTION_STATUSES, "redaction_status", errors);
  validateEnumField(packet.dedupe_status, DEDUPE_STATUSES, "dedupe_status", errors);
  validateMinimalUsefulPayload(packet.minimal_useful_payload, errors);
  validateOptionalExclusionSummary(packet.export_exclusion_summary, errors);
  validateOptionalReceiptRef(packet.receipt_or_proof_ref, errors);

  return {
    ok: errors.length === 0,
    errors
  };
}

export async function loadPacketFromFile(filePath) {
  const text = await fs.readFile(filePath, "utf8");
  return JSON.parse(text);
}

export async function runPacketValidation(filePath) {
  const packet = await loadPacketFromFile(filePath);
  return validateGatewayPacket(packet);
}

function formatUsage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --input <packet.json>`,
    "",
    "Validates Local Data Gateway packet fields only.",
    "No emit, send, transform, or remote behavior is performed."
  ].join("\n");
}

async function main(argv) {
  const args = [...argv];

  if (args.includes("--help") || args.includes("-h")) {
    console.log(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const inputIndex = args.indexOf("--input");
  if (inputIndex === -1 || !args[inputIndex + 1]) {
    console.error("Missing required --input <packet.json> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  const inputPath = path.resolve(process.cwd(), args[inputIndex + 1]);

  try {
    const result = await runPacketValidation(inputPath);
    if (result.ok) {
      console.log(JSON.stringify({
        ok: true,
        input: inputPath,
        errors: []
      }, null, 2));
      return 0;
    }

    console.error(JSON.stringify({
      ok: false,
      input: inputPath,
      errors: result.errors
    }, null, 2));
    return 1;
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      input: inputPath,
      errors: [error instanceof Error ? error.message : String(error)]
    }, null, 2));
    return 1;
  }
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  const exitCode = await main(process.argv.slice(2));
  process.exit(exitCode);
}
