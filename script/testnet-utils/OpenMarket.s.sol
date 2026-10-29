// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AtomicMarketOpener} from "./AtomicMarketOpener.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";

interface IERC20T {
    function transfer(address, uint256) external returns (bool);
}

interface IMarketCoreNonce {
    function marketCreationNonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice **Testnet utility.** Deploy the atomic opener, fund it, sign the market-creation
///         approval for it as creator, and open a decision market past the SpotLiquidityVault
///         deviation guard — in one broadcast.
///
///         Env: HUB, POOL_MANAGER, HOOK, DEPLOYER_PRIVATE_KEY, MARKET_CREATION_SIGNER_KEY,
///         VENTURE_ID, MARKET_TITLE, and comma-delimited PROPOSAL_TITLES (>= 2). Optional:
///         PROPOSAL_PAYLOADS (comma-delimited hex, one per title, "0x" for an informational
///         proposal; omit to make all informational), TRADING_DURATION (seconds, 0 = protocol
///         default), PIN_FUNDING (venture-token base units to cover the pin swap + stake,
///         default 20_000e18).
contract OpenMarket is Script {
    bytes32 constant TYPEHASH = keccak256(
        "CreateMarketApproval(address creator,uint256 ventureId,bytes32 titleHash,uint256 startTimestamp,uint256 duration,bytes32 proposalsHash,uint256 nonce)"
    );

    function run() external {
        address hub = vm.envAddress("HUB");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK");
        uint256 ventureId = vm.envUint("VENTURE_ID");
        string memory title = vm.envString("MARKET_TITLE");
        uint256 duration = vm.envOr("TRADING_DURATION", uint256(0));
        uint256 pinFunding = vm.envOr("PIN_FUNDING", uint256(20_000e18));

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 signerKey = vm.envUint("MARKET_CREATION_SIGNER_KEY");

        IUmiaMarketCore.CreateProposalParams[] memory proposals = _readProposals();
        address ventureToken = IUmiaHub(hub).ventureTokenById(ventureId);
        address marketCore = IUmiaHub(hub).umiaMarketCore();

        vm.startBroadcast(deployerKey);

        AtomicMarketOpener opener = new AtomicMarketOpener(hub, poolManager, hook);
        console2.log("opener deployed:", address(opener));

        IERC20T(ventureToken).transfer(address(opener), pinFunding);

        uint256 startTs = block.timestamp;
        uint256 nonce = IMarketCoreNonce(marketCore).marketCreationNonces(address(opener));
        bytes memory signature =
            _sign(signerKey, marketCore, address(opener), ventureId, title, startTs, duration, proposals, nonce);

        AtomicMarketOpener.RunParams memory rp = AtomicMarketOpener.RunParams({
            ventureId: ventureId,
            title: title,
            startTimestamp: startTs,
            duration: duration,
            proposals: proposals,
            nonce: nonce,
            signature: signature
        });

        uint256 marketId = opener.run(rp);
        console2.log("MARKET CREATED, id:", marketId);

        vm.stopBroadcast();
    }

    /// @dev Read PROPOSAL_TITLES (required, comma-delimited) and PROPOSAL_PAYLOADS (optional,
    ///      comma-delimited hex aligned 1:1). A missing/short payload list makes proposals
    ///      informational (empty payload).
    function _readProposals() internal view returns (IUmiaMarketCore.CreateProposalParams[] memory proposals) {
        string[] memory titles = vm.envString("PROPOSAL_TITLES", ",");
        require(titles.length >= 2, "need >= 2 PROPOSAL_TITLES");
        bytes[] memory payloads = vm.envOr("PROPOSAL_PAYLOADS", ",", new bytes[](0));

        proposals = new IUmiaMarketCore.CreateProposalParams[](titles.length);
        for (uint256 i = 0; i < titles.length; i++) {
            proposals[i] = IUmiaMarketCore.CreateProposalParams({
                title: titles[i], executionPayload: i < payloads.length ? payloads[i] : bytes("")
            });
        }
    }

    function _sign(
        uint256 signerKey,
        address marketCore,
        address creator,
        uint256 ventureId,
        string memory title,
        uint256 startTs,
        uint256 duration,
        IUmiaMarketCore.CreateProposalParams[] memory proposals,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                creator,
                ventureId,
                keccak256(bytes(title)),
                startTs,
                duration,
                keccak256(abi.encode(proposals)),
                nonce
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IMarketCoreNonce(marketCore).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
