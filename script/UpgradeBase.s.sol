// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolState} from "./ProtocolState.sol";
import {IUmiaHub} from "../src/interfaces/IUmiaHub.sol";

/// @title UpgradeBase
/// @notice One flow for every protocol upgrade. The target (hub proxy, market core proxy or
///         venture beacon) is resolved from the hub registry by `Kind`:
///
///         1. deploy the new implementation from DEPLOYER_PRIVATE_KEY (the only broadcast by default)
///         2. check it is a locked UUPS implementation
///         3. rehearse the upgrade in the fork as the live owner and diff protocol state reads
///         4. EXECUTE_UPGRADE=true and the deployer owns the target: broadcast the upgrade;
///            otherwise print the exact calldata the owner (Safe, or Safe -> timelock) must send
///
///         Run without --broadcast for a pure dry run: steps 1-3 still execute in the fork.
///
///         Environment:
///         - UMIA_ENV, UMIA_CHAIN    select the hub from contracts.json (e.g. testnet, base-sepolia)
///         - UMIA_HUB_ADDRESS        hub proxy address; skips the contracts.json lookup
///         - DEPLOYER_PRIVATE_KEY    deploys the implementation; leave unset for a hardware wallet
///                                   (forge --ledger/--trezor) with DEPLOYER_ADDRESS set to the signer
///         - UPGRADE_INIT_DATA       abi-encoded reinitializer call forwarded to upgradeToAndCall
///                                   (optional; proxies only, the beacon cannot carry calldata)
///         - EXECUTE_UPGRADE         also send the upgrade when the deployer is the owner (default false)
abstract contract UpgradeBase is Script {
    enum Kind {
        Hub,
        MarketCore,
        VentureBeacon
    }

    /// @dev ERC-7201 slot of OZ `Initializable`; `_disableInitializers` writes uint64.max there.
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    string internal constant MARKET_CORE_ARTIFACT = "out/UmiaMarketCore.sol/UmiaMarketCore.json";
    string internal constant SETTLEMENT_LIB = "src/libraries/SettlementLib.sol:SettlementLib";
    string internal constant MARKET_CREATION_LIB = "src/libraries/MarketCreationLib.sol:MarketCreationLib";

    struct UpgradeConfig {
        uint256 deployerKey;
        IUmiaHub hub;
        bytes initData;
        bool execute;
    }

    struct Plan {
        address target;
        address newImpl;
        address previousImpl;
        address owner;
        bytes initData;
        bytes data;
        bytes32 salt;
        bool executed;
    }

    Kind internal immutable KIND;

    constructor(Kind kind) {
        KIND = kind;
    }

    function _deployImplementation() internal virtual returns (address);

    function run() external returns (Plan memory) {
        return upgrade(
            UpgradeConfig({
                // Zero key = hardware wallet mode: the signer comes from the forge CLI wallet
                // flags (--ledger/--trezor) and the address from DEPLOYER_ADDRESS.
                deployerKey: vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0)),
                hub: ProtocolState.hubFromContractsJson(
                    vm.envOr("UMIA_ENV", string("")), vm.envOr("UMIA_CHAIN", string(""))
                ),
                initData: vm.envOr("UPGRADE_INIT_DATA", bytes("")),
                execute: vm.envOr("EXECUTE_UPGRADE", false)
            })
        );
    }

    function upgrade(UpgradeConfig memory cfg) public returns (Plan memory plan) {
        address deployer = _deployer(cfg.deployerKey);
        plan.target = _target(cfg.hub);
        require(plan.target.code.length > 0, "target has no bytecode");
        plan.owner = _owner(cfg.hub, plan.target);
        plan.previousImpl = _currentImplementation(plan.target);
        ProtocolState.Snapshot memory before = ProtocolState.snapshot(cfg.hub);

        console.log(string.concat("== Upgrade ", _label(), " =="));
        console.log("target:             ", plan.target);
        console.log("owner:              ", plan.owner);
        console.log("deployer:           ", deployer);
        console.log("live implementation:", plan.previousImpl);

        _startBroadcast(cfg.deployerKey);
        plan.newImpl = _deployImplementation();
        vm.stopBroadcast();
        console.log("new implementation: ", plan.newImpl);
        console.log("bytecode changed:   ", plan.newImpl.codehash != plan.previousImpl.codehash);

        _assertLockedUupsImplementation(plan.newImpl);

        plan.initData = cfg.initData;
        plan.data = _upgradeCalldata(plan.newImpl, cfg.initData);
        plan.salt = keccak256(abi.encodePacked(plan.target, plan.newImpl));

        _rehearse(cfg.hub, plan, before);

        if (cfg.execute) {
            require(plan.owner == deployer, "EXECUTE_UPGRADE set but the deployer is not the owner");
            _startBroadcast(cfg.deployerKey);
            _sendUpgrade(plan);
            vm.stopBroadcast();
            require(_currentImplementation(plan.target) == plan.newImpl, "upgrade did not land");
            ProtocolState.requireUnchanged(before, ProtocolState.snapshot(cfg.hub), "post-upgrade");
            plan.executed = true;
            console.log("upgrade executed; live implementation:", plan.newImpl);
        } else {
            _logHandoff(plan);
        }

        _logBookkeeping(plan);
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

    /// @notice Addresses of the external libraries linked into a market core implementation.
    function linkedLibraries(address impl) public view returns (address settlementLib, address marketCreationLib) {
        settlementLib = _linkedLibrary(impl, MARKET_CORE_ARTIFACT, SETTLEMENT_LIB);
        marketCreationLib = _linkedLibrary(impl, MARKET_CORE_ARTIFACT, MARKET_CREATION_LIB);
        require(settlementLib != address(0) && marketCreationLib != address(0), "library link not found");
    }

    // ─────────────────────────────────────────────────────────
    // Kind dispatch
    // ─────────────────────────────────────────────────────────

    function _label() internal view returns (string memory) {
        if (KIND == Kind.Hub) return "UmiaHub";
        if (KIND == Kind.MarketCore) return "UmiaMarketCore";
        return "Venture beacon";
    }

    function _target(IUmiaHub hub) internal view returns (address) {
        if (KIND == Kind.Hub) return address(hub);
        if (KIND == Kind.MarketCore) return hub.umiaMarketCore();
        return hub.ventureBeacon();
    }

    function _owner(IUmiaHub hub, address target) internal view returns (address) {
        return KIND == Kind.VentureBeacon ? UpgradeableBeacon(target).owner() : hub.owner();
    }

    function _currentImplementation(address target) internal view returns (address) {
        return KIND == Kind.VentureBeacon
            ? UpgradeableBeacon(target).implementation()
            : ProtocolState.implementationOf(target);
    }

    function _upgradeCalldata(address newImpl, bytes memory initData) internal view returns (bytes memory) {
        if (KIND != Kind.VentureBeacon) return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, initData));
        require(initData.length == 0, "beacon upgrades cannot carry init data");
        return abi.encodeCall(UpgradeableBeacon.upgradeTo, (newImpl));
    }

    function _sendUpgrade(Plan memory plan) internal {
        if (KIND == Kind.VentureBeacon) UpgradeableBeacon(plan.target).upgradeTo(plan.newImpl);
        else UUPSUpgradeable(plan.target).upgradeToAndCall(plan.newImpl, plan.initData);
    }

    function _logBookkeeping(Plan memory plan) internal view {
        console.log("\n== Record in contracts.json[env][chain].umia ==");
        if (KIND == Kind.Hub) {
            console.log("hubImpl:", plan.newImpl);
        } else if (KIND == Kind.VentureBeacon) {
            console.log("ventureImpl:", plan.newImpl);
        } else {
            (address settlementLib, address marketCreationLib) = linkedLibraries(plan.newImpl);
            console.log("marketCoreImpl:   ", plan.newImpl);
            console.log("settlementLib:    ", settlementLib);
            console.log("marketCreationLib:", marketCreationLib);
        }
    }

    // ─────────────────────────────────────────────────────────
    // Checks
    // ─────────────────────────────────────────────────────────

    function _assertLockedUupsImplementation(address impl) internal view {
        require(impl.code.length > 0, "new implementation has no bytecode");
        require(
            IERC1822Proxiable(impl).proxiableUUID() == ERC1967Utils.IMPLEMENTATION_SLOT,
            "new implementation is not a UUPS implementation"
        );
        uint64 initialized = uint64(uint256(vm.load(impl, INITIALIZABLE_STORAGE)));
        require(initialized == type(uint64).max, "new implementation did not disable its initializers");
    }

    function _rehearse(IUmiaHub hub, Plan memory plan, ProtocolState.Snapshot memory before) internal {
        uint256 snapshot = vm.snapshotState();

        vm.prank(plan.owner);
        (bool ok, bytes memory ret) = plan.target.call(plan.data);
        require(ok, string.concat("rehearsal: upgrade reverted: ", vm.toString(ret)));
        require(_currentImplementation(plan.target) == plan.newImpl, "rehearsal: implementation not updated");
        ProtocolState.requireUnchanged(before, ProtocolState.snapshot(hub), "rehearsal");

        vm.revertToState(snapshot);
        console.log("rehearsal: upgrade succeeds as owner, protocol state reads unchanged");
    }

    // ─────────────────────────────────────────────────────────
    // Output
    // ─────────────────────────────────────────────────────────

    function _logHandoff(Plan memory plan) internal view {
        console.log("\n== Owner action required ==");
        console.log("send to:  ", plan.target);
        console.log("from:     ", plan.owner);
        console.log("calldata: ", vm.toString(plan.data));

        (bool isTimelock, uint256 minDelay) = _timelockDelay(plan.owner);
        if (!isTimelock) {
            if (plan.owner.code.length > 0) {
                console.log("owner is a contract (Safe): submit the calldata above via the transaction builder");
            } else {
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
            }
            return;
        }

        TimelockController timelock = TimelockController(payable(plan.owner));
        bytes32 id = timelock.hashOperation(plan.target, 0, plan.data, bytes32(0), plan.salt);
        console.log("\nowner is a TimelockController; two steps:");
        console.log("1. proposer (Safe) -> timelock.schedule, min delay (s):", minDelay);
        console.log("   to:      ", plan.owner);
        console.log(
            "   calldata:",
            vm.toString(abi.encodeCall(timelock.schedule, (plan.target, 0, plan.data, bytes32(0), plan.salt, minDelay)))
        );
        console.log("2. anyone -> timelock.execute once ready (isOperationReady(id))");
        console.log("   to:      ", plan.owner);
        console.log(
            "   calldata:",
            vm.toString(abi.encodeCall(timelock.execute, (plan.target, 0, plan.data, bytes32(0), plan.salt)))
        );
        console.log("   operation id:", vm.toString(id));
        console.log("   salt:        ", vm.toString(plan.salt));
    }

    function _timelockDelay(address owner) internal view returns (bool isTimelock, uint256 minDelay) {
        if (owner.code.length == 0) return (false, 0);
        (bool ok, bytes memory ret) = owner.staticcall(abi.encodeCall(TimelockController.getMinDelay, ()));
        if (!ok || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev Address linked into `impl` for the external library `fqn` ("path:Name"), read from
    ///      the bytecode at the offset of solc's link placeholder in the artifact. Zero if unlinked.
    function _linkedLibrary(address impl, string memory artifact, string memory fqn) internal view returns (address) {
        string memory object = vm.parseJsonString(vm.readFile(artifact), ".deployedBytecode.object");
        string memory hashPrefix = vm.replace(vm.toString(abi.encodePacked(bytes17(keccak256(bytes(fqn))))), "0x", "");
        uint256 index = vm.indexOf(object, string.concat("__$", hashPrefix, "$__"));
        if (index == type(uint256).max) return address(0);
        bytes memory code = impl.code;
        uint256 offset = (index - 2) / 2;
        address linked;
        assembly {
            linked := shr(96, mload(add(add(code, 0x20), offset)))
        }
        return linked;
    }
}
