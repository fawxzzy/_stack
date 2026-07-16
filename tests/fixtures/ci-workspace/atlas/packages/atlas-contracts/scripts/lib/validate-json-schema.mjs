import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const packageRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
);

export const schemaDir = path.join(packageRoot, "schemas");
export const fixturesDir = path.join(packageRoot, "fixtures");

export const supportedContractMajorVersions = Object.freeze([1, 2]);

export const knownSchemaPlan = Object.freeze([
  {
    id: "atlas.env.v1",
    file: "atlas.env.v1.schema.json",
    valid: "valid/env.json",
    invalid: "invalid/env.missing-required.json",
  },
  {
    id: "atlas.app-registration.v1",
    file: "atlas.app-registration.v1.schema.json",
    valid: "valid/app-registration.json",
    invalid: "invalid/app-registration.bad-repo-class.json",
  },
  {
    id: "atlas.health.v1",
    file: "atlas.health.v1.schema.json",
    valid: "valid/health.json",
    invalid: "invalid/health.bad-status.json",
  },
  {
    id: "atlas.event.v1",
    file: "atlas.event.v1.schema.json",
    valid: "valid/event.json",
    invalid: "invalid/event.bad-type.json",
  },
  {
    id: "atlas.receipt.v1",
    file: "atlas.receipt.v1.schema.json",
    valid: "valid/receipt.json",
    invalid: "invalid/receipt.bad-status.json",
  },
  {
    id: "atlas.github.event-receipt.v1",
    file: "atlas.github.event-receipt.v1.schema.json",
    valid: "valid/github.event-receipt.v1.json",
    invalid: "invalid/github.event-receipt.v1.bad-authority.json",
  },
  {
    id: "atlas.github.event-admission.v1",
    file: "atlas.github.event-admission.v1.schema.json",
    valid: "valid/github.event-admission.v1.json",
    invalid: "invalid/github.event-admission.v1.bad-decision.json",
  },
  {
    id: "atlas.github.projection-intent.v1",
    file: "atlas.github.projection-intent.v1.schema.json",
    valid: "valid/github.projection-intent.v1.json",
    invalid: "invalid/github.projection-intent.v1.bad-external-mutation.json",
  },
  {
    id: "atlas.project-board.owner-export.v1",
    file: "atlas.project-board.owner-export.v1.schema.json",
    valid: "valid/project-board.owner-export.v1.json",
    invalid: "invalid/project-board.owner-export.v1.semantic-conflict.json",
  },
  {
    id: "atlas.component-manifest.v2",
    file: "atlas.component-manifest.v2.schema.json",
    valid: "valid/component-manifest.v2.json",
    invalid: "invalid/component-manifest.v2.bad-authority.json",
  },
  {
    id: "atlas.job-envelope.v2",
    file: "atlas.job-envelope.v2.schema.json",
    valid: "valid/job-envelope.v2.json",
    invalid: "invalid/job-envelope.v2.bad-authority.json",
  },
  {
    id: "atlas.execution-receipt.v2",
    file: "atlas.execution-receipt.v2.schema.json",
    valid: "valid/execution-receipt.v2.json",
    invalid: "invalid/execution-receipt.v2.bad-status.json",
  },
  {
    id: "atlas.context-packet.v2",
    file: "atlas.context-packet.v2.schema.json",
    valid: "valid/context-packet.v2.json",
    invalid: "invalid/context-packet.v2.no-sources.json",
  },
  {
    id: "atlas.evidence-bundle.v2",
    file: "atlas.evidence-bundle.v2.schema.json",
    valid: "valid/evidence-bundle.v2.json",
    invalid: "invalid/evidence-bundle.v2.bad-classification.json",
  },
  {
    id: "atlas.approval-record.v2",
    file: "atlas.approval-record.v2.schema.json",
    valid: "valid/approval-record.v2.json",
    invalid: "invalid/approval-record.v2.bad-decision.json",
  },
  {
    id: "atlas.worker-lease.v2",
    file: "atlas.worker-lease.v2.schema.json",
    valid: "valid/worker-lease.v2.json",
    invalid: "invalid/worker-lease.v2.bad-status.json",
  },
  {
    id: "atlas.card-record.v2",
    file: "atlas.card-record.v2.schema.json",
    valid: "valid/card-record.v2.json",
    invalid: "invalid/card-record.v2.bad-lifecycle.json",
  },
  {
    id: "atlas.board-event.v2",
    file: "atlas.board-event.v2.schema.json",
    valid: "valid/board-event.v2.json",
    invalid: "invalid/board-event.v2.bad-result.json",
  },
  {
    id: "atlas.marker-evidence.v2",
    file: "atlas.marker-evidence.v2.schema.json",
    valid: "valid/marker-evidence.v2.json",
    invalid: "invalid/marker-evidence.v2.bad-rollup.json",
  },
  {
    id: "atlas.knowledge-candidate.v2",
    file: "atlas.knowledge-candidate.v2.schema.json",
    valid: "valid/knowledge-candidate.v2.json",
    invalid: "invalid/knowledge-candidate.v2.bad-kind.json",
  },
]);

const isoDateTimePattern =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function joinPath(base, segment) {
  if (!base) {
    return segment;
  }

  if (segment.startsWith("[")) {
    return `${base}${segment}`;
  }

  return `${base}.${segment}`;
}

function resolveRef(rootSchema, ref) {
  if (!ref.startsWith("#/")) {
    throw new Error(`Unsupported $ref: ${ref}`);
  }

  const segments = ref
    .slice(2)
    .split("/")
    .map((segment) => segment.replace(/~1/g, "/").replace(/~0/g, "~"));

  let current = rootSchema;
  for (const segment of segments) {
    current = current?.[segment];
  }

  if (!current) {
    throw new Error(`Unresolvable $ref: ${ref}`);
  }

  return current;
}

