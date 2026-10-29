// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./StringUtils.sol";

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
     * Asserts that the claim is signed by the expected witnesses
     */
    function assertValidSignedClaim(SignedClaim memory self, address[] memory expectedWitnessAddresses) internal pure {
        require(self.signatures.length > 0, "No signatures");
        address[] memory signedWitnesses = recoverSignersOfSignedClaim(self);
        for (uint256 i = 0; i < expectedWitnessAddresses.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < signedWitnesses.length; j++) {
                if (signedWitnesses[j] == expectedWitnessAddresses[i]) {
                    found = true;
                    break;
                }
            }
            require(found, "Missing witness signature");
        }
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
            StringUtils.bytes2str(abi.encodePacked(self.identifier)),
            "\n",
            StringUtils.address2str(self.owner),
            "\n",
            StringUtils.uint2str(self.timestampS),
            "\n",
            StringUtils.uint2str(self.epoch)
        );
    }

    /**
     * @dev returns the address of the user that generated the signature
     */
    function verifySignature(bytes memory content, bytes memory signature) internal pure returns (address signer) {
        bytes32 signedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n", StringUtils.uint2str(content.length), content)
        );
        return ECDSA.recover(signedHash, signature);
    }

    function hashClaimInfo(ClaimInfo memory claimInfo) internal pure returns (bytes32) {
        bytes memory serialised =
            abi.encodePacked(claimInfo.provider, "\n", claimInfo.parameters, "\n", claimInfo.context);
        return keccak256(serialised);
    }

    function extractFieldFromContext(string memory data, string memory target) public pure returns (string memory) {
        bytes memory dataBytes = bytes(data);
        bytes memory targetBytes = bytes(target);

        require(dataBytes.length >= targetBytes.length, "target is longer than data");
        uint256 start = 0;
        bool foundStart = false;
        // Find start of "contextMessage":"

        for (uint256 i = 0; i <= dataBytes.length - targetBytes.length; i++) {
            bool isMatch = true;

            for (uint256 j = 0; j < targetBytes.length && isMatch; j++) {
                if (dataBytes[i + j] != targetBytes[j]) {
                    isMatch = false;
                }
            }

            if (isMatch) {
                start = i + targetBytes.length; // Move start to the end of "contextMessage":"
                foundStart = true;
                break;
            }
        }

        if (!foundStart) {
            return ""; // Malformed or missing message
        }

        // Find the end of the message, assuming it ends with a quote not preceded by a backslash.
        // The function does not need to handle escaped backslashes specifically because
        // it only looks for the first unescaped quote to mark the end of the field value.
        // Escaped quotes (preceded by a backslash) are naturally ignored in this logic.
        uint256 end = start;
        while (end < dataBytes.length && !(dataBytes[end] == '"' && dataBytes[end - 1] != "\\")) {
            end++;
        }

        if (end >= dataBytes.length || end <= start) {
            return "";
        }

        bytes memory contextMessage = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            contextMessage[i - start] = dataBytes[i];
        }
        return string(contextMessage);
    }

    /// @notice Extracts the raw JSON object substring (including outer braces)
    ///         that follows `target` in `data`. Tracks brace depth and respects
    ///         JSON string escapes so values containing `}` or escaped quotes
    ///         don't truncate the output. Returns empty bytes if the target is
    ///         absent or the object is malformed / never closes.
    /// @dev Used to grab `extractedParameters` verbatim out of a Reclaim
    ///      context for off-/onchain identity hashing without having to parse
    ///      JSON. The returned bytes are byte-equivalent to the substring the
    ///      attestor signed.
    function extractJsonObjectFromContext(string memory data, string memory target)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory dataBytes = bytes(data);
        bytes memory targetBytes = bytes(target);

        if (dataBytes.length < targetBytes.length) return "";

        uint256 start = 0;
        bool foundStart = false;
        for (uint256 i = 0; i <= dataBytes.length - targetBytes.length; i++) {
            bool isMatch = true;
            for (uint256 j = 0; j < targetBytes.length && isMatch; j++) {
                if (dataBytes[i + j] != targetBytes[j]) {
                    isMatch = false;
                }
            }
            if (isMatch) {
                start = i + targetBytes.length;
                foundStart = true;
                break;
            }
        }
        if (!foundStart) return "";

        // Skip optional whitespace between the colon and the opening brace.
        while (start < dataBytes.length && (dataBytes[start] == 0x20 || dataBytes[start] == 0x09)) {
            start++;
        }
        if (start >= dataBytes.length || dataBytes[start] != "{") return "";

        uint256 depth = 0;
        bool inStr = false;
        bool escaped = false;
        uint256 end = dataBytes.length;
        for (uint256 i = start; i < dataBytes.length; i++) {
            bytes1 ch = dataBytes[i];
            if (inStr) {
                if (escaped) {
                    escaped = false;
                } else if (ch == "\\") {
                    escaped = true;
                } else if (ch == '"') {
                    inStr = false;
                }
                continue;
            }
            if (ch == '"') {
                inStr = true;
            } else if (ch == "{") {
                depth++;
            } else if (ch == "}") {
                depth--;
                if (depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        if (end > dataBytes.length || depth != 0) return "";

        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = dataBytes[i];
        }
        return out;
    }

    /// @notice Accepts a nonempty JSON object whose values are all nonblank strings.
    /// @dev Mirrors the extracted-parameter shape checked by the API before an identity is stored.
    function hasNonEmptyStringValues(bytes memory object) internal pure returns (bool) {
        uint256 length = object.length;
        if (length < 2 || object[0] != "{" || object[length - 1] != "}") return false;

        uint256 cursor = 1;
        while (cursor < length) {
            cursor = _skipJsonWhitespace(object, cursor);
            if (cursor >= length - 1 || object[cursor] != '"') return false;
            (cursor,) = _scanJsonString(object, cursor);
            if (cursor == 0) return false;

            cursor = _skipJsonWhitespace(object, cursor);
            if (cursor >= length - 1 || object[cursor] != ":") return false;
            cursor = _skipJsonWhitespace(object, cursor + 1);
            if (cursor >= length - 1 || object[cursor] != '"') return false;
            bool hasValue;
            (cursor, hasValue) = _scanJsonString(object, cursor);
            if (cursor == 0 || !hasValue) return false;

            cursor = _skipJsonWhitespace(object, cursor);
            if (cursor == length - 1) return true;
            if (cursor >= length - 1 || object[cursor] != ",") return false;
            ++cursor;
        }
        return false;
    }

    function _skipJsonWhitespace(bytes memory data, uint256 cursor) private pure returns (uint256) {
        while (cursor < data.length && _isJsonWhitespace(uint8(data[cursor]))) ++cursor;
        return cursor;
    }

    function _isJsonWhitespace(uint256 codepoint) private pure returns (bool) {
        return codepoint == 0x20 || (codepoint >= 0x09 && codepoint <= 0x0d);
    }

    function _isTrimWhitespace(uint256 codepoint) private pure returns (bool) {
        return _isJsonWhitespace(codepoint) || codepoint == 0xa0 || codepoint == 0x1680
            || (codepoint >= 0x2000 && codepoint <= 0x200a) || codepoint == 0x2028 || codepoint == 0x2029
            || codepoint == 0x202f || codepoint == 0x205f || codepoint == 0x3000 || codepoint == 0xfeff;
    }

    /// @dev Returns cursor zero for malformed strings. Tracks content after JavaScript-style trim.
    function _scanJsonString(bytes memory data, uint256 cursor) private pure returns (uint256, bool) {
        bool hasContent;
        ++cursor;
        while (cursor < data.length) {
            uint8 ch = uint8(data[cursor]);
            if (ch == 0x22) return (cursor + 1, hasContent);
            if (ch == 0x5c) {
                if (++cursor >= data.length) return (0, false);
                ch = uint8(data[cursor]);
                if (ch == 0x75) {
                    if (cursor + 4 >= data.length) return (0, false);
                    uint256 escapedCodepoint;
                    for (uint256 j = 1; j <= 4; ++j) {
                        uint256 digit = _hexDigit(uint8(data[cursor + j]));
                        if (digit > 15) return (0, false);
                        escapedCodepoint = (escapedCodepoint << 4) | digit;
                    }
                    if (!_isTrimWhitespace(escapedCodepoint)) hasContent = true;
                    cursor += 5;
                    continue;
                }
                if (ch == 0x22 || ch == 0x5c || ch == 0x2f || ch == 0x62) hasContent = true;
                else if (ch != 0x66 && ch != 0x6e && ch != 0x72 && ch != 0x74) return (0, false);
                ++cursor;
                continue;
            }
            if (ch < 0x20) return (0, false);
            uint256 codepoint;
            (codepoint, cursor) = _decodeUtf8(data, cursor);
            if (cursor == 0) return (0, false);
            if (!_isTrimWhitespace(codepoint)) hasContent = true;
        }
        return (0, false);
    }

    function _hexDigit(uint8 ch) private pure returns (uint256) {
        if (ch >= 0x30 && ch <= 0x39) return ch - 0x30;
        if (ch >= 0x41 && ch <= 0x46) return ch - 0x41 + 10;
        if (ch >= 0x61 && ch <= 0x66) return ch - 0x61 + 10;
        return 16;
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
