# Contract Upgrade Strategy

This document specifies the upgrade mechanisms for Umia Protocol smart contracts.

## Architecture Overview

```
┌─────────────┐      ┌─────────────┐      ┌─────────────────────┐
│   UmiaHub   │─────▶│   Venture   │─────▶│ SpotLiquidityVault  │
│  (registry) │      │ (treasury)  │      │ (spot LP position)  │
└─────────────┘      └─────────────┘      └─────────────────────┘
       │                                           │
       │                                           │ pulls / returns liquidity
       ▼                                           ▼
┌─────────────────────────────────────────────────────────┐
│                    UmiaMarketCore                       │
│  (borrows vault liquidity to seed decision markets)     │
└─────────────────────────────────────────────────────────┘
```

| Contract          | Description                                                            |
| ----------------- | ---------------------------------------------------------------------- |
| UmiaHub           | Central registry; deploys ventures and stores protocol contract addresses |
| Venture              | Treasury contract; holds venture assets under governance control       |
| UmiaMarketCore | Pulls spot vault liquidity to create decision markets and returns it at settlement |

## Registry Pattern

UmiaHub implements a registry pattern that enables hot-swapping of stateless periphery contracts without proxies.

Registry setters:
- `setUmiaMarketCore(address)`
- `setDefaultGovernanceExecutor(address)`
- `setConditionalMarketOracle(address)`
- `setLbpStrategyFactory(address)`
- `setVentureBeacon(address)`
- `setUmiaMarketStake(address)`
- `setCcaFactory(address)`
- `setSpotMigrator(address)`
- `setActiveLiquidityKeeper(address)`

Dependent contracts resolve references dynamically:

```solidity
IConditionalMarketOracle oracle = IConditionalMarketOracle(HUB.conditionalMarketOracle());
IGovernanceExecutor(HUB.governanceExecutor(venture)).executeProposal(...);
```

## Contract Classification

| Contract                | State          | Upgrade Strategy | Mechanism                                           |
| ----------------------- | -------------- | ---------------- | --------------------------------------------------- |
| UmiaMarketCore       | Heavy          | UUPS Proxy       | Active markets and ERC6909 balances require proxy   |
| Venture                    | Medium         | Beacon + UUPS    | Beacon for protocol upgrades, UUPS opt-out per venture |
| UmiaHub                 | Medium         | UUPS Proxy       | venture registry requires state preservation           |
| GovernanceExecutor      | Stateless      | Registry Swap    | `hub.setDefaultGovernanceExecutor()`                |
| ConditionalMarketOracle | Per-proposal   | Registry Swap    | `hub.setConditionalMarketOracle()`                  |
| SpotMigrator            | Per-venture prep | Registry Swap  | `hub.setSpotMigrator()`                             |
| UmiaLBPFactory / V2     | Immutables     | Registry Swap    | `hub.setLbpStrategyFactory()`, paired with a new hook |
| UmiaHook / UmiaHookV2   | Pool registry  | Non-upgradeable  | CreateX singleton; new bytecode means a new address |
| VentureToken               | ERC20 balances | Non-upgradeable  | Token identity tied to address                      |
| UmiaLBP                 | Lifecycle      | Non-upgradeable  | Terminates after migration                          |

---

## UUPS Proxy Contracts

### UmiaMarketCore

State that requires proxy preservation:
- ERC6909 virtual token balances and supplies (`balanceOf`, `totalSupply`)
- Active market state (`_markets`, `_proposals`, `activeMarketByVenture`, `proposalToMarket`)
- CPMM reserves and LP shares (`_pools`)
- Settlement state (`_settle`, `_hasClaimed`)
- EIP-712 nonces (`marketCreationNonces`, `swapNonces`)
- Per-market fee-exempt ALM (`activeManager`)

```solidity
mapping(uint256 proposalId => Pool) internal _pools;
mapping(uint256 marketId => MarketData) internal _markets;
mapping(uint256 id => uint256) public totalSupply;
```

Market stake deposits live in the separate `UmiaMarketStake` contract, not in the core.

Registry swap is not viable; all active markets and user balances would be invalidated.

`MarketCreationLib` and `SettlementLib` are external libraries linked into every implementation.
A new implementation deploys fresh copies; `script/UpgradeMarketCore.s.sol` reads the linked
addresses out of the bytecode so they can be recorded and verified.

