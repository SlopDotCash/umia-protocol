// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {UmiaHook} from "../src/periphery/UmiaHook.sol";
import {UmiaHookV2} from "../src/periphery/UmiaHookV2.sol";

/// @title MineUmiaHookSalt
/// @notice Off-chain mining script that finds a CreateX salt producing a UmiaHook address
///         whose lower 14 bits encode the required V4 permission mask (0x38C4), optionally
///         with a leading vanity byte prefix.
///
/// @dev Salt layout. The first 20 bytes are a fixed sentinel that drops CreateX into its
///      "Random + RedeployFlag.False" _guard branch (no sender protection, no cross-chain
///      protection). In that branch CreateX hashes the salt before CREATE2:
///          guardedSalt = keccak256(salt)
///      so the predicted address must use the hashed salt. Because the transformation only
///      depends on the raw salt and not on msg.sender or block.chainid, the same raw salt
///      + same init code still yields the same address on every chain regardless of who
///      runs the deploy. `_computeAddr` mirrors this transformation so its prediction
///      matches CreateX's actual deploy destination.
///
///      The remaining 12 bytes are a counter we iterate over. 2^96 candidates is more than
///      enough for any vanity target this script can mine in reasonable time.
///
/// @dev Why a sentinel. CreateX reverts on salt prefixes that look like address(0) when the
///      redeploy-flag byte isn't set, and adds permissioned-sender protection (an extra
///      msg.sender mix-in to the salt hash) on prefixes matching msg.sender. 0xdEAd... is
///      neither, so it lands in the chain-independent branch above. Note that the branch
///      *does* guard the salt (it hashes it); it just doesn't tie the address to a
///      specific sender or chain.
///
/// Usage (interpreted EVM):
///
///   UMIA_HOOK_DEPLOYER=0xYourDeployerEOA \
///   VANITY_PREFIX=0xCC \
///   MAX_ATTEMPTS=10000000 \
///   forge script script/MineUmiaHookSalt.s.sol --rpc-url $MAINNET_RPC -vv
///
/// Set HOOK_V2=true to mine for `UmiaHookV2` (same permission mask).
///
/// VANITY_PREFIX is optional; 0-2 bytes is practical in interpreted EVM. For longer prefixes
/// switch to a native miner that replicates the same _computeAddr formula.
contract MineUmiaHookSalt is Script {
    address constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// V4 hook permission flags carried in the lower 14 bits of the hook address. Matches
    /// UmiaHook.getHookPermissions: beforeInitialize, afterInitialize, beforeAddLiquidity,
    /// beforeRemoveLiquidity, beforeSwap. No swap-time return delta (mask 0x3A80).
    uint160 constant REQUIRED_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);
    uint160 constant FLAG_MASK = 0x3FFF;

    /// Sentinel salt prefix (bytes [0:20]). Non-zero, not an EOA anyone is likely to use as
    /// deployer, so CreateX falls into its "Random + RedeployFlag.False" _guard branch.
    bytes20 constant SALT_PREFIX = bytes20(uint160(0xDead00000000000000000000000000000000DD00));

    function run() external view {
        address deployer = vm.envAddress("UMIA_HOOK_DEPLOYER");
        bytes memory vanity = vm.envOr("VANITY_PREFIX", bytes(""));
        uint256 maxAttempts = vm.envOr("MAX_ATTEMPTS", uint256(10_000_000));
        uint256 minCounter = vm.envOr("MIN_COUNTER", uint256(0));

        require(vanity.length <= 4, "VANITY_PREFIX > 4 bytes; switch to a native miner");

        bytes memory creationCode =
            vm.envOr("HOOK_V2", false) ? type(UmiaHookV2).creationCode : type(UmiaHook).creationCode;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, abi.encode(deployer)));

        console.log("Deployer EOA:", deployer);
        console.log("Init code hash:");
        console.logBytes32(initCodeHash);
        console.log("Required permission mask (low 14 bits):", uint256(REQUIRED_FLAGS));
        if (vanity.length > 0) {
            console.log("Vanity prefix:");
            console.logBytes(vanity);
            if (vanity.length > 2) {
                console.log("Warning: > 2 bytes of vanity may take hours in interpreted EVM");
            }
        } else {
            console.log("No vanity constraint");
        }
        console.log("Max attempts:", maxAttempts);
        console.log("Mining...");

        for (uint96 counter = uint96(minCounter); counter < maxAttempts; counter++) {
            bytes32 salt = bytes32(abi.encodePacked(SALT_PREFIX, counter));
            address predicted = _computeAddr(salt, initCodeHash);

            if (uint160(predicted) & FLAG_MASK != REQUIRED_FLAGS) continue;
            if (!_matchesPrefix(predicted, vanity)) continue;

            console.log("=== MATCH ===");
            console.log("Salt:");
            console.logBytes32(salt);
            console.log("Predicted address:", predicted);
            console.log("Attempts:", uint256(counter) + 1);
            console.log("");
            bool v2 = vm.envOr("HOOK_V2", false);
            console.log(
                v2 ? "Wire these env vars into DeploySpotLiquidityV2.s.sol:" : "Wire these env vars into Deploy.s.sol:"
            );
            console.log(string.concat(v2 ? "  UMIA_HOOK_V2_SALT=" : "  UMIA_HOOK_SALT=", vm.toString(salt)));
            console.log(string.concat("  UMIA_HOOK_DEPLOYER=", vm.toString(deployer)));
            return;
        }

        revert("no match within MAX_ATTEMPTS; raise the limit or shorten VANITY_PREFIX");
    }

    /// Inline CREATE2 address computation that mirrors CreateX's "Random + RedeployFlag.False"
    /// guard branch: `guardedSalt = keccak256(salt)` before standard CREATE2.
    /// Cheaper than calling CreateX over RPC on every iteration (no external CALL).
    function _computeAddr(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(salt));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE_X, guardedSalt, initCodeHash)))));
    }

    function _matchesPrefix(address addr, bytes memory prefix) internal pure returns (bool) {
        if (prefix.length == 0) return true;
        bytes20 a = bytes20(addr);
        for (uint256 i = 0; i < prefix.length; i++) {
            if (a[i] != prefix[i]) return false;
        }
        return true;
    }
}
