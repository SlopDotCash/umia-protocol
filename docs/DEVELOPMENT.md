# Smart Contracts Development Guide

This guide is for contributors working in this Foundry project.

## 1) Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation). `foundry.toml` pins
  `solc = "0.8.26"` and builds with `via-ir`, so the first build is slow.
- Git, with the submodules under `lib/` initialized:

```bash
git submodule update --init --recursive
```

Optional: Anvil for the local Uniswap v4 bootstrap (`script/DeployV4Infra.s.sol`), `bun` for the
ABI package, `jq` and `curl` for the verification helpers.

## 2) Build, test, format

```bash
forge build
forge test
forge fmt
```

Useful targeted runs:

```bash
forge test --match-path 'test/markets/*'
forge test --match-path 'test/governance/*'
forge test --match-path 'test/launchpad/*'
forge test --match-path 'test/periphery/*'
forge test --match-test testFunctionName
```

Run `forge fmt` before sending a change; CI checks with `forge fmt --check`.

### Fork tests

`test/fork/*.t.sol` and `test/proxy/UpgradeRehearsal.t.sol` run against a fork of a live
deployment. They read `FORK_RPC_URL` and skip (or set up nothing) when it is unset, so the default
`forge test` never touches the network. To run them:

```bash
FORK_RPC_URL=https://... forge test --match-path 'test/fork/*'
```

Some of them need more:

- `test/fork/SpotMigrationUmiaFork.t.sol` pins its block (`FORK_BLOCK` overrides it) because the
  migration reverts by design when spot is far from its TWAP.
- `test/fork/AllowanceSourcesUpgradeInvariants.t.sol` and `test/proxy/UpgradeRehearsal.t.sol`
  resolve the hub through `script/ProtocolState.sol`, which reads `../contracts.json`
  (`<env>.<chain>.umia.hub`, selected by `UMIA_ENV` and `UMIA_CHAIN`). That address book is not
  part of this tree; supply one with the hub address of the deployment you fork.

## 3) Check scripts

All of these live at the project root.

| Script | What it does | Needs |
| ------ | ------------ | ----- |
| `check-licenses.sh` | Every file under `src/` carries the expected SPDX identifier on line 1 (MIT for `src/interfaces/`, `src/zktls/` and a listed set of libraries and value types, BUSL-1.1 for the rest), `src/` does not import `@metavest` (AGPL stays out of deployed code), and `licenses/` has no placeholder left | bash |
| `check-contract-sizes.sh` | `forge inspect <Contract> deployedBytecode` for every deployable listed in the script is at most 24576 bytes (EIP-170), printed with its margin | a build |
| `check-abi-codegen.sh` | Regenerates the ABI package (`bun run codegen` in `abi/`) and fails if `abi/src/generated.ts`, `abi/src/generated-addresses.ts`, `abi/addresses.json` or `abi/json/` differ from the committed copies | `bun`, and the project in a directory named `smart-contracts` (the script `cd`s one level up) |
| `check-addresses.sh` | Regenerates only the address book (`abi/addresses.json`, `abi/src/generated-addresses.ts`) and fails on a diff. No forge or solc needed | `bun`, the same directory layout, and the `contracts.json` address book the generator reads, which is not part of this tree |
| `check-bid-validation-doc.sh` | Hashes the validation hook sources against a hash recorded in a documentation page outside this tree | that page; not runnable from a standalone checkout |
| `verify-fixed.sh <address> <path:Name> [ctor-args-hex] [forge args]` | Verifies a contract on Base (chain id 8453) through the Etherscan v2 API using forge's standard JSON input, with the remappings taken from the deployed artifact's metadata. Forge's own verify path infers an extra `test/=...` remapping that changes the metadata hash and fails the exact-bytecode check | a build in `out/`, `ETHERSCAN_API_KEY`, `jq`, `curl` |
| `verify-runtime.sh <address> <path:Name> [forge args]` | For contracts created at runtime by another contract or an EOA outside a forge broadcast: fetches the creation transaction, strips the local artifact's creation bytecode off its input to recover the constructor args, then calls `verify-fixed.sh` | same as above |

## 4) Storage layout snapshots

`.storage-layouts/UmiaHub.json`, `UmiaMarketCore.json` and `Venture.json` are the storage layouts
of the three upgradeable contracts: the `forge inspect <Contract> storageLayout` output reduced to
`label`, `slot`, `offset` and `type` per variable, plus the `types` table. They are the reference
for two comparisons:

- **Drift**: the layout of the current build must equal the committed snapshot. When a storage
  change is intentional, regenerate the snapshot from the new build and review the diff; that diff
  is the review artifact for the storage change.
- **Compatibility**: the new layout must be upgrade-safe against the snapshot of the release that is
  live on the target chain. Every existing variable keeps its label, slot, offset and type; struct
  and mapping internals do not change; new variables either fit in unused bytes of the last pre-gap
  slot or take slots from `__gap`, which shrinks by exactly that many; nothing is removed.

