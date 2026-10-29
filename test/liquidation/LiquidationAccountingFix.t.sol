// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SimpleLiquidator} from "../../src/liquidation/SimpleLiquidator.sol";
import {ILiquidator} from "../../src/interfaces/ILiquidator.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {GovernanceActions} from "../../src/libraries/GovernanceActions.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Regression tests for the liquidation pro-rata accounting fixes.
///  - #104039: treasury-held venture tokens (e.g. the venture's redeemed spot-LP share) must not
///    count in the claim denominator, otherwise a matching fraction of every liquidation asset
///    strands in the treasury forever because the treasury can never call claim().
///  - #2901: they are burned rather than excluded, so a standing venture-token approval cannot move
///    them into circulation after the snapshot and over-draw every holder.
///  - #104007: the venture (claim-burn) token must never be a distributable liquidation asset, so a
///    claimant cannot forward a venture-token payout to fresh addresses and claim again to over-draw.
contract LiquidationAccountingFixTest is Test {
    address internal admin = makeAddr("admin");
    address internal marketCore = makeAddr("marketCore");
    address internal team1 = makeAddr("team1");
    address internal bob = makeAddr("bob");
    address internal alice = makeAddr("alice");
    address internal spender = makeAddr("spender");

    UmiaHub internal hub;
    GovernanceExecutor internal executor;
    Venture internal venture;
    VentureToken internal qToken;
    SimpleLiquidator internal liquidator;
    MockERC20 internal assetToken;

    function setUp() public {
        UmiaHub hubImpl = new UmiaHub();
        hub = UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (admin)))));

        vm.prank(admin);
        hub.setUmiaMarketCore(marketCore);

        executor = new GovernanceExecutor(address(hub));
        vm.prank(admin);
        hub.setDefaultGovernanceExecutor(address(executor));

        MockERC20 moneyToken = new MockERC20("Money", "MNY", 18);
        assetToken = new MockERC20("Asset", "AST", 18);

        Venture ventureImpl = new Venture();
        venture = Venture(
            payable(address(
                    new ERC1967Proxy(address(ventureImpl), abi.encodeCall(Venture.initializeProxy, (address(hub))))
                ))
        );

        qToken = new VentureToken("Test", "TST", address(venture));

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = team1;

        vm.prank(address(hub));
        venture.initialize(
            IVenture.InitializeVentureParams({
                token: address(qToken),
                moneyToken: address(moneyToken),
                lbp: address(0x1234),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );

        liquidator = new SimpleLiquidator(address(hub));
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(address(executor));
        venture.mint(to, amount);
    }

    function _startLiquidation(GovernanceTypes.LiquidationAsset[] memory assets) internal {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.LiquidationPlan({liquidator: address(liquidator), assets: assets}))
        });
        GovernanceTypes.ExecutionPlanV1 memory plan = GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions});
        vm.prank(marketCore);
        executor.executeProposal(address(venture), 1, 1, abi.encode(plan));
    }

    function _erc20Asset(address token) internal pure returns (GovernanceTypes.LiquidationAsset[] memory assets) {
        assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] =
            GovernanceTypes.LiquidationAsset({assetType: GovernanceTypes.AssetType.ERC20, token: token, tokenId: 0});
    }

    /// #104039: treasury-held venture tokens are burned out of the denominator, so the sole external
    /// holder redeems the FULL asset balance instead of being diluted by non-claimable treasury supply.
    function test_treasuryHeldSupplyBurnedBeforeSnapshot() public {
        _mint(bob, 100e18); // circulating
        _mint(address(venture), 100e18); // treasury-held (e.g. redeemed vault LP) — can never claim
        assetToken.mint(address(venture), 1000e18);

        _startLiquidation(_erc20Asset(address(assetToken)));

        assertEq(qToken.balanceOf(address(venture)), 0, "treasury-held supply burned");
        assertEq(qToken.totalSupply(), 100e18, "only circulating supply remains");
        assertEq(liquidator.totalSupplySnapshot(), 100e18, "denominator excludes treasury-held supply");

        vm.prank(bob);
        liquidator.claim();

        // Bob is the only claimant and receives the full asset balance — nothing strands.
        assertEq(assetToken.balanceOf(bob), 1000e18, "sole holder redeems full asset balance");
        assertEq(assetToken.balanceOf(address(venture)), 0, "no assets stranded in treasury");
    }

    /// #104007: listing the venture token as a liquidation asset is a no-op — it is skipped, so no
    /// venture tokens are ever paid back out and the recycling vector is closed.
    function test_ventureTokenAssetIsSkipped() public {
        _mint(bob, 100e18);
        _mint(address(venture), 100e18); // treasury-held venture tokens
        assetToken.mint(address(venture), 1000e18);

        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](2);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(qToken), tokenId: 0
        });
        assets[1] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(assetToken), tokenId: 0
        });

        _startLiquidation(assets);

        // Only the real asset is snapshotted; the venture token was skipped.
        assertEq(liquidator.liquidationAssetCount(), 1, "venture token excluded from asset set");

        vm.prank(bob);
        liquidator.claim();

        // Bob's tokens are burned and NONE are returned, so he cannot recycle to over-draw.
        assertEq(qToken.balanceOf(bob), 0, "no venture tokens returned to claimant");
        assertEq(assetToken.balanceOf(bob), 1000e18, "bob still receives the real asset in full");
    }

    /// Sanity: with no treasury-held supply, the denominator still equals total supply (no regression).
    function test_noTreasuryHeldSupply_denominatorEqualsTotalSupply() public {
        _mint(bob, 100e18);
        _mint(alice, 100e18);
        assetToken.mint(address(venture), 1000e18);

        _startLiquidation(_erc20Asset(address(assetToken)));

        assertEq(liquidator.totalSupplySnapshot(), 200e18, "no treasury supply -> denominator == total supply");

        vm.prank(bob);
        liquidator.claim();
        vm.prank(alice);
        liquidator.claim();

        assertEq(assetToken.balanceOf(bob), 500e18, "bob 50%");
        assertEq(assetToken.balanceOf(alice), 500e18, "alice 50%");
    }

    /// #2901: a standing approval on the venture token cannot pull treasury-held venture tokens into
    /// circulation after the snapshot, so the legitimate holder's claim is not diluted.
    function test_standingVentureTokenApprovalCannotOverdraw() public {
        _mint(bob, 100e18);
        _mint(address(venture), 100e18);
        assetToken.mint(address(venture), 1000e18);

        vm.prank(address(executor));
        venture.setAllowance(address(qToken), spender, type(uint256).max);

        _startLiquidation(_erc20Asset(address(assetToken)));

        assertEq(qToken.balanceOf(address(venture)), 0, "treasury-held supply burned");
        vm.prank(spender);
        vm.expectRevert();
        qToken.transferFrom(address(venture), spender, 100e18);

        vm.prank(spender);
        vm.expectRevert(ILiquidator.NothingToClaim.selector);
        liquidator.claim();

        vm.prank(bob);
        liquidator.claim();
        assertEq(assetToken.balanceOf(bob), 1000e18, "legitimate holder redeems full asset balance");
    }

    /// With every venture token held by the treasury there is no one to claim, so liquidation reverts.
    function test_noCirculatingSupply_reverts() public {
        _mint(address(venture), 100e18);
        assetToken.mint(address(venture), 1000e18);

        vm.expectRevert(GovernanceActions.InvalidParams.selector);
        _startLiquidation(_erc20Asset(address(assetToken)));
    }
}
