// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IGatedValidationHook} from "./IGatedValidationHook.sol";
import {IMaxBidPriceValidationHook} from "./IMaxBidPriceValidationHook.sol";
import {IVerifyEveryBidHook} from "./IVerifyEveryBidHook.sol";

/// @title IUmiaValidationHook
/// @notice CIP-1 custom interface for {UmiaValidationHook}: the permissionless surface an
///         integrator needs to read a gated auction's gating config.
/// @dev Advertised via ERC165 `supportsInterface` alongside `IValidationHook` and `IERC165`.
///      Owner-only administration is deliberately left out: it is an ops surface, not something
///      a caller discovers, and keeping it out means routine admin changes cannot shift the
///      interface ID that integrators key off. Inheriting `IMaxBidPriceValidationHook`,
///      `IGatedValidationHook` and `IVerifyEveryBidHook` does not move this ID either: Solidity
///      excludes inherited selectors from `type().interfaceId`.
interface IUmiaValidationHook is IMaxBidPriceValidationHook, IGatedValidationHook, IVerifyEveryBidHook {
    /// @notice A cached auction step, as a half-open block range.
    struct BlockRange {
        uint64 startBlock; // inclusive
        uint64 endBlock; // exclusive
    }

    /// @notice Returns the user that currently owns a canonical identity key,
    ///         or address(0) if unclaimed.
    function identityOwner(bytes32 identityHash) external view returns (address);

    /// @notice Returns true if a server-permit nonce has already been consumed.
    function isPermitNonceUsed(bytes32 nonce) external view returns (bool);

    /// @notice Check if a user is verified for a given step
    /// @param stepIndex The step to check verification for
    /// @param user The address to check
    /// @return True if the user is verified at or before the given step
    function isVerified(uint256 stepIndex, address user) external view returns (bool);

    /// @notice Check if a step has verification enforcement enabled
    /// @param stepIndex The step to check
    /// @return True if the step enforces verification
    function isStepEnabled(uint256 stepIndex) external view returns (bool);

    /// @notice Check if a step has server-permit verification enabled
    /// @param stepIndex The step to check
    /// @return True if the step accepts server-permit verification
    function isStepPermitEnabled(uint256 stepIndex) external view returns (bool);

    /// @notice Get the required provider hashes for a step
    /// @param stepIndex The step to check
    /// @return Array of required provider hashes (empty = no zkTLS proof gate; step open unless a server permit is enabled)
    function getStepProviders(uint256 stepIndex) external view returns (bytes32[] memory);

    /// @notice Get all cached step ranges read from the CCA
    /// @return Array of BlockRange structs with startBlock (inclusive) and endBlock (exclusive)
    function getSteps() external view returns (BlockRange[] memory);

    /// @notice Get the paired CCA contract address
    function cca() external view returns (address);

    /// @notice Get the authorized server permit signer address
    function signer() external view returns (address);

    /// @notice Get the per-step cumulative zkTLS bid cap (0 = no cap), in money-token base units.
    /// @param stepIndex The 0-indexed step to read
    function stepMaxBidAmount(uint256 stepIndex) external view returns (uint256);

    /// @notice Get a wallet's cumulative zkTLS bid amount at a step, in money-token base units.
    /// @param wallet The bidder address
    /// @param stepIndex The 0-indexed step to read
    function zkBidTotal(address wallet, uint256 stepIndex) external view returns (uint256);
}
