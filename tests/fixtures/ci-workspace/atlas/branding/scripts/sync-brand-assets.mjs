import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
if (!args.includes("--check")) {
  throw new Error("stack_ci_brand_fixture_check_only");
}
const manifestIndex = args.indexOf("--manifest");
const defaultManifest = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "manifest.json");
const manifestPath = manifestIndex >= 0 ? args[manifestIndex + 1] : defaultManifest;
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const atlasRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const stale = [];
for (const consumer of manifest.consumers ?? []) {
  const source = await readFile(path.resolve(atlasRoot, consumer.source));
  const target = await readFile(path.resolve(atlasRoot, consumer.target));
  if (!source.equals(target)) stale.push(consumer.id);
}
if (stale.length > 0) {
  process.stderr.write(`stale ${stale.join(",")}\n`);
  process.exitCode = 1;
}
