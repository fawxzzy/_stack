import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  ACCEPTED_ATLAS_CONTRACT_COMMIT,
  ACCEPTED_CANONICAL_SCHEMA_SHA256,
  CANONICAL_SCHEMA_RELATIVE_PATH,
  CONTRACT_VERSION,
  ERROR_CODES,
  EVENT_FAMILIES,
  FACT_STATES,
  MIRROR_PROVENANCE_RELATIVE_PATH,
  MIRROR_SCHEMA_RELATIVE_PATH,
  SCHEMA_SOURCE,
  canonicalStringify,
  createErrorResult,
  createSelfCheckResult,
  loadReceiptSchema,
  normalizeGithubEventReceipt,
  resolveReceiptSchema,
  sha256,
  validateReceipt
} from "../ops/github/github-event-normalizer.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = path.join(repoRoot, "ops", "github", "github-event-normalizer.mjs");
const sourceText = fs.readFileSync(cliPath, "utf8");

function findAtlasRoot(startDir) {
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

const atlasRoot = findAtlasRoot(repoRoot);
const atlasSchemaPath = path.join(atlasRoot, CANONICAL_SCHEMA_RELATIVE_PATH);
const atlasValidatorPath = path.join(atlasRoot, "packages", "atlas-contracts", "scripts", "validate-artifact.mjs");

function fixture(overrides = {}) {
  const base = {
    event_family: "pull_request",
    fact_state: "observed",
    observed_at: "2026-07-13T11:14:17Z",
    source: {
      account: "fawxzzy",
      repository: { owner: "fawxzzy", name: "_stack" },
      delivery_id: "delivery-123",
      source_event_id: "evt-123",
      event_name: "pull_request",
      event_action: "synchronize",
      url: "https://github.com/fawxzzy/_stack/pull/1"
    },
    subject: {
      kind: "pull_request",
      id: "pr:1",
      number: 1,
      title: "normalize governed GitHub event receipts",
      branch: "codex/github-normalizer",
      sha: "1111222233334444555566667777888899990000",
      url: "https://github.com/fawxzzy/_stack/pull/1"
    },
    correlation: {
      branch: "codex/github-normalizer",
      commit: "1111222233334444555566667777888899990000",
      pull_request: "1",
      issue: null,
      workflow_run: null,
      release: null,
      security_alert: null,
      atlas_job_id: null,
      parent_event_id: null
    },
    evidence: {
      refs: [
        "ops/codex/AtlasContractsV2Producer.ps1",
        "ops/stack/StackWorkerArtifacts.ps1"
      ]
    },
    facts: {
      action: "synchronize",
      state: "open",
      url: "https://github.com/fawxzzy/_stack/pull/1",
      head_branch: "codex/github-normalizer",
      base_branch: "main",
      head_sha: "1111222233334444555566667777888899990000",
      workflow_name: null,
      run_conclusion: null,
      release_tag: null,
      alert_state: null,
      alert_severity: null
    },
    payload: {
      pull_request: {
        head: { ref: "codex/github-normalizer", sha: "1111222233334444555566667777888899990000" },
        base: { ref: "main" }
      },
      repository: {
        name: "_stack",
        owner: { login: "fawxzzy" }
      }
    }
  };
  return structuredClone({ ...base, ...overrides });
}

function runCliWith(cliTargetPath, args, options = {}) {
  return spawnSync(process.execPath, [cliTargetPath, ...args], {
    cwd: options.cwd ?? repoRoot,
    encoding: "utf8",
    input: options.input
  });
}

function runCli(args, options = {}) {
  return runCliWith(cliPath, args, options);
}

function normalizeErrorCode(action) {
  try {
    action();
    return "no_error";
  } catch (error) {
    return error.reasonCode;
  }
}

async function importIsolatedModule(tempRoot) {
  const isolatedCliPath = path.join(tempRoot, "ops", "github", "github-event-normalizer.mjs");
  return import(`${pathToFileURL(isolatedCliPath).href}?cacheBust=${Date.now()}-${Math.random()}`);
}

function createIsolatedFixture() {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "github-event-normalizer-isolated-"));
  fs.mkdirSync(path.join(tempRoot, "ops", "github"), { recursive: true });
  fs.mkdirSync(path.join(tempRoot, "exports"), { recursive: true });
  fs.copyFileSync(cliPath, path.join(tempRoot, "ops", "github", "github-event-normalizer.mjs"));
  fs.copyFileSync(path.join(repoRoot, MIRROR_SCHEMA_RELATIVE_PATH), path.join(tempRoot, MIRROR_SCHEMA_RELATIVE_PATH));
  fs.copyFileSync(path.join(repoRoot, MIRROR_PROVENANCE_RELATIVE_PATH), path.join(tempRoot, MIRROR_PROVENANCE_RELATIVE_PATH));
  return tempRoot;
}

