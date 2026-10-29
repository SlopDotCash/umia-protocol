// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ZkTlsVerifier} from "../../src/zktls/ZkTlsVerifier.sol";
import {Claims} from "../../src/zktls/Claims.sol";
import {ZkTlsContext} from "../../src/zktls/ZkTlsContext.sol";
import {LegacyReclaimFormatting} from "./LegacyReclaimFormatting.sol";

/// @dev Exposes signature and epoch authentication for proofs whose context is not Umia JSON.
contract ZkTlsVerifierHarness is ZkTlsVerifier {
    constructor(Witness[] memory witnesses, uint8 minWitnesses) ZkTlsVerifier(witnesses, minWitnesses) {}

    function authenticate(Proof memory proof) external view {
        _verifyProof(proof);
    }
}

contract ZkTlsVerifierTest is Test {
    ZkTlsVerifierHarness public zktlsVerifier;

    uint256 constant WITNESS_PRIVATE_KEY = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    address witnessAddress;

    function setUp() public {
        witnessAddress = vm.addr(WITNESS_PRIVATE_KEY);
        zktlsVerifier = new ZkTlsVerifierHarness(_witnesses(witnessAddress), 1);
    }

    function test_InitialOwnerIsDeployer() public view {
        assertEq(zktlsVerifier.owner(), address(this));
    }

    function test_TransferOwnership() public {
        address multisig = makeAddr("multisig");
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: witnessAddress, host: "wss://test.example.com"});

        vm.expectEmit(true, true, false, true, address(zktlsVerifier));
        emit Ownable.OwnershipTransferred(address(this), multisig);
        zktlsVerifier.transferOwnership(multisig);
        assertEq(zktlsVerifier.owner(), multisig);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        zktlsVerifier.addNewEpoch(witnesses, 1);

        vm.prank(multisig);
        zktlsVerifier.addNewEpoch(witnesses, 1);
        assertEq(zktlsVerifier.currentEpoch(), 2);
        assertEq(zktlsVerifier.fetchEpoch(2).witnesses[0].addr, witnessAddress);
    }

    function test_TransferOwnership_RevertsUnauthorized() public {
        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        zktlsVerifier.transferOwnership(makeAddr("multisig"));
        assertEq(zktlsVerifier.owner(), address(this));
    }

    function test_TransferOwnership_RevertsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        zktlsVerifier.transferOwnership(address(0));
        assertEq(zktlsVerifier.owner(), address(this));
    }

    function test_InitialEpochSetup() public view {
        // Check that epoch 1 exists after deployment
        assertEq(zktlsVerifier.currentEpoch(), 1);

        ZkTlsVerifier.Epoch memory epoch = zktlsVerifier.fetchEpoch(1);
        assertEq(epoch.id, 1);
        assertEq(epoch.minimumWitnessesForClaimCreation, 1);
        assertEq(epoch.witnesses.length, 1);
        assertEq(epoch.witnesses[0].addr, witnessAddress);
        assertEq(epoch.witnesses[0].host, "wss://test.example.com");
    }

    function test_FetchEpochZeroReverts() public {
        vm.expectRevert("Unknown epoch");
        zktlsVerifier.fetchEpoch(0);
    }

    function test_AddNewEpoch() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](2);
        witnesses[0] = ZkTlsVerifier.Witness({addr: address(0x1), host: "wss://witness1.example.com"});
        witnesses[1] = ZkTlsVerifier.Witness({addr: address(0x2), host: "wss://witness2.example.com"});

        zktlsVerifier.addNewEpoch(witnesses, 2);

        assertEq(zktlsVerifier.currentEpoch(), 2);

        ZkTlsVerifier.Epoch memory epoch = zktlsVerifier.fetchEpoch(2);
        assertEq(epoch.id, 2);
        assertEq(epoch.minimumWitnessesForClaimCreation, 2);
        assertEq(epoch.witnesses.length, 2);
    }

    function test_AddNewEpoch_RevertsTooManyRequiredWitnesses() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.expectRevert("Invalid requisite witnesses count");
        zktlsVerifier.addNewEpoch(witnesses, 2);
    }

    function test_AddNewEpoch_RevertsZeroWitnesses() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](0);

        vm.expectRevert("No witnesses provided");
        zktlsVerifier.addNewEpoch(witnesses, 0);
    }

    function test_AddNewEpoch_RevertsZeroRequiredWitnesses() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.expectRevert("Invalid requisite witnesses count");
        zktlsVerifier.addNewEpoch(witnesses, 0);
    }

    function test_AddNewEpochOnlyOwner() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xdead)));
        zktlsVerifier.addNewEpoch(witnesses, 1);
    }

    function test_AddNewEpochEndsCurrentEpoch() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: address(0x1), host: "wss://witness1.example.com"});

        vm.warp(block.timestamp + 1 hours);
        zktlsVerifier.addNewEpoch(witnesses, 1);

        ZkTlsVerifier.Epoch memory epoch1 = zktlsVerifier.fetchEpoch(1);
        assertEq(epoch1.timestampEnd, uint32(block.timestamp));
    }

    function test_FetchWitnessesForClaim() public view {
        ZkTlsVerifier.Witness[] memory witnesses =
            zktlsVerifier.fetchWitnessesForClaim(1, bytes32(uint256(123)), uint32(block.timestamp));

        assertEq(witnesses.length, 1);
        assertEq(witnesses[0].addr, witnessAddress);
    }

    function test_VerifyProofWithValidSignature() public {
        // Setup: Add epoch with our test witness
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: witnessAddress, host: "wss://test.example.com"});
        zktlsVerifier.addNewEpoch(witnesses, 1);

        // Create claim info
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: "test-context"});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        // Create complete claim data
        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: address(this), timestampS: uint32(block.timestamp), epoch: 2
        });

        // Sign the claim
        bytes memory serialised = abi.encodePacked(
            LegacyReclaimFormatting.bytes2str(abi.encodePacked(claimData.identifier)),
            "\n",
            LegacyReclaimFormatting.address2str(claimData.owner),
            "\n",
            LegacyReclaimFormatting.uint2str(claimData.timestampS),
            "\n",
            LegacyReclaimFormatting.uint2str(claimData.epoch)
        );

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n", LegacyReclaimFormatting.uint2str(serialised.length), serialised
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WITNESS_PRIVATE_KEY, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        ZkTlsVerifier.Proof memory proof = ZkTlsVerifier.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        // This should not revert
        zktlsVerifier.authenticate(proof);
    }

    function test_VerifyProofRevertNoSignatures() public {
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: "test-context"});

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: Claims.hashClaimInfo(claimInfo),
            owner: address(this),
            timestampS: uint32(block.timestamp),
            epoch: 1
        });

        bytes[] memory signatures = new bytes[](0);

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        ZkTlsVerifier.Proof memory proof = ZkTlsVerifier.Proof({claimInfo: claimInfo, signedClaim: signedClaim});
    }

    function test_VerifyRealWorldProof() public {
        // Real-world proof from ZkTlsVerifier Protocol
        Claims.ClaimInfo memory claimInfo = Claims.ClaimInfo({
            provider: "http",
            parameters: '{"body":"","geoLocation":"in","method":"GET","paramValues":{"CLAIM_DATA":"76561199632643233"},"responseMatches":[{"type":"contains","value":"_steamid\\">Steam ID: {{CLAIM_DATA}}</div>"}],"responseRedactions":[{"jsonPath":"","regex":"_steamid\\">Steam\\\\ ID:\\\\ (.*)</div>","xPath":"id(\\"responsive_page_template_content\\")/div[@class=\\"page_header_ctn\\"]/div[@class=\\"page_content\\"]/div[@class=\\"youraccount_steamid\\"]"}],"url":"https://store.steampowered.com/account/"}',
            context: '{"contextAddress":"user\'s address","contextMessage":"for acmecorp.com on 1st january","extractedParameters":{"CLAIM_DATA":"76561199632643233"},"providerHash":"0x61433e76ff18460b8307a7e4236422ac66c510f0f9faff2892635c12b7c1076e"}'
        });

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: 0x0ae1908b6ea3e2729c930391e2e8e08708f2e04073f000a6c92e4f73bc958e27,
            owner: 0x0D0cC50d2c4DcD65A000304D2Dbdd103C2F37B63,
            timestampS: 1721386619,
            epoch: 1
        });

        bytes[] memory signatures = new bytes[](1);
        signatures[0] =
            hex"2a647de47e8827c54d1078b27341a2838e422e96090aa2bbacffc3d3dee686cc480d05471e03a1f4628546e03b697ae8193d5c91b91e1167ee92082c73d605741c";

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        ZkTlsVerifier.Proof memory proof = ZkTlsVerifier.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        // Verify the identifier matches the hash of claimInfo
        bytes32 expectedIdentifier = Claims.hashClaimInfo(claimInfo);
        assertEq(claimData.identifier, expectedIdentifier, "Identifier should match hash of claimInfo");

        // A fresh beacon does not implicitly trust ZkTlsVerifier's public attestor.

        // The historical fixture remains verifiable when its witness is explicitly configured.
        ZkTlsVerifierHarness historicalBeacon =
            new ZkTlsVerifierHarness(_witnesses(0x244897572368Eadf65bfBc5aec98D8e5443a9072), 1);
        historicalBeacon.authenticate(proof);
    }

    function test_VerifyProofRevertIdentifierMismatch() public {
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: "test-context"});

        // Use wrong identifier
        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: bytes32(uint256(123)), // Wrong identifier
            owner: address(this),
            timestampS: uint32(block.timestamp),
            epoch: 1
        });

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = new bytes(65);

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        ZkTlsVerifier.Proof memory proof = ZkTlsVerifier.Proof({claimInfo: claimInfo, signedClaim: signedClaim});
    }

    function test_ConstructorUsesAllProvidedWitnesses() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](2);
        witnesses[0] = ZkTlsVerifier.Witness({addr: witnessAddress, host: "wss://first.example.com"});
        witnesses[1] = ZkTlsVerifier.Witness({addr: address(2), host: "wss://second.example.com"});
        ZkTlsVerifier beacon = new ZkTlsVerifier(witnesses, 2);
        ZkTlsVerifier.Epoch memory epoch = beacon.fetchEpoch(1);
        assertEq(epoch.minimumWitnessesForClaimCreation, 2);
        assertEq(epoch.witnesses.length, 2);
        for (uint256 i; i < witnesses.length; ++i) {
            assertEq(epoch.witnesses[i].addr, witnesses[i].addr);
            assertEq(epoch.witnesses[i].host, witnesses[i].host);
        }
    }

    function test_ConstructorRejectsEmptyWitnesses() public {
        vm.expectRevert("No witnesses provided");
        new ZkTlsVerifier(new ZkTlsVerifier.Witness[](0), 0);
    }

    function test_ConstructorRejectsInvalidThreshold() public {
        ZkTlsVerifier.Witness[] memory witnesses = _witnesses(witnessAddress);
        vm.expectRevert("Invalid requisite witnesses count");
        new ZkTlsVerifier(witnesses, 0);
        vm.expectRevert("Invalid requisite witnesses count");
        new ZkTlsVerifier(witnesses, 2);
    }

    function test_RotationRejectsOldEpoch() public {
        ZkTlsVerifier.Proof memory proof = _signedProof(1, WITNESS_PRIVATE_KEY);
        zktlsVerifier.validateProof(proof);

        zktlsVerifier.addNewEpoch(_witnesses(vm.addr(2)), 1);
        vm.expectRevert("Stale epoch");
        zktlsVerifier.validateProof(proof);

        proof = _signedProof(2, 2);
        zktlsVerifier.validateProof(proof);
    }

    function test_ZeroEpochRejected() public {
        ZkTlsVerifier.Proof memory proof = _signedProof(0, WITNESS_PRIVATE_KEY);
        vm.expectRevert("Stale epoch");
        zktlsVerifier.validateProof(proof);
    }

    function test_FutureEpochRejected() public {
        ZkTlsVerifier.Proof memory proof = _signedProof(2, WITNESS_PRIVATE_KEY);
        vm.expectRevert("Stale epoch");
        zktlsVerifier.validateProof(proof);
    }

    function test_ViewVerificationIsReadOnlyAndRepeatable() public {
        ZkTlsVerifier.Proof memory proof = _signedProof(1, WITNESS_PRIVATE_KEY);
        vm.recordLogs();
        zktlsVerifier.validateProof(proof);
        zktlsVerifier.validateProof(proof);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_ViewRejectsTamperedClaimInfo() public {
        ZkTlsVerifier.Proof memory proof = _signedProof(1, WITNESS_PRIVATE_KEY);
        proof.claimInfo.context = '{"contextAddress":"forged"}';
        vm.expectRevert("Claim identifier mismatch");
        zktlsVerifier.validateProof(proof);
    }

    function test_ViewRejectsUntrustedWitnessAndMissingSignatures() public {
        ZkTlsVerifier.Proof memory proof = _signedProof(1, 2);
        vm.expectRevert("Signature not appropriate");
        zktlsVerifier.validateProof(proof);
        proof.signedClaim.signatures = new bytes[](0);
        vm.expectRevert("No signatures");
        zktlsVerifier.validateProof(proof);
    }

    function test_ViewReturnsAuthenticatedContext() public {
        ZkTlsVerifier.Proof memory proof = _signedContextProof(
            '{"contextAddress":"0x00000000000000000000000000000000000000aA","providerHash":"0x00000000000000000000000000000000000000000000000000000000000000bb","identityProvider":"github","contextMessage":"domain","extractedParameters": { "account": "alice" }}'
        );
        ZkTlsContext.Context memory context = zktlsVerifier.validateProof(proof);
        assertEq(context.contextAddress, address(0xaa));
        assertEq(context.providerHash, bytes32(uint256(0xbb)));
        assertEq(context.identityProvider, "github");
        assertEq(context.contextMessage, "domain");
        assertEq(string(context.extractedParameters), '{ "account": "alice" }');
    }

    function test_ViewRejectsSignedDuplicateContext() public {
        ZkTlsVerifier.Proof memory proof = _signedContextProof('{"providerHash":"real","providerHash":"decoy"}');
        vm.expectRevert("Duplicate context key");
        zktlsVerifier.validateProof(proof);
    }

    function test_RequiresDistinctCompleteWitnessSet() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](2);
        witnesses[0] = ZkTlsVerifier.Witness(witnessAddress, "wss://first.example.com");
        witnesses[1] = ZkTlsVerifier.Witness(vm.addr(2), "wss://second.example.com");
        zktlsVerifier.addNewEpoch(witnesses, 2);
        ZkTlsVerifier.Proof memory proof = _signedProof(2, WITNESS_PRIVATE_KEY);
        bytes memory firstSignature = proof.signedClaim.signatures[0];
        vm.expectRevert("Number of signatures not equal to number of witnesses");
        zktlsVerifier.validateProof(proof);

        proof.signedClaim.signatures = new bytes[](2);
        proof.signedClaim.signatures[0] = firstSignature;
        proof.signedClaim.signatures[1] = firstSignature;
        vm.expectRevert("Duplicated Signatures Found");
        zktlsVerifier.validateProof(proof);

        proof.signedClaim.signatures[1] = _signedProof(2, 3).signedClaim.signatures[0];
        vm.expectRevert("Signature not appropriate");
        zktlsVerifier.validateProof(proof);

        proof.signedClaim.signatures[1] = _signedProof(2, 2).signedClaim.signatures[0];
        zktlsVerifier.validateProof(proof);
    }

    function _signedContextProof(string memory context) private view returns (ZkTlsVerifier.Proof memory proof) {
        proof = _signedProof(1, WITNESS_PRIVATE_KEY);
        proof.claimInfo.context = context;
        proof.signedClaim.claim.identifier = Claims.hashClaimInfo(proof.claimInfo);
        bytes memory serialised = Claims.serialise(proof.signedClaim.claim);
        bytes32 hash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n", LegacyReclaimFormatting.uint2str(serialised.length), serialised
            )
        );
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(WITNESS_PRIVATE_KEY, hash);
        proof.signedClaim.signatures[0] = abi.encodePacked(r, sigS, v);
    }

    function testFuzz_WitnessSelectionPreservesLegacySeed(bytes32 identifier, uint32 timestamp) public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](5);
        for (uint256 i; i < witnesses.length; ++i) {
            witnesses[i] = ZkTlsVerifier.Witness(address(uint160(i + 1)), "wss://test.example.com");
        }
        zktlsVerifier.addNewEpoch(witnesses, 3);
        bytes32 seed = keccak256(
            abi.encodePacked(
                LegacyReclaimFormatting.bytes2str(abi.encodePacked(identifier)),
                "\n2\n3\n",
                LegacyReclaimFormatting.uint2str(timestamp)
            )
        );
        ZkTlsVerifier.Witness[] memory selected = zktlsVerifier.fetchWitnessesForClaim(2, identifier, timestamp);
        uint256 remaining = witnesses.length;
        for (uint256 i; i < selected.length; ++i) {
            uint256 index = uint32(bytes4(seed << (i * 32))) % remaining;
            assertEq(selected[i].addr, witnesses[index].addr);
            witnesses[index] = witnesses[--remaining];
        }
    }

    function _witnesses(address witness) private pure returns (ZkTlsVerifier.Witness[] memory witnesses) {
        witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: witness, host: "wss://test.example.com"});
    }

    function _signedProof(uint32 epoch, uint256 key) private view returns (ZkTlsVerifier.Proof memory proof) {
        proof.claimInfo = Claims.ClaimInfo({
            provider: "test-provider",
            parameters: "test-params",
            context: '{"contextAddress":"0x00000000000000000000000000000000000000aa","providerHash":"0x00000000000000000000000000000000000000000000000000000000000000bb"}'
        });
        proof.signedClaim.claim = Claims.CompleteClaimData({
            identifier: Claims.hashClaimInfo(proof.claimInfo),
            owner: address(this),
            timestampS: uint32(block.timestamp),
            epoch: epoch
        });
        bytes memory serialised = Claims.serialise(proof.signedClaim.claim);
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n", LegacyReclaimFormatting.uint2str(serialised.length), serialised
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, messageHash);
        proof.signedClaim.signatures = new bytes[](1);
        proof.signedClaim.signatures[0] = abi.encodePacked(r, s, v);
    }
}
