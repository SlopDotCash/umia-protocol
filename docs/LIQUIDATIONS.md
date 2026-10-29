# Building a Liquidation Proposal

Practical guide for constructing a correct `LIQUIDATE_TREASURY` decision-market
proposal. Liquidation is terminal and irreversible, and two ordering details
decide whether treasury value is distributed **fairly and completely** or is
silently lost. Both are properties of the **execution plan**, not the contracts:
a plan that skips them still executes, just wrongly.

See [GOVERNANCE_TREASURY_LAYER.md](./GOVERNANCE_TREASURY_LAYER.md) for the action
language and encoding. This doc is the liquidation-specific checklist.

## What liquidation does

`LIQUIDATE_TREASURY` (in `GovernanceActions._executeLiquidation`):

1. Redeems the venture's spot-LP shares into the treasury. For a V2 vault it also empties the
   ActiveLiquidityManager (`withdrawAll`). Its basket leftovers in a market only reach it through
   `claimDecisionMarket`, which is permissionless and must be called for every settled market
   before the liquidation executes; anything claimed after liquidation stays in the manager for good.
2. Burns every venture token the treasury now holds (its own balance plus the redeemed LP
   and ALM tokens), then snapshots the pro-rata denominator as `claimableSupply = totalSupply`.
3. Calls `venture.setLiquidator(liquidator)` → sets `liquidationActive = true` (terminal).
4. `ILiquidator(liquidator).initialize(venture, assets, claimableSupply)`.

Holders then `claim()` on the liquidator: it burns the caller's entire venture-token
balance and pays `assetBalance × userBalance / claimableSupply` of each listed asset,
withdrawn straight from the treasury. Assets never move into the liquidator; it
authorizes treasury withdrawals per claim.

## The canonical action ordering

A correct plan is ordered so every state change that must precede the snapshot runs
**before** `LIQUIDATE_TREASURY`, which is always last:

```
CALL → VentureVestingAuthority.terminateGrant(allocation_i)   // one per grant, see §1
...
SET_ALLOWANCE(moneyToken, spender_j, 0)                       // one per live allowance, see §2
...
CALL → vault.redeem(shares, venture, venture) / Pool.withdraw  // one per budget source, see §3
...
CALL → SpotLiquidityVault.withdraw(shares, 0, 0, venture)     // V1 shares a migrated venture still holds, see §4
...
CALL → ActiveLiquidityManager.withdrawAll()                    // V2 ALM; optional, the action empties it too
...
LIQUIDATE_TREASURY(liquidator, assets)                        // always last
```

Once `LIQUIDATE_TREASURY` runs, `liquidationActive` is `true` and the venture is
frozen: `executeCall` (`whenNotLiquidating`) and every vesting-admin path
(`LiquidationActive` guard) revert. Anything you did not do before this action can
never be done. That is why every concern below is a *pre-liquidate* action in the
same atomic plan.

## §1: Terminate vesting/price-milestone grants first

**The hazard.** The snapshot denominator is the post-burn `totalSupply`, which
**includes tokens held by MetaVesT vesting allocation contracts**. Those contracts
cannot call `claim()`, and tokens gated on a **price milestone that was never met**
(and any still-unvested tokens) will never reach a wallet that can claim. Their share
of the treasury is neither delivered to the grantee nor redistributed to claimers. It
is allocated in the denominator and then **stranded in the treasury forever**. The loss
falls entirely on the locked holders; every claimer still receives their exact
pro-rata.

**The fix.** Prepend a `CALL` action per grant that invokes
`VentureVestingAuthority.terminateGrant(allocation)`, ordered before
`LIQUIDATE_TREASURY`. This works on the deployed contracts, no protocol change,
because of two facts that hold only *before* the liquidate action runs:

- A `CALL` action executes via `venture.executeCall(...)`, so `msg.sender` reaching
  the vesting authority is the **venture itself**, and `_requireVestingAdmin` allows
  `msg.sender == treasury`. (`executeCall`'s `whenNotLiquidating` is also still
  satisfied.)
- `liquidationActive` is still `false`, so the authority's `LiquidationActive` guard
  does not trip.

`terminateGrant` keeps each grantee's **earned (vested)** portion in their allocation
and claws the **unearned** portion (unvested time plus unmet price milestones,
evaluated at the liquidation instant) back to the treasury via `_sweep`. The
liquidate action then burns them with the rest of the treasury's balance, so the
snapshot **excludes them automatically**. No new denominator logic.

