# SpotLiquidityVaultV2

Source: `src/core/SpotLiquidityVaultV2.sol`, `src/interfaces/ISpotLiquidityVaultV2.sol`

## Purpose

A venture's anchor liquidity in its `UmiaHookV2` pool: one full-range position, the only source of decision-market liquidity. A copy of `SpotLiquidityVault` (left untouched so its deployed bytecode keeps matching the repo) with three differences:

- `bootstrapFromLBP` is gated to the immutable `bootstrapper`: the `UmiaLBPV2` for fresh launches, `SpotMigrator` for migrated pools.
- `activeManager()` returns the pool's `activeOperator`, read from the hook. It is fixed at registration.
- The sandwich guard is two-window (`SpotTwapGuard.withinBands`): spot within `MAX_TICK_DEVIATION` (1000 ticks) of the 30-minute TWAP, as in V1, and within `MAX_LONG_TICK_DEVIATION` (2000 ticks, roughly 22%) of the 6-hour TWAP of the coarse ring (`LONG_TWAP_WINDOW`). Both windows fail closed with `InsufficientOracleHistory`.

Everything else is unchanged: share accounting, `deposit` / `withdraw`, `pullForDecisionMarket` / `returnFromDecisionMarket` (MarketCore only), fee crystallization and protocol cut, and the 100-slot ring seeding at bootstrap. MarketCore and `UmiaTwapMilestoneCondition` read it through `ISpotLiquidityVault`; MarketCore also snapshots `activeManager()` per market (`ISpotLiquidityVaultV2`), and the liquidation action unwinds the ALM through the same getter.

## Notes

- `_addIdleAsLiquidity` keeps one wei of headroom per token, because the pool rounds owed amounts up.
- The 30-minute guard reads the pool's own per-block ring, so after a migration deposits, withdrawals and new decision markets wait 30 minutes for the new pool's history. The 6-hour window is served at once from the coarse ring the migration backfilled.
- Known and accepted: like V1, the protocol cut is transferred to `hub.protocolFeeRecipient()` on every fee crystallization (deposit, withdraw, decision-market pull and return). A recipient that rejects transfers (for example a blacklisted address) blocks settlement, market creation, LP exits and liquidation until the timelock sets a new recipient. The ALM accrues its cut for a later claim instead. Switching the vault to accrue-and-claim is a contained change if this ever matters; the recipient is the protocol Safe.
