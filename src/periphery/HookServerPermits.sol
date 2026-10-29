// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title HookServerPermits
/// @notice Single-use EIP-712 permits, each bound to one bid's wallet, step, amount and deadline.
///         A permit never registers the wallet: the signer holds each wallet's allowance.
abstract contract HookServerPermits {
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 public constant SERVER_PERMIT_TYPEHASH =
        keccak256("ServerPermit(address wallet,uint256 step,bytes32 nonce,uint256 deadline,uint128 amount)");

    /// @notice EIP-712 domain separator (bound to contract address and chain ID)
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Authorized server permit signer (address(0) = disabled)
    address internal _signer;

    /// @notice Single-use permit nonces. Once a server permit is consumed in a bid,
    ///         its nonce is burned and the signature cannot be replayed.
    mapping(bytes32 nonce => bool) internal _usedPermits;

    error SignerNotSet();
    error ExpiredDeadline();
    error InvalidSignature();
    error PermitAlreadyUsed(bytes32 nonce);

    event SignerSet(address indexed oldSigner, address indexed newSigner);
    event PermitConsumed(address indexed user, uint256 indexed stepIndex, bytes32 indexed nonce);

    constructor(address signer_) {
        _signer = signer_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("UmiaValidationHook"), keccak256("1"), block.chainid, address(this))
        );
    }

    function _setSigner(address newSigner) internal {
        address old = _signer;
        _signer = newSigner;
        emit SignerSet(old, newSigner);
    }

    /// @dev Whether `permit` is a canonical abi.encode(uint256, bytes32, uint256, bytes) whose
    ///      signature fits. The length is bounded first, so a hostile length word can't overflow.
    function _isPermitEnvelope(bytes calldata permit) internal pure returns (bool) {
        if (permit.length < 160) return false;
        uint256 sigLen = uint256(bytes32(permit[128:160]));
        return uint256(bytes32(permit[96:128])) == 0x80 && sigLen <= permit.length
            && permit.length >= 160 + ((sigLen + 31) / 32) * 32;
    }

    /// @dev Verifies a permit for `user`'s bid of exactly `amount` at `stepIndex` and burns its
    ///      nonce. `permit` must already pass `_isPermitEnvelope`.
    function _consumeServerPermit(address user, uint256 stepIndex, bytes calldata permit, uint128 amount) internal {
        (, bytes32 nonce, uint256 deadline, bytes memory signature) =
            abi.decode(permit, (uint256, bytes32, uint256, bytes));
        if (_signer == address(0)) revert SignerNotSet();
        if (block.timestamp > deadline) revert ExpiredDeadline();
        if (_usedPermits[nonce]) revert PermitAlreadyUsed(nonce);

        bytes32 structHash = keccak256(abi.encode(SERVER_PERMIT_TYPEHASH, user, stepIndex, nonce, deadline, amount));
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);

        // tryRecover (not recover) so a wrong-length or malleable signature reverts this hook's
        // InvalidSignature rather than OpenZeppelin's own ECDSA error.
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != _signer) revert InvalidSignature();

        _usedPermits[nonce] = true;
        emit PermitConsumed(user, stepIndex, nonce);
    }
}
