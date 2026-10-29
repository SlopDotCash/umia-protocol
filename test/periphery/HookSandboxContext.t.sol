// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Claims} from "../../src/zktls/Claims.sol";
import {ZkTlsVerifier} from "../../src/zktls/ZkTlsVerifier.sol";
import {HookProofValidation} from "../../src/periphery/libraries/HookProofValidation.sol";
import {UmiaValidationHookBase} from "./UmiaValidationHookBase.t.sol";

/// @dev A witness-signed sandbox proof (`sandboxProofContextMessage` in @umia/types) for the bidder
///      and an enabled provider must still fail both auction context checks.
contract HookSandboxContextTest is UmiaValidationHookBase {
    function _sandboxProof(address _user) internal view returns (bytes memory) {
        string memory context = string(
            abi.encodePacked(
                '{"contextAddress":"',
                _addressToString(_user),
                '","providerHash":"',
                _bytes32ToHexString(PROVIDER_HASH_1),
                '","contextMessage":"sandbox:',
                _uint2str(block.chainid),
                ":",
                _address2str(_user),
                ':3f2b6c1e-8d4a-4b7c-9e2f-1a2b3c4d5e6f"}'
            )
        );
        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});
        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: Claims.hashClaimInfo(claimInfo),
            owner: _user,
            timestampS: uint32(vm.getBlockTimestamp()),
            epoch: 2
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
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);
        return abi.encode(
            ZkTlsVerifier.Proof({
                claimInfo: claimInfo, signedClaim: Claims.SignedClaim({claim: claimData, signatures: signatures})
            })
        );
    }

    function test_sandboxProofCannotRegister() public {
        bytes memory proof = _sandboxProof(user);
        vm.roll(hook.getSteps()[0].startBlock);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.RegistrationProofContextMismatch.selector);
        hook.validate(0, 0, user, user, abi.encodePacked(uint256(0), proof));
        assertFalse(hook.isVerified(0, user));
    }

    function test_sandboxProofCannotAuthorizeABid() public {
        vm.startPrank(admin);
        hook.setSigner(signerAddress);
        hook.enableStepPermit(0);
        hook.setVerifyEveryBid(0, true);
        vm.stopPrank();
        bytes memory proof = _sandboxProof(user);
        vm.roll(hook.getSteps()[0].startBlock);
        vm.prank(address(mockCCA));
        vm.expectRevert(HookProofValidation.BidProofContextMismatch.selector);
        hook.validate(0, 1, user, user, abi.encodePacked(uint256(0), proof));
    }
}
