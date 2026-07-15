#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REGISTRY_PATH = "queue/owner-work-registry.json";
const ATLAS_REGISTRY_PATH = "repos/_stack/queue/owner-work-registry.json";
const OUTPUT_PATH = "exports/stack.project-board.owner-export.v1.json";
const BOARD_ID = "discordos:project-feedback:stack";
const STATUS_MAPPING = new Map([
  ["in-progress", { recordStatus: "active", lifecycle: "in-progress" }],
  ["planned", { recordStatus: "active", lifecycle: "planning" }],
  ["ready", { recordStatus: "active", lifecycle: "ready" }],
  ["candidate", { recordStatus: "candidate", lifecycle: "intake" }],
  ["blocked", { recordStatus: "active", lifecycle: "blocked" }]
]);
const CARD_TYPES = new Set([
  "feature", "bug", "governance", "architecture", "documentation",
  "automation", "research", "migration", "reliability", "technical-debt"
]);
const uniqueSorted = (values) => [...new Set(values)].sort((left, right) => left.localeCompare(right));
const atlasPath = (value) => `repos/_stack/${value.replaceAll("\\", "/")}`;
const normalizeLineEndings = (value) => value.replace(/\r\n?/g, "\n");

function normalizeTimestamp(value) {
  const candidate = /^\d{4}-\d{2}-\d{2}$/.test(value ?? "") ? `${value}T00:00:00.000Z` : value;
  const parsed = new Date(candidate);
  if (!candidate || Number.isNaN(parsed.getTime())) throw new Error("registry.updatedAt must be an ISO date or date-time");
  return parsed.toISOString();
}

function stringArray(item, field, allowEmpty = true) {
  if (!Array.isArray(item[field]) || item[field].some((value) => typeof value !== "string" || value.trim() === "")) {
    throw new Error(`${item.id ?? "<unknown>"}.${field} must be an array of non-empty strings`);
  }
  if (!allowEmpty && item[field].length === 0) throw new Error(`${item.id}.${field} must not be empty`);
  return item[field];
}

function mapItem(item, generatedAt, schemaVersion) {
  const mapping = STATUS_MAPPING.get(item.status);
  if (!mapping) throw new Error(`unsupported non-complete owner status for ${item.id}: ${JSON.stringify(item.status)}`);
  if (typeof item.id !== "string" || !/^STK-[A-Z0-9-]+$/.test(item.id)) throw new Error("work item id must use the STK-* format");
  if (typeof item.title !== "string" || item.title.trim() === "") throw new Error(`${item.id}.title is required`);
  if (typeof item.goal !== "string" || item.goal.trim() === "") throw new Error(`${item.id}.goal is required`);
  if (!CARD_TYPES.has(item.type)) throw new Error(`${item.id}.type is not supported`);
  if (item.priority !== null) throw new Error(`${item.id}.priority must remain null until owner prioritization is explicit`);
  const dependencies = uniqueSorted(stringArray(item, "dependencies"));
  const sourceRef = `${ATLAS_REGISTRY_PATH}#${item.id}`;
  const normalizedId = item.id.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

  return {
    idempotency_key: `pbk_stack_${normalizedId}_v1`,
    record_kind: "project-work",
    record_status: mapping.recordStatus,
    record: {
      contract_version: "atlas.card-record.v2",
      card_id: item.id,
      project_id: "_stack",
      board_id: BOARD_ID,
      title: item.title,
      description: item.goal,
      card_type: item.type,
      lifecycle: mapping.lifecycle,
      priority: null,
      owner: "_stack",
      dependencies,
      board_version: 1,
      updated_at: generatedAt,
      source_ref: sourceRef,
      extensions: { owner_status: item.status, owner_registry_schema_version: schemaVersion }
    },
    source: {
      source_id: "stack-owner-registry",
      source_ref: sourceRef,
      source_status: "current",
      source_updated_at: generatedAt
    },
    content: {
      summary: item.goal,
      objective: item.goal,
      acceptance_criteria: stringArray(item, "acceptanceCriteria", false),
      discoveries: [],
      next_actions: [],
      blockers: item.status === "blocked" ? dependencies.map((dependency) => `Blocked by ${dependency}.`) : [],
      evidence: uniqueSorted(stringArray(item, "evidence").map(atlasPath))
    },
    relationships: { parent_card_id: null, duplicate_of: null, superseded_by: null }
  };
}

