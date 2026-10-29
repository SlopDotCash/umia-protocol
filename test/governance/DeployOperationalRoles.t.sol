// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";

/// @dev Exposes the deploy script's role wiring. The harness is the Hub owner in these tests, so the
///      `onlyOwner` setters behave exactly as they do inside the script's broadcast window.
contract DeployHarness is Deploy {
    function configureRoles(UmiaHub hub) external {
        _configureOperationalRoles(hub);
    }

    function roleDecision(string memory envKey, string memory consequence) external view returns (address) {
        return _requireRoleDecision(envKey, consequence);
    }
}

/// @notice The deploy script must not let a forgotten export ship a protocol with an operational
///         role silently disabled. `vm` has no `unsetEnv`, so the revert path is exercised through
///         env keys nothing else sets, and the real `VESTING_ADMIN` / `VETO_GUARDIAN` /
///         `ACTIVE_LIQUIDITY_KEEPER` wiring is asserted against a live Hub.
contract DeployOperationalRolesTest is Test {
    DeployHarness harness;
    UmiaHub hub;

    address constant VESTING_ADMIN_ADDR = address(0xA11A);
    address constant VETO_GUARDIAN_ADDR = address(0x7E70);
    address constant KEEPER_ADDR = address(0x4EE9);

    function setUp() public {
        harness = new DeployHarness();
        hub = UmiaHub(
            address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (address(harness)))))
        );
    }

    function test_Revert_UnsetRoleIsNotAcknowledged() public {
        vm.expectRevert(bytes("NEVER_SET_ROLE unset: nothing works. Set it, or set NEVER_SET_ROLE_UNSET_OK=true."));
        harness.roleDecision("NEVER_SET_ROLE", "nothing works.");
    }

    function test_UnsetRoleAllowedWhenAcknowledged() public {
        vm.setEnv("ACKED_ROLE_UNSET_OK", "true");
        assertEq(harness.roleDecision("ACKED_ROLE", "nothing works."), address(0), "acknowledged unset is permitted");
    }

    function test_ConfigureRoles_WiresAllThreeOntoTheHub() public {
        vm.setEnv("VESTING_ADMIN", vm.toString(VESTING_ADMIN_ADDR));
        vm.setEnv("VETO_GUARDIAN", vm.toString(VETO_GUARDIAN_ADDR));
        vm.setEnv("ACTIVE_LIQUIDITY_KEEPER", vm.toString(KEEPER_ADDR));

        assertEq(hub.vestingAdmin(), address(0), "unset before the script configures it");
        assertEq(hub.vetoGuardian(), address(0), "unset before the script configures it");
        assertEq(hub.activeLiquidityKeeper(), address(0), "unset before the script configures it");

        harness.configureRoles(hub);

        assertEq(hub.vestingAdmin(), VESTING_ADMIN_ADDR, "deploy wires the vesting admin");
        assertEq(hub.vetoGuardian(), VETO_GUARDIAN_ADDR, "deploy wires the veto guardian");
        assertEq(hub.activeLiquidityKeeper(), KEEPER_ADDR, "deploy wires the active liquidity keeper");
    }
}
