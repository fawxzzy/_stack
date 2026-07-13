import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const schemaPath = path.join(repoRoot, "exports", "github.event-receipt.schema.v1.json");

export const CONTRACT_VERSION = "atlas.github.event-receipt.v1";
export const SELF_CHECK_VERSION = "atlas.github.event-normalizer.self-check.v1";
export const EVENT_FAMILIES = Object.freeze([
  "repository",
  "branch",
  "pull_request",
  "issue",
  "workflow_run",
  "release",
  "security_alert"
]);
export const FACT_STATES = Object.freeze([
  "observed",
  "empty",
  "unknown",
  "access_denied",
  "disabled",
  "conflicting",
  "not_applicable"
]);
export const ERROR_CODES = Object.freeze({
  usageError: "github_event_normalizer_usage_error",
  inputRequired: "github_event_normalizer_input_required",
  invalidJson: "github_event_normalizer_invalid_json",
  secretLikeInputRejected: "github_event_normalizer_secret_like_input_rejected",
  invalidSource: "github_event_normalizer_invalid_source",
  invalidSubject: "github_event_normalizer_invalid_subject",
  invalidEvidence: "github_event_normalizer_invalid_evidence",
  missingSourceIdentity: "github_event_normalizer_missing_source_identity",
  invalidObservedAt: "github_event_normalizer_invalid_observed_at",
  unsupportedEventFamily: "github_event_normalizer_unsupported_event_family",
  unsupportedFactState: "github_event_normalizer_unsupported_fact_state",
  invalidCorrelation: "github_event_normalizer_invalid_correlation",
  schemaValidationFailed: "github_event_normalizer_schema_validation_failed",
  outputWriteFailed: "github_event_normalizer_output_write_failed"
});

const SECRET_KEYS = new Set([
  "access_key",
  "access_token",
  "api_key",
  "auth_token",
  "authorization",
  "client_secret",
  "cookie",
  "credential",
  "credentials",
  "passwd",
  "password",
  "private_key",
  "refresh_token",
  "secret",
  "token"
]);
const SECRET_VALUE_PATTERNS = [
  /github_pat_[a-zA-Z0-9_]{20,}/,
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
  /\bBearer\s+[A-Za-z0-9._-]{12,}\b/,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/
];
const ISO_UTC_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

function createReasonError(reasonCode, errors = []) {
  const error = new Error(reasonCode);
  error.reasonCode = reasonCode;
  error.errors = errors;
  return error;
}

export function loadReceiptSchema() {
  return JSON.parse(fs.readFileSync(schemaPath, "utf8"));
}

export function toCanonicalValue(value) {
  if (Array.isArray(value)) {
    return value.map((item) => toCanonicalValue(item));
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, toCanonicalValue(value[key])])
    );
  }
  return value;
}

export function canonicalStringify(value) {
  return `${JSON.stringify(toCanonicalValue(value))}\n`;
}

export function sha256(text) {
  return `sha256:${crypto.createHash("sha256").update(text, "utf8").digest("hex")}`;
}

function prefixedDigest(prefix, value) {
  return `${prefix}${crypto.createHash("sha256").update(value, "utf8").digest("hex")}`;
}

function stringifyNullableString(value) {
  return value == null ? null : String(value);
}

