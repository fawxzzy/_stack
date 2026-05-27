import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { loadPacketFromFile, validateGatewayPacket } from "./data-gateway-packet-validator.mjs";

const DEFAULT_ARTIFACT_ROOT = path.resolve(fileURLToPath(new URL("../../../runtime/gateway-packets/", import.meta.url)));

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function sanitizeSegment(value) {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

function buildDateSegment(emittedAt) {
  return emittedAt.toISOString().slice(0, 10);
}

function buildTimestampSegment(emittedAt) {
  return emittedAt
    .toISOString()
    .replace(/[:]/g, "")
    .replace(/\.\d{3}Z$/, "z")
    .replace("T", "t")
    .toLowerCase();
}

function buildPacketId(packet, lane, emittedAt) {
  if (isNonEmptyString(packet.packet_id)) {
    return sanitizeSegment(packet.packet_id);
  }

  return [
    sanitizeSegment(lane),
    buildTimestampSegment(emittedAt),
    randomUUID().slice(0, 8)
  ].join("-");
}

function formatSummary(packet, metadata) {
  return [
    `# Local Data Gateway Dry-Run Packet Summary`,
    ``,
    `- packet id: \`${metadata.packet_id}\``,
    `- lane: \`${metadata.lane}\``,
    `- emitted at: \`${metadata.emitted_at}\``,
    `- mode: \`${metadata.emit_mode}\``,
    `- downstream send performed: \`${String(metadata.downstream_send_performed)}\``,
    `- packet purpose: \`${packet.packet_purpose}\``,
    `- schema version: \`${packet.packet_schema_version}\``,
    `- sensitivity label: \`${packet.sensitivity_label}\``,
    `- downstream target class: \`${packet.downstream_target_class}\``,
    `- validation result: \`${packet.validation_result}\``,
    `- redaction status: \`${packet.redaction_status}\``,
    `- dedupe status: \`${packet.dedupe_status}\``,
    `- input path: \`${metadata.input_path}\``,
    `- artifact root: \`${metadata.artifact_root}\``,
    `- artifact directory: \`${metadata.artifact_dir}\``,
    ``,
    `## No-Send Guarantees`,
    ``,
    `No downstream send performed.`,
    ``,
    `- no remote send`,
    `- no model/API/SaaS emission`,
    `- no secret expansion`,
    `- no hidden filesystem discovery beyond the explicit input path`,
    ``,
    `## Artifact Set`,
    ``,
    `- \`packet.json\``,
    `- \`packet-summary.md\``,
    `- \`packet-metadata.json\``
  ].join("\n");
}

export function buildArtifactDirectory({ lane, artifactRoot = DEFAULT_ARTIFACT_ROOT, emittedAt, packetId }) {
  const safeLane = sanitizeSegment(lane);

  if (!safeLane) {
    throw new Error("lane must resolve to a non-empty artifact path segment.");
  }

  return path.join(
    artifactRoot,
    safeLane,
    buildDateSegment(emittedAt),
    packetId
  );
}

export async function emitDryRunPacket({ inputPath, lane, artifactRoot = DEFAULT_ARTIFACT_ROOT, emittedAt = new Date() }) {
  if (!isNonEmptyString(inputPath)) {
    throw new Error("inputPath is required.");
  }

  if (!isNonEmptyString(lane)) {
    throw new Error("lane is required.");
  }

  const resolvedInputPath = path.resolve(inputPath);
  const resolvedArtifactRoot = path.resolve(artifactRoot);
  const packet = await loadPacketFromFile(resolvedInputPath);
  const validation = validateGatewayPacket(packet);

  if (!validation.ok) {
    return {
      ok: false,
      errors: validation.errors,
      inputPath: resolvedInputPath,
      artifactRoot: resolvedArtifactRoot,
      wroteArtifacts: false
    };
  }

  const packetId = buildPacketId(packet, lane, emittedAt);
  const artifactDir = buildArtifactDirectory({
    lane,
    artifactRoot: resolvedArtifactRoot,
    emittedAt,
    packetId
  });

  const emittedPacket = {
    packet_id: packetId,
    ...packet
  };

  const artifacts = {
    packet: path.join(artifactDir, "packet.json"),
    summary: path.join(artifactDir, "packet-summary.md"),
    metadata: path.join(artifactDir, "packet-metadata.json")
  };

  const metadata = {
    packet_id: packetId,
    lane,
    emit_mode: "dry-run",
    downstream_send_performed: false,
    input_path: resolvedInputPath,
    artifact_root: resolvedArtifactRoot,
    artifact_dir: artifactDir,
    emitted_at: emittedAt.toISOString(),
    artifacts,
    no_send_guarantees: [
      "no remote send",
      "no model/API/SaaS emission",
      "no secret expansion",
      "no hidden filesystem discovery beyond explicit input"
    ]
  };

  await fs.mkdir(artifactDir, { recursive: true });
  await fs.writeFile(artifacts.packet, `${JSON.stringify(emittedPacket, null, 2)}\n`, "utf8");
  await fs.writeFile(artifacts.summary, `${formatSummary(emittedPacket, metadata)}\n`, "utf8");
  await fs.writeFile(artifacts.metadata, `${JSON.stringify(metadata, null, 2)}\n`, "utf8");

  return {
    ok: true,
    errors: [],
    inputPath: resolvedInputPath,
    artifactRoot: resolvedArtifactRoot,
    artifactDir,
    packetId,
    artifacts,
    metadata
  };
}

function formatUsage(scriptName) {
  return [
    "Usage:",
    `  node ${scriptName} --input <packet.json> --lane <lane> [--artifact-root <path>]`,
    "",
    "Emits Local Data Gateway dry-run packet artifacts locally only.",
    "No send, transport, model, API, or SaaS behavior is performed."
  ].join("\n");
}

async function main(argv) {
  const args = [...argv];

  if (args.includes("--help") || args.includes("-h")) {
    console.log(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 0;
  }

  const inputIndex = args.indexOf("--input");
  const laneIndex = args.indexOf("--lane");
  const artifactRootIndex = args.indexOf("--artifact-root");

  if (inputIndex === -1 || !args[inputIndex + 1]) {
    console.error("Missing required --input <packet.json> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  if (laneIndex === -1 || !args[laneIndex + 1]) {
    console.error("Missing required --lane <lane> argument.");
    console.error(formatUsage(path.basename(fileURLToPath(import.meta.url))));
    return 1;
  }

  const inputPath = args[inputIndex + 1];
  const lane = args[laneIndex + 1];
  const artifactRoot = artifactRootIndex !== -1 && args[artifactRootIndex + 1]
    ? args[artifactRootIndex + 1]
    : DEFAULT_ARTIFACT_ROOT;

  try {
    const result = await emitDryRunPacket({
      inputPath,
      lane,
      artifactRoot
    });

    if (!result.ok) {
      console.error(JSON.stringify({
        ok: false,
        input: result.inputPath,
        artifactRoot: result.artifactRoot,
        errors: result.errors
      }, null, 2));
      return 1;
    }

    console.log(JSON.stringify({
      ok: true,
      input: result.inputPath,
      artifactDir: result.artifactDir,
      packetId: result.packetId,
      artifacts: result.artifacts,
      downstreamSendPerformed: false,
      errors: []
    }, null, 2));
    return 0;
  } catch (error) {
    console.error(JSON.stringify({
      ok: false,
      errors: [error instanceof Error ? error.message : String(error)]
    }, null, 2));
    return 1;
  }
}

const isDirectExecution = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectExecution) {
  const exitCode = await main(process.argv.slice(2));
  process.exit(exitCode);
}
