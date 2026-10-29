# Spot Pool TWAP Oracle

## Overview

Umia integrates a time-weighted average price (TWAP) oracle into `UmiaHook`, the oracle-only Uniswap V4 hook attached to every Venture's spot pool. One hook instance serves all spot pools on a chain, keyed by `PoolId`; `UmiaHookV2`, the hook for V2 spot pools, carries the same rings and read surface. The oracle records price observations on every swap and liquidity change, so any onchain or off-chain consumer can query manipulation-resistant TWAPs.

The oracle is **dual-cadence**: each pool carries two independent observation rings written from the same hook callbacks.

| Ring          | Write cadence                       | Read entrypoint | Serves                                              |
| ------------- | ----------------------------------- | --------------- | --------------------------------------------------- |
| **Per-block** | At most once per block              | `observe`       | Short windows (minutes to hours)                    |
| **Coarse**    | At most once per hour (`COARSE_INTERVAL`) | `observeLong`   | Month-scale windows, at any trade volume            |

The split exists because ring capacity is hard-capped at 65,535 slots (`uint16`). On Base (2s blocks) a pool touched every block wraps the per-block ring in ~36 hours, so a 30-day lookback can never survive on it. The coarse ring's span is governed by cadence, not block frequency: ~744 hourly slots cover a full month regardless of how hard the pool trades.

Four consumers exist today:

| Consumer                       | Window                                       | Ring | Purpose                                                                                                                                                                                                                                                                                                       |
| ------------------------------ | -------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **SpotLiquidityVault**         | 30 minutes (`TWAP_WINDOW`); V2 also 6 hours  | Per-block (`observe`); V2 also coarse (`observeLong`) | Sandwich guard. Reverts if the spot tick deviates from the 30-minute TWAP tick by more than `MAX_TICK_DEVIATION` (1000 ticks, roughly 10.5%); V2 also reverts when spot is more than `MAX_LONG_TICK_DEVIATION` (2000 ticks, roughly 22%) from the 6-hour TWAP (`SpotTwapGuard.withinBands`). Runs on `deposit`, `withdraw`, `pullForDecisionMarket` (decision-market creation) and `returnFromDecisionMarket` (settlement).                                       |
| **UmiaTwapMilestoneCondition** | Configurable at construction (mainnet: 30 days) | Selected by window | Gates a MetaVesT vesting milestone on the full-window TWAP. Reads the coarse ring (`observeLong`) for windows ≥ 2 × `COARSE_INTERVAL` (the 30-day mainnet gate) and the per-block ring (`observe`) for shorter windows, which an hourly ring cannot average. Threshold resolved live from `VentureVestingAuthority`. Fail-closed. |
| **ActiveLiquidityManager**     | 30 minutes (`TWAP_WINDOW`) and 12 hours (`LONG_TWAP_WINDOW`) | Per-block and coarse | Rebalance guard (`rebalance` only; `seed` and `basketArb` skip it). Reverts with `SpotPriceDeviationTooHigh` when spot is further than the venture-set `maxTwapDeviationTicks` (capped at the pool fee in ticks) from the 30-minute TWAP, or more than `MAX_LONG_TICK_DEVIATION` (500 ticks, roughly 5%) from the 12-hour TWAP. |
| **SpotMigrator**               | 30 minutes (`SEAM_TWAP_WINDOW`) and 6 hours  | Per-block and coarse | Seam check on the V1 pool before `migrate`: spot within `fee / 50` ticks (200 for a 1% pool) of the 30-minute TWAP and within `SEAM_MAX_LONG_TICK_DEVIATION` (300 ticks) of the 6-hour TWAP, else `SeamPriceDeviationTooHigh`. `seamBlocked` exposes the same test. |

Within each ring the window is a query-time parameter, not a configuration.

## How It Works

### The Observation Buffer

Each pool has a circular buffer of up to 65,535 **observations**. An observation records:

```solidity
struct Observation {
    uint32  blockTimestamp;                      // when this observation was written
    int24   prevTick;                            // the tick at time of writing
    int48   tickCumulative;                      // cumulative sum of (tick * seconds elapsed)
    uint144 secondsPerLiquidityCumulativeX128;   // cumulative seconds / liquidity
    bool    initialized;                         // whether this slot has been written
}
```

