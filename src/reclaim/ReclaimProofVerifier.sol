// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Reclaim} from "./Reclaim.sol";
import {Claims} from "./Claims.sol";

/// @notice Stateless verification against a Reclaim beacon, including already deployed beacons.
/// @dev Mirrors `Reclaim.verifyProof` without writing its public replay registry, so a public
///      verification call cannot invalidate a pending consumer transaction. Consumers must
///      enforce their own domain binding and replay protection.
library ReclaimProofVerifier {
    function verifyProof(Reclaim beacon, Reclaim.Proof memory proof) internal view {
        require(proof.signedClaim.signatures.length > 0, "No signatures");
        Claims.SignedClaim memory signed = Claims.SignedClaim(proof.signedClaim.claim, proof.signedClaim.signatures);

        bytes32 hashed = Claims.hashClaimInfo(proof.claimInfo);
        require(proof.signedClaim.claim.identifier == hashed, "Claim identifier mismatch");

        Reclaim.Witness[] memory expectedWitnesses = beacon.fetchWitnessesForClaim(
            proof.signedClaim.claim.epoch, proof.signedClaim.claim.identifier, proof.signedClaim.claim.timestampS
        );
        address[] memory signedWitnesses = Claims.recoverSignersOfSignedClaim(signed);

        require(
            signedWitnesses.length == expectedWitnesses.length, "Number of signatures not equal to number of witnesses"
        );

        for (uint256 i = 0; i < signedWitnesses.length; i++) {
            for (uint256 j = 0; j < signedWitnesses.length; j++) {
                if (i == j) continue;
                require(signedWitnesses[i] != signedWitnesses[j], "Duplicated Signatures Found");
            }
        }

        for (uint256 i = 0; i < signed.signatures.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < expectedWitnesses.length; j++) {
                if (signedWitnesses[i] == expectedWitnesses[j].addr) {
                    found = true;
                    break;
                }
            }
            require(found, "Signature not appropriate");
        }
    }
}
