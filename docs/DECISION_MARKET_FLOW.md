# Decision Market Flow

## Overview

Umia decision markets allow communities to make decisions through a futarchy mechanism. Market participants trade conditional tokens representing different proposals, and the proposal with the highest price (relative to a threshold) becomes the winning decision.

## Architecture Context

### Ventures

A venture is an entity that:

- Has its own token (e.g., "AliceVenture" token)
- Maintains a spot market on Uniswap V4 for its token
- The venture's spot liquidity vault, V1 `SpotLiquidityVault` or V2 `SpotLiquidityVaultV2` (registered on the Hub as `ventureLiquidityVault`), holds the canonical spot liquidity for the main DEX pair: **venture Token / Money Token** (e.g., AliceVenture/USDC)
- This spot market determines the real-time price of the venture token

### Conditional Markets

Decision markets create **conditional markets** for each proposal:

- Each proposal has its own CPMM (Constant Product Market Maker) using Uniswap V2 logic
- Uses virtual tokens on a minimal in-contract ledger (`balanceOf`/`transfer`, ERC6909-style IDs, no approvals) instead of separate ERC20 contracts for gas efficiency
- Virtual tokens represent conditional claims: "If this proposal wins, I get X tokens"
- Prices in conditional markets reflect market sentiment about each proposal's impact on the venture token value

### Two Market Types

1. **Spot Market (Uniswap V4)**: The real venture token trades against money (USDC) - this is the actual price discovery mechanism
2. **Conditional Markets (CPMM)**: Virtual tokens trade within each proposal's pool - these are prediction markets that determine which proposal wins

## Token Flow Model: Split/Merge

The system uses a **split/merge model** inspired by conditional token markets such as Gnosis:

### Split Operation

When a user **splits** real tokens:

1. User deposits real tokens (venture and/or Money) into the contract
2. User receives virtual tokens **for ALL proposals** at 1:1 ratio
3. Real tokens are tracked in `realVentureBalance` and `realMoneyBalance`

```
User deposits 100 USDC
→ User receives:
  - 100 virtualMoney in Proposal 1 (no-op)
  - 100 virtualMoney in Proposal 2
  - 100 virtualMoney in Proposal 3
  - ... (for all proposals)
```

### Merge Operation

When a user **merges** virtual tokens:

1. User must have equal amounts of virtual tokens **in ALL proposals**
2. User burns virtual tokens from all proposals
3. User receives real tokens back at 1:1 ratio

```
User merges 50 virtualMoney
→ Burns 50 virtualMoney from Proposal 1
→ Burns 50 virtualMoney from Proposal 2
→ Burns 50 virtualMoney from Proposal 3
→ User receives 50 USDC
```

### Why Split/Merge?

This model ensures **solvency** at all times:

- The contract only needs to pay out the winning proposal's virtual tokens
- Since users must split equally across all proposals, the real token backing is always sufficient
- **Invariant**: for every proposal, `realVentureBalance` covers `userVirtualVentureSupply` plus the pool's venture reserve and accrued venture fees, and `realMoneyBalance` does the same for `userVirtualMoneySupply` (see [Invariant & Solvency Guarantee](#invariant--solvency-guarantee))

## End-to-End Flow

### Stage 1: Market Creation (Before Opening)

**Actor**: Market creator/staker, or the Hub owner on their behalf. Either way `createMarket` carries an EIP-712 approval from the Hub's `marketCreationSigner`.

**Actions**:

1. Alice creates a venture with an initial spot market on Uniswap V4
2. Alice creates a decision market with multiple proposals
3. The system pulls 50% of the liquidity in the venture's spot liquidity vault, V1 or V2, from the spot AMM (`vault.pullForDecisionMarket`). The vault's TWAP guard reverts while spot sits outside the 30-minute band, or on V2 the 6-hour band as well, and the call is retried
4. The removed tokens initialize CPMM pools for each proposal (including a "no-op" proposal)

**Example**:

- Alice creates "AliceVenture" with 1,000,000 tokens and $500 USDC seed liquidity
- Alice creates market: "Should we cut yearly emissions?"
  - Proposal 1: "No-op" (default, do nothing)
  - Proposal 2: "Cut emissions by 10%"
  - Proposal 3: "Cut emissions by 15%"
- System removes 50% of the vault's current liquidity from the spot AMM
- Each proposal gets a CPMM initialized with these amounts as virtual tokens
- The contract holds these virtual tokens (minted to `address(this)`) as initial CPMM reserves
- The market's `SettleAcct` (`ventureRemoved`, `moneyRemoved`, `liquidityRemoved`; read via `marketSettlementState`) tracks the removed amounts for later accounting, and the seed is folded into `realVentureBalance` / `realMoneyBalance`

**State**:

- Market status: `PENDING`
- Trading not yet open
- CPMM pools initialized with equal reserves for all proposals
- `proposalToMarket` mapping set for each proposal

### Stage 2: Market Opening & Splitting