TWAPs are computed from the `tickCumulative` field. Each observation adds the accepted tick's time integral since the previous write to the running sum (a ramp is integrated as a ramp, see below). To compute a TWAP between two times, you subtract their cumulative values and divide by the time difference:

```
twapTick = (tickCumulative[now] - tickCumulative[then]) / (now - then)
```

This is a **geometric mean** TWAP (since ticks are logarithmic), which dampens short upward spikes relative to an arithmetic mean. The broader manipulation resistance comes from time-weighting the cumulative observations and from the tick-slew bound on what each observation can record.

### When Observations Are Written

`UmiaHook` writes an observation in three hook callbacks, each capturing the tick *before* the event executes:

- **`beforeSwap`** the standard oracle pattern.
- **`beforeAddLiquidity`** keeps the oracle current before liquidity changes affect the `secondsPerLiquidityCumulative` accumulator.
- **`beforeRemoveLiquidity`** same, for removals.

At most one observation is written per block. If multiple swaps happen in the same block, the first one writes and subsequent ones are no-ops.

The **coarse ring** is not written independently. On the first event of each `COARSE_INTERVAL` (1 hour) bucket, `_writeObservation` checkpoints the per-block ring's freshly written observation into the coarse ring via `SpotMarketOracle.writeSnapshot`. The coarse ring is therefore a downsample of the per-block ring's already-time-weighted cumulative: it inherits the per-block time resolution, so a transient spike contributes only its fine-ring integral (including its bounded slew/recovery tail), never a whole interval (see [Security](#security-properties)). A bucket with no trades records nothing; quiet stretches are reconstructed by `observe`'s slew-aware extrapolation (≤1h fuzz on a window endpoint, ~0.14% of a 30-day window).

Coarse writes are a byproduct of trading, with no cranker. The one-time grow of each ring to its full span is done by the keeper's `grow-oracle` cron, the same way the per-block ring is grown.

### Initialization

`afterInitialize` seeds both rings at cardinality 1 when the pool is first initialized. The seed is idempotent: a second initialize for the same `PoolId` is a no-op because `oracleStates[id].cardinality` is only zero before the first seed (the rings are always seeded together, so the per-block cardinality gates both). `UmiaHookV2` gates only the coarse seed on that ring's own cardinality, so a migrated pool's backfilled coarse ring survives pool initialization.

Cardinality 1 is not enough to serve any TWAP window (see [Fail-closed behavior](#fail-closed-behavior)), so `SpotLiquidityVault.bootstrapFromLBP` (V1 and V2) seeds both rings to **100 slots** (`increaseCardinalityNext` / `increaseCoarseCardinalityNext`). The seed is kept small so its cold SSTOREs fit alongside pool init under Base's 2^24 per-transaction gas cap. The keeper's `grow-oracle` cron then chunk-grows each ring to its target, one 300-slot chunk per tick: per-block 1000 (`ORACLE_CARDINALITY_TARGET`; 2000 on sub-second chains via `ORACLE_CARDINALITY_TARGET_BY_CHAIN`), coarse 900 (`COARSE_ORACLE_CARDINALITY_TARGET`).

The coarse seed is not time-critical: cardinality above 1 preserves the seed observation, the first post-seed write is a full interval out, and 100 slots take days to wrap, so the cron reaches 900 long before any history is evicted. Anyone can also grow either ring permissionlessly.

### Elapsed-time truncation

The oracle's accepted tick can approach the raw pool tick at no more than **4,558 ticks per elapsed second** (`SpotMarketOracle.TICK_SLEW_PER_SECOND`; the conditional oracle passes its own, far lower rate to the shared `TickSlew` library). Over a normal two-second Base block this permits the same 9,116-tick move as the former per-observation clamp (roughly a 2.5x price change), but the allowance now depends on time rather than on how many observations an attacker can trigger.

Each update integrates the accepted tick's continuous path: it ramps linearly toward the raw tick at the maximum rate, then holds the raw tick for any time left in the interval. If a burst moves the accepted tick away from reality and the pool is restored, the next update likewise integrates only the short recovery ramp and the honest remainder of the quiet interval. It cannot clamp down by one step and mistakenly credit that stale endpoint across the entire hour.

The linear-ramp area has a denominator of 9,116. A per-pool remainder carries the fractional numerator between writes using floor division, so splitting one constant price path across many updates produces exactly the same accepted endpoint and cumulative as one sparse update. This prevents observation-count ratcheting and rounding drift.

Because the coarse ring copies the per-block cumulative rather than integrating a sampled tick (see [When Observations Are Written](#when-observations-are-written)), it inherits the elapsed-time bound and the fine-ring time resolution. There is no separate per-hour clamp and no boundary-resample amplification.

## Querying the Oracle

### `observe(PoolKey, uint32[] secondsAgos)`

Returns cumulative tick and liquidity values at each requested point in the past.

```solidity
uint32[] memory secondsAgos = new uint32[](2);
secondsAgos[0] = 1800; // 30 minutes ago
secondsAgos[1] = 0;    // now

(int48[] memory tickCumulatives, ) = hook.observe(key, secondsAgos);

int24 twapTick = TwapMath.averageTick(tickCumulatives[0], tickCumulatives[1], 1800);

// Convert tick to price if needed:
uint160 twapSqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
```

Use `TwapMath.averageTick` rather than dividing by hand: Solidity division truncates toward zero, which biases a negative average upward.

Any window length works, from 1 minute to 30 days, as long as the buffer contains observations spanning that period. Reverts with `TargetPredatesOldestObservation` if the requested time is older than the oldest observation in the buffer.

### `observeLong(PoolKey, uint32[] secondsAgos)`

Identical semantics and return shape to `observe`. Each requested lookback is served from the coarse ring, except targets at or after the newest coarse checkpoint (including `secondsAgo == 0`), which come from the per-block ring. The rings share one cumulative scale (the coarse ring downsamples the per-block one), so the mix composes; sourcing the recent end from the per-block ring means its live-tick extrapolation spans at most one block, so a flash move cannot be credited for the open bucket's elapsed hour. `UmiaTwapMilestoneCondition` reads its 30-day window through `observeLong`; for windows below 2 × `COARSE_INTERVAL` it falls back to `observe`, since an hourly ring cannot average a sub-hour window. Precision at the old endpoint is bounded by one `COARSE_INTERVAL` of interpolation fuzz: negligible against a monthly average, and exact whenever it falls in an already-settled quiet stretch.

### `oracleStates(PoolId)` and `getObservation(PoolId, uint16)`

`oracleStates` returns `(index, cardinality, cardinalityNext)`. `getObservation` returns a single slot's `(blockTimestamp, tickCumulative, secondsPerLiquidityCumulativeX128, initialized)`. Together they let a consumer check whether a window is servable before calling `observe`, which is how the vault's fail-closed predicate works. `coarseOracleStates` and `getCoarseObservation` are the coarse-ring equivalents.

### `increaseCardinalityNext(PoolKey, uint16)`

Pre-allocates observation buffer slots. Permissionless: anyone can call it and pay the gas. `increaseCoarseCardinalityNext` is the coarse-ring twin.

```solidity
hook.increaseCardinalityNext(key, 1000);
```

Each slot costs one cold SSTORE (~22,100 gas) to initialize. The call is a no-op if `cardinalityNext` is already at or above the requested value, and `grow()` picks up where the last call left off, so large targets can be reached across several transactions.

## Buffer Sizing (Cardinality)

### What is cardinality?

The observation buffer is a fixed-size circular array. **Cardinality** is the number of usable slots. When all slots are full, new observations overwrite the oldest ones. `cardinalityNext` is the capacity that has been paid for; `cardinality` catches up to it lazily as writes wrap past the current end.

### Cardinality and window length

A TWAP query for a given window only works if the buffer still contains an observation from that far back. If trading activity has overwritten every observation older than the window, the query reverts with `TargetPredatesOldestObservation`.

The oracle is always **time-based**: you query "what was the average price over the last N seconds?" It interpolates between observations, assuming the tick stays constant between them. Even with sparse observations (say 1 per day), a 30-day TWAP is valid as long as the oldest observation is at least 30 days old. Cardinality is an infrastructure constraint, not a semantic one.

Because at most one observation is written per block, **cardinality is denominated in blocks with activity, not in swaps**. On Base (2s blocks), a fully saturated pool consumes 30 slots per minute.

### Sizing for the 30-minute sandwich guard

Worst case is one observation per block for the whole window: 1800s / 2s = **900 slots** on Base. The bootstrap default of 100 slots only covers ~200s of back-to-back active blocks, so a pool under sustained per-block activity can wrap its buffer inside the window and start failing the guard with `InsufficientOracleHistory`.

This fails safe, never open, but it does block `createMarket`, `deposit` and `withdraw` until history rebuilds. **Grow busy pools to at least 1,000 slots.** One `increaseCardinalityNext(key, 1000)` call costs ~20M gas and is permissionless.

### Sizing for 30-day TWAPs: the coarse ring

Long windows are served by the coarse ring, whose consumption rate is fixed by cadence: **at most 24 slots per day, at any trade volume**. The per-block ring is structurally incapable of a 30-day window under load (one swap per 2s block needs 1,296,000 slots, ~20x the 65,535 maximum). That limit is why the coarse ring exists; it is not a sizing knob to tune around.

Repeated `increaseCoarseCardinalityNext` calls, which anyone can send, bring the ring to `COARSE_ORACLE_CARDINALITY_TARGET = 900` (30 days x 24 buckets, plus up to 122 backfilled slots on a migrated pool, plus headroom), which is sufficient permanently. Growing further only lengthens the maximum servable window (e.g. 1,488 slots for a 60-day TWAP); it is never needed to keep the 30-day window alive.

Note the coarse ring is fail-closed by time, not slots: the 30-day read serves only once 30 days of history exist. On a new pool with no predecessor (a fresh launch), `UmiaTwapMilestoneCondition.checkCondition` correctly reports `OracleNotReady` until a full window has accrued; the vault and ALM guards report the same state as `InsufficientOracleHistory`. A `UmiaHookV2` migration keeps serving, and requires a predecessor hook with a seeded coarse ring: pools on a legacy hook without one cannot migrate; see [Migration backfill](#migration-backfill).

### Grow cost and Base's per-transaction cap

Each slot costs ~22,100 gas (cold SSTORE). The constraint is not the block gas limit but **Base's 2^24 (~16.78M) per-transaction cap**: a single tx cannot exceed it, and the keeper ships `migrate()` with an explicit 16M limit. So growing 900 coarse slots (~20M) in one call is impossible, and folding it into `migrate()` (which already does pool init + a full-range mint) would blow the cap outright.

Both rings are therefore grown the same way: `bootstrapFromLBP` seeds 100 slots each (~2.2M apiece, inside the migration tx), and the `grow-oracle` cron cranks 300-slot chunks (~6.6M each, well under the cap) until it reaches 1000 (per-block) and 900 (coarse). Growing is permissionless and does not need to come from the Venture owner.

### Fail-closed behavior

`SpotLiquidityVault._oracleHasFullWindow` refuses to serve the guard unless **both** hold:

1. `cardinality >= 2`. With a single observation, `observe` extrapolates forward and returns `twapTick == spotTick`, which would make the deviation check pass unconditionally and silently disable the guard.
2. The oldest initialized observation is at or before `block.timestamp - TWAP_WINDOW`.

If either fails, the vault reverts with `InsufficientOracleHistory`. The only case that skips the guard entirely is an empty position (`currentLiquidity() == 0`): there are no reserves to sandwich, and keeping it open is what lets a fully drained vault be re-bootstrapped.

`SpotTwapGuard.withinBands` (the V2 vault, the ALM and the migrator seam) applies the same two conditions to each ring: the per-block ring for the 30-minute window, the coarse ring for the consumer's long window (`LONG_TWAP_WINDOW`: 6 hours for the vault and the migration seam, 12 hours for the ALM). When the newest coarse checkpoint is older than that window the lookback stretches back to it, so the lookback stays on the coarse ring. A per-block ring short of history returns `ready == false` and the caller reverts with `InsufficientOracleHistory`. The coarse ring is only read once the short-window deviation is within `shortBand`, and then a short coarse ring does the same. A short-window breach returns `ok == false` before that check, so the caller reverts with its deviation error even if long-window history is missing.

Long-window consumers behave the same way: `UmiaTwapMilestoneCondition` reverts rather than reporting a milestone as unmet on missing data.

## Migration backfill

A `UmiaHookV2` pool migrated from an earlier hook (see [SpotMigrator](./contracts/SpotMigrator.md)) replaces a **predecessor** pool. A new pool starts with empty rings, so without help every 30-day TWAP would be unservable for 30 days after a migration.

**Backfill.** `registerMigratedPool` runs inside the migration transaction, right after the venture's V1 vault withdrawal. It makes one `predecessor.observeLong` call for targets every `BACKFILL_SPACING = 6 hours`, back `BACKFILL_STEPS = 121` steps (30 days plus one step) or to the predecessor's oldest coarse observation, whichever is newer. It writes the results into this pool's coarse ring as ordinary observations, oldest first, rebased so the newest (the handover) is zero, the same point the per-block ring starts from. `afterInitialize` leaves the backfilled ring alone.

**Reads.** `observeLong` is `UmiaHook`'s read path verbatim. Nothing reads the predecessor after the migration transaction, so later swaps on the V1 pool change nothing, and a later migration from this pool carries the backfilled history on.

**Precision.** A window whose start falls in a backfilled 6-hour segment interpolates linearly inside it. The error in the average tick is at most `(M − m) · 6h / (4 · window)`, where `M − m` is the tick range inside that segment: 3.8 ticks (0.04%) for a 20% swing, 14.4 ticks (0.14%) for a 100% swing on a 30-day window. A window starting on a sample point is exact. Windows between 2 hours and about a week see proportionally more error for their first `window` after a migration. The vault's 6-hour and the ALM's 12-hour guard windows are in that range: the error is at most a quarter (6 h) or an eighth (12 h) of the tick range inside the backfilled segment.

**No growth deadline.** The migration reserves `BACKFILL_RESERVE` (721) coarse slots past the backfill without pre-writing them, so the ring cannot wrap onto the backfill before the pool has 30 days of its own hourly history. Each hourly writer pays its slot's first write. The keeper's `grow-oracle` still tops the ring up to 900.

**Scope.**

- `observe` (per-block) is not backfilled. Its consumers (the vault and ALM 30-minute guards) check this pool's own oldest slot first, so a migrated pool behaves like a fresh one for 30 minutes.
- A predecessor with less than 30 days of coarse history yields fewer samples. The 30-day read serves once the window fits inside the copied history plus this pool's own.

## Security Properties

**Manipulation resistance**: an attacker skewing a TWAP must sustain an artificial price against everyone who profits from correcting it. The accepted tick moves by at most 4,558 ticks per elapsed second, and the cumulative integrates its ramp and recovery path. Triggering more writes cannot accelerate the filter, while restoring the pool lets it recover during a quiet gap instead of carrying a stale clamped tick across that gap.

**No coarse-ring boundary amplification**: because the coarse ring copies the per-block cumulative rather than re-integrating the tick sampled at the bucket boundary, a transient move earns only its bounded fine-ring ramp/recovery area in the long-window TWAP. A naive coarse ring that recorded the boundary tick would let a one-block spike, held across an hour boundary, count for the whole hour, ~1800x amplification against the milestone gate. Downsampling closes that on the write path, and `observeLong` closes the read path symmetrically by serving targets newer than the latest checkpoint from the per-block ring, so a flash move at read time gets at most one block of extrapolation weight instead of the open bucket's elapsed hour.

**Operator-only, full-range liquidity**: `UmiaHook` enforces in `beforeAddLiquidity` and `beforeRemoveLiquidity` that only the pool's registered `operator` (the venture's `SpotLiquidityVault`) may change liquidity, and that every position spans `minUsableTick` to `maxUsableTick`. Concentrated liquidity would create zero-liquidity tick gaps where the tick can be moved for free, undermining the slew limit. Violations revert with `UnauthorizedLiquidityOperator` or `OnlyFullRangePositions`.

`UmiaHookV2` keeps the full-range anchor and adds one concentrated operator, the venture's `ActiveLiquidityManager`. Its positions sit on top of the anchor's full-range position, so no tick has zero liquidity while the anchor is funded; concentrated liquidity only deepens the book near the price. Decision markets pull from the anchor only, and only half of it. The manager can rebalance only while spot is within `maxTwapDeviationTicks` (venture-set, at most the pool fee in ticks) of the 30-minute TWAP and within `MAX_LONG_TICK_DEVIATION` (500 ticks) of the 12-hour TWAP (`LONG_TWAP_WINDOW`), so a compromised keeper cannot profit from placing ranges at a manipulated price.

**No liquidity lock**: unlike reference implementations that permanently lock liquidity to guarantee oracle integrity, Umia does not enforce a liquidity floor. The vault holds the canonical seed LP from LBP migration, and decision-market creation only pulls `BOOTSTRAP_PULL_BPS` (50%). Elapsed-time truncation provides manipulation resistance regardless of liquidity depth.

**Fail-closed guard**: see [Fail-closed behavior](#fail-closed-behavior). Buffer exhaustion by dust swaps blocks the operation instead of bypassing the check.

## Integration with Decision Markets

`UmiaMarketCore.createMarket()` does not query the oracle itself. It calls `MarketCreationLib._pullSeedLiquidity`, which delegates to the vault:

1. `MarketCreationLib` reads the venture's vault from `hub.ventureLiquidityVault()`, reverting with `LPPositionNotRegistered` if unset.
2. It calls `ISpotLiquidityVault.pullForDecisionMarket(marketId, BOOTSTRAP_PULL_BPS)`.
3. The vault runs `_requireSpotWithinTwapDeviation()` before removing anything: it checks `_oracleHasFullWindow`, queries the 30-minute TWAP via `hook.observe()`, reads the current spot tick from `getSlot0`, and computes `|spotTick - twapTick|`. `SpotLiquidityVaultV2` runs the same check through `SpotTwapGuard.withinBands`, which also compares spot to the 6-hour TWAP of the coarse ring.
4. It reverts with `SpotPriceDeviationTooHigh` if that difference exceeds `MAX_TICK_DEVIATION` (1000 ticks, roughly 10.5%), or on V2 if spot is more than `MAX_LONG_TICK_DEVIATION` (2000 ticks) from the 6-hour TWAP, or `InsufficientOracleHistory` if a window is not servable.
5. Only then does it remove 50% of its full-range liquidity and hand the proceeds to `UmiaMarketCore`.

Tick differences map directly to percentage price changes because ticks are logarithmic (`price = 1.0001^tick`), so a fixed tick difference is a fixed percentage regardless of the absolute tick level.

Settlement takes the same path in reverse: `SettlementLib` calls `returnFromDecisionMarket`, which runs the identical guard before re-adding liquidity.

## Files

| File                                           | Role                                                                                                                          |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `src/libraries/SpotMarketOracle.sol`           | Circular buffer library: observation storage, writes, truncation, binary search, interpolation (shared by both rings)          |
| `src/periphery/UmiaHookV2.sol`                 | V2 hook: same rings and read surface, anchor + active operators, coarse-ring backfill from a migrated pool's predecessor      |
| `src/periphery/UmiaHook.sol`                   | Hook integration: writes both rings in `beforeSwap`/`beforeAddLiquidity`/`beforeRemoveLiquidity`; exposes `observe()`/`observeLong()`, `oracleStates()`/`coarseOracleStates()`, `getObservation()`/`getCoarseObservation()`, `increaseCardinalityNext()`/`increaseCoarseCardinalityNext()` |
| `src/libraries/TwapMath.sol`                   | `averageTick()` helper with correct rounding for negative averages                                                            |
| `src/libraries/SpotTwapGuard.sol`              | Two-window band check (`withinBands`) and fail-closed predicate shared by `SpotLiquidityVaultV2`, `ActiveLiquidityManager` and the `SpotMigrator` seam |
| `src/core/SpotLiquidityVault.sol`              | Consumer: 30-minute sandwich guard on deposits, withdrawals, and decision-market pull/return; grows both rings at bootstrap    |
| `src/core/SpotLiquidityVaultV2.sol`            | Consumer: V1 guard plus the 6-hour band (`MAX_LONG_TICK_DEVIATION`, 2000 ticks); grows both rings at bootstrap                 |
| `src/periphery/UmiaTwapMilestoneCondition.sol` | Consumer: full-window TWAP query (via `observeLong`) gating MetaVesT vesting milestones                                        |
| `test/launchpad/UmiaLBPOracle.t.sol`           | Oracle integration tests, including coarse-ring servability, gap extrapolation, and segmented-path precision                   |
| `test/periphery/UmiaHook.t.sol`                | Hook unit tests, including coarse-ring bucket gating, ring independence, clamp cadence, and grow gas budget                    |
| `test/markets/DecisionMarketOracleTruncation.t.sol` | Truncation behavior tests                                                                                                 |
