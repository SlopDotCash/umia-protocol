// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {LibString} from "@solady/utils/LibString.sol";

/**
 * Library to assist with requesting,
 * serialising & verifying credentials
 */
library Claims {
    /**
     * Data required to describe a claim
     */
    struct CompleteClaimData {
        bytes32 identifier;
        address owner;
        uint32 timestampS;
        uint32 epoch;
    }

    struct ClaimInfo {
        string provider;
        string parameters;
        string context;
    }

    /**
     * Claim with signatures & signer
     */
    struct SignedClaim {
        CompleteClaimData claim;
        bytes[] signatures;
    }

    /**
     * @dev recovers the signer of the claim
     */
    function recoverSignersOfSignedClaim(SignedClaim memory self) internal pure returns (address[] memory) {
        bytes memory serialised = serialise(self.claim);
        address[] memory signers = new address[](self.signatures.length);
        for (uint256 i = 0; i < self.signatures.length; i++) {
            signers[i] = verifySignature(serialised, self.signatures[i]);
        }

        return signers;
    }

    /**
     * @dev serialises the credential into a string;
     * the string is used to verify the signature
     *
     * the serialisation is the same as done by the TS library
     */
    function serialise(CompleteClaimData memory self) internal pure returns (bytes memory) {
        return abi.encodePacked(
            LibString.toHexString(uint256(self.identifier), 32),
            "\n",
            LibString.toHexString(self.owner),
            "\n",
            LibString.toString(uint256(self.timestampS)),
            "\n",
            LibString.toString(uint256(self.epoch))
        );
    }

    /**
     * @dev returns the address of the user that generated the signature
     */
    function verifySignature(bytes memory content, bytes memory signature) internal pure returns (address signer) {
        bytes32 signedHash = MessageHashUtils.toEthSignedMessageHash(content);
        return ECDSA.recover(signedHash, signature);
    }

    function hashClaimInfo(ClaimInfo memory claimInfo) internal pure returns (bytes32) {
        bytes memory serialised =
            abi.encodePacked(claimInfo.provider, "\n", claimInfo.parameters, "\n", claimInfo.context);
        return keccak256(serialised);
    }
}
