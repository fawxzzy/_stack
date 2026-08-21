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
const GATES = new Set(["plan", "mutation", "verify", "archive"]);
const VISUAL_TASK_TYPES = new Set(["ui_parity", "visual_change", "pwa_layout"]);
const PARITY_LANGUAGE = /\b(?:same as|match(?:es|ed|ing)?|carry over|duplicate this|make it like|reuse|already solved|same component|same style|same behavior)\b/i;
const FAST_LANE_RISK_LANGUAGE = /\b(?:schema|migration|auth|security|production|billing|secret|credential|destructive)\b/i;

const PHASE_TO_CARD_LIFECYCLE = Object.freeze({
  captured: new Set(["intake"]),
  normalized: new Set(["intake", "planning"]),
  precedent_checked: new Set(["planning", "ready"]),
  planned: new Set(["planning", "ready"]),
  in_progress: new Set(["in-progress"]),
  implemented: new Set(["in-progress", "review"]),
  verified: new Set(["review", "completed"]),
  archived: new Set(["completed", "archived"]),
  blocked: new Set(["blocked"]),
  reopened: new Set(["planning", "ready", "in-progress"]),
});

export class EngineeringMemoryGateError extends Error {}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function contentDigest(value) {
  return `sha256:${crypto.createHash("sha256").update(JSON.stringify(value)).digest("hex")}`;
}

function parseArguments(argv) {
  const options = { gate: "mutation", output: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) {
      throw new EngineeringMemoryGateError(`Unsupported argument: ${argument}`);
    }
    const key = argument.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new EngineeringMemoryGateError(`${argument} requires a value.`);
    }
    options[key] = value;
    index += 1;
  }
  for (const key of ["jobEnvelope", "cardRecord"]) {
    if (!options[key]) throw new EngineeringMemoryGateError(`Missing required argument: ${key}.`);
  }
  if (!GATES.has(options.gate)) {
    throw new EngineeringMemoryGateError(`Gate must be one of: ${[...GATES].join(", ")}.`);
  }
  return options;
}

function rootRelative(inputPath, { output = false } = {}) {
  const resolved = path.resolve(ROOT, inputPath);
  const relative = path.relative(ROOT, resolved).replaceAll("\\", "/");
  if (!relative || relative.startsWith("../") || path.isAbsolute(relative)) {
    throw new EngineeringMemoryGateError("Path must resolve inside the Atlas root.");
  }
  const segments = relative.toLowerCase().split("/");
  if (segments.includes("secrets") || segments.some((segment) => segment === ".env" || segment.startsWith(".env."))) {
    throw new EngineeringMemoryGateError(`Sensitive path is forbidden: ${relative}`);
  }
  if (output && !relative.startsWith("runtime/atlas/engineering-memory-gates/") && !relative.startsWith("tmp/")) {
    throw new EngineeringMemoryGateError("Output must be under runtime/atlas/engineering-memory-gates/ or tmp/.");
  }
  return { resolved, relative };
}

function workspaceRelative(workspaceRoot, inputPath) {
  if (path.isAbsolute(inputPath)) {
    throw new EngineeringMemoryGateError("Repository archive refs must be workspace-relative.");
  }
  const resolved = path.resolve(workspaceRoot, inputPath);
  const relative = path.relative(workspaceRoot, resolved).replaceAll("\\", "/");
  if (!relative || relative.startsWith("../") || path.isAbsolute(relative)) {
    throw new EngineeringMemoryGateError("Repository archive ref must resolve inside the bound workspace.");
  }
  const segments = relative.toLowerCase().split("/");
  if (segments.includes("secrets") || segments.some((segment) => segment === ".env" || segment.startsWith(".env."))) {
    throw new EngineeringMemoryGateError(`Sensitive archive path is forbidden: ${relative}`);
  }
  return { resolved, relative };
}

async function schemaErrors(value, schemaId, label) {
  const schema = await loadKnownSchema(schemaId);
  if (!schema.ok) return [`${label} schema unavailable: ${schema.error}`];
  return validateJsonSchema(value, schema.schema).map((error) => `${label}: ${error}`);
}

