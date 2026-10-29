// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IUmiaHookV2
/// @notice Public interface for the singleton `UmiaHookV2` Uniswap V4 hook.
/// @dev Keeps every oracle read and ring-growth signature of `IUmiaHook`, so `SpotLiquidityVault`
///      and `UmiaTwapMilestoneCondition` can call a V2 hook through `IUmiaHook`. `PoolConfig`,
///      `initialize` and the registration surface differ, which is why this is a separate interface.
interface IUmiaHookV2 {
    // ─────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────

    /// @notice Per-pool configuration written once at registration and immutable thereafter.
    /// @dev `launcher` is forced to `msg.sender` at registration. `anchorOperator` (the venture's
    ///      spot vault) may only hold full-range liquidity. `activeOperator` (the venture's active
    ///      liquidity manager) may hold any range; zero means the venture has none. One pool, one
    ///      manager: replacing it means migrating to a new pool.
    struct PoolConfig {
        address launcher;
        address venture;
        address anchorOperator;
        address activeOperator;
    }

    /// @notice Spot-market oracle ring-buffer cursor for a given pool.
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error NotFactoryDeployedLBP(address caller);
    error NotSpotMigrator(address caller);
    error PoolAlreadyRegistered(PoolId id);
    error UnauthorizedLauncher(address caller, address expected);
    error UnauthorizedLiquidityOperator(address caller);
    error OnlyPoolManager();
    error OnlyFullRangePositions();
    error FactoryAlreadySet();
    error NotInitialOwner();
    error InvalidVentureAddress();
    error InvalidOperator();
    error InvalidFactory();
    error InvalidPoolManager();
    error InvalidHub();
    error InvalidInitialOwner();
    error InvalidHooksAddress(address provided, address expected);
    /// @notice The predecessor key does not trade the same pair, is not this venture's pool, or
    ///         has no seeded oracle.
    error InvalidPredecessor();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event Initialized(address factory, address poolManager, address hub);
    event PoolRegistered(PoolId indexed id, address indexed anchorOperator, PoolConfig config);
    event PoolPredecessorSet(
        PoolId indexed id,
        address indexed predecessorHook,
        PoolId indexed predecessorId,
        uint32 backfillStart,
        uint16 observations
    );

    // ─────────────────────────────────────────────────────────
    // External Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Wires the LBP factory, the PoolManager and the Hub. Once, by the initial owner.
    function initialize(address factory, IPoolManager poolManager, address hub) external;

    /// @notice Register a fresh pool. Caller must be a factory-deployed UmiaLBP.
    function registerPool(PoolKey calldata key, PoolConfig calldata cfg) external;

    /// @notice Register a pool that replaces `predecessorKey`, backfilling its coarse ring from the
    ///         predecessor's. Caller must be the Hub's `spotMigrator`.
    function registerMigratedPool(PoolKey calldata key, PoolConfig calldata cfg, PoolKey calldata predecessorKey)
        external;

    /// @notice Grows the per-block ring so it can hold `cardinalityNext` observations. Anyone may
    ///         call and pays for the new slots; a target at or below the current one is a no-op.
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    /// @notice Same as `increaseCardinalityNext`, for the coarse ring.
    function increaseCoarseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    // ─────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Registration config of a pool; `launcher` is zero for pools this hook does not know.
    function pools(PoolId id)
        external
        view
        returns (address launcher, address venture, address anchorOperator, address activeOperator);

    /// @notice Ring cursor of the per-block oracle: newest slot, slots in use, slots paid for.
    function oracleStates(PoolId id) external view returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);

    /// @notice Ring cursor of the coarse oracle; see `oracleStates`.
    function coarseOracleStates(PoolId id)
        external
        view
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);

    /// @notice Width of a coarse ring bucket: at most one coarse checkpoint is written per hour.
    function COARSE_INTERVAL() external view returns (uint32);

    /// @notice Per-block ring read. Never backfilled: a migrated pool's history starts at handover.
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Coarse ring read for month-scale lookbacks.
    function observeLong(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Raw slot of the per-block ring; `initialized` is false for slots never written.
    function getObservation(PoolId id, uint16 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int48 tickCumulative,
            uint144 secondsPerLiquidityCumulativeX128,
            bool initialized
        );

    /// @notice Raw slot of the coarse ring; `initialized` is false for slots never written.
    function getCoarseObservation(PoolId id, uint16 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int48 tickCumulative,
            uint144 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}