test("canonical Atlas schema resolves in the normal workspace and receipts validate against the canonical shape", () => {
  assert.ok(fs.existsSync(atlasSchemaPath), "Atlas canonical schema fixture must exist for this test");

  const resolution = resolveReceiptSchema();
  const receipt = normalizeGithubEventReceipt(fixture());

  assert.equal(resolution.source, SCHEMA_SOURCE.atlasSiblingCanonical);
  assert.equal(resolution.schema_reference.replaceAll("\\", "/"), "packages/atlas-contracts/schemas/atlas.github.event-receipt.v1.schema.json");
  assert.equal(resolution.digest, `sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`);
  assert.equal(resolution.mirror_status.digest, `sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`);
  assert.equal(resolution.mirror_status.digest_matches_canonical, true);
  assert.equal(resolution.mirror_status.provenance_valid, true);

  assert.equal(receipt.contract_version, CONTRACT_VERSION);
  assert.equal(receipt.source.provider, "github");
  assert.equal(receipt.source.producer, "_stack");
  assert.equal(receipt.source.repository_owner, "fawxzzy");
  assert.equal(receipt.source.repository_name, "_stack");
  assert.equal(receipt.source.endpoint, "repos/fawxzzy/_stack/pulls/1");
  assert.equal(receipt.subject.repository, "fawxzzy/_stack");
  assert.equal(receipt.subject.entity_type, "pull_request");
  assert.equal(receipt.subject.entity_id, "1");
  assert.equal(receipt.subject.entity_ref, "refs/pull/1/head");
  assert.deepEqual(receipt.evidence_refs, fixture().evidence.refs);
  assert.equal(receipt.digest.algorithm, "sha256");
  assert.equal(receipt.digest.value.length, 64);
  assert.equal(receipt.authority.producer, "_stack");
  assert.equal(receipt.authority.atlas_contract_owner, "Atlas Contracts");
  assert.equal(receipt.authority.read_only_first, true);
  assert.equal(receipt.authority.external_mutation, "denied");
  assert.ok(receipt.normalized_facts.length >= 1);
  assert.ok(receipt.normalized_facts.some((fact) => fact.fact_key === "pull_request.number"));
  assert.ok(receipt.normalized_facts.some((fact) => fact.fact_key === "pull_request.head_sha"));
  assert.deepEqual(validateReceipt(receipt), []);
  assert.deepEqual(validateReceipt(receipt, loadReceiptSchema()), []);
});

