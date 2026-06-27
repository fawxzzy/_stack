import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import test from "node:test";
import { emitDryRunPacket } from "./data-gateway-packet-emitter.mjs";
import { reviewDryRunPacket } from "./data-gateway-packet-review.mjs";
import { runPacketWrapper } from "./data-gateway-packet-wrapper.mjs";

function toPosixAbsolute(...segments) {
  return path.resolve(...segments).replace(/\\/g, "/");
}

const WORKFLOW_CASES = [
  {
    lane: "supabase-export-approval",
    packet: {
      packet_purpose: "supabase-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "export",
        source_refs: ["docs/ops/FITNESS-SUPABASE-PROFILE-DATA-HYGIENE-EXPORT-PACKET-1-2026-05-24.md"],
        captured_at: "2026-05-27T00:00:00Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["bounded approval rows only"]
      }
    }
  },
  {
    lane: "vercel-dependency-deletion-decision",
    packet: {
      packet_purpose: "vercel-review",
      source_provenance: {
        owner_surface: "repos/_stack",
        source_type: "receipt-chain",
        source_refs: ["docs/ops/VERCEL-HELPER-SURFACE-DELETION-DECISION-2026-05-25.md"],
        captured_at: "2026-05-27T00:00:00Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["candidate helper dependency scope only"]
      }
    }
  },
  {
    lane: "model-prompt-context-packet",
    packet: {
      packet_purpose: "model-context-packet",
      downstream_target_class: "model",
      source_provenance: {
        owner_surface: "docs/memory/profiles",
        source_type: "local-file-set",
        source_refs: [
          "docs/memory/profiles/zachariah_workflow_profile.md",
          "docs/PLAYBOOK_NOTES.md"
        ],
        captured_at: "2026-06-18T00:00:00Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["prompt-safe context only", "bounded local context packet"]
      },
      minimal_useful_payload: {
        context_sections: ["workflow-profile", "playbook-notes"],
        prompt_ready: true,
        token_budget: "bounded"
      },
      export_exclusion_summary: {
        omitted_classes: ["raw-transcript", "absolute-paths", "secret-values"],
        reason: "minimum-necessary prompt context"
      },
      receipt_or_proof_ref: "docs/atlas-book/09-automation-and-command-candidates.md"
    }
  },
  {
    lane: "stack-update-draft-downstream-package",
    packet: {
      packet_purpose: "stack-update-draft-package",
      downstream_target_class: "automation-helper",
      source_provenance: {
        owner_surface: "repos/_stack",
        source_type: "receipt-chain",
        source_refs: ["repos/_stack/receipts/stack-update-draft-first-implementation-worker-proof-and-receipt-packet-2-2026-06-08.md"],
        captured_at: "2026-06-18T00:00:00Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["downstream package only", "no publication or mutation payload"]
      },
      minimal_useful_payload: {
        repo: "repos/fawxzzy-fitness",
        package_state: "package-ready",
        proof_ref: "repos/fawxzzy-fitness/docs/releases/fitness/2026/2026-06-03-fitness-2026.06.03-1.md",
        ledger_ref: "repos/fawxzzy-fitness/docs/releases/RELEASE_LEDGER.jsonl"
      },
      export_exclusion_summary: {
        omitted_classes: ["discord-post-copy", "owner-ledger-mutations"],
        reason: "downstream package boundary only"
      },
      receipt_or_proof_ref: "repos/_stack/receipts/stack-update-draft-first-implementation-worker-proof-and-receipt-packet-2-2026-06-08.md"
    }
  },
  {
    lane: "fitness-qa-llel-proof-packet",
    packet: {
      packet_purpose: "fitness-qa-llel-proof-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/fitness/llel-captures/latest/report.json",
          "runtime/receipts/dev/dev-server.latest.json",
          "runtime/fitness/qa-auth-summary.json",
          "repos/fawxzzy-fitness/scripts/qa/progression-visual-receipt.mjs",
          "repos/fawxzzy-fitness/scripts/qa/fitness-ui-checkpoint.mjs"
        ],
        captured_at: "2026-06-14T06:33:00Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["proof metadata only", "release-readiness prep without screenshot binaries"]
      },
      minimal_useful_payload: {
        evidence_profile: "web_visual",
        evidence_tier: "emulated_browser",
        route_count: 3,
        screenshots_produced: true,
        auth_user_present: true
      },
      export_exclusion_summary: {
        omitted_classes: ["screenshot-binaries", "storage-state-file", "raw-dev-logs"],
        reason: "bounded proof summary for review only"
      },
      receipt_or_proof_ref: "docs/ops/AI-REPETITION-TO-AUTOMATION-PIPELINE-QA-LLEL-PROOF-PACKET-PREPARATION-CONTRACT-FREEZE-PASS-48-2026-06-09.md"
    }
  },
  {
    lane: "fitness-feedback-reviewed-task-packet",
    packet: {
      packet_purpose: "fitness-feedback-reviewed-task-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/feedback-board/monetization-seeded.json",
          "runtime/feedback-tasks/latest.json",
          "runtime/feedback-tasks/latest.md",
          "runtime/feedback-tasks/codex-prompts.md",
          "repos/fawxzzy-fitness/scripts/generate-feedback-task-packets.mjs",
          "repos/fawxzzy-fitness/scripts/generate-feedback-task-packets.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-FEEDBACK-REVIEWED-TASKS.md"
        ],
        captured_at: "2026-06-10T21:29:14.637Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["reviewed packets only", "draft prompts without board mutation or task execution"]
      },
      minimal_useful_payload: {
        packet_count: 20,
        prompt_surface_present: true,
        documentation_contract_present: true,
        human_review_required: true
      },
      export_exclusion_summary: {
        omitted_classes: ["discord-user-ids", "attachment-bytes", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded reviewed-task packet surface for local-only implementation review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-FEEDBACK-REVIEWED-TASKS.md"
    }
  },
  {
    lane: "fitness-feedback-board-export-packet",
    packet: {
      packet_purpose: "fitness-feedback-board-export-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/feedback-board/monetization-seeded.json",
          "runtime/feedback-board/monetization-seeded.md",
          "runtime/feedback-board/codex-drafts.md",
          "repos/fawxzzy-fitness/scripts/export-feedback-board.mjs",
          "repos/fawxzzy-fitness/scripts/export-feedback-board.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-FEEDBACK-BOARD-EXPORTS.md"
        ],
        captured_at: "2026-06-10T21:29:14.637Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["one-board export only", "review-only codex drafts without ticket creation or ATLAS mutation"]
      },
      minimal_useful_payload: {
        board_markdown_present: true,
        board_json_present: true,
        codex_drafts_present: true,
        masked_identity_export: true
      },
      export_exclusion_summary: {
        omitted_classes: ["raw-reporter-ids", "attachment-bytes", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded one-board export and draft surface for local-only review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-FEEDBACK-BOARD-EXPORTS.md"
    }
  },
  {
    lane: "fitness-discord-inventory-noise-packet",
    packet: {
      packet_purpose: "fitness-discord-inventory-noise-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/discord-inventory/latest.json",
          "runtime/discord-inventory/latest.md",
          "runtime/discord-noise/latest.json",
          "runtime/discord-noise/latest.md",
          "repos/fawxzzy-fitness/scripts/discord-server-inventory.mjs",
          "repos/fawxzzy-fitness/scripts/discord-server-inventory.test.mjs",
          "repos/fawxzzy-fitness/scripts/discord-noise-audit.mjs",
          "repos/fawxzzy-fitness/scripts/discord-noise-audit.test.mjs",
          "repos/fawxzzy-fitness/scripts/discord-noise-apply.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-DISCORD-INVENTORY-NOISE-AUDITS.md"
        ],
        captured_at: "2026-06-18T22:56:33-04:00",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["inventory snapshot and noise audit only", "apply lane remains recommendation-only without Discord mutation"]
      },
      minimal_useful_payload: {
        inventory_markdown_present: true,
        inventory_json_present: true,
        noise_markdown_present: true,
        noise_json_present: true
      },
      export_exclusion_summary: {
        omitted_classes: ["discord-permission-mutations", "discord-message-sends", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded inventory and noise review surface for local-only operator inspection"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-DISCORD-INVENTORY-NOISE-AUDITS.md"
    }
  },
  {
    lane: "fitness-discord-feedback-export-packet",
    packet: {
      packet_purpose: "fitness-discord-feedback-export-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/discord-feedback/latest.json",
          "runtime/discord-feedback/latest.md",
          "repos/fawxzzy-fitness/scripts/export-discord-bug-reports.mjs",
          "repos/fawxzzy-fitness/scripts/export-discord-bug-reports.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-DISCORD-FEEDBACK-EXPORTS.md"
        ],
        captured_at: "2026-06-18T23:02:25-04:00",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["filtered report export only", "masked reporter provenance without forum or row mutation"]
      },
      minimal_useful_payload: {
        feedback_markdown_present: true,
        feedback_json_present: true,
        masked_reporter_ids: true
      },
      export_exclusion_summary: {
        omitted_classes: ["raw-reporter-ids", "forum-thread-creation", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded feedback export surface for local-only review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-DISCORD-FEEDBACK-EXPORTS.md"
    }
  },
  {
    lane: "fitness-release-readiness-report-packet",
    packet: {
      packet_purpose: "fitness-release-readiness-report-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/fitness/release-readiness.latest.json",
          "runtime/fitness/release-readiness.latest.md",
          "repos/fawxzzy-fitness/scripts/release/fitness-release-readiness.mjs",
          "repos/fawxzzy-fitness/scripts/release/fitness-release-readiness.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-RELEASE-READINESS-REPORTS.md"
        ],
        captured_at: "2026-06-18T23:12:29-04:00",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["bounded readiness report only", "failing readiness remains reportable without deploy or ledger mutation"]
      },
      minimal_useful_payload: {
        readiness_markdown_present: true,
        readiness_json_present: true,
        production_deploy_ready_boolean_present: true
      },
      export_exclusion_summary: {
        omitted_classes: ["deploy-mutations", "release-ledger-writes", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded production readiness report surface for local-only review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-RELEASE-READINESS-REPORTS.md"
    }
  },
  {
    lane: "fitness-feedback-phase-readiness-report-packet",
    packet: {
      packet_purpose: "fitness-feedback-phase-readiness-report-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/feedback-phase/latest.json",
          "runtime/feedback-phase/latest.md",
          "repos/fawxzzy-fitness/scripts/check-feedback-phase-readiness.mjs",
          "repos/fawxzzy-fitness/scripts/check-feedback-phase-readiness.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-FEEDBACK-PHASE-READINESS-REPORTS.md"
        ],
        captured_at: "2026-06-18T23:56:16-04:00",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["bounded phase-gate report only", "failing reaction lookup remains reportable without Discord or row mutation"]
      },
      minimal_useful_payload: {
        phase_markdown_present: true,
        phase_json_present: true,
        next_report_present: true,
        required_report_present: true
      },
      export_exclusion_summary: {
        omitted_classes: ["discord-mutations", "supabase-row-mutations", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded feedback phase readiness report surface for local-only review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-FEEDBACK-PHASE-READINESS-REPORTS.md"
    }
  },
  {
    lane: "fitness-discord-community-doctor-report-packet",
    packet: {
      packet_purpose: "fitness-discord-community-doctor-report-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/discord-community/latest.json",
          "runtime/discord-community/latest.md",
          "repos/fawxzzy-fitness/scripts/doctor-discord-community.mjs",
          "repos/fawxzzy-fitness/scripts/doctor-discord-community.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-DISCORD-COMMUNITY-DOCTOR-REPORTS.md"
        ],
        captured_at: "2026-06-19T00:05:43-04:00",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["bounded doctor report only", "failing or warning health checks remain reportable without Discord or row mutation"]
      },
      minimal_useful_payload: {
        doctor_markdown_present: true,
        doctor_json_present: true,
        check_summary_present: true,
        pass_warn_fail_counts_present: true
      },
      export_exclusion_summary: {
        omitted_classes: ["discord-mutations", "supabase-row-mutations", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded discord community doctor report surface for local-only review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-DISCORD-COMMUNITY-DOCTOR-REPORTS.md"
    }
  },
  {
    lane: "fitness-typecheck-debt-inventory-report-packet",
    packet: {
      packet_purpose: "fitness-typecheck-debt-inventory-report-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/receipts/typecheck/typecheck-debt.latest.json",
          "runtime/receipts/typecheck/typecheck-debt.latest.md",
          "repos/fawxzzy-fitness/scripts/typecheck-debt-inventory.mjs",
          "repos/fawxzzy-fitness/scripts/typecheck-debt-inventory.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-TYPECHECK-DEBT-INVENTORY-REPORTS.md"
        ],
        captured_at: "2026-06-19T04:30:00-04:00",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["bounded typecheck debt report only", "failing typecheck results remain reportable without source mutation"]
      },
      minimal_useful_payload: {
        receipt_json_present: true,
        receipt_markdown_present: true,
        summary_counts_present: true,
        recommended_lane_summary_present: true
      },
      export_exclusion_summary: {
        omitted_classes: ["source-file-mutations", "automatic-pull-request-creation", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded typecheck debt inventory report surface for local-only review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-TYPECHECK-DEBT-INVENTORY-REPORTS.md"
    }
  },
  {
    lane: "fitness-pilot-readiness-report-packet",
    packet: {
      packet_purpose: "fitness-pilot-readiness-report-packet",
      downstream_target_class: "human-review",
      source_provenance: {
        owner_surface: "repos/fawxzzy-fitness",
        source_type: "local-file-set",
        source_refs: [
          "runtime/fitness/pilot-readiness/latest.json",
          "runtime/fitness/pilot-readiness/latest.md",
          "repos/fawxzzy-fitness/scripts/evaluate-fitness-pilot-readiness.mjs",
          "repos/fawxzzy-fitness/scripts/evaluate-fitness-pilot-readiness.test.mjs",
          "repos/fawxzzy-fitness/docs/ops/FITNESS-PILOT-READINESS-REPORTS.md"
        ],
        captured_at: "2026-06-19T05:55:00-04:00",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["bounded pilot-readiness report only", "stay-shadow and rollback outcomes remain reportable without rollout mutation"]
      },
      minimal_useful_payload: {
        readiness_json_present: true,
        readiness_markdown_present: true,
        decision_present: true,
        threshold_checks_present: true
      },
      export_exclusion_summary: {
        omitted_classes: ["rollout-mutations", "source-receipt-mutations", "automatic-issue-creation", "atlas-writes"],
        reason: "bounded pilot-readiness report surface for local-only review"
      },
      receipt_or_proof_ref: "repos/fawxzzy-fitness/docs/ops/FITNESS-PILOT-READINESS-REPORTS.md"
    }
  },
  {
    lane: "discordos-trust-boundary",
    packet: {
      packet_purpose: "discordos-boundary-handoff",
      source_provenance: {
        owner_surface: "repos/DiscordOS",
        source_type: "receipt-chain",
        source_refs: ["repos/DiscordOS/docs/ops/feedback-lookup-transport-neutral-externally-backed-live-provider-trust-boundary-package-16-2026-05-27.md"],
        captured_at: "2026-05-27T00:00:00Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["trust-boundary payload only"]
      }
    }
  }
];