function normalizeInteger(value) {
  if (value == null) return null;
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (typeof value === "string" && /^\d+$/.test(value)) return Number(value);
  return value;
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isInvalidIdentityString(value) {
  return typeof value !== "string" || value.trim().length === 0 || value.trim().toLowerCase() === "undefined";
}

function assertRequiredIdentityString(value, valuePath, reasonCode) {
  if (isInvalidIdentityString(value)) {
    throw createReasonError(reasonCode, [`${valuePath} must be a non-empty string`]);
  }
}

function assertNullableIdentityString(value, valuePath, reasonCode) {
  if (value == null || value === "") {
    return;
  }
  if (typeof value !== "string" || value.trim().toLowerCase() === "undefined") {
    throw createReasonError(reasonCode, [`${valuePath} must be null or a non-empty string`]);
  }
}

function assertEvidenceRefs(refs) {
  if (!Array.isArray(refs) || refs.length < 1) {
    throw createReasonError(ERROR_CODES.invalidEvidence, ["$.evidence.refs must contain at least one string"]);
  }
  refs.forEach((value, index) => {
    if (isInvalidIdentityString(value)) {
      throw createReasonError(ERROR_CODES.invalidEvidence, [`$.evidence.refs[${index}] must be a non-empty string`]);
    }
  });
}

export function assertNoSecretLikeContent(value) {
  const queue = [{ value }];
  while (queue.length > 0) {
    const current = queue.shift().value;
    if (Array.isArray(current)) {
      for (const item of current) queue.push({ value: item });
      continue;
    }
    if (isPlainObject(current)) {
      for (const [key, child] of Object.entries(current)) {
        if (SECRET_KEYS.has(String(key).toLowerCase())) {
          throw createReasonError(ERROR_CODES.secretLikeInputRejected);
        }
        queue.push({ value: child });
      }
      continue;
    }
    if (typeof current === "string") {
      for (const pattern of SECRET_VALUE_PATTERNS) {
        if (pattern.test(current)) {
          throw createReasonError(ERROR_CODES.secretLikeInputRejected);
        }
      }
    }
  }
}

function assertUtcTimestamp(observedAt) {
  if (typeof observedAt !== "string" || !ISO_UTC_PATTERN.test(observedAt) || Number.isNaN(Date.parse(observedAt))) {
    throw createReasonError(ERROR_CODES.invalidObservedAt, ["$.observed_at must be an ISO-8601 UTC timestamp"]);
  }
}

function assertEventFamily(eventFamily) {
  if (!EVENT_FAMILIES.includes(eventFamily)) {
    throw createReasonError(ERROR_CODES.unsupportedEventFamily, [`$.event_family must be one of: ${EVENT_FAMILIES.join(", ")}`]);
  }
}

function assertFactState(factState) {
  if (!FACT_STATES.includes(factState)) {
    throw createReasonError(ERROR_CODES.unsupportedFactState, [`$.fact_state must be one of: ${FACT_STATES.join(", ")}`]);
  }
}

function assertSourceIdentity(source) {
  const deliveryId = stringifyNullableString(source.delivery_id);
  const sourceEventId = stringifyNullableString(source.source_event_id);
  if (!deliveryId && !sourceEventId) {
    throw createReasonError(ERROR_CODES.missingSourceIdentity, ["$.source.delivery_id or $.source.source_event_id is required"]);
  }
}

function assertFamilyCorrelation(eventFamily, subject, correlation) {
  const requiredCorrelationKeys = {
    repository: [],
    branch: ["branch"],
    pull_request: ["pull_request"],
    issue: ["issue"],
    workflow_run: ["workflow_run"],
    release: ["release"],
    security_alert: ["security_alert"]
  };
  if (subject.kind !== eventFamily) {
    throw createReasonError(ERROR_CODES.invalidCorrelation, [`$.subject.kind must equal ${eventFamily}`]);
  }
  if (typeof correlation.repository !== "string" || correlation.repository.length < 1) {
    throw createReasonError(ERROR_CODES.invalidCorrelation, ["$.correlation.repository must be a non-empty string"]);
  }
  for (const key of requiredCorrelationKeys[eventFamily]) {
    if (typeof correlation[key] !== "string" || correlation[key].length < 1) {
      throw createReasonError(ERROR_CODES.invalidCorrelation, [`$.correlation.${key} must be a non-empty string for ${eventFamily}`]);
    }
  }
}

function normalizeEvidenceRefs(refs) {
  return refs.map((value) => value.trim());
}

function normalizeSource(inputSource) {
  assertRequiredIdentityString(inputSource?.account, "$.source.account", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.repository?.owner, "$.source.repository.owner", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.repository?.name, "$.source.repository.name", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.event_name, "$.source.event_name", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.event_action, "$.source.event_action", ERROR_CODES.invalidSource);
  assertNullableIdentityString(inputSource?.delivery_id, "$.source.delivery_id", ERROR_CODES.invalidSource);
  assertNullableIdentityString(inputSource?.source_event_id, "$.source.source_event_id", ERROR_CODES.invalidSource);

  return {
    account: inputSource.account.trim(),
    repository: {
      owner: inputSource.repository.owner.trim(),
      name: inputSource.repository.name.trim()
    },
    delivery_id: stringifyNullableString(inputSource.delivery_id)?.trim() ?? null,
    source_event_id: stringifyNullableString(inputSource.source_event_id)?.trim() ?? null,
    event_name: inputSource.event_name.trim(),
    event_action: inputSource.event_action.trim(),
    url: stringifyNullableString(inputSource.url)
  };
}

function normalizeSubject(inputSubject) {
  assertRequiredIdentityString(inputSubject?.kind, "$.subject.kind", ERROR_CODES.invalidSubject);
  assertRequiredIdentityString(inputSubject?.id, "$.subject.id", ERROR_CODES.invalidSubject);

  return {
    kind: inputSubject.kind.trim(),
    id: inputSubject.id.trim(),
    number: normalizeInteger(inputSubject.number),
    title: stringifyNullableString(inputSubject.title),
    branch: stringifyNullableString(inputSubject.branch),
    sha: stringifyNullableString(inputSubject.sha),
    url: stringifyNullableString(inputSubject.url)
  };
}

function normalizeCorrelation(source, inputCorrelation) {
  return {
    repository: `${source.repository.owner}/${source.repository.name}`,
    branch: stringifyNullableString(inputCorrelation?.branch),
    commit: stringifyNullableString(inputCorrelation?.commit),
    pull_request: stringifyNullableString(inputCorrelation?.pull_request),
    issue: stringifyNullableString(inputCorrelation?.issue),
    workflow_run: stringifyNullableString(inputCorrelation?.workflow_run),
    release: stringifyNullableString(inputCorrelation?.release),
    security_alert: stringifyNullableString(inputCorrelation?.security_alert),
    delivery: stringifyNullableString(inputCorrelation?.delivery ?? source.delivery_id),
    source_event: stringifyNullableString(inputCorrelation?.source_event ?? source.source_event_id)
  };
}

function normalizeFacts(inputFacts = {}) {
  return {
    action: stringifyNullableString(inputFacts.action),
    state: stringifyNullableString(inputFacts.state),
    url: stringifyNullableString(inputFacts.url),
    head_branch: stringifyNullableString(inputFacts.head_branch),
    base_branch: stringifyNullableString(inputFacts.base_branch),
    head_sha: stringifyNullableString(inputFacts.head_sha),
    workflow_name: stringifyNullableString(inputFacts.workflow_name),
    run_conclusion: stringifyNullableString(inputFacts.run_conclusion),
    release_tag: stringifyNullableString(inputFacts.release_tag),
    alert_state: stringifyNullableString(inputFacts.alert_state),
    alert_severity: stringifyNullableString(inputFacts.alert_severity)
  };
}

function buildDeterministicEventIdentity(source, subject, eventFamily) {
  return canonicalStringify({
    contract_version: CONTRACT_VERSION,
    event_family: eventFamily,
    source: {
      account: source.account,
      delivery_id: source.delivery_id,
      event_action: source.event_action,
      event_name: source.event_name,
      repository: source.repository,
      source_event_id: source.source_event_id
    },
    subject: {
      id: subject.id,
      kind: subject.kind
    }
  });
}

function buildDeterministicIdempotencyIdentity(eventId) {
  return canonicalStringify({
    contract_version: CONTRACT_VERSION,
    event_id: eventId
  });
}

function resolveSchemaRef(schemaRoot, ref) {
  if (!ref.startsWith("#/")) {
    throw createReasonError(ERROR_CODES.schemaValidationFailed, [`unsupported schema ref: ${ref}`]);
  }
  return ref
    .slice(2)
    .split("/")
    .reduce((node, segment) => node?.[segment], schemaRoot);
}

function validateType(expectedType, value) {
  if (expectedType === "null") return value === null;
  if (expectedType === "array") return Array.isArray(value);
  if (expectedType === "object") return isPlainObject(value);
  if (expectedType === "integer") return Number.isInteger(value);
  return typeof value === expectedType;
}

export function validateAgainstSchema(schemaRoot, schema, value, valuePath = "$") {
  if (schema.$ref) {
    return validateAgainstSchema(schemaRoot, resolveSchemaRef(schemaRoot, schema.$ref), value, valuePath);
  }

  const errors = [];
  if ("const" in schema && value !== schema.const) {
    return [`${valuePath} must equal ${JSON.stringify(schema.const)}`];
  }
  if (schema.enum && !schema.enum.includes(value)) {
    return [`${valuePath} is not an allowed value`];
  }
  if (schema.type) {
    const expectedTypes = Array.isArray(schema.type) ? schema.type : [schema.type];
    const matched = expectedTypes.some((expectedType) => validateType(expectedType, value));
    if (!matched) {
      return [`${valuePath} must be ${expectedTypes.join(" or ")}`];
    }
  }

  if (schema.type === "object" || (Array.isArray(schema.type) && isPlainObject(value))) {
    for (const key of schema.required ?? []) {
      if (!(key in value)) errors.push(`${valuePath}.${key} is required`);
    }
    const properties = schema.properties ?? {};
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!(key in properties)) errors.push(`${valuePath}.${key} is not allowed`);
      }
    }
    for (const [key, childSchema] of Object.entries(properties)) {
      if (key in value) {
        errors.push(...validateAgainstSchema(schemaRoot, childSchema, value[key], `${valuePath}.${key}`));
      }
    }
  } else if (schema.type === "array") {
    if (schema.minItems != null && value.length < schema.minItems) {
      errors.push(`${valuePath} must contain at least ${schema.minItems} item(s)`);
    }
    if (schema.items) {
      value.forEach((item, index) => errors.push(...validateAgainstSchema(schemaRoot, schema.items, item, `${valuePath}[${index}]`)));
    }
  } else if (typeof value === "string") {
    if (schema.minLength != null && value.length < schema.minLength) {
      errors.push(`${valuePath} is too short`);
    }
    if (schema.pattern && !(new RegExp(schema.pattern).test(value))) {
      errors.push(`${valuePath} does not match the required pattern`);
    }
    if (schema.format === "date-time") {
      if (!ISO_UTC_PATTERN.test(value) || Number.isNaN(Date.parse(value))) {
        errors.push(`${valuePath} must be an ISO-8601 UTC timestamp`);
      }
    }
  }

  return errors;
}

