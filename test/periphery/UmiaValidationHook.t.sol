// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IValidationHook} from "@continuous-clearing-auction/interfaces/IValidationHook.sol";
import {
    IBaseERC1155ValidationHook
} from "@continuous-clearing-auction/periphery/validationHooks/BaseERC1155ValidationHook.sol";
import {
    IGatedERC1155ValidationHook
} from "@continuous-clearing-auction/periphery/validationHooks/GatedERC1155ValidationHook.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {IGatedValidationHook} from "../../src/interfaces/IGatedValidationHook.sol";
import {IMaxBidPriceValidationHook} from "../../src/interfaces/IMaxBidPriceValidationHook.sol";
import {IVerifyEveryBidHook} from "../../src/interfaces/IVerifyEveryBidHook.sol";
import {IUmiaValidationHook} from "../../src/interfaces/IUmiaValidationHook.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {HookServerPermits} from "../../src/periphery/HookServerPermits.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {UmiaValidationHookBase, MockCCA, StaleMockCCA} from "./UmiaValidationHookBase.t.sol";

contract UmiaValidationHookTest is UmiaValidationHookBase {
    // ============ Pre-verification Flow ============

    function test_validate_robinhoodGateUsesL2Block() public {
        vm.chainId(46_630);
        address arbSys = address(100);
        vm.etch(arbSys, address(new MockArbSys()).code);
        MockArbSys(arbSys).setArbBlockNumber(step0Start);
        vm.roll(1); // Ancestor height is before the auction, but L2 is in its gated step.
        UmiaValidationHook nitroHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        vm.startPrank(admin);
        nitroHook.setCCA(address(mockCCA));
        nitroHook.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, uint256(0)));
        nitroHook.validate(0, 1, user, user, bytes(""));

        MockArbSys(arbSys).setArbBlockNumber(step0End);
        vm.prank(address(mockCCA));
        nitroHook.validate(0, 1, user, user, bytes(""));
    }

    function test_validate_inline_emitsProofVerified() public {
        bytes memory proofData = _createProofForUser(user);

        vm.roll(step0Start);
        vm.prank(address(mockCCA));
        vm.expectEmit(true, true, false, false);
        emit UmiaValidationHook.ProofVerified(user, 0, bytes32(0));
        hook.validate(0, 0, user, user, abi.encodePacked(uint256(0), proofData));
    }

    // ============ Inline Verification Flow ============

    function test_validate_inline_validProof_succeeds() public {
        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_validate_inline_contextMismatch_reverts() public {
        address wrongUser = makeAddr("wrongUser");
        bytes memory proofData = _createProofForUserWithWrongContext(user, wrongUser);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ContextAddressMismatch.selector, user, wrongUser));
        hook.validate(0, 0, user, user, hookData);
    }

    function test_validate_inline_storesVerification() public {
        assertFalse(hook.isVerified(0, user));

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    // ============ Inline Verification — Monotonic Step Prefix ============

    function test_validate_inline_monotonic_differentProviders_succeeds() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(200); // step 1 — different providers, but proofStep=0 targets step 0's providers
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);

        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
    }

    function test_validate_inline_futureStep_reverts() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(1), proofData);

        vm.roll(100); // step 0 — proofStep=1 > currentStep=0
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofStepTooHigh.selector, 1, 0));
        hook2.validate(0, 0, user, user, hookData);
    }

    function test_validate_inline_monotonic_alreadyVerified_shortCircuits() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        _register(hook2, user, 0, proofData);

        vm.roll(200); // step 1 — already verified from step 0, hookData not needed
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inline_stepPrefixed_storesLowestStep() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        // First: inline at step 1 with PROVIDER_HASH_2 proof
        bytes memory proofStep1 = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_2, address(cca2));
        bytes memory hookData1 = abi.encodePacked(uint256(1), proofStep1);
        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData1);
        assertTrue(hook2.isVerified(1, user));
        assertFalse(hook2.isVerified(0, user));

        // Second: inline at step 0 with PROVIDER_HASH_1 proof — lowers the stored step
        bytes memory proofStep0 = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        bytes memory hookData0 = abi.encodePacked(uint256(0), proofStep0);
        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData0);
        assertTrue(hook2.isVerified(0, user));
    }

    function test_validate_permitOnlyStep_rejectsProofWithServerPermitRequired() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        hook2.enableStepPermit(0);
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        // Permit-only step: a zkTLS proof is the wrong credential, so the step's gate
        // (permit) drives the error rather than the payload's type byte.
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        hook2.validate(0, 0, user, user, hookData);
    }

    // ============ Inline Verification — Extended Edge Cases ============

    function test_validate_inline_threeStepSkip_succeeds() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployThreeStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        hook2.enableStep(2, _singleHash(PROVIDER_HASH_3), _singleId("provider-3"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(300); // step 2 — proof targets step 0, skipping step 1 entirely
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);

        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
        assertTrue(hook2.isVerified(2, user));
    }

    function test_validate_inline_outOfBoundsProofStep_reverts() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(99), proofData);

        vm.roll(200); // step 1 — proofStep=99 far exceeds currentStep=1
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofStepTooHigh.selector, 99, 1));
        hook2.validate(0, 0, user, user, hookData);
    }

    function test_validate_inline_shortHookData_reverts() public {
        vm.roll(step0Start);
        // 14 bytes: too short for the leading proofStep word -> ProofRequired, not a panic.
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook.validate(0, 0, user, user, hex"0000000000000000000000000000");
    }

    function test_validate_permitOnly_truncatedPermit_reverts() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        vm.roll(step0Start);
        // just the 0x01 type byte: too short for the permit ABI head -> ServerPermitRequired, not a panic.
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, hex"01");
    }

    function test_validate_permitOnly_truncatedSignatureTail_reverts() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        // Canonical head (0x01 || permitStep, nonce, deadline, offset=0x80) whose length word
        // declares a 65-byte signature, but no tail data follows. The envelope check must revert
        // ServerPermitRequired instead of letting abi.decode read out of bounds.
        bytes memory truncated =
            abi.encodePacked(uint8(0x01), uint256(0), bytes32(0), uint256(0), uint256(0x80), uint256(65));

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, truncated);
    }

    function test_validate_permitOnly_hugeSignatureLength_reverts() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        // Canonical head whose signature length word is crafted at type(uint256).max. The
        // envelope check must revert ServerPermitRequired, not an arithmetic-overflow panic.
        bytes memory malformed =
            abi.encodePacked(uint8(0x01), uint256(0), bytes32(0), uint256(0), uint256(0x80), type(uint256).max);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, malformed);
    }

    function test_validate_bothGates_emptyHookData_reverts() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider")); // proof gate
        h.enableStepPermit(0); // and permit gate
        vm.stopPrank();

        vm.roll(step0Start);
        // both gates configured, no payload -> generic NotVerified (either credential works).
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.NotVerified.selector, user));
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inline_step0_withAllStepsEnabled() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployThreeStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        hook2.enableStep(2, _singleHash(PROVIDER_HASH_3), _singleId("provider-3"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        // Inline at step 0 — proofStep=0, currentStep=0, exact boundary
        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);
        assertTrue(hook2.isVerified(0, user));

        // Now bid at step 1 — short-circuits because already verified from step 0
        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        // And step 2 — also short-circuits
        vm.roll(300);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inline_secondUserIndependent() public {
        address user2 = makeAddr("user2");
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        // User1 verifies at step 0 inline
        bytes memory proof1 = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        bytes memory hookData1 = abi.encodePacked(uint256(0), proof1);
        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData1);

        // User2 is NOT verified — should still revert
        vm.roll(200);
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 1));
        hook2.validate(0, 0, user2, user2, bytes(""));

        // User2 verifies at step 1 inline with step 1's provider
        bytes memory proof2 = _createProofForUserWithProviderAndAuction(user2, PROVIDER_HASH_2, address(cca2));
        bytes memory hookData2 = abi.encodePacked(uint256(1), proof2);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user2, user2, hookData2);

        // User1: verified from step 0 (covers 0,1)
        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
        // User2: verified from step 1 only
        assertFalse(hook2.isVerified(0, user2));
        assertTrue(hook2.isVerified(1, user2));
    }

    function test_validate_inline_proofStepEqualsCurrentStep_boundaryCheck() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployThreeStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        hook2.enableStep(2, _singleHash(PROVIDER_HASH_3), _singleId("provider-3"));
        vm.stopPrank();

        // proofStep == currentStep at each step boundary
        bytes memory proof0 = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_2, address(cca2));
        bytes memory hookData = abi.encodePacked(uint256(1), proof0);

        vm.roll(200); // step 1: proofStep=1 == currentStep=1
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);
        assertTrue(hook2.isVerified(1, user));
        assertFalse(hook2.isVerified(0, user)); // NOT verified at step 0
    }

    // ============ Validate — Enabled Step ============

    function test_validate_inEnabledStep_whenNotVerified_reverts() public {
        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inEnabledStep_whenVerified_succeeds() public {
        bytes memory proofData = _createProofForUser(user);
        _register(hook, user, 0, proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inEnabledStep_whenSenderDiffers_succeeds() public {
        address other = makeAddr("other");

        bytes memory proofData = _createProofForUser(user);
        _register(hook, user, 0, proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, other, bytes(""));
    }

    function test_validate_inEnabledStep_verifiedForLaterStep_reverts() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        vm.stopPrank();

        _register(hook2, user, 1, proofData);

        vm.roll(100);
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inEnabledStep_verifiedForCorrectStep_succeeds() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        _register(hook2, user, 1, proofData);

        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    // ============ Validate — Monotonic Verification ============

    function test_validate_monotonic_verifiedAtStep0_passesStep1() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        _register(hook2, user, 0, proofData);

        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_monotonic_verifiedAtStep1_failsStep0() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        _register(hook2, user, 1, proofData);

        vm.roll(200);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        vm.roll(100);
        vm.prank(hook2.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_monotonic_laterProofKeepsEarlierRegistration() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        _register(hook2, user, 0, proofData);
        // A registered owner's hookData is ignored, so a step-1 proof cannot move the registration later.
        _register(hook2, user, 1, proofData);

        assertTrue(hook2.isVerified(0, user), "registration must stay dated to step 0");
    }

    // ============ Validate — Disabled Step ============

    function test_validate_inDisabledStep_allowsAnyone() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.prank(admin);
        hook2.setCCA(address(cca2));

        vm.roll(step0Start);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inDisabledStep_allowsDifferentSender() public {
        address other = makeAddr("other");

        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.prank(admin);
        hook2.setCCA(address(cca2));

        vm.roll(step0Start);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, other, bytes(""));
    }

    // ============ Validate — Outside Steps / No CCA ============

    function test_validate_outsideSteps_allowsAnyone() public {
        vm.roll(step0End);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_outsideSteps_allowsDifferentSender() public {
        address other = makeAddr("other");
        vm.roll(step0End);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, other, bytes(""));
    }

    function test_validate_noCCA_allowsAnyone() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        freshHook.validate(0, 0, user, user, bytes(""));
    }

    // ============ setCCA ============

    function test_setCCA_succeeds() public view {
        IUmiaValidationHook.BlockRange[] memory steps = hook.getSteps();
        assertEq(steps.length, 1);
        assertEq(steps[0].startBlock, step0Start);
        assertEq(steps[0].endBlock, step0End);
    }

    function test_setCCA_emitsEvent() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.CCASet(address(cca2));
        vm.prank(admin);
        hook2.setCCA(address(cca2));
    }

    function test_setCCA_zeroAddress_reverts() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ZeroAddress.selector);
        hook2.setCCA(address(0));
    }

    function test_setCCA_alreadySet_isNoOp() public {
        MockCCA otherCCA = _deploySingleStepCCA();

        vm.prank(admin);
        hook.setCCA(address(otherCCA));

        assertEq(hook.cca(), address(mockCCA));
    }

    function test_setCCA_nonOwner_reverts() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook2.setCCA(address(cca2));
    }

    // ============ enableStep / disableStep ============

    function test_enableStep_succeeds() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        assertFalse(hook2.isStepEnabled(0));

        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        assertTrue(hook2.isStepEnabled(0));
        assertFalse(hook2.isStepEnabled(1));
        vm.stopPrank();
    }

    function test_enableStep_emitsEvent() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepEnabled(0);
        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        vm.stopPrank();
    }

    function test_enableStep_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.enableStep(5, _emptyHashes(), _emptyIds());
    }

    function test_enableStep_noCCA_reverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.enableStep(0, _emptyHashes(), _emptyIds());
    }

    function test_enableStep_whenNotOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.enableStep(0, _emptyHashes(), _emptyIds());
    }

    function test_disableStep_succeeds() public {
        assertTrue(hook.isStepEnabled(0));

        vm.prank(admin);
        hook.disableStep(0);
        assertFalse(hook.isStepEnabled(0));
    }

    function test_disableStep_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepDisabled(0);
        vm.prank(admin);
        hook.disableStep(0);
    }

    function test_disableStep_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.disableStep(5);
    }

    // ============ enableStepBatch / disableStepBatch ============

    function test_enableStepBatch_succeeds() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;
        bytes32[][] memory providerHashes = new bytes32[][](2);
        providerHashes[0] = _emptyHashes();
        providerHashes[1] = _emptyHashes();
        string[][] memory providerIds = new string[][](2);
        providerIds[0] = _emptyIds();
        providerIds[1] = _emptyIds();
        hook2.enableStepBatch(indices, providerHashes, providerIds);

        assertTrue(hook2.isStepEnabled(0));
        assertTrue(hook2.isStepEnabled(1));
        vm.stopPrank();
    }

    function test_disableStepBatch_succeeds() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;
        hook2.disableStepBatch(indices);

        assertFalse(hook2.isStepEnabled(0));
        assertFalse(hook2.isStepEnabled(1));
        vm.stopPrank();
    }

    // ============ setStepProviders / addStepProvider ============

    function test_setStepProviders_succeeds() public {
        vm.prank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 1);
        assertEq(providers[0], PROVIDER_HASH_1);
    }

    function test_setStepProviders_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderSet(0, PROVIDER_HASH_1, "provider-1");
        vm.prank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.setStepProviders(5, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_noCCA_reverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_whenNotOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProviders_replacesArray() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 2);
        assertEq(providers[0], PROVIDER_HASH_1);
        assertEq(providers[1], PROVIDER_HASH_2);
    }

    function test_addStepProviders_appendsToArray() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.addStepProviders(steps, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 2);
        assertEq(providers[0], PROVIDER_HASH_1);
        assertEq(providers[1], PROVIDER_HASH_2);
    }

    function test_addStepProviders_multiple() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_2;
        hashes[1] = PROVIDER_HASH_3;
        string[] memory ids = new string[](2);
        ids[0] = "provider-2";
        ids[1] = "provider-3";
        hook.addStepProviders(steps, hashes, ids);
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 3);
        assertEq(providers[0], PROVIDER_HASH_1);
        assertEq(providers[1], PROVIDER_HASH_2);
        assertEq(providers[2], PROVIDER_HASH_3);
    }

    function test_addStepProviders_acrossSteps() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 1;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        string[] memory ids = new string[](2);
        ids[0] = "provider-1";
        ids[1] = "provider-2";
        hook2.addStepProviders(steps, hashes, ids);
        vm.stopPrank();

        assertEq(hook2.getStepProviders(0).length, 1);
        assertEq(hook2.getStepProviders(0)[0], PROVIDER_HASH_1);
        assertEq(hook2.getStepProviders(1).length, 1);
        assertEq(hook2.getStepProviders(1)[0], PROVIDER_HASH_2);
    }

    function test_addStepProviders_emitsEvents() public {
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderSet(0, PROVIDER_HASH_1, "provider-1");
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderSet(0, PROVIDER_HASH_2, "provider-2");

        vm.prank(admin);
        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        string[] memory ids = new string[](2);
        ids[0] = "provider-1";
        ids[1] = "provider-2";
        hook.addStepProviders(steps, hashes, ids);
    }

    function test_addStepProviders_arrayMismatch_reverts() public {
        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.addStepProviders(steps, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_addStepProviders_outOfBounds_reverts() public {
        uint256[] memory steps = new uint256[](1);
        steps[0] = 5;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.addStepProviders(steps, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_addStepProviders_noCCA_reverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.addStepProviders(steps, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
    }

    function test_setStepProvidersBatch_succeeds() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        bytes32[][] memory hashes = new bytes32[][](2);
        hashes[0] = _singleHash(PROVIDER_HASH_1);
        hashes[1] = _singleHash(PROVIDER_HASH_2);

        string[][] memory ids = new string[][](2);
        ids[0] = _singleId("provider-1");
        ids[1] = _singleId("provider-2");

        hook2.setStepProvidersBatch(indices, hashes, ids);
        vm.stopPrank();

        bytes32[] memory providers0 = hook2.getStepProviders(0);
        assertEq(providers0.length, 1);
        assertEq(providers0[0], PROVIDER_HASH_1);
        bytes32[] memory providers1 = hook2.getStepProviders(1);
        assertEq(providers1.length, 1);
        assertEq(providers1[0], PROVIDER_HASH_2);
    }

    function test_setStepProvidersBatch_arrayLengthMismatch_reverts() public {
        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        bytes32[][] memory hashes = new bytes32[][](1);
        hashes[0] = _singleHash(PROVIDER_HASH_1);

        string[][] memory ids = new string[][](1);
        ids[0] = _singleId("provider-1");

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.setStepProvidersBatch(indices, hashes, ids);
    }

    function test_getStepProviders_returnsEmptyForUnconfiguredStep() public view {
        bytes32[] memory providers = hook.getStepProviders(1);
        assertEq(providers.length, 0);
    }

    // ============ Provider Hash Validation ============

    function test_validate_withCorrectProviderHash_succeeds() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_1);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_validate_withWrongProviderHash_reverts() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ProviderHashMismatch.selector, PROVIDER_HASH_1, PROVIDER_HASH_2)
        );
        hook.validate(0, 0, user, user, hookData);
    }

    function test_validate_inline_wrongProviderHash_reverts() public {
        vm.prank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);

        vm.roll(step0Start);
        vm.prank(address(mockCCA));
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ProviderHashMismatch.selector, PROVIDER_HASH_1, PROVIDER_HASH_2)
        );
        hook.validate(0, 0, user, user, abi.encodePacked(uint256(0), proofData));
    }

    function test_validate_differentStepsDifferentProviders() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.setStepProviders(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        vm.stopPrank();

        bytes memory proofForStep0 = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        bytes memory hookData = abi.encodePacked(uint256(0), proofForStep0);

        vm.roll(100);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, hookData);
        assertTrue(hook2.isVerified(0, user));
    }

    // ============ Multiple Providers Per Step ============

    function test_validate_withMultipleProviders_matchesAny() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 0, user, user, hookData);

        assertTrue(hook.isVerified(0, user));
    }

    function test_validate_withMultipleProviders_noMatch_reverts() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_3);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ProviderHashMismatch.selector, PROVIDER_HASH_1, PROVIDER_HASH_3)
        );
        hook.validate(0, 0, user, user, hookData);
    }

    function test_enableStep_emptyProviders_noPermit_isOpen() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        // no server permit enabled -> the step has no gate at all
        vm.stopPrank();

        vm.roll(step0Start);
        // Empty providers + no permit = open: the bid passes with no hookData, and a
        // stray proof is ignored (no verification stored) rather than reverting.
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, bytes(""));

        bytes memory proofData = _createProofForUserWithProvider(user, PROVIDER_HASH_2);
        vm.prank(hook2.cca());
        hook2.validate(0, 0, user, user, abi.encodePacked(uint256(0), proofData));
        assertFalse(hook2.isVerified(0, user));
    }

    // ============ isVerified ============

    function test_isVerified_returnsFalseByDefault() public view {
        assertFalse(hook.isVerified(0, user));
    }

    function test_isVerified_isMonotonic() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        _register(hook2, user, 0, proofData);

        assertTrue(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
    }

    function test_isVerified_notEligibleForEarlierSteps() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2));
        _register(hook2, user, 1, proofData);

        assertFalse(hook2.isVerified(0, user));
        assertTrue(hook2.isVerified(1, user));
    }

    // ============ ERC165 ============

    function test_supportsInterface() public view {
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertTrue(hook.supportsInterface(type(IValidationHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IUmiaValidationHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IGatedValidationHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IVerifyEveryBidHook).interfaceId));
    }

    /// @dev Integrators discover the hook by these IDs, so a change to any of these interfaces
    ///      must be a deliberate one: update the constants here and the tables in docs/contracts.
    function test_supportsInterface_idsAreStable() public pure {
        assertEq(type(IUmiaValidationHook).interfaceId, bytes4(0x5084080f));
        assertEq(type(IMaxBidPriceValidationHook).interfaceId, bytes4(0x2268a4c3));
        assertEq(type(IGatedValidationHook).interfaceId, bytes4(0x6d417064));
        assertEq(type(IVerifyEveryBidHook).interfaceId, bytes4(0x98e51cb6));
    }

    /// @dev Our local declaration is only useful while its ID matches the one their UI probes.
    function test_gatedInterfaceId_matchesUniswap() public pure {
        assertEq(type(IGatedValidationHook).interfaceId, type(IGatedERC1155ValidationHook).interfaceId);
    }

    /// @dev A consumer that saw this ID would call `erc1155()` and `tokenId()`, which we lack.
    function test_supportsInterface_erc1155GateNotClaimed() public view {
        assertFalse(hook.supportsInterface(type(IBaseERC1155ValidationHook).interfaceId));
    }

    /// @dev Must stay byte-identical to Uniswap's MaxBidPriceValidationHook so their tooling
    ///      decodes our revert. Adding parameters back would change it.
    function test_maxBidPriceExceeded_selectorMatchesUniswap() public pure {
        assertEq(UmiaValidationHook.MaxBidPriceExceeded.selector, bytes4(0x77c99cf5));
    }

    /// @dev Uniswap standardised `maxBidPrice() == 0` as "no effective cap", so the claim is
    ///      static: an uncapped hook still implements the interface, it just reports no cap.
    function test_supportsInterface_maxBidPrice_regardlessOfCap() public {
        assertEq(hook.maxBidPrice(), 0);
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));

        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));

        vm.prank(admin);
        hook.setMaxBidPrice(0);
        assertTrue(hook.supportsInterface(type(IMaxBidPriceValidationHook).interfaceId));
    }

    function test_supportsInterface_WhenNotSupported() public view {
        bytes4 unsupported = bytes4(keccak256("not_supported"));
        assertFalse(hook.supportsInterface(unsupported));
    }

    function testFuzz_supportsInterface_WhenNotSupported(bytes4 interfaceId) public view {
        vm.assume(
            interfaceId != type(IERC165).interfaceId && interfaceId != type(IValidationHook).interfaceId
                && interfaceId != type(IUmiaValidationHook).interfaceId
                && interfaceId != type(IMaxBidPriceValidationHook).interfaceId
                && interfaceId != type(IGatedValidationHook).interfaceId
        );
        assertFalse(hook.supportsInterface(interfaceId));
    }

    // ============ Expiration Block ============

    function test_expirationBlock_isLastGatedStepEnd() public view {
        assertEq(hook.expirationBlock(), step0End);
    }

    function test_expirationBlock_zeroBeforeSetCCA() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        assertEq(freshHook.expirationBlock(), 0);
    }

    function test_expirationBlock_zeroWhenNoStepEnabled() public {
        UmiaValidationHook hook2 = _deployThreeStepHook();

        assertEq(hook2.expirationBlock(), 0);
    }

    /// @dev An enabled step with no providers and no permit lets everyone bid (see validate).
    function test_expirationBlock_ignoresEnabledButUngatedStep() public {
        UmiaValidationHook hook2 = _deployThreeStepHook();

        vm.prank(admin);
        hook2.enableStep(1, _emptyHashes(), _emptyIds());

        assertEq(hook2.expirationBlock(), 0);
    }

    function test_expirationBlock_countsPermitOnlyStep() public {
        UmiaValidationHook hook2 = _deployThreeStepHook();

        vm.startPrank(admin);
        hook2.enableStep(1, _emptyHashes(), _emptyIds());
        hook2.enableStepPermit(1);
        vm.stopPrank();

        assertEq(hook2.expirationBlock(), 300);
    }

    function test_expirationBlock_tracksHighestGatedStep() public {
        UmiaValidationHook hook2 = _deployThreeStepHook();

        vm.startPrank(admin);
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.enableStep(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));
        assertEq(hook2.expirationBlock(), 300);

        hook2.disableStep(1);
        assertEq(hook2.expirationBlock(), 200);

        hook2.disableStep(0);
        assertEq(hook2.expirationBlock(), 0);
        vm.stopPrank();
    }

    function test_expirationBlock_dropsStepWhenPermitDisabled() public {
        UmiaValidationHook hook2 = _deployThreeStepHook();

        vm.startPrank(admin);
        hook2.enableStep(0, _emptyHashes(), _emptyIds());
        hook2.enableStepPermit(0);
        assertEq(hook2.expirationBlock(), 200);

        hook2.disableStepPermit(0);
        assertEq(hook2.expirationBlock(), 0);
        vm.stopPrank();
    }

    /// @dev Their UI compares it against the current block, so it must not track the live step.
    function test_expirationBlock_constantAsAuctionAdvances() public {
        UmiaValidationHook hook2 = _deployThreeStepHook();

        vm.prank(admin);
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        vm.roll(150);
        assertEq(hook2.expirationBlock(), 200);
        vm.roll(350);
        assertEq(hook2.expirationBlock(), 200);
    }

    // ============ Stale Step Fallback ============

    function test_validate_staleStep_enforcesNextStepVerification() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        StaleMockCCA cca = _deployStaleTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        bytes memory proofData = _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca));
        _register(h, user, 1, proofData);

        vm.roll(200);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_staleStep_revertsUnverified() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        StaleMockCCA cca = _deployStaleTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        vm.roll(200);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 1));
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_staleStep_pastAllStepsAllowsAnyone() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        StaleMockCCA cca = _deployStaleTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        vm.stopPrank();

        vm.roll(300);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, bytes(""));
    }

    // ============ unregister / unregisterBatch ============

    function test_unregister_succeeds() public {
        bytes memory proofData = _createProofForUser(user);
        _register(hook, user, 0, proofData);
        assertTrue(hook.isVerified(0, user));

        vm.prank(admin);
        hook.unregister(user);
        assertFalse(hook.isVerified(0, user));
    }

    function test_unregister_emitsEvent() public {
        bytes memory proofData = _createProofForUser(user);
        _register(hook, user, 0, proofData);

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.Unregistered(user);
        vm.prank(admin);
        hook.unregister(user);
    }

    function test_unregister_noCCA_reverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.unregister(user);
    }

    function test_unregister_whenNotOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.unregister(user);
    }

    function test_unregisterBatch_succeeds() public {
        address user2 = makeAddr("user2");
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = user2;

        _register(hook, user, 0, _createProofForUser(user));
        _register(hook, user2, 0, _createProofForUser(user2));
        assertTrue(hook.isVerified(0, user));
        assertTrue(hook.isVerified(0, user2));

        vm.prank(admin);
        hook.unregisterBatch(users);

        assertFalse(hook.isVerified(0, user));
        assertFalse(hook.isVerified(0, user2));
    }

    function test_unregisterBatch_emitsEvents() public {
        address user2 = makeAddr("user2");
        address[] memory users = new address[](2);
        users[0] = user;
        users[1] = user2;

        _register(hook, user, 0, _createProofForUser(user));
        _register(hook, user2, 0, _createProofForUser(user2));

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.Unregistered(user);
        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.Unregistered(user2);
        vm.prank(admin);
        hook.unregisterBatch(users);
    }

    function test_unregisterBatch_noCCA_reverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        address[] memory users = new address[](1);
        users[0] = user;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.unregisterBatch(users);
    }

    function test_unregisterBatch_whenNotOwner_reverts() public {
        address[] memory users = new address[](1);
        users[0] = user;

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.unregisterBatch(users);
    }

    function test_unregister_clearsVerification() public {
        bytes memory proofData = _createProofForUser(user);

        _register(hook, user, 0, proofData);
        assertTrue(hook.isVerified(0, user));

        vm.prank(admin);
        hook.unregister(user);
        assertFalse(hook.isVerified(0, user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        hook.validate(0, 0, user, user, bytes(""));
    }

    // ============ removeStepProviders ============

    function test_removeStepProviders_succeeds() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 1);
        assertEq(providers[0], PROVIDER_HASH_2);
    }

    function test_removeStepProviders_multiple() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        hook.removeStepProviders(steps, hashes);
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 0);
    }

    function test_removeStepProviders_acrossSteps() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));
        hook2.setStepProviders(1, _singleHash(PROVIDER_HASH_2), _singleId("provider-2"));

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 1;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        hook2.removeStepProviders(steps, hashes);
        vm.stopPrank();

        assertEq(hook2.getStepProviders(0).length, 0);
        assertEq(hook2.getStepProviders(1).length, 0);
    }

    function test_removeStepProviders_emitsEvents() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("provider-1", "provider-2"));

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_1);
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_2);

        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = PROVIDER_HASH_1;
        hashes[1] = PROVIDER_HASH_2;
        hook.removeStepProviders(steps, hashes);
        vm.stopPrank();
    }

    function test_removeStepProviders_lastElement_succeeds() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 0);
    }

    function test_removeStepProviders_swapAndPop() public {
        vm.startPrank(admin);
        bytes32[] memory threeHashes = new bytes32[](3);
        threeHashes[0] = PROVIDER_HASH_1;
        threeHashes[1] = PROVIDER_HASH_2;
        threeHashes[2] = PROVIDER_HASH_3;
        string[] memory threeIds = new string[](3);
        threeIds[0] = "p1";
        threeIds[1] = "p2";
        threeIds[2] = "p3";
        hook.setStepProviders(0, threeHashes, threeIds);

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 2);
        assertEq(providers[0], PROVIDER_HASH_3);
        assertEq(providers[1], PROVIDER_HASH_2);
    }

    function test_removeStepProviders_notFound_reverts() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("provider-1"));

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProviderNotFound.selector, 0, PROVIDER_HASH_2));
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_2));
        vm.stopPrank();
    }

    function test_removeStepProviders_arrayMismatch_reverts() public {
        uint256[] memory steps = new uint256[](2);
        steps[0] = 0;
        steps[1] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.ArrayLengthMismatch.selector);
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    function test_removeStepProviders_outOfBounds_reverts() public {
        uint256[] memory steps = new uint256[](1);
        steps[0] = 5;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    function test_removeStepProviders_noCCA_reverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    function test_removeStepProviders_whenNotOwner_reverts() public {
        uint256[] memory steps = new uint256[](1);
        steps[0] = 0;

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.removeStepProviders(steps, _singleHash(PROVIDER_HASH_1));
    }

    // ============ setStepProviders emits StepProviderRemoved ============

    function test_setStepProviders_emitsRemovedForDroppedProviders() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_2), _twoIds("p1", "p2"));

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_1);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_2), _singleId("p2"));
        vm.stopPrank();
    }

    function test_setStepProviders_retainsSameProviders() public {
        vm.startPrank(admin);
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("p1"));
        hook.setStepProviders(0, _singleHash(PROVIDER_HASH_1), _singleId("p1"));
        vm.stopPrank();

        bytes32[] memory providers = hook.getStepProviders(0);
        assertEq(providers.length, 1);
        assertEq(providers[0], PROVIDER_HASH_1);
    }

    function test_enableStep_emitsRemovedForReplacedProviders() public {
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("p1"));

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepProviderRemoved(0, PROVIDER_HASH_1);
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_2), _singleId("p2"));
        vm.stopPrank();
    }

    // ============ Server Permit — Signer Management ============

    function test_setSigner_succeeds() public {
        vm.prank(admin);
        hook.setSigner(signerAddress);

        assertEq(hook.signer(), signerAddress);
    }

    function test_setSigner_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit HookServerPermits.SignerSet(address(0), signerAddress);
        vm.prank(admin);
        hook.setSigner(signerAddress);
    }

    function test_setSigner_notOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setSigner(signerAddress);
    }

    function test_setSigner_toZero_disables() public {
        vm.startPrank(admin);
        hook.setSigner(signerAddress);
        assertEq(hook.signer(), signerAddress);

        hook.setSigner(address(0));
        assertEq(hook.signer(), address(0));
        vm.stopPrank();
    }

    // ============ Server Permit — enableStepPermit / disableStepPermit ============

    function test_enableStepPermit_succeeds() public {
        assertFalse(hook.isStepPermitEnabled(0));

        vm.prank(admin);
        hook.enableStepPermit(0);

        assertTrue(hook.isStepPermitEnabled(0));
    }

    function test_enableStepPermit_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepPermitEnabled(0);
        vm.prank(admin);
        hook.enableStepPermit(0);
    }

    function test_enableStepPermit_notOwner_reverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.enableStepPermit(0);
    }

    function test_enableStepPermit_outOfBounds_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 5));
        hook.enableStepPermit(5);
    }

    function test_enableStepPermit_noCCA_reverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);

        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.enableStepPermit(0);
    }

    function test_disableStepPermit_succeeds() public {
        vm.startPrank(admin);
        hook.enableStepPermit(0);
        assertTrue(hook.isStepPermitEnabled(0));

        hook.disableStepPermit(0);
        assertFalse(hook.isStepPermitEnabled(0));
        vm.stopPrank();
    }

    function test_disableStepPermit_emitsEvent() public {
        vm.startPrank(admin);
        hook.enableStepPermit(0);

        vm.expectEmit(true, false, false, false);
        emit UmiaValidationHook.StepPermitDisabled(0);
        hook.disableStepPermit(0);
        vm.stopPrank();
    }

    // ============ Server Permit — Inline ============

    function test_validate_inlineServerPermit_succeeds() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-1");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce));
        // Server permits no longer persist verification — every bid requires a fresh permit.
        assertFalse(h.isVerified(0, user));
    }

    function test_validate_inlineServerPermit_boundBidAmountSucceeds() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-amount-bound-success");
        uint128 signedAmount = 1 ether;
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, signedAmount);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, signedAmount, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_rejectsDifferentBidAmount() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-amount-bound");
        uint128 signedAmount = 1 ether;
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, signedAmount);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(HookServerPermits.InvalidSignature.selector);
        h.validate(0, 2 ether, user, user, hookData);

        assertFalse(h.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_replay_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-replay");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);
        vm.prank(h.cca());

        vm.expectRevert(abi.encodeWithSelector(HookServerPermits.PermitAlreadyUsed.selector, nonce));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_freshPermitPerBid_succeeds() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        vm.roll(step0Start);

        bytes32 nonceA = keccak256("nonce-A");
        bytes memory sigA = _signServerPermit(address(h), user, 0, nonceA, deadline);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, _encodePermitHookData(0, nonceA, deadline, sigA));

        bytes32 nonceB = keccak256("nonce-B");
        bytes memory sigB = _signServerPermit(address(h), user, 0, nonceB, deadline);
        vm.prank(h.cca());
        h.validate(0, 0, user, user, _encodePermitHookData(0, nonceB, deadline, sigB));

        assertTrue(h.isPermitNonceUsed(nonceA));
        assertTrue(h.isPermitNonceUsed(nonceB));
    }

    function test_validate_inlineServerPermit_emptyHookData_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inlineServerPermit_monotonic_succeeds() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        h.enableStepPermit(1);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-monotonic");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(200); // step 1 — permit signed for step 0, monotonic allows it
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_permitStepTooHigh_reverts() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        h.enableStepPermit(1);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-too-high");
        bytes memory signature = _signServerPermit(address(h), user, 1, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(1, nonce, deadline, signature);

        vm.roll(step0Start); // step 0 — permit signed for step 1 which is in the future
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.PermitStepTooHigh.selector, 1, 0));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_bareStepAfterPermitStep_isOpen() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        // step 1 has no providers and is not permit-enabled -> open, even though step 0
        // is permit-enabled: server permits are single-bid, not monotonic whitelisting.
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-only-first");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(200); // step 1 — open; a submitted permit is ignored, not consumed
        vm.prank(h.cca());
        h.validate(0, 0, user, user, hookData);
        assertFalse(h.isPermitNonceUsed(nonce));

        // and an empty bid passes too
        vm.prank(h.cca());
        h.validate(0, 0, user, user, bytes(""));
    }

    function test_validate_inlineServerPermit_notEnabled_reverts() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(1); // step 1 is permit-gated; step 0 is not permit-enabled
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-not-enabled");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        // step 1 accepts permits, but this permit targets step 0, which is not permit-enabled.
        vm.roll(200);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitNotEnabled.selector, 0));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_providerOnlyStep_rejectsPermitWithProofRequired() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        // provider-gated, permit NOT enabled
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-proof-required");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        // Provider-only step: a server permit is the wrong credential -> ProofRequired.
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_bothGates_typeBytePicksCredential() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider")); // proof gate
        h.enableStepPermit(0); // and permit gate
        vm.stopPrank();

        vm.roll(step0Start);

        // 0x01 byte -> permit path: a valid permit passes.
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("both-gates-permit");
        bytes memory permitData =
            _encodePermitHookData(0, nonce, deadline, _signServerPermit(address(h), user, 0, nonce, deadline));
        vm.prank(h.cca());
        h.validate(0, 0, user, user, permitData);

        // non-0x01 -> proof path: a valid matching proof passes.
        address bidder2 = makeAddr("both-gates-bidder2");
        bytes memory proofData = _createProofForUserWithProviderAndAuction(bidder2, PROVIDER_HASH_1, address(cca2));
        vm.prank(h.cca());
        h.validate(0, 0, bidder2, bidder2, abi.encodePacked(uint256(0), proofData));
        assertTrue(h.isVerified(0, bidder2));
    }

    function test_validate_inlineServerPermit_signerNotSet_reverts() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-no-signer");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(HookServerPermits.SignerNotSet.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_invalidSignature_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-invalid-sig");
        uint256 wrongKey = 0x1111111111111111111111111111111111111111111111111111111111111111;
        bytes32 DOMAIN_TYPEHASH_LOCAL =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 SERVER_PERMIT_TYPEHASH_LOCAL =
            keccak256("ServerPermit(address wallet,uint256 step,bytes32 nonce,uint256 deadline,uint128 amount)");
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH_LOCAL, keccak256("UmiaValidationHook"), keccak256("1"), block.chainid, address(h)
            )
        );
        bytes32 structHash = keccak256(abi.encode(SERVER_PERMIT_TYPEHASH_LOCAL, user, 0, nonce, deadline, uint128(0)));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory wrongSig = abi.encodePacked(r, s, v);

        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, wrongSig);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(HookServerPermits.InvalidSignature.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_boundToHookDomain_rejectedByOtherHook() public {
        UmiaValidationHook hookA = _setupServerPermit();
        UmiaValidationHook hookB = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cross-hook");
        bytes memory signature = _signServerPermit(address(hookA), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(hookB.cca());
        vm.expectRevert(HookServerPermits.InvalidSignature.selector);
        hookB.validate(0, 0, user, user, hookData);

        vm.prank(hookA.cca());
        hookA.validate(0, 0, user, user, hookData);
        assertTrue(hookA.isPermitNonceUsed(nonce));
    }

    function test_validate_inlineServerPermit_wrongLengthSignature_revertsInvalidSignature() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-bad-len");
        // 10 bytes: a valid ABI bytes tail (the envelope check passes) but not a 64/65-byte ECDSA
        // signature. tryRecover must surface the hook's InvalidSignature, not OpenZeppelin's length error.
        bytes memory shortSig = new bytes(10);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, shortSig);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(HookServerPermits.InvalidSignature.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_inlineServerPermit_expiredDeadline_reverts() public {
        UmiaValidationHook h = _setupServerPermit();

        uint256 deadline = block.timestamp - 1;
        bytes32 nonce = keccak256("nonce-expired");
        bytes memory signature = _signServerPermit(address(h), user, 0, nonce, deadline);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.roll(step0Start);
        vm.prank(h.cca());
        vm.expectRevert(HookServerPermits.ExpiredDeadline.selector);
        h.validate(0, 0, user, user, hookData);
    }

    function test_validate_proofOnPermitOnlyStep_rejected() public {
        UmiaValidationHook h = _setupServerPermit();

        bytes memory proofData = _createProofForUser(user);
        bytes memory hookData = abi.encodePacked(uint256(0), proofData);

        vm.roll(step0Start);
        // Permit-only step (server permit set up, no providers): a proof is rejected as
        // the wrong credential for the step's gate.
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 0));
        h.validate(0, 0, user, user, hookData);
    }

    // ============ Helper Functions ============

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — setMaxBidPrice
    // ─────────────────────────────────────────────────────────

    function test_setMaxBidPrice_storesValue() public {
        assertEq(hook.maxBidPrice(), 0, "initial cap should be 0");
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000, "cap not stored");
    }

    function test_setMaxBidPrice_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.MaxBidPriceSet(5000);
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
    }

    function test_setMaxBidPrice_zeroRemovesCap() public {
        vm.startPrank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000);

        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.MaxBidPriceSet(0);
        hook.setMaxBidPrice(0);
        assertEq(hook.maxBidPrice(), 0, "cap should be cleared");
        vm.stopPrank();
    }

    function test_setMaxBidPrice_nonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 0, "cap should remain unchanged after revert");
    }

    function test_setMaxBidPrice_noCCAReverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        assertEq(freshHook.maxBidPrice(), 0, "fresh hook cap should be 0");
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.setMaxBidPrice(5000);
        assertEq(freshHook.maxBidPrice(), 0, "cap should remain 0 after revert");
    }

    function test_setMaxBidPrice_tickAlignmentReverts_midTick() public {
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        hook.setMaxBidPrice(1050);
        assertEq(hook.maxBidPrice(), 0, "cap should remain 0 after revert");
    }

    function test_setMaxBidPrice_tickAlignmentReverts_variousOffsets() public {
        uint256[4] memory badPrices = [uint256(1001), 1099, 1150, 1199];
        for (uint256 i; i < badPrices.length; i++) {
            vm.prank(admin);
            vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
            hook.setMaxBidPrice(badPrices[i]);
        }
        assertEq(hook.maxBidPrice(), 0, "cap should remain 0 after all reverts");
    }

    function test_setMaxBidPrice_tickAlignmentValid() public {
        vm.prank(admin);
        hook.setMaxBidPrice(1100);
        assertEq(hook.maxBidPrice(), 1100);
    }

    function test_setMaxBidPrice_atFloorPrice() public {
        vm.prank(admin);
        hook.setMaxBidPrice(1000);
        assertEq(hook.maxBidPrice(), 1000, "floor price itself should be valid");
    }

    function test_setMaxBidPrice_belowFloorPriceReverts() public {
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        hook.setMaxBidPrice(900);
        assertEq(hook.maxBidPrice(), 0, "cap should remain 0");
    }

    function test_setMaxBidPrice_belowFloorPriceReverts_oneBelow() public {
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        hook.setMaxBidPrice(999);
        assertEq(hook.maxBidPrice(), 0);
    }

    function test_setMaxBidPrice_updateExisting() public {
        vm.startPrank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000);

        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.MaxBidPriceSet(3000);
        hook.setMaxBidPrice(3000);
        assertEq(hook.maxBidPrice(), 3000);
        vm.stopPrank();
    }

    function test_setMaxBidPrice_updateEmitsCorrectOldAndNew() public {
        vm.startPrank(admin);
        hook.setMaxBidPrice(2000);
        hook.setMaxBidPrice(4000);
        hook.setMaxBidPrice(1000);
        assertEq(hook.maxBidPrice(), 1000, "should reflect last set value");
        vm.stopPrank();
    }

    function test_setMaxBidPrice_differentTickSpacings() public {
        MockCCA cca2 = _deploySingleStepCCA();
        cca2.setFloorPrice(500);
        cca2.setTickSpacing(250);

        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));

        h.setMaxBidPrice(750);
        assertEq(h.maxBidPrice(), 750, "500 + 1*250 = 750 should be valid");

        h.setMaxBidPrice(500);
        assertEq(h.maxBidPrice(), 500, "floor price itself should be valid");

        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        h.setMaxBidPrice(600);

        vm.expectRevert(UmiaValidationHook.PriceNotAlignedToTick.selector);
        h.setMaxBidPrice(499);

        assertEq(h.maxBidPrice(), 500, "cap should remain at last valid value");
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — validate enforcement
    // ─────────────────────────────────────────────────────────

    function test_validate_belowCapSucceeds() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        hook.validate(4000, 1 ether, user, user, "");
        assertEq(hook.maxBidPrice(), 5000, "cap should be unchanged after validate");
    }

    function test_validate_atCapSucceeds() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        hook.validate(5000, 1 ether, user, user, "");
        assertEq(hook.maxBidPrice(), 5000, "cap should be unchanged after validate");
    }

    function test_validate_aboveCapReverts() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start);
        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(6000, 1 ether, user, user, "");
    }

    function test_validate_aboveCapByOneReverts() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(5001, 1 ether, user, user, "");
    }

    function test_validate_noCapAllowsAnyPrice() public {
        assertEq(hook.maxBidPrice(), 0, "cap should start at 0");

        vm.roll(step0Start - 1);
        vm.prank(address(mockCCA));
        hook.validate(type(uint256).max, 1 ether, user, user, "");
    }

    function test_validate_exactBoundaryPrices() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);

        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        hook.validate(cap - 1, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        hook.validate(cap, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(cap + 1, 1 ether, user, user, "");
    }

    function test_validate_capDoesNotLimitAmount() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        vm.roll(step0Start - 1);

        uint128[5] memory amounts =
            [uint128(1), uint128(1 ether), uint128(100 ether), uint128(1_000_000 ether), type(uint128).max];
        for (uint256 i; i < amounts.length; i++) {
            vm.prank(address(mockCCA));
            hook.validate(5000, amounts[i], user, user, "");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — batch / scenario
    // ─────────────────────────────────────────────────────────

    function test_validate_batch20Bids_exactAcceptRejectCounts() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        uint256 accepted;
        uint256 rejected;

        for (uint256 i; i < 20; i++) {
            uint256 price = 1000 + i * 300;
            vm.prank(address(mockCCA));
            if (price <= cap) {
                vm.prank(hook.cca());
                hook.validate(price, 1 ether, user, user, "");
                accepted++;
            } else {
                vm.prank(hook.cca());
                vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
                hook.validate(price, 1 ether, user, user, "");
                rejected++;
            }
        }

        assertEq(accepted, 14, "bids at prices 1000..4900 (step 300) should pass");
        assertEq(rejected, 6, "bids at prices 5200..6700 (step 300) should fail");
        assertEq(accepted + rejected, 20, "total should be 20");
    }

    function test_validate_allBidsAtCap_allSucceed() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        for (uint256 i; i < 20; i++) {
            vm.prank(address(mockCCA));
            hook.validate(cap, 1 ether, user, user, "");
        }
    }

    function test_validate_allBidsAboveCap_allRevert() public {
        uint256 cap = 5000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        for (uint256 i; i < 10; i++) {
            uint256 price = cap + 1 + i * 100;
            vm.prank(address(mockCCA));
            vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
            hook.validate(price, 1 ether, user, user, "");
        }
    }

    function test_validate_multipleUsersAllCapped() public {
        uint256 cap = 3000;
        vm.prank(admin);
        hook.setMaxBidPrice(cap);
        vm.roll(step0Start - 1);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");
        address[3] memory users_ = [alice, bob, charlie];

        for (uint256 i; i < users_.length; i++) {
            vm.prank(address(mockCCA));
            hook.validate(cap, 1 ether, users_[i], users_[i], "");

            vm.prank(address(mockCCA));
            vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
            hook.validate(cap + 100, 1 ether, users_[i], users_[i], "");
        }
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — dynamic cap changes
    // ─────────────────────────────────────────────────────────

    function test_validate_lowerCapRejectsFormerlyValidPrice() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        hook.validate(4000, 1 ether, user, user, "");

        vm.prank(admin);
        hook.setMaxBidPrice(3000);
        assertEq(hook.maxBidPrice(), 3000);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(4000, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        hook.validate(3000, 1 ether, user, user, "");
    }

    function test_validate_raiseCapAcceptsPreviouslyRejectedPrice() public {
        vm.prank(admin);
        hook.setMaxBidPrice(3000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(4000, 1 ether, user, user, "");

        vm.prank(admin);
        hook.setMaxBidPrice(5000);
        assertEq(hook.maxBidPrice(), 5000);

        vm.prank(address(mockCCA));
        hook.validate(4000, 1 ether, user, user, "");
    }

    function test_validate_removeCapAllowsAnyPriceAfterSetting() public {
        vm.prank(admin);
        hook.setMaxBidPrice(3000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(9000, 1 ether, user, user, "");

        vm.prank(admin);
        hook.setMaxBidPrice(0);
        assertEq(hook.maxBidPrice(), 0, "cap should be removed");

        vm.prank(address(mockCCA));
        hook.validate(9000, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        hook.validate(type(uint256).max, 1 ether, user, user, "");
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — interaction with step verification
    // ─────────────────────────────────────────────────────────

    function test_validate_capEnforcedDuringActiveStep() public {
        vm.prank(admin);
        hook.setMaxBidPrice(5000);

        vm.roll(step0Start);

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(6000, 1 ether, user, user, "");
    }

    function test_validate_capRevertsBeforeVerificationCheck() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(3000);
        vm.stopPrank();

        vm.roll(step0Start);

        vm.prank(address(cca2));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        h.validate(5000, 1 ether, user, user, "");
    }

    function test_validate_belowCapStillNeedsVerification() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        vm.prank(address(cca2));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, 0));
        h.validate(3000, 1 ether, user, user, "");
    }

    function test_validate_permitUnderPriceCapSucceeds() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cap-under");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1 ether);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        h.validate(3000, 1 ether, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce), "permit nonce should be burned after a valid bid");
    }

    function test_validate_permitAtPriceCapSucceeds() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cap-at");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1 ether);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        h.validate(5000, 1 ether, user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce), "permit nonce should be burned");
    }

    function test_validate_permitAbovePriceCapReverts_nonceNotBurned() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setMaxBidPrice(5000);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("cap-above");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1 ether);
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        h.validate(6000, 1 ether, user, user, hookData);

        assertFalse(h.isPermitNonceUsed(nonce), "permit nonce must not be burned when the price cap rejects the bid");
    }

    // ─────────────────────────────────────────────────────────
    // Max Bid Price Tests — cap at floor price (tightest cap)
    // ─────────────────────────────────────────────────────────

    function test_validate_capAtFloorPrice_onlyFloorAllowed() public {
        vm.prank(admin);
        hook.setMaxBidPrice(1000);
        assertEq(hook.maxBidPrice(), 1000);
        vm.roll(step0Start - 1);

        vm.prank(address(mockCCA));
        hook.validate(1000, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(1100, 1 ether, user, user, "");

        vm.prank(address(mockCCA));
        vm.expectRevert(UmiaValidationHook.MaxBidPriceExceeded.selector);
        hook.validate(1001, 1 ether, user, user, "");
    }

    // ============ Sybil resistance (OPRF identity) ============

    function test_inlineRegistration_sybil_rejectedForDifferentWallet() public {
        string memory params = '{"username":"sybil-test"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);
        _register(hook, user, 0, proofA);

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentity(user2, PROVIDER_HASH_1, params);

        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, params);
        vm.prank(address(mockCCA));
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.IdentityAlreadyClaimed.selector, PROVIDER_HASH_1, identityHash, user
            )
        );
        hook.validate(0, 0, user2, user2, abi.encodePacked(uint256(0), proofB));
    }

    function test_inlineRegistration_sybil_sameUserReregistersAfterUnregister() public {
        string memory params = '{"username":"sybil-test"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);

        _register(hook, user, 0, proofA);
        vm.prank(admin);
        hook.unregister(user);
        // The identity slot still belongs to the same wallet, so its proof registers it again.
        _register(hook, user, 0, proofA);
        assertTrue(hook.isVerified(0, user));
    }

    function test_inlineRegistration_sybil_differentIdentitiesAllowed() public {
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, '{"username":"alice"}');
        _register(hook, user, 0, proofA);

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentity(user2, PROVIDER_HASH_1, '{"username":"bob"}');
        _register(hook, user2, 0, proofB);

        assertTrue(hook.isVerified(0, user));
        assertTrue(hook.isVerified(0, user2));
    }

    function test_inlineRegistration_sybil_identityProviderIsolation() public {
        string memory params = '{"username":"shared"}';

        // Hook A has PROVIDER_HASH_1 enabled at step 0.
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);
        _register(hook, user, 0, proofA);

        // The distinct identity-provider namespace keeps independent accounts separate.
        UmiaValidationHook hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();
        vm.startPrank(admin);
        hook2.setCCA(address(cca2));
        hook2.enableStep(0, _singleHash(PROVIDER_HASH_2), _singleId("test-provider-2"));
        vm.stopPrank();

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentityForAuction(user2, PROVIDER_HASH_2, params, address(cca2));
        _register(hook2, user2, 0, proofB);
        assertTrue(hook2.isVerified(0, user2));
    }

    function test_inlineRegistration_sybil_emptyExtractedParametersRejected() public {
        vm.roll(step0Start);
        string[13] memory emptyObjects = [
            string("{}"),
            "{ }",
            "{\t\n\r }",
            '{"account":""}',
            '{"account":" "}',
            '{"account":"\\t\\n"}',
            '{"account":"\\u0020"}',
            '{"account":"\\u00a0"}',
            string(bytes.concat(bytes('{"account":"'), hex"c2a0", bytes('"}'))),
            '{"account":"valid","other":""}',
            '{"account":null}',
            '{"account":123}',
            '{"account":[]}'
        ];
        for (uint256 i; i < emptyObjects.length; ++i) {
            bytes memory proofData = _createProofWithIdentity(user, PROVIDER_HASH_1, emptyObjects[i]);
            vm.prank(address(mockCCA));
            vm.expectRevert(UmiaValidationHook.EmptyIdentityParameters.selector);
            hook.validate(0, 0, user, user, abi.encodePacked(uint256(0), proofData));
        }
    }

    function test_inlineRegistration_sybil_multipleNonEmptyIdentityValuesAccepted() public {
        string memory params = string(bytes.concat(bytes('{"account":"'), hex"c3a9", bytes('","other":"b"}')));
        _register(hook, user, 0, _createProofWithIdentity(user, PROVIDER_HASH_1, params));
        assertTrue(hook.isVerified(0, user));
    }

    function test_inlineRegistration_sybil_crossRecipeSameNamespace() public {
        vm.prank(admin);
        hook.setStepProviders(0, _twoHashes(PROVIDER_HASH_1, PROVIDER_HASH_3), _twoIds("github-one", "github-two"));
        string memory params = '{"account":"stable-private-id"}';
        _register(hook, user, 0, _createProofWithIdentity(user, PROVIDER_HASH_1, params));
        bytes32 identityKey = _expectedIdentityHash(PROVIDER_HASH_1, params);
        assertEq(identityKey, 0xb10940d6eb3daf10fd2314c89fcacd69790663f230f45f3da441518d34e14ae4);
        assertEq(identityKey, _expectedIdentityHash(PROVIDER_HASH_3, params));

        address secondWallet = makeAddr("secondWallet");
        vm.prank(address(mockCCA));
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.IdentityAlreadyClaimed.selector, PROVIDER_HASH_3, identityKey, user
            )
        );
        hook.validate(
            0,
            0,
            secondWallet,
            secondWallet,
            abi.encodePacked(uint256(0), _createProofWithIdentity(secondWallet, PROVIDER_HASH_3, params))
        );

        vm.prank(admin);
        hook.unregister(user);
        _register(hook, user, 0, _createProofWithIdentity(user, PROVIDER_HASH_3, params));
        assertEq(hook.identityOwner(identityKey), user);
    }

    function test_identityProvider_assignmentCannotChange() public {
        vm.prank(admin);
        hook.setIdentityProvider(PROVIDER_HASH_1, "github");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.IdentityProviderImmutable.selector, PROVIDER_HASH_1));
        hook.setIdentityProvider(PROVIDER_HASH_1, "other");
    }

    function test_identityProvider_signedNamespaceMustMatchAssignment() public {
        UmiaValidationHook other = new UmiaValidationHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA auction = _deploySingleStepCCA();
        vm.startPrank(admin);
        other.setIdentityProvider(PROVIDER_HASH_1, "other");
        other.setCCA(address(auction));
        other.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("github"));
        vm.stopPrank();
        bytes memory proofData =
            _createProofWithIdentityForAuction(user, PROVIDER_HASH_1, '{"account":"private"}', address(auction));
        vm.roll(step0Start);
        vm.prank(address(auction));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.IdentityProviderMismatch.selector, PROVIDER_HASH_1));
        other.validate(0, 0, user, user, abi.encodePacked(uint256(0), proofData));
    }

    function test_inlineRegistration_sybil_emitsIdentityClaimedEvent() public {
        string memory params = '{"username":"alice"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);

        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, params);
        vm.roll(step0Start);
        vm.prank(address(mockCCA));
        vm.expectEmit(true, true, true, true);
        emit UmiaValidationHook.IdentityClaimed(user, PROVIDER_HASH_1, identityHash, 0);
        hook.validate(0, 0, user, user, abi.encodePacked(uint256(0), proofA));
    }

    function test_clearIdentity_ownerOnly() public {
        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, '{"username":"x"}');
        vm.expectRevert();
        hook.clearIdentity(identityHash);

        vm.prank(admin);
        hook.clearIdentity(identityHash);
        // No revert from owner; idempotent on a never-claimed slot.
    }

    function test_clearIdentity_allowsReRegistration() public {
        string memory params = '{"username":"alice"}';
        bytes memory proofA = _createProofWithIdentity(user, PROVIDER_HASH_1, params);
        _register(hook, user, 0, proofA);

        bytes32 identityHash = _expectedIdentityHash(PROVIDER_HASH_1, params);
        assertEq(hook.identityOwner(identityHash), user);

        vm.prank(admin);
        hook.clearIdentity(identityHash);
        assertEq(hook.identityOwner(identityHash), address(0));

        address user2 = makeAddr("user2");
        bytes memory proofB = _createProofWithIdentity(user2, PROVIDER_HASH_1, params);
        _register(hook, user2, 0, proofB);

        assertEq(hook.identityOwner(identityHash), user2);
        assertTrue(hook.isVerified(0, user2));
    }

    // ─────────────────────────────────────────────────────────
    // Per-Step zkTLS Bid Amount Cap — setStepMaxBidAmount config
    // ─────────────────────────────────────────────────────────

    function test_setStepMaxBidAmount_storesValue() public {
        assertEq(hook.stepMaxBidAmount(0), 0, "initial cap should be 0");
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        assertEq(hook.stepMaxBidAmount(0), ZK_CAP, "cap not stored");
    }

    function test_setStepMaxBidAmount_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.StepMaxBidAmountSet(0, ZK_CAP);
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
    }

    function test_setStepMaxBidAmount_zeroRemovesCap() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        assertEq(hook.stepMaxBidAmount(0), ZK_CAP);
        hook.setStepMaxBidAmount(0, 0);
        assertEq(hook.stepMaxBidAmount(0), 0, "cap should be cleared");
        vm.stopPrank();
    }

    function test_setStepMaxBidAmount_nonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        assertEq(hook.stepMaxBidAmount(0), 0, "cap should remain unchanged after revert");
    }

    function test_setStepMaxBidAmount_noCCAReverts() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        vm.expectRevert(UmiaValidationHook.NoCCA.selector);
        freshHook.setStepMaxBidAmount(0, ZK_CAP);
    }

    function test_setStepMaxBidAmount_outOfBoundsReverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.StepIndexOutOfBounds.selector, 1));
        hook.setStepMaxBidAmount(1, ZK_CAP);
    }

    // ─────────────────────────────────────────────────────────
    // Per-Step zkTLS Bid Amount Cap — validate enforcement
    // ─────────────────────────────────────────────────────────

    function test_zkCap_firstProofBidUnderCap_succeedsAndAccrues() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 400e6, user, user, _inlineProof(0, user));

        assertTrue(hook.isVerified(0, user), "proof should be stored on first bid");
        assertEq(hook.zkBidTotal(user, 0), 400e6, "first bid should accrue");
    }

    function test_zkCap_accumulatesAcrossBids_exceedReverts() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 400e6, user, user, "");
        vm.prank(hook.cca());
        hook.validate(0, 600e6, user, user, ""); // cumulative 1000e6, exactly at cap
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "cumulative should reach cap");
        vm.prank(hook.cca());

        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, 1, user, user, "");
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "total should be unchanged after revert");
    }

    function test_zkCap_noCapAllowsAnyAmount_noAccrual() public {
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, type(uint128).max, user, user, "");
        assertEq(hook.zkBidTotal(user, 0), 0, "uncapped steps do not accrue");
    }

    function test_zkCap_firstBidOverCap_leavesWalletUnverified() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, uint128(ZK_CAP + 1), user, user, _inlineProof(0, user));

        assertFalse(hook.isVerified(0, user), "proof storage must roll back when the first bid exceeds the cap");
        assertEq(hook.zkBidTotal(user, 0), 0);
    }

    function test_zkCap_capAddedMidStream_onlyCountsSubsequentBids() public {
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 800e6, user, user, ""); // uncapped, not counted
        assertEq(hook.zkBidTotal(user, 0), 0);

        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, ""); // now capped; only this counts
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP);
        vm.prank(hook.cca());

        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, 1, user, user, "");
    }

    function test_zkCap_walletsIndependentAtSameStep() public {
        address user2 = makeAddr("user2");
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        _register(hook, user, 0, _createProofForUser(user));
        _register(hook, user2, 0, _createProofForUser(user2));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, "");
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user2, user2, ""); // user2 has its own budget
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP);
        assertEq(hook.zkBidTotal(user2, 0), ZK_CAP);
    }

    function test_zkCap_perStepBudgetsIndependent_monotonicVerification() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.setStepMaxBidAmount(0, ZK_CAP);
        h.setStepMaxBidAmount(1, 500e6);
        vm.stopPrank();

        _register(h, user, 0, _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2))); // verified from step 0, monotonic

        // Step 0: fill its budget to the cap.
        vm.roll(100);
        vm.prank(h.cca());
        h.validate(0, uint128(ZK_CAP), user, user, "");
        assertEq(h.zkBidTotal(user, 0), ZK_CAP);

        // Step 1: independent budget governed by step 1's cap; step 0 spend does not consume it.
        vm.roll(200);
        vm.prank(h.cca());
        h.validate(0, 500e6, user, user, "");
        assertEq(h.zkBidTotal(user, 1), 500e6);
        assertEq(h.zkBidTotal(user, 0), ZK_CAP, "step 0 total untouched by step 1 bids");
        vm.prank(h.cca());

        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 1, 500e6 + 1, 500e6)
        );
        h.validate(0, 1, user, user, "");
    }

    function test_zkCap_permitPathUnaffectedByZkCap() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setStepMaxBidAmount(0, ZK_CAP);
        vm.stopPrank();

        vm.roll(step0Start);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("zk-cap-permit");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, uint128(ZK_CAP * 5));
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        // Amount far above the zk cap, but the permit path is independent and must not be capped.
        vm.prank(address(cca2));
        h.validate(0, uint128(ZK_CAP * 5), user, user, hookData);

        assertTrue(h.isPermitNonceUsed(nonce), "permit should be consumed");
        assertEq(h.zkBidTotal(user, 0), 0, "permit bids must not accrue into the zk total");
    }

    // ─────────────────────────────────────────────────────────
    // Auction-Wide zkTLS Bid Volume Cap — setZkGlobalMaxBidAmount config
    // ─────────────────────────────────────────────────────────

    function test_setZkGlobalMaxBidAmount_storesValue() public {
        assertEq(hook.zkGlobalMaxBidAmount(), 0, "initial cap should be 0");
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        assertEq(hook.zkGlobalMaxBidAmount(), ZK_GLOBAL_CAP, "cap not stored");
    }

    function test_setZkGlobalMaxBidAmount_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit UmiaValidationHook.ZkGlobalMaxBidAmountSet(ZK_GLOBAL_CAP);
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
    }

    function test_setZkGlobalMaxBidAmount_zeroRemovesCap() public {
        vm.startPrank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        hook.setZkGlobalMaxBidAmount(0);
        vm.stopPrank();
        assertEq(hook.zkGlobalMaxBidAmount(), 0, "cap should be cleared");
    }

    function test_setZkGlobalMaxBidAmount_nonOwnerReverts() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        assertEq(hook.zkGlobalMaxBidAmount(), 0, "cap should remain unchanged after revert");
    }

    function test_setZkGlobalMaxBidAmount_settableBeforeCCA() public {
        UmiaValidationHook freshHook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        freshHook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        assertEq(freshHook.zkGlobalMaxBidAmount(), ZK_GLOBAL_CAP, "cap should be configurable before pairing");
    }

    // ─────────────────────────────────────────────────────────
    // Auction-Wide zkTLS Bid Volume Cap — validate enforcement
    // ─────────────────────────────────────────────────────────

    function test_zkGlobalCap_sharedAcrossWallets_exceedReverts() public {
        address user2 = makeAddr("user2");
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        _register(hook, user, 0, _createProofForUser(user));
        _register(hook, user2, 0, _createProofForUser(user2));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 1_500e6, user, user, "");
        vm.prank(hook.cca());
        hook.validate(0, 500e6, user2, user2, ""); // shared pool now exactly at cap
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "wallets must draw from one shared pool");

        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user2, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        hook.validate(0, 1, user2, user2, "");
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "total should be unchanged after revert");
    }

    function test_zkGlobalCap_accruesWhileUncapped_capCountsHistory() public {
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_GLOBAL_CAP), user, user, "");
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "global total accrues even without a cap");

        // A cap set mid-auction counts the volume already landed.
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        hook.validate(0, 1, user, user, "");

        // Removing the cap reopens the zk path; the total keeps accruing.
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(0);
        vm.prank(hook.cca());
        hook.validate(0, 1, user, user, "");
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP + 1);
    }

    function test_zkGlobalCap_emitsAccrualEvent() public {
        _register(hook, user, 0, _createProofForUser(user));
        vm.roll(step0Start);

        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.ZkGlobalBidAccrued(user, 400e6, 400e6);
        vm.prank(hook.cca());
        hook.validate(0, 400e6, user, user, "");

        // The running total carries across bids; the indexer copies newTotal verbatim.
        vm.expectEmit(true, false, false, true);
        emit UmiaValidationHook.ZkGlobalBidAccrued(user, 100e6, 500e6);
        vm.prank(hook.cca());
        hook.validate(0, 100e6, user, user, "");
    }

    function test_zkGlobalCap_inlineProofFirstBidOverCap_leavesWalletUnverified() public {
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        hook.validate(0, uint128(ZK_GLOBAL_CAP + 1), user, user, _inlineProof(0, user));

        assertFalse(hook.isVerified(0, user), "proof storage must roll back when the bid exceeds the cap");
        assertEq(hook.zkGlobalBidTotal(), 0);
    }

    function test_zkGlobalCap_tighterThanStepCap_globalRevertsFirst() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_CAP - 1);
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, ZK_CAP, ZK_CAP - 1)
        );
        hook.validate(0, uint128(ZK_CAP), user, user, "");
    }

    function test_zkGlobalCap_stepCapStillBindsWhenGlobalHasRoom() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP)
        );
        hook.validate(0, uint128(ZK_CAP + 1), user, user, "");
        assertEq(hook.zkGlobalBidTotal(), 0, "global total must roll back when the step cap reverts");
    }

    function test_zkGlobalCap_permitPathNotCounted() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.setSigner(signerAddress);
        h.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();

        vm.roll(step0Start);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("zk-global-cap-permit");
        bytes memory signature =
            _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, uint128(ZK_GLOBAL_CAP * 5));
        bytes memory hookData = _encodePermitHookData(0, nonce, deadline, signature);

        vm.prank(address(cca2));
        h.validate(0, uint128(ZK_GLOBAL_CAP * 5), user, user, hookData);

        assertEq(h.zkGlobalBidTotal(), 0, "permit bids must not accrue into the global zk total");
    }

    function test_zkGlobalCap_verifiedWalletRequiresPermitOnLaterPermitOnlyStep() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(1);
        h.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();

        _register(h, user, 0, _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2)));
        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, uint128(ZK_GLOBAL_CAP), user, user, "");
        assertEq(h.zkGlobalBidTotal(), ZK_GLOBAL_CAP);

        vm.roll(step0End);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ServerPermitRequired.selector, 1));
        h.validate(0, 500e6, user, user, "");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("verified-permit-only");
        bytes memory signature = _signServerPermitWithAmount(address(h), user, 1, nonce, deadline, 500e6);
        bytes memory permitData = _encodePermitHookData(1, nonce, deadline, signature);

        vm.prank(h.cca());
        h.validate(0, 500e6, user, user, permitData);
        assertTrue(h.isPermitNonceUsed(nonce), "permit must be consumed");
        assertEq(h.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "permit-only bid must not use the zk budget");
        assertEq(h.zkBidTotal(user, 1), 0, "permit-only bid must not use the zk step cap");

        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(HookServerPermits.PermitAlreadyUsed.selector, nonce));
        h.validate(0, 500e6, user, user, permitData);
    }

    function test_zkGlobalCap_verifiedWalletOnLaterDualGateStillUsesProofCap() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(1);
        h.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();

        _register(h, user, 0, _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2)));
        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, uint128(ZK_GLOBAL_CAP), user, user, "");

        vm.roll(step0End);
        vm.prank(h.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        h.validate(0, 1, user, user, "");

        vm.prank(admin);
        h.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP + 1);
        vm.prank(h.cca());
        h.validate(0, 1, user, user, "");
        assertEq(h.zkGlobalBidTotal(), ZK_GLOBAL_CAP + 1, "later proof-gated bid still accrues globally");
    }

    function test_zkGlobalCap_verifiedWalletOnEnabledOpenStepDoesNotAccrue() public {
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployTwoStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();

        _register(h, user, 0, _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2)));
        vm.roll(step0Start);
        vm.prank(h.cca());
        h.validate(0, uint128(ZK_GLOBAL_CAP), user, user, "");

        vm.roll(step0End);
        vm.prank(h.cca());
        h.validate(0, 1, user, user, "");
        assertEq(h.zkGlobalBidTotal(), ZK_GLOBAL_CAP, "open step must not use the zk budget");
    }

    function test_zkGlobalCap_disabledStepNotCounted() public {
        vm.startPrank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        hook.disableStep(0);
        vm.stopPrank();

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_GLOBAL_CAP * 3), user, user, "");
        assertEq(hook.zkGlobalBidTotal(), 0, "open bids must not accrue into the global zk total");
    }

    function test_validate_revertsForNonCCACaller() public {
        _register(hook, user, 0, _createProofForUser(user));
        vm.roll(step0Start);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(UmiaValidationHook.CallerNotCCA.selector);
        hook.validate(0, 1000e6, user, user, "");
    }

    function test_zkCap_cannotBeInflatedByNonCCACaller() public {
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        _register(hook, user, 0, _createProofForUser(user));
        vm.roll(step0Start);

        // An attacker calling validate() directly (no funds moved) must not accrue into a
        // verified victim's per-step total and DoS their bids.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(UmiaValidationHook.CallerNotCCA.selector);
        hook.validate(0, uint128(ZK_CAP), user, user, "");

        assertEq(hook.zkBidTotal(user, 0), 0, "attacker must not inflate the victim's total");
        assertEq(hook.zkGlobalBidTotal(), 0, "attacker must not inflate the global total");
    }

    // ─────────────────────────────────────────────────────────
    // Cap Retune — lowering the per-wallet cap while raising the global cap
    // ─────────────────────────────────────────────────────────

    /// Operator retune: a wallet already past the NEW per-wallet cap is frozen at that step.
    /// The step total is never rebased on a cap change, so `used > cap` blocks even a 1-unit
    /// bid — raising the global cap does not unblock it.
    function test_capRetune_walletOverNewStepCap_isFrozenDespiteGlobalHeadroom() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP); // 1,000
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP); // 2,000
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, ""); // spends the full 1,000
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "wallet should sit at the old cap");

        // Retune: halve the per-wallet cap, double the global cap.
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP / 2); // 500 — below what the wallet already spent
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP * 2); // 4,000 — plenty of room
        vm.stopPrank();

        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "retune must not rebase the accrued total");

        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 1, ZK_CAP / 2)
        );
        hook.validate(0, 1, user, user, "");
        assertEq(hook.zkGlobalBidTotal(), ZK_CAP, "the rejected bid must not accrue globally");
    }

    /// The same retune leaves a fresh wallet fully able to bid up to the new, lower cap —
    /// the freeze is per-wallet, not a step-wide halt.
    function test_capRetune_freshWalletGetsNewLowerCap() public {
        address user2 = makeAddr("user2");
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));
        _register(hook, user2, 0, _createProofForUser(user2));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, "");

        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP / 2);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP * 2);
        vm.stopPrank();

        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP / 2), user2, user2, ""); // exactly the new cap
        assertEq(hook.zkBidTotal(user2, 0), ZK_CAP / 2, "fresh wallet should fill the new cap");

        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsStepCap.selector, user2, 0, ZK_CAP / 2 + 1, ZK_CAP / 2
            )
        );
        hook.validate(0, 1, user2, user2, "");
    }

    /// A wallet still under the new cap keeps exactly the residual headroom (newCap - used).
    function test_capRetune_partiallySpentWalletKeepsResidualHeadroom() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP);
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, 300e6, user, user, "");

        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP / 2); // 500, wallet has spent 300
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP * 2);
        vm.stopPrank();

        vm.prank(hook.cca());
        hook.validate(0, 200e6, user, user, ""); // consumes the exact 200 residual
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP / 2, "wallet should land exactly on the new cap");

        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP / 2 + 1, ZK_CAP / 2)
        );
        hook.validate(0, 1, user, user, "");
    }

    /// Raising the global cap genuinely reopens the shared pool: a bid that the old global
    /// cap rejected succeeds after the raise, with the accrued history still counted.
    function test_capRetune_raisingGlobalCapReopensSharedPool() public {
        address user2 = makeAddr("user2");
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP); // 2,000
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));
        _register(hook, user2, 0, _createProofForUser(user2));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, "");
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user2, user2, ""); // global now exactly at 2,000

        address user3 = makeAddr("user3");
        _register(hook, user3, 0, _createProofForUser(user3));
        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsGlobalCap.selector, user3, ZK_GLOBAL_CAP + 1, ZK_GLOBAL_CAP
            )
        );
        hook.validate(0, 1, user3, user3, "");

        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP / 2);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP * 2); // 4,000
        vm.stopPrank();

        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP / 2), user3, user3, ""); // fits both new caps
        assertEq(hook.zkGlobalBidTotal(), ZK_GLOBAL_CAP + ZK_CAP / 2, "global total keeps its history");
        assertEq(hook.zkBidTotal(user3, 0), ZK_CAP / 2, "fresh wallet fills the new per-wallet cap");
    }

    /// Ordering guard: the global cap is checked and accrued before the per-wallet cap, so a
    /// bid rejected by the per-wallet cap must not leave global volume behind.
    function test_capRetune_stepCapRejectionDoesNotLeakGlobalAccrual() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP * 2);
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, "");
        uint256 globalBefore = hook.zkGlobalBidTotal();

        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP / 2);

        vm.prank(hook.cca());
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.ZkBidExceedsStepCap.selector, user, 0, ZK_CAP + 500e6, ZK_CAP / 2)
        );
        hook.validate(0, 500e6, user, user, "");
        assertEq(hook.zkGlobalBidTotal(), globalBefore, "global total must roll back with the revert");
    }

    /// Footgun guard: 0 means "no cap", not "blocked". Retuning the per-wallet cap down to 0
    /// removes the gate entirely and stops accrual, so the global cap becomes the only limit.
    function test_capRetune_stepCapToZeroRemovesGateAndStopsAccrual() public {
        vm.startPrank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP * 2);
        vm.stopPrank();
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, "");

        vm.prank(admin);
        hook.setStepMaxBidAmount(0, 0); // reads as "uncapped", NOT "frozen"

        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, ""); // formerly capped wallet bids freely
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "an uncapped step stops accruing");
        assertEq(hook.zkGlobalBidTotal(), ZK_CAP * 2, "the global pool still counts the volume");
    }

    /// Asymmetry guard: the per-step total only accrues while a cap is set, so introducing a
    /// per-wallet cap mid-auction grants a full fresh allowance — unlike the global cap, which
    /// counts volume that landed while it was uncapped.
    function test_capRetune_introducingStepCapMidAuctionIgnoresPriorVolume() public {
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(ZK_GLOBAL_CAP * 2);
        _register(hook, user, 0, _createProofForUser(user));

        vm.roll(step0Start);
        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, ""); // no per-step cap yet -> no accrual
        assertEq(hook.zkBidTotal(user, 0), 0, "uncapped step must not accrue");
        assertEq(hook.zkGlobalBidTotal(), ZK_CAP, "global accrues regardless");

        vm.prank(admin);
        hook.setStepMaxBidAmount(0, ZK_CAP);

        vm.prank(hook.cca());
        hook.validate(0, uint128(ZK_CAP), user, user, ""); // full fresh 1,000 despite prior 1,000
        assertEq(hook.zkBidTotal(user, 0), ZK_CAP, "late cap grants a full allowance");
        assertEq(hook.zkGlobalBidTotal(), ZK_CAP * 2, "global keeps the running history");
    }
}
