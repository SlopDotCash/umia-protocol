// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IUmiaHub} from "../src/interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../src/interfaces/IUmiaMarketCore.sol";
import {IVenture} from "../src/interfaces/IVenture.sol";

/// @title ProtocolState
/// @notice The reads that must be identical before and after any protocol upgrade, as labeled
///         digests, plus the contracts.json lookup both the upgrade scripts and the fork tests use.
library ProtocolState {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Newest ventures and markets sampled; older ones share the same implementation.
    uint256 internal constant SAMPLE = 25;

    struct Snapshot {
        string[] labels;
        bytes32[] digests;
    }

    /// @dev `UMIA_HUB_ADDRESS` skips the file read, for checkouts without the monorepo's contracts.json.
    function hubFromContractsJson(string memory env, string memory chain) internal view returns (IUmiaHub) {
        address hubOverride = vm.envOr("UMIA_HUB_ADDRESS", address(0));
        if (hubOverride != address(0)) return IUmiaHub(hubOverride);
        require(bytes(env).length != 0 && bytes(chain).length != 0, "set UMIA_ENV and UMIA_CHAIN, or UMIA_HUB_ADDRESS");
        string memory json = vm.readFile("../contracts.json");
        return IUmiaHub(vm.parseJsonAddress(json, string.concat('$["', env, '"]["', chain, '"]["umia"]["hub"]')));
    }

    function implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function snapshot(IUmiaHub hub) internal view returns (Snapshot memory s) {
        IUmiaMarketCore core = IUmiaMarketCore(hub.umiaMarketCore());
        (uint256 ventureFrom, uint256 ventureTo) = _sample(hub.ventureCount());
        (uint256 marketFrom, uint256 marketTo) =
            address(core) == address(0) ? (uint256(1), uint256(0)) : _sample(core.marketCounter());
        (string[] memory hubNames, bytes[] memory hubCalls) = _hubFields();

        uint256 n = hubNames.length + 1 + (ventureTo + 1 - ventureFrom) + (marketTo + 1 - marketFrom);
        s.labels = new string[](n);
        s.digests = new bytes32[](n);
        uint256 i;
        // Getters can be added or renamed by the very upgrade being rehearsed, so hub fields are
        // read tolerantly and compared on the intersection of both snapshots (requireUnchanged).
        for (uint256 f = 0; f < hubCalls.length; f++) {
            (bool ok, bytes memory ret) = address(hub).staticcall(hubCalls[f]);
            if (!ok || ret.length != 32) continue;
            s.labels[i] = string.concat("hub.", hubNames[f]);
            s.digests[i++] = keccak256(ret);
        }
        s.labels[i] = "market core";
        s.digests[i++] = address(core) == address(0) ? bytes32(0) : _core(core);
        for (uint256 id = ventureFrom; id <= ventureTo; id++) {
            s.labels[i] = string.concat("venture #", vm.toString(id));
            s.digests[i++] = _venture(hub, core, id);
        }
        for (uint256 id = marketFrom; id <= marketTo; id++) {
            s.labels[i] = string.concat("market #", vm.toString(id));
            s.digests[i++] = _market(core, id);
        }
        assembly {
            mstore(mload(s), i)
            mstore(mload(add(s, 0x20)), i)
        }
    }

    /// @dev Labels present in both snapshots must match. A hub field missing afterwards is a
    ///      removed or renamed getter, not corruption (the storage-compat check owns the slots);
    ///      any other label must survive.
    function requireUnchanged(Snapshot memory before, Snapshot memory after_, string memory context) internal pure {
        for (uint256 i = 0; i < before.labels.length; i++) {
            (bool found, bytes32 digest) = _find(after_, before.labels[i]);
            if (!found) {
                require(
                    _startsWith(before.labels[i], "hub."),
                    string.concat(context, ": ", before.labels[i], " missing after upgrade")
                );
                continue;
            }
            require(digest == before.digests[i], string.concat(context, ": ", before.labels[i], " reads changed"));
        }
    }

    function _find(Snapshot memory s, string memory label) private pure returns (bool, bytes32) {
        bytes32 needle = keccak256(bytes(label));
        for (uint256 i = 0; i < s.labels.length; i++) {
            if (keccak256(bytes(s.labels[i])) == needle) return (true, s.digests[i]);
        }
        return (false, bytes32(0));
    }

    function _startsWith(string memory str, string memory prefix) private pure returns (bool) {
        bytes memory a = bytes(str);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _hubFields() private pure returns (string[] memory names, bytes[] memory calls) {
        names = new string[](22);
        calls = new bytes[](22);
        uint256 i;
        (names[i], calls[i++]) = ("owner", abi.encodeCall(IUmiaHub.owner, ()));
        (names[i], calls[i++]) = ("ventureCount", abi.encodeCall(IUmiaHub.ventureCount, ()));
        (names[i], calls[i++]) = ("umiaMarketCore", abi.encodeCall(IUmiaHub.umiaMarketCore, ()));
        (names[i], calls[i++]) = ("ventureBeacon", abi.encodeCall(IUmiaHub.ventureBeacon, ()));
        (names[i], calls[i++]) = ("defaultGovernanceExecutor", abi.encodeCall(IUmiaHub.defaultGovernanceExecutor, ()));
        (names[i], calls[i++]) = ("conditionalMarketOracle", abi.encodeCall(IUmiaHub.conditionalMarketOracle, ()));
        (names[i], calls[i++]) = ("umiaMarketStake", abi.encodeCall(IUmiaHub.umiaMarketStake, ()));
        (names[i], calls[i++]) = ("lbpStrategyFactory", abi.encodeCall(IUmiaHub.lbpStrategyFactory, ()));
        (names[i], calls[i++]) = ("ccaFactory", abi.encodeCall(IUmiaHub.ccaFactory, ()));
        (names[i], calls[i++]) = ("marketCreationSigner", abi.encodeCall(IUmiaHub.marketCreationSigner, ()));
        (names[i], calls[i++]) = ("protocolFeeRecipient", abi.encodeCall(IUmiaHub.protocolFeeRecipient, ()));
        (names[i], calls[i++]) = ("vetoGuardian", abi.encodeCall(IUmiaHub.vetoGuardian, ()));
        (names[i], calls[i++]) = ("vestingAdmin", abi.encodeCall(IUmiaHub.vestingAdmin, ()));
        (names[i], calls[i++]) = ("winningMarketThresholdBps", abi.encodeCall(IUmiaHub.winningMarketThresholdBps, ()));
        (names[i], calls[i++]) =
        ("decisionMarketExecutionDelay", abi.encodeCall(IUmiaHub.decisionMarketExecutionDelay, ()));
        (names[i], calls[i++]) = ("spotSwapFeeBps", abi.encodeCall(IUmiaHub.spotSwapFeeBps, ()));
        (names[i], calls[i++]) = ("spotProtocolFeeCutBps", abi.encodeCall(IUmiaHub.spotProtocolFeeCutBps, ()));
        (names[i], calls[i++]) = ("decisionSwapFeeBps", abi.encodeCall(IUmiaHub.decisionSwapFeeBps, ()));
        (names[i], calls[i++]) = ("decisionProtocolFeeCutBps", abi.encodeCall(IUmiaHub.decisionProtocolFeeCutBps, ()));
        (names[i], calls[i++]) = ("defaultPoolTickSpacing", abi.encodeCall(IUmiaHub.defaultPoolTickSpacing, ()));
        (names[i], calls[i++]) = ("migrationDelayBlocks", abi.encodeCall(IUmiaHub.migrationDelayBlocks, ()));
        (names[i], calls[i++]) = ("sweepDelayBlocks", abi.encodeCall(IUmiaHub.sweepDelayBlocks, ()));
    }

    function _sample(uint256 count) private pure returns (uint256 from, uint256 to) {
        if (count == 0) return (1, 0);
        return (count > SAMPLE ? count - SAMPLE + 1 : 1, count);
    }

    function _core(IUmiaMarketCore core) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(core.HUB()),
                core.DOMAIN_SEPARATOR(),
                core.marketCounter(),
                core.proposalCounter(),
                core.activeUnsettledMarketCount()
            )
        );
    }

    function _venture(IUmiaHub hub, IUmiaMarketCore core, uint256 id) private view returns (bytes32) {
        IUmiaHub.VentureInfo memory info = hub.ventureById(id);
        address moneyToken = hub.ventureMoneyTokenById(id);
        bytes32 registry = keccak256(
            abi.encode(
                info,
                hub.ventureTokenById(id),
                moneyToken,
                hub.approvedMoneyTokens(moneyToken),
                hub.governanceExecutor(info.venture),
                hub.ventureLiquidityVault(info.venture),
                address(core) == address(0) ? 0 : core.activeMarketByVenture(id)
            )
        );
        return keccak256(abi.encode(registry, _treasury(IVenture(info.venture), moneyToken)));
    }

    function _treasury(IVenture venture, address moneyToken) private view returns (bytes32) {
        (uint256 allowance, uint256 spent, uint256 month) = venture.monthlyAllowance(moneyToken);
        bytes32 config = keccak256(
            abi.encode(
                implementationOf(address(venture)),
                venture.HUB(),
                venture.token(),
                venture.moneyToken(),
                venture.lbp(),
                venture.minMarketStake(),
                venture.documentCount()
            )
        );
        return keccak256(
            abi.encode(
                config,
                allowance,
                spent,
                month,
                venture.tradingPauseDuration(),
                venture.tradingPauseDeadline(),
                venture.liquidationActive(),
                venture.authorizedLiquidator()
            )
        );
    }

    function _market(IUmiaMarketCore core, uint256 id) private view returns (bytes32) {
        uint256[] memory proposals = core.marketProposalIds(id);
        bytes32 digest =
            keccak256(abi.encode(core.getMarketStatus(id), core.marketSettled(id), core.marketExecuted(id), proposals));
        for (uint256 i = 0; i < proposals.length; i++) {
            digest = keccak256(abi.encode(digest, _proposal(core, proposals[i])));
        }
        return digest;
    }

    function _proposal(IUmiaMarketCore core, uint256 id) private view returns (bytes32) {
        (uint256 reserve0, uint256 reserve1) = core.cpmmStates(id);
        (uint256 ventureFee, uint256 moneyFee) = core.proposalFeeState(id);
        return keccak256(
            abi.encode(
                core.proposalToMarket(id),
                reserve0,
                reserve1,
                ventureFee,
                moneyFee,
                core.totalSupply(core.getVirtualVentureId(id)),
                core.totalSupply(core.getVirtualMoneyId(id)),
                core.totalSupply(core.getLiquidityShareId(id)),
                core.userVirtualVentureSupply(id),
                core.userVirtualMoneySupply(id)
            )
        );
    }
}