/** Load and parse a JSON document from a caller-supplied artifact path. */
export async function loadJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, "utf8"));
}

/** Validate a JSON value against an Atlas-supported JSON Schema subset. */
export function validateJsonSchema(value, schema, rootSchema = schema, atPath = "$") {
  if (schema.$ref) {
    return validateJsonSchema(value, resolveRef(rootSchema, schema.$ref), rootSchema, atPath);
  }

  if (schema.anyOf) {
    const branchErrors = schema.anyOf.map((branch) =>
      validateJsonSchema(value, branch, rootSchema, atPath),
    );
    if (branchErrors.some((errors) => errors.length === 0)) {
      return [];
    }
    return [
      `${atPath} must satisfy at least one allowed shape`,
      ...branchErrors.flat(),
    ];
  }

  const errors = [];

  if (schema.const !== undefined && value !== schema.const) {
    errors.push(`${atPath} must equal ${JSON.stringify(schema.const)}`);
  }

  if (schema.enum && !schema.enum.includes(value)) {
    errors.push(
      `${atPath} must be one of ${schema.enum.map((entry) => JSON.stringify(entry)).join(", ")}`,
    );
  }

  if (schema.type !== undefined) {
    const allowedTypes = Array.isArray(schema.type) ? schema.type : [schema.type];
    const matchesType = allowedTypes.some((type) => {
      if (type === "null") return value === null;
      if (type === "array") return Array.isArray(value);
      if (type === "object") return isPlainObject(value);
      if (type === "integer") return Number.isInteger(value);
      return typeof value === type;
    });

    if (!matchesType) {
      errors.push(`${atPath} must be of type ${allowedTypes.join(" | ")}`);
      return errors;
    }
  }

  if (typeof value === "string") {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      errors.push(`${atPath} must have length >= ${schema.minLength}`);
    }

    if (schema.pattern) {
      const regex = new RegExp(schema.pattern);
      if (!regex.test(value)) {
        errors.push(`${atPath} must match pattern ${schema.pattern}`);
      }
    }

    if (schema.format === "date-time") {
      if (!isoDateTimePattern.test(value) || Number.isNaN(Date.parse(value))) {
        errors.push(`${atPath} must be an ISO 8601 UTC timestamp`);
      }
    }
  }

  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      errors.push(`${atPath} must be >= ${schema.minimum}`);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      errors.push(`${atPath} must be <= ${schema.maximum}`);
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${atPath} must contain at least ${schema.minItems} item(s)`);
    }

    if (schema.items) {
      value.forEach((item, index) => {
        errors.push(
          ...validateJsonSchema(item, schema.items, rootSchema, joinPath(atPath, `[${index}]`)),
        );
      });
    }
  }

  if (isPlainObject(value)) {
    const propertyKeys = Object.keys(value);
    const definedProperties = schema.properties ?? {};
    const requiredProperties = schema.required ?? [];

    for (const key of requiredProperties) {
      if (!(key in value)) {
        errors.push(`${joinPath(atPath, key)} is required`);
      }
    }

    if (schema.additionalProperties === false) {
      for (const key of propertyKeys) {
        if (!(key in definedProperties)) {
          errors.push(`${joinPath(atPath, key)} is not allowed`);
        }
      }
    }

    for (const [key, propertySchema] of Object.entries(definedProperties)) {
      if (key in value) {
        errors.push(
          ...validateJsonSchema(value[key], propertySchema, rootSchema, joinPath(atPath, key)),
        );
      }
    }
  }

  return errors;
}

function hasTraversalSegment(reference) {
  return reference.replaceAll("\\", "/").split("/").some(
    (segment) => segment === "." || segment === "..",
  );
}

function contractMajorFromReference(reference) {
  const match = reference.replaceAll("\\", "/").match(
    /(?:^|\/)atlas(?:\.[a-z0-9-]+)+\.v(\d+)(?:\.schema\.json)?$/i,
  );
  return match ? Number(match[1]) : null;
}

/**
 * Resolve only a registered Atlas schema identifier or exact package-owned
 * schema file. This intentionally does not expose a generic schema loader.
 */
export function resolveKnownSchema(reference) {
  if (typeof reference !== "string" || reference.trim() === "") {
    return { ok: false, code: "UNKNOWN_SCHEMA", error: "A schema identifier is required." };
  }

  if (hasTraversalSegment(reference)) {
    return {
      ok: false,
      code: "INVALID_SCHEMA_REFERENCE",
      error: "Schema references must not contain path traversal segments.",
    };
  }

  const normalized = reference.replaceAll("\\", "/");
  const absoluteReference = path.resolve(reference);
  const entry = knownSchemaPlan.find((candidate) =>
    candidate.id === reference
    || candidate.file === normalized
    || `schemas/${candidate.file}` === normalized
    || path.join(schemaDir, candidate.file) === absoluteReference,
  );

  if (entry) {
    return {
      ok: true,
      entry,
      path: path.join(schemaDir, entry.file),
    };
  }

  const major = contractMajorFromReference(reference);
  if (major !== null && !supportedContractMajorVersions.includes(major)) {
    return {
      ok: false,
      code: "UNSUPPORTED_CONTRACT_VERSION",
      error: `Contract major version v${major} is not supported.`,
    };
  }

  return {
    ok: false,
    code: "UNKNOWN_SCHEMA",
    error: "Schema is not registered by @atlas/contracts.",
  };
}

/** Load a schema only after it has passed registered-schema resolution. */
export async function loadKnownSchema(reference) {
  const resolved = resolveKnownSchema(reference);
  if (!resolved.ok) {
    return resolved;
  }

  return {
    ...resolved,
    schema: await loadJson(resolved.path),
  };
}
