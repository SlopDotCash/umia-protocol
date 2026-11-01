// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

/// @title DeployerCall
/// @notice Sends one call from DEPLOYER_PRIVATE_KEY. The key is read from the environment, so it
///         never appears in process arguments the way `cast send --private-key` puts it there.
/// @dev forge script script/DeployerCall.s.sol --sig "deployer()" --rpc-url <rpc>
///      forge script script/DeployerCall.s.sol --sig "run(address,bytes)" <target> <calldata> --rpc-url <rpc> --broadcast
contract DeployerCall is Script {
    function deployer() external view {
        console.log("deployer:", vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY")));
    }

    function run(address target, bytes calldata data) external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        (bool ok, bytes memory ret) = target.call(data);
        vm.stopBroadcast();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