test("deterministic replay identity survives reordered payloads and conflicting payload digests", () => {
  const firstInput = fixture();
  const secondInput = fixture();
  secondInput.payload = {
    repository: {
      owner: { login: "fawxzzy" },
      name: "_stack"
    },
    pull_request: {
      base: { ref: "main" },
      head: { sha: "1111222233334444555566667777888899990000", ref: "codex/github-normalizer" }
    }
  };

  const firstReceipt = normalizeGithubEventReceipt(firstInput);
  const secondReceipt = normalizeGithubEventReceipt(secondInput);
  const conflictingReplay = normalizeGithubEventReceipt(
    fixture({
      observed_at: "2026-07-13T13:14:17Z",
      payload: {
        repository: {
          owner: { login: "fawxzzy" },
          name: "_stack"
        },
        pull_request: {
          head: { ref: "codex/github-normalizer", sha: "9999222233334444555566667777888899990000" },
          base: { ref: "main" }
        }
      }
    })
  );

  assert.equal(canonicalStringify(firstReceipt), canonicalStringify(secondReceipt));
  assert.equal(firstReceipt.event_id, secondReceipt.event_id);
  assert.equal(firstReceipt.idempotency_key, secondReceipt.idempotency_key);
  assert.equal(firstReceipt.digest.value, secondReceipt.digest.value);
  assert.equal(firstReceipt.digest.value, sha256(canonicalStringify(firstInput.payload)).replace("sha256:", ""));
  assert.equal(firstReceipt.digest.source_event_identity, secondReceipt.digest.source_event_identity);
  assert.equal(firstReceipt.digest.fact_payload_identity, secondReceipt.digest.fact_payload_identity);
  assert.equal(firstReceipt.event_id, conflictingReplay.event_id);
  assert.equal(firstReceipt.idempotency_key, conflictingReplay.idempotency_key);
  assert.notEqual(firstReceipt.digest.value, conflictingReplay.digest.value);
});

