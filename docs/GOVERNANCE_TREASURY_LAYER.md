# Governance & Treasury Execution Layer (v1)

## Overview

This document specifies the governance execution and treasury control layer for Umia ventures. It defines a structured action language for proposal execution, a canonical payload encoding, and the execution flow from decision market settlement to onchain treasury changes. The goal is to replace opaque raw calldata with auditable, typed actions while preserving an escape hatch for advanced use cases.

The spec targets:

- Market settlement → execution of a winning proposal
- A governance VM that executes deterministic, enumerable actions
- Treasury operations on any asset type (native, ERC20, ERC721, ERC1155)
- A document registry for legal/off-chain updates
- A liquidation mechanism with pro rata distribution

## Goals

- Deterministic, typed execution payloads
- Easy to audit and explain proposal outcomes
- Frontend-friendly encoding and validation
- Atomic execution across multiple actions
- Forward-compatible versioning
- Escape hatch for opaque calls

## Non-goals (v1)

- Complex param updates (reserved for future)
- Permissionless upgrades of executor logic
- Custom allowance cadences beyond calendar-month accounting
- NFT pro-rata liquidation (must be converted to fungible assets before liquidation)

## Architecture

### Actors & Contracts

- **UmiaMarketCore**: Settles decision markets and triggers execution of the winning proposal.
- **Venture**: Treasury contract holding assets.
- **GovernanceExecutor**: Per-venture executor contract that decodes and runs execution payloads.
- **GovernancePayloadValidator (library)**: Decodes and validates execution plan structure.
- **GovernanceActions (library)**: Validates and dispatches individual action semantics.

### Execution Flow

1. Market is created with proposals that include `executionPayload` bytes.
2. Market ends and `UmiaMarketCore` determines the winning proposal.
3. `UmiaMarketCore.executeWinningProposal(marketId)` calls:
   - `GovernanceExecutor.executeProposal(venture, marketId, proposalId, executionPayload)`
4. `GovernanceExecutor` decodes the plan via `GovernancePayloadValidator` and executes actions via `GovernanceActions`, atomically.
5. On success, the market is marked as executed and events are emitted.

## Versioning & Payload Encoding

### Canonical Payload

`executionPayload` MUST be ABI-encoded as:

```solidity
struct ExecutionPlanV1 {
    uint16 version; // must be 1
    ActionV1[] actions;
}

struct ActionV1 {
    ActionType actionType;
    uint16 actionVersion; // must be 1
    bytes data; // ABI-encoded action-specific payload
}
```

`executionPayload = abi.encode(ExecutionPlanV1({version: 1, actions}))`

Versioning rules:

- `ExecutionPlanV1.version` identifies the plan format.
- `ActionV1.actionVersion` identifies the action encoding for that action type.
- The executor MUST reject any version != 1 in v1.
- A plan holds at most 20 actions (`TooManyActions`).

## Updating Actions (Guide)

When you want to change a single action’s payload or behavior, prefer incrementing that **action’s version** rather than the whole plan format.

### When to bump the plan version

- You change the **container format** (`ExecutionPlanV1`) or how plans are decoded.
- You need to change how actions are ordered, validated, or executed at the plan level.

### When to bump an action version

- You change the **payload struct** for a specific action.
- You change the **semantics** of a specific action type but can keep the plan format unchanged.

### Recommended upgrade flow

1. **Add a new action version** in the Governance VM implementation.
   - Example: support `UPDATE_MONTHLY_ALLOWANCE` action version `2` while still supporting version `1`.
2. **Deploy a new GovernanceExecutor** that decodes the new action version. The executor is not upgradeable; a new version is a new contract.
3. **The Hub owner points the registry at it**: `setDefaultGovernanceExecutor(executor)`, or `setVentureGovernanceExecutor(ventureId, executor)` for a single venture.
4. **Frontends encode the new action version** for new proposals; old proposals remain valid.

### Example pattern (pseudocode)

```solidity
if (actionType == UPDATE_MONTHLY_ALLOWANCE) {
    if (actionVersion == 1) {
        // decode v1 struct
    } else if (actionVersion == 2) {
        // decode v2 struct
    } else {
        revert InvalidActionVersion();
    }
}
```

