// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IUmiaMarketStake} from "../interfaces/IUmiaMarketStake.sol";
import {IVenture} from "../interfaces/IVenture.sol";

/// @title UmiaMarketStake
/// @notice Holds staked tokens required for market creation and manages the stake lifecycle.
contract UmiaMarketStake is IUmiaMarketStake {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────

    IUmiaHub public immutable HUB;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    mapping(uint256 ventureId => mapping(address staker => MarketStake)) public marketStakes;

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Constructor.
    /// @param _hub The address of the UmiaHub contract.
    constructor(address _hub) {
        HUB = IUmiaHub(_hub);
    }

    // ─────────────────────────────────────────────────────────
    // Deposit and Withdraw
    // ─────────────────────────────────────────────────────────

    /// @notice Deposit the minimum stake required to open a market for a venture.
    /// @param ventureId The ID of the venture.
    function depositMarketStake(uint256 ventureId) external {
        IUmiaHub.VentureInfo memory ventureInfo = HUB.ventureById(ventureId);
        if (ventureInfo.venture == address(0)) revert VentureNotFound();

        uint256 minStake = IVenture(ventureInfo.venture).minMarketStake();
        if (minStake == 0) revert MarketStakeNotConfigured();

        MarketStake storage stake = marketStakes[ventureId][msg.sender];
        if (stake.amount >= minStake) revert MarketStakeAlreadyDeposited();
        uint256 depositAmount = minStake - stake.amount;

        address ventureToken = HUB.ventureTokenById(ventureId);
        if (ventureToken == address(0)) revert VentureNotFound();
        IERC20(ventureToken).safeTransferFrom(msg.sender, address(this), depositAmount);

        stake.amount = minStake;
        emit MarketStakeDeposited(ventureId, msg.sender, depositAmount);
    }

    /// @notice Withdraw a market stake deposit.
    /// @param ventureId The ID of the venture.
    function withdrawMarketStake(uint256 ventureId) external {
        MarketStake storage stake = marketStakes[ventureId][msg.sender];
        if (stake.amount == 0) revert MarketStakeRequired();
        if (block.timestamp < stake.lockedUntil) revert MarketStakeStillLocked();

        uint256 amount = stake.amount;
        stake.amount = 0;
        stake.lockedUntil = 0;

        address ventureToken = HUB.ventureTokenById(ventureId);
        if (ventureToken == address(0)) revert VentureNotFound();
        IERC20(ventureToken).safeTransfer(msg.sender, amount);

        emit MarketStakeWithdrawn(ventureId, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────
    // Verify and Lock Stake
    // ─────────────────────────────────────────────────────────

    /// @notice Verify that a creator has staked the required amount and lock it until trading ends.
    /// @param ventureId The ID of the venture.
    /// @param creator The address that deposited the stake.
    /// @param tradingEnd The timestamp when trading ends (stake locked until then).
    /// @param marketId The ID of the market being created.
    function verifyAndLockStake(uint256 ventureId, address creator, uint256 tradingEnd, uint256 marketId) external {
        if (msg.sender != HUB.umiaMarketCore()) revert Unauthorized();

        IUmiaHub.VentureInfo memory ventureInfo = HUB.ventureById(ventureId);
        if (ventureInfo.venture == address(0)) revert VentureNotFound();

        uint256 minStake = IVenture(ventureInfo.venture).minMarketStake();
        if (minStake == 0) revert MarketStakeNotConfigured();

        MarketStake storage stake = marketStakes[ventureId][creator];
        if (stake.amount < minStake) revert MarketStakeRequired();

        if (tradingEnd > stake.lockedUntil) {
            stake.lockedUntil = tradingEnd;
        }
        emit MarketStakeLocked(ventureId, creator, marketId, tradingEnd);
    }
}
