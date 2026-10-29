// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {SSTORE2} from "@solady/utils/SSTORE2.sol";

import {SpotLiquidityVaultV2} from "../core/SpotLiquidityVaultV2.sol";
import {ActiveLiquidityManager} from "../core/ActiveLiquidityManager.sol";

/// @title SpotLiquidityV2Code
/// @notice The creation code of `SpotLiquidityVaultV2` and `ActiveLiquidityManager`, stored once with
///         SSTORE2 and read by both `UmiaLBPFactoryV2` and `SpotMigrator`.
/// @dev Separate for two reasons: embedding both blobs in either deployer would exceed the EIP-3860
///      initcode limit, and one shared copy guarantees a fresh launch and a migration deploy the
///      same code, differing only in constructor arguments.
contract SpotLiquidityV2Code {
    address public immutable vaultCreationCode;
    address public immutable almCreationCode;

    constructor() {
        vaultCreationCode = SSTORE2.write(type(SpotLiquidityVaultV2).creationCode);
        almCreationCode = SSTORE2.write(type(ActiveLiquidityManager).creationCode);
    }
}
