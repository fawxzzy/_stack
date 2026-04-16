import assert from "node:assert/strict";
import test from "node:test";
import { extractVercelDeploymentUrl, findCounterpartTarget } from "./release-launcher.mjs";

test("extracts the labeled Vercel preview URL from launcher output", () => {
  const output = [
    "Inspect: https://vercel.com/fawxzzy/fitness/abc123 [2s]",
    "Preview: https://fitness-git-main-fawxzzy.vercel.app [2s]"
  ].join("\n");

  assert.equal(
    extractVercelDeploymentUrl(output),
    "https://fitness-git-main-fawxzzy.vercel.app"
  );
});

test("falls back to the last deployment hostname when Vercel prints a bare URL", () => {
  const output = [
    "\u001b[32mDeploying project...\u001b[0m",
    "https://mazer-7d9k3f4m-fawxzzy.vercel.app"
  ].join("\n");

  assert.equal(
    extractVercelDeploymentUrl(output),
    "https://mazer-7d9k3f4m-fawxzzy.vercel.app"
  );
});

test("prefers the standard prod target as the preview deploy counterpart", () => {
  const counterpart = findCounterpartTarget(
    [
      {
        id: "fitness-prod-prebuilt",
        app: "fitness",
        action: { id: "deploy-prod" },
        advanced: true,
        script: "fitness:deploy:prebuilt:prod"
      },
      {
        id: "fitness-prod",
        app: "fitness",
        action: { id: "deploy-prod" },
        advanced: false,
        script: "fitness:deploy:prod"
      }
    ],
    {
      id: "fitness-preview",
      app: "fitness",
      action: { id: "preview" },
      advanced: false,
      script: "fitness:deploy:preview"
    },
    "deploy-prod"
  );

  assert.equal(counterpart?.id, "fitness-prod");
});
