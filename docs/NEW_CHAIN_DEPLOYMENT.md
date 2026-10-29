# Umia New Chain Deployment

How to deploy the Umia protocol contracts to an EVM chain with `script/Deploy.s.sol`, and how to
check the result from the chain alone.

## Scope

Use this document to:

- deploy Umia to a public testnet or mainnet,
- stand up a second, independent Umia deployment on a chain that already has one.

For upgrading a live deployment, see [UPGRADES.md](./UPGRADES.md).

## What the deploy script deploys

`script/Deploy.s.sol:Deploy` sends every transaction from `DEPLOYER_PRIVATE_KEY`, in this order:

1. `UmiaHub` implementation and ERC1967 proxy, `initialize(deployer)`: the deployer is the owner
2. `ConditionalMarketOracle(hub)`
3. `UmiaMarketCore` implementation and ERC1967 proxy, `initialize(hub)`; forge deploys and links
   the external libraries `MarketCreationLib` and `SettlementLib`
4. `GovernanceExecutor(hub)`
5. `UmiaMarketStake(hub)`
6. `ContinuousClearingAuctionFactory(feeController)`, or an existing one (`CCA_FACTORY`); a fresh
   factory gets a zero-fee `ProtocolFeeController(deployer)` unless `PROTOCOL_FEE_CONTROLLER`
   points at one
7. `AuctionStateLens`, `CCALens`, `CCAExitHelper`, or existing ones
8. `UmiaHookV2(INITIAL_OWNER = UMIA_HOOK_DEPLOYER)` through CreateX at the salt-mined address
9. `SpotLiquidityV2Code` (vault and ALM creation code) and
   `UmiaLBPFactoryV2(poolManager, hookV2, hub, code)`
10. `ZkTlsVerifier(initialWitnesses, 1)`, or an existing one (`ZKTLS_VERIFIER_ADDRESS`)
11. `hookV2.initialize(factoryV2, poolManager, hub)`; must be sent by `UMIA_HOOK_DEPLOYER`
12. the MetaVesT singletons (`MetaVesTFactory`, `VestingAllocationFactory`, `TokenOptionFactory`,
    `RestrictedTokenFactory`, `UmiaTwapMilestoneCondition(TWAP_WINDOW)`), or existing ones
13. `Venture` implementation and `UpgradeableBeacon(ventureImpl, deployer)`
14. Hub wiring: `setVentureBeacon`, `setUmiaMarketCore`, `setDefaultGovernanceExecutor`,
    `setUmiaMarketStake`, `setConditionalMarketOracle`, `setMarketCreationSigner`,
    `setLbpStrategyFactory(factoryV2)`, `setLaunchAnchorBps(7500)`,
    `setLaunchActiveHalfWidthTicks(10980)`, `setCcaFactory`, `setProtocolFeeRecipient(deployer)`
15. Operational roles: `setVestingAdmin`, `setVetoGuardian`, `setActiveLiquidityKeeper`, each
    only when its input is set
16. `setApprovedMoneyToken(USDC_ADDRESS, true)` when `USDC_ADDRESS` is set
17. `addNewEpoch` on a freshly deployed verifier until it reaches `ZKTLS_CLAIM_EPOCH`; last, so
    no other deployment's address moves