export function validateReceipt(receipt, schema = loadReceiptSchema()) {
  return validateAgainstSchema(schema, schema, receipt);
}

export function normalizeGithubEventReceipt(input, options = {}) {
  assertNoSecretLikeContent(input);

  const eventFamily = String(input?.event_family ?? "");
  const factState = String(input?.fact_state ?? "");
  const observedAt = input?.observed_at;

  assertEventFamily(eventFamily);
  assertFactState(factState);
  assertUtcTimestamp(observedAt);

  const source = normalizeSource(input.source ?? {});
  assertSourceIdentity(source);

  const subject = normalizeSubject(input.subject ?? {});
  const correlation = normalizeCorrelation(source, input.correlation ?? {});
  assertFamilyCorrelation(eventFamily, subject, correlation);

  assertEvidenceRefs(input?.evidence?.refs);

  const payload = input.payload ?? {};
  const payloadSha256 = sha256(canonicalStringify(payload));
  const eventId = prefixedDigest("ghr_", buildDeterministicEventIdentity(source, subject, eventFamily));
  const idempotencyKey = prefixedDigest("ghk_", buildDeterministicIdempotencyIdentity(eventId));

  const receipt = {
    contract_version: CONTRACT_VERSION,
    event_id: eventId,
    idempotency_key: idempotencyKey,
    event_family: eventFamily,
    fact_state: factState,
    observed_at: observedAt,
    source,
    subject,
    correlation,
    authority: {
      operator: "_stack",
      posture: "read_only_first",
      external_mutation: "denied",
      owner_repository_truth: "preserved"
    },
    evidence: {
      refs: normalizeEvidenceRefs(input.evidence.refs)
    },
    digest: {
      algorithm: "sha256",
      payload_sha256: payloadSha256
    },
    facts: normalizeFacts(input.facts)
  };

  const schema = options.schema ?? loadReceiptSchema();
  const validationErrors = validateReceipt(receipt, schema);
  if (validationErrors.length > 0) {
    throw createReasonError(ERROR_CODES.schemaValidationFailed, validationErrors);
  }

  return receipt;
}

