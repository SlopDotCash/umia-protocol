// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Venture} from "../../src/core/Venture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {IUmiaMarketStake} from "../../src/interfaces/IUmiaMarketStake.sol";
import {ConditionalMarketOracle} from "../../src/periphery/ConditionalMarketOracle.sol";

/// @dev Base mainnet rehearsal of the #2893 oracle swap: the new oracle goes in behind the live Hub's
///      registry pointer and a market on the live Umia venture settles on it through the deployed
///      MarketCore. Runs only with FORK_RPC_URL set.
contract ConditionalOracleSwapBaseForkTest is Test {
    address internal constant HUB = 0x120dbCDd58Bb787309573e29159fE6D37A1983F6;
    address internal constant MARKET_CORE = 0x55975E430Cc54C63dff03B1E6d27Be574Ce229F6;
    address internal constant MARKET_STAKE = 0x1819093Ec7376384A659e1c4976CDbc52F5564b9;
    address internal constant LIVE_ORACLE = 0x114C446Ce246b6C5c432Eb001fBeB17864Fc1d34;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 internal constant UMIA_VENTURE_ID = 7;

    /// @dev Mean ticks are floored, so passing the 2% threshold takes a 199-tick lead.
    int24 internal constant THRESHOLD_TICKS = 199;

    IUmiaHub internal hub = IUmiaHub(HUB);
    IUmiaMarketCore internal core = IUmiaMarketCore(MARKET_CORE);
    ConditionalMarketOracle internal oracle;
    IERC20 internal umia;

    uint256 internal signerKey;
    address internal creator = makeAddr("creator");
    address internal trader = makeAddr("trader");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        assertEq(hub.conditionalMarketOracle(), LIVE_ORACLE);
        oracle = new ConditionalMarketOracle(HUB);
        address signer;
        (signer, signerKey) = makeAddrAndKey("umia-2893-market-signer");

        // The timelock batch: the setter's withNoActiveMarkets guard must pass on the live core.
        vm.startPrank(Ownable(HUB).owner());
        hub.setConditionalMarketOracle(address(oracle));
        hub.setMarketCreationSigner(signer);
        vm.stopPrank();

        umia = IERC20(Venture(payable(hub.ventureById(UMIA_VENTURE_ID).venture)).token());
    }

    function test_fork_settlesOnTheNewOraclesMeanTick() public {
        (uint256 marketId, uint256 noOp, uint256 challenger) = _createMarket(1 days);
        (,, uint256 tradingStart, uint256 tradingEnd) = core.marketInfo(marketId);
        vm.warp(tradingStart);
        _split(marketId);

        _buy(challenger, 50_000e6);
        vm.warp(tradingEnd);

        assertGe(_twapTick(challenger) - _twapTick(noOp), THRESHOLD_TICKS, "the trade should clear the threshold");

        core.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winner = core.winningProposalByMarketId(marketId);
        assertEq(winner.proposalId, challenger);
        assertEq(winner.price, core.getProposalTWAP(challenger));
        assertEq(winner.price, oracle.calculateTWAP(challenger, 0, 0));
        // The retired oracle never saw the market.
        vm.expectRevert(ConditionalMarketOracle.ProposalNotInitialized.selector);
        ConditionalMarketOracle(LIVE_ORACLE).calculateTWAP(challenger, 1, 1);
    }

    /// @dev C-01: a pump held across two spaced updates and dumped in the second's block used to
    ///      leave the clamp's anchor ratcheted, credited for the rest of the window.
    function test_fork_roundTripPumpDoesNotStick() public {
        (uint256 marketId, uint256 noOp, uint256 challenger) = _createMarket(1 days);
        (,, uint256 tradingStart, uint256 tradingEnd) = core.marketInfo(marketId);
        vm.warp(tradingStart);
        _split(marketId);

        int24 honestTick = _poolTick(challenger);
        uint256 pumpAt = tradingStart + 1 hours;
        uint256 hold = 10 minutes;
        vm.warp(pumpAt);
        uint256 bought = _buy(challenger, 200_000e6);
        int24 pumpedTick = _poolTick(challenger);
        assertLt(pumpedTick - honestTick, 4558, "the pump lands within one second of slew");
        vm.warp(pumpAt + hold);
        _buy(challenger, 1e6);
        _sell(challenger, bought);
        int24 dumpedTick = _poolTick(challenger);
        vm.warp(tradingEnd);

        // Each price is credited only for the time it was held: no anchor outlives the dump.
        int256 held = int256(honestTick) * int256(pumpAt - tradingStart) + int256(pumpedTick) * int256(hold)
            + int256(dumpedTick) * int256(tradingEnd - pumpAt - hold);
        int256 expected = held / int256(tradingEnd - tradingStart);
        assertApproxEqAbs(int256(_twapTick(challenger)), expected, 1);
        assertLt(int256(_twapTick(challenger)) - honestTick, THRESHOLD_TICKS, "the pump alone cannot pass it");

        core.settleMarket(marketId);
        assertEq(core.winningProposalByMarketId(marketId).proposalId, noOp);
    }

    function _createMarket(uint256 duration) internal returns (uint256 marketId, uint256 noOp, uint256 challenger) {
        deal(address(umia), creator, 1_000_000e18);
        vm.startPrank(creator);
        umia.approve(MARKET_STAKE, type(uint256).max);
        IUmiaMarketStake(MARKET_STAKE).depositMarketStake(UMIA_VENTURE_ID);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "rehearse the oracle swap", executionPayload: ""});
        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: UMIA_VENTURE_ID,
            title: "#2893 fork rehearsal",
            startTimestamp: block.timestamp + 1 hours,
            duration: duration,
            proposals: proposals
        });
        uint256 nonce = core.marketCreationNonces(creator);
        marketId = core.createMarket(params, creator, nonce, _sign(params, nonce));
        vm.stopPrank();

        uint256[] memory ids = core.marketProposalIds(marketId);
        (,, bool firstIsNoOp,,) = core.proposalInfo(ids[0]);
        (noOp, challenger) = firstIsNoOp ? (ids[0], ids[1]) : (ids[1], ids[0]);
    }

    function _sign(IUmiaMarketCore.CreateMarketParams memory params, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "CreateMarketApproval(address creator,uint256 ventureId,bytes32 titleHash,uint256 startTimestamp,uint256 duration,bytes32 proposalsHash,uint256 nonce)"
                ),
                creator,
                params.ventureId,
                keccak256(bytes(params.title)),
                params.startTimestamp,
                params.duration,
                keccak256(abi.encode(params.proposals)),
                nonce
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", core.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _split(uint256 marketId) internal {
        deal(USDC, trader, 1_000_000e6);
        deal(address(umia), trader, 1_000_000e18);
        vm.startPrank(trader);
        IERC20(USDC).approve(MARKET_CORE, type(uint256).max);
        umia.approve(MARKET_CORE, type(uint256).max);
        core.split(marketId, 1_000_000e18, 1_000_000e6);
        vm.stopPrank();
    }

    function _buy(uint256 proposalId, uint256 moneyIn) internal returns (uint256 ventureOut) {
        vm.prank(trader);
        return core.swapExactIn(proposalId, moneyIn, 0, 10_000, false, block.timestamp);
    }

    function _sell(uint256 proposalId, uint256 ventureIn) internal {
        vm.prank(trader);
        core.swapExactIn(proposalId, ventureIn, 0, 10_000, true, block.timestamp);
    }

    function _poolTick(uint256 proposalId) internal view returns (int24) {
        (uint256 reserve0, uint256 reserve1) = core.cpmmStates(proposalId);
        return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(FullMath.mulDiv(reserve1, 1 << 192, reserve0))));
    }

    function _twapTick(uint256 proposalId) internal view returns (int24) {
        (uint256 reserve0, uint256 reserve1) = core.cpmmStates(proposalId);
        return oracle.calculateTWAPTick(proposalId, reserve0, reserve1);
    }
}