**Actor**: Traders (e.g., Bob)

**Actions**:

1. Market opens at `tradingStart` (at/before now → immediate; otherwise up to `TRADING_MAX_START_DELAY` = 7 days out)
2. Traders call `split()` to deposit real tokens and receive virtual tokens for ALL proposals
3. Traders can now trade in the conditional markets

**Example**:

- Market can open immediately or up to 7 days after creation; trading runs for a per-market duration (1h–96h, default 3 days)
- Bob calls `split(marketId, 0, 1000e6)` to deposit 1,000 USDC
- Bob receives virtual tokens for all proposals:
  - 1,000 virtualMoney in Proposal 1 (no-op)
  - 1,000 virtualMoney in Proposal 2
  - 1,000 virtualMoney in Proposal 3

**State**:

- Market status: `OPEN`
- `realMoneyBalance[marketId]` increased by 1,000 USDC
- `userVirtualMoneySupply[proposalId]` increased for each proposal
- Traders have virtual tokens for all proposals

### Stage 3: Trading Period

**Actor**: Traders

**Actions**:

1. Traders swap virtual tokens within proposal CPMMs using `swapExactIn()` or `swapExactOut()`
2. Swaps transfer tokens between user and CPMM reserves (no minting/burning)
3. `userVirtualVentureSupply` and `userVirtualMoneySupply` are updated on each swap
4. Higher prices indicate market confidence in that proposal
5. Trading continues until `tradingEnd` (the market's duration, 3 days by default)

**Key Mechanism**: When a user swaps:

- Input tokens transfer FROM user TO contract (CPMM reserves)
- Output tokens transfer FROM contract (CPMM reserves) TO user
- Total supply remains constant - tokens just move between parties
- `userVirtualVentureSupply` and `userVirtualMoneySupply` adjust to track how much users hold vs CPMM reserves

**Example**:

- Bob believes Proposal 2 will win
- Bob swaps 100 virtualMoney for ~95 virtualVenture in Proposal 2
  - `userVirtualMoneySupply[proposal2]` decreases by 100
  - `userVirtualVentureSupply[proposal2]` increases by 95
  - CPMM reserves adjust accordingly
- After trading:
  - Proposal 1 (no-op): Price = 0.5 (unchanged)
  - Proposal 2: Price = 0.6 (increased due to buying pressure)
  - Proposal 3: Price = 0.55

**Optional**: Traders can call `merge()` to exit positions early by burning equal amounts from all proposals.

**Basket swaps**: `basketSwapExactOut(marketId, zeroForOne, outFractionWad, amountInMaxPerLeg, deadline)` runs one exact-output swap in every proposal, no-op included, each taking the same fraction of its pool's output reserve. Every proposal's price moves by the same factor, so it realigns the market with spot while every ratio between proposals, and therefore the settlement comparison, stays unchanged. Anyone may call it and pays the normal fee on every leg. The market's `activeManager` (the venture's `ActiveLiquidityManager`, snapshotted at `createMarket`) pays no fee, but only through this function; its ordinary swaps pay in full. The ALM uses it for basket arbitrage against spot; see [ActiveLiquidityManager](contracts/ActiveLiquidityManager.md).

**State**:

- Market status: `OPEN`
- CPMM reserves change based on trades
- `userVirtualVentureSupply` and `userVirtualMoneySupply` track user holdings per proposal
- Prices reflect market sentiment

### Stage 4: Market Resolution

**Actor**: Anyone (typically a bot or keeper)

**Actions**:

1. After `tradingEnd`, anyone can call `settleMarket()`
2. System reads each proposal's TWAP from the `ConditionalMarketOracle` (Q112, frozen at `tradingEnd`)
3. System finds the proposal with the highest TWAP
4. System compares the highest TWAP vs the no-op TWAP
5. If the delta >= the market's `winningThresholdBps` (snapshotted from the Hub at creation), that proposal wins; otherwise no-op wins
6. System calculates how much users need for claims: the winning proposal's `userVirtualVentureSupply` and `userVirtualMoneySupply` plus the collective LP-share claim (`_previewCollectiveUserLiquidityClaim`), and reserves the winning pool's protocol fees
7. System calculates excess tokens that can go back to LP
8. System returns the excess to the venture's spot liquidity vault, V1 or V2 (`vault.returnFromDecisionMarket`), which re-adds it to the spot AMM under its TWAP guard. The guard can revert `settleMarket`; it is permissionless and retried
9. Winning proposal and TWAP stored in `_settle[marketId]` (read via `winningProposalByMarketId`)

**Settlement Accounting**:

