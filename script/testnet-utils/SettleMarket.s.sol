// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AtomicMarketSettler} from "./AtomicMarketSettler.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";

interface IERC20T {
    function transfer(address, uint256) external returns (bool);
}

/// @notice **Testnet utility.** Deploy the atomic settler, fund it, and settle an ended decision
///         market past the SpotLiquidityVault deviation guard — in one broadcast. `settleMarket`
///         is permissionless, so this needs only the deployer key (for gas + the venture token
///         that funds the pin swap).
///
///         Env: HUB, POOL_MANAGER, HOOK, DEPLOYER_PRIVATE_KEY, VENTURE_ID, MARKET_ID,
///         and optionally PIN_FUNDING (venture-token base units, default 50_000e18).
contract SettleMarket is Script {
    function run() external {
        address hub = vm.envAddress("HUB");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK");
        uint256 ventureId = vm.envUint("VENTURE_ID");
        uint256 marketId = vm.envUint("MARKET_ID");
        uint256 pinFunding = vm.envOr("PIN_FUNDING", uint256(50_000e18));

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address ventureToken = IUmiaHub(hub).ventureTokenById(ventureId);

        vm.startBroadcast(deployerKey);

        AtomicMarketSettler settler = new AtomicMarketSettler(hub, poolManager, hook);
        console2.log("settler deployed:", address(settler));

        // Bots keep spot above the TWAP, so the pin sells the venture token.
        IERC20T(ventureToken).transfer(address(settler), pinFunding);

        settler.run(ventureId, marketId);
        console2.log("MARKET SETTLED, id:", marketId);

        vm.stopBroadcast();
    }
}
