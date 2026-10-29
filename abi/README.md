# umia-abi

Typed ABIs, raw JSON exports, and the deployed address book for the Umia smart contracts. ABIs are generated from `forge build` output via `wagmi-cli`; addresses come from the monorepo's `contracts.json`.

> Published to npm as **`umia-abi`** (unscoped). Inside the monorepo it's the `@umia/abi` workspace package; the name is swapped at publish time (see `publish.sh`).

## Layout

| Path                        | What                                                            |
| --------------------------- | --------------------------------------------------------------- |
| `src/contracts.ts`          | Source-of-truth list of contracts whose ABIs we publish          |
| `src/generated.ts`          | `wagmi generate` output: typed `as const` ABIs                   |
| `src/generated-addresses.ts`| Address book, generated from the monorepo's `contracts.json`     |
| `src/addresses.ts`          | Typed lookups over the address book                              |
| `src/index.ts`              | Public TS entrypoint                                             |
| `json/*.json`               | Raw ABI JSON, one file per contract                              |
| `addresses.json`            | Raw address book, for non-TS consumers                           |
| `wagmi.config.ts`           | `wagmi-cli` config                                               |
| `src/dump-json.ts`          | Extracts `out/*.sol/*.json` → `json/*.json`                      |
| `src/gen-addresses.ts`      | Extracts `contracts.json` → the address book                     |

## Use

From inside the monorepo:

```ts
import { umiaHubAbi } from "@umia/abi";
```

From outside (`bun add umia-abi`):

```ts
import { umiaHubAbi, getContractAddress } from "umia-abi";

const hub = getContractAddress("mainnet", 8453, "hub");
```

The package is published as compiled ESM with `.d.ts` alongside, so plain Node
works. Raw JSON is available too, for non-TS clients:

```ts
import umiaHub from "umia-abi/json/UmiaHub.json";
import addresses from "umia-abi/addresses.json";
```

## Regenerate

After changing any of the contracts listed in `src/contracts.ts`, from `abi/`:

```bash
bun run codegen
```

This runs `wagmi generate` (which calls `forge build` internally), dumps the raw JSON, and regenerates the address book. The package's devDependencies use the monorepo's `catalog:` ranges, so codegen runs from the monorepo workspace; the published package carries no dev dependencies. Commit the regenerated `src/generated.ts`, `json/*.json`, `addresses.json`, and `src/generated-addresses.ts` alongside the contract change.

## Addresses

`addresses.json` and `src/generated-addresses.ts` are generated from the
monorepo's root `contracts.json`, narrowed to what's useful publicly: the
`testnet` and `mainnet` environments only (devnet is an internal anvil fork that
resets without warning), minus operational fields like `anvilUrl` and
`maxReorgDepth`.

`startBlock` is the block Umia's own indexer syncs that chain from. On the mainnet chains it is the protocol's deployment block; on a testnet it can sit after a reset or after history-pruning upstreams forced a later start, so do not read it as the first protocol transaction there.

```ts
import { addresses, getChainAddressesById, getContractAddress } from "umia-abi";

getContractAddress("mainnet", 8453, "hub");        // "0x120dbC…" | null
getChainAddressesById("mainnet", 8453)?.startBlock; // indexer start height
addresses.mainnet.base.umia.ccaFactory;             // literal-typed
```

Regenerate with `bun run addresses` (or `bun run codegen`, which includes it).
CI re-derives it on any `contracts.json` change via `check-addresses.sh`, so a
redeploy that updates `contracts.json` without regenerating fails the build.
Outside the monorepo, point `CONTRACTS_JSON` at a copy of the file; without one
the address step is skipped and the committed address book is kept.

## Adding a contract

Add the name to the appropriate list in `src/contracts.ts`: `CONTRACTS` (in-scope deployables), `INTERFACES` (spec-only / integrator-facing), or `LIBRARIES` (with custom errors). Then run `bun run codegen`.

## Decoding errors

Custom errors are declared across contracts, interfaces, and libraries. `allErrorsAbi` is a composite that unions every error declaration in the published surface, so SDK consumers can decode any revert without manually composing ABIs:

```ts
import { allErrorsAbi } from "@umia/abi";
import { decodeErrorResult } from "viem";

try {
  await client.simulateContract(...);
} catch (err) {
  const decoded = decodeErrorResult({ abi: allErrorsAbi, data: err.data });
  console.log(decoded.errorName, decoded.args);
}
```

The three lists exist because solc doesn't always bubble errors from libraries and uninherited interfaces into the calling contract's ABI. Shipping the source-of-truth ABIs alongside the contract ABIs closes that gap.

## Publishing to npm

1. Bump `version` in `abi/package.json`.
2. Commit the bump.
3. From `abi/`:
   ```bash
   ./publish.sh
   ```

The script refuses to publish if `abi/` has uncommitted changes or if `bun run codegen` would produce a diff (i.e. the committed ABIs are stale). It then typechecks, compiles `src/` to `dist/`, and publishes as **`umia-abi`** with public access.

Two manifest fields are publish-time only, applied by `publish-manifest.ts` and reverted by a trap in `publish.sh`: the `@umia/abi` workspace name becomes the unscoped `umia-abi`, and the entrypoints move from `src/*.ts` to `dist/*.js`. In-repo consumers resolve the TypeScript sources directly; published consumers can't, because Node refuses to type-strip inside `node_modules`.

Consumers install with `bun add umia-abi` (or `pnpm` / `npm`) and import either the typed TS barrel or the raw JSON files:

```ts
// typed (viem / wagmi-friendly, `as const` ABIs) + addresses
import { umiaHubAbi, allErrorsAbi, getContractAddress } from "umia-abi";

// raw JSON (any TS / JS / Node setup)
import umiaHub from "umia-abi/json/UmiaHub.json";
import addresses from "umia-abi/addresses.json";
```
