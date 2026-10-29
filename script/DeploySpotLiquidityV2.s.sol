// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {UmiaHookV2} from "../src/periphery/UmiaHookV2.sol";
import {UmiaLBPFactoryV2} from "../src/launchpad/UmiaLBPFactoryV2.sol";
import {SpotLiquidityV2Code} from "../src/periphery/SpotLiquidityV2Code.sol";
import {SpotMigrator} from "../src/periphery/SpotMigrator.sol";
import {ConditionalMarketOracle} from "../src/periphery/ConditionalMarketOracle.sol";

// Canonical constants; duplicated from Deploy.s.sol (same pattern as DeployOracleUpgrade.s.sol).
address constant CREATE_X = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
uint160 constant UMIA_HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);

/// @title DeploySpotLiquidityV2
/// @notice Stages the V2 spot liquidity stack (#2389) on a chain that already runs the protocol,
///         wired to the EXISTING hub:
///
///           1. UmiaHookV2 via CreateX (salt mined with `HOOK_V2=true MineUmiaHookSalt.s.sol`)
///           2. SpotLiquidityV2Code (vault + ALM creation code, shared by 3 and 5)
///           3. UmiaLBPFactoryV2(poolManager, hookV2, hub, code)
///           4. hookV2.initialize(factoryV2, poolManager, hub)
///           5. SpotMigrator(hub, poolManager, hookV2, sourceHook, code), migrating pools from the
///              live V1 hook
///           6. ConditionalMarketOracle(hub), the tick-space settlement oracle
///
///         Nothing here touches the Hub. The script prints the Hub owner's (timelock's) batch, in
///         order: upgrade the Hub and MarketCore (markets created before the MarketCore upgrade get
///         no fee-exempt ALM), point the Hub at the new oracle, swap in a new GovernanceExecutor
///         (liquidation empties the ALM; it must be live before any ALM holds capital), set the
///         migrator and default ALM keeper, and flip the LBP factory once the keeper and indexer
///         watch the V2 hook. Existing ventures move by proposal after `migrator.prepare(venture)`.
///
/// @dev forge script script/DeploySpotLiquidityV2.s.sol:DeploySpotLiquidityV2 --rpc-url <rpc>          # simulate
///      forge script script/DeploySpotLiquidityV2.s.sol:DeploySpotLiquidityV2 --rpc-url <rpc> --broadcast --verify
///
///      Env (all required):
///        DEPLOYER_PRIVATE_KEY  — funded key; MUST derive to UMIA_HOOK_DEPLOYER (initialize is owner-gated)
///        UMIA_HOOK_DEPLOYER    — EOA embedded as the V2 hook's INITIAL_OWNER
///        UMIA_HOOK_V2_SALT     — salt mined from THIS commit's UmiaHookV2 bytecode
///        POOL_MANAGER          — canonical Uniswap v4 PoolManager on this chain
///        UMIA_HUB_ADDRESS      — the live hub proxy
///        UMIA_HOOK_ADDRESS     — the live V1 hook whose pools the migrator moves
contract DeploySpotLiquidityV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerEOA = vm.envAddress("UMIA_HOOK_DEPLOYER");
        bytes32 hookSalt = vm.envBytes32("UMIA_HOOK_V2_SALT");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hubAddr = vm.envAddress("UMIA_HUB_ADDRESS");
        address sourceHook = vm.envAddress("UMIA_HOOK_ADDRESS");

        require(
            vm.addr(deployerPrivateKey) == deployerEOA,
            "DeploySpotLiquidityV2: DEPLOYER_PRIVATE_KEY must derive to UMIA_HOOK_DEPLOYER"
        );
        require(hubAddr.code.length > 0, "DeploySpotLiquidityV2: UMIA_HUB_ADDRESS has no bytecode");
        require(poolManager.code.length > 0, "DeploySpotLiquidityV2: POOL_MANAGER has no bytecode");
        require(sourceHook.code.length > 0, "DeploySpotLiquidityV2: UMIA_HOOK_ADDRESS has no bytecode");

        // CreateX hashes our sentinel-prefixed salt before CREATE2 (see DeployOracleUpgrade.s.sol).
        bytes memory hookCreationCode = abi.encodePacked(type(UmiaHookV2).creationCode, abi.encode(deployerEOA));
        address predictedHook =
            HookMiner.computeAddress(CREATE_X, uint256(keccak256(abi.encodePacked(hookSalt))), hookCreationCode);
        require(
            uint160(predictedHook) & 0x3FFF == UMIA_HOOK_FLAGS,
            "DeploySpotLiquidityV2: predicted UmiaHookV2 address missing required permission bits"
        );
        require(predictedHook.code.length == 0, "DeploySpotLiquidityV2: hook already deployed (stale salt?)");

        vm.startBroadcast(deployerPrivateKey);

        (bool ok, bytes memory ret) =
            CREATE_X.call(abi.encodeWithSignature("deployCreate2(bytes32,bytes)", hookSalt, hookCreationCode));
        require(ok, "DeploySpotLiquidityV2: CreateX UmiaHookV2 deploy failed");
        UmiaHookV2 hook = UmiaHookV2(abi.decode(ret, (address)));
        require(address(hook) == predictedHook, "DeploySpotLiquidityV2: hook address differs from predicted");

        SpotLiquidityV2Code code = new SpotLiquidityV2Code();
        UmiaLBPFactoryV2 factory = new UmiaLBPFactoryV2(IPoolManager(poolManager), address(hook), hubAddr, code);
        hook.initialize(address(factory), IPoolManager(poolManager), hubAddr);
        SpotMigrator migrator = new SpotMigrator(hubAddr, IPoolManager(poolManager), address(hook), sourceHook, code);
        ConditionalMarketOracle oracle = new ConditionalMarketOracle(hubAddr);

        vm.stopBroadcast();

        require(hook.factory() == address(factory), "DeploySpotLiquidityV2: hook.factory mismatch");
        require(hook.hub() == hubAddr, "DeploySpotLiquidityV2: hook.hub mismatch");
        require(factory.umiaHook() == address(hook), "DeploySpotLiquidityV2: factory.umiaHook mismatch");
        require(migrator.hookV2() == address(hook), "DeploySpotLiquidityV2: migrator.hookV2 mismatch");

        console.log("\n--- contracts.json ---");
        console.log("umia.hookV2=%s", address(hook));
        console.log("umia.spotLiquidityV2Code=%s", address(code));
        console.log("umia.lbpFactoryV2=%s", address(factory));
        console.log("umia.spotMigrator=%s", address(migrator));
        console.log("umia.conditionalMarketOracle=%s", address(oracle));

        console.log("\n--- Hub owner, in order ---");
        console.log("1. Upgrade the Hub, then MarketCore, in one batch:");
        console.log("   just forge-upgrade hub <env> <chain>");
        console.log("   just forge-upgrade market-core <env> <chain>");
        console.log("2. Point the Hub at the new settlement oracle (requires no active markets):");
        console.log(_send(hubAddr, "setConditionalMarketOracle(address)", address(oracle)));
        console.log("3. Swap in a new GovernanceExecutor (liquidation empties the ALM), before any ALM holds capital:");
        console.log("   just forge-swap-executor <env> <chain>");
        console.log("4. Set the migrator:");
        console.log(_send(hubAddr, "setSpotMigrator(address)", address(migrator)));
        console.log("5. Set the ALM keeper (the external rebalancer's signing address):");
        console.log(
            string.concat(
                "   cast send ", vm.toString(hubAddr), ' "setActiveLiquidityKeeper(address)" <keeper> --rpc-url <rpc>'
            )
        );
        console.log("6. Set how V2 launches split liquidity between anchor and ALM, and the ALM's first range:");
        console.log(
            string.concat("   cast send ", vm.toString(hubAddr), ' "setLaunchAnchorBps(uint16)" 7500 --rpc-url <rpc>')
        );
        console.log(
            string.concat(
                "   cast send ", vm.toString(hubAddr), ' "setLaunchActiveHalfWidthTicks(int24)" 10980 --rpc-url <rpc>'
            )
        );
        console.log("7. After keeper + indexer watch the V2 hook, flip new launches to V2:");
        console.log(_send(hubAddr, "setLbpStrategyFactory(address)", address(factory)));
        console.log("\n--- Per existing venture, before its migration proposal ---");
        console.log(string.concat("   cast send ", vm.toString(address(migrator)), ' "prepare(address)" <venture>'));
    }

    function _send(address target, string memory sig, address arg) internal pure returns (string memory) {
        return
            string.concat("   cast send ", vm.toString(target), ' "', sig, '" ', vm.toString(arg), " --rpc-url <rpc>");
    }
}
