import assert from "node:assert/strict";
import { copyFile, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync, statSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { ERROR_CODES, resolveAtlasBrandScript } from "./Invoke-AtlasBrand.mjs";

const wrapperPath = fileURLToPath(new URL("./Invoke-AtlasBrand.mjs", import.meta.url));

function runGit(workingDirectory, argumentsList) {
  return execFileSync("git", ["-C", workingDirectory, ...argumentsList], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
}

function runWrapper(wrapper, argumentsList, environment = {}) {
  return spawnSync(process.execPath, [wrapper, ...argumentsList], {
    encoding: "utf8",
    env: { ...process.env, ...environment }
  });
}

async function createFixture(t, { duplicateStackConsumer = false } = {}) {
  const fixtureRoot = await mkdtemp(path.join(os.tmpdir(), "atlas-brand-wrapper-"));
  t.after(() => rm(fixtureRoot, { recursive: true, force: true }));

  const atlasRoot = path.join(fixtureRoot, "ATLAS");
  const canonicalStackRoot = path.join(atlasRoot, "repos", "_stack");
  const linkedStackRoot = path.join(atlasRoot, "repos", "_stack-linked");
  const canonicalWrapperPath = path.join(canonicalStackRoot, "ops", "branding", "Invoke-AtlasBrand.mjs");
  const scriptsDirectory = path.join(atlasRoot, "branding", "scripts");
  const sourceDirectory = path.join(atlasRoot, "branding", "source");

  await mkdir(path.dirname(canonicalWrapperPath), { recursive: true });
  await mkdir(scriptsDirectory, { recursive: true });
  await mkdir(sourceDirectory, { recursive: true });
  await mkdir(path.join(canonicalStackRoot, "ops", "assets"), { recursive: true });
  await mkdir(path.join(atlasRoot, "repos", "fitness", "public"), { recursive: true });
  await copyFile(wrapperPath, canonicalWrapperPath);
  await writeFile(path.join(scriptsDirectory, "build-brand-assets.mjs"), "process.exitCode = 0;\n");
  await writeFile(path.join(sourceDirectory, "current.ico"), "current\n");
  await writeFile(path.join(canonicalStackRoot, "ops", "assets", "release-launcher.ico"), "current\n");
  await writeFile(path.join(atlasRoot, "repos", "fitness", "public", "icon.ico"), "stale\n");
  await writeFile(path.join(scriptsDirectory, "sync-brand-assets.mjs"), `
import { readFile, writeFile } from "node:fs/promises";
import process from "node:process";
const manifestIndex = process.argv.indexOf("--manifest");
const manifestPath = manifestIndex >= 0 ? process.argv[manifestIndex + 1] : new URL("../manifest.json", import.meta.url);
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
if (process.env.ATLAS_BRAND_TEST_CAPTURE) {
  await writeFile(process.env.ATLAS_BRAND_TEST_CAPTURE, JSON.stringify({ argv: process.argv.slice(2), manifestPath, manifest }));
}
const atlasRoot = new URL("../../", import.meta.url);
const stale = [];
for (const consumer of manifest.consumers) {
  const source = await readFile(new URL(consumer.source, atlasRoot), "utf8");
  const target = await readFile(new URL(consumer.target, atlasRoot), "utf8");
  if (source !== target) stale.push(consumer.id);
}
if (stale.length > 0) {
  console.error("stale " + stale.join(","));
  process.exitCode = 1;
}
`);

  const consumers = [
    {
      id: "stack-launcher-icon",
      source: "branding/source/current.ico",
      target: "repos/_stack/ops/assets/release-launcher.ico"
    },
    {
      id: "fitness-drift",
      source: "branding/source/current.ico",
      target: "repos/fitness/public/icon.ico"
    }
  ];
  if (duplicateStackConsumer) {
    consumers.push({ ...consumers[0] });
  }
  await writeFile(path.join(atlasRoot, "branding", "manifest.json"), JSON.stringify({ schemaVersion: 1, brand: { id: "fixture" }, consumers }, null, 2));

  runGit(canonicalStackRoot, ["init"]);
  runGit(canonicalStackRoot, ["add", "."]);
  runGit(canonicalStackRoot, ["-c", "user.email=fixture@example.test", "-c", "user.name=Atlas Fixture", "commit", "-m", "fixture"]);
  runGit(canonicalStackRoot, ["worktree", "add", linkedStackRoot]);

  return { atlasRoot, canonicalStackRoot, canonicalWrapperPath, linkedStackRoot };
}

test("git worktree add fixture resolves canonical and linked _stack wrappers to one Atlas script", async (t) => {
  const fixture = await createFixture(t);
  const linkedWrapperPath = path.join(fixture.linkedStackRoot, "ops", "branding", "Invoke-AtlasBrand.mjs");
  const canonicalScript = resolveAtlasBrandScript("build", fixture.canonicalWrapperPath);
  const linkedScript = resolveAtlasBrandScript("build", linkedWrapperPath);
  const expectedScript = path.join(fixture.atlasRoot, "branding", "scripts", "build-brand-assets.mjs");
  const expectedScriptStats = statSync(expectedScript, { bigint: true });

  for (const resolvedScript of [canonicalScript, linkedScript]) {
    const resolvedScriptStats = statSync(resolvedScript, { bigint: true });
    assert.equal(resolvedScriptStats.dev, expectedScriptStats.dev);
    assert.equal(resolvedScriptStats.ino, expectedScriptStats.ino);
  }

  await rm(expectedScript);
  assert.throws(
    () => resolveAtlasBrandScript("build", linkedWrapperPath),
    (error) => error?.code === ERROR_CODES.canonicalScriptNotFound
  );
});

test("scoped verification filters the canonical manifest and cleans its temporary file", async (t) => {
  const fixture = await createFixture(t);
  const capturePath = path.join(fixture.atlasRoot, "capture.json");
  const result = runWrapper(fixture.canonicalWrapperPath, ["verify", "--consumer-id", "stack-launcher-icon", "--dry-run"], {
    ATLAS_BRAND_TEST_CAPTURE: capturePath
  });

  assert.equal(result.status, 0, result.stderr);
  const capture = JSON.parse(await readFile(capturePath, "utf8"));
  assert.deepEqual(capture.manifest.consumers.map((consumer) => consumer.id), ["stack-launcher-icon"]);
  assert.equal(capture.manifest.brand.id, "fixture");
  assert.ok(capture.argv.includes("--check"));
  assert.ok(capture.argv.includes("--dry-run"));
  assert.equal(existsSync(capture.manifestPath), false);
});

test("scoped verification ignores unrelated owner drift while root-wide verification reports it", async (t) => {
  const fixture = await createFixture(t);
  const scoped = runWrapper(fixture.canonicalWrapperPath, ["verify", "--consumer-id", "stack-launcher-icon"]);
  const rootWide = runWrapper(fixture.canonicalWrapperPath, ["verify"]);

  assert.equal(scoped.status, 0, scoped.stderr);
  assert.equal(rootWide.status, 1);
  assert.match(rootWide.stderr, /fitness-drift/);
});

test("missing and duplicate consumer selections fail closed with stable reason codes", async (t) => {
  const fixture = await createFixture(t);
  const missing = runWrapper(fixture.canonicalWrapperPath, ["verify", "--consumer-id", "missing-consumer"]);
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, new RegExp(ERROR_CODES.consumerNotFound));

  const duplicateFixture = await createFixture(t, { duplicateStackConsumer: true });
  const duplicate = runWrapper(duplicateFixture.canonicalWrapperPath, ["verify", "--consumer-id", "stack-launcher-icon"]);
  assert.equal(duplicate.status, 1);
  assert.match(duplicate.stderr, new RegExp(ERROR_CODES.consumerDuplicate));
});