The deployer owns the hub and the beacon afterwards. Transferring ownership to a timelock is a
separate, one-shot step (`script/DeployTimelock.s.sol`, see
[UPGRADES.md](./UPGRADES.md#timelock-adoption)).

## Inputs

Required:

- `DEPLOYER_PRIVATE_KEY`: funded deployer key used for all onchain transactions.
- `POOL_MANAGER`: Uniswap v4 `PoolManager` address for the target chain.
- `UMIA_HOOK_DEPLOYER`: EOA passed as `INITIAL_OWNER` to `UmiaHookV2`. Must equal
  `vm.addr(DEPLOYER_PRIVATE_KEY)`; `initialize` is gated on it.
- `UMIA_HOOK_V2_SALT`: CreateX salt mined offline with `HOOK_V2=true` (see
  [Mine the UmiaHookV2 salt](#mine-the-umiahookv2-salt)). It must produce an unoccupied hook address
  on the target chain.
- `TWAP_WINDOW`: vesting TWAP condition window in seconds (mainnet: `2592000`). Required unless
  the MetaVesT singletons are reused; there is no default.

Operational roles (one of the two forms is required for each):

These roles are deliberately separate from the Hub owner so an ops key is never the upgrade key, and
all are `address(0)` after `initialize`, which silently means the capability is off. The script
refuses to guess: supply the address, or acknowledge the off state explicitly. A forgotten export
cannot quietly ship a protocol with a capability disabled.

- `VESTING_ADMIN`: address allowed to terminate and reissue vesting grants on every venture adapter
  (ventures can opt out individually through futarchy). Set `VESTING_ADMIN_UNSET_OK=true` to deploy
  with no vesting admin.
- `VETO_GUARDIAN`: address allowed to trip (but not reset) decision-market circuit breakers. Set
  `VETO_GUARDIAN_UNSET_OK=true` to deploy with owner-only tripping.
- `ACTIVE_LIQUIDITY_KEEPER`: signer allowed to rebalance every venture's `ActiveLiquidityManager`.
  Set `ACTIVE_LIQUIDITY_KEEPER_UNSET_OK=true` to deploy without one; ALMs are seeded at launch or
  migration but never move until `setActiveLiquidityKeeper` is called.

Optional:

- `MARKET_CREATION_SIGNER_KEY`: private key whose derived address becomes the market creation
  signer; defaults to the deployer if unset.
- `USDC_ADDRESS`: if set, the script approves that token as a money token in `UmiaHub`.
- `CCA_FACTORY`: reuse an existing Continuous Clearing Auction factory instead of deploying one.
  When deploying a fresh factory, `PROTOCOL_FEE_CONTROLLER` reuses an existing zero-fee controller.
- `AUCTION_STATE_LENS_ADDRESS`, `CCA_LENS_ADDRESS`, `CCA_EXIT_HELPER_ADDRESS`: reuse existing CCA
  read lenses and exit helper.
- `ZKTLS_VERIFIER_ADDRESS`: reuse an existing `ZkTlsVerifier` instead of deploying a new one.
- `ZKTLS_WITNESS_ADDRESS` and `ZKTLS_WITNESS_HOST`: required when deploying a new verifier; the
  approved Umia attestor's signer and WebSocket URL. The script validates them before broadcasting.
- `ZKTLS_CLAIM_EPOCH`: the epoch the attestor signs (`ZKTLS_SHARED_ATTESTOR.claimEpoch`, default
  1). A fresh verifier is advanced to it with the same witness.
- `METAVEST_FACTORY` plus `VESTING_ALLOCATION_FACTORY`, `TOKEN_OPTION_FACTORY`,
  `RESTRICTED_TOKEN_FACTORY`, `TWAP_MILESTONE_CONDITION`: reuse the per-chain MetaVesT singletons;
  all five are read when `METAVEST_FACTORY` is set.

## Mine the UmiaHookV2 salt

The hook is deployed through CreateX, so one salt produces the same `UmiaHookV2` address on every
chain where the deployer, the bytecode and CreateX are the same. A **second independent Umia
deployment on the same chain** needs a different hook address: the original CreateX address is
occupied. Mine a fresh salt for that deployment, verify the predicted address has no bytecode on
the target chain, and check external routing support for the new hook address.

The hook's address must encode the V4 permission flags in its lower 14 bits (`0x3A80`). Optional
vanity: a leading byte (for example `0xCC`).

### Prerequisites

- Pick the deployer EOA. The same key broadcasts `Deploy.s.sol` on every chain. Keep it cold.
- Decide the vanity target. One leading byte is cheap; longer prefixes need a native miner.

### Mine

`script/MineUmiaHookSalt.s.sol` is a Foundry script that calls CreateX's view function. Run it
against a fork where CreateX (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`) is present; the
address is the same on every chain that has it:

```bash
HOOK_V2=true \
UMIA_HOOK_DEPLOYER=0xYourColdDeployerEOA \
VANITY_PREFIX=0xCC \
forge script script/MineUmiaHookSalt.s.sol --rpc-url "$RPC_URL" -vv
```

`MAX_ATTEMPTS` (default 10M) bounds the search and `MIN_COUNTER` resumes it. `HOOK_V2=true`
selects the `UmiaHookV2` init code, which `Deploy.s.sol` and `DeploySpotLiquidityV2.s.sol`
deploy; without it the script mines for the V1 `UmiaHook`, which no script deploys any more.

Expected runtime: 5 to 15 minutes for one vanity byte plus the flags (about 4M attempts on average,
single-threaded interpreted EVM).

Output ends with:

```
=== MATCH ===
Salt:
  0xdead00000000000000000000000000000000dd00XXXXXXXXXXXXXXXXXXXXXXXX
Predicted address: 0xCC...3A80
```

The salt is the fixed sentinel prefix `0xdead...dd00` followed by the mined counter; the `X`s above
are a placeholder, not a value. Save the salt and the predicted address. Reuse them only for
deployments that intentionally share this hook identity on different chains and where the
predicted address is unoccupied. The address is part of each deployment's protocol identity.

### When to re-mine

Only if any of these change:
- The deployer EOA (`UMIA_HOOK_DEPLOYER`).
- `UmiaHookV2` source code (any change to bytecode invalidates the init-code hash).
- The CreateX address (would only change on a chain with a non-standard deployment).
- A separate deployment on a chain where that predicted address is already occupied.

If you re-mine, you get a new canonical address. Every deploy after the change must use the new
salt, and any chain already deployed with the old salt stays on the old address forever.

### Factory immutability after `initialize`

Once `UmiaHookV2.initialize(factory, poolManager, hub)` is called, the `factory` address is
immutable. LBPs deployed by any other factory fail `registerPool` with `NotFactoryDeployedLBP`, so
a new `UmiaLBPFactoryV2` means a new hook: mine a new address against the new bytecode and check
external routing support again. The old hook keeps serving its existing pools forever; new pools
point at the new hook, and the Hub owner flips launches with `hub.setLbpStrategyFactory`.
`script/DeployOracleUpgrade.s.sol` and `script/DeploySpotLiquidityV2.s.sol` are that path on a
live chain; both leave the flip to the hub owner.

There is intentionally no admin path to update `factory` on the hook. The trade-off is a simpler
trust model and easier audit, at the cost of a one-shot commitment to whichever factory exists at
the time of the first `initialize`.

## Preflight

Before broadcasting anything, collect and verify:

1. Chain metadata: chain ID, explorer URL, RPC URL
2. Upstream dependencies: the official Uniswap v4 `PoolManager` for the chain, and the money token
   to approve, typically USDC
3. Keys: a funded deployer key, and a dedicated market-creation signer key for non-local
   environments

Run the contract checks first:

```bash
forge build
forge test
```

## Testnet: shorten market lifecycle constants

Before `forge build`, edit the trading constants in `src/libraries/MarketCreationLib.sol` to
testing-friendly values (these are the ones market creation validates against). The defaults are
mainnet-tuned; on testnet they make every smoke test wait before trading can even start.

| Constant                   | Mainnet default | Testnet value         |
| -------------------------- | --------------- | --------------------- |
| `TRADING_MAX_START_DELAY`  | `7 days`        | shorten to taste      |
| `TRADING_MIN_DURATION`     | `1 hours`       | keep or lower         |
| `TRADING_MAX_DURATION`     | `96 hours`      | shorten to taste      |
| `TRADING_DEFAULT_DURATION` | `3 days`        | `1 hours`             |

These are `internal constant`, so the change is a compile-time edit baked into the deployed
`UmiaMarketCore` implementation. Revert the file before any mainnet deploy: there is no admin
setter, and a wrong value means redeploying the implementation and upgrading the proxy.

There is no on-chain minimum start delay: a `startTimestamp` at or before now clamps to
`block.timestamp` (open immediately). The only bound is `TRADING_MAX_START_DELAY`.

## Local chains only: deploy Uniswap v4 infra first

`script/DeployV4Infra.s.sol:DeployV4Infra` is only for fresh local chains such as Anvil. Do not use
it on public networks that already have canonical Uniswap v4 deployments.

```bash
export DEPLOYER_PRIVATE_KEY=0x...

forge script script/DeployV4Infra.s.sol:DeployV4Infra \
  --rpc-url http://localhost:8545 \
  --broadcast
```

The script prints `POOL_MANAGER`, `PERMIT2`, `POSITION_MANAGER`, `STATE_VIEW`, `UNIVERSAL_ROUTER`,
and `WETH9`. Only `POOL_MANAGER` is an input to `Deploy.s.sol`; the rest are for off-chain
consumers. The Permit2 etch is refused outside Anvil (31337) and Monad testnet unless
`ALLOW_V4_BOOTSTRAP=true`.

## Set deployment environment variables

Example shell setup:

```bash
export RPC_URL=https://...
export DEPLOYER_PRIVATE_KEY=0x...
export MARKET_CREATION_SIGNER_KEY=0x...

export POOL_MANAGER=0x...

# UmiaHookV2 (use a fresh salt for another deployment on the same chain)
export UMIA_HOOK_DEPLOYER=0x...     # must equal vm.addr(DEPLOYER_PRIVATE_KEY)
export UMIA_HOOK_V2_SALT=0x...      # from MineUmiaHookSalt.s.sol with HOOK_V2=true

export USDC_ADDRESS=0x...
export TWAP_WINDOW=2592000              # vesting TWAP condition window; required unless METAVEST_FACTORY is set

# Approved attestor (ZKTLS_SHARED_ATTESTOR); required unless ZKTLS_VERIFIER_ADDRESS is set
export ZKTLS_WITNESS_ADDRESS=0x...
export ZKTLS_WITNESS_HOST=wss://attestor.zktls.umia.finance/ws
export ZKTLS_CLAIM_EPOCH=2

# Operational roles (separate from the owner). Supply the address, or set the
# matching _UNSET_OK flag to record that leaving the capability off is deliberate.
export VESTING_ADMIN=0x...
export VETO_GUARDIAN=0x...
export ACTIVE_LIQUIDITY_KEEPER=0x...

# Optional reuse points
export CCA_FACTORY=0x...
export PROTOCOL_FEE_CONTROLLER=0x...    # only read when CCA_FACTORY is unset
export AUCTION_STATE_LENS_ADDRESS=0x...
export CCA_LENS_ADDRESS=0x...
export ZKTLS_VERIFIER_ADDRESS=0x...
export CCA_EXIT_HELPER_ADDRESS=0x...
export METAVEST_FACTORY=0x...           # when set, the four below are required too
export VESTING_ALLOCATION_FACTORY=0x...
export TOKEN_OPTION_FACTORY=0x...
export RESTRICTED_TOKEN_FACTORY=0x...
export TWAP_MILESTONE_CONDITION=0x...
```

Notes:

- Verify that `UMIA_HOOK_DEPLOYER` matches the broadcasting key and the predicted hook address is
  unoccupied. The deploy script does not check these conditions before its first contract creation,
  so a bad salt or owner can leave a partial deployment. Run a full dry run before broadcast.
- Leave `CCA_FACTORY` unset to deploy a fresh CCA factory (and a zero-fee `ProtocolFeeController`
  unless `PROTOCOL_FEE_CONTROLLER` is set).
- Leave `METAVEST_FACTORY` unset to deploy fresh MetaVesT singletons and a
  `UmiaTwapMilestoneCondition(TWAP_WINDOW)`; the per-venture controller and adapter are created at
  launch (see [the MetaVesT integration](./metavest/README.md)).
- Leave `ZKTLS_VERIFIER_ADDRESS` unset to deploy a fresh `ZkTlsVerifier`. The deployer is its
  initial owner and can later call `transferOwnership(multisig)` to hand over witness-epoch
  administration. Reusing an existing deployment does not add ownership transfer to its bytecode.
- For a fresh verifier, set `ZKTLS_WITNESS_ADDRESS` and `ZKTLS_WITNESS_HOST` to the approved
  attestor's public values from `ZKTLS_SHARED_ATTESTOR` (`@umia/types`). The constructor takes
  `(Witness[] initialWitnesses, uint8 minWitnesses)`; the script initializes a one-witness epoch
  with threshold 1, then advances it to `ZKTLS_CLAIM_EPOCH` with the same witness. No public
  Reclaim witness is trusted implicitly.
- Proof verification accepts only the current epoch, including in the verifier's read-only
  `validateProof` used by new hooks. Rotation immediately rejects earlier and zero-epoch proofs;
  users must regenerate pending proofs. Standing hook registrations are unaffected. Existing
  verifiers and hooks require redeployment to gain these changes.
- New hooks require a verifier with `validateProof`, which returns authenticated parsed context.
  Older verifiers are incompatible and have no fallback. Deploy the new verifier and hook before
  creating the auction; hook deployment no longer needs a separately linked `Claims` library.
- During rollout, review and update the deployment's authority address and code-hash pins against
  the new verifier's compiled executable and observed chain state before publishing configuration.
  `infra/devnet/zktls/authority.ts` pins the currently deployed verifier's executable hash and
  rejects replacement bytecode until that pin is updated.
- Leave `CCA_EXIT_HELPER_ADDRESS` unset to deploy a fresh `CCAExitHelper` (logged as
  `CCAExitHelper deployed at:`). It collapses a live out-bid auction exit into one transaction;
  nothing on-chain references it.
- Leave `USDC_ADDRESS` unset if you do not want the deploy script to approve a money token yet.
- `VESTING_ADMIN`, `VETO_GUARDIAN` and `ACTIVE_LIQUIDITY_KEEPER` are the inputs the script will
  not let you forget: it aborts unless each is either set or explicitly acknowledged as unset. All
  three are changeable later by the owner (`hub.setVestingAdmin`, `hub.setVetoGuardian`,
  `hub.setActiveLiquidityKeeper`).

## Simulate before broadcast

Run the deploy script once without `--broadcast` to catch missing inputs or constructor issues:

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL"
```

If the simulation succeeds, broadcast the deployment with contract verification:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Set `ETHERSCAN_API_KEY` to the block explorer API key for the target chain. This verifies all
deployed contracts in the same step as the broadcast. `foundry.toml` carries explorer entries for
chains that need a non-default verifier URL.

## Capture deployment artifacts

The deploy script logs the addresses you need at the end of the run. Record all of them.

Core outputs printed by the script:

- `UMIA_HUB_ADDRESS`
- `UMIA_MARKET_CORE_ADDRESS`
- `UMIA_GOVERNANCE_EXECUTOR_ADDRESS`
- `CONDITIONAL_MARKET_ORACLE_ADDRESS`
- `CCA_FACTORY_ADDRESS`
- `PROTOCOL_FEE_CONTROLLER_ADDRESS`
- `AUCTION_STATE_LENS_ADDRESS`
- `CCA_LENS_ADDRESS`
- `UMIA_HOOK_V2_ADDRESS` (specific to this independent deployment)
- `LBP_FACTORY_V2_ADDRESS`
- `SPOT_LIQUIDITY_V2_CODE_ADDRESS`
- `ZKTLS_VERIFIER_ADDRESS`
- `UMIA_MARKET_STAKE_ADDRESS`
- `start_block`: the block to index this deployment from

Sanity check before recording: `UMIA_HOOK_V2_ADDRESS` must equal the predicted address from the
mining step. The deploy script asserts this internally, but double-check it against your saved
value.

Also keep the implementation-level and singleton addresses logged earlier in the run
(`<Name> deployed at:` or `<Name> (existing):`):

- `UmiaHub implementation`
- `UmiaMarketCore implementation`
- `Venture implementation`
- `Venture beacon`
- `CCAExitHelper`
- `MetaVesTFactory`, `VestingAllocationFactory`, `TokenOptionFactory`, `RestrictedTokenFactory`,
  `UmiaTwapMilestoneCondition`

Foundry also writes the transaction trace to `broadcast/Deploy.s.sol/<chain-id>/run-latest.json`.
Keep that file until the deployment is fully recorded elsewhere.

## Verify onchain configuration

After broadcast, confirm that the hub points at the freshly deployed contracts and that the money
token approval landed if you set `USDC_ADDRESS`.

The script prints the addresses but does not export them. Set them in your shell first, from the recorded output:

```bash
export UMIA_HUB_ADDRESS=0x... LBP_FACTORY_V2_ADDRESS=0x... UMIA_HOOK_V2_ADDRESS=0x... TWAP_MILESTONE_CONDITION=0x...
```

```bash
cast call "$UMIA_HUB_ADDRESS" "umiaMarketCore()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "defaultGovernanceExecutor()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "conditionalMarketOracle()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "lbpStrategyFactory()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "ccaFactory()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "umiaMarketStake()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "ventureBeacon()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "marketCreationSigner()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "launchAnchorBps()(uint16)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "launchActiveHalfWidthTicks()(int24)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "vestingAdmin()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "vetoGuardian()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "activeLiquidityKeeper()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HUB_ADDRESS" "approvedMoneyTokens(address)(bool)" "$USDC_ADDRESS" --rpc-url "$RPC_URL"

# UmiaHookV2 wiring
cast call "$LBP_FACTORY_V2_ADDRESS" "umiaHook()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HOOK_V2_ADDRESS" "factory()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HOOK_V2_ADDRESS" "hub()(address)" --rpc-url "$RPC_URL"
cast call "$UMIA_HOOK_V2_ADDRESS" "poolManager()(address)" --rpc-url "$RPC_URL"

# vesting condition window
cast call "$TWAP_MILESTONE_CONDITION" "TWAP_WINDOW()(uint32)" --rpc-url "$RPC_URL"
```

Expected result:

- each hub getter returns the address printed by the deploy script,
- `approvedMoneyTokens` returns `true` if you passed `USDC_ADDRESS`,
- `launchAnchorBps` is `7500` and `launchActiveHalfWidthTicks` is `10980`,
- `factoryV2.umiaHook()` returns `UMIA_HOOK_V2_ADDRESS`,
- `hookV2.factory()` returns `LBP_FACTORY_V2_ADDRESS`, `hookV2.hub()` returns `UMIA_HUB_ADDRESS`,
  `hookV2.poolManager()` returns the `POOL_MANAGER` you passed in,
- `UMIA_HOOK_V2_ADDRESS` is identical to the predicted address from the mining step and, for a
  shared identity, to the other chains' hook address,
- `TWAP_WINDOW()` is the window you deployed with.

If you did not set `USDC_ADDRESS`, skip that call.

## Final checklist

- `forge build` and `forge test` passed before deployment
- `UMIA_HOOK_V2_SALT` and `UMIA_HOOK_DEPLOYER` are set to the values from the mining step
- `UMIA_HOOK_DEPLOYER` matches `vm.addr(DEPLOYER_PRIVATE_KEY)`
- deploy script simulated successfully without `--broadcast`
- deploy script broadcast successfully
- `UMIA_HOOK_V2_ADDRESS` matches the predicted address from mining
- `factoryV2.umiaHook() == hookV2`, `hookV2.factory() == factoryV2`, `hookV2.hub() == hub`,
  `hookV2.poolManager() == POOL_MANAGER`
- all printed addresses and `start_block` were recorded
- onchain hub getters match the deployment output

The zkTLS verifier was renamed from `Reclaim` with no input aliases; a set `RECLAIM_ADDRESS` stops the script. The renamed address-book keys retain existing addresses and do not imply a redeployment. See [the migration guide](ZKTLS_VERIFIER_MIGRATION.md) before reusing or replacing a verifier.