Upgrade process: see [Upgrade flow](#upgrade-flow).

File: `src/core/UmiaMarketCore.sol`

### UmiaHub

State that requires proxy preservation:
- `ventureCount`, `_ventureById` (venture registry)
- `approvedMoneyTokens` (token whitelist)

Upgrade process: see [Upgrade flow](#upgrade-flow).

File: `src/core/UmiaHub.sol`

---

## Venture: Beacon + UUPS Opt-Out

Venture uses an UpgradeableBeacon for protocol-wide upgrades with per-venture UUPS opt-out via governance.

### Architecture

```
                    ┌────────────────────────────┐
                    │   UpgradeableBeacon        │
                    │   - Stores canonical impl  │
                    │   - Owned by Umia owner    │
                    │   - upgradeTo(VentureV2)      │
                    └─────────────┬──────────────┘
                                  │ implementation()
              ┌───────────────────┼───────────────────┐
              ▼                   ▼                   ▼
     ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
     │  VentureProxy (A)  │ │  VentureProxy (B)  │ │  VentureProxy (C)  │
     │  follows beacon │ │  follows beacon │ │  opted out ─────┼──▶ CustomImpl
     └─────────────────┘ └─────────────────┘ └─────────────────┘
```

VentureProxy is a custom proxy (`src/core/VentureProxy.sol`) that checks the ERC1967 implementation slot first. If empty (default), it falls back to the beacon. This allows per-venture UUPS opt-out while keeping the beacon as the default upgrade path.

```solidity
function _implementation() internal view override returns (address impl) {
    impl = ERC1967Utils.getImplementation();
    if (impl == address(0) || impl.code.length == 0) {
        impl = IBeacon(_beacon).implementation();
    }
}
```

OZ does not provide a hybrid beacon/ERC1967 proxy. VentureProxy is a custom 35-line contract composed from OZ primitives (`Proxy`, `ERC1967Utils`, `IBeacon`). Venture overrides `_checkProxy()` to only verify delegatecall context, since the default OZ check (`getImplementation() == __self`) fails for beacon-mode Ventures where the implementation slot is `address(0)`.

### Upgrade Paths

**Protocol-level upgrades (owner-controlled)**

The beacon owner upgrades the beacon. All ventures that haven't opted out receive the update atomically.

```
Owner (EOA / multisig / timelock) → UpgradeableBeacon.upgradeTo(VentureImplV2)
```

Use cases: bug fixes, security patches, protocol improvements.

**Per-venture upgrades (Decision market)**

A venture opts out of the beacon by writing a direct implementation to its ERC1967 slot via governance.

```
Decision Market wins → GovernanceExecutor → Venture.upgradeToAndCall(CustomImpl, "")
```

Use cases: venture-specific customizations, opting out of protocol updates.

### Default Behavior

New ventures are deployed as VentureProxy pointing to the shared UpgradeableBeacon. Protocol upgrades via the beacon apply to all default ventures automatically. No action required from individual venture communities.

### Opting Out

A venture can vote via decision market to upgrade to a custom implementation. This writes to the ERC1967 implementation slot, and VentureProxy will read that slot instead of the beacon from that point on. The venture no longer receives automatic protocol updates and assumes full responsibility for its implementation.

### Governance Action

```solidity
// GovernanceTypes.sol
enum ActionType {
    // ... existing actions
    UPGRADE_IMPLEMENTATION
}

struct UpgradeImplementation {
    address newImplementation;
    bytes data;
}
```

```solidity
// Venture.sol
function _authorizeUpgrade(address) internal override onlyExecutor {}
```

Files:
- `src/core/Venture.sol`
- `src/core/VentureProxy.sol`
- `src/libraries/GovernanceTypes.sol`
- `src/libraries/GovernancePayloadValidator.sol`
- `src/libraries/GovernanceActions.sol`

---

## Registry Swap Contracts

These contracts are stateless or have ephemeral state, enabling upgrade via registry swap.

### GovernanceExecutor

```solidity
IUmiaHub public immutable HUB;
```

The executor is not upgradeable, so a new action type ships as a new executor:

1. Deploy `new GovernanceExecutor(hub)`.
2. Hub owner: `hub.setDefaultGovernanceExecutor(newExecutor)`.

`script/SwapGovernanceExecutor.s.sol` does both, with a rehearsal in between: it deploys the
executor from `DEPLOYER_PRIVATE_KEY`, then simulates the swap in a fork as the hub owner and
checks that every venture resolves to the new executor, that no venture keeps a per-venture
override, that every unexecuted proposal payload still validates, and that the old executor can
no longer execute. With `EXECUTE_UPGRADE=true` and a deployer-owned hub it sends the swap;
otherwise it prints the calldata the owner must send.

A venture with a per-venture override (`hub.setVentureGovernanceExecutor`) keeps its old executor
through the swap, and the rehearsal fails while any override is set, even one pointing at the new
executor. Clear each first with `hub.setVentureGovernanceExecutor(ventureId, address(0))`.

The hub emits an event for every executor it points at, so off-chain consumers discover the new
executor from the hub alone.

File: `src/core/GovernanceExecutor.sol`

### ConditionalMarketOracle

```solidity
mapping(uint256 proposalId => OracleState) public oracleStates;
```

Per-proposal state is written once by `initialize` (guarded by `AlreadyInitialized`) and cannot be
reconstructed after the fact, so a replacement oracle only serves markets created after the swap.

The `initialize`/`update`/`calculateTWAP` interface is the upgrade seam. `initialize` receives the
scoring window and the market's snapshotted `winningThresholdBps`, so a replacement implementation
(e.g. one whose filter is calibrated to the threshold) needs no new inputs from the core. The swap
is a Hub pointer change, with no `UmiaMarketCore` implementation upgrade.

Upgrade:
1. Wait for all active markets to settle (oracle data required for settlement); the setter's
   `withNoActiveMarkets` guard enforces this
2. Deploy the new `ConditionalMarketOracle(hubAddress)` (`script/DeploySpotLiquidityV2.s.sol`
   deploys the current one alongside the V2 spot stack)
3. Hub owner: `hub.setConditionalMarketOracle(newOracle)`, in the same batch as the rest of the
   release (`test/fork/ConditionalOracleSwapBase.t.sol` rehearses it on a Base fork)

Constraint: Cannot swap during active markets due to cumulative price history dependency.

File: `src/periphery/ConditionalMarketOracle.sol`

### Swaps that are not free

- `hub.setUmiaMarketCore` is gated by `withNoActiveMarkets`; prefer a UUPS upgrade of the existing
  proxy, which needs no quiet window.
- `hub.setLbpStrategyFactory` alone breaks new launches: `UmiaHook` (and `UmiaHookV2`) is bound to
  one factory at `initialize` and is CREATE2-canonical, so a new factory means a new hook (salt
  mining, new pool keys for future ventures). Treat it as a redeploy of the launch stack:
  `script/DeployOracleUpgrade.s.sol` and `script/DeploySpotLiquidityV2.s.sol` are that redeploy, and
  both leave the flip to the hub owner, to be sent once off-chain consumers watch the new hook.
- Every address change is a release for off-chain consumers: anything that indexes or calls the
  protocol needs the new address. Old hooks keep serving their existing pools, so the old addresses
  stay relevant next to the new ones.

---

## Non-Upgradeable Contracts

### VentureToken

- ERC20Pausable with mint/burn/pause/unpause controlled by Venture owner
- Lifecycle bound to its venture
- Address change would invalidate holder balances

### UmiaLBP

- Lifecycle contract: auction → migration → dormant
- Fresh deployment per venture via factory
- Post-migration LBPs are dormant and unaffected by upgrades

### Uniswap V4 References

`UmiaHub` holds no Uniswap addresses. The only one baked into the protocol is the
`PoolManager`, fixed at construction on `UmiaLBPFactory`, `UmiaLBPFactoryV2` and
`SpotMigrator`, and at `initialize()` on `UmiaHook` and `UmiaHookV2`; changing it means
redeploying them, not a Hub upgrade. The protocol stores no other Uniswap address (position
manager, Permit2, state view, universal router); off-chain tooling resolves those itself.

---

## Governance

### Protocol Contracts

UmiaHub, UmiaMarketCore, and the Venture UpgradeableBeacon are owner-gated onchain.
In production, owner can be an EOA, multisig, timelock, or governance contract.

```
Owner (recommended: multisig + timelock)
    ├── UmiaHub UUPS
    ├── UmiaMarketCore UUPS
    └── Venture UpgradeableBeacon
```

### Timelock Adoption

`script/DeployTimelock.s.sol` deploys a stock OpenZeppelin `TimelockController` and
transfers ownership of the UmiaHub proxy (and optionally the Venture beacon) to it.
UmiaMarketCore needs no transfer: its `_authorizeUpgrade` checks `HUB.owner()`.

Role layout:

```
proposer multisig ── PROPOSER_ROLE + CANCELLER_ROLE ──▶ TimelockController ──owns──▶ UmiaHub, beacon
anyone            ── EXECUTOR_ROLE (open)           ──▶ execute() after minDelay
timelock          ── DEFAULT_ADMIN_ROLE (self)      ──▶ role/delay changes via scheduled ops
```

Every owner action becomes `schedule()` (sent by the proposer) → wait `minDelay` (default 2 days) →
`execute()` (an authorized executor; anyone only when `EXECUTOR_ROLE` is granted to `address(0)`).
The payload is fixed at schedule time. The proposer can `cancel()` a queued operation during the
delay. Emergency response stays instant through the separate `vetoGuardian` key, which trips
decision-market circuit breakers without touching the timelock; resets remain owner-gated and
therefore timelocked.

Script inputs: `DEPLOYER_PRIVATE_KEY` (the current hub owner), `UMIA_HUB_ADDRESS`,
`TIMELOCK_PROPOSER`, and optionally `TIMELOCK_MIN_DELAY` (seconds, default 2 days),
`TIMELOCK_EXECUTOR` (default `address(0)`, open execution), `VENTURE_BEACON_ADDRESS` (also
transfer the beacon), `TIMELOCK_ALLOW_EOA_PROPOSER` and `TIMELOCK_ALLOW_SHORT_DELAY` (both default
false).

UmiaHub uses single-step `Ownable`, so adoption is irreversible; the script asserts the timelock's
role configuration before transferring. The script is opt-in and not part of `Deploy.s.sol`, so a
fresh deployment starts deployer-owned.

Tests: `test/governance/HubTimelock.t.sol` (governance flow through the timelock) and
`test/governance/DeployTimelock.t.sol` (adoption script guard rails).

### Per-Venture Opt-Out

Individual ventures can opt out of the beacon via decision market through GovernanceExecutor.

```
Venture Token Holders → Decision Market → GovernanceExecutor → Venture.upgradeToAndCall()
```

---

## Configuration Parameters

These parameters are adjustable without contract upgrades:

```solidity
hub.setApprovedMoneyToken(address token, bool approved);
hub.setWinningMarketThresholdBps(uint16 bps);
hub.setDecisionMarketExecutionDelay(uint32 delay);
hub.setMarketCreationSigner(address signer);
hub.setVestingAdmin(address admin);
hub.setVetoGuardian(address guardian);
```

---

## Upgrade Path Selection

| Scenario                              | Path                                               |
| ------------------------------------- | -------------------------------------------------- |
| Protocol bug fix (Hub, MarketCore) | UUPS upgrade via owner (recommended: multisig)     |
| Protocol feature addition             | UUPS upgrade via owner (recommended: multisig)     |
| Venture implementation change            | Beacon upgrade (all) or decision market (per-venture) |
| Storage layout modification           | UUPS upgrade (preserve slot ordering)              |
| Stateless contract change             | Registry swap                                      |
| Per-market state contract             | Registry swap (between market cycles)              |
| Token contract                        | Non-upgradeable; deploy new                        |

---

## Storage Layout

All upgradeable contracts reserve storage slots for future variables:

```solidity
uint256[50] private __gap;
```

Storage rules:
- Never reorder, retype, or remove existing storage variables
- Upgrading a deployed layout: append new variables before `__gap` and shrink `__gap` by the
  slots they use. An append that fits in unused bytes of the final pre-gap slot consumes no
  gap slots. Before a contract's first deployment the layout is free to change and the
  gap stays at the full `uint256[50]`
- Never change the members of a struct that lives in storage (add a new mapping instead)
- Beacon-upgraded `Venture` storage must be safe at zero: a beacon upgrade cannot run an initializer

Venture layout history: `allowanceSources` at slot 12 and `allowanceSourceCount` at slot 13
(budget sources and the per-underlying count), gap shrunk to `uint256[48]` at slot 14. No
reinitializer; every new path is gated on an empty registry. `.storage-layouts/Venture.json` is
the authority if this line and the contract ever disagree.

UmiaHub layout history: `spotMigrator` at slot 19, `activeLiquidityKeeper` at slot 20,
`ventureVestingAuthority` at slot 21, `launchAnchorBps` and `launchActiveHalfWidthTicks` packed in
slot 22, gap shrunk to `uint256[46]` at slot 23. All are owner-set after the upgrade; zero leaves
migrations disabled, every ALM without a default keeper, and V2 launches reverting
`LaunchSplitUnset`. `.storage-layouts/UmiaHub.json` is the authority.

UmiaMarketCore layout history: `activeManager` at slot 16 (the fee-exempt basket trader), gap
shrunk to `uint256[49]` at slot 17. Snapshotted per market at creation, so markets created before
the upgrade have no exempt trader. Ships in the same owner batch as the Hub upgrade.
`.storage-layouts/UmiaMarketCore.json` is the authority.

Two checks guard the layouts, both built on the snapshots in `.storage-layouts/` (the
`forge inspect <Contract> storageLayout` output, reduced to label, slot, offset and type):

| Check | Rule |
| ----- | ---- |
| Drift | The current build's layout equals the committed snapshot. An intentional change regenerates the snapshot; the diff is the review artifact |
| Compatibility | The current build can be upgraded onto the layout live on the target chain (the snapshot at that release) |

Compatibility fails on any removed, moved, retyped, or renamed variable, any struct/mapping
internals change, a new variable outside the old gap and the unused bytes of the final pre-gap
slot, or a gap that does not shrink by exactly the appended slots. See
[DEVELOPMENT.md](./DEVELOPMENT.md#4-storage-layout-snapshots).

---

## Reinitializers

New storage that needs a non-zero value is seeded by a `reinitializer(n)` delivered atomically
through `upgradeToAndCall(impl, abi.encodeCall(initializeVn, (...)))`. `n` is the next
`Initializable` version: 2 for the hub and market core, 3 for ventures (`initialize` is already
version 2).

A reinitializer is gated by an authority that can actually reach it: `onlyOwner` on the hub,
`HUB.owner()` on the market core, and on ventures the governance executor or the hub owner. The
delegatecall inside `upgradeToAndCall` preserves `msg.sender`, so the atomic path passes the gate
(for ventures that is the executor, via the `UPGRADE_IMPLEMENTATION` action's `data`), and an
upgrade that lands without its payload leaves nothing anyone else can call. OZ's
`_disableInitializers` in the constructor keeps the implementation contract itself uninitializable.

Beacon upgrades carry no calldata, so after `beacon.upgradeTo` the hub owner sweeps each venture
with a separate reinitializer call; the implementation must behave correctly before it runs.

Reference shapes and tests: `test/mocks/UpgradedImplementations.sol`, `test/proxy/UpgradeabilityTest.t.sol`
(`Reinitializers` section), `test/governance/HubTimelock.t.sol`.

---

## Upgrade flow

An upgrade is one owner transaction per target, sent by whoever owns it (an EOA, a multisig, or a
timelock that the multisig schedules into):

| Target | Owner call | Authority |
| ------ | ---------- | --------- |
| `UmiaHub` proxy | `hub.upgradeToAndCall(newImpl, data)` | `hub.owner()` |
| `UmiaMarketCore` proxy | `marketCore.upgradeToAndCall(newImpl, data)` | `hub.owner()` (`_authorizeUpgrade` checks `HUB.owner()`) |
| Venture beacon | `beacon.upgradeTo(newImpl)` | `beacon.owner()`; no calldata, so a reinitializer is swept per venture afterwards |

`data` is empty or the reinitializer call (see [Reinitializers](#reinitializers)).

`script/UpgradeHub.s.sol`, `script/UpgradeMarketCore.s.sol` and `script/UpgradeVentureBeacon.s.sol`
share `script/UpgradeBase.s.sol`, which:

1. deploys the new implementation from `DEPLOYER_PRIVATE_KEY` (the only transaction it sends by
   default; leave the key unset and set `DEPLOYER_ADDRESS` for a hardware wallet via forge's
   `--ledger`/`--trezor`)
2. checks it is a locked UUPS implementation (`proxiableUUID`, initializers disabled)
3. rehearses the upgrade in the fork as the live owner and diffs protocol state reads before and
   after (`script/ProtocolState.sol`: hub registry, market core, and the newest ventures and markets)
4. with `EXECUTE_UPGRADE=true` and a deployer-owned target, sends the upgrade; otherwise prints the
   calldata the owner must send (raw calldata for a contract owner, or the `schedule`/`execute`
   pair plus operation id when the owner is a `TimelockController`)

`UPGRADE_INIT_DATA` carries the optional reinitializer calldata (proxies only). The scripts locate
the hub through `script/ProtocolState.sol`: set `UMIA_HUB_ADDRESS` to the `UmiaHub` proxy for every
target (the MarketCore proxy and the Venture beacon are read from the Hub's registry), or provide a `contracts.json` address book one directory above this tree
(`<env>.<chain>.umia.hub`, selected by `UMIA_ENV` and `UMIA_CHAIN`). Run without
`--broadcast` for a pure dry run: steps 1 to 3 still execute in the fork.

Before sending anything: the new layout must pass the compatibility check against the snapshot of
the release live on the target chain, and the full cycle should run on a fork of the live
deployment through execution (`test/proxy/UpgradeRehearsal.t.sol`, gated on `FORK_RPC_URL`, takes
over the proxies with a throwaway key).

After the upgrade, read the live implementation back: the ERC1967 implementation slot
(`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`) on each proxy, and
`beacon.implementation()` on the beacon. Implementation addresses are bookkeeping only; nothing
reads them at runtime. Off-chain consumers should gate behaviour on the implementation slot, not
on when the upgrade was expected to land.

### V2 spot liquidity release

`script/DeploySpotLiquidityV2.s.sol` stages the V2 stack on a chain that already runs the
protocol, wired to the existing hub, and touches nothing on the Hub itself. Inputs, all required:
`DEPLOYER_PRIVATE_KEY` (must derive to `UMIA_HOOK_DEPLOYER`), `UMIA_HOOK_DEPLOYER`,
`UMIA_HOOK_V2_SALT` (mined with `HOOK_V2=true` against this commit's bytecode, see
[NEW_CHAIN_DEPLOYMENT.md](./NEW_CHAIN_DEPLOYMENT.md#mine-the-umiahookv2-salt)), `POOL_MANAGER`,
`UMIA_HUB_ADDRESS` and `UMIA_HOOK_ADDRESS` (the live V1 hook). It deploys, in order:

1. `UmiaHookV2` via CreateX
2. `SpotLiquidityV2Code` (vault and ALM creation code)
3. `UmiaLBPFactoryV2(poolManager, hookV2, hub, code)`
4. `hookV2.initialize(factoryV2, poolManager, hub)`
5. `SpotMigrator(hub, poolManager, hookV2, sourceHook, code)`
6. `ConditionalMarketOracle(hub)`

Hub owner, in this order:

1. `hub.upgradeToAndCall(newHubImpl, "")`, then `marketCore.upgradeToAndCall(newCoreImpl, "")`.
   Markets created before the MarketCore upgrade get no fee-exempt ALM.
2. `hub.setConditionalMarketOracle(oracle)` (requires no active markets).
3. `hub.setDefaultGovernanceExecutor(new GovernanceExecutor(hub))`. The executor shipped with V2
   empties the ALM on `LIQUIDATE_TREASURY`, so it must be live before any ALM holds capital.
4. `hub.setSpotMigrator(migrator)`.
5. `hub.setActiveLiquidityKeeper(keeper)`: the external rebalancer's signing address.
6. `hub.setLaunchAnchorBps(7500)` and `hub.setLaunchActiveHalfWidthTicks(10980)`: how V2 launches
   split liquidity between the anchor vault and the ALM, and the ALM's first range (0.33x to 3x at
   tick spacing 60). Launches revert `LaunchSplitUnset` until both are set.
7. `hub.setLbpStrategyFactory(factoryV2)`, once off-chain consumers watch the V2 hook. This flips
   new launches to V2; in-flight LBPs from the old factory keep their hook and graduate onto V1.

Per existing venture: `migrator.prepare(venture)` (permissionless, its own transaction, about 7.2M
gas), then one decision-market proposal with two `CALL` actions:

```text
1. CALL oldVault.withdraw(venture's V1 shares, 0, 0, migrator)
2. CALL migrator.migrate(MigrateParams{anchorBps, activeSlices[]})
```

`test/fork/SpotMigrationUmiaFork.t.sol` rehearses the migration on a Base fork. See
[SpotMigrator](./contracts/SpotMigrator.md).

### Rehearsal

Run the full cycle on a testnet deployment before any mainnet upgrade, using the real owner path
(the multisig or timelock, not the deployer EOA), so the handoff is exercised end to end. A
deployment that redeploys from scratch cannot stand in for this: it never upgrades anything.
