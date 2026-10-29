# Certora Formal Verification

Formal verification specs for Umia's core contracts using the [Certora Prover](https://www.certora.com/).

```
certora/
├── conf/                          # Prover configuration
│   ├── CPMM.conf
│   ├── MarketCore.conf
│   └── StateMachine.conf
├── harness/                       # Wrapper contracts exposing internals
│   ├── CPMMHarness.sol
│   └── MarketCoreHarness.sol
└── specs/                         # CVL specification files
    ├── CPMM.spec
    ├── MarketCore.spec
    └── StateMachine.spec
```

## Prerequisites

1. Install the prover CLI (`pip install certora-cli`) and set your key: `export CERTORAKEY=<your-key>`
2. Have `solc` 0.8.26 installed and available in `PATH`

## Running

From the project root:

```bash
certoraRun certora/conf/CPMM.conf            # CPMM math invariants
certoraRun certora/conf/MarketCore.conf      # Solvency, settlement, claims
certoraRun certora/conf/StateMachine.conf    # Market lifecycle transitions
```

Each conf compiles its harness with `via-ir`, bounds loops (`loop_iter`), and names the spec to
verify. Results appear on the [Certora Prover dashboard](https://prover.certora.com/).

## Specs

32 rules and 2 invariants in total.

### `CPMM.spec`: AMM math (11 rules, 1 invariant)

Target: `CPMMHarness.sol` wrapping `src/libraries/CPMM.sol`

| Rule                                       | Property                                                          |
| ------------------------------------------ | ----------------------------------------------------------------- |
| `constantProductNeverDecreases_exactIn`    | `k` never decreases after a swap (fees make it grow)              |
| `constantProductNeverDecreases_exactOut`   | Same for exact-output swaps                                       |
| `outputAlwaysLessThanReserve`              | Swap output is strictly less than the output reserve              |
| `swapExactInOutputMonotonicity`            | Larger input produces larger or equal output                      |
| `getAmountOutNeverExceedsReserve`          | Pure math: `_getAmountOut < reserveOut`                           |
| `getAmountInRoundTrip`                     | `getAmountIn → getAmountOut` round-trip within rounding tolerance |
| `feeIsAlwaysCollected`                     | Output with fee is strictly less than no-fee output               |
| `swapPreservesReserveDirectionality`       | zeroForOne increases reserve0, decreases reserve1                 |
| `priceImpactBounded`                       | Price impact is in `[0, 10000]` bps                               |
| `addLiquidityPreservesPrice`               | Price ratio preserved after liquidity addition (within rounding)  |
| `addLiquidityIncreasesReserves`            | Both reserves non-decreasing after liquidity addition             |
| **Invariant:** `reservesPositiveAfterInit` | Once both reserves are positive, they stay positive               |

### `MarketCore.spec`: solvency and settlement (11 rules, 1 ghost invariant)

Target: `MarketCoreHarness.sol` extending `src/core/UmiaMarketCore.sol`

| Rule                                              | Property                                                                     |
| ------------------------------------------------- | ---------------------------------------------------------------------------- |
| `solvencyInvariantHoldsAfterSplit`                | `_checkInvariant` passes after split                                         |
| `solvencyInvariantHoldsAfterMerge`                | `_checkInvariant` passes after merge                                         |
| `splitMergeNetZero`                               | Split then merge same amounts restores real balances                         |
| `splitExactSupplyChange`                          | Split increases supply by exact amount for market proposals, zero for others |
| `noDoubleClaim`                                   | Second claim reverts                                                         |
| `claimBurnsVirtualTokens`                         | User's virtual token balance is zero after claim                             |
| `claimSetsFlag`                                   | The claimed flag is true after a successful claim                            |
| `virtualSupplyConservationOnSwap`                 | CPMM reserves + user supply constant through swaps                           |
| `totalSupplyTracksOnSplit`                        | `totalSupply` non-decreasing after split                                     |
| `settleOnlyOnce`                                  | Settling an already-settled market reverts                                   |
| `executeOnlyOnce`                                 | Executing an already-executed market reverts                                 |
| **Ghost invariant:** `totalSupplyIsSumOfBalances` | `totalSupply[id] == Σ balanceOf[user][id]` for all users                     |

The ghost variable `sumOfBalances` is maintained by an `Sstore` hook on `balanceOf` and independently verifies that the contract's `totalSupply` counter matches actual token holdings.

### `StateMachine.spec`: market lifecycle (10 rules)

Target: `MarketCoreHarness.sol`

| Rule                       | Property                                                       |
| -------------------------- | -------------------------------------------------------------- |
| `splitOnlyWhenOpen`        | `split` reverts when market is not OPEN                        |
| `mergeOnlyWhenOpen`        | `merge` reverts when market is not OPEN                        |
| `settlementOnlyWhenEnded`  | `settleMarket` reverts when market is not ENDED                |
| `claimOnlyWhenSettled`     | `claimSettlement` reverts when market is not settled           |
| `marketCounterMonotonic`   | Market counter never decreases (parametric over all functions) |
| `proposalCounterMonotonic` | Proposal counter never decreases                               |
| `hasClaimedMonotonic`      | The claimed flag never goes from true to false                 |
| `marketExecutedMonotonic`  | `marketExecuted` never goes from true to false                 |
| `settlementMonotonic`      | Winning proposal ID never changes once set                     |
| `addLiquidityOnlyWhenOpen` | `addLiquidity` reverts when market is not OPEN                 |

## Assumptions (NONDET summaries)

External calls are summarized as `NONDET`: the prover assumes they succeed and return an arbitrary value. These specs therefore verify **internal accounting invariants**, not integration correctness.

| Summary                                                                   | Rationale                                                                                                      |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `safeTransfer` / `safeTransferFrom`                                       | Umia uses standard ERC20 tokens vetted at venture creation. Fee-on-transfer and rebasing tokens are out of scope. |
| `update`, `initialize`, `calculateTWAP`                                   | `ConditionalMarketOracle` interactions. Specs focus on accounting, not oracle correctness.                     |
| `conditionalMarketOracle`                                                 | Hub registry lookup. Access control is not verified (the prover can pick any address).                         |
| `ventureById`, `ventureTokenById`, `ventureMoneyTokenById`                | Hub registry. Token addresses are arbitrary in the prover.                                                     |
| `winningMarketThresholdBps`, `decisionMarketCircuitBreakerActive`, `governanceExecutor` | Protocol parameters. Specs verify accounting holds for any parameter values.                        |

## Coverage gaps

- **Vault liquidity pull and return**: `MarketCreationLib` seeds a market with
  `vault.pullForDecisionMarket(marketId, BOOTSTRAP_PULL_BPS)` and `SettlementLib` hands the
  remainder back with `vault.returnFromDecisionMarket(marketId, ventureAmount, moneyAmount)`. The
  vault and its Uniswap V4 position are not modelled, so a return that lands less than expected is
  outside the specs.
- **Ghost scope**: only `totalSupply == Σ balanceOf` is implemented. Ghosts for
  `userVirtualSupply == Σ balanceOf` (per proposal) and full conservation
  (`reserve + Σ user balances == constant`) are deferred to avoid prover performance degradation.
- **Swap access control**: `swapExactIn` / `swapExactOut` (and their permit variants) are open to
  any caller, so there is no sender check to verify. The only sender-specific swap rule, the
  `activeManager` fee exemption below, is not covered.

## Known gaps

Not covered by any spec:

- `basketSwapExactOut`, the per-proposal basket trade used for arbitrage against spot.
- The `activeManager` fee exemption: `basketSwapExactOut` charges no fee when
  `msg.sender == activeManager[marketId]`, the manager snapshotted from the venture's V2 vault at
  market creation.
- The V2 spot liquidity paths: `SpotLiquidityVaultV2`, `ActiveLiquidityManager` and `SpotMigrator`
  have no harness or spec.

The harness and specs predate the current `UmiaMarketCore` storage layout.
`certora/harness/MarketCoreHarness.sol` indexes `cpmmStates[...]`, `hasClaimed[...]`,
`userVirtualVentureSupply[...]`, `realVentureBalance[...]`, `marketExecuted[...]` and
`liquidityRemovalInfo[...]` as public storage, while the core now keeps that state in `_pools`,
`_hasClaimed` and `_settle` behind view functions (`cpmmStates(uint256)`,
`userVirtualVentureSupply(uint256)`, `marketExecuted(uint256)`). The spec method blocks also
declare `routerSwapExactIn` / `routerSwapExactOut` and summarise `swapRouter()` and
`circuitBreakerActive(uint256)`, none of which exist any more (there is no router, and the Hub
read is `decisionMarketCircuitBreakerActive(uint256)`). The harness and the method blocks must be
updated to the current MarketCore storage and surface before the suite runs again.
