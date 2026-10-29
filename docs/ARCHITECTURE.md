# Umia Smart Contracts Architecture

This document describes the current Solidity code under `smart-contracts/src`.
It is intentionally code-first and references concrete contracts in this repository.

## High-level Components

- **Hub / registry layer**
  - `src/core/UmiaHub.sol`
  - Creates ventures and stores canonical protocol addresses (market core, oracle, governance executor, LBP factory, market stake, each venture's spot vault, spot migrator, ALM keeper) plus fee and timing parameters.

- **venture treasury layer**
  - `src/core/Venture.sol`
  - Holds treasury assets and the venture's spot vault shares (minted to it at LBP migration), and is the target of governance execution.

- **Decision market layer**
  - `src/core/UmiaMarketCore.sol`
  - Runs market lifecycle, split/merge accounting, virtual token balances (ERC6909), CPMM state, settlement, and winning proposal execution.

- **Governance execution layer**
  - `src/core/GovernanceExecutor.sol`
  - Decodes typed action plans via `GovernancePayloadValidator` and dispatches actions into `Venture` via `GovernanceActions`.
  - Shared types in `src/libraries/GovernanceTypes.sol`.

- **Periphery layer**
  - `src/periphery/ConditionalMarketOracle.sol` for per-proposal TWAP tracking.
  - `src/periphery/UmiaValidationHook.sol` for auction-time validation hooks (one per gated CCA, wired in at auction creation).

- **Launchpad layer**
  - `src/launchpad/UmiaLBPFactory.sol` and `src/launchpad/UmiaLBP.sol`
  - Launch flow for venture token distribution, migration to Uniswap v4, and LP registration callback.
  - `src/launchpad/UmiaLBPFactoryV2.sol` and `src/launchpad/UmiaLBPV2.sol`: the same flow landing on V2 spot liquidity.

- **Spot liquidity layer**
  - V1 (mainnet today): `src/core/SpotLiquidityVault.sol` holds the canonical full-range position; `src/periphery/UmiaHook.sol` is the oracle-only hook.
  - V2: `src/core/SpotLiquidityVaultV2.sol` (anchor), `src/core/ActiveLiquidityManager.sol` (keeper-managed concentrated liquidity), `src/periphery/UmiaHookV2.sol`, `src/periphery/SpotMigrator.sol` (V1 to V2 move), `src/libraries/SpotTwapGuard.sol` (two-window sandwich guard). See [SPOT_ORACLE.md](./SPOT_ORACLE.md).

- **Incentive / vesting layer**
  - `src/periphery/UmiaTwapMilestoneCondition.sol`: stateless, shared MetaVesT condition singleton (one per chain) that gates a vesting milestone on the spot pool TWAP. It holds no per-allocation state, no auth, and no events: at check time it resolves the milestone's threshold off the allocation's adapter (`allocation → controller → authority → effectiveThreshold`) and compares the venture's full-window TWAP.
  - `src/periphery/VentureVestingAuthority.sol`: per-venture adapter that holds the MetaVesT controller's `authority` role and routes it to the venture treasury (so futarchy creates/amends/terminates grants post-launch; the Hub's `vestingAdmin` may also terminate and reissue unless the venture revokes it via `setVestingAdminRevoked`), and is also the per-allocation price-ladder registry: a grant's ladder is written here atomically with `createMetavest`. Absolute thresholds are stored; relative thresholds are resolved live as `multiple × clearingPrice`, so there is no separate ladder-registration or finalize step. `UmiaHub.ventureVestingAuthority(ventureId)` records which adapter owns a venture's grants.
  - Vesting itself runs through MetaVesT, imported as a git submodule at `lib/metavest`.

- **Token layer**
  - `src/tokens/VentureToken.sol` (ERC20Pausable; mint/burn/pause/unpause controlled by Venture owner).

## Core Data Flow

### 1) venture creation and launch

1. `UmiaHub.createVenture(...)` deploys:
   - `Venture`
   - `VentureToken`
   - LBP contract via `lbpStrategyFactory` (`IDistributorFactory.create`; `UmiaLBPFactory` or `UmiaLBPFactoryV2`).
2. Hub mints total token supply to itself, transfers token ownership to `Venture`, and sends supply to LBP. `createVentureWithToken` does the same with a pre-deployed `VentureToken` owned by the Hub.
3. LBP runs auction and eventually migrates liquidity to Uniswap v4.
4. On V1, `UmiaLBP.migrate()` deploys the venture's `SpotLiquidityVault` on `UmiaHook`, registers it on the hub
   (`registerSpotLiquidityVault`), and hands the raised liquidity to the vault, which holds the
   canonical full-range spot position.
5. `migrate()` (V1 and V2) then notifies the treasury via `ILBPMigrationCallback.onLBPMigrated()`, which
   only applies the optional post-migration trading pause.

