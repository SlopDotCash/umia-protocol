# Umia Protocol

Umia is an onchain protocol for funding and running ventures. A venture raises money by selling its token in a public auction. What it raises sits in a treasury and a liquidity pool that its founders cannot drain. And every decision about that treasury is made by a market, not by a vote.

Each proposal gets its own conditional market. Holders trade on which option makes the token worth more, and the option whose time-weighted price comes out on top is executed against the treasury by a contract: spend, mint, hire, change a parameter, or wind the venture down. Team vesting unlocks on price milestones read from the same pool.

This repository is the whole protocol: the Hub that creates ventures, the auction strategy, the spot pool hook and its oracle, the decision markets, the treasury and its governance executor, the vesting adapter, and the liquidation path. It is deployed on Base and on Robinhood Chain; addresses are in [`abi/addresses.json`](./abi/addresses.json). The code is always the current design; where an earlier generation of a contract still serves live ventures it stays in the tree, and the releases of this repository describe what each upgrade changed.

## How a venture works

Numbers below are the protocol constants and the Hub's defaults as deployed; the Hub owner can move the configurable ones within the bounds in [`UmiaHub`](./docs/contracts/UmiaHub.md).

**1. Creation.** [`UmiaHub.createVenture`](./docs/contracts/UmiaHub.md) deploys three contracts in one transaction: the treasury ([`Venture`](./docs/contracts/Venture.md), a beacon proxy), the token ([`VentureToken`](./docs/contracts/VentureToken.md), a pausable ERC-20 with an initial supply between 100 and 10^12 units; governance can mint and burn later), and the launch strategy ([`UmiaLBPV2`](./docs/contracts/UmiaLBPV2.md)). The Hub mints the supply, hands token ownership to the treasury and sends the supply to the launch contract. Part of it is for sale; the rest is the reserve that will seed the pool.

