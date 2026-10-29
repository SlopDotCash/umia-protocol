# Contract Reference Index

These references describe the current contracts in `src/`.

## Core

- [UmiaHub](./UmiaHub.md)
- [Venture](./Venture.md)
- [UmiaMarketCore](./UmiaMarketCore.md)
- [GovernanceExecutor](./GovernanceExecutor.md)

## V2 spot liquidity

The V2 spot liquidity release. New launches land here once the Hub's launch factory points at `UmiaLBPFactoryV2`; ventures on V1 move here through a migration proposal.

- [UmiaHookV2](./UmiaHookV2.md)
- [SpotLiquidityVaultV2](./SpotLiquidityVaultV2.md)
- [ActiveLiquidityManager](./ActiveLiquidityManager.md)
- [SpotMigrator](./SpotMigrator.md)
- [UmiaLBPV2 / UmiaLBPFactoryV2](./UmiaLBPV2.md)

## Periphery

- [ConditionalMarketOracle](./ConditionalMarketOracle.md)
- [UmiaValidationHook](./UmiaValidationHook.md)

## Launchpad / token

- [UmiaLBP](./UmiaLBP.md)
- [UmiaLBPFactory](./UmiaLBPFactory.md)
- [VentureToken](./VentureToken.md)

## Incentive / vesting

- [UmiaTwapMilestoneCondition](./UmiaTwapMilestoneCondition.md)
- [VentureVestingAuthority](./VentureVestingAuthority.md)

See [`../metavest/`](../metavest/README.md) for how these compose into the full MetaVesT vesting integration.

## Shared libraries (governance path)

- [GovernanceTypes](./GovernanceTypes.md)
- [GovernancePayloadValidator + GovernanceActions](./GovernanceLibraries.md)
