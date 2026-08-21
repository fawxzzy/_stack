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
import { buildGateReceipt } from "./engineering_memory_gate.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

export class EngineeringMemoryCloseoutError extends Error {}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) throw new EngineeringMemoryCloseoutError(`Unsupported argument: ${argument}`);
    const key = argument.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new EngineeringMemoryCloseoutError(`${argument} requires a value.`);
    options[key] = value;
    index += 1;
  }
  for (const key of [
    "jobEnvelope",
    "cardRecord",
    "closeoutRecord",
    "runnerVerification",
    "workspaceRoot",
    "verifyReceipt",
    "archiveReceipt",
  ]) {
    if (!options[key]) throw new EngineeringMemoryCloseoutError(`Missing required argument: ${key}.`);
  }
  return options;
}

function insideRoot(inputPath, label) {
  const resolved = path.resolve(ROOT, inputPath);
  const relative = path.relative(ROOT, resolved).replaceAll("\\", "/");
  if (!relative || relative.startsWith("../") || path.isAbsolute(relative)) {
    throw new EngineeringMemoryCloseoutError(`${label} must resolve inside the Atlas root.`);
  }
  const segments = relative.toLowerCase().split("/");
  if (segments.includes("secrets") || segments.some((segment) => segment === ".env" || segment.startsWith(".env."))) {
    throw new EngineeringMemoryCloseoutError(`${label} cannot resolve through a sensitive path.`);
  }
  return { resolved, relative };
}

async function schemaErrors(value, schemaId, label) {
  const schema = await loadKnownSchema(schemaId);
  if (!schema.ok) return [`${label} schema unavailable: ${schema.error}`];
  return validateJsonSchema(value, schema.schema).map((error) => `${label}: ${error}`);
}

