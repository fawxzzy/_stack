import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  loadJson,
  loadKnownSchema,
  validateJsonSchema,
} from "../../packages/atlas-contracts/scripts/lib/validate-json-schema.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const PARITY_LANGUAGE = /\b(?:same as|match(?:es|ed|ing)?|carry over|duplicate this|make it like|reuse|already solved|same component|same style|same behavior)\b/i;
const PWA_LANGUAGE = /\b(?:pwa|standalone|home screen|safe[- ]area|browser toolbar|display-mode)\b/i;
const VISUAL_LANGUAGE = /\b(?:ui|visual|screen|route|layout|spacing|color|icon|button|card|modal|nav|hud|animation|responsive|mobile)\b/i;
const TEXT_EXTENSIONS = new Set([
  ".cjs", ".css", ".html", ".js", ".json", ".jsx", ".md", ".mjs", ".ps1",
  ".psm1", ".py", ".scss", ".sql", ".toml", ".ts", ".tsx", ".txt", ".yaml", ".yml",
]);
const IGNORED_DIRECTORIES = new Set([
  ".git", ".next", ".turbo", ".vercel", "build", "coverage", "dist", "node_modules",
  "runtime", "secrets", "tmp",
]);
const STOP_WORDS = new Set([
  "about", "after", "again", "also", "before", "being", "behavior", "between", "change", "changes",
  "could", "every", "from", "have", "implement", "into", "must", "only", "should", "task", "that", "their",
  "there", "these", "they", "this", "through", "user", "using", "where", "which", "with", "would",
]);

export class EngineeringMemoryIntakeError extends Error {}

