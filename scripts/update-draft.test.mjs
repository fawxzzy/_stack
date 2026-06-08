import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import test from "node:test";
import { runUpdateDraftCommand } from "./update-draft.mjs";

function createProof(overrides = {}) {
  return [
    `# Fitness Release: ${overrides.version ?? "fitness-2026.06.03-1"}`,
    "",
    "## Summary",
    "",
    overrides.summary ?? "Bounded production release summary.",
    "",
    "## Release Facts",
    "",
    `- App: ${overrides.app ?? "fitness"}`,
    `- Environment: ${overrides.environment ?? "production"}`,
    `- Branch: \`${overrides.branch ?? "main"}\``,
    `- Commit: \`${overrides.commit ?? "abc123def456"}\``,
    `- Previous commit: ${overrides.previousCommit ?? "prev123"}`,
    `- Deployed at: ${overrides.deployedAt ?? "2026-06-03T15:14:17Z"}`,
    `- Production URL: ${overrides.productionUrl ?? "https://fitness.example.app"}`,
    `- Deployment URL: ${overrides.deploymentUrl ?? "https://fitness-preview.example.app"}`
  ].join("\n");
}

function createLedgerEntry(overrides = {}) {
  return JSON.stringify({
    version: overrides.version ?? "fitness-2026.06.03-1",
    app: overrides.app ?? "fitness",
    environment: overrides.environment ?? "production",
    branch: overrides.branch ?? "main",
    commit: overrides.commit ?? "abc123def456",
    previousCommit: overrides.previousCommit ?? "prev123",
    deployedAt: overrides.deployedAt ?? "2026-06-03T15:14:17Z",
    prodUrl: overrides.prodUrl ?? "https://fitness.example.app",
    deploymentUrl: overrides.deploymentUrl ?? "https://fitness-preview.example.app",
    lanes: overrides.lanes ?? ["Fitness release lane"],
    userFacingChanges: overrides.userFacingChanges ?? ["One user-facing change."],
    internalChanges: overrides.internalChanges ?? ["One internal change."],
    verification: overrides.verification ?? ["npm run verify"],
    artifacts: overrides.artifacts ?? ["docs/releases/fitness/2026/mock.md"],
    knownGaps: overrides.knownGaps ?? ["One known gap."]
  });
}

function createReceiptContext(overrides = {}) {
  return [
    `# Fitness Release: ${overrides.version ?? "fitness-2026.06.03-1"}`,
    "",
    "## Context",
    "",
    `- ${overrides.contextNote ?? "Deployment metadata already cleared the same-story update handoff."}`,
    "",
    "## Release Facts",
    "",
    `- Commit: \`${overrides.commit ?? "abc123def456"}\``
  ].join("\n");
}

async function withWorkspace(files) {
  const workspaceRoot = await fs.mkdtemp(path.join(os.tmpdir(), "stack-update-draft-"));
  for (const [relativePath, content] of Object.entries(files)) {
    const absolutePath = path.join(workspaceRoot, relativePath);
    await fs.mkdir(path.dirname(absolutePath), { recursive: true });
    await fs.writeFile(absolutePath, content, "utf8");
  }
  return workspaceRoot;
}

function assertExactKeys(actual, expected) {
  assert.deepEqual(Object.keys(actual).sort(), [...expected].sort());
}

