// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibString} from "@solady/utils/LibString.sol";
import {JSONParserLib} from "@solady/utils/JSONParserLib.sol";
import {Claims} from "../../src/zktls/Claims.sol";
import {ZkTlsVerifier} from "../../src/zktls/ZkTlsVerifier.sol";
import {UmiaValidationHookBase} from "./UmiaValidationHookBase.t.sol";

contract HookProofSecurityTest is UmiaValidationHookBase {
    function test_registrationRejectsNestedDuplicateProviderHash() public {
        _expectDecoyRejection(
            string(abi.encodePacked('"providerHash":"', _bytes32ToHexString(PROVIDER_HASH_1), '"')),
            "Duplicate context key"
        );
    }

    function test_registrationRejectsNestedDuplicateExtractedParameters() public {
        _expectDecoyRejection('"extractedParameters":{"account":"attacker"}', "Duplicate context key");
    }

    function test_registrationRejectsNestedDuplicateIdentityProvider() public {
        _expectDecoyRejection('"identityProvider":"test-provider"', "Duplicate context key");
    }

    function test_registrationRejectsStaleEpoch() public {
        bytes memory proof = _createProofForUser(user);
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness({addr: vm.addr(2), host: "wss://new.example.com"});
        zktlsVerifier.addNewEpoch(witnesses, 1);
        _expectRegistrationRejection(proof, "Stale epoch");
    }

    function test_registrationRejectsZeroEpoch() public {
        ZkTlsVerifier.Proof memory proof = abi.decode(_createProofForUser(user), (ZkTlsVerifier.Proof));
        proof.signedClaim.claim.epoch = 0;
        _signProof(proof);
        _expectRegistrationRejection(abi.encode(proof), "Stale epoch");
    }

    function test_registrationRejectsTruncatedProviderHashAlias() public {
        _expectMalformedFieldRejection(
            "providerHash",
            _bytes32ToHexString(PROVIDER_HASH_1),
            string.concat(_bytes32ToHexString(PROVIDER_HASH_1), "ff"),
            abi.encodeWithSignature("Error(string)", "Invalid context hex length")
        );
    }

    function test_registrationRejectsOverlongAddressAlias() public {
        // A superfluous leading zero must not create an alternate-width address.
        string memory value = _addressToString(user);
        _expectMalformedFieldRejection(
            "contextAddress",
            value,
            string.concat("0x0", LibString.slice(value, 2)),
            abi.encodeWithSignature("Error(string)", "Invalid context hex length")
        );
    }

    function test_registrationRejectsNonHexProviderHash() public {
        string memory value = _bytes32ToHexString(PROVIDER_HASH_1);
        _expectMalformedFieldRejection(
            "providerHash",
            value,
            string.concat(LibString.slice(value, 0, 65), "g"),
            abi.encodePacked(JSONParserLib.ParsingFailed.selector)
        );
    }

    function _expectMalformedFieldRejection(
        string memory field,
        string memory original,
        string memory malformed,
        bytes memory revertData
    ) private {
        ZkTlsVerifier.Proof memory proof = abi.decode(_createProofForUser(user), (ZkTlsVerifier.Proof));
        proof.claimInfo.context = LibString.replace(
            proof.claimInfo.context,
            string.concat('"', field, '":"', original, '"'),
            string.concat('"', field, '":"', malformed, '"')
        );
        assertNotEq(Claims.hashClaimInfo(proof.claimInfo), proof.signedClaim.claim.identifier);
        proof.signedClaim.claim.identifier = Claims.hashClaimInfo(proof.claimInfo);
        _signProof(proof);
        vm.roll(hook.getSteps()[0].startBlock);
        vm.prank(address(mockCCA));
        vm.expectRevert(revertData);
        hook.validate(0, 0, user, user, abi.encodePacked(uint256(0), abi.encode(proof)));
        assertFalse(hook.isVerified(0, user));
    }

    function _expectDecoyRejection(string memory decoy, string memory reason) private {
        ZkTlsVerifier.Proof memory proof = abi.decode(_createProofForUser(user), (ZkTlsVerifier.Proof));
        // Keep a fully signed, otherwise valid registration proof; prepend the attacker's nested fields.
        proof.claimInfo.context = string.concat('{"a":{', decoy, "},", _withoutOpeningBrace(proof.claimInfo.context));
        proof.signedClaim.claim.identifier = Claims.hashClaimInfo(proof.claimInfo);
        _signProof(proof);
        _expectRegistrationRejection(abi.encode(proof), reason);
    }

    function _expectRegistrationRejection(bytes memory proof, string memory reason) private {
        vm.roll(hook.getSteps()[0].startBlock);
        vm.prank(address(mockCCA));
        vm.expectRevert(bytes(reason));
        hook.validate(0, 0, user, user, abi.encodePacked(uint256(0), proof));
        assertFalse(hook.isVerified(0, user));
    }

    function _signProof(ZkTlsVerifier.Proof memory proof) private view {
        bytes memory serialised = Claims.serialise(proof.signedClaim.claim);
        bytes32 messageHash =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", _uint2str(serialised.length), serialised));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WITNESS_PRIVATE_KEY, messageHash);
        proof.signedClaim.signatures[0] = abi.encodePacked(r, s, v);
    }

    function _withoutOpeningBrace(string memory context) private pure returns (string memory) {
        bytes memory original = bytes(context);
        bytes memory tail = new bytes(original.length - 1);
        for (uint256 i = 1; i < original.length; ++i) {
            tail[i - 1] = original[i];
        }
        return string(tail);
    }
}
