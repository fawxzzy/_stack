import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = path.join(repoRoot, "exports", "repo.playbook.adoption.evidence.schema.v1.json");
const adoptionPath = path.join(repoRoot, "exports", "_stack.playbook.adoption.evidence.v1.json");
const reportPath = path.join(repoRoot, "exports", "_stack.playbook.verification.report.v1.json");
const adoptionNotePath = path.join(repoRoot, "docs", "ops", "_STACK-PLAYBOOK-ADOPTION.md");
const packagePath = path.join(repoRoot, "package.json");
const targetedCommand = "pnpm run test:playbook-adoption";

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function resolveSchemaRef(schema, ref) {
  assert.ok(ref.startsWith("#/"), `unsupported schema ref: ${ref}`);
  return ref.slice(2).split("/").reduce((node, segment) => node?.[segment], schema);
}

function validate(schemaRoot, schema, value, valuePath = "$") {
  if (schema.$ref) return validate(schemaRoot, resolveSchemaRef(schemaRoot, schema.$ref), value, valuePath);
  const errors = [];
  if (schema.enum && !schema.enum.includes(value)) return [`${valuePath} is not an allowed value`];
  if (schema.type === "object") {
    if (!value || typeof value !== "object" || Array.isArray(value)) return [`${valuePath} must be an object`];
    for (const key of schema.required ?? []) if (!(key in value)) errors.push(`${valuePath}.${key} is required`);
    const properties = schema.properties ?? {};
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(value)) if (!(key in properties)) errors.push(`${valuePath}.${key} is not allowed`);
    }
    for (const [key, childSchema] of Object.entries(properties)) {
      if (key in value) errors.push(...validate(schemaRoot, childSchema, value[key], `${valuePath}.${key}`));
    }
  } else if (schema.type === "array") {
    if (!Array.isArray(value)) return [`${valuePath} must be an array`];
    if (schema.minItems && value.length < schema.minItems) errors.push(`${valuePath} must not be empty`);
    if (schema.items) value.forEach((item, index) => errors.push(...validate(schemaRoot, schema.items, item, `${valuePath}[${index}]`)));
  } else if (schema.type === "string") {
    if (typeof value !== "string") return [`${valuePath} must be a string`];
    if (schema.minLength && value.length < schema.minLength) errors.push(`${valuePath} is too short`);
  } else if (schema.type === "boolean" && typeof value !== "boolean") {
    errors.push(`${valuePath} must be a boolean`);
  }
  return errors;
}

function assertRepoRelative(ref) {
  assert.match(ref, /^(?![A-Za-z]:)(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[^\\]+$/);
  assert.equal(fs.existsSync(path.join(repoRoot, ref)), true, `missing local evidence ref: ${ref}`);
}

test("_stack adoption export validates locally and declares the exact Playbook profile", () => {
  const schema = readJson(schemaPath);
  const adoption = readJson(adoptionPath);
  assert.deepEqual(validate(schema, schema, adoption), []);
  assert.deepEqual(adoption.repo, {
    repo_id: "_stack",
    role: "workflow_operator",
    repo_identity: "remote",
    repo_path: "repos/_stack",
    notes: ["_stack is a remote workflow/operator consumer of Playbook contracts."]
  });
  assert.equal(adoption.contract_claim.contract_id, "playbook_convergence_contract");
  assert.equal(adoption.contract_claim.contract_version, "1.0.0");
  assert.equal(adoption.contract_claim.source_repo_id, "playbook");
  assert.equal(adoption.contract_claim.source_export_path, "repos/playbook/exports/playbook.contract.example.v1.json");
  assert.equal(adoption.contract_claim.claim_state, "declared");
  assert.ok(adoption.contract_claim.notes.includes("Owner reference: main."));
  assert.equal(adoption.summary.adoption_status, "adopted");
  assert.equal(adoption.summary.verification_state, "targeted");
  adoption.evidence_refs.forEach(assertRepoRelative);
  adoption.implemented_patterns.flatMap((item) => item.evidence_refs ?? []).forEach(assertRepoRelative);
  adoption.adoption_checks.flatMap((item) => item.evidence_refs ?? []).forEach(assertRepoRelative);
});

test("_stack targeted verification report is green only for its declared criteria", () => {
  const report = readJson(reportPath);
  assert.equal(report.repo.repo_id, "_stack");
  assert.equal(report.repo.role, "workflow_operator");
  assert.equal(report.repo.repo_identity, "remote");
  assert.equal(report.scope.verification_kind, "targeted");
  assert.equal(report.summary.verification_status, "verified");
  assert.deepEqual(report.summary.blocking_gaps, []);
  for (const criterion of ["adoption_export", "adoption_test", "verification_path"]) {
    assert.equal(report.criteria[criterion].status, "passed", `${criterion} must pass before verified is declared`);
  }
  assert.deepEqual(report.criteria.verification_path.commands, [targetedCommand]);
  report.evidence_refs.forEach(assertRepoRelative);
  Object.values(report.criteria).flatMap((criterion) => criterion.evidence_refs ?? []).forEach(assertRepoRelative);
});

test("_stack exposes the non-mutating targeted command and bounded consumer wording", () => {
  const packageJson = readJson(packagePath);
  const adoptionNote = fs.readFileSync(adoptionNotePath, "utf8");
  assert.equal(packageJson.scripts["test:playbook-adoption"], "node --test .\\tests\\playbook-adoption-evidence.test.mjs");
  assert.match(adoptionNote, /workflow\/operator consumer/);
  assert.match(adoptionNote, /does not claim repo-wide Playbook certification/i);
  assert.match(adoptionNote, /without copying, certifying, or owning Playbook doctrine/i);
});