**2. Auction.** The launch contract runs a continuous clearing auction (Uniswap's CCA) with a floor price and timed steps. Bidding can be gated: [`UmiaValidationHook`](./docs/contracts/UmiaValidationHook.md) checks zkTLS proofs of off-chain facts (through the vendored Reclaim verifier) or single-use server permits before a bid is accepted. Outbid participants exit with `CCAExitHelper`.

**3. Landing.** Once the auction ends and `migrationDelayBlocks` (300) have passed, anyone calls `migrate()`. The raise is swept: `ventureBps` of it goes to the treasury as money; the rest is paired with the reserved tokens in a Uniswap V4 pool whose hook, [`UmiaHookV2`](./docs/contracts/UmiaHookV2.md), is also the oracle. The pool charges `spotSwapFeeBps` (1%), half of which is the protocol's. Pool-bound liquidity goes into two positions the treasury owns: a full-range anchor ([`SpotLiquidityVaultV2`](./docs/contracts/SpotLiquidityVaultV2.md), held through vault shares) and a concentrated range managed by a keeper ([`ActiveLiquidityManager`](./docs/contracts/ActiveLiquidityManager.md)). The Hub sets the split and the first range (`launchAnchorBps`, 75/25 today, and `launchActiveHalfWidthTicks`, 0.33x to 3x around the clearing price). Neither position can be funded twice: each has an immutable `bootstrapper`.

**4. Price.** The hook records two observation rings per pool: one per block and one every hour. The short ring serves the 30-minute TWAP that guards every liquidity move; the coarse ring serves the 6-hour band and the 30-day window that vesting reads. Cardinality is grown once, by anyone, and no keeper is needed to keep the oracle alive. [docs/SPOT_ORACLE.md](./docs/SPOT_ORACLE.md) covers the guards and the fail-closed rules.

**5. Decisions.** A market ([`UmiaMarketCore`](./docs/contracts/UmiaMarketCore.md)) holds up to five proposals plus a mandatory first one, "do nothing", that every other proposal has to beat. Opening one costs the creator a stake and pulls half of the anchor vault's liquidity, split 1:1 into conditional tokens for every proposal so that each proposal starts with the same pool. Anyone splits real tokens into conditional ones, trades on the per-proposal constant-product pools, and merges back. Trading lasts between 1 hour and 96 hours (default 3 days). At settlement the proposal with the highest TWAP, measured by [`ConditionalMarketOracle`](./docs/contracts/ConditionalMarketOracle.md) with a rate-limited tick slew that defeats last-minute pushes, wins, but only if it beats "do nothing" by `winningMarketThresholdBps` (2%). Holders of the winning proposal's tokens redeem 1:1; the losing proposals' pools return to the vault. [docs/DECISION_MARKET_FLOW.md](./docs/DECISION_MARKET_FLOW.md) walks through split, merge, trade, settle and claim with worked numbers.

**6. Execution.** A winning proposal carries a typed plan of at most 20 actions. After `decisionMarketExecutionDelay` (4 hours, bounded between 1 and 12), anyone triggers [`GovernanceExecutor`](./docs/contracts/GovernanceExecutor.md), which validates the plan and dispatches it into the treasury: `MINT_TOKENS`, `BURN_TOKENS`, `TRANSFER_TREASURY_ASSETS`, `UPDATE_MONTHLY_ALLOWANCE`, `UPDATE_TEAM_MEMBER`, `UPDATE_PARAMS`, `UPLOAD_DOCUMENT`, `SET_ALLOWANCE`, `SET_ALLOWANCE_SOURCE`, `CALL`, `UPGRADE_IMPLEMENTATION` and `LIQUIDATE_TREASURY`. Team members draw their monthly allowance directly from the treasury; everything else goes through a market. A veto guardian can trip a per-market circuit breaker during the delay; only the Hub owner resets it. [docs/GOVERNANCE_TREASURY_LAYER.md](./docs/GOVERNANCE_TREASURY_LAYER.md) defines every action.

**7. Vesting and exit.** Team grants live in MetaVesT. [`VentureVestingAuthority`](./docs/contracts/VentureVestingAuthority.md) routes the grant authority to the treasury, so grants are created and amended by decision market, and [`UmiaTwapMilestoneCondition`](./docs/contracts/UmiaTwapMilestoneCondition.md) unlocks each milestone only when the pool's full-window TWAP (30 days on mainnet) clears the milestone's price. `LIQUIDATE_TREASURY` is terminal: the treasury snapshots its assets and `SimpleLiquidator` pays every token holder pro rata. [docs/LIQUIDATIONS.md](./docs/LIQUIDATIONS.md) shows how to build a plan that does it correctly.

## Contract map

Everything that reads a venture's liquidity goes through the Hub's `ventureLiquidityVault` pointer, so decision markets, liquidation and vesting do not care which generation of vault a venture is on.

| Area | Contracts | Reference |
| --- | --- | --- |
| Registry | `UmiaHub` (UUPS): venture factory, protocol pointers, fees, timings, approved money tokens | [UmiaHub](./docs/contracts/UmiaHub.md) |
| Treasury | `Venture` behind `VentureProxy` (beacon): assets, allowances, team, documents, liquidation state | [Venture](./docs/contracts/Venture.md) |
| Token | `VentureToken` | [VentureToken](./docs/contracts/VentureToken.md) |
| Launch | `UmiaLBPV2`, `UmiaLBPFactoryV2`; `CCAExitHelper`; `UmiaLBP` and `UmiaLBPFactory` are the earlier strategy, kept for the ventures it launched | [UmiaLBPV2](./docs/contracts/UmiaLBPV2.md), [UmiaLBP](./docs/contracts/UmiaLBP.md), [UmiaLBPFactory](./docs/contracts/UmiaLBPFactory.md) |
| Bid gating | `UmiaValidationHook`, `HookServerPermits`, `ReclaimProofVerifier` | [UmiaValidationHook](./docs/contracts/UmiaValidationHook.md) |
| Spot pool | `UmiaHookV2`; `SpotMarketOracle`, `TwapMath`, `SpotTwapGuard`, `TickSlew`; `UmiaHook` is the earlier hook, still serving pools created before it | [UmiaHookV2](./docs/contracts/UmiaHookV2.md), [SPOT_ORACLE](./docs/SPOT_ORACLE.md) |
| Spot liquidity | `SpotLiquidityVaultV2`, `ActiveLiquidityManager`, `ActiveSlices`, `SpotLiquidityV2Code`, `SpotLiquidityV2Deploy`; `SpotMigrator` moves a venture from the earlier vault (`SpotLiquidityVault`) in one proposal | [SpotLiquidityVaultV2](./docs/contracts/SpotLiquidityVaultV2.md), [ActiveLiquidityManager](./docs/contracts/ActiveLiquidityManager.md), [SpotMigrator](./docs/contracts/SpotMigrator.md) |
| Decision markets | `UmiaMarketCore` (UUPS) with the external libraries `MarketCreationLib` and `SettlementLib`; `CPMM`, `CPMMWithFee`, `LedgerLib`; `UmiaMarketStake`; `ConditionalMarketOracle` | [UmiaMarketCore](./docs/contracts/UmiaMarketCore.md), [ConditionalMarketOracle](./docs/contracts/ConditionalMarketOracle.md) |
| Execution | `GovernanceExecutor`; `GovernanceTypes`, `GovernancePayloadValidator`, `GovernanceActions` | [GovernanceExecutor](./docs/contracts/GovernanceExecutor.md), [GovernanceTypes](./docs/contracts/GovernanceTypes.md), [GovernanceLibraries](./docs/contracts/GovernanceLibraries.md) |
| Vesting | `VentureVestingAuthority`, `UmiaTwapMilestoneCondition`, MetaVesT (submodule) | [VentureVestingAuthority](./docs/contracts/VentureVestingAuthority.md), [UmiaTwapMilestoneCondition](./docs/contracts/UmiaTwapMilestoneCondition.md), [metavest/README](./docs/metavest/README.md) |
| Wind-down | `SimpleLiquidator`; `YieldPositionGuardian` (emergency exit from yield positions by an appointed operator) | [LIQUIDATIONS](./docs/LIQUIDATIONS.md) |

[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) has the layer diagram and the runtime interaction map; [docs/contracts/README.md](./docs/contracts/README.md) indexes every reference page.

## Trust and control

- **Hub owner.** Sets protocol pointers, fees and timings, approves money tokens, upgrades the Hub and the market core, swaps the governance executor, flips the launch factory. On mainnet this is a timelock. The owner never holds a venture's assets or vault shares; its reach into a venture is through upgrades and pointer changes, which is why it sits behind a timelock.
- **Venture treasury.** Moves only through a passed decision market or a team member's monthly allowance. Holds the vault shares; can pause its ALM.
- **Market creation signer.** Co-signs market creation (EIP-712) so that proposals are well formed before they reach the chain.
- **Veto guardian.** Can trip a per-market circuit breaker during the execution delay. Only the Hub owner resets it.
- **ALM keeper.** Reshapes the concentrated position within TWAP guards and runs basket arbitrage in the venture's own markets. Cannot withdraw; only the treasury can.
- **Vesting admin.** May terminate and reissue grants unless the venture revokes that right.
- **Anyone.** Settles markets, executes winning proposals after the delay, claims decision-market leftovers, grows oracle cardinality, migrates a finished auction.

[docs/SECURITY.md](./docs/SECURITY.md) states the invariants the contracts keep (split/merge solvency, one claim per user per market, one execution per market, terminal liquidation) and the surfaces a reviewer should focus on. `certora/` holds formal specs for the CPMM and the market core; see [certora/README.md](./certora/README.md) for what they cover and what they do not yet.

## Deployments

| Network | Chain id | Hub | Market core |
| --- | --- | --- | --- |
| Base | 8453 | `0x120dbCDd58Bb787309573e29159fE6D37A1983F6` | `0x55975E430Cc54C63dff03B1E6d27Be574Ce229F6` |
| Robinhood Chain | 4663 | `0x3712AFf63D6F0D094b0894f2e1ff4a2637265F04` | `0x114C446Ce246b6C5c432Eb001fBeB17864Fc1d34` |
| Base Sepolia | 84532 | `0xC40beFd6c9Ee9B6061056AEdF7173A4B652CD7a2` | `0x4d09719B66f97BE351cFf34be2477C72017cF9e0` |

The full address book, including hooks, factories, oracles, executors and the other testnets, is [`abi/addresses.json`](./abi/addresses.json) and ships with the `umia-abi` package. The Hub exposes the venture records (`ventureById`, `ventureLiquidityVault`) and the protocol pointers (`umiaMarketCore`, `conditionalMarketOracle`, `defaultGovernanceExecutor`, `lbpStrategyFactory`, `spotMigrator`); the hook, the lenses, the exit helper and the Uniswap infrastructure are only in the address book.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/). `foundry.toml` pins `solc 0.8.26`, which the Uniswap V4 and CCA dependencies require, and compiles with `via-ir`.