export function createErrorResult(reasonCode, errors = []) {
  const result = {
    ok: false,
    reason_code: reasonCode
  };
  if (errors.length > 0) {
    result.errors = errors;
  }
  return result;
}

export function createSuccessString(receipt) {
  return canonicalStringify(receipt);
}

export function createSelfCheckResult() {
  const sampleInput = {
    event_family: "pull_request",
    fact_state: "observed",
    observed_at: "2026-07-13T11:14:17Z",
    source: {
      account: "fawxzzy",
      repository: { owner: "fawxzzy", name: "_stack" },
      delivery_id: "delivery-self-check",
      source_event_id: "evt-self-check",
      event_name: "pull_request",
      event_action: "opened",
      url: "https://github.com/fawxzzy/_stack/pull/1"
    },
    subject: {
      kind: "pull_request",
      id: "pr:1",
      number: 1,
      title: "fixture",
      branch: "codex/fixture",
      sha: "abc123",
      url: "https://github.com/fawxzzy/_stack/pull/1"
    },
    correlation: {
      branch: "codex/fixture",
      commit: "abc123",
      pull_request: "1",
      issue: null,
      workflow_run: null,
      release: null,
      security_alert: null
    },
    evidence: {
      refs: ["ops/codex/AtlasContractsV2Producer.ps1"]
    },
    facts: {
      action: "opened",
      state: "open",
      url: "https://github.com/fawxzzy/_stack/pull/1",
      head_branch: "codex/fixture",
      base_branch: "main",
      head_sha: "abc123"
    },
    payload: {
      z: 1,
      a: { b: 2, a: 1 }
    }
  };

  const first = createSuccessString(normalizeGithubEventReceipt(sampleInput));
  const second = createSuccessString(
    normalizeGithubEventReceipt({
      ...sampleInput,
      payload: {
        a: { a: 1, b: 2 },
        z: 1
      }
    })
  );

  return {
    ok: true,
    contract_version: SELF_CHECK_VERSION,
    checks: {
      canonical_output_stable: first === second,
      schema_loaded: true,
      supported_event_families: [...EVENT_FAMILIES],
      supported_fact_states: [...FACT_STATES]
    }
  };
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function parseArgs(argv) {
  const args = {
    input: null,
    output: null,
    selfCheck: false
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--self-check") {
      args.selfCheck = true;
      continue;
    }
    if (token === "--input") {
      args.input = argv[index + 1] ?? null;
      index += 1;
      continue;
    }
    if (token === "--output") {
      args.output = argv[index + 1] ?? null;
      index += 1;
      continue;
    }
    throw createReasonError(ERROR_CODES.usageError, [`unknown argument: ${token}`]);
  }
  if (args.selfCheck && (args.input || args.output)) {
    throw createReasonError(ERROR_CODES.usageError, ["--self-check does not accept --input or --output"]);
  }
  if ((args.input === null && argv.includes("--input")) || (args.output === null && argv.includes("--output"))) {
    throw createReasonError(ERROR_CODES.usageError, ["--input and --output require a path argument"]);
  }
  return args;
}

