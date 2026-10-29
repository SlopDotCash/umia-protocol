# UmiaLBPFactory

Source: `src/launchpad/UmiaLBPFactory.sol`

## Purpose

Factory for deploying `UmiaLBP` strategy contracts via CREATE2. liquidity-launcher v3 removed the `StrategyFactory` base, so the factory implements `IDistributorFactory` directly and reproduces the salt derivation (`keccak256(abi.encode(sender, salt))`) and address precomputation (`getAddress`). Superseded for new launches by `UmiaLBPFactoryV2` (see [UmiaLBPV2](./UmiaLBPV2.md)); the Hub selects the factory with `setLbpStrategyFactory`.

## Key state

- `poolManager`, `umiaHook`, `hub` (immutables)
- `lbpCreationCodePointer`, `vaultCreationCodePointer` (immutable SSTORE2 pointers to the `UmiaLBP` and `SpotLiquidityVault` creation code, written in the constructor so neither sits in factory or LBP bytecode)
- `isLBP[address]` (deployed strategies; `UmiaHook.registerPool` accepts only these)

## Important behavior

- `create(token, totalSupply, configData, salt)`: Hub-only (`Unauthorized`), deploys via CREATE2, marks `isLBP`, emits `DistributionInitialized`.
- `_validateParamsAndReturnDeployedBytecode(...)`:
  - validates `totalSupply <= uint128.max` (`InvalidAmount`)
  - decodes the config tuple `(tokenSplitToAuction, moneyToken, auctionParams, venture, ventureBps)`
  - returns the `UmiaLBP` creation code read from SSTORE2 with constructor args, including `vaultCreationCodePointer`.

## Notes

- Validates non-zero `poolManager`, `umiaHook` and `hub` addresses in constructor.
