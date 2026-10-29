# UmiaHookV2

Source: `src/periphery/UmiaHookV2.sol`

## Purpose

Singleton Uniswap V4 hook for V2 spot pools, introduced with the V2 spot liquidity release. Same permission bits (`0x3A80`), oracle rings and read surface as `UmiaHook`, so `SpotLiquidityVault*` and `UmiaTwapMilestoneCondition` call it through `IUmiaHook` unchanged. Two additions:

- **Two liquidity operators per pool.** `anchorOperator` (the venture's `SpotLiquidityVaultV2`) may only hold full-range liquidity and is the only decision-market source. `activeOperator` (the venture's `ActiveLiquidityManager`) may hold any range; zero means none. Both are fixed at registration (`InvalidOperator` if the anchor is zero or equals the active operator), which only factory LBPs and the migrator can do, so no other address ever gets any-range liquidity rights.
- **Oracle backfill on migration.** A pool migrated from an earlier hook starts its coarse ring with the predecessor's last 30 days, sampled every 6 hours. Existing 30-day vesting TWAPs keep working across a migration, and reads never consult the predecessor afterwards.

## Key state

- `INITIAL_OWNER` (immutable), `poolManager`, `factory` (`UmiaLBPFactoryV2`), `hub`
- `pools[id]`: `PoolConfig {launcher, venture, anchorOperator, activeOperator}`
- per-pool fine and coarse rings, identical to `UmiaHook`

## Important functions

- `initialize(factory, poolManager, hub)`: one-shot, `INITIAL_OWNER` only.
- `registerPool(key, cfg)`: factory-deployed LBPs (`factory.isLBP`).
- `registerMigratedPool(key, cfg, predecessorKey)`: `hub.spotMigrator()` only. Checks the predecessor is the pool of the venture's Hub-registered vault, is registered to the same venture on its own hook, trades the same pair and has a seeded coarse ring (else `InvalidPredecessor`), then backfills this pool's coarse ring from it.
- `observe`, `observeLong`, `getObservation`, `getCoarseObservation`, `oracleStates`, `coarseOracleStates`, `increaseCardinalityNext`, `increaseCoarseCardinalityNext`, `COARSE_INTERVAL`: as `UmiaHook`.
- `BACKFILL_SPACING` (6 hours), `BACKFILL_STEPS` (121), `BACKFILL_RESERVE` (721 coarse slots reserved past the backfill, not pre-written).

## Liquidity gating

| Caller | Add | Remove |
| --- | --- | --- |
| `anchorOperator` | full range only (`OnlyFullRangePositions`) | yes |
| `activeOperator` | any range the PoolManager accepts | yes |
| anyone else | `UnauthorizedLiquidityOperator` | allowed, but V4 keys positions by owner so there is nothing to remove |

Removals are not gated so a replaced active operator can always unwind.

## Oracle backfill

See [SPOT_ORACLE.md, Migration backfill](../SPOT_ORACLE.md#migration-backfill). `registerMigratedPool` reads the predecessor's `observeLong` every 6 hours back 30 days plus 6 hours (or to its oldest coarse observation) inside the migration transaction and writes the results into this pool's coarse ring, rebased to zero at the handover. `afterInitialize` seeds the coarse ring only while it is empty, so the backfill survives pool initialization. Reads are `UmiaHook`'s. `observe` (per-block) is not backfilled. The migration reserves `BACKFILL_RESERVE` coarse slots past the backfill, so the 30-day read keeps serving with no keeper growth.

## Events

`Initialized`, `PoolRegistered(id, anchorOperator, config)`, `PoolPredecessorSet(id, predecessorHook, predecessorId, backfillStart, observations)`.

## Notes

- `PoolConfig` has four fields, so `PoolRegistered` has a different signature from V1; consumers decoding hook events must register `UmiaHookV2` separately.
- Concentrated active liquidity sits on top of the anchor's full-range position, so no tick ever has zero liquidity while the anchor is funded. That is the property the V1 full-range rule protected; see SPOT_ORACLE.md.
- Deploy via CreateX with a salt mined by `HOOK_V2=true script/MineUmiaHookSalt.s.sol`.
