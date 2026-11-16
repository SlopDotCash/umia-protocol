import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

test("publication removes workspace-only dev dependencies", () => {
  const abi = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const dir = mkdtempSync(join(tmpdir(), "umia-publish-manifest-"));
  try {
    for (const file of ["package.json", "publish-manifest.ts"]) {
      copyFileSync(join(abi, file), join(dir, file));
    }
    const original = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
    const result = spawnSync(process.execPath, [join(dir, "publish-manifest.ts")], {
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const published = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
    assert.equal(Object.hasOwn(published, "devDependencies"), false);
    assert.equal(published.name, "umia-abi");
    assert.equal(published.version, original.version);
    assert.equal(published.exports["."].default, "./dist/index.js");
    assert.deepEqual(published.files, original.files);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
