import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  CONTRACT_VERSION,
  ERROR_CODES,
  EVENT_FAMILIES,
  FACT_STATES,
  canonicalStringify,
  createErrorResult,
  createSelfCheckResult,
  loadReceiptSchema,
  normalizeGithubEventReceipt,
  sha256,
  validateReceipt
} from "../ops/github/github-event-normalizer.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = path.join(repoRoot, "ops", "github", "github-event-normalizer.mjs");
const sourceText = fs.readFileSync(cliPath, "utf8");

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
      security_alert: null
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

function runCli(args, options = {}) {
  return spawnSync(process.execPath, [cliPath, ...args], {
    cwd: repoRoot,
    encoding: "utf8",
    input: options.input
  });
}

function normalizeErrorCode(action) {
  try {
    action();
    return "no_error";
  } catch (error) {
    return error.reasonCode;
  }
}

test("schema-backed pull_request normalization is deterministic across reordered semantic input", () => {
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

  assert.equal(firstReceipt.contract_version, CONTRACT_VERSION);
  assert.deepEqual(validateReceipt(firstReceipt), []);
  assert.equal(canonicalStringify(firstReceipt), canonicalStringify(secondReceipt));
  assert.equal(firstReceipt.event_id, secondReceipt.event_id);
  assert.equal(firstReceipt.idempotency_key, secondReceipt.idempotency_key);
  assert.equal(firstReceipt.digest.payload_sha256, secondReceipt.digest.payload_sha256);
  assert.equal(firstReceipt.digest.payload_sha256, sha256(canonicalStringify(firstInput.payload)));
});

test("replays preserve event identity across observed_at changes and conflicting payloads", () => {
  const baseline = normalizeGithubEventReceipt(fixture());
  const observedAtReplay = normalizeGithubEventReceipt(
    fixture({
      observed_at: "2026-07-13T12:14:17Z"
    })
  );
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

  assert.equal(baseline.event_id, observedAtReplay.event_id);
  assert.equal(baseline.idempotency_key, observedAtReplay.idempotency_key);
  assert.equal(baseline.event_id, conflictingReplay.event_id);
  assert.equal(baseline.idempotency_key, conflictingReplay.idempotency_key);
  assert.notEqual(baseline.digest.payload_sha256, conflictingReplay.digest.payload_sha256);
});

test("workflow_run and security_alert representative facts normalize without live calls", () => {
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
        security_alert: null
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
        security_alert: "1"
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
          secret_type: "supabase_service_key"
        }
      }
    })
  );

  assert.equal(workflowReceipt.event_family, "workflow_run");
  assert.equal(workflowReceipt.facts.run_conclusion, "failure");
  assert.equal(securityReceipt.event_family, "security_alert");
  assert.equal(securityReceipt.facts.alert_state, "open");
  assert.deepEqual(validateReceipt(workflowReceipt), []);
  assert.deepEqual(validateReceipt(securityReceipt), []);
});

test("all supported fact states remain distinct", () => {
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
          security_alert: null
        }
      })
    );
    assert.equal(receipt.fact_state, factState);
  }
});

test("missing or invalid raw source and subject identity fail closed with stable reason codes", () => {
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ source: { ...fixture().source, account: undefined } }))),
    ERROR_CODES.invalidSource
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ source: { ...fixture().source, event_name: "undefined" } }))),
    ERROR_CODES.invalidSource
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ source: { ...fixture().source, delivery_id: null, source_event_id: null } }))),
    ERROR_CODES.missingSourceIdentity
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ subject: { ...fixture().subject, id: undefined } }))),
    ERROR_CODES.invalidSubject
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ subject: { ...fixture().subject, id: "undefined" } }))),
    ERROR_CODES.invalidSubject
  );
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture({ evidence: { refs: ["undefined"] } }))),
    ERROR_CODES.invalidEvidence
  );
});

test("invalid input categories fail closed and schema-invalid output is rejected", () => {
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

  const schema = loadReceiptSchema();
  schema.$defs.evidence.properties.refs.minItems = 3;
  assert.equal(
    normalizeErrorCode(() => normalizeGithubEventReceipt(fixture(), { schema })),
    ERROR_CODES.schemaValidationFailed
  );
});

test("secret-like input is rejected and cli never echoes secrets or normalized undefined identities", () => {
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

test("cli supports stdin, --input, --output, and --self-check while remaining local and deterministic", () => {
  const stdinRun = runCli([], { input: JSON.stringify(fixture()) });
  assert.equal(stdinRun.status, 0);
  const parsedStdout = JSON.parse(stdinRun.stdout);
  assert.equal(parsedStdout.event_family, "pull_request");

  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "github-event-normalizer-"));
  const inputPath = path.join(tempRoot, "input.json");
  const outputPath = path.join(tempRoot, "output.json");
  fs.writeFileSync(
    inputPath,
    JSON.stringify(
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
          security_alert: null
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
    ),
    "utf8"
  );
  const fileRun = runCli(["--input", inputPath, "--output", outputPath]);
  assert.equal(fileRun.status, 0);
  assert.equal(fileRun.stdout, "");
  assert.equal(JSON.parse(fs.readFileSync(outputPath, "utf8")).event_family, "release");

  const selfCheck = runCli(["--self-check"]);
  assert.equal(selfCheck.status, 0);
  assert.deepEqual(JSON.parse(selfCheck.stdout), createSelfCheckResult());

  for (const family of EVENT_FAMILIES) {
    assert.match(sourceText, new RegExp(`"${family}"`));
  }
  assert.doesNotMatch(sourceText, /\bfetch\s*\(/);
  assert.doesNotMatch(sourceText, /\bhttps\.(request|get)\b/);
  assert.doesNotMatch(sourceText, /\bspawnSync\([^)]*git\b/);
  assert.doesNotMatch(sourceText, /\bDiscordOS\b/);
  assert.equal(
    canonicalStringify(createErrorResult(ERROR_CODES.invalidJson)),
    "{\"ok\":false,\"reason_code\":\"github_event_normalizer_invalid_json\"}\n"
  );
});
