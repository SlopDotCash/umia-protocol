// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolState} from "./ProtocolState.sol";
import {GovernanceExecutor} from "../src/core/GovernanceExecutor.sol";
import {IGovernanceExecutor} from "../src/interfaces/IGovernanceExecutor.sol";
import {IUmiaHub} from "../src/interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../src/interfaces/IUmiaMarketCore.sol";
import {IVenture} from "../src/interfaces/IVenture.sol";

/// @title SwapGovernanceExecutor
/// @notice `just forge-swap-executor <env> <chain>`. The GovernanceExecutor is not upgradeable, so a
///         new action type ships as a new executor behind `hub.setDefaultGovernanceExecutor`.
///
///         1. deploy `new GovernanceExecutor(hub)` from DEPLOYER_PRIVATE_KEY
///         2. rehearse the swap in the fork as the hub owner: every venture resolves to the new
///            executor, no venture carries a per-venture override, every unexecuted proposal
///            payload still validates, the old executor can no longer execute
///         3. EXECUTE_UPGRADE=true and the deployer owns the hub: broadcast the swap and re-check;
///            otherwise print the exact calldata the owner must send
///
///         Environment: UMIA_ENV, UMIA_CHAIN, EXECUTE_UPGRADE (default false), and either
///         DEPLOYER_PRIVATE_KEY or a hardware wallet via forge's --ledger/--trezor flags with
///         DEPLOYER_ADDRESS set to the signer.
contract SwapGovernanceExecutor is Script {
    struct SwapConfig {
        uint256 deployerKey;
        IUmiaHub hub;
        bool execute;
    }

    struct Plan {
        address hub;
        address owner;
        address previousExecutor;
        address newExecutor;
        bytes data;
        uint256 ventures;
        uint256 pendingProposals;
        bool executed;
    }

    function run() external returns (Plan memory) {
        return swap(
            SwapConfig({
                // Zero key = hardware wallet mode: the signer comes from the forge CLI wallet
                // flags (--ledger/--trezor) and the address from DEPLOYER_ADDRESS.
                deployerKey: vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0)),
                hub: ProtocolState.hubFromContractsJson(
                    vm.envOr("UMIA_ENV", string("")), vm.envOr("UMIA_CHAIN", string(""))
                ),
                execute: vm.envOr("EXECUTE_UPGRADE", false)
            })
        );
    }

    function swap(SwapConfig memory cfg) public returns (Plan memory plan) {
        address deployer = _deployer(cfg.deployerKey);
        plan.hub = address(cfg.hub);
        plan.owner = cfg.hub.owner();
        plan.previousExecutor = cfg.hub.defaultGovernanceExecutor();

        console.log("== Swap GovernanceExecutor ==");
        console.log("hub:              ", plan.hub);
        console.log("owner:            ", plan.owner);
        console.log("deployer:         ", deployer);
        console.log("live executor:    ", plan.previousExecutor);

        _startBroadcast(cfg.deployerKey);
        plan.newExecutor = address(new GovernanceExecutor(plan.hub));
        vm.stopBroadcast();
        console.log("new executor:     ", plan.newExecutor);

        require(address(GovernanceExecutor(plan.newExecutor).HUB()) == plan.hub, "new executor points at another hub");
        require(plan.newExecutor.codehash != plan.previousExecutor.codehash, "new executor has the live bytecode");

        plan.data = abi.encodeCall(IUmiaHub.setDefaultGovernanceExecutor, (plan.newExecutor));
        (plan.ventures, plan.pendingProposals) = _rehearse(cfg.hub, plan);

        if (cfg.execute) {
            require(plan.owner == deployer, "EXECUTE_UPGRADE set but the deployer is not the hub owner");
            _startBroadcast(cfg.deployerKey);
            (bool ok,) = plan.hub.call(plan.data);
            vm.stopBroadcast();
            require(ok, "swap reverted");
            _verify(cfg.hub, plan);
            plan.executed = true;
            console.log("swap executed; default executor:", plan.newExecutor);
        } else {
            _logHandoff(plan);
        }

        console.log("\n== Record in contracts.json[env][chain].umia ==");
        console.log("governanceExecutor:", plan.newExecutor);
        console.log("indexer: keep", plan.previousExecutor, "listed next to the new address so history stays indexed");
    }

    /// @dev A zero key means hardware-wallet mode: the CLI wallet flags carry the signer.
    function _deployer(uint256 deployerKey) internal returns (address) {
        if (deployerKey != 0) return vm.addr(deployerKey);
        return vm.envAddress("DEPLOYER_ADDRESS");
    }

    function _startBroadcast(uint256 deployerKey) internal {
        if (deployerKey != 0) vm.startBroadcast(deployerKey);
        else vm.startBroadcast();
    }

    function _rehearse(IUmiaHub hub, Plan memory plan) internal returns (uint256 ventures, uint256 pending) {
        uint256 snapshot = vm.snapshotState();

        vm.prank(plan.owner);
        (bool ok, bytes memory ret) = plan.hub.call(plan.data);
        require(ok, string.concat("rehearsal: swap reverted: ", vm.toString(ret)));
        (ventures, pending) = _verify(hub, plan);

        vm.revertToState(snapshot);
        console.log("rehearsal: swap succeeds as owner");
        console.log("  ventures resolving to the new executor:", ventures);
        console.log("  unexecuted proposals re-validated:      ", pending);
    }

    /// @dev Invariants that must hold once the hub points at the new executor.
    function _verify(IUmiaHub hub, Plan memory plan) internal view returns (uint256 ventures, uint256 pending) {
        require(hub.defaultGovernanceExecutor() == plan.newExecutor, "default executor not updated");

        // Bounded so a registry with thousands of ventures cannot stall the rehearsal; raise
        // MAX_VENTURE_SCAN when the registry outgrows it rather than letting the scan run unbounded.
        uint256 maxScan = vm.envOr("MAX_VENTURE_SCAN", uint256(1024));
        uint256 overrides;
        for (uint256 id = 1; id <= maxScan; id++) {
            IUmiaHub.VentureInfo memory info = hub.ventureById(id);
            if (info.venture == address(0)) break;
            ventures++;
            if (hub.governanceExecutorByVenture(info.venture) != address(0)) {
                overrides++;
                console.log("  WARNING: venture keeps a per-venture executor override:", info.venture);
                continue;
            }
            require(
                hub.governanceExecutor(info.venture) == plan.newExecutor,
                string.concat("venture ", vm.toString(id), " does not resolve to the new executor")
            );
        }
        if (ventures == 0) {
            // A fresh chain legitimately has no ventures yet; require an explicit opt-in so the
            // empty registry still fails closed on established chains (wrong env/chain guard).
            require(
                vm.envOr("ALLOW_EMPTY_REGISTRY", false),
                "hub registry is empty; set ALLOW_EMPTY_REGISTRY=true for a fresh chain"
            );
            console.log("  WARNING: hub registry is empty; per-venture executor checks skipped");
        }
        require(ventures < maxScan, "venture scan hit MAX_VENTURE_SCAN; raise it and re-run");
        require(
            overrides == 0,
            "ventures carry per-venture executor overrides; clear them with setVentureGovernanceExecutor(id, address(0)) and re-run"
        );

        IUmiaMarketCore core = IUmiaMarketCore(hub.umiaMarketCore());
        uint256 markets = core.marketCounter();
        require(markets <= maxScan, "market count exceeds MAX_VENTURE_SCAN; raise it and re-run");
        for (uint256 marketId = 1; marketId <= markets; marketId++) {
            if (core.marketExecuted(marketId)) continue;
            uint256[] memory proposals = core.marketProposalIds(marketId);
            for (uint256 i = 0; i < proposals.length; i++) {
                bytes memory payload = core.proposalExecutionPayload(proposals[i]);
                if (payload.length == 0) continue;
                (bool ok,) = plan.newExecutor.staticcall(abi.encodeCall(IGovernanceExecutor.validatePayload, (payload)));
                require(ok, string.concat("proposal ", vm.toString(proposals[i]), " no longer validates"));
                pending++;
            }
        }
    }

    function _logHandoff(Plan memory plan) internal view {
        console.log("\n== Owner action required ==");
        console.log("send to:  ", plan.hub);
        console.log("from:     ", plan.owner);
        console.log("calldata: ", vm.toString(plan.data));

        if (plan.owner.code.length == 0) {
            if (vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0)) != 0) {
                console.log("owner is an EOA: cast send <send to> <calldata> --private-key <owner key>");
            } else {
                string memory hw = vm.envOr("HW_WALLET", string("ledger"));
                console.log(
                    string.concat(
                        "owner is an EOA: cast send <send to> <calldata> --",
                        hw,
                        " --mnemonic-index ",
                        vm.toString(vm.envOr("LEDGER_INDEX", uint256(0)))
                    )
                );
            }
            return;
        }
        (bool isTimelock, bytes memory ret) = plan.owner.staticcall(abi.encodeCall(TimelockController.getMinDelay, ()));
        if (!isTimelock || ret.length != 32) {
            console.log("owner is a contract (Safe): submit the calldata above via the transaction builder");
            return;
        }
        TimelockController timelock = TimelockController(payable(plan.owner));
        bytes32 salt = keccak256(abi.encodePacked(plan.hub, plan.newExecutor));
        uint256 minDelay = abi.decode(ret, (uint256));
        console.log("\nowner is a TimelockController; two steps:");
        console.log("1. proposer -> timelock.schedule, min delay (s):", minDelay);
        console.log(
            "   calldata:",
            vm.toString(abi.encodeCall(timelock.schedule, (plan.hub, 0, plan.data, bytes32(0), salt, minDelay)))
        );
        console.log("2. anyone -> timelock.execute once ready");
        console.log(
            "   calldata:", vm.toString(abi.encodeCall(timelock.execute, (plan.hub, 0, plan.data, bytes32(0), salt)))
        );
    }
}
