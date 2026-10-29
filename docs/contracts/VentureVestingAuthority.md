# VentureVestingAuthority

Source: `src/periphery/VentureVestingAuthority.sol`

## Purpose

A per-venture adapter that holds a [MetaVesT](../metavest/README.md) controller's
`authority` role and routes it to the venture treasury, so that **after launch only futarchy can
create / amend / terminate vesting allocations** (terminations may also come from the Hub's
`vestingAdmin`, see Grant administration below). The launch operator (ADMIN) deploys it before the
venture exists, hands the controller authority to it **before genesis grants**, funds each grant via
`fundGenesisGrant`, closes genesis with `closeGenesis`, and binds it to the treasury after launch.
The Hub owner then records it with `UmiaHub.setVentureVestingAuthority`: the MetaVesT factory is
permissionless, so that record is what makes this adapter's grants the venture's.

It exists to bridge a timing gap: at genesis the treasury does not exist yet, but ADMIN must already
be out of the authority seat before the venture goes live. The adapter can accept the authority role
immediately (it is a plain contract) and resolve its treasury later, once the venture is created.

The adapter is **also the per-allocation price-milestone registry**. A grant's price ladder is
written here in the *same transaction* as `createMetavest` (genesis or futarchy), so grants and their
ladders share a single mutating path and a single auth gate. The [`UmiaTwapMilestoneCondition`](./UmiaTwapMilestoneCondition.md)
singleton reads thresholds back from the adapter via `effectiveThreshold` (`allocation → controller →
authority`); there is no separate ladder-registration step and no finalize/anchor step.

## Key design choices

