// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {UmiaHookV2} from "../../src/periphery/UmiaHookV2.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {ActiveLiquidityManager} from "../../src/core/ActiveLiquidityManager.sol";
import {SpotMigrator} from "../../src/periphery/SpotMigrator.sol";
import {ActiveSlices} from "../../src/libraries/ActiveSlices.sol";
import {SpotLiquidityV2Code} from "../../src/periphery/SpotLiquidityV2Code.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {TwapMath} from "../../src/libraries/TwapMath.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {IUmiaMarketStake} from "../../src/interfaces/IUmiaMarketStake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Mainnet acceptance test for #2389: migrate UMIA's spot liquidity to `UmiaHookV2` with a
///         single two-action proposal executed through the live GovernanceExecutor, on a Base fork
///         after staging the Hub upgrade, the V2 hook and the migrator. Runs only with
///         FORK_RPC_URL set.
contract SpotMigrationUmiaForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IUmiaHub constant HUB = IUmiaHub(0x120dbCDd58Bb787309573e29159fE6D37A1983F6);
    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    address constant LBP_FACTORY = 0x8E6A262e4FdfAC98565C08a2aE6fc6D16253Ad1b;
    address constant HOOK_V2 = address(uint160(0xB0B0 << 20) | 0x3A80);
    address constant HOOK_OWNER = address(0x0123);
    uint32 constant VESTING_WINDOW = 30 days;
    uint256 constant BASE_TX_GAS_CAP = 1 << 24;
    uint256 constant FORK_BLOCK = 52_250_000;

    address venture;
    ISpotLiquidityVault oldVault;
    SpotMigrator migrator;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Pinned: the migration reverts by design whenever UMIA spot is >2% (twice the 1% fee) off its 30-minute TWAP,
        // so a live-block fork would make this test depend on the market.
        vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK));

        venture = _findVenture("UMIA");
        oldVault = ISpotLiquidityVault(HUB.ventureLiquidityVault(venture));

        address hubOwner = HUB.owner();
        address hubImpl = address(new UmiaHub());
        vm.prank(hubOwner);
        UUPSUpgradeable(address(HUB)).upgradeToAndCall(hubImpl, "");

        deployCodeTo("UmiaHookV2.sol:UmiaHookV2", abi.encode(HOOK_OWNER), HOOK_V2);
        vm.prank(HOOK_OWNER);
        UmiaHookV2(HOOK_V2).initialize(LBP_FACTORY, POOL_MANAGER, address(HUB));

        migrator = new SpotMigrator(
            address(HUB), POOL_MANAGER, HOOK_V2, address(oldVault.getPoolKey().hooks), new SpotLiquidityV2Code()
        );
        vm.prank(hubOwner);
        HUB.setSpotMigrator(address(migrator));
        uint256 prepareGas = gasleft();
        migrator.prepare(venture);
        console.log("prepare gas", prepareGas - gasleft());
    }

    function test_UmiaMigration_SingleProposal() public {
        (address newVault, address alm,) = migrator.prepared(venture);
        PoolKey memory oldKey = oldVault.getPoolKey();
        (uint160 v1Price,,,) = POOL_MANAGER.getSlot0(oldKey.toId());
        uint256 shares = oldVault.shareBalance(venture);
        console.log("venture shares / total", shares, oldVault.totalShares());
        (bool longServable, int24 longBefore) = _vestingTwapTick();

        bytes memory payload = _payload(shares, _params());
        address executor = HUB.governanceExecutor(venture);
        address marketCore = HUB.umiaMarketCore();
        vm.prank(marketCore);
        uint256 gasBefore = gasleft();
        GovernanceExecutor(executor).executeProposal(venture, type(uint128).max, 0, payload);
        uint256 gasUsed = gasBefore - gasleft();
        console.log("execute gas", gasUsed);
        assertLt(gasUsed, BASE_TX_GAS_CAP * 3 / 4);

        assertEq(HUB.ventureLiquidityVault(venture), newVault);
        assertEq(oldVault.shareBalance(venture), 0);
        PoolKey memory newKey = ISpotLiquidityVault(newVault).getPoolKey();
        (uint160 v2Price,,,) = POOL_MANAGER.getSlot0(newKey.toId());
        assertEq(v2Price, v1Price);
        assertEq(ActiveLiquidityManager(alm).positions().length, 1);
        assertEq(IERC20Metadata(IVenture(venture).token()).balanceOf(address(migrator)), 0);
        assertEq(IERC20Metadata(IVenture(venture).moneyToken()).balanceOf(address(migrator)), 0);

        // The vesting condition's read keeps answering across the seam, with the same TWAP.
        (bool longServableAfter, int24 longAfter) = _vestingTwapTick();
        console.log("30d TWAP servable", longServable);
        console.log("30d TWAP tick before / after");
        console.logInt(longBefore);
        console.logInt(longAfter);
        assertEq(longServableAfter, longServable);
        if (longServable) assertApproxEqAbs(longAfter, longBefore, 1);
    }

    function test_UmiaMigration_RevertLeavesV1Intact() public {
        uint256 shares = oldVault.shareBalance(venture);
        SpotMigrator.MigrateParams memory bad = _params();
        bad.anchorBps = 0;
        bytes memory payload = _payload(shares, bad);

        address executor = HUB.governanceExecutor(venture);
        address marketCore = HUB.umiaMarketCore();
        vm.prank(marketCore);
        vm.expectRevert();
        GovernanceExecutor(executor).executeProposal(venture, type(uint128).max, 0, payload);

        assertEq(oldVault.shareBalance(venture), shares);
        assertEq(HUB.ventureLiquidityVault(venture), address(oldVault));
    }

    /// @notice Acceptance test for the basket RFC: after the migration and the MarketCore upgrade, a
    ///         UMIA decision market snapshots the new ALM as its fee-exempt trader, and the ALM
    ///         closes a spot gap through a fee-free basket at a profit; the market still settles.
    function test_UmiaMigration_ThenBasketArb() public {
        address hubOwner = HUB.owner();
        UmiaMarketCore core = UmiaMarketCore(HUB.umiaMarketCore());
        address coreImpl = address(new UmiaMarketCore());
        vm.prank(hubOwner);
        core.upgradeToAndCall(coreImpl, "");

        (, address alm,) = migrator.prepared(venture);
        GovernanceExecutor executor = GovernanceExecutor(HUB.governanceExecutor(venture));
        bytes memory payload = _payload(oldVault.shareBalance(venture), _params());
        vm.prank(address(core));
        executor.executeProposal(venture, type(uint128).max, 0, payload);
        ISpotLiquidityVault vault = ISpotLiquidityVault(HUB.ventureLiquidityVault(venture));
        PoolKey memory key = vault.getPoolKey();
        _warmV2Oracle(key);

        uint256 marketId = _createUmiaMarket(core);
        assertEq(core.activeManager(marketId), alm);
        uint256[] memory proposalIds = core.marketProposalIds(marketId);

        _pushSpotDown(key, 250);

        uint256 size = type(uint256).max;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (uint256 reserve0,) = core.cpmmStates(proposalIds[i]);
            if (reserve0 / 1000 < size) size = reserve0 / 1000;
        }
        uint256 fraction = type(uint256).max;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (uint256 quoted,) = core.quoteSwapExactIn(proposalIds[i], size, true);
            (, uint256 reserve1) = core.cpmmStates(proposalIds[i]);
            if (quoted * 1e18 / reserve1 < fraction) fraction = quoted * 1e18 / reserve1;
        }

        address keeper = makeAddr("keeper");
        vm.prank(hubOwner);
        HUB.setActiveLiquidityKeeper(keeper);
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        (uint256 moneyProfit,) = ActiveLiquidityManager(alm).basketArb(marketId, true, size, fraction, 0, 1);
        console.log("basketArb gas", gasBefore - gasleft());
        console.log("basketArb money profit", moneyProfit);
        assertGt(moneyProfit, 0);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (uint256 feeVenture, uint256 feeMoney) = core.proposalFeeState(proposalIds[i]);
            assertEq(feeVenture + feeMoney, 0);
        }

        (,,, uint256 tradingEnd) = core.marketInfo(marketId);
        vm.warp(tradingEnd + 1);
        vm.roll(block.number + 1);
        core.settleMarket(marketId);
        assertTrue(core.marketSettled(marketId));
    }

    /// @dev The vault's seed-pull guard needs the new pool's per-block ring to cover 30 minutes.
    function _warmV2Oracle(PoolKey memory key) internal {
        UmiaHookV2(HOOK_V2).increaseCardinalityNext(key, 32);
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 10 minutes);
            vm.roll(block.number + 300);
            _swapSpot(key, true, 1e15);
        }
    }

    function _createUmiaMarket(UmiaMarketCore core) internal returns (uint256 marketId) {
        uint256 ventureId = _ventureId(venture);
        address creator = makeAddr("creator");
        (address signer, uint256 signerKey) = makeAddrAndKey("marketSigner");
        address hubOwner = HUB.owner();
        vm.startPrank(hubOwner);
        HUB.setMarketCreationSigner(signer);
        HUB.setVentureMinMarketStake(ventureId, 1e18);
        vm.stopPrank();

        address token = IVenture(venture).token();
        IUmiaMarketStake stake = IUmiaMarketStake(HUB.umiaMarketStake());
        deal(token, creator, 1e18);
        vm.startPrank(creator);
        IERC20(token).approve(address(stake), 1e18);
        stake.depositMarketStake(ventureId);
        vm.stopPrank();

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "fork basket", executionPayload: ""});
        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "fork basket market",
            startTimestamp: block.timestamp,
            duration: 1 hours,
            proposals: proposals
        });
        uint256 nonce = core.marketCreationNonces(creator);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "CreateMarketApproval(address creator,uint256 ventureId,bytes32 titleHash,uint256 startTimestamp,uint256 duration,bytes32 proposalsHash,uint256 nonce)"
                ),
                creator,
                ventureId,
                keccak256(bytes(params.title)),
                params.startTimestamp,
                params.duration,
                keccak256(abi.encode(params.proposals)),
                nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", core.DOMAIN_SEPARATOR(), structHash)));
        vm.prank(creator);
        marketId = core.createMarket(params, creator, nonce, abi.encodePacked(r, s, v));
    }

    /// @dev Sells the venture token on the V2 pool until its price is `bps` lower.
    function _pushSpotDown(PoolKey memory key, uint256 bps) internal {
        (uint160 sqrtPrice,,,) = POOL_MANAGER.getSlot0(key.toId());
        bool ventureIsToken0 = Currency.unwrap(key.currency0) == IVenture(venture).token();
        uint160 limit = ventureIsToken0
            ? uint160(uint256(sqrtPrice) * (10_000 - bps / 2) / 10_000)
            : uint160(uint256(sqrtPrice) * 10_000 / (10_000 - bps / 2));
        PoolSwapTest router = new PoolSwapTest(POOL_MANAGER);
        address token = IVenture(venture).token();
        deal(token, address(this), 1e30);
        IERC20(token).approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({zeroForOne: ventureIsToken0, amountSpecified: -int256(1e30), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapSpot(PoolKey memory key, bool sellVenture, uint256 amount) internal {
        bool ventureIsToken0 = Currency.unwrap(key.currency0) == IVenture(venture).token();
        bool zeroForOne = sellVenture == ventureIsToken0;
        PoolSwapTest router = new PoolSwapTest(POOL_MANAGER);
        address token = IVenture(venture).token();
        deal(token, address(this), amount);
        IERC20(token).approve(address(router), amount);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _ventureId(address v) internal view returns (uint256) {
        uint256 count = HUB.ventureCount();
        for (uint256 i = 1; i <= count; i++) {
            if (HUB.ventureById(i).venture == v) return i;
        }
        revert("venture id not found");
    }

    function _params() internal view returns (SpotMigrator.MigrateParams memory p) {
        int24 spacing = oldVault.getPoolKey().tickSpacing;
        p.anchorBps = 7500;
        p.activeSlices = new ActiveSlices.Slice[](1);
        p.activeSlices[0] =
            ActiveSlices.Slice({tickLowerOffset: -20 * spacing, tickUpperOffset: 21 * spacing, bps: 9000});
    }

    function _payload(uint256 shares, SpotMigrator.MigrateParams memory p) internal view returns (bytes memory) {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](2);
        actions[0] =
            _call(address(oldVault), abi.encodeCall(ISpotLiquidityVault.withdraw, (shares, 0, 0, address(migrator))));
        actions[1] = _call(address(migrator), abi.encodeCall(SpotMigrator.migrate, (p)));
        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }

    function _call(address target, bytes memory data) internal pure returns (GovernanceTypes.ActionV1 memory) {
        return GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.CALL,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.Call({target: target, value: 0, data: data}))
        });
    }

    /// @dev Same path as `UmiaTwapMilestoneCondition`: Hub -> vault -> hook -> observeLong.
    function _vestingTwapTick() internal view returns (bool servable, int24 tick) {
        ISpotLiquidityVault vault = ISpotLiquidityVault(HUB.ventureLiquidityVault(venture));
        uint32[] memory s = new uint32[](2);
        s[0] = VESTING_WINDOW;
        try IUmiaHook(vault.hook()).observeLong(vault.getPoolKey(), s) returns (int48[] memory c, uint144[] memory) {
            return (true, TwapMath.averageTick(c[0], c[1], VESTING_WINDOW));
        } catch {
            return (false, 0);
        }
    }

    function _findVenture(string memory symbol) internal view returns (address) {
        uint256 count = HUB.ventureCount();
        for (uint256 i = 1; i <= count; i++) {
            address v = HUB.ventureById(i).venture;
            if (
                keccak256(bytes(IERC20Metadata(IVenture(v).token()).symbol())) == keccak256(bytes(symbol))
                    && HUB.ventureLiquidityVault(v) != address(0)
            ) return v;
        }
        revert("venture not found");
    }
}
