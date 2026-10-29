// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AuctionStep} from "@continuous-clearing-auction/libraries/StepLib.sol";
import {SSTORE2} from "@solady/utils/SSTORE2.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {Reclaim} from "../../src/reclaim/Reclaim.sol";
import {Claims} from "../../src/reclaim/Claims.sol";

contract MockCCA {
    address private _pointer;
    uint64 private _startBlock;
    uint256 private _floorPrice;
    uint256 private _tickSpacing;

    uint24[] private _mps;
    uint64[] private _starts;
    uint64[] private _ends;

    constructor(bytes memory _stepsData, uint64 startBlock_) {
        _pointer = SSTORE2.write(_stepsData);
        _startBlock = startBlock_;
        _floorPrice = 1000;
        _tickSpacing = 100;

        uint64 cursor = startBlock_;
        for (uint256 i; i < _stepsData.length; i += 8) {
            uint24 mps;
            uint40 blockDelta;
            assembly {
                let packed := shr(192, mload(add(add(_stepsData, 0x20), i)))
                mps := shr(40, packed)
                blockDelta := and(packed, 0xFFFFFFFFFF)
            }
            _mps.push(mps);
            _starts.push(cursor);
            uint64 end = cursor + uint64(blockDelta);
            _ends.push(end);
            cursor = end;
        }
    }

    function pointer() external view returns (address) {
        return _pointer;
    }

    function startBlock() external view returns (uint64) {
        return _startBlock;
    }

    function step() external view returns (AuctionStep memory) {
        for (uint256 i; i < _starts.length; i++) {
            if (block.number >= _starts[i] && block.number < _ends[i]) {
                return AuctionStep({mps: _mps[i], startBlock: _starts[i], endBlock: _ends[i]});
            }
        }
        uint256 last = _starts.length - 1;
        return AuctionStep({mps: _mps[last], startBlock: _starts[last], endBlock: _ends[last]});
    }

    function floorPrice() external view returns (uint256) {
        return _floorPrice;
    }

    function tickSpacing() external view returns (uint256) {
        return _tickSpacing;
    }

    function setFloorPrice(uint256 fp) external {
        _floorPrice = fp;
    }

    function setTickSpacing(uint256 ts) external {
        _tickSpacing = ts;
    }
}

contract StaleMockCCA {
    address private _pointer;
    uint64 private _startBlock;

    uint24[] private _mps;
    uint64[] private _starts;
    uint64[] private _ends;
    uint256 private _currentIdx;

    constructor(bytes memory _stepsData, uint64 startBlock_) {
        _pointer = SSTORE2.write(_stepsData);
        _startBlock = startBlock_;

        uint64 cursor = startBlock_;
        for (uint256 i; i < _stepsData.length; i += 8) {
            uint24 mps;
            uint40 blockDelta;
            assembly {
                let packed := shr(192, mload(add(add(_stepsData, 0x20), i)))
                mps := shr(40, packed)
                blockDelta := and(packed, 0xFFFFFFFFFF)
            }
            _mps.push(mps);
            _starts.push(cursor);
            uint64 end = cursor + uint64(blockDelta);
            _ends.push(end);
            cursor = end;
        }
    }

    function pointer() external view returns (address) {
        return _pointer;
    }

    function startBlock() external view returns (uint64) {
        return _startBlock;
    }

    function step() external view returns (AuctionStep memory) {
        return AuctionStep({mps: _mps[_currentIdx], startBlock: _starts[_currentIdx], endBlock: _ends[_currentIdx]});
    }

    function advanceStep() external {
        if (_currentIdx + 1 < _starts.length) _currentIdx++;
    }

    function floorPrice() external pure returns (uint256) {
        return 1000;
    }

    function tickSpacing() external pure returns (uint256) {
        return 100;
    }
}

