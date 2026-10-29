// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {HookProofValidation} from "../../src/periphery/libraries/HookProofValidation.sol";
import {UmiaValidationHookBase, MockCCA} from "./UmiaValidationHookBase.t.sol";

contract HookProofFreshnessTest is UmiaValidationHookBase {
    function test_registrationProofCannotBeReusedForAnotherAuction() public {
        UmiaValidationHook other = _newHook(admin, address(zktlsVerifier), address(0));
        MockCCA otherCCA = _deploySingleStepCCA();
        vm.startPrank(admin);
        other.setCCA(address(otherCCA));
        other.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);

        bytes memory proof = _createProofForUser(user);
        _register(hook, user, 0, proof);
        vm.prank(address(otherCCA));
        vm.expectRevert(HookProofValidation.RegistrationProofContextMismatch.selector);
        other.validate(0, 0, user, user, abi.encodePacked(uint256(0), proof));
    }

    function test_unregisterClearsRegistrationUntilAProofIsResubmitted() public {
        bytes memory proof = _createProofForUser(user);
        _register(hook, user, 0, proof);
        address[] memory users = new address[](1);
        users[0] = user;
        vm.prank(admin);
        hook.unregisterBatch(users);
        assertFalse(hook.isVerified(0, user));
        _register(hook, user, 0, proof);
        assertTrue(hook.isVerified(0, user));
    }

    function test_registrationReplayDoesNotEmitMisleadingRegisteredEvent() public {
        UmiaValidationHook h = _deployThreeStepHook();
        vm.startPrank(admin);
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();
        bytes memory proof = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, h.cca());
        _register(h, user, 0, proof);
        vm.roll(200);
        address auction = h.cca();
        vm.recordLogs();
        vm.prank(auction);
        h.validate(0, 0, user, user, abi.encodePacked(uint256(1), proof));
        // The registered wallet short-circuits: only the zk accrual, no Registered event
        // moving the indexer's registration later.
        assertEq(vm.getRecordedLogs().length, 1);
        assertTrue(h.isVerified(0, user));
    }

    function test_credentialViewMatchesEmptyBidAcrossGateModes() public {
        MockCCA cca2 = _deployTwoStepCCA();
        UmiaValidationHook h = _newHook(admin, address(zktlsVerifier), address(0));
        vm.warp(block.timestamp + 1);
        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();
        _register(h, user, 0, _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2)));
        assertTrue(h.authorizesWithoutCredential(1, user));
        vm.prank(admin);
        h.setVerifyEveryBid(1, true);
        assertFalse(h.authorizesWithoutCredential(1, user));
        vm.roll(200);
        vm.prank(address(cca2));
        vm.expectPartialRevert(UmiaValidationHook.ProofRequired.selector);
        h.validate(0, 1, user, makeAddr("sponsor"), "");
        vm.startPrank(admin);
        h.setVerifyEveryBid(1, false);
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(1);
        vm.stopPrank();
        assertFalse(h.authorizesWithoutCredential(1, user));
        vm.prank(address(cca2));
        vm.expectPartialRevert(UmiaValidationHook.ServerPermitRequired.selector);
        h.validate(0, 1, user, user, "");
        vm.prank(admin);
        h.disableStepPermit(1);
        assertTrue(h.authorizesWithoutCredential(1, user));
        vm.prank(address(cca2));
        h.validate(0, 1, user, user, "");
        vm.startPrank(admin);
        h.enableStepPermit(1);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepAlreadyStarted.selector, uint256(1)));
        h.setVerifyEveryBid(1, true);
        vm.stopPrank();
        assertFalse(h.authorizesWithoutCredential(1, user));
        vm.prank(admin);
        h.disableStep(1);
        assertTrue(h.authorizesWithoutCredential(1, user));
        assertFalse(h.authorizesWithoutCredential(99, user));
    }
}
