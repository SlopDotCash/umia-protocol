# UmiaLBPV2 / UmiaLBPFactoryV2

Source: `src/launchpad/UmiaLBPV2.sol`, `src/launchpad/UmiaLBPFactoryV2.sol`

## Purpose

New launches straight onto V2 spot liquidity, no migration involved. Copies of `UmiaLBP` and `UmiaLBPFactory` (both left untouched). `UmiaLBPV2.migrate` differs only in steps 8, 9 and 11:

- deploys an `ActiveLiquidityManager(bootstrapper = this)` and a `SpotLiquidityVaultV2(bootstrapper = this)` through `SpotLiquidityV2Deploy`; the ALM is found through the vault (`activeManager()`), not the Hub;
- `hub.registerSpotLiquidityVault(venture, vault)`;
- registers the pool on `UmiaHookV2` with `anchorOperator = vault`, `activeOperator = alm`;
- splits the pool-bound tokens and currency by `hub.launchAnchorBps()`: the vault bootstraps with its share, the ALM receives the rest and is seeded with one range of `hub.launchActiveHalfWidthTicks()` on each side of the clearing tick (`ActiveSlices`). Reverts `LaunchSplitUnset` while the Hub has not set both; a 100% anchor share leaves the ALM empty.

The ALM cannot rebalance until the new pool has 12 hours of oracle history, so the launch range is its whole book for that time; the venture can add to or withdraw from the ALM later by proposal, and its keeper takes over once the guards can read the TWAPs.

## Factory

`UmiaLBPFactoryV2(poolManager, hookV2, hub, code)` writes the `UmiaLBPV2` creation code and reads the vault and ALM code pointers from `SpotLiquidityV2Code`, shared with `SpotMigrator`. One deployer embedding all three codes would land at about 49 KB, past the EIP-3860 initcode limit.

## Rollout

The V2 spot liquidity release, on a chain that already runs the protocol:

1. `script/DeploySpotLiquidityV2.s.sol`: `UmiaHookV2`, `SpotLiquidityV2Code`, `UmiaLBPFactoryV2`, `hookV2.initialize(factoryV2, poolManager, hub)`, `SpotMigrator`, `ConditionalMarketOracle`.
2. Hub owner, in order: `hub.upgradeToAndCall(newHubImpl, "")` and `marketCore.upgradeToAndCall(newCoreImpl, "")`, `setConditionalMarketOracle(oracle)`, `setDefaultGovernanceExecutor(new GovernanceExecutor(hub))` (the new executor's `LIQUIDATE_TREASURY` empties the ALM), `setSpotMigrator(migrator)`, `setActiveLiquidityKeeper(keeper)`, `setLaunchAnchorBps(7500)`, `setLaunchActiveHalfWidthTicks(10980)`.
3. Point off-chain consumers (the keeper, anything indexing pools) at the new addresses.
4. Hub owner: `setLbpStrategyFactory(factoryV2)`.

In-flight LBPs from the old factory keep their immutable hook and graduate onto V1. The full order, with the per-venture migration proposal, is in [UPGRADES.md](../UPGRADES.md#v2-spot-liquidity-release).
