// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IUmiaOracleSource
/// @notice The reads `UmiaHookV2` makes on a pool's previous hook, V1 or V2, to copy its coarse
///         oracle history into a migrated pool.
interface IUmiaOracleSource {
    /// @notice Registration config of a pool, cut to the fields both hook versions share.
    /// @dev Only the first two fields are decoded, so V1 (3-field) and V2 (4-field) configs both fit.
    function pools(PoolId id) external view returns (address launcher, address venture);

    /// @notice Ring cursor of the coarse oracle: newest slot, slots in use, slots paid for.
    function coarseOracleStates(PoolId id)
        external
        view
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);

    /// @notice Coarse ring read for month-scale lookbacks.
    function observeLong(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Raw slot of the coarse ring.
    /// @return blockTimestamp When the slot was written.
    /// @return tickCumulative Tick integral over time up to the slot.
    /// @return secondsPerLiquidityCumulativeX128 Seconds-per-liquidity integral up to the slot, Q128.
    /// @return initialized False for slots never written.
    function getCoarseObservation(PoolId id, uint16 index) external view returns (uint32, int48, uint144, bool);
}
