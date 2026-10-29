// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LibBytes} from "@solady/utils/LibBytes.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Context binding for registration and bid proofs, plus bid-proof freshness.
library HookProofValidation {
    error BidProofExpired();
    error BidProofFromFuture();
    error BidProofContextMismatch();
    error RegistrationProofContextMismatch();

    /// @dev Registration proofs belong to one auction, but can be submitted at any of its steps.
    function validateRegistration(string memory contextMessage, address auction) internal view {
        bytes memory message = bytes(contextMessage);
        bytes memory prefix =
            abi.encodePacked("register:", LibString.toString(block.chainid), ":", LibString.toHexString(auction), ":");
        if (!_hasPrefixAndSuffix(message, prefix)) revert RegistrationProofContextMismatch();
    }

    /// @dev Reject future and expired bid proofs before authenticating their context.
    function validateBidTimestamp(uint32 timestampS, uint256 maxAge) internal view {
        if (timestampS > block.timestamp) revert BidProofFromFuture();
        if (block.timestamp - timestampS > maxAge) revert BidProofExpired();
    }

    /// @dev Bind a previously verified context to this exact bid.
    function validateBid(string memory contextMessage, address auction, uint256 stepIndex, uint128 amount)
        internal
        view
    {
        bytes memory message = bytes(contextMessage);
        bytes memory prefix = abi.encodePacked(
            "bid:",
            LibString.toString(block.chainid),
            ":",
            LibString.toHexString(auction),
            ":",
            LibString.toString(stepIndex),
            ":",
            LibString.toString(uint256(amount)),
            ":"
        );
        if (!_hasPrefixAndSuffix(message, prefix)) revert BidProofContextMismatch();
    }

    function _hasPrefixAndSuffix(bytes memory message, bytes memory prefix) private pure returns (bool) {
        return message.length > prefix.length && LibBytes.startsWith(message, prefix);
    }
}