function digest(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) throw new EngineeringMemoryIntakeError(`Unsupported argument: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new EngineeringMemoryIntakeError(`${argument} requires a value.`);
    const key = argument.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    options[key] = value;
    index += 1;
  }
  for (const key of ["jobEnvelope", "sourceTextFile", "cardRecord", "searchRecord", "workspaceRoot"]) {
    if (!options[key]) throw new EngineeringMemoryIntakeError(`Missing required argument: ${key}.`);
  }
  return options;
}

function insideRoot(root, candidate, label) {
  const resolved = path.resolve(root, candidate);
  const relative = path.relative(root, resolved).replaceAll("\\", "/");
  if (!relative || relative.startsWith("../") || path.isAbsolute(relative)) {
    throw new EngineeringMemoryIntakeError(`${label} must resolve inside the Atlas root.`);
  }
  const segments = relative.toLowerCase().split("/");
  if (segments.includes("secrets") || segments.some((segment) => segment === ".env" || segment.startsWith(".env."))) {
    throw new EngineeringMemoryIntakeError(`${label} cannot resolve through a sensitive path.`);
  }
  return { resolved, relative };
}

function slug(value, fallback = "task") {
  const result = String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 72);
  return result || fallback;
}

function normalizeTitle(job, sourceText) {
  const objective = String(job.objective ?? "").trim();
  if (objective) return objective;
  const firstContent = sourceText.split(/\r?\n/).map((line) => line.replace(/^\s*#+\s*/, "").trim()).find(Boolean);
  return firstContent?.slice(0, 160) || "Governed engineering task";
}

function classifyTask(sourceText, title) {
  const text = `${title}\n${sourceText}`;
  if (PARITY_LANGUAGE.test(text)) return "ui_parity";
  if (PWA_LANGUAGE.test(text)) return "pwa_layout";
  if (VISUAL_LANGUAGE.test(text)) return "visual_change";
  if (/\b(?:docs?|documentation|readme|runbook)\b/i.test(text)) return "documentation";
  if (/\b(?:governance|contract|policy|schema|workflow|gate|enforcement)\b/i.test(text)) return "governance";
  if (/\b(?:research|investigate|evaluate|compare)\b/i.test(text)) return "research";
  if (/\b(?:refactor|extract|restructure|cleanup)\b/i.test(text)) return "refactor";
  if (/\b(?:bug|fix|broken|fails?|error|incorrect|missing)\b/i.test(text)) return "bug";
  if (/\b(?:add|create|implement|feature|support)\b/i.test(text)) return "feature";
  return "other";
}

function queryTermsFrom(sourceText, title, configured = []) {
  const explicit = configured.map((item) => String(item).trim()).filter(Boolean);
  if (explicit.length > 0) return [...new Set(explicit)].slice(0, 8);
  const frequencies = new Map();
  for (const token of `${title} ${sourceText}`.toLowerCase().match(/[a-z][a-z0-9-]{3,}/g) ?? []) {
    if (STOP_WORDS.has(token) || token.startsWith("http")) continue;
    frequencies.set(token, (frequencies.get(token) ?? 0) + 1);
  }
  const ranked = [...frequencies.entries()]
    .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
    .map(([token]) => token);
  return ranked.slice(0, 8).length > 0 ? ranked.slice(0, 8) : [slug(title)];
}

function acceptanceCriteriaFrom(sourceText, title, configured = []) {
  const explicit = configured
    .map((item) => typeof item === "string" ? item : item?.text)
    .map((item) => String(item ?? "").trim())
    .filter(Boolean);
  if (explicit.length > 0) return [...new Set(explicit)];
  const lines = sourceText.split(/\r?\n/);
  const section = [];
  let active = false;
  for (const line of lines) {
    if (/^\s*#{1,6}\s+acceptance criteria\s*$/i.test(line)) {
      active = true;
      continue;
    }
    if (active && /^\s*#{1,6}\s+/.test(line)) break;
    if (active) {
      const match = line.match(/^\s*(?:[-*]|\d+[.)])\s+(.+?)\s*$/);
      if (match) section.push(match[1]);
    }
  }
  if (section.length > 0) return [...new Set(section)];
  return [`Implement the smallest coherent change for: ${title}.`, "Run the declared verification and retain exact evidence."];
}

function routeStatesFrom(sourceText, taskType) {
  const routes = [...new Set(sourceText.match(/\/(?:[a-z0-9._~-]+\/?)+/gi) ?? [])].slice(0, 6);
  const result = routes.map((route) => ({ route, state: "requested", surface: route }));
  if (taskType === "pwa_layout") {
    return [
      { route: routes[0] ?? "/", state: "browser", surface: "app-shell-bottom" },
      { route: routes[0] ?? "/", state: "standalone", surface: "app-shell-bottom" },
    ];
  }
  if (/\bmain menu\b/i.test(sourceText)) result.push({ route: "main-menu", state: "visible", surface: "main-menu" });
  if (/\bgameplay\b/i.test(sourceText)) result.push({ route: "gameplay", state: "active", surface: "gameplay" });
  return result.filter((item, index, values) => values.findIndex((other) => JSON.stringify(other) === JSON.stringify(item)) === index);
}

function visualContract(taskType, title, sourceText, routeStates) {
  const required = ["ui_parity", "visual_change", "pwa_layout"].includes(taskType);
  if (!required) {
    return { required: false, source_surface: null, target_surfaces: [], shared_properties: [], implementation_strategy: "not-applicable" };
  }
  if (taskType === "pwa_layout") {
    return {
      required: true,
      source_surface: "browser:app-shell-bottom",
      target_surfaces: ["standalone:app-shell-bottom"],
      shared_properties: ["bottom edge coverage", "safe-area ownership", "absence of phantom browser-toolbar spacing"],
      implementation_strategy: "shared-style-contract",
    };
  }
  if (taskType === "ui_parity" && /\bmain menu\b/i.test(sourceText) && /\bgameplay\b/i.test(sourceText)) {
    return {
      required: true,
      source_surface: "main-menu:semantic-control",
      target_surfaces: ["gameplay:semantic-control"],
      shared_properties: ["color", "shape", "animation", "container", "spacing", "behavior"],
      implementation_strategy: "shared-style-contract",
    };
  }
  const surfaces = routeStates.map((item) => `${item.route}:${item.state}:${item.surface}`);
  const fallback = slug(title);
  return {
    required: true,
    source_surface: surfaces[0] ?? `canonical-source:${fallback}`,
    target_surfaces: surfaces.slice(1).length > 0 ? surfaces.slice(1) : [`requested-target:${fallback}`],
    shared_properties: taskType === "ui_parity"
      ? ["color", "shape", "animation", "container", "spacing", "behavior"]
      : ["layout", "spacing", "responsive behavior"],
    implementation_strategy: taskType === "ui_parity" ? "shared-style-contract" : "documented-variant",
  };
}

function componentHints(job) {
  const hints = (job.scope?.allowed_paths ?? [])
    .map((item) => String(item).replaceAll("\\", "/"))
    .map((item) => item.split("/").filter(Boolean).find((part) => !/[?*]/.test(part)))
    .filter(Boolean);
  return [...new Set(hints)].slice(0, 8).length > 0 ? [...new Set(hints)].slice(0, 8) : [job.scope?.owner_repository ?? "governed-workspace"];
}

async function collectTextFiles(root, { maximumFiles = 4000 } = {}) {
  const files = [];
  const pending = [root];
  while (pending.length > 0 && files.length < maximumFiles) {
    const directory = pending.pop();
    let entries;
    try {
      entries = await fs.readdir(directory, { withFileTypes: true });
    } catch {
      continue;
    }
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const candidate = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (!IGNORED_DIRECTORIES.has(entry.name.toLowerCase())) pending.push(candidate);
      } else if (entry.isFile() && TEXT_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) {
        files.push(candidate);
        if (files.length >= maximumFiles) break;
      }
    }
  }
  return files.sort();
}

async function searchSurface(searchRoot, atlasRoot, queryTerms, excluded = new Set()) {
  const files = await collectTextFiles(searchRoot);
  const matches = [];
  for (const file of files) {
    const relative = path.relative(atlasRoot, file).replaceAll("\\", "/");
    if (excluded.has(relative)) continue;
    let stat;
    try { stat = await fs.stat(file); } catch { continue; }
    if (stat.size > 512 * 1024) continue;
    let content;
    try { content = (await fs.readFile(file, "utf8")).toLowerCase(); } catch { continue; }
    const present = queryTerms.filter((term) => content.includes(term.toLowerCase()));
    if (present.length === 0) continue;
    const score = present.length + (content.includes(queryTerms.join(" ").toLowerCase()) ? 3 : 0);
    matches.push({ ref: relative, score, terms: present });
  }
  return matches.sort((left, right) => right.score - left.score || left.ref.localeCompare(right.ref)).slice(0, 12);
}

async function validateAgainstKnownSchema(value, schemaId, label) {
  const loaded = await loadKnownSchema(schemaId);
  if (!loaded.ok) throw new EngineeringMemoryIntakeError(`${label} schema unavailable: ${loaded.error}`);
  const errors = validateJsonSchema(value, loaded.schema);
  if (errors.length > 0) throw new EngineeringMemoryIntakeError(`${label} invalid: ${errors.join("; ")}`);
}

async function writeJsonAtomic(target, value) {
  await fs.mkdir(path.dirname(target), { recursive: true });
  const temporary = `${target}.${process.pid}.tmp`;
  await fs.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await fs.rename(temporary, target);
}

export async function prepareEngineeringMemoryJob({
  job,
  sourceText,
  sourceRef,
  workspaceRoot,
  cardRecordRef,
  searchRecordRef,
  root = ROOT,
  checkedAt = new Date().toISOString(),
}) {
  const title = normalizeTitle(job, sourceText);
  const intake = job.extensions?.engineering_memory_intake ?? {};
  const queryTerms = queryTermsFrom(sourceText, title, intake.query_terms ?? []);
  const taskType = classifyTask(sourceText, title);
  const acceptanceCriteria = acceptanceCriteriaFrom(sourceText, title, intake.acceptance_criteria ?? []);
  const routeStates = routeStatesFrom(sourceText, taskType);
  const searchRef = path.relative(root, searchRecordRef).replaceAll("\\", "/");
  const sourceRefRelative = path.relative(root, sourceRef).replaceAll("\\", "/");
  const excluded = new Set([searchRef, sourceRefRelative]);
  const [repoMatches, atlasMatches] = await Promise.all([
    searchSurface(workspaceRoot, root, queryTerms, excluded),
    searchSurface(path.join(root, "docs"), root, queryTerms, excluded),
  ]);
  const usableMatches = [...repoMatches.map((item) => ({ ...item, kind: "current_repo" })), ...atlasMatches.map((item) => ({ ...item, kind: "atlas_docs" }))]
    .filter((item, index, values) => values.findIndex((other) => other.ref === item.ref) === index)
    .sort((left, right) => right.score - left.score || left.ref.localeCompare(right.ref))
    .slice(0, 8);
  const hasMatches = usableMatches.length > 0;
  const direct = usableMatches.find((item) => item.kind === "current_repo" && item.score >= Math.min(3, queryTerms.length));
  const decision = !hasMatches ? "first-durable-pattern" : direct ? "reuse" : "adapt";
  const rationale = !hasMatches
    ? "No matching precedent found. Creating first durable pattern."
    : direct
      ? "A strong current-repository precedent exists; inspect and reuse it before introducing a new implementation."
      : "Related repository or Atlas precedents exist; inspect and adapt them before introducing a new pattern.";
  const searchedSources = [
    {
      kind: "current_repo",
      ref: path.relative(root, workspaceRoot).replaceAll("\\", "/"),
      result: repoMatches.length > 0 ? "match" : "no_match",
      evidence_refs: repoMatches.length > 0 ? repoMatches.slice(0, 6).map((item) => item.ref) : [`${searchRef}#current_repo`],
    },
    {
      kind: "atlas_docs",
      ref: "docs",
      result: atlasMatches.length > 0 ? "match" : "no_match",
      evidence_refs: atlasMatches.length > 0 ? atlasMatches.slice(0, 6).map((item) => item.ref) : [`${searchRef}#atlas_docs`],
    },
  ];
  const verificationRequirements = [
    ...(job.verification?.commands ?? []).map((command) => `Run: ${command}`),
  ];
  if (["ui_parity", "visual_change", "pwa_layout"].includes(taskType)) {
    verificationRequirements.unshift("Capture route-aware visual evidence for the canonical and target surfaces.");
  }
  if (verificationRequirements.length === 0) verificationRequirements.push("Retain at least one passed technical verification reference.");
  const visual = visualContract(taskType, title, sourceText, routeStates);
  const cardId = job.correlations?.card_id
    || `aem-card-${digest(`${job.project_id}\0${job.scope?.owner_repository}\0${sourceText.trim()}`).slice(0, 24)}`;
  const profile = {
    contract_version: "atlas.engineering-memory-profile.v1",
    task_id: job.job_id,
    source_text: sourceText.trim() || title,
    normalized_title: title,
    task_type: taskType,
    phase: "planned",
    project: job.project_id,
    repo: job.scope.owner_repository,
    route_states: routeStates,
    components: componentHints(job),
    acceptance_criteria: acceptanceCriteria,
    precedent_check: {
      status: hasMatches ? "checked-matches" : "checked-none",
      query_terms: queryTerms,
      searched_sources: searchedSources,
      matches: usableMatches.map((item) => ({
        ref: item.ref,
        classification: item === direct ? "direct" : "adaptable",
        rationale: `Matched ${item.terms.join(", ")} in the ${item.kind} search.`,
      })),
      decision,
      rationale,
      checked_at: checkedAt,
    },
    verification: {
      requirements: verificationRequirements,
      evidence: [],
      unverified: [...verificationRequirements],
      visual,
    },
    scope_lock: {
      acceptance_frozen: true,
      discovery_policy: "linked-child-task",
      parent_task_id: job.correlations?.parent_job_id ?? null,
      child_task_ids: [],
    },
    fast_lane: {
      lane: "normal",
      eligible: false,
      verification_route_known: (job.verification?.commands?.length ?? 0) > 0 || visual.required,
      disqualifiers: ["Producer defaults to the normal lane; a worker may narrow only with evidence."],
      rationale: "The producer does not infer fast-lane authority from rough natural-language input.",
    },
    archive: { status: "pending", ref: null, final_status: null },
    blockers: [],
  };
  job.correlations.card_id = cardId;
  job.extensions = { ...job.extensions, engineering_memory: profile };
  const card = {
    contract_version: "atlas.card-record.v2",
    card_id: cardId,
    project_id: job.project_id,
    board_id: String(intake.board_id ?? job.project_id),
    title,
    description: sourceText.trim() || title,
    card_type: ({
      bug: "bug", documentation: "documentation", feature: "feature", governance: "governance",
      research: "research", refactor: "technical-debt", ui_parity: "bug", visual_change: "bug", pwa_layout: "bug",
    })[taskType] ?? "technical-debt",
    lifecycle: "ready",
    priority: intake.priority ?? "medium",
    owner: intake.owner ?? job.scope.owner_repository,
    dependencies: job.depends_on ?? [],
    board_version: Number.isInteger(intake.board_version) ? intake.board_version : 0,
    updated_at: checkedAt,
    source_ref: sourceRefRelative,
    extensions: {
      execution_job_id: job.job_id,
      producer: "_stack",
      projection: "run-bound-canonical-card",
    },
  };
  const searchRecord = {
    schema: "atlas.engineering-memory-precedent-search.v1",
    job_id: job.job_id,
    card_id: cardId,
    checked_at: checkedAt,
    query_terms: queryTerms,
    sources: searchedSources,
    matches: usableMatches,
    decision,
    rationale,
  };
  await Promise.all([
    validateAgainstKnownSchema(job, "atlas.job-envelope.v2", "JobEnvelope"),
    validateAgainstKnownSchema(card, "atlas.card-record.v2", "CardRecord"),
    validateAgainstKnownSchema(profile, "atlas.engineering-memory-profile.v1", "EngineeringMemoryProfile"),
  ]);
  return { job, card, searchRecord, profile };
}

