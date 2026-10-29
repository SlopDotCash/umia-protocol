# UmiaMarketCore

Source: `src/core/UmiaMarketCore.sol`

## Purpose

Decision market engine with virtual token accounting.

- Creates markets/proposals.
- Handles split/merge with a minimal virtual-token ledger (`balanceOf`/`transfer` + `LedgerLib`), not full ERC-6909 (no approve/allowance/operator surface).
- Runs per-proposal CPMM markets.
- Settles markets with TWAP-based winner selection.
- Coordinates settlement claims and winning payload execution.

## Key state

- `marketCounter`, `proposalCounter`, `activeUnsettledMarketCount`
- `_markets[marketId]` (`MarketData`), `_proposals[proposalId]` (`ProposalData`): packed structs in `MarketCoreTypes`
- `_pools[proposalId]` (`Pool`: CPMM reserves, accrued protocol fees, user virtual supplies, LP shares)
- `_settle[marketId]` (`SettleAcct`: real venture/money balances, winner + winning TWAP, LP re-add accounting, `settledAt`, `executed`-adjacent flags on `MarketData`)
- `balanceOf[owner][id]`, `totalSupply[id]`: the virtual venture/money + LP-share ledger (`LedgerLib`)
- `proposalToMarket`, `activeMarketByVenture`, `_hasClaimed[marketId][user]`
- `activeManager[marketId]`: the venture's `ActiveLiquidityManager` at `createMarket` (`vault.activeManager()`, read with `try/catch`; zero for V1 vaults). The manager comes from the V2 pool's hook record, written only by the migrator or a factory LBP. Pays no fee on `basketSwapExactOut` only.
- EIP-712 replay state: `marketCreationNonces`, `swapNonces`, `DOMAIN_SEPARATOR`
- Market stake accounting lives in the separate `UmiaMarketStake` contract, not here.

## Important functions

- Market lifecycle:
  - `createMarket`
  - `getMarketStatus`
  - `settleMarket`
  - `claimSettlement`
  - `claimSettlementFor`: redeems a list of holders' winning positions to those holders. Permissionless, so a keeper can clear forgotten claims; skips holders who already claimed or hold nothing
  - `executeWinningProposal`
- Trading/accounting:
  - `split`, `merge`
  - swaps: `swapExactIn`, `swapExactOut`, `splitAndSwapExactIn` (self-custodial), plus `swapExactInWithPermit`, `swapExactOutWithPermit` (EIP-712 relayed)
  - `basketSwapExactOut`: the same fraction of each pool's output reserve in every proposal, no-op included. Every price moves by the same factor, so it is outcome-neutral and the market's `activeManager` trades it fee-free; everyone else pays the normal fee per leg. Reverts with `InvalidAmount` if the fraction is outside `(0, 1e18)` or any leg rounds to zero output
  - `addLiquidity`
- Views:
  - `getProposalTWAP` (Q112, read from the Hub's current oracle), `getPriceX96`, `quoteSwapExactIn`, `marketSettlementState`, `winningProposalByMarketId`

## Access control and checks

- `createMarket` requires an EIP-712 approval from the Hub's `marketCreationSigner` over the params and the creator's nonce; the caller must be `creator` or the Hub owner.
- Swaps are self-custodial: `swapExactIn` / `swapExactOut` move the caller's own virtual tokens. The permit variants recover an EIP-712 signer and consume a per-signer `swapNonces` entry for replay protection.
- The only fee waiver is `basketSwapExactOut` for `activeManager[marketId]`. Replacing the venture's ALM mid-market leaves the old one exempt until the market ends.
- `executeWinningProposal` runs only after `settledAt + executionDelay` (snapshotted from the Hub at creation) and while the Hub's circuit breaker for the market is inactive. It resolves the executor from the hub and requires a non-zero executor if payload execution is needed.

## Important constants

Defined in `MarketCreationLib` (not on `UmiaMarketCore` itself):

- `TRADING_MAX_START_DELAY = 7 days`: start at/before `block.timestamp` clamps to now (no minimum delay)
- `TRADING_MIN_DURATION = 1 hours`
- `TRADING_MAX_DURATION = 96 hours`
- `TRADING_DEFAULT_DURATION = 3 days`: used when `duration == 0`
- `MIN_PROPOSALS = 1`
- `MAX_PROPOSALS = 5`

## Notes

- A no-op proposal is auto-inserted at index 0 for each market.
- 50% of the venture's vault liquidity (`BOOTSTRAP_PULL_BPS = 5000`) is pulled at market creation through `vault.pullForDecisionMarket` and the excess is re-added at settlement through `vault.returnFromDecisionMarket`. The vault is the venture's spot liquidity vault, V1 or V2. Both calls run its spot-vs-TWAP guard (the 30-minute band on V1 and V2; V2 adds a 6-hour band) and fail closed, so `createMarket` and `settleMarket` can revert transiently and are retried.
- Winner threshold comparison uses the Hub's `winningMarketThresholdBps`, snapshotted into the market at creation.
