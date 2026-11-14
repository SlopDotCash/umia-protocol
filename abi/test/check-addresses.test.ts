import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const outputs = ["abi/addresses.json", "abi/src/generated-addresses.ts"];

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "umia-address-check-"));
  mkdirSync(join(dir, "abi/src"), { recursive: true });
  for (const file of ["check-addresses.sh", "abi/src/gen-addresses.ts"]) {
    copyFileSync(join(root, file), join(dir, file));
  }
  const source = join(dir, "contracts.json");
  writeFileSync(source, JSON.stringify({ testnet: {}, mainnet: {} }));
  const env = {
    PATH: `${dirname(process.execPath)}:${process.env.PATH}`,
    HOME: dir,
    CONTRACTS_JSON: source,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
  };
  const run = (command: string, args: string[]) => {
    const result = spawnSync(command, args, { cwd: dir, env, encoding: "utf8" });
    if (result.error) throw result.error;
    return result;
  };
  const success = (command: string, args: string[]) => {
    const result = run(command, args);
    assert.equal(result.status, 0, result.stdout + result.stderr);
  };
  success("git", ["init", "-q"]);
  success("git", ["config", "user.name", "Address check test"]);
  success("git", ["config", "user.email", "test@example.invalid"]);
  success(process.execPath, ["abi/src/gen-addresses.ts"]);
  success("git", ["add", "."]);
  success("git", ["commit", "-qm", "fixture"]);
  return {
    dir, source, run, success,
    check: () => run("bash", ["check-addresses.sh"]),
    dispose: () => rmSync(dir, { recursive: true, force: true }),
  };
}

test("address check accepts committed output and ignores unrelated files", () => {
  const f = fixture();
  try {
    writeFileSync(join(f.dir, "unrelated.txt"), "not generated\n");
    const result = f.check();
    assert.equal(result.status, 0, result.stdout + result.stderr);
  } finally {
    f.dispose();
  }
});

test("address check rejects tracked output drift", () => {
  const f = fixture();
  try {
    writeFileSync(f.source, JSON.stringify({ testnet: {}, mainnet: { base: { chainId: 8453 } } }));
    assert.equal(f.check().status, 1);
  } finally {
    f.dispose();
  }
});

test("address check rejects regenerated output missing from the commit", () => {
  const f = fixture();
  try {
    f.success("git", ["rm", ...outputs]);
    f.success("git", ["commit", "-qm", "omit generated output"]);
    const result = f.check();
    for (const output of outputs) assert.ok(readFileSync(join(f.dir, output)).length);
    assert.equal(result.status, 1, result.stdout + result.stderr);
  } finally {
    f.dispose();
  }
});

test("address check rejects staged output not yet committed", () => {
  const f = fixture();
  try {
    writeFileSync(f.source, JSON.stringify({ testnet: {}, mainnet: { base: { chainId: 8453 } } }));
    f.success(process.execPath, ["abi/src/gen-addresses.ts"]);
    f.success("git", ["add", ...outputs]);
    const result = f.check();
    assert.equal(result.status, 1, result.stdout + result.stderr);
  } finally {
    f.dispose();
  }
});
