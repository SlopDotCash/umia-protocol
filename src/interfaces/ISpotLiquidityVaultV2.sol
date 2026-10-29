// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISpotLiquidityVault} from "./ISpotLiquidityVault.sol";

/// @title ISpotLiquidityVaultV2
/// @notice `ISpotLiquidityVault` plus the V2 bootstrap gate and the paired active manager.
interface ISpotLiquidityVaultV2 is ISpotLiquidityVault {
    error CallerNotBootstrapper();

    /// @notice The only caller allowed to run the one-shot `bootstrapFromLBP`.
    function bootstrapper() external view returns (address);

    /// @notice The pool's current active operator (the venture's ActiveLiquidityManager), read from
    ///         the hook; zero if it has none. Liquidation unwinds it through this getter.
    function activeManager() external view returns (address);
}