- **Genesis-to-launch bridge**: ADMIN hands the controller authority to the adapter *before*
  genesis grants, so every grant routes through the adapter and emits `AllocationFunded` (see the
  [genesis sequence](../metavest/README.md#genesis-sequence)).
- **`fundGenesisGrant`**: deployer-gated pre-launch path: pulls tokens from the operator, forwards
  `createMetavest` to the controller, emits `AllocationFunded`, and registers the grant's price ladder
  atomically. Reverts after `bind` or `closeGenesis`.
- **`closeGenesis`**: write-once seal on the genesis funding window; post-launch grants use
  `forward` only.
- **`bind` is deployer-gated and write-once**: only the deployer (the launch operator) can bind,
  exactly once, and the treasury is resolved from `UmiaHub.ventureById(id).venture` rather than taken
  from caller input.
- **`forward` is gated to the treasury**, the governance mutating path post-launch. A passed market
  reaches it via `Venture.executeCall`. Emits `AllocationFunded` and registers the price ladder when
  calldata is `createMetavest`; `priceProgram.kind` must be `None` for non-`createMetavest` calls. It
  rejects `initiateAuthorityUpdate` (`AuthorityTransferForbidden`: the condition resolves ladders
  through `controller.authority()`) and `terminateMetavestVesting` (`UseTerminateGrant`).
- **Grant administration**: `terminateGrant` and `terminateAndReissue` are callable by the treasury,
  or by the Hub's `vestingAdmin` (`UmiaHub.setVestingAdmin`, owner-only) unless the venture opted out
  with `setVestingAdminRevoked(true)`. Both revert `LiquidationActive` while the venture is
  liquidating. MetaVesT returns a terminated grant's clawback to the authority, so the adapter sweeps
  it to the treasury (`terminateGrant`) or recycles it into the replacement grant
  (`terminateAndReissue`).
- **Atomic price-ladder registry**: a grant's ladder is written in the same transaction as the grant.
  The condition resolves thresholds back from this adapter, so there is one write path and one auth
  gate for grants and ladders, and no separate registration on the condition.
- **No stored CCA; lazy relative thresholds**: the adapter stores no auction reference. `cca()`
  resolves the venture's auction live as `IUmiaLBP(venture.lbp()).initializer()` (zero before `bind`),
  so a relative ladder's threshold is computed live at read time against the current clearing price.
  There is no anchoring or finalize step.
- **Funding via a standing allowance**: `createMetavest` pulls a grant's tokens from the controller's
  `authority` (this adapter), so `bind` grants the controller a `type(uint256).max` allowance of the
  venture token.
- **No AGPL linkage**: the controller is reached through local interfaces, so the deployed adapter
  carries no MetaVesT import (cf. `UmiaTwapMilestoneCondition`).

## Key state

- `deployer` / `hub` / `controller`: immutables set in the constructor.
- `treasury`: the bound venture treasury (set once, in `bind`).
- `bound`: whether `bind` has run.
- `genesisClosed`: whether `closeGenesis` has run.
- `ventureToken`: the venture token, resolved in `bind`.
- `vestingAdminRevoked`: whether the venture opted out of the Hub `vestingAdmin` path (default:
  opted in).
- `_programs[allocation]`: per-allocation price ladder, write-once at grant creation. A
  `PriceProgram` carries a `kind` (`None` / `Absolute` / `Relative`) plus either a `uint160[]` of Q96
  absolute thresholds or a `uint256[]` of `1e6`-scaled multiples; the other array is empty. A relative
  ladder stores **no anchor**; the auction is resolved live at read time. `MULTIPLE_SCALE = 1e6`, so a
  2x multiple is stored as `2_000_000`. An optional `uint48[] cliffs` array (empty, or one unix
  timestamp per milestone) time-gates individual milestones; `0` means price-only.

## Price ladders

A ladder is supplied alongside a grant as a `PriceProgramInput`:

```solidity
enum PriceProgramKind { None, Absolute, Relative }

struct PriceProgramInput {
    PriceProgramKind kind;
    uint160[] absoluteThresholds; // kind == Absolute (Q96, moneyToken per ventureToken)
    uint256[] multiplesX1e6;      // kind == Relative (1e6 scale: 2x == 2_000_000)
    uint48[] cliffs;              // optional per-milestone cliff timestamps (unix seconds); 0 = price-only
}
```

`kind` selects which array applies; the other must be empty. Registration is **write-once** per
allocation and validates the ladder: a `None` input must carry no data and is a no-op (the grant
has no price milestones; arrays alongside `kind == None` revert `InvalidPriceProgram`),
and a non-empty ladder must have strictly **ascending**, **non-zero** thresholds / multiples
(`EmptyThresholds`, `ZeroThreshold`, `ThresholdsNotAscending`). A ladder may only ride a
`createMetavest` call; attaching one to an amend/terminate reverts `InvalidPriceProgram`.

## Never add or remove milestones on a price-program grant

**Rule:** a grant with a registered price program (`priceProgramKind(allocation) != None`) must
never have milestones added or removed. To change its milestone structure, use
`terminateAndReissue`, which builds the new milestone list and its ladder together. Grants with
no price program can be amended normally.

The ladder is indexed by milestone position and write-once (`ProgramAlreadyRegistered`), but
MetaVesT's milestone array is not:

- **Removal unlocks early.** MetaVesT removes milestone `i` by swap-and-pop: the last milestone
  moves into slot `i` and the tail is dropped. The ladder does not move, so the relocated award is
  now gated by the removed milestone's threshold and cliff.
- **Append locks forever.** An appended milestone sits at an index with no ladder entry, so
  `effectiveThreshold` / `effectiveCliff` revert `NotRegistered` and it can never confirm.

Example: milestones `[10k @ $1, 20k @ $2, 100k @ $5]`. Removing index 0 leaves
`[100k, 20k]`, and the 100k award at index 0 now unlocks at **$1** with index 0's cliff.

The contract does not block this, and nothing in the calldata of such a `forward` call shows the
re-indexing, so the guard has to live with whoever builds the governance payload: never emit a
milestone add or remove through `forward` for a price-program allocation. See also the
[MetaVesT integration warning](../metavest/README.md).

`cliffs` is either empty (no milestone has a cliff, the price-only behavior) or exactly one
entry per milestone (`CliffsLengthMismatch` otherwise). A non-zero entry is an **absolute unix
timestamp** the milestone cannot confirm before, even when the price gate is already met; a `0`
entry leaves that milestone price-only. Cliffs are stored verbatim for absolute and relative
ladders alike.

## Important functions

### Mutating (grants + ladders)

- `claim()`: accept the controller's pending-authority role (its two-step handoff).
- `fundGenesisGrant(token, amount, createMetavestCalldata, priceProgram)`: fund and create a genesis
  grant and register its price ladder atomically; emits `AllocationFunded` and, for a non-`None`
  ladder, `PriceProgramRegistered`. Deployer-gated, pre-`bind`. Any over-funded remainder (`amount`
  above the grant total the controller pulls) is returned to the deployer.
- `forward(data, priceProgram)`: forward an authority call (`createMetavest` / amend / terminate) to
  the controller, and register the price ladder when the call is `createMetavest`. Gated to the bound
  treasury, so only futarchy drives it. `priceProgram.kind` must be `None` for non-`createMetavest`
  calls (else `InvalidPriceProgram`). Never forward a milestone add or remove for a price-program
  grant (see [above](#never-add-or-remove-milestones-on-a-price-program-grant)).
- `closeGenesis()`: permanently close the genesis funding window; emits `GenesisSealed` and reverts
  if already closed.
- `bind(ventureId)`: resolve the treasury from the Hub and lock it in (deployer-gated, write-once),
  record `ventureToken`, and grant the controller a standing allowance of the venture token. Emits
  `Bound(ventureId, treasury, token)`.
- `terminateGrant(allocation)`: terminate a grant's vesting through the controller and sweep the
  clawback to the treasury. Treasury or effective vesting admin; emits `GrantTerminated`.
- `terminateAndReissue(allocation, createMetavestCalldata, priceProgram)`: terminate and fund a
  replacement grant from the clawback in one call, registering its ladder. Same auth; the replacement
  must be denominated in `ventureToken` (`ReissueTokenMismatch`). Emits `GrantReissued`.
- `sweep(token)`: permissionless after `bind`; returns idle adapter balance to the treasury. Emits
  `Swept`.
- `setVestingAdminRevoked(bool)`: treasury-only opt-out of the Hub `vestingAdmin` path. Emits
  `VestingAdminRevokedSet`.

### Read surface (consumed by the condition)

- `effectiveThreshold(allocation, idx)`: the threshold the condition compares the TWAP against. For
  an **absolute** program returns the stored Q96 threshold; for a **relative** program returns
  `multiple × clearingPrice / 1e6` computed **live** at read time (capped at `type(uint160).max`).
  Reverts `NotRegistered` (no program, or `idx` out of range), `NotBound` (relative program read
  before `bind`) and `AuctionNotCleared` (no auction resolved, or its `clearingPrice()` is 0).
- `cca()`: the venture's auction, resolved live as `IUmiaLBP(venture.lbp()).initializer()`. Returns
  zero before `bind`. **No stored CCA**: relative thresholds are lazy and always reflect the current
  clearing price.
- `effectiveCliff(allocation, idx)`: the milestone's cliff timestamp (unix seconds); `0` when the
  milestone has no cliff. Reverts `NotRegistered` (no program, or `idx` out of range). Never needs
  the auction: cliffs resolve pre-`bind` even for relative programs.
- `priceProgramKind(allocation)`: `None` / `Absolute` / `Relative` for the allocation.
- `programLength(allocation)`: number of milestones in the ladder.
- `absoluteThresholdAt(allocation, idx)`: the stored absolute threshold (reverts for a relative
  program).
- `multipleAt(allocation, idx)`: the stored `1e6`-scaled multiple (reverts for an absolute program).
- `effectiveVestingAdmin()`: the Hub's `vestingAdmin` when it may act on this venture, else zero
  (unbound, revoked, Hub unset, or liquidating).

## Events

- `AllocationFunded(controller, allocation, beneficiary, token, allocationType, streamTotal, milestoneAwardTotal)`:
  the discovery signal for every grant (genesis and post-launch), for anything indexing the chain.
- `PriceProgramRegistered(allocation, token, programKind, count, cliffs)`: emitted (in the same tx
  as funding) when a non-`None` price ladder is registered; `programKind` is `1` for absolute, `2`
  for relative, `count` is the number of milestones, and `cliffs` is the per-milestone cliff array
  (empty when the program has none). Off-chain consumers read this to flag a milestone as
  price-gated and record its cliff.
- `Bound(ventureId, treasury, token)`: the adapter is bound to the venture's treasury. Grants are
  linked to a venture only through `UmiaHub.VentureVestingAuthoritySet`, not this event.
- `GenesisSealed()`: the genesis funding window has been permanently closed.
- `GrantTerminated(allocation, caller)`: a grant was terminated through the adapter.
- `GrantReissued(oldAllocation, newAllocation, caller)`: a clawback was recycled into a replacement
  grant.
- `VestingAdminRevokedSet(revoked)`: the venture opted in or out of the Hub `vestingAdmin` path.
- `Swept(token, amount)`: idle adapter balance was returned to the treasury.

## Integration

At genesis the operator deploys the adapter, hands authority, funds grants (with their ladders) via
`fundGenesisGrant`, calls `closeGenesis`, launches, binds, and has the Hub owner record the adapter
([genesis sequence](../metavest/README.md#genesis-sequence)). Post-launch, governance funds and
creates grants (with their ladders) through `forward`
([post-launch vesting allocations](../metavest/README.md#post-launch-vesting-allocations)). The `UmiaTwapMilestoneCondition`
singleton resolves each milestone's threshold from this adapter at check time; there is no separate
registration or finalize step. See [the MetaVesT integration doc](../metavest/README.md) (authority model + adapter).