Rules and layout history: [UPGRADES.md](./UPGRADES.md#storage-layout).

## 5) ABI package

`abi/` is the `umia-abi` npm package: typed `as const` ABIs generated with `wagmi-cli` from the
forge build, raw JSON per contract, a composite `allErrorsAbi` for decoding reverts, and the
deployed address book. After changing any contract listed in `abi/src/contracts.ts`:

```bash
cd abi && bun run codegen
```

The package's devDependencies are `catalog:` ranges from the monorepo root, so codegen runs from the monorepo workspace, not from a standalone checkout.

Commit the regenerated `src/generated.ts`, `json/*.json`, `addresses.json` and
`src/generated-addresses.ts` with the contract change. `check-abi-codegen.sh` fails CI on stale
output. See [`abi/README.md`](../abi/README.md) for the layout and the publishing steps.

## 6) Repository layout

- `src/core/` - hub, market core, market stake, venture treasury + proxy, governance executor, spot liquidity vaults (V1, V2) and active liquidity manager
- `src/periphery/` - conditional market oracle, `UmiaHook`/`UmiaHookV2` (spot oracle + pool registry), `SpotMigrator`, auction validation hook + server permits, CCA exit helper, vesting authority, yield guardian, TWAP milestone condition
- `src/launchpad/` - LBP strategy and factory (V1 and V2)
- `src/tokens/` - venture token
- `src/libraries/` - CPMM math, market creation + settlement (external libraries), governance action VM/types, helpers
- `src/interfaces/`, `src/zktls/` (zkTLS verifier), `src/liquidation/`
- `script/` - deployment and upgrade scripts
- `test/` - Foundry test suites
- `docs/` - protocol and contract docs
- `certora/` - formal verification specs
- `abi/` - the ABI package

## 7) Deployment scripts

For a full new-chain deployment, see `docs/NEW_CHAIN_DEPLOYMENT.md`; for upgrades,
`docs/UPGRADES.md`.

### Deploy protocol contracts

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url <RPC_URL> \
  --broadcast
```

Inputs:
- Required: `DEPLOYER_PRIVATE_KEY`, `POOL_MANAGER`, `UMIA_HOOK_DEPLOYER`, `UMIA_HOOK_V2_SALT`, `TWAP_WINDOW` (unless `METAVEST_FACTORY` reuses the singletons)
- Required decision: `VESTING_ADMIN`, `VETO_GUARDIAN` and `ACTIVE_LIQUIDITY_KEEPER`, or the matching `*_UNSET_OK=true`
- Optional: `MARKET_CREATION_SIGNER_KEY`, `USDC_ADDRESS`, and reuse addresses (`CCA_FACTORY`, `ZKTLS_VERIFIER_ADDRESS`, `CCA_EXIT_HELPER_ADDRESS`, ...)

### Deploy local Uniswap v4 infra (for fresh local chains)

```bash
forge script script/DeployV4Infra.s.sol:DeployV4Infra \
  --rpc-url http://localhost:8545 \
  --broadcast
```

## 8) Developing governance execution payloads

Winning proposal execution payload is decoded as:

- `GovernanceTypes.ExecutionPlanV1`
- containing `GovernanceTypes.ActionV1[]`

Current action semantics live in:
- `src/libraries/GovernanceTypes.sol`
- `src/libraries/GovernancePayloadValidator.sol`
- `src/libraries/GovernanceActions.sol`

When adding an action:
1. Extend `ActionType` / payload structs in `GovernanceTypes`.
2. Add validation in `GovernanceActions.validateActionV1` and execution in `GovernanceActions.executeActionV1`.
3. Add test coverage in `test/governance/*`.
4. Update docs in `docs/GOVERNANCE_TREASURY_LAYER.md` and `docs/contracts/`.

## 9) Market development checklist

For changes touching `UmiaMarketCore`:

- Keep split/merge solvency invariant intact.
- Validate proposal lifecycle (`PENDING -> OPEN -> ENDED`).
- Keep swap-permit replay protection intact (EIP-712 signer recovery + `swapNonces`).
- Keep `_syncOracle` (the `ConditionalMarketOracle.update` push) on every path that changes a proposal pool's reserves.
- Add tests for settlement and claims edge-cases.

## 10) Documentation workflow

If a contract interface changes, update:

1. `docs/contracts/<Contract>.md`
2. `docs/ARCHITECTURE.md` (if interaction flow changed)
3. `README.md` (if new docs added)
4. the ABI package (`cd abi && bun run codegen`; CI fails on stale codegen)

If an upgradeable contract's storage changes, regenerate its snapshot in `.storage-layouts/` and
review the diff (see [Storage layout snapshots](#4-storage-layout-snapshots)).

Keep docs aligned with code in `src/` and tests in `test/`.
