import assert from "node:assert/strict";
import test from "node:test";
import { buildExecutionSpec, buildPnpmScriptExecution, formatExecutionSpec } from "./command-runner.mjs";

test("normalizes pnpm run targets for Windows launcher execution", () => {
  const spec = buildPnpmScriptExecution("mazer:deploy:prod", {
    cwd: "C:\\ATLAS\\repos\\_stack",
    env: {},
    platform: "win32"
  });

  assert.equal(spec.executable, "pnpm.cmd");
  assert.deepEqual(spec.args, ["run", "mazer:deploy:prod"]);
  assert.equal(spec.cwd, "C:\\ATLAS\\repos\\_stack");
  assert.equal(spec.shell, true);
});

test("keeps powershell.exe direct on Windows", () => {
  const spec = buildExecutionSpec({
    executable: "powershell",
    args: ["-NoProfile", "-File", ".\\ops\\Invoke-MazerDeploy.ps1"],
    cwd: "C:\\ATLAS\\repos\\_stack",
    env: {},
    platform: "win32"
  });

  assert.equal(spec.executable, "powershell.exe");
  assert.deepEqual(spec.args, ["-NoProfile", "-File", ".\\ops\\Invoke-MazerDeploy.ps1"]);
  assert.equal(spec.shell, false);
});

test("routes batch wrappers through shell mode on Windows", () => {
  const spec = buildExecutionSpec({
    executable: ".\\ops\\bin\\mazer-preview.cmd",
    args: [],
    cwd: "C:\\ATLAS\\repos\\_stack",
    env: {},
    platform: "win32"
  });

  assert.equal(spec.executable, ".\\ops\\bin\\mazer-preview.cmd");
  assert.deepEqual(spec.args, []);
  assert.equal(spec.shell, true);
});

test("formats the resolved execution details for failure output", () => {
  const spec = buildPnpmScriptExecution("mazer:verify", {
    cwd: "C:\\ATLAS\\repos\\_stack",
    env: {},
    platform: "win32"
  });

  assert.equal(
    formatExecutionSpec(spec),
    "executable: pnpm.cmd\nargs: [\"run\",\"mazer:verify\"]\ncwd: C:\\ATLAS\\repos\\_stack\nshell: true"
  );
});
