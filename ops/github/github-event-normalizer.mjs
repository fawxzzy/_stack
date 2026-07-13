import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");

export const CONTRACT_VERSION = "atlas.github.event-receipt.v1";
export const SELF_CHECK_VERSION = "atlas.github.event-normalizer.self-check.v1";
export const ACCEPTED_ATLAS_CONTRACT_COMMIT = "e05019c88f696f4efd8cdb02719e0505f3b0d64a";
export const ACCEPTED_CANONICAL_SCHEMA_SHA256 = "5c4d7ec4e5d7f566ecc3f3d91fbc3344eae513acd7cbab528a0305c7953c303d";
export const ATLAS_OWNER_REPOSITORY = "ATLAS";
export const ATLAS_OWNER_REF = "root-commit";
export const CANONICAL_SCHEMA_RELATIVE_PATH = path.join(
  "packages",
  "atlas-contracts",
  "schemas",
  "atlas.github.event-receipt.v1.schema.json"
);
export const MIRROR_SCHEMA_RELATIVE_PATH = path.join("exports", "github.event-receipt.schema.v1.json");
export const MIRROR_PROVENANCE_RELATIVE_PATH = path.join("exports", "github.event-receipt.provenance.v1.json");
export const SCHEMA_SOURCE = Object.freeze({
  explicit: "explicit",
  atlasSiblingCanonical: "atlas_sibling_canonical",
  mirrorFallback: "repo_local_mirror"
});
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
  explicitSchemaMissing: "github_event_normalizer_explicit_schema_missing",
  explicitSchemaInvalid: "github_event_normalizer_explicit_schema_invalid",
  canonicalSchemaMissing: "github_event_normalizer_canonical_schema_missing",
  canonicalSchemaInvalid: "github_event_normalizer_canonical_schema_invalid",
  canonicalSchemaDigestMismatch: "github_event_normalizer_canonical_schema_digest_mismatch",
  mirrorSchemaMissing: "github_event_normalizer_mirror_schema_missing",
  mirrorProvenanceMissing: "github_event_normalizer_mirror_provenance_missing",
  mirrorProvenanceInvalid: "github_event_normalizer_mirror_provenance_invalid",
  mirrorDigestMismatch: "github_event_normalizer_mirror_digest_mismatch",
  schemaValidationFailed: "github_event_normalizer_schema_validation_failed",
  outputWriteFailed: "github_event_normalizer_output_write_failed"
});

const mirrorSchemaPath = path.join(repoRoot, MIRROR_SCHEMA_RELATIVE_PATH);
const mirrorProvenancePath = path.join(repoRoot, MIRROR_PROVENANCE_RELATIVE_PATH);
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
const GITHUB_EVENT_ID_PATTERN = /^ghr_[a-z0-9][a-z0-9_-]*$/;
const REQUIRED_CANONICAL_SCHEMA_FIELDS = Object.freeze([
  "contract_version",
  "event_id",
  "idempotency_key",
  "observed_at",
  "event_family",
  "fact_state",
  "source",
  "subject",
  "correlation",
  "evidence_refs",
  "digest",
  "normalized_facts",
  "authority"
]);

