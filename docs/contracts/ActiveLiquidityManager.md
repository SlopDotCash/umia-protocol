# ActiveLiquidityManager

Source: `src/core/ActiveLiquidityManager.sol`, `src/interfaces/IActiveLiquidityManager.sol`

## Purpose

Keeper-managed concentrated positions in a venture's V2 spot pool, funded by the venture treasury. Improves execution near the price. Registered on `UmiaHookV2` as the pool's `activeOperator`. Decision markets never draw from it; in its own venture's markets it runs basket arbitrage against spot, trading the same fraction of each proposal's output reserve.

## Roles

| Caller | May |
| --- | --- |
| `venture` (a passed proposal via `executeCall`) | fund by plain token transfer, `defund` idle, `withdrawAll`, `setKeeper`, `setConstraints`, `setPaused(true / false)` |
| `bootstrapper` (`SpotMigrator`) | `seed(positions)` once before any rebalance, skipping the TWAP guard (it runs at the price the pool was just initialized to) |
| `keeper()` | `rebalance(positions)`, `basketArb`, `setPaused(true)` |
| `hub.owner()` | `setPaused(true)` |
| anyone | views, `collectFees`, `claimProtocolFees`, `claimDecisionMarket` |

`keeper()` is the venture's override or, when unset, `hub.activeLiquidityKeeper()`.

## Constraints

Venture-settable; the constructor starts every ALM at 3 positions, width 2 to 1000 tick spacings (`ActiveSlices.DEFAULT_MAX_WIDTH_SPACINGS`, wide so a launch range survives its first day), 1 hour between rebalances, band = fee.

- `maxPositions` (at most `MAX_POSITIONS = 8`), `minWidthTicks` (at least the tick spacing), `maxWidthTicks`
- `minRebalanceInterval`
- `maxTwapDeviationTicks`: `rebalance` reverts while spot is further than this from the pool's 30-minute TWAP. **Capped at the pool fee in ticks** (`maxTwapDeviationCap()`, 100 for a 1% pool). Same-block swaps do not move the TWAP, so a compromised keeper could otherwise push the price to the edge of the band, place a range just under the pushed price and sell into it. With the band at most the fee, the swap fee the manager earns on that flow covers the premium it pays. Holding the pushed price for 30 minutes does not help either: `rebalance` also reverts while spot is more than `MAX_LONG_TICK_DEVIATION` (500 ticks, ~5%) from the 12-hour TWAP (`LONG_TWAP_WINDOW`; `SpotTwapGuard.withinBands`, coarse ring; fails closed with `InsufficientOracleHistory` until that ring covers 12 hours, which a migrated pool's backfill already does), so a 15% push has to be held for about eight hours, and a range placed once it passes can be off by at most a few fees.

## Invariants

- Tokens leave only into the pool, to `venture`, (the protocol cut) to `hub.protocolFeeRecipient()`, or into a decision market whose `activeManager` is this manager. No arbitrary call path.
- V4 reports each position's swap fees apart from principal when it is removed or poked, so fees are separated from principal. The venture is paid `fees - cut` immediately; the cut (`hub.spotProtocolFeeCutBps()`) accrues in `protocolOwedVenture` / `protocolOwedMoney` and leaves through `claimProtocolFees`. A reverting fee recipient can never block `withdrawAll`. A seed or rebalance that would leave less than the owed cut in the contract reverts (`InsufficientIdle`), so the keeper cannot reinvest it.
- `paused` blocks `rebalance` and `basketArb`, never `seed`, `withdrawAll`, `defund` or `claimDecisionMarket`. A passed migration seeds even a paused manager, so a pause can't veto it.
- Position `i` lives under salt `i`.

## Decision markets

The only decision-market path is basket arbitrage: the same reserve fraction in every proposal, no-op included. A single-proposal trade would be a bet on the outcome made with venture capital, so none exists. It requires `marketCore.activeManager(marketId) == address(this)`. MarketCore records the manager of the venture's spot vault when a market is created, which pins it to the venture's own markets.

- `basketArb(marketId, sellToMarkets, size, outFractionWad, sqrtPriceLimitX96, minMoneyProfit)`: when every proposal is priced above spot, buy `size` venture tokens on spot, split, sell for `outFractionWad` of each pool's money reserve (`basketSwapExactOut(marketId, zeroForOne, outFractionWad, amountInMaxPerLeg = size, deadline)`, fee-free for this manager), merge the smallest leg. The buy direction mirrors it. Reverts with `BasketUnprofitable` unless real balances end with no less venture token and at least `minMoneyProfit` more money. Unmergeable remainders stay as conditional tokens valued at zero. No TWAP guard or interval: the profit check means a keeper can cost the venture only gas. Returns `(moneyProfit, ventureGain)`, so the keeper sizes it by `eth_call`. Every proposal's price moves by the same factor, so a basket never changes a lead.
- `claimDecisionMarket(marketId)`: after settlement, redeems the winning proposal's basket remainders through `claimSettlement`. Call it once per market, after settlement and before the winning proposal executes; a second call reverts with `AlreadyClaimed`.

The manager never provides decision-market liquidity; markets are seeded from the anchor, and extra depth is a governance decision (`addLiquidity` is public). `totalAssets` excludes decision-market holdings. `withdrawAll` returns real tokens only; anything in an unsettled market comes back through `claimDecisionMarket`. Sizing: `basketArb` returns `(moneyProfit, ventureGain)` and reverts `BasketUnprofitable` otherwise, so the keeper sizes a basket by `eth_call` against `basketArb` itself, trying candidate `size` values with `minMoneyProfit = 0` and sending the most profitable one with a real `minMoneyProfit`. See [MarketCore fee rules](./UmiaMarketCore.md#access-control-and-checks).

## One pool, one manager

The code that deploys a manager (`SpotMigrator`, `UmiaLBPV2`) writes it into the V2 pool's hook record at registration, and it never changes. That record is the only way to become a pool's active operator or its markets' `activeManager` (the fee-exempt basket trader). A venture that wants an outside market maker sets it as this manager's keeper (`setKeeper`). A misbehaving manager is paused and emptied by the venture; a different manager means migrating to a new pool.

## Keeper

Rebalancing strategy is market making and runs outside this monorepo: an external bot holds the keeper role (`hub.activeLiquidityKeeper()` or the venture's `setKeeper` override) and calls `rebalance` within the constraints above. Every seed, rebalance and basket action is emitted (`Seeded`, `Rebalanced`, `BasketArb`, `DecisionMarketClaimed`), so a monitor needs nothing beyond the events. Its decision-market trades count as volume, like any market maker's.

## Liquidation

`LIQUIDATE_TREASURY` empties the ALM (`withdrawAll`) before the claim snapshot. Basket leftovers count only once claimed into it: claim them after each settlement and before the liquidation executes, since a claim made after the liquidation can never leave the ALM. This lives in `GovernanceActions`, linked into the `GovernanceExecutor`, so the executor shipped with the V2 spot liquidity release must be the Hub default before any ALM holds capital; a liquidation plan written for an older executor must add an explicit `CALL` action `alm.withdrawAll()` before `LIQUIDATE_TREASURY`. Leftovers in earlier markets must be claimed before the liquidation executes: once it does, the venture can no longer move its funds out of the ALM. `claimProtocolFees` stays permissionless and still pays the accrued protocol cut to the Hub's recipient. See [LIQUIDATIONS.md](../LIQUIDATIONS.md).
