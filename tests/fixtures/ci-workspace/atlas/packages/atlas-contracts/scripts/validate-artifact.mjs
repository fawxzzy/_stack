import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import {
  loadJson,
  loadKnownSchema,
  validateJsonSchema,
} from "./lib/validate-json-schema.mjs";
import { validateContractSemantics } from "./lib/validate-semantics.mjs";

export const exitCodes = Object.freeze({
  VALID: 0,
  INVALID_ARTIFACT: 1,
  UNSUPPORTED_SCHEMA: 2,
  MALFORMED_JSON: 3,
  MISSING_INPUT: 4,
});

function parseArguments(argv) {
  const options = { json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--json") {
      options.json = true;
      continue;
    }

    const equalsMatch = argument.match(/^--(schema|artifact)=(.*)$/);
    if (equalsMatch) {
      options[equalsMatch[1]] = equalsMatch[2];
      continue;
    }

    if (argument === "--schema" || argument === "--artifact") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) {
        options.argumentError = `${argument} requires a value.`;
        continue;
      }
      options[argument.slice(2)] = value;
      index += 1;
      continue;
    }

    options.argumentError = `Unsupported argument: ${argument}`;
  }
  return options;
}

function makeResult({ ok, code, schema = null, artifact = null, errors = [] }) {
  return { ok, code, schema, artifact, errors };
}

function emit(result, json) {
  if (json) {
    console.log(JSON.stringify(result));
    return;
  }

  console.log(`${result.code}: ${result.ok ? "artifact is valid" : result.errors.join(" ")}`);
}

function schemaResult(entry) {
  return entry ? { id: entry.id, file: `schemas/${entry.file}` } : null;
}

export async function runArtifactValidator(argv) {
  const options = parseArguments(argv);
  if (options.argumentError || !options.schema || !options.artifact) {
    return {
      exitCode: exitCodes.MISSING_INPUT,
      result: makeResult({
        ok: false,
        code: "MISSING_INPUT",
        artifact: options.artifact ?? null,
        errors: [options.argumentError ?? "Both --schema and --artifact are required."],
      }),
      json: options.json,
    };
  }

  const loadedSchema = await loadKnownSchema(options.schema);
  if (!loadedSchema.ok) {
    return {
      exitCode: exitCodes.UNSUPPORTED_SCHEMA,
      result: makeResult({
        ok: false,
        code: loadedSchema.code,
        artifact: options.artifact,
        errors: [loadedSchema.error],
      }),
      json: options.json,
    };
  }

  let artifact;
  try {
    artifact = await loadJson(options.artifact);
  } catch (error) {
    if (error instanceof SyntaxError) {
      return {
        exitCode: exitCodes.MALFORMED_JSON,
        result: makeResult({
          ok: false,
          code: "MALFORMED_JSON",
          schema: schemaResult(loadedSchema.entry),
          artifact: options.artifact,
          errors: ["Artifact JSON could not be parsed."],
        }),
        json: options.json,
      };
    }

    if (error?.code === "ENOENT" || error?.code === "ENOTDIR") {
      return {
        exitCode: exitCodes.MISSING_INPUT,
        result: makeResult({
          ok: false,
          code: "MISSING_INPUT",
          schema: schemaResult(loadedSchema.entry),
          artifact: options.artifact,
          errors: ["Artifact JSON path does not exist."],
        }),
        json: options.json,
      };
    }

    throw error;
  }

  const errors = [
    ...validateJsonSchema(artifact, loadedSchema.schema),
    ...validateContractSemantics(loadedSchema.entry.id, artifact),
  ];
  if (errors.length > 0) {
    return {
      exitCode: exitCodes.INVALID_ARTIFACT,
      result: makeResult({
        ok: false,
        code: "INVALID_ARTIFACT",
        schema: schemaResult(loadedSchema.entry),
        artifact: options.artifact,
        errors,
      }),
      json: options.json,
    };
  }

  return {
    exitCode: exitCodes.VALID,
    result: makeResult({
      ok: true,
      code: "VALID",
      schema: schemaResult(loadedSchema.entry),
      artifact: options.artifact,
    }),
    json: options.json,
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const outcome = await runArtifactValidator(process.argv.slice(2));
  emit(outcome.result, outcome.json);
  process.exitCode = outcome.exitCode;
}
