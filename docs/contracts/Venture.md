# Venture

Source: `src/core/Venture.sol`

## Purpose

Treasury contract for a single venture.

- Owns venture token mint/burn rights.
- Holds treasury assets.
- Exposes governance-controlled treasury actions.
- Tracks team membership, monthly allowances, documents, and liquidation state.

## Key state

- `token`, `moneyToken`, `lbp`, `HUB`
- `minMarketStake`
- `monthlyAllowance[token]` (`amount`, `spent`, `currentMonth`)
- `allowanceSources[source]`, `allowanceSourceCount[underlying]` (budget sources, see GOVERNANCE_TREASURY_LAYER.md)
- `isTeamMember`
- `documents`, `documentCount`
- `tradingPauseDuration`, `tradingPauseDeadline` (post-LBP pause, at most `MAX_TRADING_PAUSE_DURATION = 60 days`)
- liquidation:
  - `liquidationActive`
  - `authorizedLiquidator`

## Important functions

- Initialization/callbacks:
  - `initializeProxy(hub)`, then `initialize(...)` (only hub)
  - `onLBPMigrated()` (only configured LBP; pauses the token for `tradingPauseDuration` if non-zero)
  - `startTrading()` (team members any time, anyone after `tradingPauseDeadline`; unpauses the token)
- Treasury mutation:
  - `mint`, `burn`, `withdraw`, `withdrawERC721`, `withdrawERC1155`, `executeCall`
- Governance-only updates:
  - `updateTeamMember`
  - `updateMonthlyAllowance`
  - `setAllowance`, `setAllowanceSource`
  - `uploadDocument`
  - `setLiquidator`
- Team-member withdrawal:
  - `withdrawMonthlyAllowance`, `withdrawMonthlyAllowanceFrom`
- Liquidation claims:
  - handled by the liquidator (`ILiquidator.claim()`), which calls `burnFrom` and `withdraw` on the venture
- Hub-only:
  - `setMinMarketStake`

## Access control

- `onlyExecutor` (the Hub's `governanceExecutor(venture)`): treasury mutation and governance updates, including UUPS upgrades.
- `onlyHub`: `setMinMarketStake`.
- During liquidation the `withdraw*` functions and `burnFrom` accept only `authorizedLiquidator`.
- `whenNotLiquidating`: blocks most normal treasury operations once liquidation starts.

## Notes

- Allowance reset uses `CalendarLib.timestampToMonth`.
- The venture does not validate liquidation assets; `SimpleLiquidator.initialize` rejects ERC721 and ERC1155 entries (`InvalidAssetType`).
- Spot liquidity lives outside the treasury: in `SpotLiquidityVault` for a V1 venture; in `SpotLiquidityVaultV2` plus the venture's `ActiveLiquidityManager` for a V2 venture, registered at launch by `UmiaLBPV2` or, for a migrated V1 venture, through `migrateSpotLiquidityVault`. The treasury holds the vault's shares.
