import { spawn } from "node:child_process";
import process from "node:process";

const WINDOWS_BATCH_PATTERN = /\.(cmd|bat)$/i;
const WINDOWS_PNPM_PATTERN = /^pnpm(?:\.cmd)?$/i;
const WINDOWS_POWERSHELL_PATTERN = /^powershell(?:\.exe)?$/i;

function ensureExecutable(value) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error("Command executable must be a non-empty string.");
  }

  return value.trim();
}

function normalizeArguments(args) {
  if (args === undefined) {
    return [];
  }

  if (!Array.isArray(args)) {
    throw new Error("Command args must be an array when provided.");
  }

  return args.map((arg, index) => {
    if (typeof arg !== "string") {
      throw new Error(`Command arg at index ${index} must be a string.`);
    }

    return arg;
  });
}

export function buildExecutionSpec({
  executable,
  args = [],
  cwd,
  env = process.env,
  platform = process.platform,
  shell,
  stdio = "inherit"
}) {
  let normalizedExecutable = ensureExecutable(executable);
  const normalizedArgs = normalizeArguments(args);

  if (platform === "win32") {
    if (WINDOWS_PNPM_PATTERN.test(normalizedExecutable)) {
      normalizedExecutable = "pnpm.cmd";
    } else if (WINDOWS_POWERSHELL_PATTERN.test(normalizedExecutable)) {
      normalizedExecutable = "powershell.exe";
    }
  }

  const normalizedShell = typeof shell === "boolean"
    ? shell
    : platform === "win32" && WINDOWS_BATCH_PATTERN.test(normalizedExecutable);

  return {
    executable: normalizedExecutable,
    args: normalizedArgs,
    cwd,
    env,
    platform,
    shell: normalizedShell,
    stdio
  };
}

export function buildPnpmScriptExecution(scriptName, options = {}) {
  if (typeof scriptName !== "string" || scriptName.trim().length === 0) {
    throw new Error("Package script name must be a non-empty string.");
  }

  return buildExecutionSpec({
    executable: "pnpm",
    args: ["run", scriptName.trim()],
    ...options
  });
}

export function formatExecutionSpec(spec) {
  return [
    `executable: ${spec.executable}`,
    `args: ${JSON.stringify(spec.args)}`,
    `cwd: ${spec.cwd}`,
    `shell: ${String(spec.shell)}`
  ].join("\n");
}

export function spawnWithSpec(spec) {
  return spawn(spec.executable, spec.args, {
    cwd: spec.cwd,
    env: spec.env,
    shell: spec.shell,
    stdio: spec.stdio
  });
}
