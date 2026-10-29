// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUmiaHub
/// @notice Interface for the Umia Hub registry contract.
interface IUmiaHub {
    // ─────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────

    struct VentureInfo {
        uint256 id;
        address venture;
        string name;
        uint256 createdAt;
    }

    struct CreateVentureParams {
        string name;
        string symbol;
        uint256 initialSupply;
        address moneyToken;
        uint256 tokenSplitToAuction;
        bytes auctionParams;
        uint256 ventureBps;
        bytes32 lbpSalt;
        address[] teamMembers;
        uint256 tradingPauseDuration;
        uint256 startingMonthlyAllowance;
    }

    struct CreateVentureWithTokenParams {
        address token;
        address moneyToken;
        uint256 tokenSplitToAuction;
        bytes auctionParams;
        uint256 ventureBps;
        bytes32 lbpSalt;
        address[] teamMembers;
        uint256 tradingPauseDuration;
        uint256 startingMonthlyAllowance;
    }

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error InvalidInitialSupply();
    error TransferFailed();
    error VentureNotFound();
    error MoneyTokenNotApproved();
    error MarketCoreNotSet();
    error InvalidBps();
    error InvalidExecutionDelay();
    error LbpStrategyFactoryNotSet();
    error DecisionMarketCircuitBreakerAlreadyActive();
    error DecisionMarketCircuitBreakerNotActive();
    error UnauthorizedVeto();
    error VentureBeaconNotSet();
    error CcaFactoryNotSet();
    error InvalidPoolTickSpacing();
    error InvalidLaunchActiveHalfWidth();
    error ActiveMarketsPreventUpdate();
    error InvalidToken();
    error NotVentureToken();
    error TokenOwnerNotHub();
    error TokenBalanceZero();
    error NotVentureLBP();
    error SpotLiquidityVaultAlreadyRegistered();
    error NotSpotMigrator();
    error SpotLiquidityVaultNotRegistered();
    error InvalidSpotLiquidityVault();
    error SpotLiquidityVaultStillFunded();
    error InvalidVestingAuthority();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event VentureCreated(uint256 indexed id, address indexed venture, uint256 createdAt);
    event VentureMinMarketStakeUpdated(uint256 indexed id, uint256 amount);
    event MoneyTokenApprovalChanged(address indexed token, bool approved);
    event UmiaMarketCoreUpdated(address indexed oldManager, address indexed newManager);
    event DefaultGovernanceExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);
    event GovernanceExecutorUpdated(address indexed venture, address indexed oldExecutor, address indexed newExecutor);
    event ConditionalMarketOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event WinningMarketThresholdUpdated(uint16 oldBps, uint16 newBps);
    event DecisionMarketExecutionDelayUpdated(uint32 oldDelay, uint32 newDelay);
    event MarketCreationSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event LbpStrategyFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event DecisionMarketCircuitBreakerTripped(uint256 indexed marketId);
    event DecisionMarketCircuitBreakerReset(uint256 indexed marketId);
    event VetoGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    event VestingAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event VentureBeaconUpdated(address indexed oldBeacon, address indexed newBeacon);
    event CcaFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event UmiaMarketStakeUpdated(address indexed oldStake, address indexed newStake);
    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event SpotSwapFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event SpotProtocolFeeCutBpsUpdated(uint16 oldBps, uint16 newBps);
    event DecisionSwapFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event DecisionProtocolFeeCutBpsUpdated(uint16 oldBps, uint16 newBps);
    event DefaultPoolTickSpacingUpdated(int24 tickSpacing);
    event LaunchAnchorBpsUpdated(uint16 oldBps, uint16 newBps);
    event LaunchActiveHalfWidthTicksUpdated(int24 oldHalfWidth, int24 newHalfWidth);
    event MigrationDelayBlocksUpdated(uint64 blocks_);
    event SweepDelayBlocksUpdated(uint64 blocks_);
    event SpotLiquidityVaultRegistered(address indexed venture, address indexed vault);
    event SpotLiquidityVaultMigrated(address indexed venture, address indexed oldVault, address indexed newVault);
    event SpotMigratorUpdated(address indexed oldMigrator, address indexed newMigrator);
    event ActiveLiquidityKeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event VentureVestingAuthoritySet(uint256 indexed ventureId, address indexed authority);

    // ─────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────

    function owner() external view returns (address);
    function ventureCount() external view returns (uint256);
    function ventureById(uint256 id) external view returns (VentureInfo memory);
    function ventureTokenById(uint256 id) external view returns (address);
    function ventureMoneyTokenById(uint256 id) external view returns (address);
    function approvedMoneyTokens(address token) external view returns (bool);
    function umiaMarketCore() external view returns (address);
    function defaultGovernanceExecutor() external view returns (address);
    function governanceExecutorByVenture(address venture) external view returns (address);
    function governanceExecutor(address venture) external view returns (address);
    function conditionalMarketOracle() external view returns (address);
    function ccaFactory() external view returns (address);
    function winningMarketThresholdBps() external view returns (uint16);
    function decisionMarketExecutionDelay() external view returns (uint32);
    function marketCreationSigner() external view returns (address);
    function lbpStrategyFactory() external view returns (address);
    function decisionMarketCircuitBreakerActive(uint256 marketId) external view returns (bool);
    function vetoGuardian() external view returns (address);

    function vestingAdmin() external view returns (address);
    /// @notice The only caller allowed to move a venture's spot vault pointer (`migrateSpotLiquidityVault`).
    function spotMigrator() external view returns (address);
    /// @notice Default keeper for every venture's ActiveLiquidityManager unless the venture overrides it.
    function activeLiquidityKeeper() external view returns (address);
    /// @notice The VentureVestingAuthority that owns `ventureId`'s vesting grants, or zero if none.
    function ventureVestingAuthority(uint256 ventureId) external view returns (address);
    function ventureBeacon() external view returns (address);
    /// @notice The single recipient of all Umia protocol fee revenue (spot + decision venues).
    function protocolFeeRecipient() external view returns (address);

    /// @notice Spot-pool swap fee, in bps of the trade (converted to Uniswap pips by the LBP).
    function spotSwapFeeBps() external view returns (uint16);

    /// @notice Protocol's cut of the spot swap fee, in bps of the fee (10000 = 100%).
    function spotProtocolFeeCutBps() external view returns (uint16);

    /// @notice Decision-market swap fee, in bps of the trade (snapshotted per market).
    function decisionSwapFeeBps() external view returns (uint16);

    /// @notice Protocol's cut of the decision swap fee, in bps of the fee (10000 = 100%).
    function decisionProtocolFeeCutBps() external view returns (uint16);

    function defaultPoolTickSpacing() external view returns (int24);

    /// @notice Share of a V2 launch's pool-bound liquidity that goes to the anchor vault (0 = unset).
    function launchAnchorBps() external view returns (uint16);

    /// @notice Half width, in ticks, of the range a V2 launch opens for the ALM (0 = unset).
    function launchActiveHalfWidthTicks() external view returns (int24);
    function migrationDelayBlocks() external view returns (uint64);
    function sweepDelayBlocks() external view returns (uint64);
    function umiaMarketStake() external view returns (address);
    function ventureLiquidityVault(address venture) external view returns (address);

    // ─────────────────────────────────────────────────────────
    // State-Changing Functions
    // ─────────────────────────────────────────────────────────

    function setVentureBeacon(address _beacon) external;
    function setUmiaMarketCore(address _umiaMarketCore) external;
    function setDefaultGovernanceExecutor(address _executor) external;
    function setVentureGovernanceExecutor(uint256 _ventureId, address _executor) external;
    function setConditionalMarketOracle(address _oracle) external;
    function setCcaFactory(address _factory) external;
    function setWinningMarketThresholdBps(uint16 bps) external;
    function setDecisionMarketExecutionDelay(uint32 delay) external;
    function setMarketCreationSigner(address _signer) external;
    function setApprovedMoneyToken(address _token, bool _approved) external;
    function setLbpStrategyFactory(address _factory) external;
    function setVentureMinMarketStake(uint256 _ventureId, uint256 _amount) external;
    function setProtocolFeeRecipient(address recipient) external;
    function setSpotSwapFeeBps(uint16 bps) external;
    function setSpotProtocolFeeCutBps(uint16 bps) external;
    function setDecisionSwapFeeBps(uint16 bps) external;
    function setDecisionProtocolFeeCutBps(uint16 bps) external;
    function setDefaultPoolTickSpacing(int24 tickSpacing) external;
    function setLaunchAnchorBps(uint16 bps) external;
    function setLaunchActiveHalfWidthTicks(int24 halfWidth) external;
    function setMigrationDelayBlocks(uint64 blocks_) external;
    function setSweepDelayBlocks(uint64 blocks_) external;
    function registerSpotLiquidityVault(address venture, address vault) external;
    function migrateSpotLiquidityVault(address venture, address newVault) external;
    function setSpotMigrator(address _migrator) external;
    function setActiveLiquidityKeeper(address _keeper) external;
    function setUmiaMarketStake(address _umiaMarketStake) external;
    function setVetoGuardian(address _guardian) external;

    function setVestingAdmin(address _admin) external;
    function setVentureVestingAuthority(uint256 ventureId, address authority) external;
    function tripDecisionMarketCircuitBreaker(uint256 _marketId) external;
    function createVenture(CreateVentureParams calldata _params) external returns (uint256 id, address payable venture);
    function createVentureWithToken(CreateVentureWithTokenParams calldata _params)
        external
        returns (uint256 id, address payable venture);
}