export function buildProjectBoardOwnerExport(registry, registryBytes) {
  if (!registry || registry.schemaVersion !== 1 || registry.projectId !== "_stack") throw new Error("unexpected _stack owner registry identity");
  if (!Array.isArray(registry.workItems)) throw new Error("registry.workItems must be an array");
  if (registry.state === "ready-empty" && registry.workItems.length !== 0) throw new Error("ready-empty registry must contain zero work items");
  if (registry.workItems.length === 0 && registry.state !== "ready-empty") throw new Error("empty registry must declare ready-empty state");
  const ids = registry.workItems.map((item) => item.id);
  if (new Set(ids).size !== ids.length) throw new Error("owner work item ids must be unique");
  const generatedAt = normalizeTimestamp(registry.updatedAt);
  const normalizedBytes = Buffer.from(registryBytes).toString("utf8").replace(/\r\n?/g, "\n");
  const digest = crypto.createHash("sha256").update(normalizedBytes, "utf8").digest("hex");
  const sourceRevision = `sha256:${digest}`;
  const cards = registry.workItems
    .filter((item) => item.status !== "complete")
    .map((item) => mapItem(item, generatedAt, registry.schemaVersion))
    .sort((left, right) => left.record.card_id.localeCompare(right.record.card_id));

  return {
    contract_version: "atlas.project-board.owner-export.v1",
    export_id: `pbe_stack_owner_registry_${digest.slice(0, 12)}`,
    project_id: "_stack",
    board_id: BOARD_ID,
    owner: "_stack",
    adapter_id: "stack-owner-registry-v1",
    source_revision: sourceRevision,
    generated_at: generatedAt,
    sources: [{
      source_id: "stack-owner-registry",
      kind: "json",
      repository: "_stack",
      path: ATLAS_REGISTRY_PATH,
      revision: sourceRevision,
      observed_at: generatedAt
    }],
    cards,
    extensions: {
      source_digest: sourceRevision,
      source_work_item_count: registry.workItems.length,
      exported_card_count: cards.length,
      owner_queue_state: registry.state,
      owner_queue_state_reason: registry.stateReason,
      atlas_candidates_admitted: false,
      discord_mutation_authorized: false
    }
  };
}

export function renderProjectBoardOwnerExport(repoRoot) {
  const bytes = fs.readFileSync(path.join(repoRoot, REGISTRY_PATH));
  return `${JSON.stringify(buildProjectBoardOwnerExport(JSON.parse(bytes.toString("utf8")), bytes), null, 2)}\n`;
}

export function runProjectBoardOwnerExport(argv, repoRoot = process.cwd()) {
  const check = argv.includes("--check");
  const unknown = argv.filter((argument) => argument !== "--check");
  if (unknown.length > 0) throw new Error(`unknown argument: ${unknown[0]}`);
  const rendered = renderProjectBoardOwnerExport(repoRoot);
  const outputPath = path.join(repoRoot, OUTPUT_PATH);
  if (check) {
    if (!fs.existsSync(outputPath) || normalizeLineEndings(fs.readFileSync(outputPath, "utf8")) !== normalizeLineEndings(rendered)) {
      throw new Error(`${OUTPUT_PATH} is stale; run pnpm board:export`);
    }
    process.stdout.write(`stack-project-board-owner-export: ok (${JSON.parse(rendered).cards.length} cards)\n`);
    return;
  }
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, rendered, "utf8");
  process.stdout.write(`stack-project-board-owner-export: wrote ${OUTPUT_PATH}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    runProjectBoardOwnerExport(process.argv.slice(2));
  } catch (error) {
    console.error(`stack-project-board-owner-export: ${error.message}`);
    process.exitCode = 1;
  }
}
