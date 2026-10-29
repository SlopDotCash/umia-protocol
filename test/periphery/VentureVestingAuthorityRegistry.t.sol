// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {VentureVestingAuthority} from "../../src/periphery/VentureVestingAuthority.sol";
import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";

contract VentureVestingAuthorityRegistryTest is DecisionMarketBase {
    address constant CONTROLLER = address(0xC0);

    uint256 otherVentureId;
    address otherVenture;

    function setUp() public override {
        super.setUp();
        (ventureId, venture,) = _createVentureWithPendingLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        (otherVentureId, otherVenture,) = _createVentureWithPendingLBP(hub, bob, "bobUMO", "BOB", 1_000_000e18);
    }

    function test_Set_UnboundAdapter() public {
        address adapter = address(new VentureVestingAuthority(address(hub), CONTROLLER));

        vm.expectEmit(address(hub));
        emit IUmiaHub.VentureVestingAuthoritySet(ventureId, adapter);
        vm.prank(umiaAdmin);
        hub.setVentureVestingAuthority(ventureId, adapter);

        assertEq(hub.ventureVestingAuthority(ventureId), adapter);
        assertEq(hub.ventureVestingAuthority(otherVentureId), address(0));
    }

    function test_Set_AdapterBoundToThisVenture() public {
        VentureVestingAuthority adapter = new VentureVestingAuthority(address(hub), CONTROLLER);
        adapter.bind(ventureId);

        vm.prank(umiaAdmin);
        hub.setVentureVestingAuthority(ventureId, address(adapter));
        assertEq(hub.ventureVestingAuthority(ventureId), address(adapter));
    }

    function test_Clear() public {
        address adapter = address(new VentureVestingAuthority(address(hub), CONTROLLER));
        vm.startPrank(umiaAdmin);
        hub.setVentureVestingAuthority(ventureId, adapter);

        vm.expectEmit(address(hub));
        emit IUmiaHub.VentureVestingAuthoritySet(ventureId, address(0));
        hub.setVentureVestingAuthority(ventureId, address(0));
        vm.stopPrank();

        assertEq(hub.ventureVestingAuthority(ventureId), address(0));
    }

    function test_Revert_AdapterBoundToAnotherVenture() public {
        VentureVestingAuthority adapter = new VentureVestingAuthority(address(hub), CONTROLLER);
        adapter.bind(otherVentureId);

        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.InvalidVestingAuthority.selector);
        hub.setVentureVestingAuthority(ventureId, address(adapter));
    }

    function test_Revert_AdapterServesAnotherHub() public {
        address adapter = address(new VentureVestingAuthority(address(0xBEEF), CONTROLLER));

        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.InvalidVestingAuthority.selector);
        hub.setVentureVestingAuthority(ventureId, adapter);
    }

    function test_Revert_UnknownVenture() public {
        address adapter = address(new VentureVestingAuthority(address(hub), CONTROLLER));
        uint256 unknownId = hub.ventureCount() + 1;

        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.VentureNotFound.selector);
        hub.setVentureVestingAuthority(unknownId, adapter);
    }

    function test_Revert_NotOwner() public {
        address adapter = address(new VentureVestingAuthority(address(hub), CONTROLLER));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.setVentureVestingAuthority(ventureId, adapter);
    }
}
