#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { getTargetTopologyMetadata, loadAtlasTopologyManifest } from "./atlas-topology.mjs";
import { buildPnpmScriptExecution, formatExecutionSpec, spawnWithSpec } from "./command-runner.mjs";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const STACK_ROOT = path.resolve(SCRIPT_DIRECTORY, "..");
const DEFAULT_CONFIG_PATH = path.join(STACK_ROOT, "config", "release-targets.json");
const DEFAULT_PACKAGE_PATH = path.join(STACK_ROOT, "package.json");

const ANSI = {
  reset: "\u001b[0m",
  cyan: "\u001b[36m",
  green: "\u001b[32m",
  yellow: "\u001b[33m",
  red: "\u001b[31m",
  dim: "\u001b[2m"
};

function colorize(text, color) {
  return `${color}${text}${ANSI.reset}`;
}

function usage() {
  console.log(`Usage:
  node scripts/release-launcher.mjs
  node scripts/release-launcher.mjs --list
  node scripts/release-launcher.mjs --target <target-id> [--dry-run]
  node scripts/release-launcher.mjs --config <path> [--target <target-id>] [--dry-run]`);
}

function parseArguments(argv) {
  const options = {
    configPath: DEFAULT_CONFIG_PATH,
    dryRun: false,
    list: false,
    targetId: null
  };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];

    if (argument === "--config") {
      index += 1;
      const value = argv[index];
      if (!value) {
        throw new Error("Missing value for --config.");
      }
      options.configPath = path.resolve(process.cwd(), value);
      continue;
    }

    if (argument === "--target") {
      index += 1;
      const value = argv[index];
      if (!value) {
        throw new Error("Missing value for --target.");
      }
      options.targetId = value;
      continue;
    }

    if (argument === "--dry-run") {
      options.dryRun = true;
      continue;
    }

    if (argument === "--list") {
      options.list = true;
      continue;
    }

    if (argument === "--help" || argument === "-h") {
      options.help = true;
      continue;
    }

    throw new Error(`Unknown argument: ${argument}`);
  }

  return options;
}

async function readJson(filePath) {
  const raw = await readFile(filePath, "utf8");
  return JSON.parse(raw);
}