async function resolveInputText(inputPath) {
  if (inputPath) {
    return fs.readFileSync(inputPath, "utf8");
  }
  const stdinText = await readStdin();
  if (stdinText.length === 0) {
    throw createReasonError(ERROR_CODES.inputRequired);
  }
  return stdinText;
}

function writeOutput(text, outputPath) {
  if (!outputPath) {
    process.stdout.write(text);
    return;
  }
  try {
    fs.writeFileSync(outputPath, text, "utf8");
  } catch {
    throw createReasonError(ERROR_CODES.outputWriteFailed);
  }
}

export async function runCli(argv = process.argv.slice(2)) {
  try {
    const args = parseArgs(argv);
    if (args.selfCheck) {
      writeOutput(canonicalStringify(createSelfCheckResult()), null);
      return 0;
    }

    const inputText = await resolveInputText(args.input);
    let parsedInput;
    try {
      parsedInput = JSON.parse(inputText);
    } catch {
      throw createReasonError(ERROR_CODES.invalidJson);
    }

    const receipt = normalizeGithubEventReceipt(parsedInput);
    writeOutput(createSuccessString(receipt), args.output);
    return 0;
  } catch (error) {
    const reasonCode = error?.reasonCode ?? ERROR_CODES.schemaValidationFailed;
    const errors = Array.isArray(error?.errors) ? error.errors : [];
    const payload = canonicalStringify(createErrorResult(reasonCode, reasonCode === ERROR_CODES.secretLikeInputRejected ? [] : errors));
    try {
      const args = (() => {
        try {
          return parseArgs(argv);
        } catch {
          return { output: null };
        }
      })();
      writeOutput(payload, args.output);
    } catch {
      process.stdout.write(payload);
    }
    return 1;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  runCli().then((exitCode) => {
    process.exitCode = exitCode;
  });
}
