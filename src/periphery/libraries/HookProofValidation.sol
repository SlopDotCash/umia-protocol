// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Reclaim} from "../../reclaim/Reclaim.sol";
import {Claims} from "../../reclaim/Claims.sol";
import {StringUtils} from "../../reclaim/StringUtils.sol";

/// @notice Context binding for registration and bid proofs, plus bid-proof freshness.
library HookProofValidation {
    error BidProofExpired();
    error BidProofFromFuture();
    error BidProofContextMismatch();
    error RegistrationProofContextMismatch();

    /// @dev Registration proofs belong to one auction, but can be submitted at any of its steps.
    function validateRegistration(Reclaim.Proof memory proof, address auction) internal view {
        bytes memory message = bytes(Claims.extractFieldFromContext(proof.claimInfo.context, '"contextMessage":"'));
        bytes memory prefix = abi.encodePacked(
            "register:", StringUtils.uint2str(block.chainid), ":", StringUtils.address2str(auction), ":"
        );
        if (!_hasPrefixAndSuffix(message, prefix)) revert RegistrationProofContextMismatch();
    }

    /// @dev The signed context message must start `bid:<chain>:<auction>:<step>:<amount>:` and
    ///      carry a nonempty nonce after it.
    function validateBid(Reclaim.Proof memory proof, address auction, uint256 stepIndex, uint128 amount, uint256 maxAge)
        internal
        view
    {
        uint256 timestamp = proof.signedClaim.claim.timestampS;
        if (timestamp > block.timestamp) revert BidProofFromFuture();
        if (block.timestamp - timestamp > maxAge) revert BidProofExpired();
        bytes memory message = bytes(Claims.extractFieldFromContext(proof.claimInfo.context, '"contextMessage":"'));
        bytes memory prefix = abi.encodePacked(
            "bid:",
            StringUtils.uint2str(block.chainid),
            ":",
            StringUtils.address2str(auction),
            ":",
            StringUtils.uint2str(stepIndex),
            ":",
            StringUtils.uint2str(amount),
            ":"
        );
        if (!_hasPrefixAndSuffix(message, prefix)) revert BidProofContextMismatch();
    }

    function _hasPrefixAndSuffix(bytes memory message, bytes memory prefix) private pure returns (bool) {
        if (message.length <= prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (message[i] != prefix[i]) return false;
        }
        return true;
    }
}
