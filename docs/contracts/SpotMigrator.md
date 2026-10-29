# SpotMigrator

Source: `src/periphery/SpotMigrator.sol`, `src/periphery/SpotLiquidityV2Code.sol`, `src/libraries/SpotLiquidityV2Deploy.sol`

## Purpose

Moves one venture's spot liquidity from its V1 pool to a new `UmiaHookV2` pool in a single passed decision-market proposal. Both actions run in one transaction, so any revert leaves V1 intact and the proposal retryable.

```text
1. CALL oldVault.withdraw(venture's shares, 0, 0, migrator)
2. CALL migrator.migrate(MigrateParams{anchorBps, activeSlices[]})
```

The migrator deploys the V2 vault and ALM itself from `SpotLiquidityV2Code` and never accepts their addresses: the Hub pointer it moves is what MarketCore and the vesting condition trust.

It migrates pools from one `sourceHook`, the live V1 hook, set at construction. `prepare`, `migrate` and `seamBlocked` accept a venture only if that hook's registry records the venture's pool as the venture's, operated by its spot vault. Factory-deployed LBPs are the only writers of that registry, so a contract posing as a venture (and registering a vault for itself through `registerSpotLiquidityVault`) is rejected with `UnknownSourcePool` before it can claim a real venture's V2 pool key. A later migrator, from V2 pools onward, anchors on the V2 hook's record the same way.

## Functions

- `prepare(venture)`: permissionless, one-shot. Deploys the `ActiveLiquidityManager` and `SpotLiquidityVaultV2` (`SpotLiquidityV2Deploy`, as the V2 LBP does) with fee and tick spacing read from the venture's V1 vault. Inert until `migrate`. About 7.2M gas on a Base fork, so it runs as its own transaction before the vote resolves.
- `migrate(p)`: the caller is the venture. In order:
  1. Require V1 spot within `fee / 50` ticks (200 for 1% pools, the fee in V4 pips) of V1's 30-minute TWAP (`SEAM_TWAP_WINDOW`) and within `SEAM_MAX_LONG_TICK_DEVIATION` (300 ticks, ~3%) of its 6-hour TWAP (`SpotTwapGuard.withinBands`; `SeamPriceDeviationTooHigh`). Fails closed while either V1 ring cannot serve its window; the keeper retries.
  2. `hookV2.registerMigratedPool` with V1 as predecessor (backfilling the V2 coarse ring from V1's last 30 days), then `poolManager.initialize` at V1's exact price.
  3. Bootstrap the anchor vault with `anchorBps` of each token (at least `MIN_ANCHOR_BPS` = 5000, so the full-range anchor keeps every tick funded; 7500 is the planned default); shares go to the venture, surplus to the treasury.
  4. Send the rest to the ALM and `seed` it from `activeSlices` (`{tickLowerOffset, tickUpperOffset, bps}` around the init tick, offsets multiples of the spacing, `bps` summing to at most 10000). An empty `activeSlices` leaves the ALM funded but unseeded.
  5. `hub.migrateSpotLiquidityVault(venture, newVault)`.
- `seamBlocked(venture)`: true while the venture is prepared and `migrate` would fail the seam check. The keeper uses it because `Venture.executeCall` reports every failed action as `TransferFailed`.

## Notes

- Fork-measured on Base (UMIA): execution about 11.1M gas including the oracle backfill (122 samples), against the 16.78M per-transaction cap.
- Shares the proposal does not withdraw (for example from a deposit made to the venture after the proposal was written; V1 `deposit` takes any receiver) stay the venture's in V1, redeemable by a later proposal. No bound applies, so such a deposit cannot block the migration. Known and accepted: on-chain liquidation redeems only the Hub's current vault and its ALM, so a liquidation plan for a venture with V1 shares left must redeem them (`withdraw` on the V1 vault) before `LIQUIDATE_TREASURY`. See [GOVERNANCE_TREASURY_LAYER.md](../GOVERNANCE_TREASURY_LAYER.md).
- Third-party V1 LPs are not migrated; they keep a working V1 vault and can withdraw at any time.
- The migration reserves 721 coarse slots past the backfill (`BACKFILL_RESERVE`), so the 30-day vesting read keeps serving without any keeper action; the ring can still be grown with `hookV2.increaseCoarseCardinalityNext`.
- Staging: `script/DeploySpotLiquidityV2.s.sol` deploys the migrator with the rest of the V2 spot liquidity release, and the Hub owner then calls `hub.setSpotMigrator(migrator)`. The full owner order is in [UPGRADES.md](../UPGRADES.md#v2-spot-liquidity-release).