test("admitted repo with proof and ledger emits the bounded package-ready success contract", async () => {
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md": createProof(),
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl": `${createLedgerEntry()}\n`
  });

  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.command, "stack update draft");
  assert.equal(result.report.repo, "repos/fawxzzy-fitness");
  assert.equal(result.report.package_mode, "package-ready");
  assert.equal(result.report.package_status, "downstream-consumption-only");
  assert.equal(result.report.context_status, "not-requested");
  assert.equal(result.report.routing_note, "package downstream-consumption only from exact proof and ledger basis");
  assert.equal(result.report.proof_ref, "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md");
  assert.equal(result.report.ledger_ref, "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl");
  assert.equal(result.report.deployment_metadata.version, "fitness-2026.06.03-1");
  assert.equal(result.report.ledger_notes.version, "fitness-2026.06.03-1");
  assert.equal("receipt_context" in result.report, false);
  assert.equal("context_note" in result.report, false);
  assertExactKeys(result.report, [
    "command",
    "repo",
    "package_mode",
    "package_status",
    "proof_ref",
    "ledger_ref",
    "package_fields",
    "context_status",
    "routing_note",
    "deployment_metadata",
    "ledger_notes"
  ]);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("same-story receipt context upgrades the bounded success contract to package-ready-plus-context", async () => {
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md": createProof(),
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl": `${createLedgerEntry()}\n`,
    "receipts/current-story.md": createReceiptContext()
  });

  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl",
    "--receipt-context",
    "receipts/current-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.package_mode, "package-ready-plus-context");
  assert.equal(result.report.context_status, "agreed");
  assert.equal(result.report.receipt_context, "receipts/current-story.md");
  assert.equal(result.report.context_note, "Deployment metadata already cleared the same-story update handoff.");
  assert.equal(
    result.report.routing_note,
    "package downstream-consumption only from exact proof and ledger basis plus one same-story context"
  );

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("inadmissible receipt context is ignored without widening the package-ready branch", async () => {
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md": createProof(),
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl": `${createLedgerEntry()}\n`,
    "receipts/stale-story.md": createReceiptContext({ commit: "ffff1111ffff1111" })
  });

  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl",
    "--receipt-context",
    "receipts/stale-story.md"
  ], { workspaceRoot });

  assert.equal(result.ok, true);
  assert.equal(result.report.package_mode, "package-ready");
  assert.equal(result.report.context_status, "ignored-as-inadmissible");
  assert.equal(result.report.receipt_context, "receipts/stale-story.md");
  assert.equal(result.report.context_fallback_reason, "receipt-context-conflicts-with-proof-ledger-story");
  assert.equal(result.report.contradiction_note.contradiction_scope, "receipt-context");
  assert.equal(result.report.contradiction_note.summary_consequence, "package-ready-without-context");
  assert.equal("context_note" in result.report, false);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("repo target outside the admitted class fails closed", async () => {
  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-mazer",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "repo-unadmitted");
  assert.equal(result.report.failure_scope, "repo-target");
});

test("missing proof basis fails closed", async () => {
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl": `${createLedgerEntry()}\n`
  });

  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/missing.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "proof-missing");
  assert.equal(result.report.failure_scope, "proof-basis");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("missing ledger basis fails closed", async () => {
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md": createProof()
  });

  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "ledger-missing");
  assert.equal(result.report.failure_scope, "ledger-basis");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("proof-ledger contradiction fails closed with the bounded contradiction payload", async () => {
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md": createProof(),
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl": `${createLedgerEntry({ commit: "ffff1111ffff1111" })}\n`
  });

  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "proof-ledger-contradiction");
  assert.equal(result.report.failure_scope, "proof-ledger-story");
  assert.equal(result.report.contradiction_note.contradiction_scope, "commit-or-target");
  assert.equal(result.report.contradiction_note.summary_consequence, "no-package");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("malformed ledger basis fails closed without fabricating a package story", async () => {
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md": createProof(),
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl": "{not-json}\n"
  });

  const result = await runUpdateDraftCommand([
    "--format",
    "json",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
  ], { workspaceRoot });

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "package-basis-unavailable");
  assert.equal(result.report.failure_scope, "ledger-basis");

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});

test("unsupported invocation fails closed as invalid input", async () => {
  const result = await runUpdateDraftCommand([
    "--format",
    "yaml",
    "--repo",
    "repos/fawxzzy-fitness",
    "--proof-ref",
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
    "--ledger-ref",
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
  ]);

  assert.equal(result.ok, false);
  assert.equal(result.report.failure_code, "invalid-input");
  assert.equal(result.report.failure_scope, "input");
});

test("bounded text rendering smoke path preserves the required line order", async () => {
  const scriptPath = path.resolve("scripts/update-draft.mjs");
  const workspaceRoot = await withWorkspace({
    "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md": createProof(),
    "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl": `${createLedgerEntry()}\n`,
    "receipts/current-story.md": createReceiptContext()
  });

  const stdout = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [
      scriptPath,
      "--repo",
      "repos/fawxzzy-fitness",
      "--proof-ref",
      "repos/fawxzzy-fitness/docs/releases/fitness/2026/mock.md",
      "--ledger-ref",
      "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl",
      "--receipt-context",
      "receipts/current-story.md"
    ], {
      cwd: path.resolve("."),
      env: {
        ...process.env,
        STACK_UPDATE_DRAFT_WORKSPACE_ROOT: workspaceRoot
      }
    });

    let output = "";
    child.stdout.on("data", (chunk) => {
      output += chunk;
    });
    child.stderr.on("data", () => {});
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`Process exited with code ${code}`));
        return;
      }

      resolve(output);
    });
  });

  assert.match(stdout, /^package_status=downstream-consumption-only/m);
  assert.match(stdout, /^repo=repos\/fawxzzy-fitness/m);
  assert.match(stdout, /^proof_ref=.* \| ledger_ref=.*/m);
  assert.match(stdout, /^package_fields=repo identity; proof and ledger refs;/m);
  assert.match(stdout, /^routing_note=package downstream-consumption only from exact proof and ledger basis plus one same-story context/m);

  await fs.rm(workspaceRoot, { recursive: true, force: true });
});
