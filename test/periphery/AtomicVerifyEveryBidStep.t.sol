// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {MockCCA} from "./UmiaValidationHookBase.t.sol";

/// @dev Verify-every-bid activation composes the ordinary setters in one guarded multicall.
contract AtomicVerifyEveryBidStepTest is Test {
    UmiaValidationHook hook;
    MockCCA auction;
    uint64 constant START = 1000;

    function setUp() public {
        hook = new UmiaValidationHook(address(this), address(0x123), address(0x456));
        auction = new MockCCA(abi.encodePacked(uint24(1), uint40(100), uint24(1), uint40(100)), START);
        hook.setCCA(address(auction));
    }

    function _activation(uint256 step, uint256 cap) internal view returns (bytes[] memory calls) {
        calls = new bytes[](5);
        calls[0] = abi.encodeCall(hook.requireStepNotStarted, (step));
        calls[1] = abi.encodeCall(hook.enableStep, (step, new bytes32[](0), new string[](0)));
        calls[2] = abi.encodeCall(hook.enableStepPermit, (step));
        calls[3] = abi.encodeCall(hook.setStepMaxBidAmount, (step, cap));
        calls[4] = abi.encodeCall(hook.setVerifyEveryBid, (step, true));
    }

    function _assertUntouched(uint256 step) internal view {
        assertFalse(hook.isStepEnabled(step));
        assertFalse(hook.isStepPermitEnabled(step));
        assertFalse(hook.verifiesEveryBid(step));
        assertEq(hook.stepMaxBidAmount(step), 0);
    }

    function testActivatesAllGateSettingsTogetherAndPreservesEarlyStep() public {
        hook.enableStep(0, new bytes32[](0), new string[](0));
        hook.enableStepPermit(0);
        hook.setStepMaxBidAmount(0, 77);
        vm.roll(START + 1); // Early bidding is already live; step 1 is still configurable.
        hook.multicall(_activation(1, 500));
        assertTrue(hook.isStepEnabled(1));
        assertTrue(hook.isStepPermitEnabled(1));
        assertTrue(hook.verifiesEveryBid(1));
        assertEq(hook.stepMaxBidAmount(1), 500);
        assertTrue(hook.isStepEnabled(0));
        assertTrue(hook.isStepPermitEnabled(0));
        assertFalse(hook.verifiesEveryBid(0));
        assertEq(hook.stepMaxBidAmount(0), 77);
    }

    function testLateMinedActivationRevertsWithoutLeavingOrdinaryGate() public {
        vm.roll(START + 100);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepAlreadyStarted.selector, 1));
        hook.multicall(_activation(1, 500));
        _assertUntouched(1);
    }

    function testBatchRevertsEntirelyWhenACallFails() public {
        bytes[] memory calls = _activation(1, 500);
        calls[1] = abi.encodeCall(hook.enableStep, (1, new bytes32[](0), new string[](1)));
        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.multicall(calls);
        _assertUntouched(1);
    }

    function testRetainedProvidersNeedNoProviderCall() public {
        bytes32[] memory providers = new bytes32[](1);
        providers[0] = keccak256("provider");
        string[] memory ids = new string[](1);
        ids[0] = "provider";
        hook.enableStep(1, providers, ids);
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(hook.requireStepNotStarted, (1));
        calls[1] = abi.encodeCall(hook.enableStepPermit, (1));
        calls[2] = abi.encodeCall(hook.setStepMaxBidAmount, (1, 500));
        calls[3] = abi.encodeCall(hook.setVerifyEveryBid, (1, true));
        hook.multicall(calls);
        assertEq(hook.getStepProviders(1), providers);
        assertTrue(hook.verifiesEveryBid(1));
        assertEq(hook.stepMaxBidAmount(1), 500);
    }

    function testRejectsNonOwnerAndMissingGate() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.multicall(_activation(1, 500));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(hook.requireStepNotStarted, (1));
        calls[1] = abi.encodeCall(hook.setVerifyEveryBid, (1, true));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.NoGateConfigured.selector, 1));
        hook.multicall(calls);
        _assertUntouched(1);
    }

    function testRequireStepNotStartedTracksTheStepStart() public {
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 2));
        hook.requireStepNotStarted(2);
        vm.roll(START + 99);
        hook.requireStepNotStarted(1);
        vm.roll(START + 100);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepAlreadyStarted.selector, 1));
        hook.requireStepNotStarted(1);
    }

    function testDirectLateEnableRevertsButDisablingRemainsAvailable() public {
        hook.enableStep(1, new bytes32[](0), new string[](0));
        hook.enableStepPermit(1);
        hook.setVerifyEveryBid(1, true);
        vm.roll(START + 100);
        hook.setVerifyEveryBid(1, false);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepAlreadyStarted.selector, 1));
        hook.setVerifyEveryBid(1, true);
        assertFalse(hook.verifiesEveryBid(1));
    }
}
