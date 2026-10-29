// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {JSONParserLib} from "@solady/utils/JSONParserLib.sol";
import {ZkTlsContext} from "../../src/zktls/ZkTlsContext.sol";

contract ZkTlsContextHexHarness {
    function parseAddress(string memory value) external pure returns (address) {
        return address(uint160(ZkTlsContext.hexValue(value, 40)));
    }

    function parseHash(string memory value) external pure returns (bytes32) {
        return bytes32(ZkTlsContext.hexValue(value, 64));
    }
}

contract ZkTlsContextHexTest is Test {
    ZkTlsContextHexHarness internal harness = new ZkTlsContextHexHarness();

    function testFuzz_DecodesFullWidthAddresses(address value) public view {
        string memory encoded = LibString.toHexString(value);
        assertEq(harness.parseAddress(encoded), value);
        assertEq(harness.parseAddress(LibString.slice(encoded, 2)), value);
        assertEq(harness.parseAddress(LibString.upper(encoded)), value);
    }

    function testFuzz_DecodesFullWidthHashes(bytes32 value) public view {
        string memory encoded = LibString.toHexString(uint256(value), 32);
        assertEq(harness.parseHash(encoded), value);
        assertEq(harness.parseHash(LibString.slice(encoded, 2)), value);
        assertEq(harness.parseHash(LibString.upper(encoded)), value);
    }

    function test_RejectsWrongAddressWidths() public {
        string memory full = "1111111111111111111111111111111111111111";
        string[8] memory invalid = [
            string(""),
            "0x",
            "1",
            "0x1",
            LibString.slice(full, 1),
            string.concat(full, "0"),
            string.concat("0x", LibString.slice(full, 1)),
            string.concat("0x", full, "0")
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert("Invalid context hex length");
            harness.parseAddress(invalid[i]);
        }
    }

    function test_RejectsWrongHashWidthsAndTruncation() public {
        string memory full = "1111111111111111111111111111111111111111111111111111111111111111";
        string[8] memory invalid = [
            string(""),
            "0x",
            "1",
            "0x1",
            LibString.slice(full, 1),
            string.concat(full, "0"),
            string.concat("0x", LibString.slice(full, 1)),
            string.concat("0x", full, "ff")
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert("Invalid context hex length");
            harness.parseHash(invalid[i]);
        }
    }

    function testFuzz_RejectsEveryNonHexByte(uint8 character, uint8 position) public {
        vm.assume(!(character >= 48 && character <= 57));
        vm.assume(!(character >= 65 && character <= 70));
        vm.assume(!(character >= 97 && character <= 102));
        bytes memory encoded = bytes("1111111111111111111111111111111111111111");
        encoded[position % encoded.length] = bytes1(character);
        vm.expectRevert(JSONParserLib.ParsingFailed.selector);
        harness.parseAddress(string(encoded));
        encoded = bytes("1111111111111111111111111111111111111111111111111111111111111111");
        encoded[position % encoded.length] = bytes1(character);
        vm.expectRevert(JSONParserLib.ParsingFailed.selector);
        harness.parseHash(string(encoded));
    }

    function test_RejectsUnexpectedPrefixes() public {
        vm.expectRevert("Invalid context hex length");
        harness.parseAddress("0z1111111111111111111111111111111111111111");
        vm.expectRevert("Invalid context hex length");
        harness.parseHash("0z1111111111111111111111111111111111111111111111111111111111111111");
        vm.expectRevert("Invalid context hex length");
        harness.parseAddress("0x11111111111111111111111111111111111111");
    }
}
