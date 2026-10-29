// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {JSONParserLib} from "@solady/utils/JSONParserLib.sol";
import {ZkTlsContext} from "../../src/zktls/ZkTlsContext.sol";

contract ZkTlsContextHarness {
    function parse(string memory data) external pure returns (ZkTlsContext.Context memory) {
        return ZkTlsContext.parse(data);
    }
}

contract ZkTlsContextTest is Test {
    ZkTlsContextHarness internal parser = new ZkTlsContextHarness();

    string internal constant SUBJECT = '"contextAddress":"0x00000000000000000000000000000000000000aA"';
    string internal constant HASH =
        '"providerHash":"0x00000000000000000000000000000000000000000000000000000000000000bb"';

    /// @dev A context carrying the required full-width hex fields plus `fields`.
    function _context(string memory fields) internal pure returns (string memory) {
        return string.concat("{", SUBJECT, ",", HASH, bytes(fields).length == 0 ? "" : ",", fields, "}");
    }

    function test_ReturnsTypedFieldsAndRawIdentityBytes() public view {
        ZkTlsContext.Context memory context = parser.parse(
            _context(
                '"identityProvider":"github","contextMessage":"register:1:auction:nonce","extractedParameters" :  { "account" : "a\\u0062" } '
            )
        );
        assertEq(context.contextAddress, address(0xaa));
        assertEq(context.providerHash, bytes32(uint256(0xbb)));
        assertEq(context.identityProvider, "github");
        assertEq(context.contextMessage, "register:1:auction:nonce");
        assertEq(string(context.extractedParameters), '{ "account" : "a\\u0062" }');
    }

    function test_PreservesEscapedStringValues() public view {
        ZkTlsContext.Context memory context =
            parser.parse(_context('"contextMessage":"tail\\\\","extractedParameters":{"u":"a\\"b}c"}'));
        assertEq(context.contextMessage, "tail\\\\");
        assertEq(string(context.extractedParameters), '{"u":"a\\"b}c"}');
    }

    function test_MissingAndWronglyTypedOptionalFieldsAreEmpty() public view {
        ZkTlsContext.Context memory context =
            parser.parse(_context('"identityProvider":[],"contextMessage":{},"extractedParameters":"oops"'));
        assertEq(context.identityProvider, "");
        assertEq(context.contextMessage, "");
        assertEq(context.extractedParameters.length, 0);
        assertEq(parser.parse(_context("")).extractedParameters.length, 0);
    }

    function test_RequiresHexSubjectAndProviderHash() public {
        string[4] memory invalid = [
            string("{}"),
            string.concat('{"contextAddress":1,', HASH, "}"),
            string.concat("{", SUBJECT, ',"providerHash":null}'),
            string.concat("{", SUBJECT, "}")
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert("Invalid context hex length");
            parser.parse(invalid[i]);
        }
    }

    function test_RejectsEveryDuplicateSecurityField() public {
        string[5] memory keys =
            [string("contextAddress"), "providerHash", "identityProvider", "contextMessage", "extractedParameters"];
        for (uint256 i; i < keys.length; ++i) {
            string memory data = string.concat('{"', keys[i], '":"first","', keys[i], '" : 42}');
            vm.expectRevert("Duplicate context key");
            parser.parse(data);
        }
    }

    function test_RejectsNestedDuplicatesInEitherOrder() public {
        vm.expectRevert("Duplicate context key");
        parser.parse('{"a":{"providerHash":"decoy"},"providerHash":"real"}');
        vm.expectRevert("Duplicate context key");
        parser.parse('{"providerHash":"real","a":[{"providerHash":"decoy"}]}');
        vm.expectRevert("Duplicate context key");
        parser.parse('{"a":{"extractedParameters":{"account":"decoy"}},"extractedParameters":{"account":"real"}}');
    }

    function test_RejectsNestedOnlyFields() public {
        vm.expectRevert("Nested context key");
        parser.parse('{"a":[{"providerHash":"decoy"}]}');
        vm.expectRevert("Nested context key");
        parser.parse('{"a":{"extractedParameters":{"account":"decoy"}}}');
    }

    function test_RejectsEscapedKeyAliases() public {
        vm.expectRevert("Escaped context key");
        parser.parse('{"providerHash":"first","provider\\u0048ash":"last"}');
    }

    function test_IgnoresKeyTextInsideStringValues() public view {
        assertEq(
            parser.parse(_context('"note":"a \\"providerHash\\":\\"decoy\\""')).providerHash, bytes32(uint256(0xbb))
        );
    }

    function test_RejectsMalformedGrammar() public {
        vm.expectRevert(JSONParserLib.ParsingFailed.selector);
        parser.parse('{"a":"b",}');
        vm.expectRevert("Invalid context JSON");
        parser.parse("[]");
        vm.expectRevert("Invalid context JSON");
        parser.parse('{"a":"unfinished}');
    }

    function test_RejectsUnquotedObjectKey() public {
        vm.expectRevert("Invalid context JSON");
        parser.parse('{xfoo":"bar"}');
    }

    function test_RejectsRawControlsAndMalformedUtf8() public {
        bytes[5] memory invalidBytes =
            [bytes(hex"01"), bytes(hex"ff"), bytes(hex"c0af"), bytes(hex"eda080"), bytes(hex"f4908080")];
        for (uint256 i; i < invalidBytes.length; ++i) {
            vm.expectRevert("Invalid context JSON");
            parser.parse(string(bytes.concat(bytes('{"note":"'), invalidBytes[i], bytes('"}'))));
        }
    }

    function test_RejectsNonJsonWhitespaceOutsideStrings() public {
        vm.expectRevert("Invalid context JSON");
        parser.parse(string(bytes.concat(hex"0b", bytes("{}"))));
    }

    function test_RejectsEmptyOrNonStringIdentityValues() public view {
        string[7] memory objects =
            [string("{}"), '{"a":""}', '{"a":" "}', '{"a":null}', '{"a":[]}', '{"a":{}}', '{"a":"valid","b":""}'];
        for (uint256 i; i < objects.length; ++i) {
            assertEq(
                parser.parse(_context(string.concat('"extractedParameters":', objects[i]))).extractedParameters.length,
                0
            );
        }
    }

    function test_RejectsUnicodeWhitespaceIdentityValues() public view {
        string[8] memory blank = [
            string('"\\t\\n"'),
            '"\\u0020"',
            '"\\u00a0"',
            '"\\u2003"',
            '"\\u2028"',
            '"\\ufeff"',
            string(bytes.concat(bytes('"'), hex"c2a0", bytes('"'))),
            string(bytes.concat(bytes('"'), hex"e38080", bytes('"')))
        ];
        for (uint256 i; i < blank.length; ++i) {
            assertEq(
                parser.parse(_context(string.concat('"extractedParameters":{"account":', blank[i], "}")))
                    .extractedParameters.length,
                0
            );
        }
    }

    function test_AcceptsUnicodeAndEscapedIdentityValuesWithoutReserializing() public view {
        string memory object = string(
            bytes.concat(bytes('{"account":"'), hex"c3a9", bytes('","other":"\\ud83d\\ude00","control":"\\u0000"}'))
        );
        assertEq(
            string(parser.parse(_context(string.concat('"extractedParameters":', object))).extractedParameters), object
        );
    }
}