```bash
git submodule update --init --recursive   # dependencies live in lib/
forge build
forge test
forge test --match-path 'test/markets/*'   # one area: governance, launchpad, liquidation, markets, periphery, proxy, reclaim, vesting
```

Fork tests skip themselves unless an RPC is set: `FORK_RPC_URL` for `test/fork/` and `test/proxy/UpgradeRehearsal.t.sol`, `BASE_RPC_URL` for `test/periphery/YieldPositionGuardianFork.t.sol`. `forge fmt` before committing. `check-licenses.sh` enforces the licence map below, `check-contract-sizes.sh` the EIP-170 limit, and `.storage-layouts/` records the upgradeable contracts' storage so a new implementation can be checked against the live one. [docs/DEVELOPMENT.md](./docs/DEVELOPMENT.md) covers the rest.

## Source layout

| Path | Contents |
| --- | --- |
| `src/core/` | Hub, treasury and proxy, market core, market stake, governance executor, spot liquidity vaults (current and earlier), active liquidity manager |
| `src/launchpad/` | Launch strategies and factories (current and earlier) |
| `src/periphery/` | Spot hooks (current and earlier), conditional market oracle, spot migrator, validation hook and server permits, CCA exit helper, vesting authority, TWAP milestone condition, yield guardian, spot liquidity creation-code store; `libraries/` holds the validation hook's proof and schedule helpers |
| `src/libraries/` | CPMM math, market creation and settlement (external libraries linked into the core), governance types, validator and actions, oracle ring, tick slew, TWAP guard, active slices, spot liquidity deploy helper, calendar and ledger helpers |
| `src/liquidation/` | `SimpleLiquidator` |
| `src/reclaim/` | Vendored Reclaim Protocol zkTLS verifier |
| `src/tokens/` | `VentureToken` |
| `src/interfaces/` | Public interfaces |
| `script/` | Deployment, upgrade and salt-mining scripts; `testnet-utils/` holds testnet-only helpers |
| `test/` | Foundry suites by area; `test/fork/` holds fork tests |
| `abi/` | The `umia-abi` npm package |
| `docs/` | Protocol and contract reference |
| `certora/` | Formal verification specs |
| `licenses/` | Full licence texts |

