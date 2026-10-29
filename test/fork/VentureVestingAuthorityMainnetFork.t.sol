// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";

/// @notice Rehearses the post-upgrade timelock calls that record every live Base venture's
///         VentureVestingAuthority. Runs only with FORK_RPC_URL set.
contract VentureVestingAuthorityMainnetForkTest is Test {
    IUmiaHub constant HUB = IUmiaHub(0x120dbCDd58Bb787309573e29159fE6D37A1983F6);
    uint256 constant FORK_BLOCK = 52_250_000;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        address hubImpl = address(new UmiaHub());
        vm.prank(HUB.owner());
        UUPSUpgradeable(address(HUB)).upgradeToAndCall(hubImpl, "");
    }

    function test_RecordLiveAuthorities() public {
        (uint256[] memory ids, address[] memory adapters) = _liveAuthorities();
        assertEq(HUB.ventureCount(), ids.length, "a venture is missing from the batch");

        vm.startPrank(HUB.owner());
        for (uint256 i; i < ids.length; i++) {
            HUB.setVentureVestingAuthority(ids[i], adapters[i]);
        }
        vm.stopPrank();

        for (uint256 i; i < ids.length; i++) {
            assertEq(HUB.ventureVestingAuthority(ids[i]), adapters[i]);
        }
    }

    /// @dev UMIA's adapter is bound to UMIA's treasury, so the hub refuses it for another venture.
    function test_Revert_UmiaAdapterForAnotherVenture() public {
        (, address[] memory adapters) = _liveAuthorities();
        address owner = HUB.owner();

        vm.prank(owner);
        vm.expectRevert(IUmiaHub.InvalidVestingAuthority.selector);
        HUB.setVentureVestingAuthority(2, adapters[6]);
    }

    /// @dev Ventures 1 and 4 hold adapters that were never bound; every adapter was deployed by the
    ///      launch operator and is the current authority of its venture's MetaVesT controller.
    function _liveAuthorities() internal pure returns (uint256[] memory ids, address[] memory adapters) {
        ids = new uint256[](7);
        adapters = new address[](7);
        adapters[0] = 0x9DfbAB968BBB210558A9bf64810EE449921762e4;
        adapters[1] = 0x3Ef1143213c04E2C818376614ADe70ec2f1d2926;
        adapters[2] = 0x544113322994C3eFCFbeA49824E5b69EB3c30381;
        adapters[3] = 0xA60814BD786aA80fc51a4c8e15495bdd848eF2dC;
        adapters[4] = 0x908108A14972efa334109E14F163E8c8cd16F501;
        adapters[5] = 0xDaF7dc420289bc585578fF6722ad2E7FDa410ab4;
        adapters[6] = 0xaF320A71651A3e3C5f8557C96958C26ABc796F5B;
        for (uint256 i; i < 7; i++) {
            ids[i] = i + 1;
        }
    }
}
