/**
 * Rewrites package.json for publication, in place. publish.sh reverts it with a
 * `git checkout` trap, so the committed manifest never carries these values.
 *
 * The workspace name @umia/abi becomes the unscoped npm name
 * (the @umia scope is unavailable), and the entrypoints move from src/*.ts to
 * the compiled dist/. In-repo consumers resolve the TypeScript directly, but
 * published consumers cannot: Node refuses to type-strip inside node_modules
 * (ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING), so shipping src would break
 * every non-Bun install.
 */
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MANIFEST = resolve(dirname(fileURLToPath(import.meta.url)), "package.json");

const pkg = JSON.parse(await readFile(MANIFEST, "utf-8"));

pkg.name = "umia-abi";
pkg.main = "./dist/index.js";
pkg.types = "./dist/index.d.ts";
// Build tools use monorepo-only catalog ranges. The compiled package needs
// none of them, and Bun cannot resolve those ranges outside the workspace.
delete pkg.devDependencies;
pkg.exports = {
  ".": { types: "./dist/index.d.ts", default: "./dist/index.js" },
  "./contracts": { types: "./dist/contracts.d.ts", default: "./dist/contracts.js" },
  "./addresses": { types: "./dist/addresses.d.ts", default: "./dist/addresses.js" },
  "./addresses.json": "./addresses.json",
  "./json/*": "./json/*",
};

await writeFile(MANIFEST, `${JSON.stringify(pkg, null, 2)}\n`);

console.log(`→ manifest set to ${pkg.name}@${pkg.version} (entrypoints -> dist/)`);
