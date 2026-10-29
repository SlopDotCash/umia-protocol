// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Claims} from "../../src/zktls/Claims.sol";
import {LegacyReclaimFormatting} from "./LegacyReclaimFormatting.sol";

contract ClaimsTest is Test {
    function testFuzz_MessageHashPreservesEip191SigningBytes(bytes memory content) public {
        bytes32 hash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n", LegacyReclaimFormatting.uint2str(content.length), content
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123, hash);
        assertEq(Claims.verifySignature(content, abi.encodePacked(r, s, v)), vm.addr(123));
    }

    function testFuzz_SoladyFormattingPreservesSigningBytes(
        bytes32 identifier,
        address owner,
        uint32 timestamp,
        uint32 epoch
    ) public pure {
        Claims.CompleteClaimData memory claim = Claims.CompleteClaimData(identifier, owner, timestamp, epoch);
        bytes memory expected = abi.encodePacked(
            LegacyReclaimFormatting.bytes2str(abi.encodePacked(identifier)),
            "\n",
            LegacyReclaimFormatting.address2str(owner),
            "\n",
            LegacyReclaimFormatting.uint2str(timestamp),
            "\n",
            LegacyReclaimFormatting.uint2str(epoch)
        );
        assertEq(Claims.serialise(claim), expected);
    }

    function test_OzRecoveryStillRejectsMalleableSignatures() public {
        bytes memory content = "signed claim";
        bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n12", content));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123, hash);
        assertEq(Claims.verifySignature(content, abi.encodePacked(r, s, v)), vm.addr(123));
        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        vm.expectRevert();
        this.recover(content, abi.encodePacked(r, bytes32(n - uint256(s)), uint8(v == 27 ? 28 : 27)));
    }

    function recover(bytes memory content, bytes memory signature) external pure returns (address) {
        return Claims.verifySignature(content, signature);
    }
}
