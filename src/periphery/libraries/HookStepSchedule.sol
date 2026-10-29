// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {IContinuousClearingAuction} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {IStepStorage} from "@continuous-clearing-auction/interfaces/IStepStorage.sol";
import {IUmiaValidationHook} from "../../interfaces/IUmiaValidationHook.sol";

/// @notice Decode and validate the immutable auction schedule before caching it in a hook.
library HookStepSchedule {
    error InvalidStepData();
    error TooManySteps();

    function read(address auction) internal view returns (IUmiaValidationHook.BlockRange[] memory ranges) {
        bytes memory packed = SSTORE2.read(IStepStorage(auction).pointer());
        if (packed.length == 0 || packed.length % 8 != 0) revert InvalidStepData();
        uint256 count = packed.length / 8;
        if (count > 256) revert TooManySteps();
        ranges = new IUmiaValidationHook.BlockRange[](count);
        uint64 cursor = IContinuousClearingAuction(auction).startBlock();
        for (uint256 i; i < count; ++i) {
            uint40 delta;
            // Each 8-byte entry is [3 bytes minPriceStep][5 bytes blockDelta].
            assembly { delta := and(shr(192, mload(add(add(packed, 0x20), mul(i, 8)))), 0xFFFFFFFFFF) }
            if (delta == 0) revert InvalidStepData();
            uint64 end = cursor + uint64(delta);
            ranges[i] = IUmiaValidationHook.BlockRange({startBlock: cursor, endBlock: end});
            cursor = end;
        }
    }
}
