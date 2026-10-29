// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDistributor} from "@liquidity-launcher/interfaces/IDistributor.sol";
import {IDistributorFactory} from "@liquidity-launcher/interfaces/IDistributorFactory.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {IUmiaMarketCore} from "../interfaces/IUmiaMarketCore.sol";
import {Venture} from "./Venture.sol";
import {VentureProxy} from "./VentureProxy.sol";
import {VentureToken} from "../tokens/VentureToken.sol";
import {IVentureToken} from "../interfaces/IVentureToken.sol";
import {IVentureVestingAuthority} from "../interfaces/IVentureVestingAuthority.sol";
import {SpotLiquidityV2Deploy} from "../libraries/SpotLiquidityV2Deploy.sol";
import {ActiveSlices} from "../libraries/ActiveSlices.sol";

/// @title UmiaHub
/// @notice The hub registry contract for Umia ventures
contract UmiaHub is Initializable, UUPSUpgradeable, Ownable, IUmiaHub {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    /// @notice The minimum initial supply of a venture token.
    uint256 public constant MIN_INITIAL_SUPPLY = 1e2 * 1e18; // 100 with 18 decimals
    /// @notice The maximum initial supply of a venture token.
    uint256 public constant MAX_INITIAL_SUPPLY = 1e12 * 1e18; // 1T with 18 decimals

    /// @notice The maximum value for a basis point.
    uint256 private constant MAX_BPS = 10_000;

    /// @notice Minimum winning-market threshold (basis points).
    /// @dev Prevents a near-zero threshold letting a 1-wei TWAP margin decide governance.
    uint16 private constant MIN_WINNING_THRESHOLD_BPS = 100;

    /// @notice The maximum decision-market execution delay (12 hours).
    uint32 public constant MAX_EXECUTION_DELAY = 12 hours;
    /// @notice The minimum decision-market execution delay (1 hour).
    uint32 public constant MIN_EXECUTION_DELAY = 1 hours;
    /// @notice The decision-market execution delay applied on initialization (4 hours).
    uint32 public constant DEFAULT_EXECUTION_DELAY = 4 hours;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    /// @notice The number of ventures created.
    uint256 public ventureCount;

    /// @notice A mapping of venture IDs to venture information. Starts at 1.
    mapping(uint256 => VentureInfo) private _ventureById;

    /// @notice Approved money tokens that can be used for venture creation.
    mapping(address => bool) public approvedMoneyTokens;

    /// @notice The address of the UmiaMarketCore contract.
    address public umiaMarketCore;

    /// @notice The default governance executor used by ventures.
    address public defaultGovernanceExecutor;

    /// @notice Optional override for a venture's governance executor.
    mapping(address => address) public governanceExecutorByVenture;

    /// @notice The address of the ConditionalMarketOracle contract (CPMM decision market oracle).
    address public conditionalMarketOracle;

    /// @notice The winning threshold in bps that determines the winning proposal.
    uint16 public winningMarketThresholdBps;

    /// @notice The authorized signer for market creation approvals.
    address public marketCreationSigner;

    /// @notice The address of the LBP strategy factory (UmiaLBPFactory).
    address public lbpStrategyFactory;

    /// @notice The address of the ContinuousClearingAuctionFactory contract.
    address public ccaFactory;

    /// @notice Circuit breaker (veto) per market ID. While active, the market's winning-proposal
    ///         execution is blocked. Reversible via `resetDecisionMarketCircuitBreaker` (owner-only).
    mapping(uint256 => bool) public decisionMarketCircuitBreakerActive;

    /// @notice The Venture beacon (shared implementation source for Venture proxies).
    address public ventureBeacon;

    /// @notice The address of the UmiaMarketStake contract.
    address public umiaMarketStake;

    /// @notice Delay after a market settles before its winning proposal can be executed, giving
    ///         governance time to trip the circuit breaker.
    /// @dev Snapshotted into each market at creation. Bounded by MAX_EXECUTION_DELAY.
    uint32 public decisionMarketExecutionDelay;

    // ─────────────────────────────────────────────────────────
    // Protocol fees
    //
    // Each venue charges a swap fee (bps of the trade); the protocol keeps a cut (bps of the fee) and
    // LPs keep the rest. Every cut pays protocolFeeRecipient.
    // ─────────────────────────────────────────────────────────

    /// @notice Max swap fee a venue may charge, in bps of the trade.
    uint16 public constant MAX_SWAP_FEE_BPS = 1_000; // 10%

    /// @notice Recipient of all protocol fee revenue.
    address public protocolFeeRecipient;

    /// @notice Spot swap fee, in bps of the trade. The LBP converts it to Uniswap pips (x100) at pool init.
    uint16 public spotSwapFeeBps;

    /// @notice Protocol's cut of the spot fee, in bps of the fee. Skimmed by the vault; the rest goes to LPs.
    uint16 public spotProtocolFeeCutBps;

    /// @notice Decision-market swap fee, in bps of the trade. Snapshotted per market at creation.
    uint16 public decisionSwapFeeBps;

    /// @notice Protocol's cut of the decision fee, in bps of the fee. The rest stays in the market reserves.
    uint16 public decisionProtocolFeeCutBps;

    /// @notice Per-venture SpotLiquidityVault, keyed by venture address, registered by the
    ///         venture's LBP at migration.
    mapping(address => address) private _ventureLiquidityVault;

    /// @notice Canonical tick spacing (V4 PoolKey.tickSpacing) for every venture's spot pool.
    int24 public defaultPoolTickSpacing;

    /// @notice Blocks after the auction's end block before an LBP may migrate into its spot pool.
    uint64 public migrationDelayBlocks;

    /// @notice Blocks after an LBP migrates before its leftover dust may be swept to the venture.
    uint64 public sweepDelayBlocks;

    /// @notice Address authorized to trip (but not reset) decision-market circuit breakers.
    /// @dev Distinct from the owner so a fast-reacting key can veto while the owner sits behind a
    ///      timelock. `address(0)` means unset: only the owner can trip. Resetting stays owner-only.
    address public vetoGuardian;

    /// @notice Address authorized to terminate (and reissue) vesting grants on every venture adapter.
    /// @dev Distinct from the owner so this operational key is not the upgrade key. `address(0)` means
    ///      unset: only each venture's own futarchy can drive its vesting. A venture may opt out
    ///      individually via `VentureVestingAuthority.setVestingAdminRevoked`.
    address public vestingAdmin;

    /// @notice The only caller allowed to move a venture's spot vault pointer to a new vault.
    address public spotMigrator;

    /// @notice Default keeper for every venture's ActiveLiquidityManager unless the venture overrides it.
    address public activeLiquidityKeeper;

    /// @notice Venture id → the VentureVestingAuthority that owns its vesting grants.
    /// @dev The canonical link between a venture and its grants. Adapters are deployed through the
    ///      permissionless MetaVesT factory, so nothing else onchain can tell a real one from a copy.
    mapping(uint256 ventureId => address) public ventureVestingAuthority;

    /// @notice Share of a V2 launch's pool-bound liquidity that bootstraps the anchor vault; the rest
    ///         funds the ALM. Zero means unset, and `UmiaLBPV2.migrate` reverts until the owner sets it.
    uint16 public launchAnchorBps;

    /// @notice Half width, in ticks, of the single range a V2 launch opens for the ALM around the
    ///         clearing tick. Zero means unset.
    int24 public launchActiveHalfWidthTicks;

    /// @notice Gap for future upgrades.
    uint256[46] private __gap;

    // ─────────────────────────────────────────────────────────
    // Upgrade
    // ─────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(address(1)) {
        _disableInitializers();
    }

    /// @notice Initialize the UmiaHub contract.
    /// @param _owner The owner of the contract.
    function initialize(address _owner) external initializer {
        _transferOwnership(_owner);

        // Set the default winning market threshold to 2% by default.
        winningMarketThresholdBps = 200;
        decisionMarketExecutionDelay = DEFAULT_EXECUTION_DELAY;

        // Fee, pool, and launchpad-timing defaults (Base ~2s blocks). All governance-tunable.
        spotSwapFeeBps = 100; // 1%
        spotProtocolFeeCutBps = 5_000; // 50% of the fee
        decisionSwapFeeBps = 100; // 1%
        decisionProtocolFeeCutBps = 5_000; // 50% of the fee
        defaultPoolTickSpacing = 60;
        migrationDelayBlocks = 300;
        sweepDelayBlocks = 7200;
    }

    /// @notice Authorize the upgrade of the contract.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Get the owner of the contract.
    /// @return The owner of the contract.
    function owner() public view override(Ownable, IUmiaHub) returns (address) {
        return Ownable.owner();
    }

    // ─────────────────────────────────────────────────────────
    // Getters
    // ─────────────────────────────────────────────────────────

    /// @notice Get a venture by ID
    /// @param id The ID of the venture
    /// @return The venture information
    function ventureById(uint256 id) external view returns (VentureInfo memory) {
        return _ventureById[id];
    }

    /// @notice Get the token address of a venture by ID
    /// @param id The ID of the venture
    /// @return The token address
    function ventureTokenById(uint256 id) external view returns (address) {
        return IVenture(_ventureById[id].venture).token();
    }

    /// @notice Get the money token address of a venture by ID
    /// @param id The ID of the venture
    /// @return The money token address
    function ventureMoneyTokenById(uint256 id) external view returns (address) {
        return IVenture(_ventureById[id].venture).moneyToken();
    }

    /// @notice Get the governance executor address for a venture.
    /// @param venture The venture treasury address.
    /// @return The executor address (venture override or default).
    function governanceExecutor(address venture) public view returns (address) {
        address executor = governanceExecutorByVenture[venture];
        if (executor == address(0)) {
            return defaultGovernanceExecutor;
        }
        return executor;
    }

    // ─────────────────────────────────────────────────────────
    // Setters
    // ─────────────────────────────────────────────────────────

    /// @notice Set the Venture beacon address used for future Venture deployments.
    /// @dev This only affects Ventures created after this call. Existing Venture proxies
    ///      have their beacon hardcoded as an immutable. To upgrade all existing Ventures
    ///      that follow the beacon, call `UpgradeableBeacon.upgradeTo(newImpl)` on the
    ///      current beacon contract instead.
    /// @param _beacon the address of the new Venture beacon.
    function setVentureBeacon(address _beacon) external onlyOwner {
        address oldBeacon = ventureBeacon;
        ventureBeacon = _beacon;
        emit VentureBeaconUpdated(oldBeacon, _beacon);
    }

    /// @notice Set the UmiaMarketCore address
    /// @param _umiaMarketCore The address of the UmiaMarketCore contract
    function setUmiaMarketCore(address _umiaMarketCore) external onlyOwner withNoActiveMarkets {
        address oldManager = umiaMarketCore;
        umiaMarketCore = _umiaMarketCore;
        emit UmiaMarketCoreUpdated(oldManager, _umiaMarketCore);
    }

    /// @notice Set the default governance executor address
    /// @param _executor The executor contract address
    function setDefaultGovernanceExecutor(address _executor) external onlyOwner {
        address oldExecutor = defaultGovernanceExecutor;
        defaultGovernanceExecutor = _executor;
        emit DefaultGovernanceExecutorUpdated(oldExecutor, _executor);
    }

    /// @notice Set a venture-specific governance executor address
    /// @param _ventureId The venture ID
    /// @param _executor The executor contract address
    function setVentureGovernanceExecutor(uint256 _ventureId, address _executor) external onlyOwner {
        VentureInfo memory info = _ventureById[_ventureId];
        if (info.venture == address(0)) revert VentureNotFound();

        address oldExecutor = governanceExecutorByVenture[info.venture];
        governanceExecutorByVenture[info.venture] = _executor;
        emit GovernanceExecutorUpdated(info.venture, oldExecutor, _executor);
    }

    /// @notice Set the ConditionalMarketOracle address
    /// @param _oracle The address of the ConditionalMarketOracle contract
    function setConditionalMarketOracle(address _oracle) external onlyOwner withNoActiveMarkets {
        address oldOracle = conditionalMarketOracle;
        conditionalMarketOracle = _oracle;
        emit ConditionalMarketOracleUpdated(oldOracle, _oracle);
    }

    /// @notice Set the winning market threshold in basis points
    /// @param bps The new winning market threshold in basis points
    function setWinningMarketThresholdBps(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS || bps < MIN_WINNING_THRESHOLD_BPS) revert InvalidBps();
        uint16 oldBps = winningMarketThresholdBps;
        winningMarketThresholdBps = bps;
        emit WinningMarketThresholdUpdated(oldBps, bps);
    }

    /// @notice Set the delay after a market settles before its winning proposal can be executed.
    /// @param delay The new execution delay in seconds, between MIN_EXECUTION_DELAY and MAX_EXECUTION_DELAY.
    function setDecisionMarketExecutionDelay(uint32 delay) external onlyOwner {
        if (delay < MIN_EXECUTION_DELAY || delay > MAX_EXECUTION_DELAY) revert InvalidExecutionDelay();
        uint32 oldDelay = decisionMarketExecutionDelay;
        decisionMarketExecutionDelay = delay;
        emit DecisionMarketExecutionDelayUpdated(oldDelay, delay);
    }

    /// @notice Set the authorized signer for market creation approvals
    /// @param _signer The address that will sign market creation approvals
    function setMarketCreationSigner(address _signer) external onlyOwner {
        address oldSigner = marketCreationSigner;
        marketCreationSigner = _signer;
        emit MarketCreationSignerUpdated(oldSigner, _signer);
    }

    /// @notice Set the approval status of a money token
    /// @param _token The address of the money token
    /// @param _approved Whether the token is approved
    function setApprovedMoneyToken(address _token, bool _approved) external onlyOwner {
        approvedMoneyTokens[_token] = _approved;
        emit MoneyTokenApprovalChanged(_token, _approved);
    }

    /// @notice Set the LBP strategy factory address
    /// @param _factory The address of the UmiaLBPFactory contract
    function setLbpStrategyFactory(address _factory) external onlyOwner {
        address oldFactory = lbpStrategyFactory;
        lbpStrategyFactory = _factory;
        emit LbpStrategyFactoryUpdated(oldFactory, _factory);
    }

    /// @notice Set the protocol fee recipient.
    /// @param recipient The new recipient.
    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        address oldRecipient = protocolFeeRecipient;
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(oldRecipient, recipient);
    }

    /// @notice Set the spot swap fee, in bps of the trade.
    /// @param bps The new fee, capped at MAX_SWAP_FEE_BPS.
    /// @dev Nonzero: a V2 pool's active-liquidity band is the fee in ticks.
    function setSpotSwapFeeBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_SWAP_FEE_BPS) revert InvalidBps();
        uint16 oldBps = spotSwapFeeBps;
        spotSwapFeeBps = bps;
        emit SpotSwapFeeBpsUpdated(oldBps, bps);
    }

    /// @notice Set the protocol's cut of the spot fee, in bps of the fee.
    /// @param bps The new cut, capped at MAX_BPS.
    function setSpotProtocolFeeCutBps(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS) revert InvalidBps();
        uint16 oldBps = spotProtocolFeeCutBps;
        spotProtocolFeeCutBps = bps;
        emit SpotProtocolFeeCutBpsUpdated(oldBps, bps);
    }

    /// @notice Set the decision swap fee, in bps of the trade.
    /// @param bps The new fee, capped at MAX_SWAP_FEE_BPS.
    function setDecisionSwapFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_SWAP_FEE_BPS) revert InvalidBps();
        uint16 oldBps = decisionSwapFeeBps;
        decisionSwapFeeBps = bps;
        emit DecisionSwapFeeBpsUpdated(oldBps, bps);
    }

    /// @notice Set the protocol's cut of the decision fee, in bps of the fee.
    /// @param bps The new cut, capped at MAX_BPS.
    function setDecisionProtocolFeeCutBps(uint16 bps) external onlyOwner {
        if (bps > MAX_BPS) revert InvalidBps();
        uint16 oldBps = decisionProtocolFeeCutBps;
        decisionProtocolFeeCutBps = bps;
        emit DecisionProtocolFeeCutBpsUpdated(oldBps, bps);
    }

    /// @notice Set the canonical tick spacing applied to every venture's spot pool at migration.
    /// @dev Clears `launchActiveHalfWidthTicks` when it no longer fits the new spacing, so launches
    ///      revert `LaunchSplitUnset` until the owner sets a width that does, instead of failing inside
    ///      the ALM seed.
    /// @param tickSpacing The V4 pool tick spacing, within [MIN_TICK_SPACING, MAX_TICK_SPACING].
    function setDefaultPoolTickSpacing(int24 tickSpacing) external onlyOwner {
        if (tickSpacing < TickMath.MIN_TICK_SPACING || tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert InvalidPoolTickSpacing();
        }
        defaultPoolTickSpacing = tickSpacing;
        emit DefaultPoolTickSpacingUpdated(tickSpacing);
        int24 halfWidth = launchActiveHalfWidthTicks;
        if (halfWidth != 0 && (halfWidth % tickSpacing != 0 || halfWidth > _maxLaunchActiveHalfWidth())) {
            launchActiveHalfWidthTicks = 0;
            emit LaunchActiveHalfWidthTicksUpdated(halfWidth, 0);
        }
    }

    /// @notice Set how a V2 launch splits its pool-bound liquidity: `bps` to the anchor vault, the rest
    ///         to the ALM. At least `SpotLiquidityV2Deploy.MIN_ANCHOR_BPS`; `MAX_BPS` gives the ALM nothing.
    function setLaunchAnchorBps(uint16 bps) external onlyOwner {
        if (bps < SpotLiquidityV2Deploy.MIN_ANCHOR_BPS || bps > MAX_BPS) revert InvalidBps();
        uint16 oldBps = launchAnchorBps;
        launchAnchorBps = bps;
        emit LaunchAnchorBpsUpdated(oldBps, bps);
    }

    /// @notice Set the half width of the range a V2 launch opens for the ALM. A positive multiple of
    ///         `defaultPoolTickSpacing`, no wider than the ALM's default `maxWidthTicks` allows.
    function setLaunchActiveHalfWidthTicks(int24 halfWidth) external onlyOwner {
        if (halfWidth <= 0 || halfWidth % defaultPoolTickSpacing != 0 || halfWidth > _maxLaunchActiveHalfWidth()) {
            revert InvalidLaunchActiveHalfWidth();
        }
        int24 oldHalfWidth = launchActiveHalfWidthTicks;
        launchActiveHalfWidthTicks = halfWidth;
        emit LaunchActiveHalfWidthTicksUpdated(oldHalfWidth, halfWidth);
    }

    function _maxLaunchActiveHalfWidth() internal view returns (int24) {
        return int24(uint24(ActiveSlices.DEFAULT_MAX_WIDTH_SPACINGS)) * defaultPoolTickSpacing / 2;
    }

    /// @notice Set the delay (in blocks) after an auction's end before its LBP may migrate.
    /// @param blocks_ The migration delay in blocks.
    function setMigrationDelayBlocks(uint64 blocks_) external onlyOwner {
        migrationDelayBlocks = blocks_;
        emit MigrationDelayBlocksUpdated(blocks_);
    }

    /// @notice Set the delay (in blocks) after migration before an LBP's dust may be swept.
    /// @param blocks_ The sweep delay in blocks.
    function setSweepDelayBlocks(uint64 blocks_) external onlyOwner {
        sweepDelayBlocks = blocks_;
        emit SweepDelayBlocksUpdated(blocks_);
    }

    /// @notice Read the SpotLiquidityVault registered for a venture.
    /// @param venture The venture address.
    /// @return The vault address, or zero if not yet registered.
    function ventureLiquidityVault(address venture) external view returns (address) {
        return _ventureLiquidityVault[venture];
    }

    /// @notice Register the SpotLiquidityVault for a venture. One-shot, callable only by the
    ///         venture's LBP (which deploys the vault during migration).
    /// @dev The vault must name this venture and this Hub, so a contract posing as a venture cannot
    ///      register someone else's vault and have the event point indexers at it.
    /// @param venture The venture address.
    /// @param vault The deployed SpotLiquidityVault address.
    function registerSpotLiquidityVault(address venture, address vault) external {
        if (msg.sender != IVenture(venture).lbp()) revert NotVentureLBP();
        if (_ventureLiquidityVault[venture] != address(0)) revert SpotLiquidityVaultAlreadyRegistered();
        if (!_isVaultOf(venture, vault)) revert InvalidSpotLiquidityVault();
        _ventureLiquidityVault[venture] = vault;
        emit SpotLiquidityVaultRegistered(venture, vault);
    }

    /// @notice Move a venture's spot vault pointer to `newVault`. Every consumer (market creation,
    ///         settlement, liquidation, the vesting TWAP condition) resolves the vault through this
    ///         pointer, so they all follow the move.
    /// @dev Only `spotMigrator`. Reverts while a decision market still holds liquidity pulled from the
    ///      old vault, since settlement returns it there.
    function migrateSpotLiquidityVault(address venture, address newVault) external {
        if (msg.sender != spotMigrator) revert NotSpotMigrator();
        address oldVault = _ventureLiquidityVault[venture];
        if (oldVault == address(0)) revert SpotLiquidityVaultNotRegistered();
        if (
            newVault == oldVault || !_isVaultOf(venture, newVault) || !ISpotLiquidityVault(newVault).isPoolInitialized()
        ) {
            revert InvalidSpotLiquidityVault();
        }
        ISpotLiquidityVault old = ISpotLiquidityVault(oldVault);
        if (old.totalDeployedVenture() != 0 || old.totalDeployedMoney() != 0) revert SpotLiquidityVaultStillFunded();
        _ventureLiquidityVault[venture] = newVault;
        emit SpotLiquidityVaultMigrated(venture, oldVault, newVault);
    }

    /// @dev Vaults name their venture and Hub at construction.
    function _isVaultOf(address venture, address vault) internal view returns (bool) {
        if (vault.code.length == 0) return false;
        ISpotLiquidityVault v = ISpotLiquidityVault(vault);
        return v.venture() == venture && v.HUB() == address(this);
    }

    /// @notice Set the spot migrator. Zero disables migrations.
    function setSpotMigrator(address _migrator) external onlyOwner {
        address oldMigrator = spotMigrator;
        spotMigrator = _migrator;
        emit SpotMigratorUpdated(oldMigrator, _migrator);
    }

    /// @notice Set the protocol-wide default ActiveLiquidityManager keeper.
    function setActiveLiquidityKeeper(address _keeper) external onlyOwner {
        address oldKeeper = activeLiquidityKeeper;
        activeLiquidityKeeper = _keeper;
        emit ActiveLiquidityKeeperUpdated(oldKeeper, _keeper);
    }

    /// @notice Set the UmiaMarketStake address
    /// @param _umiaMarketStake The address of the UmiaMarketStake contract
    function setUmiaMarketStake(address _umiaMarketStake) external onlyOwner {
        address oldStake = umiaMarketStake;
        umiaMarketStake = _umiaMarketStake;
        emit UmiaMarketStakeUpdated(oldStake, _umiaMarketStake);
    }

    /// @notice Set the ContinuousClearingAuctionFactory address
    /// @param _factory The address of the ContinuousClearingAuctionFactory contract
    function setCcaFactory(address _factory) external onlyOwner {
        address oldFactory = ccaFactory;
        ccaFactory = _factory;
        emit CcaFactoryUpdated(oldFactory, _factory);
    }

    /// @notice Set the minimum market stake required for a venture.
    /// @param _ventureId The ID of the venture.
    /// @param _amount The minimum stake amount required.
    function setVentureMinMarketStake(uint256 _ventureId, uint256 _amount) external onlyOwner {
        VentureInfo memory info = _ventureById[_ventureId];
        if (info.venture == address(0)) revert VentureNotFound();

        IVenture(info.venture).setMinMarketStake(_amount);
        emit VentureMinMarketStakeUpdated(_ventureId, _amount);
    }

    // ─────────────────────────────────────────────────────────
    // Circuit Breaker
    // ─────────────────────────────────────────────────────────

    /// @notice Set (or revoke) the veto guardian authorized to trip circuit breakers.
    /// @dev Set to `address(0)` to revoke, restoring owner-only tripping.
    /// @param _guardian The new veto guardian address, or `address(0)` to revoke.
    function setVetoGuardian(address _guardian) external onlyOwner {
        address oldGuardian = vetoGuardian;
        vetoGuardian = _guardian;
        emit VetoGuardianUpdated(oldGuardian, _guardian);
    }

    /// @notice Trip the circuit breaker for a market, pausing its winning-proposal execution.
    /// @dev Callable by the owner or the veto guardian, enabling a fast key to react while the owner
    ///      sits behind a timelock. Reversible via `resetDecisionMarketCircuitBreaker` (owner-only), so
    ///      a veto-to-investigate is a pause, not a permanent kill. Execution is blocked while active.
    /// @param _marketId The ID of the market to pause.
    function tripDecisionMarketCircuitBreaker(uint256 _marketId) external {
        if (msg.sender != owner() && msg.sender != vetoGuardian) revert UnauthorizedVeto();
        if (decisionMarketCircuitBreakerActive[_marketId]) revert DecisionMarketCircuitBreakerAlreadyActive();
        decisionMarketCircuitBreakerActive[_marketId] = true;
        emit DecisionMarketCircuitBreakerTripped(_marketId);
    }

    /// @notice Clear a market's circuit breaker, resuming its winning-proposal execution.
    /// @dev Used to un-pause after a veto-to-investigate turns out to be a false alarm. Harmless if
    ///      the market has already executed (nothing left to execute).
    /// @param _marketId The ID of the market to resume.
    function resetDecisionMarketCircuitBreaker(uint256 _marketId) external onlyOwner {
        if (!decisionMarketCircuitBreakerActive[_marketId]) revert DecisionMarketCircuitBreakerNotActive();
        decisionMarketCircuitBreakerActive[_marketId] = false;
        emit DecisionMarketCircuitBreakerReset(_marketId);
    }

    // ─────────────────────────────────────────────────────────
    // Vesting admin
    // ─────────────────────────────────────────────────────────

    /// @notice Set (or revoke) the address authorized to terminate/reissue vesting grants.
    /// @dev Set to `address(0)` to revoke platform-wide, leaving each venture's futarchy as the only
    ///      path to its vesting.
    /// @param _admin The new vesting admin address, or `address(0)` to revoke.
    function setVestingAdmin(address _admin) external onlyOwner {
        address oldAdmin = vestingAdmin;
        vestingAdmin = _admin;
        emit VestingAdminUpdated(oldAdmin, _admin);
    }

    /// @notice Record the VentureVestingAuthority that owns a venture's vesting grants.
    /// @dev `address(0)` clears the link. A nonzero authority must serve this hub and, once bound,
    ///      this venture's treasury.
    /// @param ventureId The venture.
    /// @param authority Its VentureVestingAuthority, or `address(0)` to clear.
    function setVentureVestingAuthority(uint256 ventureId, address authority) external onlyOwner {
        address venture = _ventureById[ventureId].venture;
        if (venture == address(0)) revert VentureNotFound();
        if (authority != address(0)) {
            IVentureVestingAuthority adapter = IVentureVestingAuthority(authority);
            if (adapter.hub() != address(this)) revert InvalidVestingAuthority();
            if (adapter.bound() && adapter.treasury() != venture) revert InvalidVestingAuthority();
        }
        ventureVestingAuthority[ventureId] = authority;
        emit VentureVestingAuthoritySet(ventureId, authority);
    }

    // ─────────────────────────────────────────────────────────
    // Venture Creation
    // ─────────────────────────────────────────────────────────

    /// @notice Create a new venture with an LBP for token distribution
    /// @param _params The parameters for creating the venture
    /// @return id The ID of the new venture
    /// @return venture The address of the new venture treasury
    /// @dev The owner of the venture is set to the msg.sender.
    /// @dev * 100% of the initial supply is sent to the LBP for auction-based distribution.
    /// @dev * At LBP migration, the LBP deploys the venture's SpotLiquidityVault and registers it
    /// @dev   on the hub; the vault holds the canonical spot liquidity.
    /// @dev * Hub encodes the factory configData itself — the venture address and positionRecipient
    /// @dev   are set to the deployed Venture, never taken from caller input.
    function createVenture(CreateVentureParams calldata _params)
        external
        onlyOwner
        returns (uint256 id, address payable venture)
    {
        if (_params.initialSupply > MAX_INITIAL_SUPPLY) {
            revert InvalidInitialSupply();
        }
        if (_params.initialSupply < MIN_INITIAL_SUPPLY) revert InvalidInitialSupply();

        address hub = address(this);
        address token = address(new VentureToken(_params.name, _params.symbol, hub));
        VentureToken(token).mint(hub, _params.initialSupply);

        (id, venture) = _deployVenture(
            token,
            _params.initialSupply,
            _params.name,
            _params.moneyToken,
            _params.tokenSplitToAuction,
            _params.auctionParams,
            _params.ventureBps,
            _params.lbpSalt,
            _params.teamMembers,
            _params.tradingPauseDuration,
            _params.startingMonthlyAllowance
        );
    }

    /// @notice Create a new venture using a pre-deployed VentureToken
    /// @param _params The parameters for creating the venture
    /// @return id The ID of the new venture
    /// @return venture The address of the new venture treasury
    /// @dev The token must be a VentureToken owned by the Hub with supply already transferred.
    /// @dev The Hub sends its entire token balance to the LBP for auction-based distribution.
    function createVentureWithToken(CreateVentureWithTokenParams calldata _params)
        external
        onlyOwner
        returns (uint256 id, address payable venture)
    {
        address hub = address(this);
        address token = _params.token;

        if (token == address(0)) revert InvalidToken();
        try IERC165(token).supportsInterface(type(IVentureToken).interfaceId) returns (bool supported) {
            if (!supported) revert NotVentureToken();
        } catch {
            revert NotVentureToken();
        }
        if (VentureToken(token).owner() != hub) revert TokenOwnerNotHub();

        uint256 supply = IERC20(token).balanceOf(hub);
        if (supply == 0) revert TokenBalanceZero();
        if (supply > MAX_INITIAL_SUPPLY) revert InvalidInitialSupply();
        if (supply < MIN_INITIAL_SUPPLY) revert InvalidInitialSupply();

        string memory tokenName = VentureToken(token).name();

        (id, venture) = _deployVenture(
            token,
            supply,
            tokenName,
            _params.moneyToken,
            _params.tokenSplitToAuction,
            _params.auctionParams,
            _params.ventureBps,
            _params.lbpSalt,
            _params.teamMembers,
            _params.tradingPauseDuration,
            _params.startingMonthlyAllowance
        );
    }

    // ─────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────

    function _deployVenture(
        address token,
        uint256 supply,
        string memory name,
        address moneyToken,
        uint256 tokenSplitToAuction,
        bytes calldata auctionParams,
        uint256 ventureBps,
        bytes32 lbpSalt,
        address[] calldata teamMembers,
        uint256 tradingPauseDuration,
        uint256 startingMonthlyAllowance
    ) internal returns (uint256 id, address payable venture) {
        if (!approvedMoneyTokens[moneyToken]) revert MoneyTokenNotApproved();

        if (ccaFactory == address(0)) revert CcaFactoryNotSet();
        if (umiaMarketCore == address(0)) revert MarketCoreNotSet();
        if (lbpStrategyFactory == address(0)) revert LbpStrategyFactoryNotSet();
        if (ventureBeacon == address(0)) revert VentureBeaconNotSet();

        id = ++ventureCount;

        address hub = address(this);

        venture = payable(address(new VentureProxy(ventureBeacon, abi.encodeCall(Venture.initializeProxy, (hub)))));

        VentureToken(token).transferOwnership(venture);

        bytes memory configData = abi.encode(tokenSplitToAuction, moneyToken, auctionParams, venture, ventureBps);

        IDistributor lbpContract = IDistributorFactory(lbpStrategyFactory).create(token, supply, configData, lbpSalt);

        IERC20(token).safeTransfer(address(lbpContract), supply);
        lbpContract.onTokensReceived();

        IVenture(venture)
            .initialize(
                IVenture.InitializeVentureParams({
                token: token,
                moneyToken: moneyToken,
                lbp: address(lbpContract),
                teamMembers: teamMembers,
                tradingPauseDuration: tradingPauseDuration,
                startingMonthlyAllowance: startingMonthlyAllowance
            })
            );

        _ventureById[id] = VentureInfo({id: id, venture: venture, name: name, createdAt: block.timestamp});

        emit VentureCreated(id, venture, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────

    /// @notice Modifier to check that no active unsettled markets exist
    modifier withNoActiveMarkets() {
        address mm = umiaMarketCore;
        if (mm != address(0) && IUmiaMarketCore(mm).activeUnsettledMarketCount() > 0) {
            revert ActiveMarketsPreventUpdate();
        }
        _;
    }
}
