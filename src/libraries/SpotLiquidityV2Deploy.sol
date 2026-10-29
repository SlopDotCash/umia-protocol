// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {SSTORE2} from "@solady/utils/SSTORE2.sol";

import {SpotLiquidityV2Code} from "../periphery/SpotLiquidityV2Code.sol";

/// @title SpotLiquidityV2Deploy
/// @notice Deploys a venture's V2 vault and ALM from the shared `SpotLiquidityV2Code`, so fresh
///         launches and migrations build them identically. The caller bootstraps the vault.
library SpotLiquidityV2Deploy {
    /// @notice Smallest share of a pool's liquidity the full-range anchor may hold at launch or
    ///         migration. It keeps every tick funded, so the active manager can't hold most of the pool.
    uint16 internal constant MIN_ANCHOR_BPS = 5_000;

    error DeploymentFailed();

    /// @param almBootstrapper May `seed` the ALM once: the LBP for a launch, the migrator for a migration.
    function deploy(
        SpotLiquidityV2Code code,
        address hub,
        address venture,
        address poolManager,
        address hook,
        uint24 fee,
        int24 tickSpacing,
        address almBootstrapper
    ) internal returns (address vault, address alm) {
        bytes memory pool = abi.encode(hub, venture, poolManager, hook, fee, tickSpacing);
        alm = _create(code.almCreationCode(), abi.encodePacked(pool, abi.encode(almBootstrapper)));
        vault = _create(code.vaultCreationCode(), abi.encodePacked(pool, abi.encode(address(this))));
    }

    function _create(address creationCodePointer, bytes memory args) private returns (address deployed) {
        bytes memory initCode = abi.encodePacked(SSTORE2.read(creationCodePointer), args);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }
}