test("representative repository, workflow_run, release, and security_alert facts normalize canonically without external calls", () => {
  const repositoryReceipt = normalizeGithubEventReceipt(
    fixture({
      event_family: "repository",
      source: {
        account: "fawxzzy",
        repository: { owner: "fawxzzy", name: "ATLAS" },
        delivery_id: "delivery-repository",
        source_event_id: "evt-repository",
        event_name: "repository",
        event_action: "observed",
        url: "https://github.com/fawxzzy/ATLAS"
      },
      subject: {
        kind: "repository",
        id: "repo:fawxzzy/ATLAS",
        number: null,
        title: "ATLAS",
        branch: "main",
        sha: "c31ff1070a3ee3f2864f23484d34aded2859fb39",
        url: "https://github.com/fawxzzy/ATLAS"
      },
      correlation: {
        branch: null,
        commit: "c31ff1070a3ee3f2864f23484d34aded2859fb39",
        pull_request: null,
        issue: null,
        workflow_run: null,
        release: null,
        security_alert: null,
        atlas_job_id: null,
        parent_event_id: null
      }
    })
  );
  const workflowReceipt = normalizeGithubEventReceipt(
    fixture({
      event_family: "workflow_run",
      source: {
        account: "fawxzzy",
        repository: { owner: "fawxzzy", name: "playbook" },
        delivery_id: "delivery-workflow",
        source_event_id: "evt-workflow",
        event_name: "workflow_run",
        event_action: "completed",
        url: "https://github.com/fawxzzy/playbook/actions/runs/29185091723"
      },
      subject: {
        kind: "workflow_run",
        id: "run:29185091723",
        number: 29185091723,
        title: "demo-integration",
        branch: "main",
        sha: "aab5ad5b4a51f37f6426b0797080dfa565954788",
        url: "https://github.com/fawxzzy/playbook/actions/runs/29185091723"
      },
      correlation: {
        branch: "main",
        commit: "aab5ad5b4a51f37f6426b0797080dfa565954788",
        pull_request: null,
        issue: null,
        workflow_run: "29185091723",
        release: null,
        security_alert: null,
        atlas_job_id: "atlas-job-123",
        parent_event_id: null
      },
      facts: {
        action: "completed",
        state: "completed",
        url: "https://github.com/fawxzzy/playbook/actions/runs/29185091723",
        head_branch: "main",
        base_branch: null,
        head_sha: "aab5ad5b4a51f37f6426b0797080dfa565954788",
        workflow_name: "demo-integration",
        run_conclusion: "failure",
        release_tag: null,
        alert_state: null,
        alert_severity: null
      },
      payload: {
        workflow_run: {
          id: 29185091723,
          conclusion: "failure"
        }
      }
    })
  );
  const releaseReceipt = normalizeGithubEventReceipt(
    fixture({
      event_family: "release",
      source: {
        account: "fawxzzy",
        repository: { owner: "fawxzzy", name: "trove" },
        delivery_id: "delivery-release",
        source_event_id: "evt-release",
        event_name: "release",
        event_action: "published",
        url: "https://github.com/fawxzzy/trove/releases/tag/v1.0.0"
      },
      subject: {
        kind: "release",
        id: "release:v1.0.0",
        number: null,
        title: "v1.0.0",
        branch: "main",
        sha: "ed51c69643047e1c59bb1caa310900ac6d526d8a",
        url: "https://github.com/fawxzzy/trove/releases/tag/v1.0.0"
      },
      correlation: {
        branch: "main",
        commit: "ed51c69643047e1c59bb1caa310900ac6d526d8a",
        pull_request: null,
        issue: null,
        workflow_run: null,
        release: "v1.0.0",
        security_alert: null,
        atlas_job_id: null,
        parent_event_id: null
      },
      facts: {
        action: "published",
        state: null,
        url: "https://github.com/fawxzzy/trove/releases/tag/v1.0.0",
        head_branch: "main",
        base_branch: null,
        head_sha: "ed51c69643047e1c59bb1caa310900ac6d526d8a",
        workflow_name: null,
        run_conclusion: null,
        release_tag: "v1.0.0",
        alert_state: null,
        alert_severity: null
      }
    })
  );
  const securityReceipt = normalizeGithubEventReceipt(
    fixture({
      event_family: "security_alert",
      source: {
        account: "fawxzzy",
        repository: { owner: "fawxzzy", name: "fawxzzy-fitness" },
        delivery_id: "delivery-security",
        source_event_id: "evt-security",
        event_name: "secret_scanning_alert",
        event_action: "created",
        url: "https://github.com/fawxzzy/fawxzzy-fitness/security/secret-scanning/1"
      },
      subject: {
        kind: "security_alert",
        id: "secret-scanning:1",
        number: 1,
        title: "Supabase Service Key",
        branch: null,
        sha: "410efe6e8fa9a30b1c56362455397dfbf51b1942",
        url: "https://github.com/fawxzzy/fawxzzy-fitness/security/secret-scanning/1"
      },
      correlation: {
        branch: null,
        commit: "410efe6e8fa9a30b1c56362455397dfbf51b1942",
        pull_request: null,
        issue: null,
        workflow_run: null,
        release: null,
        security_alert: "1",
        atlas_job_id: null,
        parent_event_id: null
      },
      facts: {
        action: "created",
        state: "open",
        url: "https://github.com/fawxzzy/fawxzzy-fitness/security/secret-scanning/1",
        head_branch: null,
        base_branch: null,
        head_sha: "410efe6e8fa9a30b1c56362455397dfbf51b1942",
        workflow_name: null,
        run_conclusion: null,
        release_tag: null,
        alert_state: "open",
        alert_severity: "Critical"
      },
      payload: {
        alert: {
          number: 1,
          state: "open",
          secret_type: "secret-scanning-redacted"
        }
      }
    })
  );

  assert.equal(repositoryReceipt.source.endpoint, "repos/fawxzzy/ATLAS");
  assert.ok(repositoryReceipt.normalized_facts.some((fact) => fact.fact_key === "repository.full_name"));
  assert.equal(workflowReceipt.correlation.source_run_id, "29185091723");
  assert.equal(workflowReceipt.correlation.atlas_job_id, "atlas-job-123");
  assert.ok(workflowReceipt.normalized_facts.some((fact) => fact.fact_key === "workflow_run.conclusion" && fact.value === "failure"));
  assert.equal(releaseReceipt.subject.entity_ref, "tags/v1.0.0");
  assert.ok(releaseReceipt.normalized_facts.some((fact) => fact.fact_key === "release.tag" && fact.value === "v1.0.0"));
  assert.equal(securityReceipt.source.endpoint, "repos/fawxzzy/fawxzzy-fitness/security/secret-scanning/1");
  assert.ok(securityReceipt.normalized_facts.some((fact) => fact.fact_key === "security_alert.severity" && fact.value === "Critical"));
  assert.deepEqual(validateReceipt(repositoryReceipt), []);
  assert.deepEqual(validateReceipt(workflowReceipt), []);
  assert.deepEqual(validateReceipt(releaseReceipt), []);
  assert.deepEqual(validateReceipt(securityReceipt), []);
});

