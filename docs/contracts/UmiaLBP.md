# UmiaLBP

Source: `src/launchpad/UmiaLBP.sol`

## Purpose

Custom launch strategy integrating auction distribution with venture treasury migration. This is the V1 strategy used by the live deployment; new launches use [`UmiaLBPV2`](./UmiaLBPV2.md).

- Creates initializer/auction on token receipt.
- Sweeps auction proceeds.
- Splits raised currency to venture share and LP migration share.
- Deploys the venture's `SpotLiquidityVault`, registers it with the Hub and the pool with the singleton `UmiaHook`, initializes the Uniswap v4 pool and hands the LP share to the vault (`bootstrapFromLBP`). No LP NFT: the vault holds the position.

## Key immutables and config

- venture config: `venture`, `ventureBps` (at most `MAX_BPS = 9_999`)
- token/currency config: `token`, `currency`, `totalSupply`, `tokenSplitToAuction` (of `TOKEN_SPLIT_DENOMINATOR = 10_000_000`), `reserveTokenAmount`
- pool config: read from the Hub at migration, `hub.spotSwapFeeBps() * 100` (pips) and `hub.defaultPoolTickSpacing()`
- timing config: read from the Hub, `migrationDelayBlocks` after the auction's `endBlock` and `sweepDelayBlocks` after `migratedAtBlock`
- dependencies: `poolManager`, `umiaHook`, `hub` (resolved from `venture.HUB()`), `vaultCreationCodePointer` (SSTORE2 pointer written by the factory)

## Important functions

- `onTokensReceived()`
- `migrate()`
- `sweepToken()` / `sweepCurrency()` (after `migratedAtBlock + hub.sweepDelayBlocks()`)
- fee path: none on the LBP. Swap fees accrue inside the vault's full-range position and are crystallized by `SpotLiquidityVault`.

## Full-range liquidity enforcement

The hook only allows full-range liquidity positions on the spot pool. Any attempt to add concentrated liquidity (tick range narrower than the full usable range) reverts with `OnlyFullRangePositions`.

This is enforced in `beforeAddLiquidity`:

```solidity
if (
    params.tickLower != TickMath.minUsableTick(key.tickSpacing)
        || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
) {
    revert OnlyFullRangePositions();
}
```

**Reason**: the spot pool's TWAP oracle uses an elapsed-time, slew-limited tick design that assumes liquidity exists at every tick level. Concentrated liquidity creates zero-liquidity gaps where moving the tick costs nothing, making the slew limit ineffective: an attacker could push the price through empty ranges with minimal capital. Full-range positions guarantee uniform liquidity depth across all ticks.

**Position modification**: Uniswap V4 positions have immutable tick ranges. To change a position's range, a user must remove the old position and add a new one. `beforeRemoveLiquidity` is enabled too, but it only checks the sender and records an observation; it does not inspect tick ranges. The enforcement in `beforeAddLiquidity` is sufficient to guarantee that only full-range positions exist on the pool. Both callbacks also restrict the sender to the registered `operator` (the venture's vault), reverting `UnauthorizedLiquidityOperator` otherwise.

## Notes

- Constructor rejects a zero `venture`, `ventureBps > MAX_BPS`, `tokenSplitToAuction >= TOKEN_SPLIT_DENOMINATOR` and a zero auction supply.
- `migrate()` calls `ILBPMigrationCallback(venture).onLBPMigrated()` (no arguments; there is no LP NFT).
- Hook permissions: `beforeInitialize`, `afterInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`. `afterSwap` is off; the hook takes no swap fee.
