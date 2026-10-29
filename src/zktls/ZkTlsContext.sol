// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {JSONParserLib as JSON} from "@solady/utils/JSONParserLib.sol";
import {LibBytes} from "@solady/utils/LibBytes.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Strict context parsing for the ZkTlsVerifier beacon. Identity bytes retain their signed spelling.
/// @dev Solady supplies JSON traversal. Encoding, unique top-level security keys and nonblank
///      identity values are protocol policy, enforced here rather than delegated to key lookup.
library ZkTlsContext {
    using JSON for JSON.Item;

    struct Context {
        address contextAddress;
        bytes32 providerHash;
        string identityProvider;
        string contextMessage;
        bytes extractedParameters;
    }

    uint256 private constant FIELD_COUNT = 5;

    struct Fields {
        JSON.Item[FIELD_COUNT] items;
        uint256 seen;
        uint256 nested;
    }

    /// @notice Parses an object context once. `contextAddress` and `providerHash` must be full-width
    ///         hex. Other missing or wrongly typed fields are empty; consumers enforce them.
    function parse(string memory data) internal pure returns (Context memory context) {
        _validateEncoding(bytes(data));
        JSON.Item memory root = JSON.parse(data);
        require(root.isObject(), "Invalid context JSON");
        Fields memory fields;
        _collect(root, fields, true);
        require(fields.nested == 0, "Nested context key");
        context.contextAddress = address(uint160(hexValue(_stringValue(fields.items[0]), 40)));
        context.providerHash = bytes32(hexValue(_stringValue(fields.items[1]), 64));
        context.identityProvider = _stringValue(fields.items[2]);
        context.contextMessage = _stringValue(fields.items[3]);
        if (_hasIdentityValues(fields.items[4])) context.extractedParameters = bytes(fields.items[4].value());
    }

    function _collect(JSON.Item memory parent, Fields memory fields, bool topLevel) private pure {
        JSON.Item[] memory children = parent.children();
        for (uint256 i; i < children.length; ++i) {
            JSON.Item memory item = children[i];
            if (parent.isObject()) {
                bytes memory key = bytes(item.key());
                require(key.length >= 2 && key[0] == '"' && key[key.length - 1] == '"', "Invalid context JSON");
                require(LibBytes.indexOfByte(key, 0x5c) == LibBytes.NOT_FOUND, "Escaped context key");
                uint256 index = _fieldIndex(keccak256(key));
                if (index < FIELD_COUNT) {
                    uint256 bit = 1 << index;
                    require(fields.seen & bit == 0, "Duplicate context key");
                    fields.seen |= bit;
                    if (topLevel) fields.items[index] = item;
                    else fields.nested |= bit;
                }
            }
            if (item.isObject() || item.isArray()) _collect(item, fields, false);
        }
    }

    function _fieldIndex(bytes32 key) private pure returns (uint256) {
        if (key == keccak256('"contextAddress"')) return 0;
        if (key == keccak256('"providerHash"')) return 1;
        if (key == keccak256('"identityProvider"')) return 2;
        if (key == keccak256('"contextMessage"')) return 3;
        if (key == keccak256('"extractedParameters"')) return 4;
        return FIELD_COUNT;
    }

    /// @notice Exactly `digits` hex digits, optionally `0x`-prefixed: never truncated or coerced.
    function hexValue(string memory value, uint256 digits) internal pure returns (uint256) {
        bytes memory encoded = bytes(value);
        bool prefixed = encoded.length >= 2 && encoded[0] == "0" && (encoded[1] == "x" || encoded[1] == "X");
        require(encoded.length == digits + (prefixed ? 2 : 0), "Invalid context hex length");
        return JSON.parseUintFromHex(value);
    }

    function _stringValue(JSON.Item memory item) private pure returns (string memory) {
        if (!item.isString()) return "";
        string memory value = item.value();
        // Keep escape spelling unchanged for the hook's domain/namespace checks.
        return LibString.slice(value, 1, bytes(value).length - 1);
    }

    /// @dev A blank value names no account, and its whitespace spellings would hash to distinct identities.
    function _hasIdentityValues(JSON.Item memory item) private pure returns (bool) {
        if (!item.isObject()) return false;
        JSON.Item[] memory values = item.children();
        if (values.length == 0) return false;
        for (uint256 i; i < values.length; ++i) {
            if (!values[i].isString()) return false;
            bytes memory decoded = bytes(JSON.decodeString(values[i].value()));
            bool hasContent;
            for (uint256 cursor; cursor < decoded.length;) {
                (uint256 codepoint, uint256 next) = _decodeUtf8(decoded, cursor);
                if (next == 0) return false;
                if (!_isTrimWhitespace(codepoint)) hasContent = true;
                cursor = next;
            }
            if (!hasContent) return false;
        }
        return true;
    }

    /// @dev Solady's parser does not reject raw controls or malformed UTF-8 in strings, which would
    ///      give one identity several signed byte spellings.
    function _validateEncoding(bytes memory data) private pure {
        bool inString;
        bool escaped;
        for (uint256 cursor; cursor < data.length;) {
            (uint256 codepoint, uint256 next) = _decodeUtf8(data, cursor);
            require(next != 0, "Invalid context JSON");
            if (codepoint < 0x20) {
                require(
                    !inString && (codepoint == 0x09 || codepoint == 0x0a || codepoint == 0x0d), "Invalid context JSON"
                );
            }
            if (inString) {
                if (escaped) escaped = false;
                else if (codepoint == 0x5c) escaped = true;
                else if (codepoint == 0x22) inString = false;
            } else if (codepoint == 0x22) {
                inString = true;
            }
            cursor = next;
        }
        require(!inString, "Invalid context JSON");
    }

    function _isTrimWhitespace(uint256 codepoint) private pure returns (bool) {
        return (codepoint == 0x20 || (codepoint >= 0x09 && codepoint <= 0x0d)) || codepoint == 0xa0
            || codepoint == 0x1680 || (codepoint >= 0x2000 && codepoint <= 0x200a) || codepoint == 0x2028
            || codepoint == 0x2029 || codepoint == 0x202f || codepoint == 0x205f || codepoint == 0x3000
            || codepoint == 0xfeff;
    }

    function _decodeUtf8(bytes memory data, uint256 cursor) private pure returns (uint256, uint256) {
        uint8 first = uint8(data[cursor]);
        if (first < 0x80) return (first, cursor + 1);
        uint256 count;
        uint256 codepoint;
        if (first >= 0xc2 && first <= 0xdf) {
            count = 2;
            codepoint = first & 0x1f;
        } else if (first >= 0xe0 && first <= 0xef) {
            count = 3;
            codepoint = first & 0x0f;
        } else if (first >= 0xf0 && first <= 0xf4) {
            count = 4;
            codepoint = first & 0x07;
        } else {
            return (0, 0);
        }
        if (cursor + count > data.length) return (0, 0);
        for (uint256 j = 1; j < count; ++j) {
            uint8 next = uint8(data[cursor + j]);
            if (next < 0x80 || next > 0xbf) return (0, 0);
            codepoint = (codepoint << 6) | (next & 0x3f);
        }
        if (
            (count == 3 && codepoint < 0x800) || (count == 4 && codepoint < 0x10000)
                || (codepoint >= 0xd800 && codepoint <= 0xdfff) || codepoint > 0x10ffff
        ) return (0, 0);
        return (codepoint, cursor + count);
    }
}