function checkedPrecedentErrors(profile) {
  const errors = [];
  const check = profile.precedent_check;
  if (!isPlainObject(check)) return errors;
  if (["pending", "blocked"].includes(check.status)) {
    errors.push("Precedent lookup must be checked before the gate can pass.");
    return errors;
  }
  if (!check.checked_at) errors.push("Precedent lookup requires checked_at evidence.");
  const searched = Array.isArray(check.searched_sources) ? check.searched_sources : [];
  for (const requiredKind of ["current_repo", "atlas_docs"]) {
    const usable = searched.find((source) => source?.kind === requiredKind && source.result !== "unavailable");
    if (!usable) errors.push(`Precedent lookup must include a usable ${requiredKind} search.`);
    else if (!Array.isArray(usable.evidence_refs) || usable.evidence_refs.length === 0) {
      errors.push(`Precedent ${requiredKind} search requires evidence_refs.`);
    }
  }
  const matches = Array.isArray(check.matches) ? check.matches : [];
  if (check.status === "checked-matches" && matches.length === 0) {
    errors.push("checked-matches requires at least one precedent match.");
  }
  if (check.status === "checked-none" && matches.some((match) => match?.classification !== "rejected")) {
    errors.push("checked-none cannot retain a direct or adaptable precedent match.");
  }
  if (check.status === "checked-none" && check.decision !== "first-durable-pattern") {
    errors.push("No-match precedent checks must declare first-durable-pattern.");
  }
  if (["reuse", "adapt"].includes(check.decision) && !matches.some((match) => ["direct", "adaptable"].includes(match?.classification))) {
    errors.push(`${check.decision} requires a direct or adaptable precedent match.`);
  }
  if (check.decision === "pending") errors.push("Precedent decision cannot remain pending after lookup.");
  return errors;
}

function parityErrors(profile) {
  const errors = [];
  if (PARITY_LANGUAGE.test(profile.source_text ?? "") && profile.task_type !== "ui_parity") {
    errors.push("Parity language in the source note must be classified as task_type ui_parity.");
  }
  if (profile.task_type !== "ui_parity") return errors;
  const visual = profile.verification?.visual;
  if (!visual?.required) errors.push("UI parity requires visual verification.");
  if (!visual?.source_surface) errors.push("UI parity requires the canonical source_surface.");
  if (!Array.isArray(visual?.target_surfaces) || visual.target_surfaces.length === 0) {
    errors.push("UI parity requires at least one target surface.");
  }
  if (!Array.isArray(visual?.shared_properties) || visual.shared_properties.length === 0) {
    errors.push("UI parity requires an explicit shared-property list.");
  }
  if (visual?.implementation_strategy === "not-applicable") {
    errors.push("UI parity requires a shared component, shared style contract, or documented variant strategy.");
  }
  if (
    visual?.implementation_strategy === "pending"
    && !["captured", "normalized", "blocked"].includes(profile.phase)
  ) {
    errors.push("Runnable UI parity work cannot retain a pending implementation strategy.");
  }
  return errors;
}

function fastLaneErrors(profile) {
  const errors = [];
  const lane = profile.fast_lane;
  if (!lane?.eligible) return errors;
  if (lane.lane !== "fast") errors.push("Fast-lane eligible work must use lane fast.");
  if (!lane.verification_route_known) errors.push("Fast-lane work requires a known verification route.");
  if ((profile.components?.length ?? 0) < 1 || profile.components.length > 2) {
    errors.push("Fast-lane work is limited to one or two affected components.");
  }
  if ((lane.disqualifiers?.length ?? 0) > 0) errors.push("Fast-lane work cannot retain disqualifiers.");
  if (FAST_LANE_RISK_LANGUAGE.test(`${profile.source_text ?? ""} ${profile.acceptance_criteria?.join(" ") ?? ""}`)) {
    errors.push("Fast-lane work cannot cross schema, auth, security, production, secret, billing, or destructive boundaries.");
  }
  return errors;
}

