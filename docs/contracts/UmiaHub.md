# UmiaHub

Source: `src/core/UmiaHub.sol`

## Purpose

Central registry and factory for ventures.

- Deploys `Venture` (beacon proxy) + `VentureToken` + launch strategy (`UmiaLBP` or `UmiaLBPV2`, from `lbpStrategyFactory`) during `createVenture`; `createVentureWithToken` takes a pre-deployed `VentureToken` owned by the Hub.
- Stores protocol pointer addresses used by other contracts.
- Stores venture metadata (`VentureInfo`) and approved money tokens.

## Key state

- `ventureCount`, `_ventureById`
- `approvedMoneyTokens`
- configurable pointers:
  - `umiaMarketCore`
  - `defaultGovernanceExecutor`
  - `governanceExecutorByVenture`
  - `conditionalMarketOracle`
  - `marketCreationSigner`
  - `lbpStrategyFactory`, `ccaFactory`, `ventureBeacon`, `umiaMarketStake`
  - `spotMigrator`: the only caller of `migrateSpotLiquidityVault`
  - `activeLiquidityKeeper`: default keeper for every venture's `ActiveLiquidityManager`
  - `vetoGuardian`: may trip (not reset) a market's circuit breaker; `vestingAdmin`: may terminate and reissue vesting grants
- `ventureLiquidityVault(venture)`: the venture's spot vault, trusted by MarketCore, liquidation and the vesting TWAP condition
- `ventureVestingAuthority(ventureId)`: the `VentureVestingAuthority` that owns the venture's vesting grants, the only onchain link from a venture to its grants (MetaVesT adapters are deployed permissionlessly)
- `winningMarketThresholdBps` (default 200), `decisionMarketExecutionDelay` (default 4 hours, max 12)
- fee parameters: `protocolFeeRecipient`, `spotSwapFeeBps` (default 100, max 1000), `spotProtocolFeeCutBps`, `decisionSwapFeeBps`, `decisionProtocolFeeCutBps` (cuts default 5000)
- pool and launch timing: `defaultPoolTickSpacing` (default 60), `migrationDelayBlocks`, `sweepDelayBlocks`
- V2 launch split: `launchAnchorBps` (share of a launch's pool-bound liquidity that bootstraps the anchor vault, the rest funds the ALM; at least 50%) and `launchActiveHalfWidthTicks` (half width of the one range the launch opens for the ALM around the clearing tick; a multiple of the tick spacing, at most half the ALM's default `maxWidthTicks`). Both start at zero, and `UmiaLBPV2.migrate` reverts `LaunchSplitUnset` until the owner sets them. Changing `defaultPoolTickSpacing` clears the half width when it no longer divides the new spacing or exceeds the ALM's default maximum, so a stale width can never reach a launch.
- `decisionMarketCircuitBreakerActive[marketId]`

## Important functions

- `createVenture(CreateVentureParams)`, `createVentureWithToken(CreateVentureWithTokenParams)`
- `setUmiaMarketCore`, `setDefaultGovernanceExecutor`, `setVentureGovernanceExecutor`
- `setConditionalMarketOracle`, `setMarketCreationSigner`
- `setApprovedMoneyToken`, `setLbpStrategyFactory`, `setCcaFactory`, `setVentureBeacon`, `setUmiaMarketStake`
- `setVentureMinMarketStake`
- fee and timing setters: `setProtocolFeeRecipient`, `setSpotSwapFeeBps`, `setSpotProtocolFeeCutBps`, `setDecisionSwapFeeBps`, `setDecisionProtocolFeeCutBps`, `setWinningMarketThresholdBps`, `setDecisionMarketExecutionDelay`, `setDefaultPoolTickSpacing`, `setLaunchAnchorBps`, `setLaunchActiveHalfWidthTicks`, `setMigrationDelayBlocks`, `setSweepDelayBlocks`
- `setVetoGuardian`, `tripDecisionMarketCircuitBreaker` (owner or `vetoGuardian`), `resetDecisionMarketCircuitBreaker`, `setVestingAdmin`
- `setVentureVestingAuthority(ventureId, authority)` (`onlyOwner`): records the venture's adapter, or clears it with `address(0)`. A nonzero adapter must serve this Hub and, once bound, this venture's treasury, else `InvalidVestingAuthority`. Emits `VentureVestingAuthoritySet`
- `governanceExecutor(venture)` (venture override or default)
- `registerSpotLiquidityVault(venture, vault)`: one-shot, the venture's LBP only
- `migrateSpotLiquidityVault(venture, newVault)`: `spotMigrator` only. Moves the vault pointer once no decision market holds the old vault's liquidity; the new vault must be a different, initialized vault that names this venture and this Hub, the same binding check registration applies. See [SpotMigrator](./SpotMigrator.md).
- `setSpotMigrator`, `setActiveLiquidityKeeper` (`onlyOwner`)

## Access control

- All registry setters are `onlyOwner`, including `setVentureGovernanceExecutor` and `setVentureMinMarketStake`. `setUmiaMarketCore` and `setConditionalMarketOracle` also require no unsettled markets (`withNoActiveMarkets`).
- `registerSpotLiquidityVault`: the venture's LBP. `migrateSpotLiquidityVault`: `spotMigrator`. `tripDecisionMarketCircuitBreaker`: owner or `vetoGuardian`.

## Notes

- venture creation requires:
  - approved money token,
  - non-zero market core, LBP strategy factory, CCA factory and venture beacon,
  - initial supply within `MIN_INITIAL_SUPPLY` (100e18) and `MAX_INITIAL_SUPPLY` (1e12 * 1e18).