test("all supported fact states remain distinct and propagate into normalized facts", () => {
  for (const factState of FACT_STATES) {
    const receipt = normalizeGithubEventReceipt(
      fixture({
        event_family: "repository",
        fact_state: factState,
        source: {
          account: "fawxzzy",
          repository: { owner: "fawxzzy", name: "ATLAS" },
          delivery_id: "delivery-repo",
          source_event_id: "evt-repo",
          event_name: "repository",
          event_action: "observed",
          url: "https://github.com/fawxzzy/ATLAS"
        },
        subject: {
          kind: "repository",
          id: "repo:fawxzzy/ATLAS",
          number: null,
          title: "ATLAS",
          branch: "main",
          sha: "c31ff1070a3ee3f2864f23484d34aded2859fb39",
          url: "https://github.com/fawxzzy/ATLAS"
        },
        correlation: {
          branch: null,
          commit: "c31ff1070a3ee3f2864f23484d34aded2859fb39",
          pull_request: null,
          issue: null,
          workflow_run: null,
          release: null,
          security_alert: null,
          atlas_job_id: null,
          parent_event_id: null
        }
      })
    );
    assert.equal(receipt.fact_state, factState);
    assert.ok(receipt.normalized_facts.every((fact) => fact.state === factState));
  }
});

test("explicit schema failures, mirror fallback, and mirror provenance or digest mismatches fail closed with stable reason codes", async () => {
  const explicitMissing = runCli(["--schema", "missing.schema.json"], { input: JSON.stringify(fixture()) });
  assert.equal(explicitMissing.status, 1);
  assert.match(explicitMissing.stdout, /github_event_normalizer_explicit_schema_missing/);

  const tempSchemaRoot = fs.mkdtempSync(path.join(os.tmpdir(), "github-event-normalizer-schema-"));
  const invalidSchemaPath = path.join(tempSchemaRoot, "invalid.schema.json");
  fs.writeFileSync(invalidSchemaPath, JSON.stringify({ contract_version: CONTRACT_VERSION }), "utf8");
  const explicitInvalid = runCli(["--schema", invalidSchemaPath], { input: JSON.stringify(fixture()) });
  assert.equal(explicitInvalid.status, 1);
  assert.match(explicitInvalid.stdout, /github_event_normalizer_explicit_schema_invalid/);

  const isolatedRoot = createIsolatedFixture();
  const isolatedModule = await importIsolatedModule(isolatedRoot);
  const isolatedResolution = isolatedModule.resolveReceiptSchema();
  const isolatedReceipt = isolatedModule.normalizeGithubEventReceipt(fixture());
  assert.equal(isolatedResolution.source, SCHEMA_SOURCE.mirrorFallback);
  assert.equal(isolatedResolution.schema_reference.replaceAll("\\", "/"), "exports/github.event-receipt.schema.v1.json");
  assert.deepEqual(isolatedModule.validateReceipt(isolatedReceipt), []);

  const provenanceMismatchRoot = createIsolatedFixture();
  const provenancePath = path.join(provenanceMismatchRoot, MIRROR_PROVENANCE_RELATIVE_PATH);
  const provenance = JSON.parse(fs.readFileSync(provenancePath, "utf8"));
  provenance.mirror_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
  fs.writeFileSync(provenancePath, JSON.stringify(provenance, null, 2), "utf8");
  const provenanceMismatch = runCliWith(
    path.join(provenanceMismatchRoot, "ops", "github", "github-event-normalizer.mjs"),
    ["--self-check"],
    { cwd: provenanceMismatchRoot }
  );
  assert.equal(provenanceMismatch.status, 1);
  assert.match(provenanceMismatch.stdout, /github_event_normalizer_mirror_provenance_invalid/);

  const digestMismatchRoot = createIsolatedFixture();
  fs.appendFileSync(path.join(digestMismatchRoot, MIRROR_SCHEMA_RELATIVE_PATH), "\n", "utf8");
  const digestMismatch = runCliWith(
    path.join(digestMismatchRoot, "ops", "github", "github-event-normalizer.mjs"),
    ["--self-check"],
    { cwd: digestMismatchRoot }
  );
  assert.equal(digestMismatch.status, 1);
  assert.match(digestMismatch.stdout, /github_event_normalizer_mirror_digest_mismatch/);
});