export async function run(argv) {
  const options = parseArguments(argv);
  const jobPath = insideRoot(ROOT, options.jobEnvelope, "JobEnvelope");
  const sourcePath = insideRoot(ROOT, options.sourceTextFile, "Source text");
  const cardPath = insideRoot(ROOT, options.cardRecord, "CardRecord");
  const searchPath = insideRoot(ROOT, options.searchRecord, "Search record");
  const workspacePath = insideRoot(ROOT, options.workspaceRoot, "Workspace root");
  const [job, sourceText] = await Promise.all([loadJson(jobPath.resolved), fs.readFile(sourcePath.resolved, "utf8")]);
  const result = await prepareEngineeringMemoryJob({
    job,
    sourceText,
    sourceRef: sourcePath.resolved,
    workspaceRoot: workspacePath.resolved,
    cardRecordRef: cardPath.resolved,
    searchRecordRef: searchPath.resolved,
    root: ROOT,
  });
  await Promise.all([
    writeJsonAtomic(jobPath.resolved, result.job),
    writeJsonAtomic(cardPath.resolved, result.card),
    writeJsonAtomic(searchPath.resolved, result.searchRecord),
  ]);
  return {
    status: "prepared",
    job_id: result.job.job_id,
    card_id: result.card.card_id,
    task_type: result.profile.task_type,
    precedent_status: result.profile.precedent_check.status,
    precedent_decision: result.profile.precedent_check.decision,
    job_digest: `sha256:${digest(JSON.stringify(result.job))}`,
    card_digest: `sha256:${digest(JSON.stringify(result.card))}`,
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    console.log(JSON.stringify(await run(process.argv.slice(2)), null, 2));
  } catch (error) {
    console.error(JSON.stringify({ status: "blocked", error: error.message }, null, 2));
    process.exitCode = 1;
  }
}