function createReasonError(reasonCode, errors = []) {
  const error = new Error(reasonCode);
  error.reasonCode = reasonCode;
  error.errors = errors;
  return error;
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function toPosixPath(value) {
  return String(value).replaceAll("\\", "/");
}

function sha256Hex(text) {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex");
}

export function sha256(text) {
  return `sha256:${sha256Hex(text)}`;
}

function prefixedDigest(prefix, value) {
  return `${prefix}${sha256Hex(value)}`;
}

export function toCanonicalValue(value) {
  if (Array.isArray(value)) {
    return value.map((item) => toCanonicalValue(item));
  }
  if (isPlainObject(value)) {
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

function pathExists(filePath) {
  return fs.existsSync(filePath);
}

function readJsonFile(filePath, reasonCode) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    throw createReasonError(reasonCode, [`${toPosixPath(filePath)} could not be parsed as JSON`]);
  }
}

function stringifyNullableString(value) {
  return value == null ? null : String(value);
}

function normalizeNullableString(value) {
  if (value == null) return null;
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeInteger(value) {
  if (value == null) return null;
  if (typeof value === "number" && Number.isInteger(value)) return value;
  if (typeof value === "string" && /^\d+$/.test(value)) return Number(value);
  return value;
}

function normalizeFactValue(value) {
  if (value == null) return null;
  return String(value).trim();
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

function assertNoSecretLikeContent(value) {
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

export { assertNoSecretLikeContent };

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
  if (!source.delivery_id && !source.source_event_id) {
    throw createReasonError(ERROR_CODES.missingSourceIdentity, ["$.source.delivery_id or $.source.source_event_id is required"]);
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

  if (correlation.parent_event_id != null && !GITHUB_EVENT_ID_PATTERN.test(correlation.parent_event_id)) {
    throw createReasonError(ERROR_CODES.invalidCorrelation, ["$.correlation.parent_event_id must be a ghr_* identifier or null"]);
  }
}

function normalizeSource(inputSource) {
  assertRequiredIdentityString(inputSource?.account, "$.source.account", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.repository?.owner, "$.source.repository.owner", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.repository?.name, "$.source.repository.name", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.event_name, "$.source.event_name", ERROR_CODES.invalidSource);
  assertRequiredIdentityString(inputSource?.event_action, "$.source.event_action", ERROR_CODES.invalidSource);
  assertNullableIdentityString(inputSource?.repository?.id, "$.source.repository.id", ERROR_CODES.invalidSource);
  assertNullableIdentityString(inputSource?.delivery_id, "$.source.delivery_id", ERROR_CODES.invalidSource);
  assertNullableIdentityString(inputSource?.source_event_id, "$.source.source_event_id", ERROR_CODES.invalidSource);
  assertNullableIdentityString(inputSource?.url, "$.source.url", ERROR_CODES.invalidSource);
  assertNullableIdentityString(inputSource?.endpoint, "$.source.endpoint", ERROR_CODES.invalidSource);

  return {
    account: inputSource.account.trim(),
    repository: {
      owner: inputSource.repository.owner.trim(),
      name: inputSource.repository.name.trim(),
      id: normalizeNullableString(inputSource.repository.id)
    },
    delivery_id: normalizeNullableString(inputSource.delivery_id),
    source_event_id: normalizeNullableString(inputSource.source_event_id),
    event_name: inputSource.event_name.trim(),
    event_action: inputSource.event_action.trim(),
    url: normalizeNullableString(inputSource.url),
    endpoint: normalizeNullableString(inputSource.endpoint)
  };
}

function normalizeSubject(inputSubject) {
  assertRequiredIdentityString(inputSubject?.kind, "$.subject.kind", ERROR_CODES.invalidSubject);
  assertRequiredIdentityString(inputSubject?.id, "$.subject.id", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.repository, "$.subject.repository", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.repository_id, "$.subject.repository_id", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.entity_id, "$.subject.entity_id", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.entity_ref, "$.subject.entity_ref", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.title, "$.subject.title", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.branch, "$.subject.branch", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.sha, "$.subject.sha", ERROR_CODES.invalidSubject);
  assertNullableIdentityString(inputSubject?.url, "$.subject.url", ERROR_CODES.invalidSubject);

  return {
    kind: inputSubject.kind.trim(),
    id: inputSubject.id.trim(),
    number: normalizeInteger(inputSubject.number),
    title: normalizeNullableString(inputSubject.title),
    branch: normalizeNullableString(inputSubject.branch),
    sha: normalizeNullableString(inputSubject.sha),
    url: normalizeNullableString(inputSubject.url),
    repository: normalizeNullableString(inputSubject.repository),
    repository_id: normalizeNullableString(inputSubject.repository_id),
    entity_id: normalizeNullableString(inputSubject.entity_id),
    entity_ref: normalizeNullableString(inputSubject.entity_ref)
  };
}

function normalizeCorrelation(source, inputCorrelation) {
  return {
    repository: `${source.repository.owner}/${source.repository.name}`,
    branch: normalizeNullableString(inputCorrelation?.branch),
    commit: normalizeNullableString(inputCorrelation?.commit),
    pull_request: normalizeNullableString(inputCorrelation?.pull_request),
    issue: normalizeNullableString(inputCorrelation?.issue),
    workflow_run: normalizeNullableString(inputCorrelation?.workflow_run),
    release: normalizeNullableString(inputCorrelation?.release),
    security_alert: normalizeNullableString(inputCorrelation?.security_alert),
    delivery: normalizeNullableString(inputCorrelation?.delivery ?? source.delivery_id),
    source_event: normalizeNullableString(inputCorrelation?.source_event ?? source.source_event_id),
    source_run_id: normalizeNullableString(inputCorrelation?.source_run_id ?? inputCorrelation?.workflow_run),
    atlas_job_id: normalizeNullableString(inputCorrelation?.atlas_job_id),
    parent_event_id: normalizeNullableString(inputCorrelation?.parent_event_id)
  };
}

function normalizeEvidenceRefs(refs) {
  return refs.map((value) => value.trim());
}

function normalizeFacts(inputFacts = {}) {
  return {
    action: normalizeNullableString(inputFacts.action),
    state: normalizeNullableString(inputFacts.state),
    url: normalizeNullableString(inputFacts.url),
    head_branch: normalizeNullableString(inputFacts.head_branch),
    base_branch: normalizeNullableString(inputFacts.base_branch),
    head_sha: normalizeNullableString(inputFacts.head_sha),
    workflow_name: normalizeNullableString(inputFacts.workflow_name),
    run_conclusion: normalizeNullableString(inputFacts.run_conclusion),
    release_tag: normalizeNullableString(inputFacts.release_tag),
    alert_state: normalizeNullableString(inputFacts.alert_state),
    alert_severity: normalizeNullableString(inputFacts.alert_severity)
  };
}

function findAtlasRootFromRepoRoot(startDir) {
  let current = path.resolve(startDir);
  while (true) {
    if (path.basename(current) === "_stack" && path.basename(path.dirname(current)) === "repos") {
      return path.dirname(path.dirname(current));
    }
    const parent = path.dirname(current);
    if (parent === current) {
      return null;
    }
    current = parent;
  }
}

function isPathInside(basePath, filePath) {
  const relativePath = path.relative(basePath, filePath);
  return relativePath !== "" && !relativePath.startsWith("..") && !path.isAbsolute(relativePath);
}

function reportPath(filePath, atlasRoot = null) {
  if (atlasRoot && (filePath === atlasRoot || isPathInside(atlasRoot, filePath))) {
    return toPosixPath(path.relative(atlasRoot, filePath) || ".");
  }
  if (filePath === repoRoot || isPathInside(repoRoot, filePath)) {
    return toPosixPath(path.relative(repoRoot, filePath) || ".");
  }
  return path.basename(filePath);
}

function loadCompatibleSchemaFromPath(filePath, reasonCode) {
  const schema = readJsonFile(filePath, reasonCode);
  assertCompatibleReceiptSchema(schema, reasonCode);
  return schema;
}

function assertCompatibleReceiptSchema(schema, reasonCode) {
  if (!isPlainObject(schema)) {
    throw createReasonError(reasonCode, ["schema root must be an object"]);
  }
  if (schema.properties?.contract_version?.const !== CONTRACT_VERSION) {
    throw createReasonError(reasonCode, [`schema must declare contract_version ${CONTRACT_VERSION}`]);
  }
  const requiredFields = Array.isArray(schema.required) ? schema.required : [];
  for (const field of REQUIRED_CANONICAL_SCHEMA_FIELDS) {
    if (!requiredFields.includes(field)) {
      throw createReasonError(reasonCode, [`schema is missing required field ${field}`]);
    }
  }
  if (schema.properties?.normalized_facts?.type !== "array") {
    throw createReasonError(reasonCode, ["schema.normalized_facts must be an array"]);
  }
  if (schema.properties?.authority?.$ref !== "#/$defs/authority") {
    throw createReasonError(reasonCode, ["schema.authority must resolve through #/$defs/authority"]);
  }
  if (schema.$defs?.authority?.properties?.producer?.const !== "_stack") {
    throw createReasonError(reasonCode, ["schema authority producer must remain _stack"]);
  }
}

function inspectMirrorStatus() {
  const status = {
    schema_path: toPosixPath(MIRROR_SCHEMA_RELATIVE_PATH),
    provenance_path: toPosixPath(MIRROR_PROVENANCE_RELATIVE_PATH),
    present: pathExists(mirrorSchemaPath),
    provenance_present: pathExists(mirrorProvenancePath),
    digest: null,
    digest_matches_canonical: false,
    provenance_valid: false,
    fallback_only_for: "isolated_stack_ci"
  };

  if (status.present) {
    status.digest = sha256(fs.readFileSync(mirrorSchemaPath, "utf8"));
    status.digest_matches_canonical = status.digest === `sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`;
  }

  if (status.provenance_present) {
    try {
      const provenance = JSON.parse(fs.readFileSync(mirrorProvenancePath, "utf8"));
      status.provenance_valid = isValidMirrorProvenance(provenance, status.digest);
    } catch {
      status.provenance_valid = false;
    }
  }

  return status;
}

function isValidMirrorProvenance(provenance, mirrorDigest) {
  return isPlainObject(provenance)
    && provenance.contract_id === CONTRACT_VERSION
    && provenance.contract_version === "v1"
    && provenance.atlas_owner_repository === ATLAS_OWNER_REPOSITORY
    && provenance.atlas_owner_ref === ATLAS_OWNER_REF
    && provenance.atlas_owner_commit === ACCEPTED_ATLAS_CONTRACT_COMMIT
    && provenance.canonical_schema_path === toPosixPath(CANONICAL_SCHEMA_RELATIVE_PATH)
    && provenance.canonical_sha256 === ACCEPTED_CANONICAL_SCHEMA_SHA256
    && provenance.mirror_path === toPosixPath(MIRROR_SCHEMA_RELATIVE_PATH)
    && provenance.mirror_sha256 === ACCEPTED_CANONICAL_SCHEMA_SHA256
    && provenance.mirror_sha256 === (mirrorDigest?.replace(/^sha256:/, "") ?? null)
    && typeof provenance.synchronization_command === "string"
    && provenance.synchronization_command.length > 0
    && typeof provenance.deterministic_check === "string"
    && provenance.deterministic_check.length > 0
    && provenance.fallback_scope === "isolated_stack_ci_only"
    && provenance.fallback_statement === "Mirror fallback is for isolated _stack CI only.";
}

function loadMirrorSchema() {
  if (!pathExists(mirrorSchemaPath)) {
    throw createReasonError(ERROR_CODES.mirrorSchemaMissing, [toPosixPath(MIRROR_SCHEMA_RELATIVE_PATH)]);
  }
  if (!pathExists(mirrorProvenancePath)) {
    throw createReasonError(ERROR_CODES.mirrorProvenanceMissing, [toPosixPath(MIRROR_PROVENANCE_RELATIVE_PATH)]);
  }

  const mirrorDigest = sha256(fs.readFileSync(mirrorSchemaPath, "utf8"));
  const provenance = readJsonFile(mirrorProvenancePath, ERROR_CODES.mirrorProvenanceInvalid);

  if (mirrorDigest !== `sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`) {
    throw createReasonError(ERROR_CODES.mirrorDigestMismatch, ["mirror digest does not match the accepted canonical digest"]);
  }
  if (!isValidMirrorProvenance(provenance, mirrorDigest)) {
    throw createReasonError(ERROR_CODES.mirrorProvenanceInvalid, ["mirror provenance does not match the accepted canonical contract"]);
  }

  return {
    schema: loadCompatibleSchemaFromPath(mirrorSchemaPath, ERROR_CODES.mirrorProvenanceInvalid),
    source: SCHEMA_SOURCE.mirrorFallback,
    schema_path: mirrorSchemaPath,
    schema_reference: toPosixPath(MIRROR_SCHEMA_RELATIVE_PATH),
    digest: mirrorDigest,
    atlas_root: null,
    mirror_status: inspectMirrorStatus()
  };
}

export function resolveReceiptSchema(options = {}) {
  const explicitSchemaPath = normalizeNullableString(options.schemaPath);
  const atlasRoot = findAtlasRootFromRepoRoot(options.repoRoot ?? repoRoot);
  const mirrorStatus = inspectMirrorStatus();
  const schemaPathWasSupplied = Object.prototype.hasOwnProperty.call(options, "schemaPath");

  if (schemaPathWasSupplied && options.schemaPath !== undefined && explicitSchemaPath == null) {
    throw createReasonError(ERROR_CODES.explicitSchemaMissing, ["--schema requires a path"]);
  }

  if (explicitSchemaPath) {
    const resolvedSchemaPath = path.resolve(options.cwd ?? repoRoot, explicitSchemaPath);
    if (!pathExists(resolvedSchemaPath)) {
      throw createReasonError(ERROR_CODES.explicitSchemaMissing, [reportPath(resolvedSchemaPath, atlasRoot)]);
    }
    return {
      schema: loadCompatibleSchemaFromPath(resolvedSchemaPath, ERROR_CODES.explicitSchemaInvalid),
      source: SCHEMA_SOURCE.explicit,
      schema_path: resolvedSchemaPath,
      schema_reference: reportPath(resolvedSchemaPath, atlasRoot),
      digest: sha256(fs.readFileSync(resolvedSchemaPath, "utf8")),
      atlas_root: atlasRoot,
      mirror_status: mirrorStatus
    };
  }

  if (atlasRoot) {
    const canonicalSchemaPath = path.join(atlasRoot, CANONICAL_SCHEMA_RELATIVE_PATH);
    if (!pathExists(canonicalSchemaPath)) {
      throw createReasonError(ERROR_CODES.canonicalSchemaMissing, [toPosixPath(CANONICAL_SCHEMA_RELATIVE_PATH)]);
    }

    const canonicalDigest = sha256(fs.readFileSync(canonicalSchemaPath, "utf8"));
    if (canonicalDigest !== `sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`) {
      throw createReasonError(ERROR_CODES.canonicalSchemaDigestMismatch, [
        `expected sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`,
        `received ${canonicalDigest}`
      ]);
    }

    return {
      schema: loadCompatibleSchemaFromPath(canonicalSchemaPath, ERROR_CODES.canonicalSchemaInvalid),
      source: SCHEMA_SOURCE.atlasSiblingCanonical,
      schema_path: canonicalSchemaPath,
      schema_reference: toPosixPath(CANONICAL_SCHEMA_RELATIVE_PATH),
      digest: canonicalDigest,
      atlas_root: atlasRoot,
      mirror_status: mirrorStatus
    };
  }

  return loadMirrorSchema();
}

export function loadReceiptSchema(options = {}) {
  return resolveReceiptSchema(options).schema;
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

  if (schema.anyOf) {
    const branchErrors = schema.anyOf.map((branch) => validateAgainstSchema(schemaRoot, branch, value, valuePath));
    if (branchErrors.some((errors) => errors.length === 0)) {
      return [];
    }
    return [`${valuePath} must satisfy at least one allowed shape`, ...branchErrors.flat()];
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

function deriveSubjectEntityId(eventFamily, subject, correlation, facts, source) {
  if (subject.entity_id) return subject.entity_id;
  if (subject.number != null) return String(subject.number);

  const perFamily = {
    repository: `${source.repository.owner}/${source.repository.name}`,
    branch: subject.branch ?? correlation.branch ?? subject.id,
    pull_request: correlation.pull_request ?? subject.id,
    issue: correlation.issue ?? subject.id,
    workflow_run: correlation.workflow_run ?? subject.id,
    release: correlation.release ?? facts.release_tag ?? subject.id,
    security_alert: correlation.security_alert ?? subject.id
  };

  return perFamily[eventFamily] ?? subject.id;
}

function deriveSubjectEntityRef(eventFamily, subject, correlation, facts, source) {
  if (subject.entity_ref) return subject.entity_ref;

  const branchName = subject.branch ?? correlation.branch;
  const releaseTag = correlation.release ?? facts.release_tag;
  const issueId = correlation.issue ?? (subject.number != null ? String(subject.number) : null);
  const prId = correlation.pull_request ?? (subject.number != null ? String(subject.number) : null);
  const workflowId = correlation.workflow_run ?? (subject.number != null ? String(subject.number) : null);
  const alertId = correlation.security_alert ?? (subject.number != null ? String(subject.number) : null);

  switch (eventFamily) {
    case "repository":
      return branchName ? `refs/heads/${branchName}` : null;
    case "branch":
      return branchName ? `refs/heads/${branchName}` : null;
    case "pull_request":
      return prId ? `refs/pull/${prId}/head` : branchName ? `refs/heads/${branchName}` : null;
    case "issue":
      return issueId ? `issues/${issueId}` : null;
    case "workflow_run":
      return workflowId ? `runs/${workflowId}` : null;
    case "release":
      return releaseTag ? `tags/${releaseTag}` : null;
    case "security_alert":
      return alertId ? `${source.event_name}:${alertId}` : null;
    default:
      return null;
  }
}

function deriveEndpointFromGithubUrl(url) {
  if (!url) {
    return null;
  }

  try {
    const parsed = new URL(url);
    if (parsed.hostname !== "github.com") {
      return null;
    }

    const segments = parsed.pathname
      .split("/")
      .filter(Boolean)
      .map((segment) => decodeURIComponent(segment));

    if (segments.length < 2) {
      return null;
    }

    const [owner, repository, ...rest] = segments;
    const base = ["repos", owner, repository];

    if (rest.length === 0) {
      return base.join("/");
    }
    if (rest[0] === "pull" && rest[1]) {
      return [...base, "pulls", rest[1]].join("/");
    }
    if (rest[0] === "issues" && rest[1]) {
      return [...base, "issues", rest[1]].join("/");
    }
    if (rest[0] === "actions" && rest[1] === "runs" && rest[2]) {
      return [...base, "actions", "runs", rest[2]].join("/");
    }
    if (rest[0] === "releases" && rest[1] === "tag" && rest[2]) {
      return [...base, "releases", "tags", ...rest.slice(2)].join("/");
    }
    if (rest[0] === "tree" && rest[1]) {
      return [...base, "branches", ...rest.slice(1)].join("/");
    }
    if (rest[0] === "security" && rest[1] && rest[2]) {
      return [...base, "security", rest[1], rest[2]].join("/");
    }

    return [...base, ...rest].join("/");
  } catch {
    return null;
  }
}

function deriveEndpoint(eventFamily, source, subject, canonicalSubject, correlation, facts) {
  if (source.endpoint) {
    return source.endpoint;
  }

  const fromUrl = deriveEndpointFromGithubUrl(source.url ?? subject.url);
  if (fromUrl) {
    return fromUrl;
  }

  const base = ["repos", source.repository.owner, source.repository.name];
  const branchName = subject.branch ?? correlation.branch ?? canonicalSubject.entity_id;
  const releaseTag = correlation.release ?? facts.release_tag ?? canonicalSubject.entity_id;
  const numericOrId = canonicalSubject.entity_id ?? subject.id;

  switch (eventFamily) {
    case "repository":
      return base.join("/");
    case "branch":
      return [...base, "branches", encodeURIComponent(branchName)].join("/");
    case "pull_request":
      return [...base, "pulls", encodeURIComponent(numericOrId)].join("/");
    case "issue":
      return [...base, "issues", encodeURIComponent(numericOrId)].join("/");
    case "workflow_run":
      return [...base, "actions", "runs", encodeURIComponent(numericOrId)].join("/");
    case "release":
      return [...base, "releases", "tags", encodeURIComponent(releaseTag)].join("/");
    case "security_alert":
      return [...base, "security", source.event_name.includes("secret_scanning") ? "secret-scanning" : "alerts", encodeURIComponent(numericOrId)].join("/");
    default:
      return base.join("/");
  }
}

function buildCanonicalSource(eventFamily, source, subject, canonicalSubject, correlation, facts) {
  const endpoint = deriveEndpoint(eventFamily, source, subject, canonicalSubject, correlation, facts);
  assertRequiredIdentityString(endpoint, "$.source.endpoint", ERROR_CODES.invalidSource);

  return {
    provider: "github",
    producer: "_stack",
    repository_owner: source.repository.owner,
    repository_name: source.repository.name,
    endpoint
  };
}

function buildCanonicalSubject(eventFamily, source, subject, correlation, facts) {
  const repository = subject.repository ?? `${source.repository.owner}/${source.repository.name}`;
  const entityId = deriveSubjectEntityId(eventFamily, subject, correlation, facts, source);
  const entityRef = deriveSubjectEntityRef(eventFamily, subject, correlation, facts, source);

  return {
    repository,
    repository_id: subject.repository_id ?? source.repository.id ?? null,
    entity_type: eventFamily,
    entity_id: normalizeFactValue(entityId),
    entity_ref: normalizeFactValue(entityRef),
    title: subject.title,
    url: subject.url ?? source.url ?? null
  };
}

function buildCanonicalCorrelation(source, correlation) {
  return {
    provider_delivery_id: correlation.delivery ?? source.delivery_id ?? null,
    source_run_id: correlation.source_run_id,
    atlas_job_id: correlation.atlas_job_id,
    parent_event_id: correlation.parent_event_id
  };
}

function addFact(facts, factState, factKey, value, sourcePath, note = null) {
  if (typeof factKey !== "string" || factKey.length < 1) {
    return;
  }
  if (facts.some((fact) => fact.fact_key === factKey)) {
    return;
  }
  facts.push({
    fact_key: factKey,
    state: factState,
    value: normalizeFactValue(value),
    source_path: sourcePath,
    note
  });
}

function buildNormalizedFacts(eventFamily, factState, source, subject, canonicalSubject, correlation, facts) {
  const normalizedFacts = [];

  addFact(normalizedFacts, factState, "event.action", facts.action ?? source.event_action, facts.action ? "facts.action" : "source.event_action");
  addFact(normalizedFacts, factState, "event.url", facts.url ?? subject.url ?? source.url, facts.url ? "facts.url" : subject.url ? "subject.url" : "source.url");

  switch (eventFamily) {
    case "repository":
      addFact(normalizedFacts, factState, "repository.full_name", canonicalSubject.repository, "source.repository");
      addFact(normalizedFacts, factState, "repository.head_branch", subject.branch, "subject.branch");
      addFact(normalizedFacts, factState, "repository.head_sha", subject.sha ?? facts.head_sha, subject.sha ? "subject.sha" : "facts.head_sha");
      break;
    case "branch":
      addFact(normalizedFacts, factState, "branch.name", subject.branch ?? correlation.branch ?? canonicalSubject.entity_id, subject.branch ? "subject.branch" : "correlation.branch");
      addFact(normalizedFacts, factState, "branch.head_sha", subject.sha ?? facts.head_sha, subject.sha ? "subject.sha" : "facts.head_sha");
      break;
    case "pull_request":
      addFact(normalizedFacts, factState, "pull_request.number", subject.number ?? correlation.pull_request ?? canonicalSubject.entity_id, subject.number != null ? "subject.number" : "correlation.pull_request");
      addFact(normalizedFacts, factState, "pull_request.title", subject.title, "subject.title");
      addFact(normalizedFacts, factState, "pull_request.head_branch", facts.head_branch ?? subject.branch, facts.head_branch ? "facts.head_branch" : "subject.branch");
      addFact(normalizedFacts, factState, "pull_request.base_branch", facts.base_branch, "facts.base_branch");
      addFact(normalizedFacts, factState, "pull_request.head_sha", facts.head_sha ?? subject.sha, facts.head_sha ? "facts.head_sha" : "subject.sha");
      break;
    case "issue":
      addFact(normalizedFacts, factState, "issue.number", subject.number ?? correlation.issue ?? canonicalSubject.entity_id, subject.number != null ? "subject.number" : "correlation.issue");
      addFact(normalizedFacts, factState, "issue.title", subject.title, "subject.title");
      addFact(normalizedFacts, factState, "issue.state", facts.state, "facts.state");
      break;
    case "workflow_run":
      addFact(normalizedFacts, factState, "workflow_run.id", correlation.workflow_run ?? subject.number ?? canonicalSubject.entity_id, correlation.workflow_run ? "correlation.workflow_run" : "subject.number");
      addFact(normalizedFacts, factState, "workflow_run.name", facts.workflow_name ?? subject.title, facts.workflow_name ? "facts.workflow_name" : "subject.title");
      addFact(normalizedFacts, factState, "workflow_run.conclusion", facts.run_conclusion, "facts.run_conclusion");
      addFact(normalizedFacts, factState, "workflow_run.branch", facts.head_branch ?? subject.branch, facts.head_branch ? "facts.head_branch" : "subject.branch");
      addFact(normalizedFacts, factState, "workflow_run.head_sha", facts.head_sha ?? subject.sha, facts.head_sha ? "facts.head_sha" : "subject.sha");
      break;
    case "release":
      addFact(normalizedFacts, factState, "release.tag", facts.release_tag ?? correlation.release ?? canonicalSubject.entity_id, facts.release_tag ? "facts.release_tag" : "correlation.release");
      addFact(normalizedFacts, factState, "release.name", subject.title, "subject.title");
      addFact(normalizedFacts, factState, "release.head_sha", facts.head_sha ?? subject.sha, facts.head_sha ? "facts.head_sha" : "subject.sha");
      break;
    case "security_alert":
      addFact(normalizedFacts, factState, "security_alert.id", correlation.security_alert ?? subject.number ?? canonicalSubject.entity_id, correlation.security_alert ? "correlation.security_alert" : "subject.number");
      addFact(normalizedFacts, factState, "security_alert.title", subject.title, "subject.title");
      addFact(normalizedFacts, factState, "security_alert.state", facts.alert_state ?? facts.state, facts.alert_state ? "facts.alert_state" : "facts.state");
      addFact(normalizedFacts, factState, "security_alert.severity", facts.alert_severity, "facts.alert_severity");
      break;
    default:
      break;
  }

  if (normalizedFacts.length === 0) {
    addFact(normalizedFacts, factState, "subject.entity_id", canonicalSubject.entity_id, "subject.id");
  }

  return normalizedFacts;
}

function buildSourceEventIdentity(eventFamily, source, subject, canonicalSubject) {
  return [
    eventFamily,
    canonicalSubject.repository,
    subject.id,
    source.event_name,
    source.event_action,
    source.delivery_id ?? source.source_event_id
  ].join(":");
}

function buildFactPayloadIdentity(eventFamily, canonicalSubject) {
  return ["github", eventFamily, canonicalSubject.repository, canonicalSubject.entity_id ?? "entity"].join(":");
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

  const normalizedRawFacts = normalizeFacts(input.facts ?? {});
  const canonicalSubject = buildCanonicalSubject(eventFamily, source, subject, correlation, normalizedRawFacts);
  const canonicalSource = buildCanonicalSource(eventFamily, source, subject, canonicalSubject, correlation, normalizedRawFacts);
  const canonicalCorrelation = buildCanonicalCorrelation(source, correlation);
  const normalizedFacts = buildNormalizedFacts(
    eventFamily,
    factState,
    source,
    subject,
    canonicalSubject,
    correlation,
    normalizedRawFacts
  );
  const payload = input.payload ?? {};
  const payloadDigest = sha256Hex(canonicalStringify(payload));
  const sourceEventIdentity = buildSourceEventIdentity(eventFamily, source, subject, canonicalSubject);
  const factPayloadIdentity = buildFactPayloadIdentity(eventFamily, canonicalSubject);
  const eventId = prefixedDigest("ghr_", buildDeterministicEventIdentity(source, subject, eventFamily));
  const idempotencyKey = prefixedDigest("ghk_", buildDeterministicIdempotencyIdentity(eventId));

  const receipt = {
    contract_version: CONTRACT_VERSION,
    event_id: eventId,
    idempotency_key: idempotencyKey,
    observed_at: observedAt,
    event_family: eventFamily,
    fact_state: factState,
    source: canonicalSource,
    subject: canonicalSubject,
    correlation: canonicalCorrelation,
    evidence_refs: normalizeEvidenceRefs(input.evidence.refs),
    digest: {
      algorithm: "sha256",
      value: payloadDigest,
      source_event_identity: sourceEventIdentity,
      fact_payload_identity: factPayloadIdentity
    },
    normalized_facts: normalizedFacts,
    authority: {
      producer: "_stack",
      atlas_contract_owner: "Atlas Contracts",
      owner_repository_truth: "preserved",
      read_only_first: true,
      external_mutation: "denied"
    }
  };

  const schema = options.schema ?? loadReceiptSchema({ schemaPath: options.schemaPath, repoRoot: options.repoRoot, cwd: options.cwd });
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

export function createSelfCheckResult(options = {}) {
  const schemaResolution = resolveReceiptSchema(options);
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

  const first = createSuccessString(normalizeGithubEventReceipt(sampleInput, { schema: schemaResolution.schema }));
  const second = createSuccessString(
    normalizeGithubEventReceipt(
      {
        ...sampleInput,
        payload: {
          a: { a: 1, b: 2 },
          z: 1
        }
      },
      { schema: schemaResolution.schema }
    )
  );

  return {
    ok: true,
    contract_version: SELF_CHECK_VERSION,
    receipt_contract_version: CONTRACT_VERSION,
    atlas_contract_commit: ACCEPTED_ATLAS_CONTRACT_COMMIT,
    canonical_schema_digest: `sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`,
    schema_resolution: {
      selected_source: schemaResolution.source,
      selected_schema_reference: schemaResolution.schema_reference,
      mirror_status: schemaResolution.mirror_status
    },
    checks: {
      canonical_output_stable: first === second,
      receipt_validates: true,
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
    schema: undefined,
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
    if (token === "--schema") {
      args.schema = argv[index + 1] ?? null;
      index += 1;
      continue;
    }
    throw createReasonError(ERROR_CODES.usageError, [`unknown argument: ${token}`]);
  }
  if (args.selfCheck && args.input) {
    throw createReasonError(ERROR_CODES.usageError, ["--self-check does not accept --input"]);
  }
  if (
    (args.input === null && argv.includes("--input"))
    || (args.output === null && argv.includes("--output"))
    || (args.schema === null && argv.includes("--schema"))
  ) {
    throw createReasonError(ERROR_CODES.usageError, ["--input, --output, and --schema require a path argument"]);
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
    const schemaResolution = resolveReceiptSchema({ schemaPath: args.schema, cwd: process.cwd() });

    if (args.selfCheck) {
      writeOutput(canonicalStringify(createSelfCheckResult({ schemaPath: args.schema, cwd: process.cwd() })), args.output);
      return 0;
    }

    const inputText = await resolveInputText(args.input);
    let parsedInput;
    try {
      parsedInput = JSON.parse(inputText);
    } catch {
      throw createReasonError(ERROR_CODES.invalidJson);
    }

    const receipt = normalizeGithubEventReceipt(parsedInput, { schema: schemaResolution.schema });
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
