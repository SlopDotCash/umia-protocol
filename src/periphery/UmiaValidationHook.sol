// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {
    ValidationHookIntrospection
} from "@continuous-clearing-auction/periphery/validationHooks/ValidationHookIntrospection.sol";
import {IValidationHook} from "@continuous-clearing-auction/interfaces/IValidationHook.sol";
import {ITickStorage} from "@continuous-clearing-auction/interfaces/ITickStorage.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {Multicallable} from "@solady/utils/Multicallable.sol";
import {BlockNumberish} from "@blocknumberish/src/BlockNumberish.sol";
import {IGatedValidationHook} from "../interfaces/IGatedValidationHook.sol";
import {IMaxBidPriceValidationHook} from "../interfaces/IMaxBidPriceValidationHook.sol";
import {IVerifyEveryBidHook} from "../interfaces/IVerifyEveryBidHook.sol";
import {IUmiaValidationHook} from "../interfaces/IUmiaValidationHook.sol";
import {Reclaim} from "../reclaim/Reclaim.sol";
import {Claims} from "../reclaim/Claims.sol";
import {ReclaimProofVerifier} from "../reclaim/ReclaimProofVerifier.sol";
import {StringUtils} from "../reclaim/StringUtils.sol";
import {HookServerPermits} from "./HookServerPermits.sol";
import {HookStepSchedule} from "./libraries/HookStepSchedule.sol";
import {HookProofValidation} from "./libraries/HookProofValidation.sol";