test("invalid raw input categories and schema-invalid output fail closed", () => {
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ observed_at: "2026-07-13" }))),
    ERROR_CODES.invalidObservedAt
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ event_family: "deployment" }))),
    ERROR_CODES.unsupportedEventFamily
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ fact_state: "healthy" }))),
    ERROR_CODES.unsupportedFactState
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ correlation: { ...fixture().correlation, pull_request: null } }))),
    ERROR_CODES.invalidCorrelation
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ correlation: { ...fixture().correlation, parent_event_id: "bad-parent" } }))),
    ERROR_CODES.invalidCorrelation
  );

  const schema = structuredClone(loadReceiptSchema());
  schema.$defs.fact.properties.fact_key.pattern = "^release\\.";
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture(), { schema })),
    ERROR_CODES.schemaValidationFailed
  );
});

test("missing identities, secret-like input, and undefined strings are rejected without echoing secrets", () => {
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ source: { ...fixture().source, account: undefined } }))),
    ERROR_CODES.invalidSource
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ source: { ...fixture().source, delivery_id: null, source_event_id: null } }))),
    ERROR_CODES.missingSourceIdentity
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ subject: { ...fixture().subject, id: "undefined" } }))),
    ERROR_CODES.invalidSubject
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ evidence: { refs: ["undefined"] } }))),
    ERROR_CODES.invalidEvidence
  );

  const secretLikeValue = ["github", "pat", "abcdefghijklmnopqrstuvwxyz0123456789"].join("_");
  const secretFailure = runCli([], {
    input: JSON.stringify(
      fixture({
        payload: {
          github_pat_token: secretLikeValue
        }
      })
    )
  });
  assert.equal(secretFailure.status, 1);
  assert.match(secretFailure.stdout, /github_event_normalizer_secret_like_input_rejected/);
  assert.doesNotMatch(secretFailure.stdout, /github_pat_/);
  assert.doesNotMatch(secretFailure.stdout, /token/i);

  const undefinedFailure = runCli([], {
    input: JSON.stringify(fixture({ source: { ...fixture().source, account: undefined } }))
  });
  assert.equal(undefinedFailure.status, 1);
  assert.match(undefinedFailure.stdout, /github_event_normalizer_invalid_source/);
  assert.doesNotMatch(undefinedFailure.stdout, /"undefined"/);
});

