# Testnet atomic market utilities

**Optional testnet tooling. Not part of the protocol.** These helpers let you open or settle a
decision market when the venture's spot pool has been pushed far from its 30-minute TWAP (for
example by testnet sim bots) and `createMarket` / `settleMarket` revert with `SpotPriceDeviationTooHigh`.

## Why they exist

`SpotLiquidityVault` guards its seed-liquidity moves with a sandwich check: the current spot tick
must be within `MAX_TICK_DEVIATION` (1000 ticks, ~10.5%) of the 30-minute TWAP. Market **creation**
pulls seed liquidity and **settlement** returns it, so both re-run that check. On a chain with
adversarial spot flow the guard can stay tripped indefinitely, blocking creation and settlement.

A single-block trade barely moves a time-weighted average, so the fix is to move the manipulable
value (spot) onto the honest one (the TWAP) **in the same transaction** as the create/settle, so the
bots can't interleave. That's all these contracts do:

- `SpotTwapPinner`: shared base: reads the venture pool's TWAP and swaps spot exactly onto it
  inside a PoolManager unlock.
- `AtomicMarketOpener`: pin → deposit stake → `createMarket`, atomically.
- `AtomicMarketSettler`: pin → `settleMarket`, atomically (`settleMarket` is permissionless, so no
  signer or stake is involved).

Each is single-use: deploy, fund with the venture token (the pin sells venture, since bots push
spot **above** the TWAP), run once, discard. Leftover tokens are swept back to the deployer.

## Usage

`HUB` is the `UmiaHub` proxy, `POOL_MANAGER` the Uniswap v4 PoolManager and `HOOK` the V1
`UmiaHook` the venture's pool runs on. Run with the deployer key; the opener additionally needs the
market-creation signer key. Export the keys first.

### Settle a stuck ended market

```bash
HUB=0x... POOL_MANAGER=0x... HOOK=0x... \
VENTURE_ID=1 MARKET_ID=1 \
DEPLOYER_PRIVATE_KEY=0x... \
forge script script/testnet-utils/SettleMarket.s.sol:SettleMarket \
  --rpc-url "$RPC_URL" --broadcast --slow
```

Optional: `PIN_FUNDING` (venture-token base units, default `50_000e18`). After settling, the winner
executes after the veto window: check `winningProposalByMarketId`, then `executeWinningProposal`.

### Open a market past the guard

```bash
HUB=0x... POOL_MANAGER=0x... HOOK=0x... \
VENTURE_ID=1 \
MARKET_TITLE='Should we do X?' \
PROPOSAL_TITLES='Do nothing,Do X' \
PROPOSAL_PAYLOADS='0x,0x<abi-encoded ExecutionPlanV1>' \
TRADING_DURATION=3600 \
DEPLOYER_PRIVATE_KEY=0x... MARKET_CREATION_SIGNER_KEY=0x... \
forge script script/testnet-utils/OpenMarket.s.sol:OpenMarket \
  --rpc-url "$RPC_URL" --broadcast --slow
```

`PROPOSAL_TITLES` is comma-delimited (>= 2). `PROPOSAL_PAYLOADS` is comma-delimited hex aligned 1:1
with the titles (`0x` = informational); omit it to make every proposal informational. Build an
`ExecutionPlanV1` (`src/libraries/GovernanceTypes.sol`) in a Foundry script, ABI-encode it
(`bytes memory payload = abi.encode(plan);`) and paste the hex; `test/governance/` has plans built for
every action type. `TRADING_DURATION` defaults to the protocol default (3 days);
`PIN_FUNDING` defaults to `20_000e18` venture-token base units (pin swap + stake).

## Notes

- These helpers target the V1 stack: the pinner reads `IUmiaHook.observe` on the `HOOK` you pass,
  builds the pool key from the V1 spot fee and tick spacing, and the guard it works around is
  `SpotLiquidityVault`'s 30-minute band. A venture migrated to V2 (`SpotLiquidityVaultV2` on
  `UmiaHookV2`) also checks spot against a 6-hour TWAP band (`LONG_TWAP_WINDOW`), which a
  same-block pin cannot move, so they are not a fit for V2 pools.
- The pin sells the venture token because bots keep spot **above** the TWAP. If spot is ever
  **below** the TWAP, the pin would need the money token instead; fund accordingly.
- Fund generously: reversing a large price move can need a lot of venture token. Whatever isn't
  spent is swept back to the deployer in the same transaction.
- `test/testnet-utils/AtomicMarketHelpers.t.sol` proves both helpers against a locally deployed
  protocol: a bare create/settle reverts on the guard, the atomic helper succeeds.
