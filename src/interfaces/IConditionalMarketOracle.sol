// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IConditionalMarketOracle
/// @notice Per-proposal TWAP oracle for Umia decision markets.
interface IConditionalMarketOracle {
    /// @notice Initialize a proposal's oracle in one call: anchor the scoring window and record the
    ///         seed price.
    /// @param proposalId The proposal ID.
    /// @param reserve0 Seed reserve of token0 (virtual venture).
    /// @param reserve1 Seed reserve of token1 (virtual money).
    /// @param tradingStart Scoring window start (the TWAP is anchored here).
    /// @param tradingEnd Scoring window end (the oracle freezes here).
    /// @param winningThresholdBps The market's snapshotted winning threshold, validated so every
    ///        implementation shares the same creation revert surface.
    function initialize(
        uint256 proposalId,
        uint256 reserve0,
        uint256 reserve1,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint16 winningThresholdBps
    ) external;

    /// @notice Record the interval since the last update at the given reserves. Called before every
    ///         reserve mutation, so the interval is attributed to the price actually held over it.
    /// @param proposalId The proposal ID.
    /// @param reserve0 Current reserve of token0.
    /// @param reserve1 Current reserve of token1.
    function update(uint256 proposalId, uint256 reserve0, uint256 reserve1) external;

    /// @notice The time-weighted geometric mean price from trading start to now (frozen after trading
    ///         end): the mean accepted tick, as money per venture.
    /// @param proposalId The proposal ID.
    /// @param reserve0 Current reserve of token0.
    /// @param reserve1 Current reserve of token1.
    /// @return twapX112 The TWAP in Q112.112 format.
    function calculateTWAP(uint256 proposalId, uint256 reserve0, uint256 reserve1)
        external
        view
        returns (uint256 twapX112);

    /// @notice The mean accepted tick behind `calculateTWAP`.
    /// @param proposalId The proposal ID.
    /// @param reserve0 Current reserve of token0.
    /// @param reserve1 Current reserve of token1.
    /// @return meanTick The time-weighted mean tick, rounded toward negative infinity.
    function calculateTWAPTick(uint256 proposalId, uint256 reserve0, uint256 reserve1)
        external
        view
        returns (int24 meanTick);
}