/// @title UmiaValidationHook
/// @notice CCA validation hook that restricts bidding to verified users. Credentials travel inline
///         in hookData and validate() is their only entry point:
///         - zkTLS proof, `proofStep (32 bytes) ++ abi.encode(Reclaim.Proof)`: registers the owner on
///           an ordinary step, or authorizes this one bid on a step that verifies every bid.
///         - Server permit, `0x01 ++ abi.encode(permitStep, nonce, deadline, signature)`: single-use,
///           signed over (wallet, step, nonce, deadline, amount), one per bid.
///         Registration is monotonic: an owner registered at step N passes later proof-gated steps.
///         Anyone may submit the bid; the proof or signature is the authorization.
contract UmiaValidationHook is
    IUmiaValidationHook,
    ValidationHookIntrospection,
    Ownable,
    BlockNumberish,
    Multicallable,
    HookServerPermits
{
    // ─────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────

    /// @dev A step's configuration. `providers` is the proof gate (empty = proofs rejected).
    struct StepGate {
        bool enabled;
        bool permit;
        bool everyBid;
        bytes32[] providers;
    }

    struct Registration {
        bool active;
        uint64 fromStep;
    }

    /// @dev What a bid at a step needs from its owner.
    enum Access {
        Open, // disabled, or enabled with no gate: nothing
        Closed, // verifies every bid with no gate: every bid reverts
        Registered, // standing registration covers the step
        Credential // an inline proof or permit
    }

    // ─────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────

    /// @notice Max age of a bid proof. Registration proofs never expire.
    uint256 public constant BID_PROOF_MAX_AGE = 10 minutes;

    Reclaim public immutable reclaim;

    address private _cca;
    BlockRange[] private _steps;
    mapping(uint256 stepIndex => StepGate) private _gates;
    uint256 private _maxBidPrice;

    mapping(address user => Registration) private _registrations;
    mapping(bytes32 proofIdentifier => bool) private _consumedBidProofs;

    mapping(bytes32 providerHash => string) private _identityProviderByHash;
    mapping(bytes32 identityHash => address) private _identityToUser;

    /// @dev zk totals are gross: refunds and cancellations are never credited back.
    mapping(uint256 stepIndex => uint256) private _stepMaxBidAmount;
    mapping(address owner => mapping(uint256 stepIndex => uint256)) private _zkBidTotal;
    uint256 private _zkGlobalMaxBidAmount;
    uint256 private _zkGlobalBidTotal;

    // ─────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────

    error CallerNotCCA();
    error NoCCA();
    error ZeroAddress();
    error StepIndexOutOfBounds(uint256 stepIndex);
    error StepAlreadyStarted(uint256 stepIndex);
    error ArrayLengthMismatch();
    error NoGateConfigured(uint256 stepIndex);
    error MaxBidPriceExceeded();
    error PriceNotAlignedToTick();

    error NotVerified(address user);
    error ProofRequired(uint256 stepIndex);
    error ServerPermitRequired(uint256 stepIndex);
    error ServerPermitNotEnabled(uint256 stepIndex);
    error CredentialStepMismatch(uint256 credentialStep, uint256 currentStep);
    error ProofStepTooHigh(uint256 proofStep, uint256 currentStep);
    error PermitStepTooHigh(uint256 permitStep, uint256 currentStep);
    error ProofAlreadyUsed(bytes32 identifier);
    error ContextAddressMismatch(address expected, address actual);
    error ProviderNotFound(uint256 stepIndex, bytes32 providerHash);
    error ProviderHashMismatch(bytes32 expected, bytes32 actual);

    error IdentityAlreadyClaimed(bytes32 providerHash, bytes32 identityHash, address existingUser);
    error IdentityProviderMissing(bytes32 providerHash);
    error IdentityProviderMismatch(bytes32 providerHash);
    error IdentityProviderImmutable(bytes32 providerHash);
    error InvalidIdentityProvider();
    error EmptyIdentityParameters();

    error ZkBidExceedsStepCap(address owner, uint256 stepIndex, uint256 attempted, uint256 cap);
    error ZkBidExceedsGlobalCap(address owner, uint256 attempted, uint256 cap);

    // ─────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────

    event CCASet(address indexed cca);
    event StepEnabled(uint256 indexed stepIndex);
    event StepDisabled(uint256 indexed stepIndex);
    event StepProviderSet(uint256 indexed stepIndex, bytes32 providerHash, string providerId);
    event StepProviderRemoved(uint256 indexed stepIndex, bytes32 providerHash);
    event StepPermitEnabled(uint256 indexed stepIndex);
    event StepPermitDisabled(uint256 indexed stepIndex);
    event VerifyEveryBidSet(uint256 indexed stepIndex, bool required);
    event MaxBidPriceSet(uint256 maxBidPrice);

    event Registered(uint256 indexed stepIndex, address indexed user);
    event Unregistered(address indexed user);
    event ProofVerified(address indexed user, uint256 indexed stepIndex, bytes32 indexed proofIdentifier);

    event IdentityClaimed(
        address indexed user, bytes32 indexed providerHash, bytes32 indexed identityHash, uint256 stepIndex
    );
    event IdentityCleared(bytes32 indexed identityHash);
    event IdentityProviderSet(bytes32 indexed providerHash, string identityProvider);

    event StepMaxBidAmountSet(uint256 indexed stepIndex, uint256 amount);
    event ZkGlobalMaxBidAmountSet(uint256 amount);
    event ZkGlobalBidAccrued(address indexed owner, uint256 amount, uint256 newTotal);

    constructor(address _owner, address _reclaim, address signer_) HookServerPermits(signer_) {
        _initializeOwner(_owner);
        reclaim = Reclaim(_reclaim);
    }

    // ─────────────────────────────────────────────────────────
    // Validation
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IValidationHook
    /// @dev Only the paired CCA may call: validate() accrues the zk totals, so a permissionless entry
    ///      point would let anyone inflate them. Credentials and caps bind to `owner`, never the sender.
    function validate(uint256 maxPrice, uint128 amount, address owner, address, bytes calldata hookData) external {
        if (_cca == address(0)) return;
        if (msg.sender != _cca) revert CallerNotCCA();
        if (_maxBidPrice != 0 && maxPrice > _maxBidPrice) revert MaxBidPriceExceeded();

        (bool inStep, uint256 step) = _currentStep();
        if (!inStep) return;

        StepGate storage gate = _gates[step];
        Access access = _access(gate, step, owner);
        if (access == Access.Open) return;
        if (access == Access.Closed) revert NoGateConfigured(step);

        if (access == Access.Credential) {
            bool proofGate = gate.providers.length != 0;
            if (hookData.length == 0) {
                if (!proofGate) revert ServerPermitRequired(step);
                if (!gate.permit) revert ProofRequired(step);
                revert NotVerified(owner);
            }
            if (gate.permit && (!proofGate || hookData[0] == 0x01)) {
                _validatePermit(gate.everyBid, step, owner, amount, hookData);
                return;
            }
            _validateProof(gate.everyBid, step, owner, amount, hookData);
        }
        _accrueZkBid(owner, step, amount);
    }

    function _access(StepGate storage gate, uint256 step, address user) private view returns (Access) {
        if (!gate.enabled) return Access.Open;
        bool proofGate = gate.providers.length != 0;
        if (!proofGate && !gate.permit) return gate.everyBid ? Access.Closed : Access.Open;
        if (proofGate && !gate.everyBid && _isRegisteredAt(step, user)) return Access.Registered;
        return Access.Credential;
    }

    function _validatePermit(bool everyBid, uint256 step, address owner, uint128 amount, bytes calldata hookData)
        private
    {
        if (hookData[0] != 0x01 || !_isPermitEnvelope(hookData[1:])) revert ServerPermitRequired(step);
        bytes calldata permit = hookData[1:];
        uint256 permitStep = uint256(bytes32(permit[:32]));
        _requireCredentialStep(everyBid, step, permitStep, true);
        if (!_gates[permitStep].permit) revert ServerPermitNotEnabled(permitStep);
        _consumeServerPermit(owner, permitStep, permit, amount);
    }

    function _validateProof(bool everyBid, uint256 step, address owner, uint128 amount, bytes calldata hookData)
        private
    {
        if (hookData[0] == 0x01 || hookData.length < 32) revert ProofRequired(step);
        uint256 proofStep = uint256(bytes32(hookData[:32]));
        _requireCredentialStep(everyBid, step, proofStep, false);
        Reclaim.Proof memory proof = abi.decode(hookData[32:], (Reclaim.Proof));
        if (everyBid) _consumeBidProof(owner, proofStep, proof, amount);
        else _register(owner, proofStep, proof);
    }

    /// @dev A credential serves a later step only when neither step verifies every bid.
    function _requireCredentialStep(bool everyBid, uint256 step, uint256 credentialStep, bool isPermit) private view {
        if ((everyBid || _gates[credentialStep].everyBid) && credentialStep != step) {
            revert CredentialStepMismatch(credentialStep, step);
        }
        if (credentialStep > step) {
            if (isPermit) revert PermitStepTooHigh(credentialStep, step);
            revert ProofStepTooHigh(credentialStep, step);
        }
    }

    /// @dev The global total accrues even while uncapped, so a cap set mid-auction counts volume
    ///      already landed. The step total accrues only while that step is capped.
    function _accrueZkBid(address owner, uint256 step, uint128 amount) private {
        uint256 globalNext = _zkGlobalBidTotal + amount;
        uint256 globalCap = _zkGlobalMaxBidAmount;
        if (globalCap != 0 && globalNext > globalCap) revert ZkBidExceedsGlobalCap(owner, globalNext, globalCap);
        _zkGlobalBidTotal = globalNext;
        emit ZkGlobalBidAccrued(owner, amount, globalNext);

        uint256 stepCap = _stepMaxBidAmount[step];
        if (stepCap == 0) return;
        uint256 stepNext = _zkBidTotal[owner][step] + amount;
        if (stepNext > stepCap) revert ZkBidExceedsStepCap(owner, step, stepNext, stepCap);
        _zkBidTotal[owner][step] = stepNext;
    }

    // ─────────────────────────────────────────────────────────
    // Proofs
    // ─────────────────────────────────────────────────────────

    function _register(address user, uint256 step, Reclaim.Proof memory proof) private {
        HookProofValidation.validateRegistration(proof, _cca);
        bytes32 identifier = _verifyProof(user, step, proof);
        _registrations[user] = Registration({active: true, fromStep: uint64(step)});
        emit Registered(step, user);
        emit ProofVerified(user, step, identifier);
    }

    /// @dev Bid proofs are single-use and never register the wallet.
    function _consumeBidProof(address user, uint256 step, Reclaim.Proof memory proof, uint128 amount) private {
        HookProofValidation.validateBid(proof, _cca, step, amount, BID_PROOF_MAX_AGE);
        bytes32 identifier = _verifyProof(user, step, proof);
        if (_consumedBidProofs[identifier]) revert ProofAlreadyUsed(identifier);
        _consumedBidProofs[identifier] = true;
        emit ProofVerified(user, step, identifier);
    }

    function _verifyProof(address user, uint256 step, Reclaim.Proof memory proof) private returns (bytes32) {
        string memory context = proof.claimInfo.context;
        address subject = StringUtils.str2address(Claims.extractFieldFromContext(context, '"contextAddress":"'));
        if (subject != user) revert ContextAddressMismatch(user, subject);
        bytes32 providerHash = StringUtils.str2bytes32(Claims.extractFieldFromContext(context, '"providerHash":"'));
        _requireProvider(step, providerHash);
        _claimIdentity(user, step, providerHash, context);
        ReclaimProofVerifier.verifyProof(reclaim, proof);
        return proof.signedClaim.claim.identifier;
    }

    function _requireProvider(uint256 step, bytes32 providerHash) private view {
        bytes32[] storage providers = _gates[step].providers;
        if (providers.length == 0) revert ProviderNotFound(step, bytes32(0));
        for (uint256 i; i < providers.length; ++i) {
            if (providers[i] == providerHash) return;
        }
        revert ProviderHashMismatch(providers[0], providerHash);
    }

    /// @dev One real-world account registers one wallet. The identity is the namespace assigned to the
    ///      provider hash plus the signed extractedParameters, so recipes in a namespace share one lock.
    function _claimIdentity(address user, uint256 step, bytes32 providerHash, string memory context) private {
        string memory namespace = _identityProviderByHash[providerHash];
        if (bytes(namespace).length == 0) revert IdentityProviderMissing(providerHash);
        string memory signedNamespace = Claims.extractFieldFromContext(context, '"identityProvider":"');
        if (keccak256(bytes(signedNamespace)) != keccak256(bytes(namespace))) {
            revert IdentityProviderMismatch(providerHash);
        }
        bytes memory parameters = Claims.extractJsonObjectFromContext(context, '"extractedParameters":');
        if (!Claims.hasNonEmptyStringValues(parameters)) revert EmptyIdentityParameters();

        bytes32 identity = keccak256(abi.encode(namespace, parameters));
        address existing = _identityToUser[identity];
        if (existing == address(0)) {
            _identityToUser[identity] = user;
            emit IdentityClaimed(user, providerHash, identity, step);
        } else if (existing != user) {
            revert IdentityAlreadyClaimed(providerHash, identity, existing);
        }
    }

    function _isRegisteredAt(uint256 step, address user) private view returns (bool) {
        Registration storage registration = _registrations[user];
        return registration.active && registration.fromStep <= step;
    }

    // ─────────────────────────────────────────────────────────
    // Pairing
    // ─────────────────────────────────────────────────────────

    /// @notice Pair with a CCA once and cache its schedule. Later calls are no-ops.
    function setCCA(address _newCCA) external onlyOwner {
        if (_newCCA == address(0)) revert ZeroAddress();
        if (_cca != address(0)) return;
        _cca = _newCCA;
        BlockRange[] memory ranges = HookStepSchedule.read(_newCCA);
        for (uint256 i; i < ranges.length; ++i) {
            _steps.push(ranges[i]);
        }
        emit CCASet(_newCCA);
    }

    /// @notice Reverts once `stepIndex` has started. Lead a multicall() with it so a late-mined batch reverts.
    function requireStepNotStarted(uint256 stepIndex) external view {
        _requireStepNotStarted(stepIndex);
    }

    function _currentStep() private view returns (bool inStep, uint256 step) {
        uint256 count = _steps.length;
        if (count == 0) return (false, 0);
        uint64 current = uint64(_getBlockNumberish());
        if (current < _steps[0].startBlock || current >= _steps[count - 1].endBlock) return (false, 0);
        uint256 lo;
        uint256 hi = count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (current >= _steps[mid].startBlock) lo = mid;
            else hi = mid - 1;
        }
        return (true, lo);
    }

    function _requirePaired() private view {
        if (_steps.length == 0) revert NoCCA();
    }

    function _requireStep(uint256 stepIndex) private view {
        _requirePaired();
        if (stepIndex >= _steps.length) revert StepIndexOutOfBounds(stepIndex);
    }

    function _requireStepNotStarted(uint256 stepIndex) private view {
        _requireStep(stepIndex);
        if (_getBlockNumberish() >= _steps[stepIndex].startBlock) revert StepAlreadyStarted(stepIndex);
    }

    // ─────────────────────────────────────────────────────────
    // Step gates
    // ─────────────────────────────────────────────────────────

    /// @notice Enable enforcement for a step and set its providers (empty = no proof gate).
    function enableStep(uint256 _stepIndex, bytes32[] calldata _providerHashes, string[] calldata _providerIds)
        external
        onlyOwner
    {
        _enableStep(_stepIndex, _providerHashes, _providerIds);
    }

    function enableStepBatch(
        uint256[] calldata _stepIndices,
        bytes32[][] calldata _providerHashes,
        string[][] calldata _providerIds
    ) external onlyOwner {
        _requirePaired();
        _requireSameLength(_stepIndices.length, _providerHashes.length, _providerIds.length);
        for (uint256 i; i < _stepIndices.length; ++i) {
            _enableStep(_stepIndices[i], _providerHashes[i], _providerIds[i]);
        }
    }

    /// @notice Disable enforcement for a step and clear its verify-every-bid flag.
    function disableStep(uint256 _stepIndex) external onlyOwner {
        _disableStep(_stepIndex);
    }

    function disableStepBatch(uint256[] calldata _stepIndices) external onlyOwner {
        _requirePaired();
        for (uint256 i; i < _stepIndices.length; ++i) {
            _disableStep(_stepIndices[i]);
        }
    }

    /// @notice Replace a step's providers (empty = no proof gate).
    function setStepProviders(uint256 _stepIndex, bytes32[] calldata _providerHashes, string[] calldata _providerIds)
        external
        onlyOwner
    {
        _requireStep(_stepIndex);
        _setProviders(_stepIndex, _providerHashes, _providerIds);
    }

    function setStepProvidersBatch(
        uint256[] calldata _stepIndices,
        bytes32[][] calldata _providerHashes,
        string[][] calldata _providerIds
    ) external onlyOwner {
        _requirePaired();
        _requireSameLength(_stepIndices.length, _providerHashes.length, _providerIds.length);
        for (uint256 i; i < _stepIndices.length; ++i) {
            _requireStep(_stepIndices[i]);
            _setProviders(_stepIndices[i], _providerHashes[i], _providerIds[i]);
        }
    }

    /// @notice Append one provider per entry to the given steps.
    function addStepProviders(
        uint256[] calldata _stepIndices,
        bytes32[] calldata _providerHashes,
        string[] calldata _providerIds
    ) external onlyOwner {
        _requirePaired();
        _requireSameLength(_stepIndices.length, _providerHashes.length, _providerIds.length);
        for (uint256 i; i < _stepIndices.length; ++i) {
            _requireStep(_stepIndices[i]);
            _gates[_stepIndices[i]].providers.push(_providerHashes[i]);
            emit StepProviderSet(_stepIndices[i], _providerHashes[i], _providerIds[i]);
        }
    }

    /// @notice Remove one provider per entry from the given steps.
    function removeStepProviders(uint256[] calldata _stepIndices, bytes32[] calldata _providerHashes)
        external
        onlyOwner
    {
        _requirePaired();
        _requireSameLength(_stepIndices.length, _providerHashes.length, _providerHashes.length);
        for (uint256 i; i < _stepIndices.length; ++i) {
            _requireStep(_stepIndices[i]);
            _removeProvider(_stepIndices[i], _providerHashes[i]);
            emit StepProviderRemoved(_stepIndices[i], _providerHashes[i]);
        }
    }

    function enableStepPermit(uint256 _stepIndex) external onlyOwner {
        _requireStep(_stepIndex);
        _gates[_stepIndex].permit = true;
        emit StepPermitEnabled(_stepIndex);
    }

    function disableStepPermit(uint256 _stepIndex) external onlyOwner {
        _requireStep(_stepIndex);
        _gates[_stepIndex].permit = false;
        emit StepPermitDisabled(_stepIndex);
    }

    /// @notice Require a current-step credential on every bid. On only before the step starts and
    ///         while the step is enabled with a proof or permit gate; off at any time.
    function setVerifyEveryBid(uint256 stepIndex, bool required) external onlyOwner {
        if (required) {
            _requireStepNotStarted(stepIndex);
            if (!_hasGate(_gates[stepIndex])) revert NoGateConfigured(stepIndex);
        } else {
            _requireStep(stepIndex);
        }
        _gates[stepIndex].everyBid = required;
        emit VerifyEveryBidSet(stepIndex, required);
    }

    function _enableStep(uint256 stepIndex, bytes32[] calldata providerHashes, string[] calldata providerIds) private {
        _requireStep(stepIndex);
        _gates[stepIndex].enabled = true;
        _setProviders(stepIndex, providerHashes, providerIds);
        emit StepEnabled(stepIndex);
    }

    function _disableStep(uint256 stepIndex) private {
        _requireStep(stepIndex);
        StepGate storage gate = _gates[stepIndex];
        gate.enabled = false;
        if (gate.everyBid) {
            gate.everyBid = false;
            emit VerifyEveryBidSet(stepIndex, false);
        }
        emit StepDisabled(stepIndex);
    }

    function _setProviders(uint256 stepIndex, bytes32[] calldata providerHashes, string[] calldata providerIds)
        private
    {
        _requireSameLength(providerHashes.length, providerIds.length, providerIds.length);
        bytes32[] storage current = _gates[stepIndex].providers;
        for (uint256 i; i < current.length; ++i) {
            if (!_contains(providerHashes, current[i])) emit StepProviderRemoved(stepIndex, current[i]);
        }
        _gates[stepIndex].providers = providerHashes;
        for (uint256 i; i < providerHashes.length; ++i) {
            emit StepProviderSet(stepIndex, providerHashes[i], providerIds[i]);
        }
    }

    function _removeProvider(uint256 stepIndex, bytes32 providerHash) private {
        bytes32[] storage providers = _gates[stepIndex].providers;
        for (uint256 i; i < providers.length; ++i) {
            if (providers[i] != providerHash) continue;
            providers[i] = providers[providers.length - 1];
            providers.pop();
            return;
        }
        revert ProviderNotFound(stepIndex, providerHash);
    }

    function _hasGate(StepGate storage gate) private view returns (bool) {
        return gate.enabled && (gate.providers.length != 0 || gate.permit);
    }

    function _requireSameLength(uint256 a, uint256 b, uint256 c) private pure {
        if (a != b || a != c) revert ArrayLengthMismatch();
    }

    function _contains(bytes32[] calldata haystack, bytes32 needle) private pure returns (bool) {
        for (uint256 i; i < haystack.length; ++i) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    // ─────────────────────────────────────────────────────────
    // Registration, identity and signer
    // ─────────────────────────────────────────────────────────

    /// @notice Clear a user's standing registration. Any valid registration proof registers them again.
    function unregister(address _user) external onlyOwner {
        _requirePaired();
        delete _registrations[_user];
        emit Unregistered(_user);
    }

    function unregisterBatch(address[] calldata _users) external onlyOwner {
        _requirePaired();
        for (uint256 i; i < _users.length; ++i) {
            delete _registrations[_users[i]];
            emit Unregistered(_users[i]);
        }
    }

    /// @notice Permanently assign a provider hash to an identity namespace; reassigning would bypass existing locks.
    function setIdentityProvider(bytes32 providerHash, string calldata identityProvider_) external onlyOwner {
        if (!_isNamespace(bytes(identityProvider_))) revert InvalidIdentityProvider();
        string storage existing = _identityProviderByHash[providerHash];
        if (bytes(existing).length != 0) {
            if (keccak256(bytes(existing)) != keccak256(bytes(identityProvider_))) {
                revert IdentityProviderImmutable(providerHash);
            }
            return;
        }
        _identityProviderByHash[providerHash] = identityProvider_;
        emit IdentityProviderSet(providerHash, identityProvider_);
    }

    /// @notice Release an identity so another wallet may claim it.
    function clearIdentity(bytes32 identityHash) external onlyOwner {
        delete _identityToUser[identityHash];
        emit IdentityCleared(identityHash);
    }

    /// @notice Set the permit signer. address(0) disables every permit.
    function setSigner(address newSigner) external onlyOwner {
        _setSigner(newSigner);
    }

    /// @dev `^[a-z][a-z0-9_]{0,63}$`
    function _isNamespace(bytes memory value) private pure returns (bool) {
        if (value.length == 0 || value.length > 64) return false;
        for (uint256 i; i < value.length; ++i) {
            bytes1 c = value[i];
            bool lower = c >= 0x61 && c <= 0x7a;
            bool digitOrUnderscore = (c >= 0x30 && c <= 0x39) || c == 0x5f;
            if (!(lower || (i != 0 && digitOrUnderscore))) return false;
        }
        return true;
    }

    // ─────────────────────────────────────────────────────────
    // Caps
    // ─────────────────────────────────────────────────────────

    /// @notice Cap the bid price, in Q96. Must sit on the CCA tick grid. 0 removes the cap.
    function setMaxBidPrice(uint256 maxBidPrice_) external onlyOwner {
        if (_cca == address(0)) revert NoCCA();
        if (maxBidPrice_ != 0) {
            uint256 floorPrice = ITickStorage(_cca).floorPrice();
            uint256 tickSpacing = ITickStorage(_cca).tickSpacing();
            if (maxBidPrice_ < floorPrice || (maxBidPrice_ - floorPrice) % tickSpacing != 0) {
                revert PriceNotAlignedToTick();
            }
        }
        _maxBidPrice = maxBidPrice_;
        emit MaxBidPriceSet(maxBidPrice_);
    }

    /// @notice Per-wallet cumulative zk cap at a step, in money-token base units. 0 = no cap.
    function setStepMaxBidAmount(uint256 stepIndex, uint256 amount) external onlyOwner {
        _requireStep(stepIndex);
        _stepMaxBidAmount[stepIndex] = amount;
        emit StepMaxBidAmountSet(stepIndex, amount);
    }

    /// @notice Auction-wide cumulative zk cap, in money-token base units. 0 = no cap. Settable before pairing.
    function setZkGlobalMaxBidAmount(uint256 amount) external onlyOwner {
        _zkGlobalMaxBidAmount = amount;
        emit ZkGlobalMaxBidAmountSet(amount);
    }

    // ─────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IVerifyEveryBidHook
    function authorizesWithoutCredential(uint256 stepIndex, address user) public view returns (bool) {
        if (stepIndex >= _steps.length) return false;
        Access access = _access(_gates[stepIndex], stepIndex, user);
        return access == Access.Open || access == Access.Registered;
    }

    /// @inheritdoc IVerifyEveryBidHook
    function verifiesEveryBid(uint256 stepIndex) public view returns (bool) {
        return _gates[stepIndex].everyBid;
    }

    /// @inheritdoc IGatedValidationHook
    /// @dev End block of the highest gated step, so a gap between gated steps reads as gated.
    function expirationBlock() external view returns (uint256) {
        for (uint256 i = _steps.length; i != 0; --i) {
            StepGate storage gate = _gates[i - 1];
            if (gate.enabled && (gate.providers.length != 0 || gate.permit || gate.everyBid)) {
                return _steps[i - 1].endBlock;
            }
        }
        return 0;
    }

    /// @inheritdoc IUmiaValidationHook
    function isVerified(uint256 _stepIndex, address _user) public view returns (bool) {
        return _stepIndex < _steps.length && _isRegisteredAt(_stepIndex, _user);
    }

    /// @inheritdoc IUmiaValidationHook
    function isStepEnabled(uint256 _stepIndex) public view returns (bool) {
        return _stepIndex < _steps.length && _gates[_stepIndex].enabled;
    }

    /// @inheritdoc IUmiaValidationHook
    function isStepPermitEnabled(uint256 _stepIndex) public view returns (bool) {
        return _stepIndex < _steps.length && _gates[_stepIndex].permit;
    }

    /// @inheritdoc IUmiaValidationHook
    function getStepProviders(uint256 _stepIndex) public view returns (bytes32[] memory) {
        return _gates[_stepIndex].providers;
    }

    /// @inheritdoc IUmiaValidationHook
    function getSteps() external view returns (BlockRange[] memory) {
        return _steps;
    }

    /// @inheritdoc IUmiaValidationHook
    function cca() external view returns (address) {
        return _cca;
    }

    /// @inheritdoc IUmiaValidationHook
    function signer() external view returns (address) {
        return _signer;
    }

    /// @inheritdoc IUmiaValidationHook
    function isPermitNonceUsed(bytes32 nonce) external view returns (bool) {
        return _usedPermits[nonce];
    }

    /// @inheritdoc IMaxBidPriceValidationHook
    function maxBidPrice() external view returns (uint256) {
        return _maxBidPrice;
    }

    /// @inheritdoc IUmiaValidationHook
    function stepMaxBidAmount(uint256 stepIndex) external view returns (uint256) {
        return _stepMaxBidAmount[stepIndex];
    }

    /// @inheritdoc IUmiaValidationHook
    function zkBidTotal(address wallet, uint256 stepIndex) external view returns (uint256) {
        return _zkBidTotal[wallet][stepIndex];
    }

    function zkGlobalMaxBidAmount() external view returns (uint256) {
        return _zkGlobalMaxBidAmount;
    }

    function zkGlobalBidTotal() external view returns (uint256) {
        return _zkGlobalBidTotal;
    }

    function identityProvider(bytes32 providerHash) external view returns (string memory) {
        return _identityProviderByHash[providerHash];
    }

    /// @inheritdoc IUmiaValidationHook
    function identityOwner(bytes32 identityHash) external view returns (address) {
        return _identityToUser[identityHash];
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ValidationHookIntrospection, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || interfaceId == type(IUmiaValidationHook).interfaceId
            || interfaceId == type(IMaxBidPriceValidationHook).interfaceId
            || interfaceId == type(IGatedValidationHook).interfaceId
            || interfaceId == type(IVerifyEveryBidHook).interfaceId;
    }
}