function buildValidPacket(overrides = {}) {
  return {
    packet_purpose: "supabase-review",
    packet_schema_version: "ldg.packet.v1",
    downstream_target_class: "human-review",
    sensitivity_label: "sensitive",
    source_provenance: {
      owner_surface: "repos/fawxzzy-fitness",
      source_type: "export",
      source_refs: ["runtime/exports/example.json"],
      captured_at: "2026-05-27T00:00:00Z",
      capture_method: "local-script"
    },
    transformation_record: {
      normalized: true,
      validated: true,
      redacted: true,
      sensitivity_classified: true,
      deduped: true,
      extracted: true,
      notes: ["row scope narrowed locally"]
    },
    validation_result: "pass",
    redaction_status: "applied",
    dedupe_status: "applied",
    minimal_useful_payload: {
      approved_rows: ["candidate-01", "candidate-02"]
    },
    export_exclusion_summary: {
      omitted_classes: ["raw-emails", "token-material"],
      reason: "minimum-necessary"
    },
    receipt_or_proof_ref: "docs/ops/example.md",
    ...overrides
  };
}

async function emitReviewablePacket({ lane }) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const emitted = await emitDryRunPacket({
    inputPath: packetPath,
    lane,
    artifactRoot: tempDir
  });

  assert.equal(emitted.ok, true);

  return {
    tempDir,
    packetPath,
    emitted
  };
}

