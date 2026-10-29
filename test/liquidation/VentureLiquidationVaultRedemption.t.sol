// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {Venture} from "../../src/core/Venture.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {IGovernanceExecutor} from "../../src/interfaces/IGovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {SimpleLiquidator} from "../../src/liquidation/SimpleLiquidator.sol";
import {ISpotLiquidityVaultV2} from "../../src/interfaces/ISpotLiquidityVaultV2.sol";

/// @dev Stands in for a V2 pool's ActiveLiquidityManager: `withdrawAll` is venture-only and sends
///      everything it holds to the venture.
contract MockActiveManager {
    address internal immutable venture;
    IERC20 internal immutable money;

    constructor(address _venture, IERC20 _money) {
        venture = _venture;
        money = _money;
    }

    function withdrawAll() external {
        require(msg.sender == venture, "venture only");
        money.transfer(venture, money.balanceOf(address(this)));
    }
}

/// @notice Covers the LIQUIDATE_TREASURY action redeeming the venture's protocol LP shares (pool
///         reserves + its pro-rata idle) into the treasury. Requires a migrated venture with a
///         bootstrapped SpotLiquidityVault; the pre-migration vault==0 skip is covered by
///         SimpleLiquidatorTest.
contract VentureLiquidationVaultRedemptionTest is DecisionMarketBase {
    uint16 internal constant PLAN_VERSION = 1;

    function setUp() public override {
        super.setUp();
    }

    function _liquidatePlan(address liquidator) internal pure returns (bytes memory) {
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.NATIVE, token: address(0), tokenId: 0
        });

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.LiquidationPlan({liquidator: liquidator, assets: assets}))
        });

        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: PLAN_VERSION, actions: actions}));
    }

    function test_liquidateTreasury_redeemsVaultSharesToTreasury() public {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();
        _warmSpotOracle(venture);
        vm.deal(venture, 1 ether);

        address vault = hub.ventureLiquidityVault(venture);
        assertGt(ISpotLiquidityVault(vault).shareBalance(venture), 0, "treasury holds bootstrap shares");

        uint256 tMoneyBefore = usdc.balanceOf(venture);

        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));
        address executor = hub.governanceExecutor(venture);

        vm.prank(hub.umiaMarketCore());
        IGovernanceExecutor(executor).executeProposal(venture, 1, 1, _liquidatePlan(address(liquidator)));

        assertEq(ISpotLiquidityVault(vault).shareBalance(venture), 0, "vault shares fully redeemed");
        assertEq(IERC20(ventureToken).balanceOf(venture), 0, "redeemed venture tokens burned");
        assertEq(liquidator.totalSupplySnapshot(), IERC20(ventureToken).totalSupply(), "snapshot is post-burn supply");
        assertGt(usdc.balanceOf(venture), tMoneyBefore, "money tokens landed in treasury");
        assertTrue(Venture(payable(venture)).liquidationActive(), "liquidation active");
        assertEq(Venture(payable(venture)).authorizedLiquidator(), address(liquidator), "liquidator set");
    }

    /// @notice A V2 vault's active manager is unwound into the treasury before the claimable
    ///         snapshot, so claimants share its capital too.
    function test_liquidateTreasury_unwindsTheActiveManagerToTreasury() public {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();
        _warmSpotOracle(venture);
        vm.deal(venture, 1 ether);

        MockActiveManager manager = new MockActiveManager(venture, IERC20(address(usdc)));
        deal(address(usdc), address(manager), 5_000e6);
        address vault = hub.ventureLiquidityVault(venture);
        vm.mockCall(
            vault, abi.encodeWithSelector(ISpotLiquidityVaultV2.activeManager.selector), abi.encode(address(manager))
        );

        uint256 tMoneyBefore = usdc.balanceOf(venture);
        SimpleLiquidator liquidator = new SimpleLiquidator(address(hub));
        address executor = hub.governanceExecutor(venture);
        vm.prank(hub.umiaMarketCore());
        IGovernanceExecutor(executor).executeProposal(venture, 1, 1, _liquidatePlan(address(liquidator)));

        assertEq(usdc.balanceOf(address(manager)), 0, "manager fully unwound");
        assertGe(usdc.balanceOf(venture), tMoneyBefore + 5_000e6, "manager capital landed in treasury");
        assertTrue(Venture(payable(venture)).liquidationActive(), "liquidation active");
    }
}