Result: unearned performance forfeits, earned holders keep exactly what they earned,
claimers split the treasury with no dilution, and nothing strands.

**Notes.**
- Enumerate a venture's grants from the vesting authority's indexed
  `AllocationFunded(controller, allocation, beneficiary, …)` events.
- Grantees still `claim()` for their **earned** share: they withdraw the vested tokens
  from their allocation to a wallet, then call `claim()`. The plan handles the
  *exclusion* of the unearned part; collecting the earned part is the holder's action
  (their allocation withdrawal is not blocked by liquidation; only the admin
  terminate path is).
- One `CALL` per grant: plan size and execution gas scale with grant count. Fine for
  tens of grants; batch or add a terminate-all helper if a venture has hundreds.

## §2: Zero every live treasury allowance first

**The hazard.** `setLiquidator` only flips the terminal flag; it does **not** revoke
standing ERC20 approvals, and after it runs they can no longer be cleared. Any spender
still approved on a claim-backing asset can `transferFrom` the treasury **after** the
snapshot and drain assets that claimants are owed.

**The fix.** Prepend a `SET_ALLOWANCE(token, spender, 0)` action for **every live
allowance** on each distributable asset (the money token, plus any other listed
treasury asset) and on the venture token, ordered before `LIQUIDATE_TREASURY`. Zero
the venture-token allowances too, so no spender can move the treasury's venture tokens
before the action burns them.

**Notes.**
- ERC20 allowances are not enumerable on-chain. Build the spender set from the indexed
  `AllowanceSet(token, spender, amount)` events, plus any known integrations (vault,
  market stake, market core, executor, Permit2 / position manager / router). Check that
  set on the claim tokens and the venture token. Treat it as best-effort: one live
  allowance left open can drain claims.
- Never list the **venture token** as a distributable asset. It is the claim-burn
  token; the liquidator skips it (paying it out pro-rata would let a claimant forward
  the payout and claim again).

## §3: Unwind budget sources first

`SET_ALLOWANCE_SOURCE` lets the treasury hold its cash as Aave aTokens, other stablecoins or
ERC-4626 vault shares. The liquidator snapshots `balanceOf` once at `initialize` and pays fixed
pro-rata amounts, so those holdings must be listed as liquidation assets to be distributed at all,
and two of them distribute badly:

- A rebasing token (aUSDC) keeps growing after the snapshot; the growth is stranded forever, and
  an exact-amount transfer that lands a wei short can revert the last claimant.
- ERC-4626 shares distribute correctly as shares, but claimants receive shares they must redeem
  themselves, paying any vault exit cost or illiquidity.

To build the unwind, fold the venture's `AllowanceSourceSet` log into the live set, derive an
Aave withdrawal from the aToken's own `POOL()`, redeem an ERC-4626 vault's full share balance, and
list a plain pegged stablecoin as a liquidation asset instead of unwinding it.

Unwind every source back to the underlying before the snapshot, in the same plan:
`CALL(Pool, 0, withdraw(USDC, type(uint256).max, venture))` for Aave,
`CALL(vault, 0, redeem(vault.balanceOf(venture), venture, venture))` for a vault, then list the
underlying in `assets`. Other pegged stablecoins can simply be listed as their own asset.
Enumerate active sources from the indexed `AllowanceSourceSet` events.

## §4: Redeem leftover V1 vault shares first

The action redeems the venture's shares in the Hub's current vault only. A venture migrated to V2
may still hold shares in its old `SpotLiquidityVault`: a donation made after the migration
proposal was written, or an under-sized migration proposal. Add
`CALL → oldVault.withdraw(shares, 0, 0, venture)` before `LIQUIDATE_TREASURY` so those tokens
are burned and distributed with the rest. There is no automatic sweep.

## Plan size

A plan is capped at 20 actions (`GovernancePayloadValidator.validatePlanV1` reverts
`TooManyActions` above that), so a venture with many grants, approvals or sources must clear
some of them in an earlier proposal.

## Ordering rule of thumb

> Everything that must be true at the snapshot has to happen **before**
> `LIQUIDATE_TREASURY`, in the same atomic plan. After it, the venture is frozen.
> Terminate grants, zero allowances, unwind budget sources, redeem leftover V1 shares,
> then liquidate. Always in that order, liquidate last.