## Scripts

Every script reads its inputs from environment variables listed in its header. Simulate with `forge script script/<File>.s.sol --rpc-url <rpc>`; add `--broadcast` to send.

| Script | Purpose |
| --- | --- |
| `Deploy.s.sol` | Full protocol deployment on a fresh chain: hub, market core, market stake, oracle, executor, hook and launch factory, CCA factory, validation infrastructure, venture beacon and the MetaVesT singletons; wires every Hub pointer |
| `DeployMetaVest.s.sol` | Per-chain MetaVesT vesting singletons and `UmiaTwapMilestoneCondition` ([deployment notes](./docs/metavest/README.md#deployment)) |
| `DeployOracleUpgrade.s.sol` | Dual-cadence oracle upgrade on a live chain: new `UmiaHook`, `UmiaLBPFactory` and `UmiaTwapMilestoneCondition` wired to the existing Hub; the factory flip stays with the Hub owner |
| `DeploySpotLiquidityV2.s.sol` | Stages the current spot liquidity contracts next to a live deployment: `UmiaHookV2`, `SpotLiquidityV2Code`, `UmiaLBPFactoryV2`, `SpotMigrator`, `ConditionalMarketOracle`; prints the Hub owner's batch without sending it |
| `DeployTimelock.s.sol` | Deploys an OpenZeppelin `TimelockController` and makes it the Hub owner, optionally the beacon owner too |
| `DeployYieldPositionGuardian.s.sol` | Deploys a `YieldPositionGuardian` for one venture |
| `MineUmiaHookSalt.s.sol` | Mines the CreateX salt that gives `UmiaHook`, or `UmiaHookV2` with `HOOK_V2=true`, an address carrying the required V4 permission bits |
| `SwapGovernanceExecutor.s.sol` | Deploys a new `GovernanceExecutor`, rehearses `setDefaultGovernanceExecutor` in a fork, then sends the swap or prints the owner's calldata |
| `UpgradeHub.s.sol`, `UpgradeMarketCore.s.sol`, `UpgradeVentureBeacon.s.sol` | `UpgradeBase.s.sol` for each upgradeable target: deploy the implementation, check it is a locked UUPS implementation, rehearse as the live owner, send or print the calldata |
| `ProtocolState.sol` | Helper, not a script: state digests compared before and after an upgrade, and the Hub lookup the upgrade scripts share (`UMIA_HUB_ADDRESS`, or a `contracts.json` address file one directory up) |
| `DeployTestnetToken.s.sol` | Testnet only: a mintable ERC-20 standing in for the money token |
| `DeployV4Infra.s.sol` | Local only: Uniswap V4 PoolManager, PositionManager, StateView, Universal Router and WETH for a fresh dev chain |
| `testnet-utils/` | Testnet only: open or settle a market atomically when bots have pushed spot off its TWAP |

`verify-fixed.sh` and `verify-runtime.sh` verify deployed contracts on Basescan with the remappings recorded in the artifact metadata. [docs/NEW_CHAIN_DEPLOYMENT.md](./docs/NEW_CHAIN_DEPLOYMENT.md) is the deploy order with the reads that prove each step; [docs/UPGRADES.md](./docs/UPGRADES.md) covers the upgrade paths.

## ABIs

`abi/` is the `umia-abi` npm package: typed `as const` ABIs generated from the build output, raw JSON per contract under `abi/json/`, and the address book. See [abi/README.md](./abi/README.md).

```ts
import { umiaHubAbi, umiaMarketCoreAbi, allErrorsAbi, getContractAddress } from "umia-abi";

const hub = getContractAddress("mainnet", 8453, "hub");
```

Events worth indexing first: `UmiaHub.VentureCreated`, `UmiaHub.SpotLiquidityVaultRegistered` and `SpotLiquidityVaultMigrated`, `UmiaMarketCore.MarketCreated`, `Swap`, `MarketSettled`, `WinningProposalExecuted`, and the hook's `PoolRegistered`.

## Documentation

| Document | Covers |
| --- | --- |
| [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) | Layers, core data flow, runtime interaction map |
| [docs/DECISION_MARKET_FLOW.md](./docs/DECISION_MARKET_FLOW.md) | Split and merge, trading, settlement and claims, with worked numbers |
| [docs/GOVERNANCE_TREASURY_LAYER.md](./docs/GOVERNANCE_TREASURY_LAYER.md) | Typed execution plans and every treasury action |
| [docs/LIQUIDATIONS.md](./docs/LIQUIDATIONS.md) | Building a correct liquidation plan |
| [docs/SPOT_ORACLE.md](./docs/SPOT_ORACLE.md) | Dual-cadence TWAP oracle, guards, cardinality, migration backfill |
| [docs/SECURITY.md](./docs/SECURITY.md) | Threat model, invariants, access control surfaces, review focus |
| [docs/UPGRADES.md](./docs/UPGRADES.md) | Upgrade paths and storage layout |
| [docs/NEW_CHAIN_DEPLOYMENT.md](./docs/NEW_CHAIN_DEPLOYMENT.md) | Deploying the protocol to a new chain |
| [docs/DEVELOPMENT.md](./docs/DEVELOPMENT.md) | Building, testing and the check scripts |
| [docs/contracts/README.md](./docs/contracts/README.md) | Per-contract reference index |
| [docs/metavest/README.md](./docs/metavest/README.md) | MetaVesT vesting integration and singleton deployment |
| [docs/analysis/conditional-oracle-damping/README.md](./docs/analysis/conditional-oracle-damping/README.md) | The backtest behind the conditional oracle's slew rate |
| [certora/README.md](./certora/README.md) | Formal verification specs and their current gaps |

## Licence

Contracts are licensed per file; the SPDX identifier on line 1 of each source file is the source of truth. Full texts are in [`licenses/`](./licenses/).

| Surface | Licence | Files |
| --- | --- | --- |
| Mechanism | BUSL-1.1 | Markets, settlement, governance, launchpad, hooks and vaults: everything under `src/` not listed below |
| Integration | MIT | `src/interfaces/**`, `VentureProxy`, `VentureToken`, `GovernanceTypes`, `MarketCoreTypes`, `SpotMarketOracle`, `TickSlew`, `PositionAmounts`, `TwapMath`, `CalendarLib` |
| Vendored | MIT | `src/reclaim/**` (Reclaim Protocol) |
| ABIs | MIT | `abi/` |

BUSL-1.1 permits all non-production use (development, testing, testnet deployment, security research, audits). Its Additional Use Grant also permits production use, except deploying the contracts, or work derived from them, to a public blockchain as or as part of a protocol, product or service that provides decision markets or futarchy-based governance, or tokenized venture funding or onchain venture treasury management; that exclusion does not apply to the Licensor's canonical deployment. On the Change Date, 2030-08-11, the licence converts to MIT. The exact parameters are in [`licenses/BUSL_LICENSE`](./licenses/BUSL_LICENSE). MetaVesT is AGPL-3.0, so `src/` declares minimal local interfaces instead of importing it.
