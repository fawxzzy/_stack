#!/usr/bin/env node

import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const WRAPPER_PATH = fileURLToPath(import.meta.url);
const ERROR_CODES = Object.freeze({
  logicalRepositoryNotFound: "atlas_brand_logical_repository_not_found",
  canonicalScriptNotFound: "atlas_brand_canonical_script_not_found",
  consumerNotFound: "atlas_brand_consumer_not_found",
  consumerDuplicate: "atlas_brand_consumer_duplicate",
  consumerScopeUnsupported: "atlas_brand_consumer_scope_not_supported",
  unsupportedOperation: "atlas_brand_operation_not_supported"
});

function reasonError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function resolveLogicalStackRoot(wrapperPath) {
  const physicalWrapperDirectory = path.dirname(path.resolve(wrapperPath));
  let commonGitDirectory;

  try {
    commonGitDirectory = execFileSync(
      "git",
      ["-C", physicalWrapperDirectory, "rev-parse", "--path-format=absolute", "--git-common-dir"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }
    ).trim();
  } catch {
    throw reasonError(ERROR_CODES.logicalRepositoryNotFound);
  }

  if (commonGitDirectory.length === 0 || path.basename(commonGitDirectory) !== ".git") {
    throw reasonError(ERROR_CODES.logicalRepositoryNotFound);
  }

  const logicalStackRoot = path.dirname(path.resolve(commonGitDirectory));
  if (path.basename(logicalStackRoot) !== "_stack") {
    throw reasonError(ERROR_CODES.logicalRepositoryNotFound);
  }

  return logicalStackRoot;
}

export function resolveAtlasBrandPaths(operation, wrapperPath = WRAPPER_PATH) {
  const scriptName = {
    build: "build-brand-assets.mjs",
    sync: "sync-brand-assets.mjs",
    verify: "sync-brand-assets.mjs"
  }[operation];
  if (!scriptName) {
    throw reasonError(ERROR_CODES.unsupportedOperation);
  }

  const logicalStackRoot = resolveLogicalStackRoot(wrapperPath);
  const atlasRoot = path.resolve(logicalStackRoot, "..", "..");
  const canonicalScriptPath = path.join(atlasRoot, "branding", "scripts", scriptName);
  if (!existsSync(canonicalScriptPath)) {
    throw reasonError(ERROR_CODES.canonicalScriptNotFound);
  }

  return {
    atlasRoot,
    canonicalManifestPath: path.join(atlasRoot, "branding", "manifest.json"),
    canonicalScriptPath,
    logicalStackRoot
  };
}

export function resolveAtlasBrandScript(operation, wrapperPath = WRAPPER_PATH) {
  return resolveAtlasBrandPaths(operation, wrapperPath).canonicalScriptPath;
}

function parseArguments(argv) {
  const childArguments = [];
  let consumerId = null;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--consumer-id") {
      const value = argv[index + 1];
      if (!value) {
        throw reasonError(ERROR_CODES.consumerNotFound);
      }
      consumerId = value;
      index += 1;
      continue;
    }
    childArguments.push(argument);
  }

  return { childArguments, consumerId };
}

async function createScopedManifest(canonicalManifestPath, consumerId) {
  const manifest = JSON.parse(await readFile(canonicalManifestPath, "utf8"));
  const matches = Array.isArray(manifest.consumers)
    ? manifest.consumers.filter((consumer) => consumer?.id === consumerId)
    : [];

  if (matches.length === 0) {
    throw reasonError(ERROR_CODES.consumerNotFound);
  }
  if (matches.length > 1) {
    throw reasonError(ERROR_CODES.consumerDuplicate);
  }

  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), "atlas-brand-manifest-"));
  const temporaryManifestPath = path.join(temporaryDirectory, "manifest.json");
  await writeFile(
    temporaryManifestPath,
    `${JSON.stringify({ ...manifest, consumers: matches }, null, 2)}\n`,
    "utf8"
  );

  return { temporaryDirectory, temporaryManifestPath };
}

function runChild(canonicalScriptPath, operation, childArguments, temporaryManifestPath = null) {
  const argumentsForChild = [canonicalScriptPath];
  if (operation === "verify") {
    argumentsForChild.push("--check");
  }
  argumentsForChild.push(...childArguments);
  if (temporaryManifestPath) {
    argumentsForChild.push("--manifest", temporaryManifestPath);
  }

  const result = spawnSync(process.execPath, argumentsForChild, { stdio: "inherit" });
  if (result.error) {
    throw result.error;
  }
  return typeof result.status === "number" ? result.status : 1;
}

export { ERROR_CODES };

async function main() {
  const [operation, ...argv] = process.argv.slice(2);
  const { childArguments, consumerId } = parseArguments(argv);
  const paths = resolveAtlasBrandPaths(operation);

  if (!consumerId) {
    process.exitCode = runChild(paths.canonicalScriptPath, operation, childArguments);
    return;
  }
  if (operation !== "sync" && operation !== "verify") {
    throw reasonError(ERROR_CODES.consumerScopeUnsupported);
  }

  let temporaryDirectory;
  try {
    const scopedManifest = await createScopedManifest(paths.canonicalManifestPath, consumerId);
    temporaryDirectory = scopedManifest.temporaryDirectory;
    process.exitCode = runChild(
      paths.canonicalScriptPath,
      operation,
      childArguments,
      scopedManifest.temporaryManifestPath
    );
  } finally {
    if (temporaryDirectory) {
      await rm(temporaryDirectory, { recursive: true, force: true });
    }
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === WRAPPER_PATH) {
  main().catch((error) => {
    process.stderr.write(`${error.code ?? error.message}\n`);
    process.exitCode = 1;
  });
}
