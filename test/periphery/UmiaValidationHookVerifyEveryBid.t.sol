// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@solady/auth/Ownable.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {HookServerPermits} from "../../src/periphery/HookServerPermits.sol";
import {HookProofValidation} from "../../src/periphery/libraries/HookProofValidation.sol";
import {Reclaim} from "../../src/reclaim/Reclaim.sol";
import {Claims} from "../../src/reclaim/Claims.sol";
import {UmiaValidationHookBase, MockCCA} from "./UmiaValidationHookBase.t.sol";

/// @dev Exposes the internal bid-context check.
contract BidContextHarness {
    function validate(Reclaim.Proof memory proof, address auction, uint256 step, uint128 amount) external view {
        HookProofValidation.validateBid(proof, auction, step, amount, 10 minutes);
    }
}

/// @dev Verify-every-bid credentials, relayed bids and hook-local proof replay.
contract UmiaValidationHookVerifyEveryBidTest is UmiaValidationHookBase {
    function _createBidProof(address _user, bytes32 _providerHash, uint256 nonce) internal view returns (bytes memory) {
        return _createBidProofForAuction(_user, _providerHash, nonce, address(mockCCA), 0, 1);
    }

    function _createBidProofForAuction(
        address _user,
        bytes32 _providerHash,
        uint256 nonce,
        address auction,
        uint256 step,
        uint128 amount
    ) internal view returns (bytes memory) {
        return _createBidProofWithIdentity(_user, _providerHash, nonce, auction, step, amount, "");
    }

    /// @dev The default proof uses a distinct synthetic identity for each wallet.
    function _createBidProofWithIdentity(
        address _user,
        bytes32 _providerHash,
        uint256 nonce,
        address auction,
        uint256 step,
        uint128 amount,
        string memory extractedParameters
    ) internal view returns (bytes memory) {
        string memory params = bytes(extractedParameters).length == 0
            ? string(abi.encodePacked('{"account":"', _addressToString(_user), '"}'))
            : extractedParameters;
        string memory context = string(
            abi.encodePacked(
                '{"contextAddress":"',
                _addressToString(_user),
                '","providerHash":"',
                _bytes32ToHexString(_providerHash),
                '","identityProvider":"',
                _identityProvider(_providerHash),
                '","contextMessage":"bid:',
                _uint2str(block.chainid),
                ":",
                _address2str(auction),
                ":",
                _uint2str(step),
                ":",
                _uint2str(amount),
                ":",
                _uint2str(nonce),
                '","extractedParameters":',
                params,
                "}"
            )
        );

        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: _user, timestampS: uint32(block.timestamp), epoch: 2
        });

        bytes memory serialised = abi.encodePacked(
            _bytes2str(abi.encodePacked(claimData.identifier)),
            "\n",
            _address2str(claimData.owner),
            "\n",
            _uint2str(claimData.timestampS),
            "\n",
            _uint2str(claimData.epoch)
        );

        bytes32 messageHash =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", _uint2str(serialised.length), serialised));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WITNESS_PRIVATE_KEY, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        return abi.encode(proof);
    }

    function _verifyEveryBidSetup() internal {
        vm.startPrank(admin);
        hook.setSigner(signerAddress);
        hook.enableStepPermit(0);
        hook.setVerifyEveryBid(0, true);
        vm.stopPrank();
        vm.roll(step0Start);
    }

    function test_bidProof_identityGate_sameWalletBidsAgain() public {
        _verifyEveryBidSetup();
        string memory params = '{"username":"one-person"}';
        for (uint256 nonce = 1; nonce <= 2; ++nonce) {
            bytes memory proof =
                _createBidProofWithIdentity(user, PROVIDER_HASH_1, nonce, address(mockCCA), 0, 1, params);
            vm.prank(address(mockCCA));
            hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proof));
        }
        assertEq(hook.identityOwner(_expectedIdentityHash(PROVIDER_HASH_1, params)), user);
    }

    function test_bidProof_identityGate_rejectsAnotherWallet() public {
        _verifyEveryBidSetup();
        string memory params = '{"username":"one-person"}';
        bytes memory first = _createBidProofWithIdentity(user, PROVIDER_HASH_1, 1, address(mockCCA), 0, 1, params);
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), first));

        address user2 = makeAddr("user2");
        bytes memory second = _createBidProofWithIdentity(user2, PROVIDER_HASH_1, 2, address(mockCCA), 0, 1, params);
        vm.prank(address(mockCCA));
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.IdentityAlreadyClaimed.selector,
                PROVIDER_HASH_1,
                _expectedIdentityHash(PROVIDER_HASH_1, params),
                user
            )
        );
        hook.validate(0, 1, user2, user2, abi.encodePacked(uint256(0), second));
    }

    function test_verifyEveryBid_registeredWalletStillRequiresCredential() public {
        MockCCA cca2 = _deployTwoStepCCA();
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(1);
        h.setVerifyEveryBid(1, true);
        vm.stopPrank();
        _register(h, user, 0, _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca2)));
        vm.roll(200);
        vm.prank(address(cca2));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.NotVerified.selector, user));
        h.validate(0, 1, user, user, "");
    }

    function test_verifyEveryBid_twoFreshProofs_noStandingRegistration_replayFails() public {
        _verifyEveryBidSetup();
        bytes memory first = abi.encodePacked(uint256(0), _createBidProof(user, PROVIDER_HASH_1, 1));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, first);
        assertFalse(hook.isVerified(0, user));
        vm.prank(address(mockCCA));
        vm.expectPartialRevert(UmiaValidationHook.ProofAlreadyUsed.selector);
        hook.validate(0, 1, user, user, first);
        bytes memory second = abi.encodePacked(uint256(0), _createBidProof(user, PROVIDER_HASH_1, 2));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, second);
        assertFalse(hook.isVerified(0, user));
        assertEq(hook.zkGlobalBidTotal(), 2);
    }

    function test_verifyEveryBid_freshnessBoundaries() public {
        _verifyEveryBidSetup();
        vm.warp(10000);
        bytes memory proof = abi.encodePacked(uint256(0), _createBidProof(user, PROVIDER_HASH_1, 1));
        vm.warp(9999);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofFromFuture.selector);
        hook.validate(0, 1, user, user, proof);
        vm.warp(10601);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofExpired.selector);
        hook.validate(0, 1, user, user, proof);
        vm.warp(10600);
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, proof);
    }

    function test_verifyEveryBid_permitIgnoresExhaustedZkBudget() public {
        _verifyEveryBidSetup();
        vm.prank(admin);
        hook.setZkGlobalMaxBidAmount(1);
        bytes memory proof = abi.encodePacked(uint256(0), _createBidProof(user, PROVIDER_HASH_1, 1));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, proof);
        uint256 deadline = block.timestamp + 300;
        bytes32 nonce = keccak256("verify-every-bid permit");
        bytes memory permit = _encodePermitHookData(
            0, nonce, deadline, _signServerPermitWithAmount(address(hook), user, 0, nonce, deadline, 20)
        );
        vm.prank(address(mockCCA));
        hook.validate(0, 20, user, user, permit);
        assertEq(hook.zkGlobalBidTotal(), 1);
        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(HookServerPermits.PermitAlreadyUsed.selector, nonce));
        hook.validate(0, 20, user, user, permit);
    }

    function test_verifyEveryBid_earlyBidToVerifyEveryBidToPublic() public {
        MockCCA cca3 = _deployThreeStepCCA();
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        vm.startPrank(admin);
        h.setCCA(address(cca3));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStepPermit(0);
        h.enableStepPermit(1);
        h.setVerifyEveryBid(1, true);
        vm.stopPrank();
        // Register with the first early bid, then reuse verification throughout early bid.
        _register(h, user, 0, _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca3)));
        vm.warp(block.timestamp + 1 days);
        vm.roll(100);
        vm.prank(address(cca3));
        h.validate(0, 1, user, user, "");
        vm.prank(address(cca3));
        h.validate(0, 1, user, user, "");
        // Neither standing status nor an earlier-step inline credential clears a step that verifies every bid.
        vm.roll(200);
        vm.prank(address(cca3));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.NotVerified.selector, user));
        h.validate(0, 1, user, user, "");
        bytes memory proof = abi.encodePacked(uint256(0), _createBidProof(user, PROVIDER_HASH_1, 2));
        vm.prank(address(cca3));
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.CredentialStepMismatch.selector, uint256(0), uint256(1))
        );
        h.validate(0, 1, user, user, proof);
        uint256 deadline = block.timestamp + 300;
        bytes32 nonce = keccak256("old-step");
        bytes memory permit = _encodePermitHookData(
            0, nonce, deadline, _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1)
        );
        vm.prank(address(cca3));
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.CredentialStepMismatch.selector, uint256(0), uint256(1))
        );
        h.validate(0, 1, user, user, permit);
        proof = abi.encodePacked(uint256(1), _createBidProofForAuction(user, PROVIDER_HASH_1, 3, address(cca3), 1, 1));
        vm.prank(address(cca3));
        h.validate(0, 1, user, user, proof);
        // Public remains open to both previously verified and fresh wallets.
        vm.roll(300);
        vm.prank(address(cca3));
        h.validate(0, 1, user, user, "");
        vm.prank(address(cca3));
        h.validate(0, 1, address(123), address(123), "");
    }

    function test_verifyEveryBid_configurationRequiresGateAndOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        hook.setVerifyEveryBid(0, true);
        vm.startPrank(admin);
        hook.setVerifyEveryBid(0, true);
        assertTrue(hook.verifiesEveryBid(0));
        hook.setVerifyEveryBid(0, false);
        assertFalse(hook.verifiesEveryBid(0));
        hook.setStepProviders(0, _emptyHashes(), _emptyIds());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.NoGateConfigured.selector, uint256(0)));
        hook.setVerifyEveryBid(0, true);
        vm.stopPrank();
    }

    function test_verifyEveryBid_removedCredentialsFailClosedAndRemainGated() public {
        _verifyEveryBidSetup();
        vm.startPrank(admin);
        hook.disableStepPermit(0);
        hook.setStepProviders(0, _emptyHashes(), _emptyIds());
        vm.stopPrank();
        assertEq(hook.expirationBlock(), step0End);
        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.NoGateConfigured.selector, uint256(0)));
        hook.validate(0, 1, user, user, "");
    }

    function test_verifyEveryBid_disableClearsFlagSoLiveReenableIsOrdinary() public {
        _verifyEveryBidSetup();
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true, address(hook));
        emit UmiaValidationHook.VerifyEveryBidSet(0, false);
        hook.disableStep(0);
        assertFalse(hook.verifiesEveryBid(0));
        hook.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();

        // The live step is back to ordinary verification: an inline proof registers the wallet.
        _register(hook, user, 0, _createProofForUser(user));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, "");
    }

    function test_verifyEveryBid_disableStepBatchClearsFlag() public {
        _verifyEveryBidSetup();
        vm.expectEmit(true, false, false, true, address(hook));
        emit UmiaValidationHook.VerifyEveryBidSet(0, false);
        vm.prank(admin);
        hook.disableStepBatch(new uint256[](1));
        assertFalse(hook.verifiesEveryBid(0));
    }

    function test_verifyEveryBid_revertedCapDoesNotConsumeProofOrRegisterWallet() public {
        _verifyEveryBidSetup();
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, 1);
        bytes memory proof =
            abi.encodePacked(uint256(0), _createBidProofForAuction(user, PROVIDER_HASH_1, 1, address(mockCCA), 0, 2));
        vm.prank(address(mockCCA));
        vm.expectRevert(
            abi.encodeWithSelector(
                UmiaValidationHook.ZkBidExceedsStepCap.selector, user, uint256(0), uint256(2), uint256(1)
            )
        );
        hook.validate(0, 2, user, user, proof);
        assertFalse(hook.isVerified(0, user));
        assertEq(hook.zkGlobalBidTotal(), 0);
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, 2);
        vm.prank(address(mockCCA));
        hook.validate(0, 2, user, user, proof);
        assertEq(hook.zkBidTotal(user, 0), 2);
    }

    function test_verifyEveryBid_relayerCanSubmitOwnersProof_capsAccrueToOwner() public {
        _verifyEveryBidSetup();
        address relayer = makeAddr("relayer");
        vm.prank(admin);
        hook.setStepMaxBidAmount(0, 10);
        bytes memory proof =
            abi.encodePacked(uint256(0), _createBidProofForAuction(user, PROVIDER_HASH_1, 1, address(mockCCA), 0, 3));
        vm.prank(address(mockCCA));
        hook.validate(0, 3, user, relayer, proof);
        assertEq(hook.zkBidTotal(user, 0), 3);
        assertEq(hook.zkBidTotal(relayer, 0), 0);
        assertFalse(hook.isVerified(0, relayer));
        assertFalse(hook.isVerified(0, user));
    }

    function test_verifyEveryBid_relayerCannotRedirectOwnersProof() public {
        _verifyEveryBidSetup();
        address relayer = makeAddr("relayer");
        bytes memory proof =
            abi.encodePacked(uint256(0), _createBidProofForAuction(user, PROVIDER_HASH_1, 1, address(mockCCA), 0, 3));
        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ContextAddressMismatch.selector, relayer, user));
        hook.validate(0, 3, relayer, relayer, proof);
        // A rejected redirection did not consume the credential.
        vm.prank(address(mockCCA));
        hook.validate(0, 3, user, relayer, proof);
    }

    function test_verifyEveryBid_relayerCannotRedirectOwnersPermitOrChangeAmount() public {
        _verifyEveryBidSetup();
        address relayer = makeAddr("relayer");
        uint256 deadline = block.timestamp + 300;
        bytes32 nonce = keccak256("relayed-permit");
        bytes memory permit = _encodePermitHookData(
            0, nonce, deadline, _signServerPermitWithAmount(address(hook), user, 0, nonce, deadline, 3)
        );
        vm.prank(address(mockCCA));
        vm.expectRevert(HookServerPermits.InvalidSignature.selector);
        hook.validate(0, 3, relayer, relayer, permit);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookServerPermits.InvalidSignature.selector);
        hook.validate(0, 4, user, relayer, permit);
        assertFalse(hook.isPermitNonceUsed(nonce));
        vm.prank(address(mockCCA));
        hook.validate(0, 3, user, relayer, permit);
        assertTrue(hook.isPermitNonceUsed(nonce));
        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(HookServerPermits.PermitAlreadyUsed.selector, nonce));
        hook.validate(0, 3, user, makeAddr("second-relayer"), permit);
    }

    function test_relayerCannotBorrowItsOwnEarlyVerificationForAnotherOwner() public {
        address relayer = makeAddr("relayer");
        _register(hook, relayer, 0, _createProofForUser(relayer));
        vm.roll(step0Start);
        vm.prank(address(mockCCA));
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.ProofRequired.selector, uint256(0)));
        hook.validate(0, 1, user, relayer, "");
    }

    function test_earlyBid_relayedInlineProofRegistersOwnerAndRemainsReusable() public {
        address relayer = makeAddr("relayer");
        vm.roll(step0Start);
        bytes memory proof = abi.encodePacked(uint256(0), _createProofForUser(user));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, relayer, proof);
        assertTrue(hook.isVerified(0, user));
        assertFalse(hook.isVerified(0, relayer));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, relayer, "");
    }

    function test_verifyEveryBid_publicVerifierFrontRunCannotBurnBidProof() public {
        _verifyEveryBidSetup();
        bytes memory proofData = _createBidProof(user, PROVIDER_HASH_1, 1);
        Reclaim.Proof memory proof = abi.decode(proofData, (Reclaim.Proof));
        vm.prank(makeAddr("mempool-observer"));
        reclaim.verifyProof(proof);
        assertTrue(reclaim.usedProofs(proof.signedClaim.claim.identifier));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proofData));
        assertEq(hook.zkGlobalBidTotal(), 1);
        vm.prank(address(mockCCA));
        vm.expectPartialRevert(UmiaValidationHook.ProofAlreadyUsed.selector);
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proofData));
    }

    function test_consumedBidProofCannotRegisterOnceTheStepIsOrdinary() public {
        _verifyEveryBidSetup();
        bytes memory proof = _createBidProof(user, PROVIDER_HASH_1, 99);
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proof));
        vm.prank(admin);
        hook.setVerifyEveryBid(0, false);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.RegistrationProofContextMismatch.selector);
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proof));
        assertFalse(hook.isVerified(0, user));
    }

    function test_verifyEveryBid_permitCannotAuthorizeLaterOrdinaryStep() public {
        UmiaValidationHook h = _deployThreeStepHook();
        vm.startPrank(admin);
        h.setSigner(signerAddress);
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        h.setVerifyEveryBid(0, true);
        h.enableStep(1, _emptyHashes(), _emptyIds());
        h.enableStepPermit(1);
        vm.stopPrank();
        uint256 deadline = block.timestamp + 300;
        bytes32 nonce = keccak256("earlier-bucket-permit");
        bytes memory permit = _encodePermitHookData(
            0, nonce, deadline, _signServerPermitWithAmount(address(h), user, 0, nonce, deadline, 1)
        );
        vm.roll(200);
        vm.prank(h.cca());
        vm.expectRevert(abi.encodeWithSelector(UmiaValidationHook.CredentialStepMismatch.selector, 0, 1));
        h.validate(0, 1, user, user, permit);
        assertFalse(h.isPermitNonceUsed(nonce));
    }

    /// @dev Same literal as `bidProofContextMessage` in @umia/types; change both together.
    function test_verifyEveryBid_contextMessageVector() public {
        vm.chainId(84532);
        BidContextHarness harness = new BidContextHarness();
        address auction = 0x000000000000000000000000000000000000c0DE;
        Reclaim.Proof memory proof;
        proof.signedClaim.claim.timestampS = uint32(block.timestamp);
        proof.claimInfo.context =
        '{"contextMessage":"bid:84532:0x000000000000000000000000000000000000c0de:2:1000:n0nce"}';
        harness.validate(proof, auction, 2, 1000);
        vm.expectRevert(HookProofValidation.BidProofContextMismatch.selector);
        harness.validate(proof, auction, 2, 1001);
    }

    function test_verifyEveryBid_proofCannotAuthorizeALaterOrdinaryStep() public {
        MockCCA cca3 = _deployThreeStepCCA();
        UmiaValidationHook h = _newHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        vm.startPrank(admin);
        h.setCCA(address(cca3));
        h.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.enableStep(1, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        h.setVerifyEveryBid(0, true);
        vm.stopPrank();
        bytes memory stepZeroBidProof =
            abi.encodePacked(uint256(0), _createBidProofForAuction(user, PROVIDER_HASH_1, 7, address(cca3), 0, 1));

        vm.roll(200);
        vm.prank(address(cca3));
        vm.expectRevert(
            abi.encodeWithSelector(UmiaValidationHook.CredentialStepMismatch.selector, uint256(0), uint256(1))
        );
        h.validate(0, 1, user, user, stepZeroBidProof);
        assertEq(h.zkBidTotal(user, 1), 0);

        // The ordinary step still registers with its own proof.
        vm.prank(address(cca3));
        h.validate(
            0,
            1,
            user,
            user,
            abi.encodePacked(
                uint256(1), _createProofForUserWithProviderAndAuction(user, PROVIDER_HASH_1, address(cca3))
            )
        );
        assertTrue(h.isVerified(1, user));
    }

    function test_verifyEveryBid_rejectsProofForOtherAuctionOrStep() public {
        _verifyEveryBidSetup();
        bytes memory otherAuction = _createBidProofForAuction(user, PROVIDER_HASH_1, 1, address(123), 0, 1);
        bytes memory otherStep = _createBidProofForAuction(user, PROVIDER_HASH_1, 1, address(mockCCA), 1, 1);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofContextMismatch.selector);
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), otherAuction));
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofContextMismatch.selector);
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), otherStep));
    }

    function test_verifyEveryBid_rejectsProofForOtherChainOrWithoutBidContext() public {
        _verifyEveryBidSetup();
        bytes memory proofData = _createBidProof(user, PROVIDER_HASH_1, 1);
        vm.chainId(block.chainid + 1);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofContextMismatch.selector);
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proofData));
        bytes memory earlyProof = _createProofForUser(user);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofContextMismatch.selector);
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), earlyProof));
    }

    function test_verifyEveryBid_cannotForgeProofEvenAfterPublicVerification() public {
        _verifyEveryBidSetup();
        bytes memory proofData = _createBidProof(user, PROVIDER_HASH_1, 1);
        Reclaim.Proof memory proof = abi.decode(proofData, (Reclaim.Proof));
        reclaim.verifyProof(proof);
        // Even a consumed identifier must have valid signatures on the supplied payload.
        proof.signedClaim.signatures[0] = new bytes(65);
        vm.prank(address(mockCCA));
        vm.expectRevert();
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), abi.encode(proof)));
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proofData));
    }

    function test_earlyBid_publicVerifierFrontRunCannotBlockBid() public {
        bytes memory proofData = _createProofForUser(user);
        Reclaim.Proof memory proof = abi.decode(proofData, (Reclaim.Proof));
        vm.prank(makeAddr("mempool-observer"));
        reclaim.verifyProof(proof);
        vm.roll(step0Start);
        vm.prank(address(mockCCA));
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proofData));
        assertTrue(hook.isVerified(0, user));
        assertEq(hook.zkGlobalBidTotal(), 1);
    }

    function test_verifyEveryBid_observerCannotConsumeProofWithDustBid() public {
        _verifyEveryBidSetup();
        bytes memory proofData = _createBidProofForAuction(user, PROVIDER_HASH_1, 1, address(mockCCA), 0, 100);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofContextMismatch.selector);
        hook.validate(0, 1, user, makeAddr("mempool-observer"), abi.encodePacked(uint256(0), proofData));
        vm.prank(address(mockCCA));
        hook.validate(0, 100, user, makeAddr("legitimate-relayer"), abi.encodePacked(uint256(0), proofData));
        assertEq(hook.zkGlobalBidTotal(), 100);
    }
}
