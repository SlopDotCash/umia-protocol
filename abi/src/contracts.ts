export const CONTRACTS = [
  "UmiaHub",
  "UmiaMarketCore",
  "UmiaMarketStake",
  "ConditionalMarketOracle",
  "Venture",
  "VentureToken",
  "MockERC20",
  "UmiaLBP",
  "UmiaLBPFactory",
  "SpotLiquidityVault",
  "UmiaHook",
  "CCAExitHelper",
  "UmiaValidationHook",
  "ContinuousClearingAuction",
  "AuctionStateLens",
  "CCALens",
  "GovernanceExecutor",
  "UmiaHookV2",
  "SpotLiquidityVaultV2",
  "ActiveLiquidityManager",
  "SpotMigrator",
  "UmiaLBPV2",
  "UmiaLBPFactoryV2",
] as const;

// Interfaces with no in-scope implementer: SDK consumers (e.g. anyone
// writing a liquidator) need these ABIs to decode errors their own
// contracts emit. Interfaces that DO have an implementer in CONTRACTS
// don't need to be listed here; their errors propagate into the
// implementing contract's ABI via inheritance.
export const INTERFACES = ["ILiquidator"] as const;

// Libraries that declare custom errors. solc only bubbles a library
// error into a calling contract's ABI when it can prove the error is
// reachable from a non-pruned path. To guarantee SDK error decoding for
// every revert the protocol can produce, ship the library ABIs too.
export const LIBRARIES = ["GovernanceActions", "GovernancePayloadValidator"] as const;

export type ContractName = (typeof CONTRACTS)[number];
export type InterfaceName = (typeof INTERFACES)[number];
export type LibraryName = (typeof LIBRARIES)[number];

export const ALL_ARTIFACTS = [...CONTRACTS, ...INTERFACES, ...LIBRARIES] as const;

export const FOUNDRY_ARTIFACT_PATHS = ALL_ARTIFACTS.map((name) => `${name}.sol/${name}.json`);
