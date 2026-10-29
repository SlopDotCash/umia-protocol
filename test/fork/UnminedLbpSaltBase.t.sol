// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "@continuous-clearing-auction/../test/utils/AuctionStepsBuilder.sol";

import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {Venture} from "../../src/core/Venture.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev A full launch through the live Base Hub, LBP factory and CCA with an unmined LBP salt: no
///      contract checks the LBP address's hook-flag bits. Runs only with FORK_RPC_URL set.
contract UnminedLbpSaltBaseForkTest is Test {
    using AuctionStepsBuilder for bytes;

    IUmiaHub internal constant HUB = IUmiaHub(0x120dbCDd58Bb787309573e29159fE6D37A1983F6);
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    uint256 internal constant FLOOR = FixedPoint96.Q96 / 1e15;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_fork_launchesAndMigratesWithAnUnminedSalt() public {
        uint64 start = uint64(block.number + 1);
        uint64 end = uint64(block.number + 101);
        uint64 claim = uint64(block.number + 201);
        bytes memory auctionParams = abi.encode(
            AuctionParameters({
                currency: USDC,
                tokensRecipient: address(1),
                fundsRecipient: address(1),
                startBlock: start,
                endBlock: end,
                claimBlock: claim,
                tickSpacing: FLOOR,
                validationHook: address(0),
                floorPrice: FLOOR,
                requiredCurrencyRaised: 0,
                auctionStepsData: AuctionStepsBuilder.init().addStep(100_000, 50).addStep(100_000, 50)
            })
        );
        address[] memory team = new address[](1);
        team[0] = makeAddr("team");

        vm.prank(HUB.owner());
        (, address payable venture) = HUB.createVenture(
            IUmiaHub.CreateVentureParams({
                name: "Unmined",
                symbol: "UNMN",
                initialSupply: 1_000_000e18,
                moneyToken: USDC,
                tokenSplitToAuction: 5_000_000,
                auctionParams: auctionParams,
                ventureBps: 2000,
                lbpSalt: bytes32(0),
                teamMembers: team,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );

        UmiaLBP lbp = UmiaLBP(payable(Venture(venture).lbp()));
        emit log_named_address("LBP", address(lbp));
        assertTrue(uint160(address(lbp)) & 0x3FFF != 0x3A80, "this salt happens to carry the flags; pick another");

        IContinuousClearingAuction auction = IContinuousClearingAuction(address(lbp.initializer()));
        vm.roll(start);
        address bidder = makeAddr("bidder");
        uint128 amount = 1_000e6;
        deal(USDC, bidder, amount);
        vm.startPrank(bidder);
        IERC20(USDC).approve(address(PERMIT2), amount);
        PERMIT2.approve(USDC, address(auction), amount, uint48(block.timestamp + 1 days));
        auction.submitBid(2 * FLOOR, amount, bidder, FLOOR, "");
        vm.stopPrank();

        vm.roll(end);
        auction.checkpoint();
        vm.roll(uint256(end) + HUB.migrationDelayBlocks());
        lbp.migrate();

        assertTrue(lbp.migrated());
        assertTrue(ISpotLiquidityVault(HUB.ventureLiquidityVault(venture)).isPoolInitialized());
    }
}