function stableEvidence(evidence) {
  const seen = new Set();
  return evidence.filter((item) => {
    const key = JSON.stringify([item.kind, item.ref, item.result, [...(item.surfaces ?? [])].sort()]);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

async function writeJsonAtomic(targetPath, value) {
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  const temporary = `${targetPath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await fs.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await fs.rename(temporary, targetPath);
}

function nextCard(card, { lifecycle, updatedAt, sourceRef = card.source_ref ?? null }) {
  const updated = structuredClone(card);
  updated.lifecycle = lifecycle;
  updated.board_version = Number.isInteger(updated.board_version) ? updated.board_version + 1 : 1;
  updated.updated_at = updatedAt;
  updated.source_ref = sourceRef;
  return updated;
}

export async function completeEngineeringMemoryJob({
  job,
  card,
  closeout,
  runnerVerification,
  workspaceRoot,
  root = ROOT,
}) {
  const inputErrors = [
    ...(await schemaErrors(job, "atlas.job-envelope.v2", "JobEnvelope")),
    ...(await schemaErrors(card, "atlas.card-record.v2", "CardRecord")),
    ...(await schemaErrors(closeout, "atlas.engineering-memory-closeout.v1", "EngineeringMemoryCloseout")),
    ...(await schemaErrors(runnerVerification, "atlas.engineering-memory-runner-verification.v1", "RunnerVerification")),
  ];
  if (inputErrors.length > 0) throw new EngineeringMemoryCloseoutError(inputErrors.join("\n"));

  const profile = job.extensions?.engineering_memory;
  if (!profile) throw new EngineeringMemoryCloseoutError("JobEnvelope engineering-memory profile is missing.");
  if (closeout.job_id !== job.job_id || runnerVerification.job_id !== job.job_id) {
    throw new EngineeringMemoryCloseoutError("Closeout and runner verification must match the JobEnvelope identity.");
  }
  if (closeout.card_id !== card.card_id || job.correlations?.card_id !== card.card_id) {
    throw new EngineeringMemoryCloseoutError("Closeout, JobEnvelope, and CardRecord must share one card identity.");
  }
  if (closeout.final_status !== "complete" || closeout.blockers.length > 0 || closeout.verification.unverified.length > 0) {
    throw new EngineeringMemoryCloseoutError("Terminal runner success requires complete status with zero blockers and zero unverified requirements.");
  }
  if (runnerVerification.records.some((record) => record.exit_code !== 0)) {
    throw new EngineeringMemoryCloseoutError("Runner verification contains a failed command.");
  }

  const runnerEvidence = runnerVerification.records.map((record) => ({
    kind: "test",
    ref: record.stdout_ref || record.command,
    result: "passed",
    surfaces: [],
  }));
  if (runnerVerification.no_change_proof_ref) {
    runnerEvidence.push({
      kind: "document",
      ref: runnerVerification.no_change_proof_ref,
      result: "passed",
      surfaces: [],
    });
  }
  if (runnerEvidence.length === 0) {
    throw new EngineeringMemoryCloseoutError("Terminal runner success requires runner-owned verification or a validated no-change proof.");
  }

  const verifiedJob = structuredClone(job);
  const verifiedProfile = verifiedJob.extensions.engineering_memory;
  verifiedProfile.phase = "verified";
  verifiedProfile.verification.evidence = stableEvidence([
    ...closeout.verification.evidence,
    ...runnerEvidence,
  ]);
  verifiedProfile.verification.unverified = [];
  verifiedProfile.blockers = [];
  if (Array.isArray(closeout.child_task_ids)) {
    verifiedProfile.scope_lock.child_task_ids = [...new Set([
      ...(verifiedProfile.scope_lock.child_task_ids ?? []),
      ...closeout.child_task_ids,
    ])];
  }
  verifiedProfile.archive = { status: "pending", ref: null, final_status: null };
  const verifiedCard = nextCard(card, { lifecycle: "completed", updatedAt: closeout.completed_at });

  const verifiedErrors = [
    ...(await schemaErrors(verifiedJob, "atlas.job-envelope.v2", "Verified JobEnvelope")),
    ...(await schemaErrors(verifiedCard, "atlas.card-record.v2", "Verified CardRecord")),
  ];
  if (verifiedErrors.length > 0) throw new EngineeringMemoryCloseoutError(verifiedErrors.join("\n"));
  const verifyReceipt = await buildGateReceipt({
    job: verifiedJob,
    card: verifiedCard,
    gate: "verify",
    root,
    workspaceRoot,
  });

  const archivedJob = structuredClone(verifiedJob);
  archivedJob.extensions.engineering_memory.phase = "archived";
  archivedJob.extensions.engineering_memory.archive = {
    status: "created",
    ref: closeout.archive_ref,
    final_status: closeout.final_status,
  };
  const archivedCard = nextCard(verifiedCard, {
    lifecycle: "archived",
    updatedAt: closeout.completed_at,
    sourceRef: closeout.archive_ref,
  });
  const archivedErrors = [
    ...(await schemaErrors(archivedJob, "atlas.job-envelope.v2", "Archived JobEnvelope")),
    ...(await schemaErrors(archivedCard, "atlas.card-record.v2", "Archived CardRecord")),
  ];
  if (archivedErrors.length > 0) throw new EngineeringMemoryCloseoutError(archivedErrors.join("\n"));
  const archiveReceipt = await buildGateReceipt({
    job: archivedJob,
    card: archivedCard,
    gate: "archive",
    root,
    workspaceRoot,
    allowRuntimeArchive: closeout.archive_kind === "no-change-runtime",
  });

  return {
    ok: verifyReceipt.status === "passed" && archiveReceipt.status === "passed",
    verifyReceipt,
    archiveReceipt,
    archivedJob,
    archivedCard,
    archiveKind: closeout.archive_kind,
  };
}

export async function run(argv) {
  const options = parseArguments(argv);
  const jobPath = insideRoot(options.jobEnvelope, "JobEnvelope");
  const cardPath = insideRoot(options.cardRecord, "CardRecord");
  const closeoutPath = insideRoot(options.closeoutRecord, "EngineeringMemoryCloseout");
  const runnerVerificationPath = insideRoot(options.runnerVerification, "RunnerVerification");
  const workspaceRoot = insideRoot(options.workspaceRoot, "Workspace root");
  const verifyReceiptPath = insideRoot(options.verifyReceipt, "Verify receipt");
  const archiveReceiptPath = insideRoot(options.archiveReceipt, "Archive receipt");
  const [job, card, closeout, runnerVerification] = await Promise.all([
    loadJson(jobPath.resolved),
    loadJson(cardPath.resolved),
    loadJson(closeoutPath.resolved),
    loadJson(runnerVerificationPath.resolved),
  ]);
  const result = await completeEngineeringMemoryJob({
    job,
    card,
    closeout,
    runnerVerification,
    workspaceRoot: workspaceRoot.resolved,
    root: ROOT,
  });
  await Promise.all([
    writeJsonAtomic(verifyReceiptPath.resolved, result.verifyReceipt),
    writeJsonAtomic(archiveReceiptPath.resolved, result.archiveReceipt),
  ]);
  if (!result.ok) {
    throw new EngineeringMemoryCloseoutError([
      ...result.verifyReceipt.errors,
      ...result.archiveReceipt.errors,
    ].join("\n"));
  }
  await Promise.all([
    writeJsonAtomic(jobPath.resolved, result.archivedJob),
    writeJsonAtomic(cardPath.resolved, result.archivedCard),
  ]);
  const identity = JSON.stringify({
    job_id: result.archivedJob.job_id,
    card_id: result.archivedCard.card_id,
    verify_receipt_id: result.verifyReceipt.receipt_id,
    archive_receipt_id: result.archiveReceipt.receipt_id,
  });
  return {
    status: "completed",
    result_id: `aemc_${crypto.createHash("sha256").update(identity).digest("hex").slice(0, 24)}`,
    job_id: result.archivedJob.job_id,
    card_id: result.archivedCard.card_id,
    final_phase: result.archivedJob.extensions.engineering_memory.phase,
    final_lifecycle: result.archivedCard.lifecycle,
    archive_kind: result.archiveKind,
    archive_ref: result.archivedJob.extensions.engineering_memory.archive.ref,
    verify_receipt: verifyReceiptPath.relative,
    archive_receipt: archiveReceiptPath.relative,
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