With `UmiaLBPFactoryV2` selected, `UmiaLBPV2.migrate()` replaces step 4: it lands the venture on
`UmiaHookV2`, deploying and registering a `SpotLiquidityVaultV2` (the full-range anchor, the only decision-market source) plus an empty
`ActiveLiquidityManager` for keeper-managed concentrated liquidity. Ventures already on V1 move with
one proposal through `SpotMigrator`; the Hub's vault pointer follows, so MarketCore, the liquidation
action's vault redemption and the vesting TWAP condition need no contract change. Anyone can redeem
the ALM's basket leftovers (`claimDecisionMarket`, once per market) after it settles and before
its winning proposal executes, and `LIQUIDATE_TREASURY` (in the GovernanceExecutor shipped with V2) empties the ALM
before the claim snapshot; a liquidation plan built for an older executor adds an explicit
`alm.withdrawAll()` call first. See [LIQUIDATIONS.md](./LIQUIDATIONS.md) and
[contracts/SpotMigrator.md](./contracts/SpotMigrator.md).

### 2) Market creation and trading

1. Market creator deposits per-venture stake: `UmiaMarketStake.depositMarketStake(ventureId)`.
2. `createMarket(...)` requires:
   - caller is `creator` or the Hub owner,
   - signature by `UmiaHub.marketCreationSigner()` (EIP-712),
   - valid nonce (`marketCreationNonces[creator]`),
   - when `UmiaMarketStake` is configured, a valid stake deposit (locked via `UmiaMarketStake.verifyAndLockStake`),
   - no other unsettled market for the venture,
   - start time at/before now clamps to `block.timestamp` (open immediately); must be ≤ `TRADING_MAX_START_DELAY` (7 days),
   - duration in `[TRADING_MIN_DURATION, TRADING_MAX_DURATION]` (1h–96h; `0` → default 3 days),
   - proposal count in `[1, 5]` (plus auto no-op proposal).
3. On market creation, the market core pulls 50% (`BOOTSTRAP_PULL_BPS`) of the venture's spot vault liquidity (`pullForDecisionMarket`) and initializes one CPMM per proposal.
4. During `OPEN` phase, users:
   - `split` real venture/money into virtual tokens across all proposals,
   - trade virtual tokens through the core's swap entrypoints (called directly or via an EIP-712 permit),
   - optionally `merge` equal virtual balances back into real tokens.

### 3) Settlement and execution

1. After `tradingEnd`, anyone calls `settleMarket(marketId)`.
2. The market core updates the oracle and computes proposal TWAPs.
3. Winner logic:
   - highest TWAP vs no-op TWAP,
   - must exceed `UmiaHub.winningMarketThresholdBps()` (default 200 bps) unless no-op remains winner.
4. The market core reserves claimable backing for winning-proposal virtual supply, records `settledAt`, and returns the excess to the spot vault (`returnFromDecisionMarket`), which re-adds it under its TWAP guard.
5. Users call `claimSettlement` to redeem winning-proposal virtual balances 1:1 in real assets; anyone can call `claimSettlementFor` to redeem them to their holders.
6. Anyone calls `executeWinningProposal` once `executionDelay` (`UmiaHub.decisionMarketExecutionDelay`, default 4 hours, max 12) has passed since settlement and the market's circuit breaker is not tripped:
   - no-op or empty payload => mark executed,
   - otherwise route to configured `GovernanceExecutor` for that venture.

## Governance Payload Path

1. Proposal stores `executionPayload` bytes in `UmiaMarketCore.Proposal`.
2. `executeWinningProposal` resolves executor from `UmiaHub.governanceExecutor(venture)`.
3. `GovernanceExecutor.executeProposal(...)` enforces:
   - caller must be the current UmiaMarketCore,
   - this executor must match hub config for venture,
   - payload non-empty,
   - venture not already in liquidation.
4. Payload is decoded as `GovernanceTypes.ExecutionPlanV1`.
5. Each action is validated/executed via `GovernanceActions.executeActionV1`.
6. `LIQUIDATE_TREASURY` must be final action in plan.

## Contract Interaction Map (runtime)

- `UmiaHub` configures/points to:
  - `UmiaMarketCore`
  - default/per-venture `GovernanceExecutor`
  - `ConditionalMarketOracle`
  - `UmiaLBPFactory` / `UmiaLBPFactoryV2` (`lbpStrategyFactory`)
  - `UmiaMarketStake`
  - each venture's spot vault (`ventureLiquidityVault`), `SpotMigrator`, `activeLiquidityKeeper`
- `UmiaMarketCore` depends on:
  - `UmiaHub` registry
  - `Venture` for token addresses
  - the venture's spot vault (`hub.ventureLiquidityVault`) for seed liquidity pull and return, and its `activeManager()` (V2) for the fee-exempt basket trader
  - `ConditionalMarketOracle` for price history
  - `GovernanceExecutor` for payload execution
- `Venture` authorizes:
  - hub,
  - current `UmiaMarketCore`,
  - current governance executor (for selected functions)

## Storage and State Ownership

- **Registry state**: `UmiaHub`
- **Treasury + governance state**: `Venture`
- **Market and virtual token state**: `UmiaMarketCore`
- **Oracle cumulative state**: `ConditionalMarketOracle`
- **Spot liquidity state**: `SpotLiquidityVault` / `SpotLiquidityVaultV2` (shares, deployments), `ActiveLiquidityManager` (positions, owed protocol cut); spot oracle rings in `UmiaHook` / `UmiaHookV2`
- **Swap permit nonce state**: `UmiaMarketCore`

## Existing docs to pair with this

- `DECISION_MARKET_FLOW.md` (detailed split/merge and settlement walkthrough)
- `GOVERNANCE_TREASURY_LAYER.md` (typed action model)
- `UPGRADES.md` (upgrade strategy notes)
