// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./Claims.sol";
import {ZkTlsContext} from "./ZkTlsContext.sol";
import {LibSort} from "@solady/utils/LibSort.sol";
import {LibString} from "@solady/utils/LibString.sol";
import "./BytesUtils.sol";

/**
 * Umia zkTLS verifier, derived from the MIT-licensed Reclaim Protocol beacon.
 */
contract ZkTlsVerifier is Ownable {
    struct Witness {
        /**
         * ETH address of the witness
         */
        address addr;
        /**
         * Host to connect to the witness
         */
        string host;
    }

    struct Epoch {
        /**
         * Epoch number
         */
        uint32 id;
        /**
         * when the epoch changed
         */
        uint32 timestampStart;
        /**
         * when the epoch will change
         */
        uint32 timestampEnd;
        /**
         * Witnesses for this epoch
         */
        Witness[] witnesses;
        /**
         * Minimum number of witnesses
         * required to create a claim
         *
         */
        uint8 minimumWitnessesForClaimCreation;
    }

    struct Proof {
        Claims.ClaimInfo claimInfo;
        Claims.SignedClaim signedClaim;
    }

    /**
     * list of all epochs
     */
    Epoch[] public epochs;

    /**
     * duration of each epoch.
     * is not a hard duration, but useful for
     * caching purposes
     *
     */
    uint32 public epochDurationS;

    /**
     * current epoch.
     * starts at 1, so that the first epoch is 1
     *
     */
    uint32 public currentEpoch;

    event EpochAdded(Epoch epoch);

    /**
     * Constructor to initialize the ZkTlsVerifier contract
     * @notice Sets the deployer as the initial owner, who can transfer ownership to a multisig.
     * @param initialWitnesses The explicitly trusted witness set for epoch 1.
     * @param minWitnesses Number of witness signatures required per claim.
     */
    constructor(Witness[] memory initialWitnesses, uint8 minWitnesses) Ownable(msg.sender) {
        epochDurationS = 1 days;
        _addNewEpoch(initialWitnesses, minWitnesses);
    }

    // epoch functions ---

    /**
     * Fetch an epoch
     * @param epoch the epoch number to fetch, from 1
     */
    function fetchEpoch(uint32 epoch) public view returns (Epoch memory) {
        require(epoch != 0, "Unknown epoch");
        return epochs[epoch - 1];
    }

    /**
     * Get the witnesses that'll sign the claim
     */
    function fetchWitnessesForClaim(uint32 epoch, bytes32 identifier, uint32 timestampS)
        public
        view
        returns (Witness[] memory)
    {
        Epoch memory epochData = fetchEpoch(epoch);
        bytes memory completeInput = abi.encodePacked(
            LibString.toHexString(uint256(identifier), 32),
            "\n",
            LibString.toString(uint256(epoch)),
            "\n",
            LibString.toString(uint256(epochData.minimumWitnessesForClaimCreation)),
            "\n",
            LibString.toString(uint256(timestampS))
        );
        bytes memory completeHash = abi.encodePacked(keccak256(completeInput));

        Witness[] memory witnessesLeftList = epochData.witnesses;
        Witness[] memory selectedWitnesses = new Witness[](epochData.minimumWitnessesForClaimCreation);
        uint256 witnessesLeft = witnessesLeftList.length;

        uint256 byteOffset = 0;
        for (uint32 i = 0; i < epochData.minimumWitnessesForClaimCreation; i++) {
            uint256 randomSeed = BytesUtils.bytesToUInt(completeHash, byteOffset);
            uint256 witnessIndex = randomSeed % witnessesLeft;
            selectedWitnesses[i] = witnessesLeftList[witnessIndex];
            // remove the witness from the list of witnesses
            // we've utilised witness at index "idx"
            // we of course don't want to pick the same witness twice
            // so we remove it from the list of witnesses
            // and reduce the number of witnesses left to pick from
            // since solidity doesn't support "pop()" in memory arrays
            // we swap the last element with the element we want to remove
            witnessesLeftList[witnessIndex] = epochData.witnesses[witnessesLeft - 1];
            byteOffset = (byteOffset + 4) % completeHash.length;
            witnessesLeft -= 1;
        }

        return selectedWitnesses;
    }

    /// @notice Verifies a current-epoch proof and returns its parsed context.
    /// @dev Stateless: consumers enforce their own domain binding and replay policy, so
    ///      permissionless verification cannot burn a credential.
    function validateProof(Proof memory proof) external view returns (ZkTlsContext.Context memory) {
        _verifyProof(proof);
        return ZkTlsContext.parse(proof.claimInfo.context);
    }

    function _verifyProof(Proof memory proof) internal view {
        require(proof.signedClaim.signatures.length > 0, "No signatures");

        // check if the hash from the claimInfo is equal to the infoHash in the claimData
        bytes32 hashed = Claims.hashClaimInfo(proof.claimInfo);
        require(proof.signedClaim.claim.identifier == hashed, "Claim identifier mismatch");

        require(proof.signedClaim.claim.epoch == currentEpoch, "Stale epoch");

        // fetch witness list from fetchEpoch(_epoch).witnesses
        Witness[] memory expectedWitnesses = fetchWitnessesForClaim(
            proof.signedClaim.claim.epoch, proof.signedClaim.claim.identifier, proof.signedClaim.claim.timestampS
        );
        address[] memory signedWitnesses = Claims.recoverSignersOfSignedClaim(proof.signedClaim);

        // check if the number of signatures is equal to the number of witnesses
        require(
            signedWitnesses.length == expectedWitnesses.length, "Number of signatures not equal to number of witnesses"
        );

        require(!LibSort.hasDuplicate(signedWitnesses), "Duplicated Signatures Found");

        for (uint256 i = 0; i < signedWitnesses.length; i++) {
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

    // admin functions ---

    /**
     * @dev Add a new epoch
     */
    function addNewEpoch(Witness[] calldata witnesses, uint8 requisiteWitnessesForClaimCreate) external onlyOwner {
        _addNewEpoch(witnesses, requisiteWitnessesForClaimCreate);
    }

    function _addNewEpoch(Witness[] memory witnesses, uint8 requisiteWitnessesForClaimCreate) private {
        require(witnesses.length > 0, "No witnesses provided");
        require(
            requisiteWitnessesForClaimCreate > 0 && requisiteWitnessesForClaimCreate <= witnesses.length,
            "Invalid requisite witnesses count"
        );

        if (epochs.length > 0) {
            epochs[epochs.length - 1].timestampEnd = uint32(block.timestamp);
        }

        currentEpoch += 1;
        Epoch storage epoch = epochs.push();
        epoch.id = currentEpoch;
        epoch.timestampStart = uint32(block.timestamp);
        epoch.timestampEnd = uint32(block.timestamp + epochDurationS);
        epoch.minimumWitnessesForClaimCreation = requisiteWitnessesForClaimCreate;

        for (uint256 i = 0; i < witnesses.length; i++) {
            epoch.witnesses.push(witnesses[i]);
        }

        emit EpochAdded(epochs[epochs.length - 1]);
    }
}
