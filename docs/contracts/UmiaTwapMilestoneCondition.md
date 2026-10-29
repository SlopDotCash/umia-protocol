# UmiaTwapMilestoneCondition

Source: `src/periphery/UmiaTwapMilestoneCondition.sol`

## Purpose

A shared, singleton [MetaVesT](../metavest/README.md) condition (`IConditionM`) that gates a vesting milestone on the Venture's spot-pool TWAP. A milestone confirms only once the full-window TWAP reaches the milestone's price threshold **and** the milestone's optional time cliff has elapsed (a cliff of `0` means price-only). One instance is deployed per chain and serves every Venture; it holds no per-allocation state. Threshold and cliff live on the Venture's [`VentureVestingAuthority`](./VentureVestingAuthority.md) (written atomically with the grant), and this contract resolves them at check time.

Pre-minted tokens are held and released by a MetaVesT allocation (linear vesting, cliffs, milestones); this contract supplies only the price-milestone gate.

## Key design choices

- **Stateless singleton**: deployed once per chain (see [deployment](../NEW_CHAIN_DEPLOYMENT.md)). It stores nothing per allocation, emits no events, and has no owner or auth. There is no registration step on the condition: the price ladder is written on the venture's adapter in the same transaction as the grant (see [`VentureVestingAuthority`](./VentureVestingAuthority.md)).
- **No AGPL linkage in the deployed contract**: MetaVesT is AGPL-3.0; the condition reads the calling allocation through a minimal local `IMetaVesTAllocation` interface (`getMetavestDetails()`, `controller()`), so the singleton itself carries no MetaVesT import. Only the end-to-end tests link the MetaVesT engine.
- **Threshold resolved off the adapter**: the condition is keyed by the calling allocation address and resolves its threshold by walking `allocation → controller → authority → effectiveThreshold`. The adapter is the canonical registry; the condition is a thin price comparator over it. This keeps the ladder and the grant on a single mutating path and a single auth gate (the adapter), with no cross-allocation collision to guard against here.
- **Fail-closed TWAP**: the price read reverts before the Venture's pool exists (`NoLpToken`) and when the oracle cannot serve the full window (`OracleNotReady`); it never degrades to a shorter window.

## Key state

- `TWAP_WINDOW`: immutable, singleton-wide observation window (seconds). Set in the constructor; a zero window reverts `InvalidTwapWindow`. This is the only stored value; there is no per-allocation state.

## Important functions

- `checkCondition(allocation, sig, data)`: the MetaVesT entrypoint, invoked from `confirmMilestone`. Decodes the milestone index from `data` (`abi.encode(uint256)`), resolves the threshold and cliff from the calling allocation's adapter (`allocation → controller → authority → effectiveThreshold / effectiveCliff`), reads the venture's full-window TWAP (Q96, moneyToken per ventureToken), and returns whether `TWAP >= threshold`. An unelapsed cliff (`cliff != 0 && block.timestamp < cliff`) returns `false` before the TWAP read, so a cliffed milestone answers `false`: not a fail-closed revert , even before the pool exists. The threshold is resolved first, so an unregistered or not-yet-cleared milestone surfaces the adapter's revert (`NotRegistered` / `NotBound` / `AuctionNotCleared`) rather than the fail-closed TWAP error.
- `TWAP_WINDOW()`: the immutable observation window.

## Threshold resolution

The threshold is never stored on the condition. For a milestone index `idx` on `allocation`, the condition reads the allocation's MetaVesT `controller()`, then that controller's current `authority` (the venture's `VentureVestingAuthority`), and calls `effectiveThreshold(allocation, idx)` on it. For an **absolute** ladder the adapter returns the stored Q96 threshold; for a **relative** ladder it returns `multiple × clearingPrice / 1e6`, computed live at read time against the venture's auction clearing price. Relative thresholds are therefore always current; there is no anchoring or finalize step. The milestone's optional cliff is read the same way via `effectiveCliff(allocation, idx)`: a stored unix timestamp (`0` = no cliff), identical for absolute and relative ladders. See [`VentureVestingAuthority`](./VentureVestingAuthority.md).

## TWAP resolution

`_getTwapPriceX96(token)` resolves the Venture via `Ownable(token).owner()` (the ownership invariant enforced in `Venture`), then the Venture's spot vault via `IUmiaHub(venture.HUB()).ventureLiquidityVault(venture)` (reverting `NoLpToken` when unset). The pool and its hook come from `vault.getPoolKey()` and `vault.hook()`. When `TWAP_WINDOW >= 2 * hook.COARSE_INTERVAL()` (one hour on both hooks), the read is `hook.observeLong(key, [TWAP_WINDOW, 0])` against the coarse ring; shorter windows use `hook.observe`. A failing read reverts `OracleNotReady`. The result is a geometric-mean TWAP over the full window, as Q96 moneyToken per ventureToken with token ordering handled automatically. A price past the `uint160` ceiling (or a non-inverted price that floored to 0) is capped at `type(uint160).max` rather than truncated or divided by zero. After a V2 spot migration the Hub pointer moves to the venture's `SpotLiquidityVaultV2` (`UmiaHub.migrateSpotLiquidityVault`), so the same read lands on the `UmiaHookV2` pool, whose coarse ring `registerMigratedPool` backfilled from the predecessor pool. See [Spot Oracle](../SPOT_ORACLE.md).

## Integration with MetaVesT

A milestone gates on this condition by listing the singleton's address in its `conditionContracts`. When anyone calls `confirmMilestone(idx)` on the allocation, MetaVesT calls `checkCondition(address(this), msg.sig, abi.encode(idx))`; a `false` return (or a fail-closed revert) blocks completion. The milestone's threshold is whatever the allocation's adapter resolves for `idx` at that moment. See [the MetaVesT integration doc](../metavest/README.md).

> **⚠️ The binding is positional.** Adding or removing a milestone on a price-gated grant re-indexes MetaVesT's milestone array but not the adapter's ladder, so an award can end up gated by another milestone's threshold. Restructure such grants with `terminateAndReissue` only; see [`VentureVestingAuthority`](./VentureVestingAuthority.md#never-add-or-remove-milestones-on-a-price-program-grant).

## Notes

- The condition holds no state and emits no events, so it is not indexed; allocations and price-gated milestones are discovered from the adapter's `AllocationFunded` / `PriceProgramRegistered` events.
- MetaVesT invokes `checkCondition` by raw selector, so the singleton implements no ERC-165 interface-detection surface.