function ensureString(value, label) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${label} must be a non-empty string.`);
  }
  return value.trim();
}

function normalizeArray(value, label) {
  if (value === undefined) {
    return [];
  }
  if (!Array.isArray(value)) {
    throw new Error(`${label} must be an array when provided.`);
  }
  return value.map((entry, index) => ensureString(entry, `${label}[${index}]`));
}

function ensureBoolean(value, label) {
  if (typeof value === "boolean") {
    return value;
  }
  if (value === undefined) {
    return false;
  }
  throw new Error(`${label} must be a boolean when provided.`);
}

function validateConfiguration(config, packageScripts, topology) {
  if (typeof config !== "object" || config === null) {
    throw new Error("Launcher config must be a JSON object.");
  }

  const actions = Array.isArray(config.actions) ? config.actions : [];
  const groups = Array.isArray(config.groups) ? config.groups : [];
  const targets = Array.isArray(config.targets) ? config.targets : [];

  if (actions.length === 0) {
    throw new Error("Launcher config must define at least one action.");
  }
  if (groups.length === 0) {
    throw new Error("Launcher config must define at least one group.");
  }
  if (targets.length === 0) {
    throw new Error("Launcher config must define at least one target.");
  }

  const actionMap = new Map();
  for (const action of actions) {
    const id = ensureString(action.id, "action.id");
    if (actionMap.has(id)) {
      throw new Error(`Duplicate action id: ${id}`);
    }

    actionMap.set(id, {
      id,
      label: ensureString(action.label, `action(${id}).label`),
      description: typeof action.description === "string" ? action.description.trim() : ""
    });
  }

  const groupMap = new Map();
  for (const group of groups) {
    const id = ensureString(group.id, "group.id");
    if (groupMap.has(id)) {
      throw new Error(`Duplicate group id: ${id}`);
    }

    groupMap.set(id, {
      id,
      label: ensureString(group.label, `group(${id}).label`),
      description: typeof group.description === "string" ? group.description.trim() : ""
    });
  }

  const targetMap = new Map();
  const normalizedTargets = targets.map((target) => {
    const id = ensureString(target.id, "target.id");
    if (targetMap.has(id)) {
      throw new Error(`Duplicate target id: ${id}`);
    }

    const actionId = ensureString(target.action, `target(${id}).action`);
    if (!actionMap.has(actionId)) {
      throw new Error(`Target ${id} references unknown action ${actionId}.`);
    }

    const groupId = ensureString(target.group, `target(${id}).group`);
    if (!groupMap.has(groupId)) {
      throw new Error(`Target ${id} references unknown group ${groupId}.`);
    }

    const script = ensureString(target.script, `target(${id}).script`);
    if (!(script in packageScripts)) {
      throw new Error(`Target ${id} references missing package script ${script}.`);
    }

    const preflightScripts = normalizeArray(target.preflightScripts, `target(${id}).preflightScripts`);
    for (const preflightScript of preflightScripts) {
      if (!(preflightScript in packageScripts)) {
        throw new Error(`Target ${id} references missing preflight package script ${preflightScript}.`);
      }
    }

    const normalizedTarget = {
      id,
      action: actionMap.get(actionId),
      advanced: ensureBoolean(target.advanced, `target(${id}).advanced`),
      group: groupMap.get(groupId),
      app: ensureString(target.app, `target(${id}).app`),
      environment: ensureString(target.environment, `target(${id}).environment`),
      label: ensureString(target.label, `target(${id}).label`),
      description: typeof target.description === "string" ? target.description.trim() : "",
      script,
      preflightScripts,
      notes: normalizeArray(target.notes, `target(${id}).notes`),
      tags: normalizeArray(target.tags, `target(${id}).tags`),
      requiresTypedConfirmation: Boolean(target.requiresTypedConfirmation),
      confirmText: typeof target.confirmText === "string" ? target.confirmText.trim() : ""
    };

    const topologyMetadata = getTargetTopologyMetadata(topology, normalizedTarget);
    normalizedTarget.canonicalEnvironment = topologyMetadata.canonicalEnvironment;
    normalizedTarget.displayEnvironment = topologyMetadata.displayEnvironment;
    normalizedTarget.serviceKey = topologyMetadata.serviceKey;
    normalizedTarget.hostnameHint = topologyMetadata.hostnameHint;
    normalizedTarget.prPreviewHint = topologyMetadata.prPreviewHint;
    normalizedTarget.topologyManaged = topologyMetadata.topologyManaged;

    if (normalizedTarget.requiresTypedConfirmation && normalizedTarget.confirmText.length === 0) {
      throw new Error(`Target ${id} requires typed confirmation but confirmText is empty.`);
    }

    targetMap.set(id, normalizedTarget);
    return normalizedTarget;
  });

  return {
    actions: [...actionMap.values()],
    actionMap,
    groups: [...groupMap.values()],
    groupMap,
    targets: normalizedTargets,
    targetMap
  };
}

function sortTargets(targets) {
  return [...targets].sort((left, right) => left.label.localeCompare(right.label));
}

function getTargetsForAction(configuration, actionId) {
  if (actionId === "maintenance") {
    return sortTargets(configuration.targets.filter((target) => target.advanced));
  }

  return sortTargets(
    configuration.targets.filter((target) => target.action.id === actionId && !target.advanced)
  );
}

function listTargets(configuration) {
  for (const action of configuration.actions) {
    const targets = getTargetsForAction(configuration, action.id);
    if (targets.length === 0) {
      continue;
    }

    console.log(`${action.label}:`);
    for (const target of targets) {
      const scope = target.advanced ? "advanced" : "default";
      const identity = target.serviceKey ?? `${target.app}/${target.canonicalEnvironment}`;
      console.log(`  ${target.id}  ${target.label} [${identity}] (${scope})`);
    }
    console.log("");
  }
}

function renderMenu(title, options, extraOptions = []) {
  console.log("");
  console.log(colorize(title, ANSI.cyan));
  for (let index = 0; index < options.length; index += 1) {
    const option = options[index];
    const description = option.description ? ` ${colorize(`- ${option.description}`, ANSI.dim)}` : "";
    console.log(`  ${index + 1}. ${option.label}${description}`);
  }

  for (let extraIndex = 0; extraIndex < extraOptions.length; extraIndex += 1) {
    const option = extraOptions[extraIndex];
    const description = option.description ? ` ${colorize(`- ${option.description}`, ANSI.dim)}` : "";
    console.log(`  ${String.fromCharCode(97 + extraIndex)}. ${option.label}${description}`);
  }
}

async function chooseOption(interfaceHandle, title, options, extraOptions = []) {
  while (true) {
    renderMenu(title, options, extraOptions);
    const answer = (await interfaceHandle.question("Choose an option: ")).trim().toLowerCase();

    if (answer.length === 0) {
      continue;
    }

    const numericChoice = Number.parseInt(answer, 10);
    if (Number.isInteger(numericChoice) && numericChoice >= 1 && numericChoice <= options.length) {
      return options[numericChoice - 1];
    }

    const extraIndex = answer.charCodeAt(0) - 97;
    if (answer.length === 1 && extraIndex >= 0 && extraIndex < extraOptions.length) {
      return extraOptions[extraIndex];
    }

    console.log(colorize("Invalid selection. Enter a listed number or letter.", ANSI.yellow));
  }
}

function titleCase(value) {
  return value
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((segment) => segment.charAt(0).toUpperCase() + segment.slice(1))
    .join(" ");
}

function stripAnsi(value) {
  return value.replace(/\u001b\[[0-9;]*m/g, "");
}

function normalizeUrlCandidate(value) {
  return value.replace(/[)\],.;:]+$/u, "");
}

function isDeploymentUrl(value) {
  try {
    const parsedUrl = new URL(value);
    return parsedUrl.protocol === "https:" && (
      parsedUrl.hostname.endsWith(".vercel.app") ||
      parsedUrl.hostname.endsWith(".vercel.link")
    );
  } catch {
    return false;
  }
}

export function extractVercelDeploymentUrl(output) {
  const normalizedOutput = stripAnsi(typeof output === "string" ? output : "");
  const labeledPreviewMatches = [...normalizedOutput.matchAll(/\bPreview:\s+(https:\/\/\S+)/giu)];
  if (labeledPreviewMatches.length > 0) {
    return normalizeUrlCandidate(labeledPreviewMatches.at(-1)[1]);
  }

  const labeledProductionMatches = [...normalizedOutput.matchAll(/\bProduction:\s+(https:\/\/\S+)/giu)];
  if (labeledProductionMatches.length > 0) {
    return normalizeUrlCandidate(labeledProductionMatches.at(-1)[1]);
  }

  const deploymentUrlMatches = [...normalizedOutput.matchAll(/https:\/\/\S+/giu)]
    .map((match) => normalizeUrlCandidate(match[0]))
    .filter((candidate) => isDeploymentUrl(candidate));

  return deploymentUrlMatches.length > 0 ? deploymentUrlMatches.at(-1) : null;
}

export function findCounterpartTarget(targets, target, actionId) {
  const matchingTargets = targets.filter(
    (candidate) => candidate.app === target.app && candidate.action.id === actionId
  );

  if (matchingTargets.length === 0) {
    return null;
  }

  return matchingTargets.find((candidate) => !candidate.advanced) ?? matchingTargets[0];
}

function printPreviewDeploymentSummary(target, configuration, executionResult) {
  const deployedPreviewUrl = extractVercelDeploymentUrl(executionResult.combinedOutput);
  const prodCounterpart = findCounterpartTarget(configuration.targets, target, "deploy-prod");

  console.log("");
  console.log(colorize("Preview Deploy Summary", ANSI.green));
  console.log(`  app:                 ${titleCase(target.app)}`);
  console.log(`  environment:         ${target.displayEnvironment}`);
  console.log(`  hostname:            ${target.hostnameHint ?? "not declared"}`);
  console.log(`  deployed preview URL:${deployedPreviewUrl ? ` ${deployedPreviewUrl}` : " not detected from deploy output"}`);
  console.log(`  prod counterpart:    ${prodCounterpart ? `pnpm run ${prodCounterpart.script}` : "not configured"}`);
}

function printTargetSummary(target, packageScripts) {
  console.log("");
  console.log(colorize(target.label, ANSI.green));
  console.log(`  id:           ${target.id}`);
  console.log(`  action:       ${target.action.label}`);
  console.log(`  surface:      ${target.advanced ? "Maintenance / Advanced" : "Top-level"}`);
  console.log(`  group:        ${target.group.label}`);
  console.log(`  app:          ${titleCase(target.app)}`);
  console.log(`  environment:  ${target.displayEnvironment}`);
  if (target.serviceKey) {
    console.log(`  service key:  ${target.serviceKey}`);
  }
  if (target.hostnameHint) {
    console.log(`  hostname:     ${target.hostnameHint}`);
  }
  if (target.prPreviewHint) {
    console.log(`  pr preview:   ${target.prPreviewHint}`);
  }
  console.log(`  launcher run: pnpm run ${target.script}`);
  console.log(`  package.json: ${packageScripts[target.script]}`);

  if (target.description) {
    console.log(`  summary:      ${target.description}`);
  }

  if (target.preflightScripts.length > 0) {
    console.log("  preflight:");
    for (const preflightScript of target.preflightScripts) {
      console.log(`    - pnpm run ${preflightScript}`);
    }
  } else {
    console.log("  preflight:    handled by the approved package script or not required");
  }

  if (target.notes.length > 0) {
    console.log("  notes:");
    for (const note of target.notes) {
      console.log(`    - ${note}`);
    }
  }
}

function runScript(scriptName, phaseLabel) {
  return new Promise((resolve, reject) => {
    console.log("");
    console.log(colorize(`${phaseLabel}: pnpm run ${scriptName}`, ANSI.cyan));

    const execution = buildPnpmScriptExecution(scriptName, { cwd: STACK_ROOT, stdio: "pipe" });
    const child = spawnWithSpec(execution);
    let stdout = "";
    let stderr = "";
    let combinedOutput = "";

    child.stdout?.on("data", (chunk) => {
      const text = chunk.toString();
      stdout += text;
      combinedOutput += text;
      process.stdout.write(chunk);
    });

    child.stderr?.on("data", (chunk) => {
      const text = chunk.toString();
      stderr += text;
      combinedOutput += text;
      process.stderr.write(chunk);
    });

    child.on("error", (error) => {
      const detail = error instanceof Error ? error.message : String(error);
      reject(new Error(`${phaseLabel} failed to launch.\n${detail}\n${formatExecutionSpec(execution)}`));
    });
    child.on("exit", (code, signal) => {
      if (signal) {
        reject(new Error(`${phaseLabel} was terminated by signal ${signal}.`));
        return;
      }
      resolve({
        exitCode: code ?? 1,
        stdout,
        stderr,
        combinedOutput
      });
    });
  });
}

async function confirmExecution(interfaceHandle, target) {
  const proceedAnswer = (await interfaceHandle.question("Proceed with this action? [y/N]: ")).trim().toLowerCase();
  if (proceedAnswer !== "y" && proceedAnswer !== "yes") {
    console.log(colorize("Cancelled before execution.", ANSI.yellow));
    return false;
  }

  if (!target.requiresTypedConfirmation) {
    return true;
  }

  console.log("");
  console.log(colorize("Typed confirmation required for this target.", ANSI.yellow));
  console.log(`Type exactly: ${target.confirmText}`);
  const typedAnswer = (await interfaceHandle.question("> ")).trim();
  if (typedAnswer !== target.confirmText) {
    console.log(colorize("Confirmation text did not match. Execution cancelled.", ANSI.red));
    return false;
  }

  return true;
}

async function executeTarget(interfaceHandle, target, packageScripts, configuration, options) {
  printTargetSummary(target, packageScripts);

  if (options.dryRun) {
    console.log("");
    console.log(colorize("Dry run only. No commands were executed.", ANSI.yellow));
    return 0;
  }

  const confirmed = await confirmExecution(interfaceHandle, target);
  if (!confirmed) {
    return 1;
  }
  interfaceHandle.close();

  for (const preflightScript of target.preflightScripts) {
    const preflightResult = await runScript(preflightScript, "Preflight");
    if (preflightResult.exitCode !== 0) {
      console.log(colorize(`Preflight failed with exit code ${preflightResult.exitCode}.`, ANSI.red));
      return preflightResult.exitCode;
    }
  }

  const executionResult = await runScript(target.script, "Execute");
  if (executionResult.exitCode !== 0) {
    console.log(colorize(`Target failed with exit code ${executionResult.exitCode}.`, ANSI.red));
    return executionResult.exitCode;
  }

  console.log("");
  console.log(colorize(`Completed ${target.label}.`, ANSI.green));
  if (target.action.id === "preview" && target.canonicalEnvironment === "preview") {
    printPreviewDeploymentSummary(target, configuration, executionResult);
  }
  return 0;
}

function buildAppOptions(targets) {
  const appIds = [...new Set(targets.map((target) => target.app))].sort((left, right) => left.localeCompare(right));
  return appIds.map((appId) => {
    const appTargets = targets.filter((target) => target.app === appId);
    const description = appTargets.length === 1
      ? appTargets[0].description || `${appTargets[0].label} via ${appTargets[0].script}`
      : `${appTargets.length} approved commands`;
    return {
      kind: "app",
      id: appId,
      label: titleCase(appId),
      description
    };
  });
}

function buildTargetOptions(targets) {
  return sortTargets(targets).map((target) => ({
    kind: "target",
    id: target.id,
    label: target.label,
    description: target.description || `${target.displayEnvironment} via ${target.script}`
  }));
}

async function selectTargetInteractively(interfaceHandle, configuration) {
  while (true) {
    const actionChoice = await chooseOption(
      interfaceHandle,
      "Choose an operator action",
      configuration.actions.map((action) => ({
        kind: "action",
        id: action.id,
        label: action.label,
        description: action.description
      })),
      [{ kind: "exit", label: "Exit" }]
    );

    if (actionChoice.kind === "exit") {
      return null;
    }

    const action = configuration.actionMap.get(actionChoice.id);
    const availableTargets = getTargetsForAction(configuration, action.id);

    if (availableTargets.length === 0) {
      console.log(colorize(`No approved targets are currently mapped to ${action.label}.`, ANSI.yellow));
      continue;
    }

    while (true) {
      const appChoice = await chooseOption(
        interfaceHandle,
        `${action.label}: choose an app`,
        buildAppOptions(availableTargets),
        [
          { kind: "back", label: "Back" },
          { kind: "exit", label: "Exit" }
        ]
      );

      if (appChoice.kind === "exit") {
        return null;
      }
      if (appChoice.kind === "back") {
        break;
      }

      const appTargets = availableTargets.filter((target) => target.app === appChoice.id);
      if (appTargets.length === 1) {
        return appTargets[0];
      }

      const targetChoice = await chooseOption(
        interfaceHandle,
        `${action.label}: ${titleCase(appChoice.id)}`,
        buildTargetOptions(appTargets),
        [
          { kind: "back", label: "Back" },
          { kind: "exit", label: "Exit" }
        ]
      );

      if (targetChoice.kind === "exit") {
        return null;
      }
      if (targetChoice.kind === "back") {
        continue;
      }

      return configuration.targetMap.get(targetChoice.id);
    }
  }
}

async function main() {
  let options;
  try {
    options = parseArguments(process.argv.slice(2));
  } catch (error) {
    console.error(colorize(error.message, ANSI.red));
    usage();
    process.exitCode = 1;
    return;
  }

  if (options.help) {
    usage();
    return;
  }

  const packageJson = await readJson(DEFAULT_PACKAGE_PATH);
  const packageScripts = packageJson?.scripts ?? {};
  const topology = await loadAtlasTopologyManifest();
  const configuration = validateConfiguration(await readJson(options.configPath), packageScripts, topology);

  if (options.list) {
    listTargets(configuration);
    return;
  }

  const target = options.targetId ? configuration.targetMap.get(options.targetId) : null;
  if (options.targetId && !target) {
    throw new Error(`Unknown target id: ${options.targetId}`);
  }

  const interfaceHandle = createInterface({
    input: process.stdin,
    output: process.stdout
  });

  try {
    const selectedTarget = target ?? await selectTargetInteractively(interfaceHandle, configuration);
    if (!selectedTarget) {
      console.log(colorize("No target selected. Exiting.", ANSI.yellow));
      return;
    }

    const exitCode = await executeTarget(interfaceHandle, selectedTarget, packageScripts, configuration, options);
    process.exitCode = exitCode;
  } finally {
    interfaceHandle.close();
  }
}

const currentScriptPath = process.argv[1] ? path.resolve(process.argv[1]) : null;

if (currentScriptPath === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error("");
    console.error(colorize("Launcher failed.", ANSI.red));
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