function verificationErrors(profile, { requireComplete = false } = {}) {
  const errors = [];
  const evidence = Array.isArray(profile.verification?.evidence) ? profile.verification.evidence : [];
  const passed = evidence.filter((item) => item?.result === "passed");
  if (passed.length === 0) errors.push("Verified work requires at least one passed evidence reference.");
  if ((profile.verification?.unverified?.length ?? 0) > 0) {
    errors.push("Verified work cannot retain unverified requirements; use implemented, partial, or blocked instead.");
  }
  if (VISUAL_TASK_TYPES.has(profile.task_type) || profile.verification?.visual?.required) {
    const visualEvidence = passed.filter((item) => ["screenshot", "dom", "visual_diff"].includes(item.kind));
    if (visualEvidence.length === 0) errors.push("Visual work requires passed screenshot, DOM, or visual-diff evidence.");
    const requiredSurfaces = [
      profile.verification?.visual?.source_surface,
      ...(profile.verification?.visual?.target_surfaces ?? []),
    ].filter(Boolean);
    const provenSurfaces = new Set(visualEvidence.flatMap((item) => item.surfaces ?? []));
    for (const surface of requiredSurfaces) {
      if (!provenSurfaces.has(surface)) errors.push(`Visual evidence is missing required surface: ${surface}.`);
    }
  }
  if (requireComplete && profile.archive?.final_status === "complete" && errors.length > 0) {
    errors.push("A complete archive requires the full verification gate to pass.");
  }
  return errors;
}

async function archiveErrors(profile, { root, workspaceRoot, allowRuntimeArchive = false }) {
  const errors = [];
  if (profile.archive?.status !== "created" || !profile.archive.ref || !profile.archive.final_status) {
    errors.push("Archive gate requires created status, a repository-visible ref, and final_status.");
    return errors;
  }
  let candidate;
  try {
    candidate = workspaceRelative(workspaceRoot, profile.archive.ref);
  } catch (error) {
    errors.push(error.message);
    return errors;
  }
  let archivePath = candidate.resolved;
  if (!candidate.relative.startsWith("docs/")) {
    if (!allowRuntimeArchive) {
      errors.push("Completion archives must be repository-visible under docs/.");
    } else {
      try {
        const runtimeCandidate = rootRelative(profile.archive.ref);
        const normalized = runtimeCandidate.relative.toLowerCase();
        const isRuntimeCloseout = normalized.includes("/.codex/logs/") || normalized.startsWith(".codex/logs/");
        if (!isRuntimeCloseout || !normalized.endsWith("/atlas.engineering-memory.closeout.v1.json")) {
          errors.push("No-change runtime archives must be the bound engineering-memory closeout record under .codex/logs/.");
        } else {
          archivePath = runtimeCandidate.resolved;
        }
      } catch (error) {
        errors.push(error.message);
      }
    }
  }
  try {
    const stat = await fs.stat(archivePath);
    if (!stat.isFile()) errors.push(`Archive ref is not a file: ${candidate.relative}.`);
  } catch {
    errors.push(`Archive ref does not exist: ${candidate.relative}.`);
  }
  if (profile.archive.final_status === "partial" && (profile.verification?.unverified?.length ?? 0) === 0) {
    errors.push("A partial archive must name at least one unverified item.");
  }
  if (profile.archive.final_status === "blocked" && (profile.blockers?.length ?? 0) === 0) {
    errors.push("A blocked archive must name at least one blocker.");
  }
  return errors;
}