async function emitWorkflowPacket({ lane, packetOverrides }) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket(packetOverrides)), "utf8");

  const emitted = await emitDryRunPacket({
    inputPath: packetPath,
    lane,
    artifactRoot: tempDir
  });

  assert.equal(emitted.ok, true);

  return {
    tempDir,
    packetPath,
    emitted
  };
}

async function emitReviewedWorkflowPacket({ lane, packetOverrides }) {
  const emittedPacket = await emitWorkflowPacket({ lane, packetOverrides });
  const reviewed = await reviewDryRunPacket({
    artifactDir: emittedPacket.emitted.artifactDir,
    reviewer: "codex",
    disposition: "approved",
    reviewerNote: "local review complete"
  });

  assert.equal(reviewed.ok, true);

  return {
    ...emittedPacket,
    reviewed
  };
}

async function writePacketToTemp(packetOverrides = {}) {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket(packetOverrides)), "utf8");

  return {
    tempDir,
    packetPath
  };
}

test("validate-only succeeds for a valid packet without writing artifacts", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "validate-only",
    sourcePath: packetPath
  });

  assert.equal(result.ok, true);
  assert.equal(result.validationState, "pass");
  assert.equal(result.wrapperStage, "validate");
  assert.equal(result.noSendAttestation.downstream_send_performed, false);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("validate-only fails closed for an invalid packet", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket();
  delete packet.packet_purpose;
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "validate-only",
    sourcePath: packetPath
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "validate");
  assert.equal(result.validationState, "fail");
  assert.match(result.errors.join("\n"), /packet_purpose must be a non-empty string/);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("emit-dry-run succeeds only after validation and preserves no-send state", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");

  const result = await runPacketWrapper({
    lane: "discordos-boundary-handoff",
    mode: "emit-dry-run",
    sourcePath: packetPath,
    artifactRoot: tempDir
  });

  assert.equal(result.ok, true);
  assert.equal(result.validationState, "pass");
  assert.equal(result.wrapperStage, "emit");
  assert.equal(result.noSendAttestation.remote_target_selected, false);
  assert.ok(result.artifactDir.startsWith(tempDir));
  assert.ok(Object.values(result.emittedArtifacts).every((filePath) => filePath.startsWith(tempDir)));

  const metadata = JSON.parse(await fs.readFile(result.emittedArtifacts.metadata, "utf8"));
  assert.equal(metadata.emit_mode, "dry-run");
  assert.equal(metadata.downstream_send_performed, false);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("emit-dry-run does not bypass primitive validation checks", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket({
    sensitivity_label: "secret-ish"
  });
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await runPacketWrapper({
    lane: "vercel-deletion-review",
    mode: "emit-dry-run",
    sourcePath: packetPath,
    artifactRoot: tempDir
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "validate");
  assert.equal(result.validationState, "fail");
  assert.match(result.errors.join("\n"), /sensitivity_label must be one of/);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("validate-only fails closed when packet refs are not ATLAS-root-relative", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket({
    source_provenance: {
      owner_surface: toPosixAbsolute("..", "fawxzzy-fitness"),
      source_type: "export",
      source_refs: ["runtime/../runtime/exports/example.json"],
      captured_at: "2026-05-27T00:00:00Z",
      capture_method: "local-script"
    }
  });
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "validate-only",
    sourcePath: packetPath
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "validate");
  assert.equal(result.validationState, "fail");
  assert.match(result.errors.join("\n"), /source_provenance\.owner_surface must not be absolute or protocol-qualified/);
  assert.match(result.errors.join("\n"), /source_provenance\.source_refs\[0\] must be a normalized ATLAS-root-relative path without dot segments/);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("review-only succeeds on the fifteen admitted workflow classes and preserves no-send state", async () => {
  for (const workflowCase of WORKFLOW_CASES) {
    const { tempDir, emitted } = await emitWorkflowPacket({
      lane: workflowCase.lane,
      packetOverrides: workflowCase.packet
    });

    const result = await runPacketWrapper({
      lane: workflowCase.lane,
      mode: "review-only",
      artifactDir: emitted.artifactDir,
      reviewer: "codex",
      disposition: "approved",
      reviewerNote: "local review complete"
    });

    assert.equal(result.ok, true);
    assert.equal(result.wrapperStage, "review");
    assert.equal(result.validationState, "pass");
    assert.equal(result.reviewState, "recorded");
    assert.equal(result.reviewer, "codex");
    assert.equal(result.disposition, "approved");
    assert.equal(result.lane, workflowCase.lane);
    assert.equal(result.noSendAttestation.downstream_send_performed, false);
    assert.equal(result.noSendAttestation.automatic_handoff_authorized, false);
    assert.ok(result.reviewArtifacts.review.startsWith(tempDir));
    assert.ok(result.reviewArtifacts.metadata.startsWith(tempDir));

    const reviewMetadata = JSON.parse(await fs.readFile(result.reviewArtifacts.metadata, "utf8"));
    assert.equal(reviewMetadata.review_mode, "local-only");
    assert.equal(reviewMetadata.disposition, "approved");
    assert.equal(reviewMetadata.lane, workflowCase.lane);
    assert.equal(reviewMetadata.no_send_attestation.downstream_send_performed, false);

    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

test("review-only fails closed on missing packet prerequisites", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "review-only",
    artifactDir: tempDir,
    reviewer: "codex",
    disposition: "approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "review");
  assert.equal(result.reviewState, "fail");
  assert.match(result.errors.join("\n"), /Missing required artifact: packet\.json\./);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("review-only does not bypass primitive review checks", async () => {
  const { tempDir, emitted } = await emitReviewablePacket({
    lane: "discordos-feedback"
  });

  const metadata = JSON.parse(await fs.readFile(emitted.artifacts.metadata, "utf8"));
  metadata.emit_mode = "send";
  await fs.writeFile(emitted.artifacts.metadata, `${JSON.stringify(metadata, null, 2)}\n`, "utf8");

  const result = await runPacketWrapper({
    lane: "discordos-feedback",
    mode: "review-only",
    artifactDir: emitted.artifactDir,
    reviewer: "codex",
    disposition: "needs-revision"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "review");
  assert.equal(result.reviewState, "fail");
  assert.match(result.errors.join("\n"), /emit_mode must remain dry-run/);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("wrapper CLI rejects transport-shaped flags at the review-only entrypoint in package 2", async () => {
  const { tempDir, emitted } = await emitReviewablePacket({
    lane: "supabase-review"
  });

  const scriptPath = path.resolve("scripts/data-gateway-packet-wrapper.mjs");

  for (const flag of ["--target", "--secret", "--send"]) {
    const result = spawnSync(
      process.execPath,
      [
        scriptPath,
        "--lane", "supabase-review",
        "--mode", "review-only",
        "--artifact-dir", emitted.artifactDir,
        "--reviewer", "codex",
        "--disposition", "approved",
        flag, "example"
      ],
      {
        cwd: path.resolve("."),
        encoding: "utf8"
      }
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${flag} is not admitted in wrapper package 2`));
  }

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("proof-only succeeds on the fifteen admitted workflow classes and preserves no-send state", async () => {
  for (const workflowCase of WORKFLOW_CASES) {
    const { tempDir, emitted } = await emitReviewedWorkflowPacket({
      lane: workflowCase.lane,
      packetOverrides: workflowCase.packet
    });

    const result = await runPacketWrapper({
      lane: workflowCase.lane,
      mode: "proof-only",
      artifactDir: emitted.artifactDir
    });

    assert.equal(result.ok, true);
    assert.equal(result.wrapperStage, "proof");
    assert.equal(result.validationState, "pass");
    assert.equal(result.reviewState, "approved");
    assert.equal(result.proofState, "packaged");
    assert.equal(result.lane, workflowCase.lane);
    assert.equal(result.noSendAttestation.downstream_send_performed, false);
    assert.equal(result.noSendAttestation.automatic_handoff_authorized, false);
    assert.ok(result.proofArtifacts.summary.startsWith(tempDir));
    assert.ok(result.proofArtifacts.metadata.startsWith(tempDir));

    const proofMetadata = JSON.parse(await fs.readFile(result.proofArtifacts.metadata, "utf8"));
    assert.equal(proofMetadata.proof_mode, "local-proof-only");
    assert.equal(proofMetadata.review_snapshot.disposition, "approved");
    assert.equal(proofMetadata.lane, workflowCase.lane);
    assert.equal(proofMetadata.no_send_attestation.downstream_send_performed, false);

    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

test("proof-only fails closed on missing reviewed packet prerequisites", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "proof-only",
    artifactDir: tempDir
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "proof");
  assert.equal(result.proofState, "fail");
  assert.match(result.errors.join("\n"), /Missing required artifact: packet\.json\./);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("proof-only does not bypass primitive proof-packager checks", async () => {
  const { tempDir, emitted } = await emitReviewedWorkflowPacket({
    lane: "discordos-feedback",
    packetOverrides: {
      packet_purpose: "discordos-boundary-handoff",
      source_provenance: {
        owner_surface: "repos/DiscordOS",
        source_type: "receipt-chain",
        source_refs: ["repos/DiscordOS/docs/ops/example.md"],
        captured_at: "2026-05-27T00:00:00Z",
        capture_method: "local-script"
      },
      transformation_record: {
        normalized: true,
        validated: true,
        redacted: true,
        sensitivity_classified: true,
        deduped: true,
        extracted: true,
        notes: ["trust-boundary payload only"]
      }
    }
  });

  const reviewMetadataPath = path.join(emitted.artifactDir, "packet-review-metadata.json");
  const reviewMetadata = JSON.parse(await fs.readFile(reviewMetadataPath, "utf8"));
  reviewMetadata.disposition = "auto-approved";
  await fs.writeFile(reviewMetadataPath, `${JSON.stringify(reviewMetadata, null, 2)}\n`, "utf8");

  const result = await runPacketWrapper({
    lane: "discordos-feedback",
    mode: "proof-only",
    artifactDir: emitted.artifactDir
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "proof");
  assert.equal(result.proofState, "fail");
  assert.match(result.errors.join("\n"), /disposition must be one of/);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("wrapper CLI rejects transport-shaped flags at the proof-only entrypoint in package 3", async () => {
  const { tempDir, emitted } = await emitReviewedWorkflowPacket({
    lane: "supabase-review",
    packetOverrides: {
      packet_purpose: "supabase-review"
    }
  });

  const scriptPath = path.resolve("scripts/data-gateway-packet-wrapper.mjs");

  for (const flag of ["--target", "--secret", "--send"]) {
    const result = spawnSync(
      process.execPath,
      [
        scriptPath,
        "--lane", "supabase-review",
        "--mode", "proof-only",
        "--artifact-dir", emitted.artifactDir,
        flag, "example"
      ],
      {
        cwd: path.resolve("."),
        encoding: "utf8"
      }
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${flag} is not admitted in wrapper package 3`));
  }

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain succeeds on the fifteen admitted workflow classes and stays receipt-ready local-only", async () => {
  for (const workflowCase of WORKFLOW_CASES) {
    const { tempDir, packetPath } = await writePacketToTemp(workflowCase.packet);

    const result = await runPacketWrapper({
      lane: workflowCase.lane,
      mode: "full-local-chain",
      sourcePath: packetPath,
      artifactRoot: tempDir,
      reviewer: "codex",
      disposition: "approved",
      reviewerNote: "full local chain complete"
    });

    assert.equal(result.ok, true);
    assert.equal(result.lane, workflowCase.lane);
    assert.equal(result.mode, "full-local-chain");
    assert.equal(result.wrapperStage, "proof");
    assert.equal(result.validationState, "pass");
    assert.equal(result.reviewState, "recorded");
    assert.equal(result.disposition, "approved");
    assert.equal(result.proofState, "packaged");
    assert.equal(typeof result.packetId, "string");
    assert.ok(result.packetId.length > 0);
    assert.equal(result.noSendAttestation.downstream_send_performed, false);
    assert.equal(result.noSendAttestation.downstream_execution_performed, false);
    assert.equal(result.noSendAttestation.remote_target_selected, false);
    assert.equal(result.noSendAttestation.automatic_handoff_authorized, false);
    assert.ok(result.artifactDir.startsWith(tempDir));
    assert.ok(result.emittedArtifacts.packet.startsWith(tempDir));
    assert.ok(result.emittedArtifacts.metadata.startsWith(tempDir));
    assert.ok(result.reviewArtifacts.review.startsWith(tempDir));
    assert.ok(result.reviewArtifacts.metadata.startsWith(tempDir));
    assert.ok(result.proofArtifacts.summary.startsWith(tempDir));
    assert.ok(result.proofArtifacts.metadata.startsWith(tempDir));
    assert.equal(path.dirname(result.emittedArtifacts.packet), result.artifactDir);
    assert.equal(path.dirname(result.reviewArtifacts.review), result.artifactDir);
    assert.equal(path.dirname(result.proofArtifacts.summary), result.artifactDir);

    const artifactNames = (await fs.readdir(result.artifactDir)).sort();
    assert.deepEqual(artifactNames, [
      "packet-metadata.json",
      "packet-review-metadata.json",
      "packet-review.md",
      "packet-summary.md",
      "packet.json",
      "proof-metadata.json",
      "proof-summary.md"
    ]);

    const proofMetadata = JSON.parse(await fs.readFile(result.proofArtifacts.metadata, "utf8"));
    assert.equal(proofMetadata.lane, workflowCase.lane);
    assert.equal(proofMetadata.proof_mode, "local-proof-only");
    assert.equal(proofMetadata.review_snapshot.disposition, "approved");
    assert.equal(proofMetadata.no_send_attestation.downstream_send_performed, false);

    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

test("full-local-chain fails at validation and stops before artifact emission", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const packet = buildValidPacket();
  delete packet.packet_purpose;
  await fs.writeFile(packetPath, JSON.stringify(packet), "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: tempDir,
    reviewer: "codex",
    disposition: "approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "validate");
  assert.equal(result.validationState, "fail");
  assert.equal(result.artifactDir, null);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries, ["packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain fails at emit and stops before review or proof", async () => {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "ldg-wrapper-"));
  const packetPath = path.join(tempDir, "packet.json");
  const blockedArtifactRoot = path.join(tempDir, "artifact-root-blocker");
  await fs.writeFile(packetPath, JSON.stringify(buildValidPacket()), "utf8");
  await fs.writeFile(blockedArtifactRoot, "blocked", "utf8");

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: blockedArtifactRoot,
    reviewer: "codex",
    disposition: "approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "emit");
  assert.equal(result.validationState, "pass");
  assert.equal(result.reviewState, undefined);
  assert.equal(result.proofState, undefined);

  const remainingEntries = await fs.readdir(tempDir);
  assert.deepEqual(remainingEntries.sort(), ["artifact-root-blocker", "packet.json"]);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain fails at review and does not run proof", async () => {
  const { tempDir, packetPath } = await writePacketToTemp();

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: tempDir,
    reviewer: "codex",
    disposition: "auto-approved"
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "review");
  assert.equal(result.validationState, "pass");
  assert.equal(result.reviewState, "fail");
  assert.ok(result.artifactDir.startsWith(tempDir));
  assert.ok(result.emittedArtifacts.packet.startsWith(tempDir));
  assert.equal(await fs.stat(path.join(result.artifactDir, "packet.json")).then(() => true, () => false), true);
  assert.equal(await fs.stat(path.join(result.artifactDir, "packet-review.md")).then(() => true, () => false), false);
  assert.equal(await fs.stat(path.join(result.artifactDir, "proof-summary.md")).then(() => true, () => false), false);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("full-local-chain fails at proof and does not downgrade primitive proof failure", async () => {
  const { tempDir, packetPath } = await writePacketToTemp();

  const result = await runPacketWrapper({
    lane: "supabase-review",
    mode: "full-local-chain",
    sourcePath: packetPath,
    artifactRoot: tempDir,
    reviewer: "codex",
    disposition: "approved",
    stageHooks: {
      async afterReview({ artifactDir }) {
        const reviewMetadataPath = path.join(artifactDir, "packet-review-metadata.json");
        const reviewMetadata = JSON.parse(await fs.readFile(reviewMetadataPath, "utf8"));
        reviewMetadata.disposition = "auto-approved";
        await fs.writeFile(reviewMetadataPath, `${JSON.stringify(reviewMetadata, null, 2)}\n`, "utf8");
      }
    }
  });

  assert.equal(result.ok, false);
  assert.equal(result.failureStage, "proof");
  assert.equal(result.validationState, "pass");
  assert.equal(result.reviewState, "recorded");
  assert.equal(result.proofState, "fail");
  assert.equal(await fs.stat(path.join(result.artifactDir, "packet-review.md")).then(() => true, () => false), true);
  assert.equal(await fs.stat(path.join(result.artifactDir, "proof-summary.md")).then(() => true, () => false), false);

  await fs.rm(tempDir, { recursive: true, force: true });
});

test("wrapper CLI rejects transport-shaped flags at the full-local-chain entrypoint in package 4", async () => {
  const { tempDir, packetPath } = await writePacketToTemp();
  const scriptPath = path.resolve("scripts/data-gateway-packet-wrapper.mjs");

  for (const flag of ["--target", "--secret", "--send"]) {
    const result = spawnSync(
      process.execPath,
      [
        scriptPath,
        "--lane", "supabase-review",
        "--mode", "full-local-chain",
        "--source", packetPath,
        "--artifact-root", tempDir,
        "--reviewer", "codex",
        "--disposition", "approved",
        flag, "example"
      ],
      {
        cwd: path.resolve("."),
        encoding: "utf8"
      }
    );

    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`${flag} is not admitted in wrapper package 4`));
  }

  await fs.rm(tempDir, { recursive: true, force: true });
});
