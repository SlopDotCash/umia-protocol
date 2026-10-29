# ConditionalMarketOracle

Source: `src/periphery/ConditionalMarketOracle.sol`

## Purpose

Per-proposal TWAP oracle used by market settlement.

- Integrates an accepted tick (log price, money per venture) that slews toward the pool's tick.
- Anchors each proposal's scoring window at `tradingStart` with a zero cumulative baseline.
- Calculates the time-weighted mean tick from `tradingStart` to the current block timestamp (frozen
  at `tradingEnd`) and reports it as a Q112.112 price: a geometric-mean TWAP.

## Interface

The interface is the upgrade seam: the Hub owner can point the core at a replacement oracle
implementing it (see `docs/UPGRADES.md`) without changing `UmiaMarketCore`. `winningThresholdBps`
is accepted (and validated) at `initialize` so a future implementation can calibrate to the
threshold settlement uses; this implementation does not consume it.

- `initialize(proposalId, reserve0, reserve1, tradingStart, tradingEnd, winningThresholdBps)`:
  one call at market creation: validates inputs, seeds the accepted tick at the pool's tick, anchors
  `lastTimestamp` at `tradingStart`. Reverts with `AlreadyInitialized` if repeated.
- `update(proposalId, reserve0, reserve1)`: called before every reserve mutation, so the elapsed
  interval is credited at the price that actually held over it. No-op before `tradingStart`,
  within the same second, after the `tradingEnd` freeze, or for degenerate (zero) reserves: a
  degenerate interval is credited by the next well-formed update instead.
- `calculateTWAP(proposalId, reserve0, reserve1)`: view; extrapolates the current interval by
  slewing toward the passed reserves' tick, and returns the mean tick's price in Q112.112.
- `calculateTWAPTick(proposalId, reserve0, reserve1)`: the mean tick behind `calculateTWAP`,
  rounded toward negative infinity.

## Key state

- `oracleStates[proposalId]`:
  - `tickCumulative`: ∫ accepted tick dt, scored from `tradingStart`
  - `lastTick`: accepted tick at `lastTimestamp`
  - `tickAreaRemainder`: fractional tick area carried between updates
  - `tradingStart`, `tradingEnd`: scoring window
  - `slewPerSecond`: max accepted-tick movement per second, fixed at `initialize` from `slewFor(duration)`
  - `lastTimestamp`: last recorded time; anchored at `tradingStart` on init
  - `initialized`

## Access control

- `initialize` and `update` are `onlyMarketCore`.

## Tick slew

The same filter as the spot oracle: both call `src/libraries/TickSlew.sol`, each with its own
rate. Over each interval the accepted tick ramps toward the pool's tick at no more than the
oracle's `slewPerSecond`, then holds it for the rest of the interval. The ramp and the hold are
integrated exactly, with the fractional area carried in `tickAreaRemainder`.

The conditional rate is low on purpose: `MIN_TICK_SLEW_PER_SECOND = 7`, 420 ticks (about 4.3%)
per minute, against the spot oracle's 4,558 per second. A conditional pool holds a fraction of the
anchor, so a crash the settlement TWAP followed at once could be bought cheaply and held for the
last minutes of the window to flip or block the winner. At 7 ticks per second the
recorded tick lags a crash by design: moving a two-day average by the 2% threshold takes a hold of
about 52 minutes (64 on a three-day market), in the open, while an honest repricing of tens of
percent still registers within minutes. Short markets get a faster rate from `slewFor(duration)`, the floor or whatever lets a
doubling (`DOUBLING_TICKS = 6,931`) register within a tenth of the window, so a one-hour market
slews at 20 ticks per second. The rate is fixed per proposal at `initialize`.

The number was chosen against real data: replaying every trade of UMIA decision market 3 on Base
through the damped oracle (`docs/analysis/conditional-oracle-damping/`), the largest one-minute
move was 316 ticks, the cap would have bound for 0.1% of the window and no settled TWAP would have
changed by a tick.

The allowance depends on elapsed time, not on how many updates are triggered: a pump held across
two spaced updates and dumped in the second's block is credited only for the ramp it was given, and
a pool nobody touches converges on its real tick. The per-update clamp this replaces left the last
accepted price ratcheted in that case and kept crediting it for the rest of the window.

Because the TWAP is the mean tick, settlement's `priceDeltaBps >= winningThresholdBps` comparison
of two TWAPs is a fixed tick offset, applied identically to every proposal. Mean ticks are floored, so
passing the 2% threshold takes a 199-tick lead (1.0001^198 settles as 199 bps).

## Pool tick

`_poolTick` computes `sqrt(reserve1 / reserve0)` in Q64.96 with `FullMath.mulDiv`, dropping
precision only for ratios at or above 2^64 and saturating at 2^128, then clamps to the V4 tick
range. No reserve pair can overflow an update or a settlement read.

## Trading end freeze

All three entry points cap their effective timestamp at `min(block.timestamp, tradingEnd)` via
`_effectiveTimestamp()`.

This means:
- After `tradingEnd`, no further accumulation occurs regardless of when `update()` is called.
- `calculateTWAP()` returns the same value whether called at `tradingEnd` or hours later.
- Settlement delay cannot dilute or extend the TWAP window beyond the trading period.
- Last-block manipulation at `tradingEnd - 1` gets at most one second of slew: `slewPerSecond` ticks, 7 on markets at the rate floor, 20 on a one-hour market.

## Deployment

Proposals are initialized on the oracle the Hub points at, and `getProposalTWAP` reads the Hub's
current oracle, so a swap mid-market would make live proposals revert with `ProposalNotInitialized`.
The Hub owner swaps the oracle with `hub.setConditionalMarketOracle(newOracle)`, which
`withNoActiveMarkets` allows only while no market is unsettled.

## Notes

- `calculateTWAP` reverts with `ProposalNotInitialized` for unknown proposals and
  `TradingNotStarted` before the scoring window opens.
- Queried in the first second of the window, `calculateTWAP` returns the seed tick's price rather
  than the raw spot of the passed reserves (which would be same-block manipulable).