test("self-check reports contract version, selected schema source, canonical digest, and mirror status without machine-specific committed paths", () => {
  const selfCheck = createSelfCheckResult();
  const cliSelfCheck = runCli(["--self-check"]);

  assert.equal(cliSelfCheck.status, 0);
  assert.deepEqual(JSON.parse(cliSelfCheck.stdout), selfCheck);
  assert.equal(selfCheck.contract_version, "atlas.github.event-normalizer.self-check.v1");
  assert.equal(selfCheck.receipt_contract_version, CONTRACT_VERSION);
  assert.equal(selfCheck.atlas_contract_commit, ACCEPTED_ATLAS_CONTRACT_COMMIT);
  assert.equal(selfCheck.canonical_schema_digest, `sha256:${ACCEPTED_CANONICAL_SCHEMA_SHA256}`);
  assert.equal(selfCheck.schema_resolution.selected_source, SCHEMA_SOURCE.atlasSiblingCanonical);
  assert.equal(selfCheck.schema_resolution.selected_schema_reference, "packages/atlas-contracts/schemas/atlas.github.event-receipt.v1.schema.json");
  assert.equal(selfCheck.schema_resolution.mirror_status.provenance_valid, true);
  assert.equal(selfCheck.schema_resolution.mirror_status.digest_matches_canonical, true);
  assert.ok(!selfCheck.schema_resolution.selected_schema_reference.includes(":"));
  assert.ok(!selfCheck.schema_resolution.mirror_status.schema_path.includes(":"));
  assert.ok(!selfCheck.schema_resolution.mirror_status.provenance_path.includes(":"));
});

test("cli supports stdin, --input, --output, and Atlas validator compatibility when available", (t) => {
  const stdinRun = runCli([], { input: JSON.stringify(fixture()) });
  assert.equal(stdinRun.status, 0);
  const parsedStdout = JSON.parse(stdinRun.stdout);
  assert.equal(parsedStdout.event_family, "pull_request");

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "github-event-normalizer-"));
  const inputPath = path.join(tempRoot, "input.json");
  const outputPath = path.join(tempRoot, "output.json");
  fs.writeFileSync(inputPath, JSON.stringify(fixture()), "utf8");

  const fileRun = runCli(["--input", inputPath, "--output", outputPath]);
  assert.equal(fileRun.status, 0);
  assert.equal(fileRun.stdout, "");
  assert.equal(JSON.parse(fs.readFileSync(outputPath, "utf8")).event_family, "pull_request");

  if (!fs.existsSync(atlasValidatorPath)) {
    t.skip("Atlas root validator is not present in this topology");
    return;
  }

  const validatorRun = spawnSync(
    process.execPath,
    [
      atlasValidatorPath,
      "--schema",
      CONTRACT_VERSION,
      "--artifact",
      outputPath,
      "--json"
    ],
    {
      cwd: atlasRoot,
      encoding: "utf8"
    }
  );

  assert.equal(validatorRun.status, 0);
  assert.deepEqual(JSON.parse(validatorRun.stdout), {
    ok: true,
    code: "VALID",
    schema: {
      id: CONTRACT_VERSION,
      file: "schemas/atlas.github.event-receipt.v1.schema.json"
    },
    artifact: outputPath,
    errors: []
  });
});

test("implementation remains local-only and never introduces network, git mutation, or Discord calls", () => {
  for (const family of EVENT_FAMILIES) {
    assert.match(sourceText, new RegExp(`"${family}"`));
  }
  assert.doesNotMatch(sourceText, /\bfetch\s*\(/);
  assert.doesNotMatch(sourceText, /\bhttps\.(request|get)\b/);
  assert.doesNotMatch(sourceText, /\bspawnSync\([^)]*git\b/);
  assert.doesNotMatch(sourceText, /\bexecSync\([^)]*git\b/);
  assert.doesNotMatch(sourceText, /\bDiscordOS\b/);
  assert.equal(
    canonicalStringify(createErrorResult(ERROR_CODES.invalidJson)),
    "{\"ok\":false,\"reason_code\":\"github_event_normalizer_invalid_json\"}\n"
  );
});
