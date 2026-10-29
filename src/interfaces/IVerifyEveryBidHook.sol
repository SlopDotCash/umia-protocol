// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IValidationHookIntrospection
} from "@continuous-clearing-auction/periphery/validationHooks/ValidationHookIntrospection.sol";

/// @title IVerifyEveryBidHook
/// @notice Optional capability of hooks that can require a fresh credential on every bid.
/// @dev Kept separate from `IUmiaValidationHook` so adding it leaves that ID unchanged.
interface IVerifyEveryBidHook is IValidationHookIntrospection {
    /// @notice Whether standing verification cannot authorize a bid at `stepIndex`
    function verifiesEveryBid(uint256 stepIndex) external view returns (bool);
    /// @notice Whether this step needs no credential from this user. The max bid price still applies,
    ///         and a registered user's bids still count toward the zk caps.
    function authorizesWithoutCredential(uint256 stepIndex, address user) external view returns (bool);
}