This allows incremental action upgrades without forcing a new plan version or re‑encoding all existing actions.

If `version != 1`, execution MUST revert.

### Action Types

```solidity
enum ActionType {
    MINT_TOKENS,
    BURN_TOKENS,
    TRANSFER_TREASURY_ASSETS,
    UPDATE_MONTHLY_ALLOWANCE,
    UPDATE_TEAM_MEMBER,
    UPDATE_PARAMS, // reserved in v1 (MUST revert)
    UPLOAD_DOCUMENT,
    LIQUIDATE_TREASURY,
    CALL,
    UPGRADE_IMPLEMENTATION,
    SET_ALLOWANCE,
    SET_ALLOWANCE_SOURCE
}
```

New action types MUST be appended at the end. Ordinals are part of the ABI of
every encoded `ExecutionPlanV1`, so reordering or inserting values would silently
re-target previously-generated proposal payloads.

### Action Payloads

#### MINT_TOKENS

Mints venture token supply to a recipient.

```solidity
struct MintTokens {
    address to;
    uint256 amount;
}
```

Rules:

- Only the venture token may be minted.
- `to != address(0)` and `amount > 0` required.

#### BURN_TOKENS

Burns venture tokens held by the treasury.

```solidity
struct BurnTokens {
    uint256 amount;
}
```

Rules:

- Burn occurs from the treasury balance (`Venture`).
- `amount > 0` required.

#### TRANSFER_TREASURY_ASSETS

Transfers assets held by the treasury to a recipient.

```solidity
enum AssetType { NATIVE, ERC20, ERC721, ERC1155 }

struct TransferTreasuryAssets {
    AssetType assetType;
    address token;   // must be address(0) for NATIVE
    address to;
    uint256 amount;  // NATIVE/ERC20/ERC1155
    uint256 tokenId; // ERC721/ERC1155
    bytes data;      // ERC1155 receiver data
}
```

Rules:

- `to != address(0)` required.
- `amount > 0` for NATIVE/ERC20/ERC1155.
- `token` must be `address(0)` for NATIVE and non-zero otherwise.
- `tokenId` selects the ERC721/ERC1155 token.

#### UPDATE_MONTHLY_ALLOWANCE

Updates the monthly allowance amount for a token. Allowance withdrawals are available to team members.

```solidity
struct UpdateMonthlyAllowance {
    address token;   // ERC20; address(0) is rejected
    uint256 amount;  // allowance per period
}
```

Rules:

- No rollover: each period starts fresh.
- Periods are calendar months (UTC) computed as `YYYYMM` via `CalendarLib.timestampToMonth(block.timestamp)`.
- On month change, `spent` resets to `0`.
- Withdrawal is permitted by any account that is a venture team member (registry updated via `UPDATE_TEAM_MEMBER`).
- If `amount == 0`, allowance is effectively disabled.

#### SET_ALLOWANCE

Sets an ERC20 allowance on the treasury for a specific spender address. Enables controlled programmatic access (e.g. a keeper or bot executing recurring TWAP buybacks via pull) without resorting to the raw `CALL` escape hatch.

```solidity
struct SetAllowance {
    address token;   // ERC20 only (address(0) not supported)
    address spender;
    uint256 amount;  // 0 to revoke the allowance
}
```

Rules:

- `token != address(0)` and `spender != address(0)` required.
- `amount` may be zero (revokes the allowance).
- Uses `forceApprove` internally for broad ERC20 compatibility.
- Distinct from `UPDATE_MONTHLY_ALLOWANCE` (the latter is calendar-month team pull allowances with spend tracking).
- **Standing allowances persist into liquidation and are not auto-revoked.** Before liquidating, a `LIQUIDATE_TREASURY` plan MUST first zero every live allowance with `SET_ALLOWANCE(token, spender, 0)` actions (see [LIQUIDATE_TREASURY](#liquidate_treasury)). Enumerate live allowances from the indexed `AllowanceSet(token, spender, amount)` events.

#### SET_ALLOWANCE_SOURCE

Registers, updates or removes a budget source: a token the treasury holds that the monthly
allowance of an underlying can be spent from. See [Monthly Allowance](#monthly-allowance) for
the budget-group model this enables.

```solidity
struct SetAllowanceSource {
    address source;      // the token the budget can be spent from
    address underlying;  // whose monthly allowance it draws down; ignored when sourceKind == 0
    uint8 sourceKind;    // 0 NONE (remove), 1 PEGGED, 2 ERC4626
}
```

Rules (payload validator, pure):

- `source != address(0)`, `sourceKind <= 2`, and `underlying != address(0)` unless removing.

Rules (Venture, at execution):

- `source` has code, `source != underlying`, and `source` is neither `token()` (backs claims) nor `moneyToken()` (the budget unit the hub spends from).
- Groups never nest in either direction: `underlying` is not itself a registered source, and `source` is not already some other group's underlying (`allowanceSourceCount(source) == 0`).
- `source != underlying` and the kind bound are the only two rules a pure validator can check, so they are enforced at market creation; the rest surface as an execution-time revert. Rehearse a registration plan on a fork before proposing it.
- `monthlyAllowance[source].amount == 0`: a token with its own cap cannot join a group until governance zeros that cap.
- Both tokens expose `decimals()` (at most 36), for either kind. `PEGGED`: one whole unit of `source` is attested to equal one whole unit of `underlying`. This is a governance attestation, not a verified peg.
- `ERC4626`: `IERC4626(source).asset() == underlying`.
- Re-registering overwrites; `sourceKind == 0` deletes and emits the previously stored underlying.

Emits `AllowanceSourceSet(underlying, source, kind)`.

#### UPDATE_TEAM_MEMBER

Updates a single team member address.

```solidity
struct UpdateTeamMember {
    address member;
    bool approved;
}
```

Rules:

- `member != address(0)` required.
- This action is the only way to update team membership after deployment.

#### UPDATE_PARAMS (reserved)

Reserved for future governance parameter updates. In v1:

- Any `UPDATE_PARAMS` action MUST revert.

#### UPLOAD_DOCUMENT

Stores a document record for off-chain legal or governance context.

```solidity
struct UploadDocument {
    string name;
    string uri; // IPFS CID or ipfs:// URI or content hash string
}
```

Rules:

- Documents are stored in an onchain enumerable mapping.
- Document IDs start at 1 and increment by 1 per upload.
- Empty `name` or `uri` MUST revert; `name` is at most 256 bytes and `uri` at most 2048.

#### LIQUIDATE_TREASURY

Starts liquidation and enables pro rata redemption of treasury assets by token holders.

```solidity
struct LiquidationAsset {
    AssetType assetType;
    address token;
    uint256 tokenId; // ERC721/ERC1155 only
}

struct LiquidationPlan {
    address liquidator;
    LiquidationAsset[] assets;
}
```

Rules:

- Liquidation is a terminal state: once activated, only liquidation claims are allowed.
- The `liquidator` address points to an external `ILiquidator` contract that handles the actual distribution strategy (pro-rata, auction, etc.) while assets remain in the Venture treasury.
- On execution, `GovernanceActions` redeems the venture's spot-LP shares in the Hub's current vault and, on a V2 pool, empties its ActiveLiquidityManager (`withdrawAll`) into the treasury, burns every venture token the treasury then holds, then calls `venture.setLiquidator(liquidator)` and `ILiquidator(liquidator).initialize(venture, assets, totalSupply)`.
- Positions outside the current vault are the plan's job: list them as calls before `LIQUIDATE_TREASURY`, which freezes `executeCall`. That includes V1 vault shares a migrated venture left behind (a donation to the venture after the migration proposal was written, or an under-sized proposal): add `withdraw(shares, 0, 0, venture)` on the V1 vault. Known and accepted; there is no automatic sweep.
- Token holders call `ILiquidator.claim()` to burn all their venture tokens and receive pro-rata shares of each asset.
- Claims are proportional to burned venture tokens over the post-burn total supply. Venture tokens held by the treasury itself (redeemed LP + any treasury balance) can never claim, so they are burned before the snapshot rather than left alive and excluded, where a standing approval could move them into circulation after the snapshot:
  - `payout = assetBalance * burnAmount / totalSupply`
- If the treasury held every venture token, nothing circulates after the burn and the action reverts `InvalidParams`.
- **Do not list the venture token in `assets`.** It is the claim-burn token, not a distributable asset; `SimpleLiquidator` skips it if listed. Paying it back out pro-rata would let a claimant recycle the payout through fresh addresses and over-draw. List the money token (and any other real treasury assets) instead.

##### Mandatory: revoke standing allowances first

**Liquidation does NOT revoke standing ERC20 allowances.** `setLiquidator` only flips the terminal flag, and afterwards `setAllowance` and the whole executor path are blocked, so a stale approval can never be cleared once liquidation starts. Any spender still holding an allowance (granted via `SET_ALLOWANCE` **or** a raw `CALL` `approve`) can then `transferFrom` treasury assets directly on the token *after* the liquidator snapshots balances, draining assets that back claims and reverting later claimants.

The liquidation governance plan therefore MUST include a `SET_ALLOWANCE(token, spender, 0)` action for every live allowance, **ordered before** the `LIQUIDATE_TREASURY` action in the same plan. Actions execute in array order (`GovernanceExecutor` loops them sequentially), and `setAllowance` runs while still not liquidating, so the approvals are zeroed before `setLiquidator` runs. ERC20 allowances are not enumerable onchain, and the indexed `AllowanceSet(token, spender, amount)` events record only `SET_ALLOWANCE`; a raw `CALL` `approve` emits nothing from the Venture. Build the candidate spenders from `AllowanceSet` events, each claim token's `Approval` logs with the venture as owner, and the protocol's own spenders; read `allowance(venture, spender)` for each and revoke every non-zero one. Include the venture token too, so no spender can move the treasury's venture tokens before the action burns them. A spender set derived from events and known integrations is a starting point, not a guarantee: any spender it misses must be added to the plan by hand, on the claim tokens and the venture token.

Example plan action order:

```
[ SET_ALLOWANCE(moneyToken, keeperA, 0),
  SET_ALLOWANCE(moneyToken, keeperB, 0),
  LIQUIDATE_TREASURY({ liquidator, assets: [moneyToken, ...] }) ]
```

#### CALL

Executes an opaque call from the treasury context.

```solidity
struct Call {
    address target;
    uint256 value;
    bytes data;
}
```

Rules:

- `target != address(0)` and `target != venture` required.
- Execution MUST use `call` (not `delegatecall`), via `Venture.executeCall`.
- A failed call reverts the whole plan with `TransferFailed`; the target's revert data is not bubbled.
- No allowlists are enforced (by design).

#### UPGRADE_IMPLEMENTATION

Upgrades a venture to a custom implementation and optionally runs initialization calldata.

```solidity
struct UpgradeImplementation {
    address newImplementation;
    bytes data;
}
```

Rules:

- Uses `UUPSUpgradeable(address(venture)).upgradeToAndCall(newImplementation, data)`.
- Emits implementation opt-out events for indexing and governance audit trails.

## GovernanceExecutor Requirements

### Access Control

- Only the **current** `UmiaMarketCore` (from `UmiaHub`) MAY call `executeProposal`.
- The executor is resolved through `UmiaHub.governanceExecutor(venture)`: the Hub owner sets a default (`setDefaultGovernanceExecutor`) and optional per-venture overrides (`setVentureGovernanceExecutor`). `executeProposal` also reverts unless the Hub resolves to this executor and the venture is not liquidating.

### Atomicity

- All actions execute in order, atomically.
- Any failure MUST revert the entire execution.

### Idempotency

- Each market should be executable at most once (tracked in `UmiaMarketCore`).
- The executor MAY emit a `planHash = keccak256(executionPayload)` for indexing.

### Events

Emitted by `GovernanceExecutor`:

```solidity
event GovernancePlanExecuted(
    address indexed venture,
    uint256 indexed marketId,
    uint256 indexed proposalId,
    bytes32 planHash
);

event GovernanceActionExecuted(
    address indexed venture,
    uint256 indexed marketId,
    uint256 indexed proposalId,
    ActionType actionType
);
```

Emitted by the `Venture` itself (so no `venture` parameter):

```solidity
event DocumentUploaded(uint256 indexed docId, string name, string uri);
event MonthlyAllowanceUpdated(address indexed token, uint256 amount);
event AllowanceSet(address indexed token, address indexed spender, uint256 amount);
event AllowanceSourceSet(address indexed underlying, address indexed source, uint8 kind);
event LiquidatorAuthorized(address indexed liquidator);
```

Emitted by the liquidator (`ILiquidator`):

```solidity
event Initialized(address indexed venture, uint256 totalSupply, uint256 assetCount);
event Claimed(address indexed account, uint256 tokenBalance);
```

## Venture Requirements

The executor must be able to operate on the treasury. Venture MUST provide restricted hooks for:

- `mint(address to, uint256 amount)`
- `burn(uint256 amount)` (from treasury balance)
- `withdraw(address token, address to, uint256 amount)` (native or ERC20)
- ERC721/1155 withdrawals:
  - `withdrawERC721(address token, address to, uint256 tokenId)`
  - `withdrawERC1155(address token, address to, uint256 tokenId, uint256 amount, bytes data)`
- `executeCall(address target, uint256 value, bytes data)` for `CALL`

Normal treasury mutation on the Venture is restricted to the GovernanceExecutor (`onlyExecutor`). Once liquidation starts, `withdraw*` accept only the `authorizedLiquidator`, which pays out claims, and `burnFrom` (callable only during liquidation) is the liquidator's too. The Hub only sets `minMarketStake`, and the market core never calls the Venture.

Team members MUST be specified at venture deployment time as part of `CreateVentureParams.teamMembers`.

## Monthly Allowance

State (per venture, per token):

- `monthlyAllowance[token].amount`
- `monthlyAllowance[token].spent`
- `monthlyAllowance[token].currentMonth` (encoded as `YYYYMM`)

Rules:

- Periods follow UTC calendar months from `CalendarLib.timestampToMonth(block.timestamp)`.
- When the computed month changes, `monthlyAllowance[token].spent` resets to `0`.
- Any team member can withdraw up to `monthlyAllowance[token].amount - monthlyAllowance[token].spent`.
- Withdrawal is a dedicated team-member function, `withdrawMonthlyAllowance(token, to, amount)`, which emits `MonthlyAllowanceWithdrawn(token, to, amount)`.

### Budget groups

The cap on an underlying is the whole month's budget for that underlying, whichever token it
leaves the treasury as. A group is the underlying plus every source registered for it with
`SET_ALLOWANCE_SOURCE`; every spend from any member debits the same `spent` counter.

- `withdrawMonthlyAllowance(underlying, to, amount)` spends the liquid underlying, as before.
- `withdrawMonthlyAllowanceFrom(source, to, assets)` spends `assets` (underlying units) from a
  registered source. `PEGGED` transfers `assets` scaled to the source's decimals (floored when the
  source has fewer decimals; the budget is debited by the floored value scaled back). `ERC4626`
  calls `withdraw(assets, to, venture)` so the recipient receives the underlying and the venture's
  shares are burned. Emits `MonthlyAllowanceWithdrawnFrom(underlying, source, to, assets, amount)`,
  with `to` indexed, `assets` the budget debit in underlying units and `amount` the transferred
  source units for `PEGGED` or the withdrawn underlying units for `ERC4626`.
- `allowanceRemaining(underlying)` returns the remaining budget, treating a stale month as unspent.
- A registered source cannot carry its own cap: `updateMonthlyAllowance(source, ..)` and
  `withdrawMonthlyAllowance(source, ..)` revert `InvalidAllowanceSource` while it is registered.
- Nothing in the spend path approves a source: `withdrawMonthlyAllowanceFrom` transfers or redeems from the venture's own balance. A misconfigured source can only revert or burn budget.
- Governance itself is **not** contained by the group. `SET_ALLOWANCE(source, spender, n)` and a raw `CALL(source, approve(...))` both still grant a spender direct access to a parked position with no debit to the budget, exactly as they do for any other treasury token. The budget bounds what the *team* can spend, not what a passed proposal can do.

Parking 1M USDC in Aave v3 on Base while keeping the budget intact, one plan in this order:

```
SET_ALLOWANCE(USDC, AavePool, 1_000_000e6)
CALL(AavePool, 0, supply(USDC, 1_000_000e6, venture, 0))
SET_ALLOWANCE(USDC, AavePool, 0)
SET_ALLOWANCE_SOURCE(aBasUSDC, USDC, PEGGED)
```

For an ERC-4626 vault such as a Morpho vault, replace the middle with `SET_ALLOWANCE(USDC, vault, amt)`,
`CALL(vault, 0, deposit(amt, venture))`, `SET_ALLOWANCE(USDC, vault, 0)` and register with `ERC4626`.
Other stablecoins join the same group as `PEGGED` sources; a depeg leaks at most the depeg
fraction of that month's cap until the source is removed.

## Document Registry

State:

```solidity
struct Document {
    string name;
    string uri;
    uint256 createdAt;
}

mapping(uint256 => Document) public documents;
uint256 public documentCount;
```

Rules:

- IDs start at 1.
- `documentCount` increments by 1 per upload.
- Documents are immutable after upload in v1.

## Liquidation Mechanics

1. On `LIQUIDATE_TREASURY`, the executor:
   - Redeems the venture's shares in the Hub's current vault and, on a V2 pool, calls `ActiveLiquidityManager.withdrawAll()`, both through `venture.executeCall`
   - Burns the treasury's venture-token balance via `venture.burn`
   - Calls `venture.setLiquidator(liquidator)` which sets `liquidationActive = true` and `authorizedLiquidator`
   - Calls `ILiquidator(liquidator).initialize(venture, assets, totalSupply)` which snapshots the post-burn supply and asset balances
2. Token holders call `ILiquidator.claim()`:
   - Burns all caller's venture tokens via `venture.burnFrom`
   - Transfers each asset pro rata based on burned amount vs the claimable-supply snapshot, via `venture.withdraw`
3. After liquidation starts, all governance actions MUST revert (`GovernanceExecutor.executeProposal` reverts `LiquidationActive`, and the `whenNotLiquidating` modifier guards the Venture).

## Security Considerations

- `CALL` is deliberately unrestricted. This makes governance powerful but increases risk:
  - Malicious proposals can drain funds or interact with unsafe contracts.
  - Frontends should warn users when a proposal contains a `CALL` action.
- Executor MUST be non-reentrant.
- All external calls MUST be guarded by checks-effects-interactions.
- Use `SafeERC20` and ERC721/1155 safe transfer methods where appropriate.
- Liquidation should be single-shot and irreversible in v1.

## Example Payloads

### Mint 1,000 venture tokens to a recipient

```solidity
ActionV1[] memory actions = new ActionV1[](1);
actions[0] = ActionV1({
    actionType: ActionType.MINT_TOKENS,
    actionVersion: 1,
    data: abi.encode(MintTokens({to: recipient, amount: 1_000e18}))
});

bytes memory payload = abi.encode(ExecutionPlanV1({version: 1, actions: actions}));
```

### Transfer 50 USDC from treasury

```solidity
actions[0] = ActionV1({
    actionType: ActionType.TRANSFER_TREASURY_ASSETS,
    actionVersion: 1,
    data: abi.encode(
        TransferTreasuryAssets({
            assetType: AssetType.ERC20,
            token: usdc,
            to: recipient,
            amount: 50e6,
            tokenId: 0,
            data: ""
        })
    )
});
```

### Upload document

```solidity
actions[0] = ActionV1({
    actionType: ActionType.UPLOAD_DOCUMENT,
    actionVersion: 1,
    data: abi.encode(UploadDocument({
        name: "Operating Agreement v2",
        uri: "ipfs://bafybeigdyr..."
    }))
});
```
