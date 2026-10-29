// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {SpotLiquidityVaultV2} from "../core/SpotLiquidityVaultV2.sol";
import {ActiveLiquidityManager} from "../core/ActiveLiquidityManager.sol";
import {SpotLiquidityV2Code} from "./SpotLiquidityV2Code.sol";
import {SpotLiquidityV2Deploy} from "../libraries/SpotLiquidityV2Deploy.sol";
import {ActiveSlices} from "../libraries/ActiveSlices.sol";
import {SpotTwapGuard} from "../libraries/SpotTwapGuard.sol";
import {IActiveLiquidityManager} from "../interfaces/IActiveLiquidityManager.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IUmiaHook} from "../interfaces/IUmiaHook.sol";
import {IUmiaHookV2} from "../interfaces/IUmiaHookV2.sol";
import {IVenture} from "../interfaces/IVenture.sol";

/// @title SpotMigrator
/// @notice Moves a venture's spot liquidity from its V1 pool to a new `UmiaHookV2` pool. One passed
///         decision-market proposal does it, with two actions in one transaction:
///
///           1. CALL oldVault.withdraw(venture's shares, 0, 0, migrator)
///           2. CALL migrator.migrate(params)
///
///         If anything reverts, V1 is untouched and the proposal can be retried.
/// @dev `prepare` deploys the V2 vault and ALM here, derived from the venture's V1 vault alone,
///      instead of taking addresses as input. The Hub pointer the migration moves is what the vesting
///      TWAP condition trusts, so it must only ever point at vault code this contract deployed.
///      Nothing in `prepare` depends on the caller, so it is permissionless.
///      `migrate` seeds the new pool at V1's exact price, backfills its oracle from V1, and runs only
///      while spot sits close to both the 30-minute and 6-hour TWAPs. Otherwise it reverts and the
///      keeper retries later.
contract SpotMigrator {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Prepared {
        address vault;
        address alm;
        bool migrated;
    }

    struct MigrateParams {
        /// @dev Share of the withdrawn liquidity that seeds the anchor vault; the rest goes to the ALM.
        uint16 anchorBps;
        ActiveSlices.Slice[] activeSlices;
    }

    uint16 internal constant MAX_BPS = 10_000;
    /// @notice The full-range anchor keeps every tick funded, so the active manager can't hold most of the pool.
    uint16 public constant MIN_ANCHOR_BPS = SpotLiquidityV2Deploy.MIN_ANCHOR_BPS;
    uint32 internal constant SEAM_TWAP_WINDOW = 30 minutes;
    uint32 internal constant SEAM_LONG_TWAP_WINDOW = 6 hours;
    /// @dev Max |V1 spot tick - 6-hour TWAP tick| (~3%) at which the migration may run.
    int24 internal constant SEAM_MAX_LONG_TICK_DEVIATION = 300;

    address public immutable HUB;
    IPoolManager public immutable poolManager;
    address public immutable hookV2;
    /// @notice The hook whose pools this migrator moves. Its registry, written only by
    ///         factory-deployed LBPs, is what proves a pool belongs to the venture asking.
    address public immutable sourceHook;
    SpotLiquidityV2Code internal immutable code;

    mapping(address venture => Prepared) public prepared;

    error AlreadyPrepared();
    error NotPrepared();
    error AlreadyMigrated();
    error NoSpotVault();
    error NothingToMigrate();
    error InvalidParams();
    error SeamPriceDeviationTooHigh();
    error UnknownSourcePool();

    event VenturePrepared(address indexed venture, address vault, address alm);
    event VentureMigrated(
        address indexed venture, address indexed oldVault, address indexed newVault, address alm, PoolId poolId
    );

    constructor(
        address _hub,
        IPoolManager _poolManager,
        address _hookV2,
        address _sourceHook,
        SpotLiquidityV2Code _code
    ) {
        if (
            _hub == address(0) || address(_poolManager) == address(0) || _hookV2 == address(0)
                || _sourceHook == address(0)
        ) revert InvalidParams();
        HUB = _hub;
        poolManager = _poolManager;
        hookV2 = _hookV2;
        sourceHook = _sourceHook;
        code = _code;
    }

    /// @notice Deploy the venture's V2 vault and ALM, inert until `migrate`. Permissionless: every
    ///         parameter comes from the venture's current V1 vault.
    function prepare(address venture) external returns (address vault, address alm) {
        if (prepared[venture].vault != address(0)) revert AlreadyPrepared();
        (, PoolKey memory oldKey) = _sourcePool(venture);
        (vault, alm) = SpotLiquidityV2Deploy.deploy(
            code, HUB, venture, address(poolManager), hookV2, oldKey.fee, oldKey.tickSpacing, address(this)
        );
        prepared[venture] = Prepared({vault: vault, alm: alm, migrated: false});
        emit VenturePrepared(venture, vault, alm);
    }

    /// @notice Second action of the migration proposal, called by the venture. Expects the V1
    ///         withdrawal proceeds to already sit on this contract.
    function migrate(MigrateParams calldata p) external {
        address venture = msg.sender;
        Prepared storage prep = prepared[venture];
        if (prep.vault == address(0)) revert NotPrepared();
        if (prep.migrated) revert AlreadyMigrated();
        prep.migrated = true;
        if (p.anchorBps < MIN_ANCHOR_BPS || p.anchorBps > MAX_BPS) revert InvalidParams();

        (address oldVault, PoolKey memory oldKey) = _sourcePool(venture);
        PoolId oldId = oldKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(oldId);
        if (!_seamNearTwap(oldKey)) revert SeamPriceDeviationTooHigh();

        PoolKey memory key = PoolKey(oldKey.currency0, oldKey.currency1, oldKey.fee, oldKey.tickSpacing, IHooks(hookV2));
        IUmiaHookV2(hookV2)
            .registerMigratedPool(
                key,
                IUmiaHookV2.PoolConfig({
                launcher: address(this), venture: venture, anchorOperator: prep.vault, activeOperator: prep.alm
            }),
                oldKey
            );
        // Slices center on the new pool's own tick: at a boundary V1's slot0 tick can sit one lower.
        int24 tick = poolManager.initialize(key, sqrtPriceX96);

        IERC20 ventureToken = IERC20(IVenture(venture).token());
        IERC20 moneyToken = IERC20(IVenture(venture).moneyToken());
        uint256 ventureBalance = ventureToken.balanceOf(address(this));
        uint256 moneyBalance = moneyToken.balanceOf(address(this));
        if (ventureBalance == 0 || moneyBalance == 0) revert NothingToMigrate();

        uint256 anchorVenture = ventureBalance * p.anchorBps / MAX_BPS;
        uint256 anchorMoney = moneyBalance * p.anchorBps / MAX_BPS;
        ventureToken.forceApprove(prep.vault, anchorVenture);
        moneyToken.forceApprove(prep.vault, anchorMoney);
        SpotLiquidityVaultV2(prep.vault).bootstrapFromLBP(anchorVenture, anchorMoney, venture);

        ventureToken.safeTransfer(prep.alm, ventureToken.balanceOf(address(this)));
        moneyToken.safeTransfer(prep.alm, moneyToken.balanceOf(address(this)));
        if (p.activeSlices.length != 0) {
            ActiveLiquidityManager(prep.alm)
                .seed(ActiveSlices.toPositions(key, prep.alm, sqrtPriceX96, tick, p.activeSlices));
        }

        IUmiaHub(HUB).migrateSpotLiquidityVault(venture, prep.vault);
        emit VentureMigrated(venture, oldVault, prep.vault, prep.alm, key.toId());
    }

    /// @notice True while `venture` is prepared and its migration would revert on the seam check.
    /// @dev `Venture.executeCall` reports every failed call as `TransferFailed`, so the keeper reads
    ///      this to tell a migration that is only waiting for calmer prices from a broken payload.
    function seamBlocked(address venture) external view returns (bool) {
        Prepared memory prep = prepared[venture];
        if (prep.vault == address(0) || prep.migrated) return false;
        (, PoolKey memory oldKey) = _sourcePool(venture);
        return !_seamNearTwap(oldKey);
    }

    // ─────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────

    /// @dev The venture's spot vault and its pool, accepted only if the source hook's registry says the
    ///      pool is this venture's and this vault operates it. Anyone can deploy a contract that calls
    ///      itself a venture; only our LBPs write that registry.
    function _sourcePool(address venture) internal view returns (address vault, PoolKey memory key) {
        vault = IUmiaHub(HUB).ventureLiquidityVault(venture);
        if (vault == address(0)) revert NoSpotVault();
        key = ISpotLiquidityVault(vault).getPoolKey();
        if (address(key.hooks) != sourceHook) revert UnknownSourcePool();
        (, address poolVenture, address operator) = IUmiaHook(sourceHook).pools(key.toId());
        if (poolVenture != venture || operator != vault) revert UnknownSourcePool();
    }

    /// @dev The proposal's calldata is fixed days before execution and anyone may execute it once
    ///      due, so the price bound lives here: V1 spot must sit within twice the fee (in ticks) of
    ///      V1's 30-minute TWAP, so pushing the price there and trading it back costs the fee both
    ///      ways, and within 300 ticks (~3%) of its 6-hour TWAP, so holding the push until
    ///      execution takes hours and the slices it seeds can be off by at most a few fees. False
    ///      (fail closed) when the V1 oracle cannot serve either window; the keeper retries.
    function _seamNearTwap(PoolKey memory oldKey) internal view returns (bool) {
        (bool ready, bool ok) = SpotTwapGuard.withinBands(
            poolManager,
            address(oldKey.hooks),
            oldKey,
            SEAM_TWAP_WINDOW,
            int24(uint24(oldKey.fee / 50)),
            SEAM_LONG_TWAP_WINDOW,
            SEAM_MAX_LONG_TICK_DEVIATION
        );
        return ready && ok;
    }
}
