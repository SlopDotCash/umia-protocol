# Smart Contracts Security Notes

This file summarizes security-relevant behavior in the current contracts.
It is not a replacement for a full audit.

## Threat model (high level)

Key trust assumptions in the current design:

- `UmiaHub.owner()` is trusted to set critical registry pointers and parameters:
  - market core and market stake
  - default and per-venture governance executor
  - conditional market oracle
  - LBP strategy factory, CCA factory, venture beacon
  - market creation signer
  - spot migrator and active liquidity keeper
  - fee recipient and fee rates, execution delay, veto guardian, vesting admin
- `marketCreationSigner` is trusted to approve market definitions via EIP-712 signatures.
- Winning proposal execution can perform powerful treasury actions (including arbitrary external calls).

## Critical invariants

## 1) Split/merge solvency invariant

`UmiaMarketCore` enforces an internal invariant after split/merge:

- `totalRealVenture >= maxUserVirtualVentureSupply`
- `totalRealMoney >= maxUserVirtualMoneySupply`

where `totalReal*` includes user-deposited backing plus initial LP liquidity removed during market creation.

This invariant is central to settlement safety.

## 2) Single claim per user per market

`hasClaimed[marketId][user]` prevents duplicate settlement claims.

## 3) Single execution per market

`marketExecuted[marketId]` gates repeat execution of winning proposal payloads.

## 4) Liquidation terminal behavior

In `Venture`, `liquidationActive` blocks treasury mutation functions via `whenNotLiquidating`. Claims are handled by an external `ILiquidator` contract set via `venture.setLiquidator()`.

## Access control surfaces

### UmiaHub (`Ownable`, UUPS)

Owner-only setters control protocol pointers, fee parameters and token approvals; the owner is also the upgrade key.
Compromise impact: broad protocol control.

### UmiaMarketCore

- Swaps are self-custodial; the permit variants recover an EIP-712 signer and consume a per-signer `swapNonces` entry for replay protection.
- Market creation requires valid signer signature and nonce.
- Winning proposal execution uses executor resolved from hub.

### GovernanceExecutor

- Only the current market core may call `executeProposal`.
- Executor must match `HUB.governanceExecutor(venture)`.
- Plan version and action versions are strictly checked.

### Venture

Privilege tiers:
- `onlyHub`: initialization and hub-level operations.
- `onlyExecutor`: mint and burn (both blocked while liquidating), withdraw (the `authorizedLiquidator` instead once liquidation is active, which also alone may `burnFrom`), arbitrary call, team member updates, allowance updates, document uploads, liquidation setup (`setLiquidator`).

## High-risk capabilities to review

1. **Arbitrary call action (`CALL`)**
   - Governance payload can call arbitrary target/value/data through `Venture.executeCall`.
   - Powerful by design; increases blast radius of malicious governance outcomes.

2. **Registry pointer updates in hub**
   - Changing executor/oracle/market core/spot migrator can materially alter system behavior.

3. **Market creation signer compromise**
   - Could approve malicious market definitions and payloads.

4. **LP liquidity operations**
   - `createMarket` pulls 50% of the venture's spot vault liquidity (`pullForDecisionMarket`); settlement returns the excess (`returnFromDecisionMarket`). Both run under the vault's TWAP guard.
   - Arithmetic and slippage protections are security-critical.

5. **Liquidation setup**
   - Liquidation is terminal and snapshots balances/supply.
   - Ensure governance process around liquidation is strict.

## Reentrancy and external calls

- `UmiaMarketCore` uses `ReentrancyGuard` on every state-changing entrypoint (market creation, split/merge, swaps and baskets, settlement, claims, execution).
- `GovernanceExecutor` uses `ReentrancyGuard`.
- `Venture` uses `ReentrancyGuard` on transfer/call sensitive methods.
- External call paths include:
  - token transfers,
  - Uniswap helper interactions,
  - `Venture.executeCall` arbitrary targets.

## Oracle manipulation protections

### Spot pool (UmiaHook)