export async function validateEngineeringMemoryGate({
  job,
  card,
  gate = "mutation",
  root = ROOT,
  workspaceRoot = root,
  allowRuntimeArchive = false,
}) {
  if (!GATES.has(gate)) throw new EngineeringMemoryGateError(`Unsupported gate: ${gate}.`);
  const errors = [
    ...(await schemaErrors(job, "atlas.job-envelope.v2", "JobEnvelope")),
    ...(await schemaErrors(card, "atlas.card-record.v2", "CardRecord")),
  ];
  const profile = job?.extensions?.engineering_memory;
  if (!isPlainObject(profile)) {
    errors.push("JobEnvelope extensions.engineering_memory is required.");
  } else {
    errors.push(...(await schemaErrors(profile, "atlas.engineering-memory-profile.v1", "EngineeringMemoryProfile")));
  }
  if (errors.length > 0 || !profile) return { ok: false, errors };

  if (!job.correlations?.card_id) errors.push("Engineering work requires a correlated canonical card_id.");
  if (job.correlations?.card_id !== card.card_id) errors.push("JobEnvelope card_id must match CardRecord card_id.");
  if (job.project_id !== card.project_id || profile.project !== job.project_id) {
    errors.push("Project identity must match across JobEnvelope, CardRecord, and EngineeringMemoryProfile.");
  }
  if (profile.task_id !== job.job_id) errors.push("EngineeringMemoryProfile task_id must equal JobEnvelope job_id.");
  if (profile.repo !== job.scope?.owner_repository) errors.push("Profile repo must equal JobEnvelope scope.owner_repository.");
  if (!PHASE_TO_CARD_LIFECYCLE[profile.phase]?.has(card.lifecycle)) {
    errors.push(`Profile phase ${profile.phase} is inconsistent with card lifecycle ${card.lifecycle}.`);
  }
  errors.push(...parityErrors(profile), ...fastLaneErrors(profile));

  if (["plan", "mutation", "verify", "archive"].includes(gate)) {
    errors.push(...checkedPrecedentErrors(profile));
  }
  if (gate === "mutation") {
    if (!["precedent_checked", "planned", "in_progress", "reopened"].includes(profile.phase)) {
      errors.push("Mutation gate requires precedent_checked, planned, in_progress, or reopened phase.");
    }
    if (!["ready", "in-progress"].includes(card.lifecycle)) {
      errors.push("Mutation gate requires the canonical card to be ready or in-progress.");
    }
    if (job.workspace?.mode === "read-only") errors.push("A read-only workspace cannot pass the mutation gate.");
    if (!profile.scope_lock?.acceptance_frozen) errors.push("Mutation gate requires frozen parent acceptance criteria.");
  }
  if (gate === "verify") {
    if (profile.phase !== "verified") errors.push("Verify gate requires profile phase verified.");
    errors.push(...verificationErrors(profile));
  }
  if (gate === "archive") {
    if (profile.phase !== "archived") errors.push("Archive gate requires profile phase archived.");
    errors.push(...(await archiveErrors(profile, { root, workspaceRoot, allowRuntimeArchive })));
    if (profile.archive?.final_status === "complete") {
      errors.push(...verificationErrors(profile, { requireComplete: true }));
    }
  }

  return { ok: errors.length === 0, errors };
}

export async function buildGateReceipt({
  job,
  card,
  gate,
  root = ROOT,
  workspaceRoot = root,
  allowRuntimeArchive = false,
}) {
  const result = await validateEngineeringMemoryGate({ job, card, gate, root, workspaceRoot, allowRuntimeArchive });
  const identity = {
    gate,
    job_id: job?.job_id ?? null,
    card_id: card?.card_id ?? null,
    job_digest: contentDigest(job),
    card_digest: contentDigest(card),
    phase: job?.extensions?.engineering_memory?.phase ?? null,
    precedent_checked_at: job?.extensions?.engineering_memory?.precedent_check?.checked_at ?? null,
    archive_mode: allowRuntimeArchive ? "no-change-runtime" : "repository-docs",
    errors: result.errors,
  };
  return {
    schema: "atlas.engineering-memory-gate-receipt.v1",
    receipt_id: `aemg_${crypto.createHash("sha256").update(JSON.stringify(identity)).digest("hex").slice(0, 24)}`,
    status: result.ok ? "passed" : "blocked",
    ...identity,
  };
}

export async function run(argv) {
  const options = parseArguments(argv);
  const jobPath = rootRelative(options.jobEnvelope);
  const cardPath = rootRelative(options.cardRecord);
  const workspaceRoot = options.workspaceRoot ? rootRelative(options.workspaceRoot).resolved : ROOT;
  const allowRuntimeArchive = options.archiveMode === "no-change-runtime";
  if (options.archiveMode && !["repository-docs", "no-change-runtime"].includes(options.archiveMode)) {
    throw new EngineeringMemoryGateError("archive-mode must be repository-docs or no-change-runtime.");
  }
  const [job, card] = await Promise.all([loadJson(jobPath.resolved), loadJson(cardPath.resolved)]);
  const receipt = await buildGateReceipt({
    job,
    card,
    gate: options.gate,
    root: ROOT,
    workspaceRoot,
    allowRuntimeArchive,
  });
  if (options.output) {
    const output = rootRelative(options.output, { output: true });
    await fs.mkdir(path.dirname(output.resolved), { recursive: true });
    await fs.writeFile(output.resolved, `${JSON.stringify(receipt, null, 2)}\n`, "utf8");
    receipt.output = output.relative;
  }
  return receipt;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const receipt = await run(process.argv.slice(2));
    console.log(JSON.stringify(receipt, null, 2));
    if (receipt.status !== "passed") process.exitCode = 1;
  } catch (error) {
    console.error(JSON.stringify({ status: "blocked", error: error.message }, null, 2));
    process.exitCode = 1;
  }
}
