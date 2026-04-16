#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const STACK_ROOT = path.resolve(SCRIPT_DIRECTORY, "..");

export const DEFAULT_ATLAS_TOPOLOGY_MANIFEST_PATH = path.resolve(
  STACK_ROOT,
  "..",
  "fawxzzy-atlas",
  "docs",
  "LIFELINE_TOPOLOGY_MANIFEST.json"
);

const ENVIRONMENT_ALIASES = new Map([
  ["production", "prod"]
]);

const DEFAULT_ENVIRONMENT_LABELS = new Map([
  ["dev", "Dev"],
  ["local", "Local"],
  ["operator", "Operator"],
  ["preview", "Preview"],
  ["prod", "Prod"]
]);

function ensureString(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${label} must be a non-empty string.`);
  }

  return value.trim();
}

function titleCase(value) {
  return value
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((segment) => segment.charAt(0).toUpperCase() + segment.slice(1))
    .join(" ");
}

function renderTemplate(template, values) {
  return template.replace(/\{([a-z_]+)\}/gi, (match, key) => {
    if (!(key in values)) {
      return match;
    }

    return String(values[key]);
  });
}

export function normalizeAtlasEnvironmentName(value) {
  const normalized = ensureString(value, "environment").toLowerCase();
  return ENVIRONMENT_ALIASES.get(normalized) ?? normalized;
}

function validateTopologyManifest(manifest, manifestPath) {
  if (typeof manifest !== "object" || manifest === null) {
    throw new Error(`Atlas topology manifest at ${manifestPath} must be a JSON object.`);
  }

  if (manifest.schema_version !== "atlas.topology.manifest.v1") {
    throw new Error(
      `Atlas topology manifest at ${manifestPath} must declare schema_version atlas.topology.manifest.v1.`
    );
  }

  if (!Array.isArray(manifest.apps) || manifest.apps.length === 0) {
    throw new Error(`Atlas topology manifest at ${manifestPath} must define apps[].`);
  }

  if (!manifest.environments || !Array.isArray(manifest.environments.named)) {
    throw new Error(`Atlas topology manifest at ${manifestPath} must define environments.named[].`);
  }

  if (!Array.isArray(manifest.hostname_rules) || manifest.hostname_rules.length === 0) {
    throw new Error(`Atlas topology manifest at ${manifestPath} must define hostname_rules[].`);
  }
}

export async function loadAtlasTopologyManifest(manifestPath = DEFAULT_ATLAS_TOPOLOGY_MANIFEST_PATH) {
  const resolvedPath = path.resolve(manifestPath);
  const manifest = JSON.parse(await readFile(resolvedPath, "utf8"));
  validateTopologyManifest(manifest, resolvedPath);

  const appMap = new Map();
  for (const app of manifest.apps) {
    const appId = ensureString(app.app_id, "apps[].app_id");
    if (appMap.has(appId)) {
      throw new Error(`Atlas topology manifest at ${resolvedPath} duplicates app_id ${appId}.`);
    }

    appMap.set(appId, app);
  }

  const namedEnvironmentMap = new Map();
  for (const environment of manifest.environments.named) {
    const name = normalizeAtlasEnvironmentName(environment.name);
    if (namedEnvironmentMap.has(name)) {
      throw new Error(`Atlas topology manifest at ${resolvedPath} duplicates named environment ${name}.`);
    }

    namedEnvironmentMap.set(name, environment);
  }

  const primaryZone =
    manifest.zones?.find((zone) => zone.kind === "primary-public" && zone.status === "active")?.zone ??
    manifest.apps.find((app) => typeof app.default_zone === "string" && app.default_zone.length > 0)?.default_zone ??
    null;

  return {
    manifest,
    manifestPath: resolvedPath,
    appMap,
    namedEnvironmentMap,
    hostnameRules: Array.isArray(manifest.hostname_rules) ? manifest.hostname_rules : [],
    primaryZone
  };
}

function getEnvironmentLabel(topology, canonicalEnvironment) {
  const namedEnvironment = topology.namedEnvironmentMap.get(canonicalEnvironment);
  if (namedEnvironment && typeof namedEnvironment.name === "string") {
    return DEFAULT_ENVIRONMENT_LABELS.get(canonicalEnvironment) ?? titleCase(namedEnvironment.name);
  }

  return DEFAULT_ENVIRONMENT_LABELS.get(canonicalEnvironment) ?? titleCase(canonicalEnvironment);
}

function getNamedRule(topology, appId, canonicalEnvironment) {
  const exactRule = topology.hostnameRules.find(
    (rule) => rule.kind === "named" && rule.environment === canonicalEnvironment && rule.app_id === appId
  );
  if (exactRule) {
    return exactRule;
  }

  return topology.hostnameRules.find(
    (rule) => rule.kind === "named" && rule.environment === canonicalEnvironment && !rule.app_id
  ) ?? null;
}

function getPrPreviewRule(topology, appId) {
  const exactRule = topology.hostnameRules.find(
    (rule) => rule.kind === "ephemeral" && rule.environment_template === "pr-{number}" && rule.app_id === appId
  );
  if (exactRule) {
    return exactRule;
  }

  return topology.hostnameRules.find(
    (rule) => rule.kind === "ephemeral" && rule.environment_template === "pr-{number}" && !rule.app_id
  ) ?? null;
}

function resolveHostnameFromRule(rule, app, topology, values = {}) {
  if (!rule || typeof rule.hostname_template !== "string") {
    return null;
  }

  const zone = typeof app.default_zone === "string" && app.default_zone.length > 0 ? app.default_zone : topology.primaryZone;
  if (!zone) {
    return null;
  }

  return renderTemplate(rule.hostname_template, {
    app: app.app_id,
    zone,
    number: "{number}",
    ...values
  });
}

function resolveServiceKey(rule, appId, canonicalEnvironment) {
  if (rule && typeof rule.service_key_template === "string" && rule.service_key_template.length > 0) {
    return renderTemplate(rule.service_key_template, {
      app: appId,
      environment: canonicalEnvironment,
      number: "{number}"
    });
  }

  return `${appId}/${canonicalEnvironment}`;
}

export function getTargetTopologyMetadata(topology, target) {
  const canonicalEnvironment = normalizeAtlasEnvironmentName(target.environment);
  const app = topology.appMap.get(target.app) ?? null;
  const actionId = target.action?.id ?? null;

  if (!app) {
    return {
      topologyManaged: false,
      canonicalEnvironment,
      displayEnvironment: getEnvironmentLabel(topology, canonicalEnvironment),
      serviceKey: null,
      hostnameHint: null,
      prPreviewHint: null
    };
  }

  const isNamedReleaseEnvironment = canonicalEnvironment === "preview" || canonicalEnvironment === "prod";
  if (actionId === "preview" && canonicalEnvironment !== "preview") {
    throw new Error(
      `Target ${target.id} contradicts Atlas topology: action preview must map ${target.app} to environment preview, not ${target.environment}.`
    );
  }

  if (actionId === "deploy-prod" && canonicalEnvironment !== "prod") {
    throw new Error(
      `Target ${target.id} contradicts Atlas topology: action deploy-prod must map ${target.app} to environment prod, not ${target.environment}.`
    );
  }

  if (canonicalEnvironment === "preview" && app.preview_hostname_mode === "none") {
    throw new Error(
      `Target ${target.id} contradicts Atlas topology: ${target.app} does not expose a preview environment.`
    );
  }

  if (canonicalEnvironment === "prod" && app.prod_hostname_mode === "none") {
    throw new Error(
      `Target ${target.id} contradicts Atlas topology: ${target.app} does not expose a prod environment.`
    );
  }

  const namedRule = isNamedReleaseEnvironment ? getNamedRule(topology, app.app_id, canonicalEnvironment) : null;
  if (isNamedReleaseEnvironment && !namedRule) {
    throw new Error(
      `Target ${target.id} contradicts Atlas topology: no hostname rule exists for ${target.app}/${canonicalEnvironment}.`
    );
  }

  const hostnameHint = resolveHostnameFromRule(namedRule, app, topology);
  const prPreviewRule =
    canonicalEnvironment === "preview" && app.pr_preview_hostname_mode !== "none"
      ? getPrPreviewRule(topology, app.app_id)
      : null;

  return {
    topologyManaged: true,
    canonicalEnvironment,
    displayEnvironment: getEnvironmentLabel(topology, canonicalEnvironment),
    serviceKey: isNamedReleaseEnvironment ? resolveServiceKey(namedRule, app.app_id, canonicalEnvironment) : null,
    hostnameHint,
    prPreviewHint: resolveHostnameFromRule(prPreviewRule, app, topology)
  };
}