```
// Venture side (seed escrow is already folded into the real balance)
totalRealVenture = realVentureBalance - winningPoolProtocolFeeVenture
ventureClaims    = userVirtualVentureSupply[winningProposalId] + collectiveLpVentureClaim   // _previewCollectiveUserLiquidityClaim
excessVenture    = totalRealVenture > ventureClaims + 1 ? totalRealVenture - ventureClaims - 1 : 0

// Money side, same shape
totalRealMoney   = realMoneyBalance - winningPoolProtocolFeeMoney
moneyClaims      = userVirtualMoneySupply[winningProposalId] + collectiveLpMoneyClaim
excessMoney      = totalRealMoney > moneyClaims + 1 ? totalRealMoney - moneyClaims - 1 : 0
```

The excess (after reserving for user claims) goes back to the vault's Uniswap V4 position.

**Example**:

- Trading ends
- Final prices: Proposal 3 has highest price at 0.7
- Price delta vs no-op: 40% (exceeds 2% threshold)
- Proposal 3 wins
- System reserves tokens for user claims, re-adds excess to LP

**State**:

- Market status: `ENDED` (implicit, based on timestamp)
- Winning proposal stored
- Excess liquidity restored to spot AMM

### Stage 5: Settlement Claims

**Actor**: Traders

**Actions**:

1. Traders call `claimSettlement(marketId)` (after settlement), or anyone calls `claimSettlementFor(marketId, users)` to redeem on their behalf (tokens always go to the holder; holders already claimed or with nothing to redeem are skipped)
2. System checks `_hasClaimed[marketId][user]` to prevent double claims
3. System redeems the trader's LP shares in the winning proposal, then reads their balances in the **winning proposal only**
4. System burns ALL virtual tokens in winning proposal
5. System transfers real tokens 1:1 (guaranteed solvent by invariant)
6. System marks user as claimed

**Example Scenarios**:

**Scenario A: Bob traded in losing proposal**

- Bob's balances in Proposal 3 (winner):
  - 0 virtualVenture
  - 1,000 virtualMoney (never traded in winning proposal)
- Bob claims: Receives 1,000 USDC
- Bob's trades in Proposal 2 (loser) don't matter

**Scenario B: Charlie traded in winning proposal**

- Charlie's balances in Proposal 3 (winner):
  - 300 virtualVenture (bought by swapping virtualMoney)
  - 700 virtualMoney (original 1000 - 300 swapped)
- Charlie claims: Receives 300 venture tokens + 700 USDC
- Charlie's bet on Proposal 3 paid off

**State**:

- `_hasClaimed[marketId][user]` = true
- Virtual tokens burned
- Real tokens distributed

## Invariant & Solvency Guarantee

The system checks a critical invariant after every split and merge (`_checkInvariant`), per proposal and per token:

```solidity
realVentureBalance >= userVirtualVentureSupply + cpmmReserve0 + accruedFeeVenture
realMoneyBalance   >= userVirtualMoneySupply   + cpmmReserve1 + accruedFeeMoney
```

This guarantees that:

1. The contract always has enough real tokens to pay ALL claims
2. Only ONE proposal wins, so only that proposal's virtual tokens are claimed
3. Split adds to all proposals equally; merge removes from all equally
4. Swaps only redistribute tokens, don't create new ones

## Key Design Principles

1. **Split/Merge Model**: Users split real tokens into virtual tokens across all proposals, can merge back at any time
2. **1:1 Redemption**: Virtual tokens in the winning proposal are redeemed 1:1 for real tokens
3. **Only Winning Proposal Matters**: Balances in losing proposals are irrelevant for claims
4. **Solvency Invariant**: Real token backing always covers worst-case claims
5. **No-Op Default**: If no proposal meets the threshold, the no-op proposal wins
6. **Single Claim**: `_hasClaimed` mapping prevents double-claiming
7. **Constant Supply**: Swaps directly manipulate balances to move tokens between users and CPMM reserves (no supply change)

## Price Calculation

Prices are calculated as: `price = reserve1 / reserve0` (virtualMoney per virtualVenture)

- Higher price = market thinks proposal will increase venture value
- Spot price in Q96 format: `priceX96 = (reserve1 * 2^96) / reserve0` (`getPriceX96`)
- Settlement uses each proposal's TWAP in Q112 format (`getProposalTWAP`), a time-weighted geometric mean over the trading window
- Price delta: `deltaBps = ((highestTWAP - noOpTWAP) * 10,000) / noOpTWAP`

## CPMM Mechanics

- Uses constant product formula: `x * y = k`
- Swap fee of `decisionSwapFeeBps` (Hub default 1%), snapshotted per market at creation. The protocol keeps `decisionProtocolFeeCutBps` of it (default 50%), collected after settlement from the winning pool; the rest stays in the pool reserves
- Slippage protection via `amountOutMin` / `amountInMax`
- Price impact protection via `maxPriceImpactBps`
- Users can add liquidity to CPMMs (reduces `userVirtualVentureSupply` and `userVirtualMoneySupply`)

## Gas Efficiency

- Uses a minimal ERC6909-style ledger instead of separate ERC20 contracts for virtual tokens
- Custom CPMM instead of full Uniswap V4 pools for conditional markets
- Single contract manages all proposals and markets
