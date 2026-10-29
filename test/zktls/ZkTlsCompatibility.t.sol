// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZkTlsVerifier} from "../../src/zktls/ZkTlsVerifier.sol";
import {Claims} from "../../src/zktls/Claims.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";

// Independent wire schema from the pre-rename Reclaim ABI. Namespaces are not encoded.
interface LegacyReclaimWire {
    struct ClaimInfo {
        string provider;
        string parameters;
        string context;
    }

    struct Claim {
        bytes32 identifier;
        address owner;
        uint32 timestampS;
        uint32 epoch;
    }

    struct SignedClaim {
        Claim claim;
        bytes[] signatures;
    }

    struct Proof {
        ClaimInfo claimInfo;
        SignedClaim signedClaim;
    }

    function validateProof(Proof memory proof) external view;
}

contract ZkTlsCompatibilityTest is Test {
    function testFuzz_ProofWireAndSelectorsUnchanged(
        bytes32 identifier,
        address owner,
        uint32 timestamp,
        uint32 epoch,
        bytes memory signature,
        string memory context
    ) public pure {
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;
        LegacyReclaimWire.Proof memory oldProof = LegacyReclaimWire.Proof(
            LegacyReclaimWire.ClaimInfo("http", "signed parameters", context),
            LegacyReclaimWire.SignedClaim(LegacyReclaimWire.Claim(identifier, owner, timestamp, epoch), signatures)
        );
        ZkTlsVerifier.Proof memory proof = ZkTlsVerifier.Proof(
            Claims.ClaimInfo("http", "signed parameters", context),
            Claims.SignedClaim(Claims.CompleteClaimData(identifier, owner, timestamp, epoch), signatures)
        );
        assertEq(abi.encode(proof), abi.encode(oldProof));
        assertEq(
            abi.encodeCall(ZkTlsVerifier.validateProof, (proof)),
            abi.encodeCall(LegacyReclaimWire.validateProof, (oldProof))
        );
    }

    function test_NewGetterBindsTheConstructorVerifier() public {
        ZkTlsVerifier.Witness[] memory witnesses = new ZkTlsVerifier.Witness[](1);
        witnesses[0] = ZkTlsVerifier.Witness(address(1), "wss://approved.example");
        ZkTlsVerifier verifier = new ZkTlsVerifier(witnesses, 1);
        UmiaValidationHook hook = new UmiaValidationHook(address(this), address(verifier), address(2));
        assertEq(address(hook.zktlsVerifier()), address(verifier));
        assertTrue(bytes4(keccak256("zktlsVerifier()")) != bytes4(keccak256("reclaim()")));
        (bool legacyGetterExists,) = address(hook).staticcall(abi.encodeWithSignature("reclaim()"));
        assertFalse(legacyGetterExists);
    }
}