/// @dev Shared fixture: a paired hook with a live Reclaim beacon, a permit signer and proof builders.
abstract contract UmiaValidationHookBase is Test {
    UmiaValidationHook hook;
    Reclaim reclaim;
    MockCCA mockCCA;

    address admin = makeAddr("admin");
    address user = makeAddr("user");

    uint256 constant WITNESS_PRIVATE_KEY = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    address witnessAddress;

    uint256 constant SIGNER_PRIVATE_KEY = 0xaabbccdd00112233445566778899aabb00112233445566778899aabbccddeeff;
    address signerAddress;

    bytes32 constant PROVIDER_HASH_1 = 0xc9e2404b50af02ddd8797e218f19b0b2a896cdcd9dbf9ea525b89db2fa37de76;
    bytes32 constant PROVIDER_HASH_2 = 0xaabbccdd00112233445566778899aabbccddeeff00112233445566778899aabb;
    bytes32 constant PROVIDER_HASH_3 = 0x1122334455667788990011223344556677889900112233445566778899001122;

    function _identityProvider(bytes32 hash) internal pure returns (string memory) {
        return hash == PROVIDER_HASH_2 ? "other" : "github";
    }

    function _newHook(address owner_, address reclaim_, address signer_) internal returns (UmiaValidationHook result) {
        result = new UmiaValidationHook(owner_, reclaim_, signer_);
        vm.prank(owner_);
        result.setIdentityProvider(PROVIDER_HASH_1, "github");
        vm.prank(owner_);
        result.setIdentityProvider(PROVIDER_HASH_2, "other");
        vm.prank(owner_);
        result.setIdentityProvider(PROVIDER_HASH_3, "github");
    }

    uint64 step0Start = 100;
    uint64 step0End = 200;

    function _packStep(uint24 mps, uint40 blockDelta) internal pure returns (bytes memory) {
        return abi.encodePacked(mps, blockDelta);
    }

    function _emptyHashes() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _emptyIds() internal pure returns (string[] memory) {
        return new string[](0);
    }

    function _singleHash(bytes32 h) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = h;
    }

    function _singleId(string memory id) internal pure returns (string[] memory arr) {
        arr = new string[](1);
        arr[0] = id;
    }

    function _twoHashes(bytes32 h1, bytes32 h2) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = h1;
        arr[1] = h2;
    }

    function _twoIds(string memory id1, string memory id2) internal pure returns (string[] memory arr) {
        arr = new string[](2);
        arr[0] = id1;
        arr[1] = id2;
    }

    function _deploySingleStepCCA() internal returns (MockCCA) {
        bytes memory data = _packStep(10_000_000, uint40(step0End - step0Start));
        return new MockCCA(data, step0Start);
    }

    function _deployTwoStepCCA() internal returns (MockCCA) {
        bytes memory data = abi.encodePacked(
            _packStep(5_000_000, 100), // step 0: blocks 100-200
            _packStep(5_000_000, 100) // step 1: blocks 200-300
        );
        return new MockCCA(data, 100);
    }

    function _deployThreeStepCCA() internal returns (MockCCA) {
        bytes memory data = abi.encodePacked(
            _packStep(5_000_000, 100), // step 0: blocks 100-200
            _packStep(5_000_000, 100), // step 1: blocks 200-300
            _packStep(5_000_000, 100) // step 2: blocks 300-400
        );
        return new MockCCA(data, 100);
    }

    function _deployThreeStepHook() internal returns (UmiaValidationHook hook2) {
        hook2 = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deployThreeStepCCA();

        vm.prank(admin);
        hook2.setCCA(address(cca2));
    }

    function _createProofForUser(address _user) internal view returns (bytes memory) {
        return _createProofForUserWithProviderAndAuction(_user, PROVIDER_HASH_1, address(mockCCA));
    }

    function _createProofForUserWithProvider(address _user, bytes32 _providerHash)
        internal
        view
        returns (bytes memory)
    {
        return _createProofForUserWithProviderAndAuction(_user, _providerHash, address(mockCCA));
    }

    function _createProofForUserWithProviderAndAuction(address _user, bytes32 _providerHash, address auction)
        internal
        view
        returns (bytes memory)
    {
        string memory context = string(
            abi.encodePacked(
                '{"contextAddress":"',
                _addressToString(_user),
                '","providerHash":"',
                _bytes32ToHexString(_providerHash),
                '","identityProvider":"',
                _identityProvider(_providerHash),
                '","contextMessage":"register:',
                _uint2str(block.chainid),
                ":",
                _address2str(auction),
                ':nonce","extractedParameters":{"account":"',
                _addressToString(_user),
                '"}}'
            )
        );

        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: _user, timestampS: uint32(vm.getBlockTimestamp()), epoch: 2
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
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        return abi.encode(proof);
    }

    function _createProofForUserWithWrongContext(address _user, address _wrongUser)
        internal
        view
        returns (bytes memory)
    {
        string memory context = string(
            abi.encodePacked(
                '{"contextAddress":"',
                _addressToString(_wrongUser),
                '","providerHash":"0x1234","contextMessage":"register:',
                _uint2str(block.chainid),
                ":",
                _address2str(address(mockCCA)),
                ':nonce"}'
            )
        );

        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: _user, timestampS: uint32(vm.getBlockTimestamp()), epoch: 2
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
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});

        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        return abi.encode(proof);
    }

    function _signServerPermit(address hookAddr, address wallet, uint256 stepIdx, bytes32 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signServerPermitWithAmount(hookAddr, wallet, stepIdx, nonce, deadline, 0);
    }

    function _signServerPermitWithAmount(
        address hookAddr,
        address wallet,
        uint256 stepIdx,
        bytes32 nonce,
        uint256 deadline,
        uint128 amount
    ) internal view returns (bytes memory) {
        bytes32 DOMAIN_TYPEHASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 SERVER_PERMIT_TYPEHASH =
            keccak256("ServerPermit(address wallet,uint256 step,bytes32 nonce,uint256 deadline,uint128 amount)");
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("UmiaValidationHook"), keccak256("1"), block.chainid, hookAddr)
        );
        bytes32 structHash = keccak256(abi.encode(SERVER_PERMIT_TYPEHASH, wallet, stepIdx, nonce, deadline, amount));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _encodePermitHookData(uint256 stepIdx, bytes32 nonce, uint256 deadline, bytes memory signature)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(uint8(0x01), abi.encode(stepIdx, nonce, deadline, signature));
    }

    function setUp() public {
        witnessAddress = vm.addr(WITNESS_PRIVATE_KEY);
        signerAddress = vm.addr(SIGNER_PRIVATE_KEY);

        reclaim = new Reclaim();
        Reclaim.Witness[] memory witnesses = new Reclaim.Witness[](1);
        witnesses[0] = Reclaim.Witness({addr: witnessAddress, host: "wss://test.example.com"});
        reclaim.addNewEpoch(witnesses, 1);

        hook = _newHook(admin, address(reclaim), address(0));
        vm.warp(block.timestamp + 1);
        mockCCA = _deploySingleStepCCA();

        vm.startPrank(admin);
        hook.setCCA(address(mockCCA));
        hook.enableStep(0, _singleHash(PROVIDER_HASH_1), _singleId("test-provider"));
        vm.stopPrank();
    }

    function _deployStaleTwoStepCCA() internal returns (StaleMockCCA) {
        bytes memory data = abi.encodePacked(
            _packStep(5_000_000, 100), // step 0: blocks 100-200
            _packStep(5_000_000, 100) // step 1: blocks 200-300
        );
        return new StaleMockCCA(data, 100);
    }

    function _setupServerPermit() internal returns (UmiaValidationHook h) {
        h = new UmiaValidationHook(admin, address(reclaim), signerAddress);
        vm.warp(block.timestamp + 1);
        MockCCA cca2 = _deploySingleStepCCA();

        vm.startPrank(admin);
        h.setCCA(address(cca2));
        h.enableStep(0, _emptyHashes(), _emptyIds());
        h.enableStepPermit(0);
        vm.stopPrank();
    }

    function _addressToString(address _addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint256(uint8(bytes20(_addr)[i] >> 4))];
            str[3 + i * 2] = alphabet[uint256(uint8(bytes20(_addr)[i] & 0x0f))];
        }
        return string(str);
    }

    function _bytes2str(bytes memory buffer) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 + buffer.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < buffer.length; i++) {
            str[2 + i * 2] = alphabet[uint8(buffer[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(buffer[i] & 0x0f)];
        }
        return string(str);
    }

    function _address2str(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2 ** (8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 + 2 * i] = _char(hi);
            s[3 + 2 * i] = _char(lo);
        }
        return string(s);
    }

    function _char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function _bytes32ToHexString(bytes32 _data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[uint8(_data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(_data[i] & 0x0f)];
        }
        return string(str);
    }

    function _createProofWithIdentity(address _user, bytes32 _providerHash, string memory _extractedParameters)
        internal
        view
        returns (bytes memory)
    {
        return _createProofWithIdentityForAuction(_user, _providerHash, _extractedParameters, address(mockCCA));
    }

    function _createProofWithIdentityForAuction(
        address _user,
        bytes32 _providerHash,
        string memory _extractedParameters,
        address auction
    ) internal view returns (bytes memory) {
        string memory context = string(
            abi.encodePacked(
                '{"contextAddress":"',
                _addressToString(_user),
                '","providerHash":"',
                _bytes32ToHexString(_providerHash),
                '","identityProvider":"',
                _identityProvider(_providerHash),
                '","contextMessage":"register:',
                _uint2str(block.chainid),
                ":",
                _address2str(auction),
                ":nonce",
                '","extractedParameters":',
                _extractedParameters,
                "}"
            )
        );

        Claims.ClaimInfo memory claimInfo =
            Claims.ClaimInfo({provider: "test-provider", parameters: "test-params", context: context});

        bytes32 identifier = Claims.hashClaimInfo(claimInfo);

        Claims.CompleteClaimData memory claimData = Claims.CompleteClaimData({
            identifier: identifier, owner: _user, timestampS: uint32(vm.getBlockTimestamp()), epoch: 2
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
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;

        Claims.SignedClaim memory signedClaim = Claims.SignedClaim({claim: claimData, signatures: signatures});
        Reclaim.Proof memory proof = Reclaim.Proof({claimInfo: claimInfo, signedClaim: signedClaim});

        return abi.encode(proof);
    }

    function _expectedIdentityHash(bytes32 providerHash, string memory extractedParameters)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_identityProvider(providerHash), bytes(extractedParameters)));
    }

    uint256 constant ZK_CAP = 1_000e6; // 1,000 USDC, money-token base units

    /// @dev Builds inline-proof hookData: abi.encodePacked(uint256 proofStep, abi.encode(Reclaim.Proof)).
    function _inlineProof(uint256 proofStep, address _user) internal view returns (bytes memory) {
        return abi.encodePacked(proofStep, _createProofForUser(_user));
    }

    /// @dev Registers `_user` the only way the hook allows: an inline proof on a bid at `step`.
    ///      Rolls into the step first; a zero amount leaves the zk totals untouched.
    function _register(UmiaValidationHook h, address _user, uint256 step, bytes memory proof) internal {
        uint64 start = h.getSteps()[step].startBlock;
        if (block.number < start) vm.roll(start);
        vm.prank(h.cca());
        h.validate(0, 0, _user, _user, abi.encodePacked(step, proof));
    }

    uint256 constant ZK_GLOBAL_CAP = 2_000e6; // 2,000 USDC, money-token base units
}
