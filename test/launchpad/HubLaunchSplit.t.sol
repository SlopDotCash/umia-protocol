// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {ActiveSlices} from "../../src/libraries/ActiveSlices.sol";

/// @notice The Hub's launch split: how much of a V2 launch's liquidity the anchor keeps, and how wide
///         the ALM's first range is. Both start unset so an upgraded Hub cannot launch on V2 by accident.
contract HubLaunchSplitTest is Test {
    UmiaHub hub;

    function setUp() public {
        hub = UmiaHub(
            address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (address(this)))))
        );
    }

    function test_StartsUnset() public view {
        assertEq(hub.launchAnchorBps(), 0);
        assertEq(hub.launchActiveHalfWidthTicks(), 0);
    }

    function test_AnchorBps_FlooredAtHalfAndCappedAtAll() public {
        vm.expectRevert(IUmiaHub.InvalidBps.selector);
        hub.setLaunchAnchorBps(4_999);
        vm.expectRevert(IUmiaHub.InvalidBps.selector);
        hub.setLaunchAnchorBps(10_001);

        vm.expectEmit();
        emit IUmiaHub.LaunchAnchorBpsUpdated(0, 7_500);
        hub.setLaunchAnchorBps(7_500);
        assertEq(hub.launchAnchorBps(), 7_500);
        hub.setLaunchAnchorBps(10_000);
        assertEq(hub.launchAnchorBps(), 10_000);
    }

    function test_HalfWidth_MultipleOfSpacingWithinAlmDefault() public {
        int24 spacing = hub.defaultPoolTickSpacing();
        int24 almMax = int24(uint24(ActiveSlices.DEFAULT_MAX_WIDTH_SPACINGS)) * spacing;

        vm.expectRevert(IUmiaHub.InvalidLaunchActiveHalfWidth.selector);
        hub.setLaunchActiveHalfWidthTicks(0);
        vm.expectRevert(IUmiaHub.InvalidLaunchActiveHalfWidth.selector);
        hub.setLaunchActiveHalfWidthTicks(spacing + 1);
        vm.expectRevert(IUmiaHub.InvalidLaunchActiveHalfWidth.selector);
        hub.setLaunchActiveHalfWidthTicks(almMax / 2 + spacing);

        vm.expectEmit();
        emit IUmiaHub.LaunchActiveHalfWidthTicksUpdated(0, 10_980);
        hub.setLaunchActiveHalfWidthTicks(10_980);
        assertEq(hub.launchActiveHalfWidthTicks(), 10_980);
        hub.setLaunchActiveHalfWidthTicks(almMax / 2);
        assertEq(hub.launchActiveHalfWidthTicks(), almMax / 2);
    }

    function test_SpacingChange_ClearsAWidthThatNoLongerFits() public {
        hub.setLaunchActiveHalfWidthTicks(10_980);

        hub.setDefaultPoolTickSpacing(30);
        assertEq(hub.launchActiveHalfWidthTicks(), 10_980, "a multiple of the new spacing and within its max");

        vm.expectEmit();
        emit IUmiaHub.LaunchActiveHalfWidthTicksUpdated(10_980, 0);
        hub.setDefaultPoolTickSpacing(50);
        assertEq(hub.launchActiveHalfWidthTicks(), 0, "10_980 is not a multiple of 50");

        hub.setDefaultPoolTickSpacing(60);
        hub.setLaunchActiveHalfWidthTicks(30_000);
        hub.setDefaultPoolTickSpacing(20);
        assertEq(hub.launchActiveHalfWidthTicks(), 0, "wider than the ALM default allows at the new spacing");
    }

    function test_Setters_OnlyOwner() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        hub.setLaunchAnchorBps(7_500);
        vm.expectRevert();
        hub.setLaunchActiveHalfWidthTicks(10_980);
        vm.stopPrank();
    }
}
