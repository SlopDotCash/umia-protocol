// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ILBPInitializer} from "@liquidity-launcher/interfaces/ILBPInitializer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUmiaHook} from "./IUmiaHook.sol";
import {IUmiaHub} from "./IUmiaHub.sol";

/// @title IUmiaLBP
/// @notice Interface for the UmiaLBP contract
interface IUmiaLBP {
    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error InvalidVentureAddress();
    error InvalidVentureBps();
    error MigrationNotAllowed();
    error NoCurrencyRaised();
    error InsufficientCurrency();
    error InitializerAlreadyCreated();
    error InitializerMustImplementInterface();
    error InvalidFundsRecipient();
    error InvalidTokensRecipient();
    error InvalidCurrency();
    error SweepNotAllowed();
    error CurrencyAmountTooHigh();
    error TokenSplitTooHigh();
    error InitializerTokenSplitIsZero();
    error AlreadyMigrated();
    error VaultDeploymentFailed();
    error LaunchSplitUnset();

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event VentureFundsDistributed(uint256 currencyAmount, uint256 tokenAmount);
    event Migrated(PoolKey indexed key, uint160 sqrtPriceX96);
    event InitializerCreated(address indexed initializer);
    event TokensSwept(address indexed recipient, uint256 amount);
    event CurrencySwept(address indexed recipient, uint256 amount);

    // ─────────────────────────────────────────────────────────
    // View Functions
    // ─────────────────────────────────────────────────────────

    function MAX_BPS() external view returns (uint256);
    function TOKEN_SPLIT_DENOMINATOR() external view returns (uint256);
    function venture() external view returns (address);
    function ventureBps() external view returns (uint256);
    function token() external view returns (address);
    function totalSupply() external view returns (uint128);
    function reserveTokenAmount() external view returns (uint128);
    function currency() external view returns (address);
    function tokenSplitToAuction() external view returns (uint256);
    function poolManager() external view returns (IPoolManager);
    function umiaHook() external view returns (IUmiaHook);
    function hub() external view returns (IUmiaHub);
    function auctionParams() external view returns (bytes memory);
    function initializer() external view returns (ILBPInitializer);
    function migrated() external view returns (bool);
    function migratedAtBlock() external view returns (uint64);

    // ─────────────────────────────────────────────────────────
    // State-Changing Functions
    // ─────────────────────────────────────────────────────────

    function migrate() external;
    function sweepToken() external;
    function sweepCurrency() external;
}