- **Elapsed-time truncated TWAP**: The accepted tick slews toward the pool tick at no more than 4,558 ticks/second (9,116 ticks over a normal two-second Base block), with the ramp and recovery path integrated exactly. Extra writes cannot ratchet the filter faster, and a restored price recovers during quiet time instead of leaking a stale clamped tick across the gap.
- **Operator-only, full-range liquidity enforcement**: `beforeAddLiquidity` and `beforeRemoveLiquidity` reject any caller other than the pool's registered operator (the venture's `SpotLiquidityVault`), and any position that isn't full-range (`minUsableTick` to `maxUsableTick`). Concentrated liquidity would create zero-liquidity tick gaps exploitable for cheap tick manipulation. `UmiaHookV2` adds a second operator per pool: the `activeOperator` (the venture's `ActiveLiquidityManager`) may add any range on top of the anchor vault's full-range position, and removals are not gated. No tick has zero liquidity while the anchor is funded.
- **Spot-vs-TWAP sandwich guard**: `SpotLiquidityVault._requireSpotWithinTwapDeviation` compares the current spot tick against the 30-minute TWAP tick (`TWAP_WINDOW`) and reverts with `SpotPriceDeviationTooHigh` beyond `MAX_TICK_DEVIATION` (1000 ticks, ~10.5%). It runs on deposits, withdrawals, decision-market creation, and settlement. V2 also rejects spot more than `MAX_LONG_TICK_DEVIATION` (2000 ticks, ~22%) from the 6-hour TWAP of the coarse ring (`SpotTwapGuard.withinBands`, shared with the migrator seam, which uses 300 ticks over 6 hours, and the ALM, which uses 500 ticks over 12 hours), since a price held for 30 minutes passes the short window on its own. It fails closed until the coarse ring covers six hours. Fail-closed: if the oracle holds fewer than 2 observations or cannot serve the full window (e.g. buffer exhausted by dust swaps), it reverts with `InsufficientOracleHistory` rather than silently allowing the operation. The only skip is an empty position (`currentLiquidity() == 0`), which has no reserves to sandwich and must stay open so a drained vault can be re-bootstrapped.
- **Oracle buffer sizing**: `afterInitialize` seeds cardinality 1 and `bootstrapFromLBP` grows it to 100 slots. At one observation per block that covers only ~200s on Base, short of the 30-minute window, so busy pools should be grown to at least 1,000 slots via the permissionless `increaseCardinalityNext()`. Combined with the fail-closed guard, buffer exhaustion blocks operations rather than bypassing them. See [SPOT_ORACLE.md](SPOT_ORACLE.md).

### Decision markets (ConditionalMarketOracle)

- **Elapsed-time tick slew**: Same mechanism as the spot oracle (`TickSlew`) at a far lower rate: the accepted tick moves toward the pool's tick at no more than 7 ticks/second (420 ticks, about 4.3%, per minute; faster only on markets shorter than a few hours), and the ramp and hold are integrated exactly. A crash or pump is credited only as fast as the slew allows, so moving a two-day settlement average by the 2% threshold takes a hold of about 52 minutes in the open rather than a few minutes at the end of the window, and once trading stops the accepted tick settles on the pool's real tick. The TWAP is the mean tick (a geometric mean), so the winning threshold is a fixed tick offset applied identically to every proposal.
- **Overflow-free reads**: The pool tick is computed from the reserve ratio with `FullMath.mulDiv`, saturating before any product can overflow and clamping to the V4 tick range, so no reserve pair can make an update or settlement read revert.
- **Trading-start anchor**: The TWAP is anchored at `tradingStart` (with a zero cumulative baseline) by a one-shot `initialize` at market creation, immutable thereafter. No price before trading start affects the average.
- **Swappable implementation**: The oracle is resolved through the Hub registry on every call and its `initialize`/`update`/`calculateTWAP` interface carries the market's winning threshold, so a hardened implementation can replace this one via `hub.setConditionalMarketOracle()` without touching `UmiaMarketCore`.
- **Trading-end freeze**: Oracle timestamps are capped at `tradingEnd` via `_effectiveTimestamp()`. After trading ends, `update()` stops accumulating and `calculateTWAP()` returns a fixed value. This prevents settlement delay from diluting the TWAP or extending the influence of last-block manipulation.
- **Settlement oracle update**: Oracle is updated at settlement time to include the final price observation before TWAP computation.

## Known operational considerations

- No protocol-wide pause mechanism is present in current code. The Hub's per-market circuit breaker (`tripDecisionMarketCircuitBreaker`, owner or `vetoGuardian`) blocks only `executeWinningProposal`; the ALM has its own `setPaused`.
- `UmiaMarketCore.executeWinningProposal` runs only after `executionDelay` from settlement (`UmiaHub.decisionMarketExecutionDelay`, default 4 hours, max 12 hours), the window in which the circuit breaker can veto it.
- Oracle correctness depends on market-core-triggered updates around swaps/settlement.
- Permit/nonces are per-contract and need replay protection monitoring.

## Recommended review focus for auditors

1. Market accounting and solvency proofs (`split`, `merge`, `settleMarket`, `claimSettlement`).
2. Governance payload decoding/dispatch correctness (`GovernanceExecutor`, `GovernancePayloadValidator`, `GovernanceActions`).
3. Access control and pointer trust model (`UmiaHub`, `Venture` modifiers).
4. Uniswap v4 integration assumptions in LP removal/re-add flow.
5. Liquidation state transitions and proportional payouts.

## Related docs

- `DECISION_MARKET_FLOW.md`
- `GOVERNANCE_TREASURY_LAYER.md`
- `UPGRADES.md`
- `docs/contracts/` references
