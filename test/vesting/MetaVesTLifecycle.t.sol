// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {MetaVesTTestBase} from "./MetaVesTTestBase.t.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";
import {VentureToken} from "../../src/tokens/VentureToken.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";

import {VentureVestingAuthority} from "../../src/periphery/VentureVestingAuthority.sol";
import {IVentureVestingAuthority} from "../../src/interfaces/IVentureVestingAuthority.sol";

import {metavestController} from "@metavest/MetaVesTController.sol";
import {BaseAllocation} from "@metavest/BaseAllocation.sol";
import {VestingAllocation} from "@metavest/VestingAllocation.sol";

/// @title MetaVesTLifecycle
/// @notice Full, REAL end-to-end MetaVesT vesting lifecycle, faithful to the spec's genesis flow
///         (§8.1): a venture launches via `createVentureWithToken` with a team grant locked **before
///         the CCA** through the `VentureVestingAuthority` adapter (authority handed off before
///         genesis grants), only the circulating float auctioned, then migrated to a
///         live spot pool. The genesis grant then runs the whole way through a real TWAP-milestone
///         unlock, linear vesting, and a real beneficiary withdrawal; and a second grant is added
///         post-launch **through a real futarchy market** (§8.2).
///
///         Every protocol contract is real (no `vm.mockCall`): the operator-deployed VentureToken,
///         the vendored MetaVesT controller + allocation, the adapter, the real CCA + LBP migration,
///         the live UmiaHook TWAP oracle, and a real decision market. Only forge cheatcodes advance
///         time and stand up actors.
contract MetaVesTLifecycleTest is MetaVesTTestBase {
    /// @dev Launch operator = the Hub owner (`createVentureWithToken` is `onlyOwner`). The spec's
    ///      "operator (ADMIN)".
    address operator;

    /// @dev Genesis grant beneficiary (a normal user, not a team member).
    address beneficiary = bob;

    uint256 constant INITIAL_SUPPLY = 1_000_000e18;
    /// @dev Linear stream total; vests AND unlocks over `STREAM_DURATION` (both rates nonzero).
    uint256 constant STREAM = 100_000e18;
    uint256 constant STREAM_DURATION = 100 days;
    uint160 constant STREAM_RATE = uint160(STREAM / STREAM_DURATION);
    /// @dev Single price-gated milestone award (unlocked on completion).
    uint256 constant AWARD = 50_000e18;
    uint256 constant TOTAL = STREAM + AWARD;
    /// @dev The genesis milestone's relative ladder: unlock once the TWAP reaches 1.5x the auction
    ///      clearing price. The migrated pool opens AT the clearing price, so this sits above the
    ///      opening TWAP — genuinely unmet until a real spot move lifts the window average past it.
    uint256 constant MILESTONE_MULTIPLE = 1_500_000; // 1.5x, 1e6 scale

    // A real VC-style grant: 1-year cliff (nothing vests), then a lump at the cliff + 3-year linear.
    // Exercises `vestingCliffCredit` and a future `vestingStartTime` (the delayed-start gate).
    uint256 constant CLIFF_AMOUNT = 120_000e18;
    uint256 constant CLIFF_LINEAR = 360_000e18;
    uint256 constant CLIFF_GRANT_TOTAL = CLIFF_AMOUNT + CLIFF_LINEAR;
    uint48 constant CLIFF_DELAY = 365 days;
    uint256 constant CLIFF_VEST_DURATION = 3 * 365 days;
    uint160 constant CLIFF_VEST_RATE = uint160(CLIFF_LINEAR / CLIFF_VEST_DURATION);

    metavestController controller;
    VentureVestingAuthority adapter;

    /// @dev The genesis grant: locked pre-CCA, run through the full lifecycle.
    address allocation;

    function setUp() public override {
        super.setUp();
        operator = umiaAdmin; // the Hub owner is the launch operator (ADMIN)

        // The §8.2 funding market must resolve to the grant proposal; the win-threshold math itself
        // is covered by the decision-market suite. 100 bps is the lowest the Hub allows.
        vm.prank(umiaAdmin);
        hub.setWinningMarketThresholdBps(100);

        allocation = _launchWithVesting();

        vm.label(venture, "VENTURE");
        vm.label(ventureToken, "VENTURE_TOKEN");
        vm.label(beneficiary, "beneficiary");
        vm.label(operator, "operator");
        vm.label(allocation, "GENESIS_ALLOCATION");
    }

    // ═══════════════════════════════════════════════════════════════
    // Genesis launch (§8.1): grant locked PRE-CCA, authority handed off BEFORE the venture exists
    // ═══════════════════════════════════════════════════════════════

    /// @dev The real launch-with-vesting sequence; returns the genesis allocation. Mirrors §8.1:
    ///      mint → deploy adapter → hand authority → fund genesis grant via adapter → close genesis →
    ///      transfer only the float to the Hub → `createVentureWithToken` → CCA + migrate → bind.
    function _launchWithVesting() internal returns (address genesisAllocation) {
        // 1. Operator deploys the venture token and mints the full supply to itself (no Hub yet).
        vm.startPrank(operator);
        VentureToken token = new VentureToken("aliceUMO", "ALICE", operator);
        token.mint(operator, INITIAL_SUPPLY);
        ventureToken = address(token);

        // 2. Deploy the MetaVesT stack (authority = operator) and the shared TWAP condition.
        controller = _deployMetaVestStack(operator);

        // 3. Deploy the adapter and hand the controller authority to it BEFORE genesis grants, so
        //    every grant routes through the adapter and emits AllocationFunded for the indexer.
        adapter = new VentureVestingAuthority(address(hub), address(controller));
        controller.initiateAuthorityUpdate(address(adapter));
        adapter.claim();

        // 4. Lock the genesis grant BEFORE the CCA via the adapter (authority = adapter).
        (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones) = _buildGrant();
        bytes memory createCalldata = abi.encodeCall(
            controller.createMetavest,
            (metavestController.metavestType.Vesting, beneficiary, alloc, milestones, 0, address(0), 0, 0)
        );
        token.approve(address(adapter), TOTAL);
        genesisAllocation =
            adapter.fundGenesisGrant(address(token), TOTAL, createCalldata, _relativeLadder(MILESTONE_MULTIPLE));
        adapter.closeGenesis();

        // 5. Transfer only the circulating float (supply − locked) and token ownership to the Hub; the
        //    Hub auctions whatever balance it then holds.
        token.transfer(address(hub), token.balanceOf(operator));
        token.transferOwnership(address(hub));
        vm.stopPrank();

        // 6. Launch: `createVentureWithToken` (Hub-owner only) auctions the float; then run the real
        //    CCA bid + `migrate()` into the live spot pool.
        LBPBlockConfig memory blocks = _defaultBlockConfig();
        address[] memory teamMembers = new address[](1);
        teamMembers[0] = alice;
        vm.prank(operator);
        (ventureId, venture) = hub.createVentureWithToken(
            IUmiaHub.CreateVentureWithTokenParams({
                token: ventureToken,
                moneyToken: address(usdc),
                tokenSplitToAuction: 5_000_000,
                auctionParams: _buildAuctionParams(blocks),
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
        _runAuctionAndMigrate(Venture(payable(venture)).lbp(), blocks);

        // 7. Bind the adapter to the now-live venture treasury.
        vm.prank(operator);
        adapter.bind(ventureId);
    }

    // ═══════════════════════════════════════════════════════════════
    // Stage 1: authority handed to the adapter before launch; gated to futarchy
    // ═══════════════════════════════════════════════════════════════

    function test_stage1_authorityRoutedToAdapter() public view {
        assertEq(controller.authority(), address(adapter), "controller authority should be the adapter");
        assertEq(adapter.treasury(), venture, "adapter treasury should be the venture");
        assertTrue(adapter.bound(), "adapter should be bound");
        assertEq(
            IERC20(ventureToken).allowance(address(adapter), address(controller)),
            type(uint256).max,
            "bind should grant the controller a standing allowance"
        );
    }

    function test_stage1_operatorCanNoLongerCreateMetavestDirectly() public {
        (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones) = _buildGrant();
        vm.prank(operator);
        vm.expectRevert(metavestController.MetaVesTController_OnlyAuthority.selector);
        controller.createMetavest(
            metavestController.metavestType.Vesting, beneficiary, alloc, milestones, 0, address(0), 0, 0
        );
    }

    // ═══════════════════════════════════════════════════════════════
    // Genesis grant: locked before the CCA, intact through launch
    // ═══════════════════════════════════════════════════════════════

    function test_genesis_grantLockedPreCcaHoldsTotal() public view {
        // The venture is live (the float auctioned + migrated), yet the genesis grant — locked before
        // the auction — still custodies its full award untouched.
        assertTrue(
            hub.ventureLiquidityVault(venture) != address(0), "venture should be migrated (spot liquidity vault live)"
        );
        assertEq(BaseAllocation(allocation).grantee(), beneficiary, "grantee should be the beneficiary");
        assertEq(BaseAllocation(allocation).controller(), address(controller), "allocation tied to controller");
        assertEq(IERC20(ventureToken).balanceOf(allocation), TOTAL, "genesis grant holds the full award");
    }

    // ═══════════════════════════════════════════════════════════════
    // Stage 2: post-launch grant created THROUGH FUTARCHY (the adapter funding path)
    // ═══════════════════════════════════════════════════════════════

    function test_stage2_grantCreatedViaFutarchyHoldsTotal() public {
        address grant = _createGrantViaFutarchy(charlie);

        assertTrue(grant.code.length > 0, "allocation should be deployed");
        assertEq(BaseAllocation(grant).grantee(), charlie, "grantee should be charlie");
        assertEq(BaseAllocation(grant).controller(), address(controller), "allocation tied to controller");
        assertEq(IERC20(ventureToken).balanceOf(grant), TOTAL, "grant should hold the full award");
        assertEq(IERC20(ventureToken).balanceOf(address(adapter)), 0, "adapter should retain no tokens");
    }

    /// @notice Same adapter -> controller -> allocation funding path, driven by pranking the
    ///         GovernanceExecutor directly instead of resolving a market — the documented fallback
    ///         that isolates the funding mechanics from the market-resolution wrapper (which
    ///         `_createGrantViaFutarchy` exercises end to end).
    function test_stage2_grantViaDirectExecutorFundingPath() public {
        (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones) = _buildGrant();
        address grant = _createGrantViaExecutor(dave, alloc, milestones, TOTAL);

        assertEq(BaseAllocation(grant).grantee(), dave, "grantee set");
        assertEq(IERC20(ventureToken).balanceOf(grant), TOTAL, "grant funded via direct executor path");
        assertEq(IERC20(ventureToken).balanceOf(address(adapter)), 0, "adapter retains no tokens");
    }

    /// @notice A cliffed price milestone confirms only once BOTH gates hold: with the TWAP already
    ///         past the threshold, confirmation still reverts until the cliff elapses, then passes.
    function test_milestoneCliff_gatesConfirmationUntilElapsed() public {
        (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones) = _buildGrant();
        uint48 cliff = uint48(block.timestamp + 30 days);
        address grant = _createGrantViaExecutor(
            dave, alloc, milestones, TOTAL, _relativeLadderWithCliff(MILESTONE_MULTIPLE, cliff)
        );
        assertEq(adapter.effectiveCliff(grant, 0), cliff, "cliff registered with the grant");

        // Lift the TWAP past the threshold: the price gate is met, the cliff is not.
        _swapSpot(venture, 40_000e6, true);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        assertGt(_twapPriceX96(venture), adapter.effectiveThreshold(grant, 0), "price gate met before the cliff");

        vm.expectRevert(BaseAllocation.MetaVesT_ConditionNotSatisfied.selector);
        BaseAllocation(grant).confirmMilestone(0);

        vm.warp(cliff);
        BaseAllocation(grant).confirmMilestone(0);
        assertEq(BaseAllocation(grant).milestoneUnlockedTotal(), AWARD, "both gates met: award unlocks");
    }

    // ═══════════════════════════════════════════════════════════════
    // Full lifecycle on the GENESIS grant, then a post-launch futarchy grant
    // ═══════════════════════════════════════════════════════════════

    function test_fullLifecycle_realPriceUnlockTimeVestAndWithdraw() public {
        assertEq(IERC20(ventureToken).balanceOf(allocation), TOTAL, "genesis grant funded with TOTAL");

        // The genesis grant's price ladder was locked in at funding: a relative milestone at 1.5x the
        // auction clearing price. The migrated pool opens at that clearing price, so the resolved
        // threshold sits above the live TWAP and the gate is genuinely unmet until a real spot move
        // lifts the window average past it.
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        uint160 milestoneThreshold = adapter.effectiveThreshold(allocation, 0);

        // ── Stage 3: real price unlock ──
        // (a) Below threshold the milestone cannot confirm — the real TWAP gate, read live from the
        //     migrated pool's oracle inside the condition.
        assertLt(_twapPriceX96(venture), milestoneThreshold, "precondition: live TWAP below the threshold");
        vm.expectRevert(BaseAllocation.MetaVesT_ConditionNotSatisfied.selector);
        BaseAllocation(allocation).confirmMilestone(0);

        uint256 unlockedBefore = BaseAllocation(allocation).milestoneUnlockedTotal();
        uint256 awardTotalBefore = BaseAllocation(allocation).milestoneAwardTotal();

        // (b) Push the SPOT price up by buying venture on the real V4 pool, then warp a full TWAP
        //     window so the higher price dominates the window average and clears the threshold.
        _swapSpot(venture, 40_000e6, true);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        assertGt(_twapPriceX96(venture), milestoneThreshold, "spot push + warp should lift the TWAP past threshold");

        BaseAllocation(allocation).confirmMilestone(0);
        assertEq(BaseAllocation(allocation).milestoneUnlockedTotal(), unlockedBefore + AWARD, "unlock adds AWARD");
        assertEq(BaseAllocation(allocation).milestoneAwardTotal(), awardTotalBefore + AWARD, "award total adds AWARD");

        // ── Stage 4: real time-vest ── warp past the stream so it fully vests and unlocks.
        vm.warp(block.timestamp + STREAM_DURATION + 1);
        assertEq(_expectedStreamVested(), STREAM, "stream fully vested after its duration");

        uint256 withdrawable = BaseAllocation(allocation).getAmountWithdrawable();
        assertEq(withdrawable, STREAM + AWARD, "withdrawable = full stream + unlocked milestone");

        // ── Stage 5/6: real claim by the beneficiary ──
        uint256 benBalBefore = IERC20(ventureToken).balanceOf(beneficiary);
        uint256 allocBalBefore = IERC20(ventureToken).balanceOf(allocation);
        vm.prank(beneficiary);
        BaseAllocation(allocation).withdraw(withdrawable);

        assertEq(IERC20(ventureToken).balanceOf(beneficiary) - benBalBefore, withdrawable, "beneficiary balance rises");
        assertEq(allocBalBefore - IERC20(ventureToken).balanceOf(allocation), withdrawable, "allocation balance drops");
        assertEq(BaseAllocation(allocation).tokensWithdrawn(), withdrawable, "tokensWithdrawn tracks the withdrawal");
        assertEq(BaseAllocation(allocation).getAmountWithdrawable(), 0, "nothing further withdrawable");

        // ── Stage 7 (§8.2): futarchy adds a second grant post-launch ──
        // The milestone push was one isolated swap then ~100 idle days, so the vault's 30-min TWAP
        // still reads the pre-move average and its sandwich guard would reject the futarchy market's
        // liquidity pull. Season the oracle with realistic post-move trading (60 swaps spanning ~2
        // TWAP windows) so the guard's TWAP converges to the new spot before the pull.
        for (uint256 i = 0; i < 60; i++) {
            _swapSpot(venture, 20e6, false);
            vm.warp(block.timestamp + 60);
        }
        address secondGrant = _createGrantViaFutarchy(charlie);
        assertEq(BaseAllocation(secondGrant).grantee(), charlie, "post-launch grant grantee set");
        assertEq(IERC20(ventureToken).balanceOf(secondGrant), TOTAL, "post-launch grant funded via futarchy");
    }

    /// @dev Real partial time-vest midway through the stream (no milestone), to verify the linear
    ///      schedule independent of the milestone award.
    function test_stage4_partialLinearVesting() public {
        vm.warp(block.timestamp + STREAM_DURATION / 2);

        uint256 withdrawable = BaseAllocation(allocation).getAmountWithdrawable();
        assertEq(withdrawable, _expectedStreamVested(), "midway withdrawable equals the linearly vested stream");
        assertGt(withdrawable, 0, "some stream should have vested");
        assertLt(withdrawable, STREAM, "but not the whole stream yet");

        uint256 benBalBefore = IERC20(ventureToken).balanceOf(beneficiary);
        vm.prank(beneficiary);
        BaseAllocation(allocation).withdraw(withdrawable);
        assertEq(IERC20(ventureToken).balanceOf(beneficiary) - benBalBefore, withdrawable, "beneficiary receives it");
    }

    // ═══════════════════════════════════════════════════════════════
    // Schedule variants: cliff + delayed start, and unlock lagging vesting
    // ═══════════════════════════════════════════════════════════════

    /// @notice A real VC-style grant: a 1-year cliff (nothing vests), then the cliff lump vests at the
    ///         boundary and the remainder vests linearly over 3 years. Exercises `vestingCliffCredit`
    ///         and a future `vestingStartTime` (the delayed-start gate) on a live, adapter-funded grant.
    function test_cliffThenLinearVesting() public {
        address grantee = makeAddr("cliffGrantee");
        uint48 start = uint48(block.timestamp + CLIFF_DELAY);

        BaseAllocation.Allocation memory alloc = BaseAllocation.Allocation({
            tokenStreamTotal: CLIFF_GRANT_TOTAL,
            vestingCliffCredit: uint128(CLIFF_AMOUNT),
            unlockingCliffCredit: uint128(CLIFF_AMOUNT),
            vestingRate: CLIFF_VEST_RATE,
            vestingStartTime: start,
            unlockRate: CLIFF_VEST_RATE,
            unlockStartTime: start,
            tokenContract: ventureToken
        });
        address grant = _createGrantViaExecutor(grantee, alloc, new BaseAllocation.Milestone[](0), CLIFF_GRANT_TOTAL);
        assertEq(IERC20(ventureToken).balanceOf(grant), CLIFF_GRANT_TOTAL, "grant funded with the full amount");

        // During the cliff year: nothing vested or withdrawable (the delayed-start gate).
        assertEq(VestingAllocation(grant).getVestedTokenAmount(), 0, "nothing vests during the cliff");
        assertEq(BaseAllocation(grant).getAmountWithdrawable(), 0, "nothing withdrawable during the cliff");

        // At the cliff boundary: the lump vests at once.
        vm.warp(start);
        assertEq(VestingAllocation(grant).getVestedTokenAmount(), CLIFF_AMOUNT, "cliff lump vests at the boundary");
        assertEq(BaseAllocation(grant).getAmountWithdrawable(), CLIFF_AMOUNT, "cliff lump is withdrawable");

        // Midway through the 3-year stream: cliff + linear, strictly between the lump and the total.
        vm.warp(start + CLIFF_VEST_DURATION / 2);
        uint256 mid = VestingAllocation(grant).getVestedTokenAmount();
        assertEq(
            mid, _linearVested(CLIFF_GRANT_TOTAL, CLIFF_VEST_RATE, start, CLIFF_AMOUNT), "mid matches the schedule"
        );
        assertGt(mid, CLIFF_AMOUNT, "more than the cliff lump has vested");
        assertLt(mid, CLIFF_GRANT_TOTAL, "but not the whole grant yet");

        // Well past the stream: fully vested and withdrawable; the grantee claims the whole grant.
        vm.warp(start + CLIFF_VEST_DURATION + 365 days);
        assertEq(VestingAllocation(grant).getVestedTokenAmount(), CLIFF_GRANT_TOTAL, "fully vested after the stream");
        uint256 withdrawable = BaseAllocation(grant).getAmountWithdrawable();
        assertEq(withdrawable, CLIFF_GRANT_TOTAL, "the whole grant is withdrawable");

        vm.prank(grantee);
        BaseAllocation(grant).withdraw(withdrawable);
        assertEq(IERC20(ventureToken).balanceOf(grantee), CLIFF_GRANT_TOTAL, "grantee claims the full grant");
        assertEq(BaseAllocation(grant).getAmountWithdrawable(), 0, "nothing left after the claim");
    }

    /// @notice Unlock lagging vesting: tokens vest twice as fast as they unlock, so withdrawable is
    ///         bound by the unlock axis (earned-but-locked) until the slower schedule catches up.
    function test_divergentUnlockLagsVesting() public {
        address grantee = makeAddr("divergentGrantee");
        uint256 grantTotal = 100_000e18;
        uint256 dur = 100 days;
        uint48 start = uint48(block.timestamp);
        uint160 vestRate = uint160(grantTotal / dur);
        uint160 unlockRate = vestRate / 2; // unlock at half the vesting speed

        BaseAllocation.Allocation memory alloc = BaseAllocation.Allocation({
            tokenStreamTotal: grantTotal,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: vestRate,
            vestingStartTime: start,
            unlockRate: unlockRate,
            unlockStartTime: start,
            tokenContract: ventureToken
        });
        address grant = _createGrantViaExecutor(grantee, alloc, new BaseAllocation.Milestone[](0), grantTotal);

        // Midway: more is vested than unlocked, and withdrawable tracks the slower unlock axis.
        vm.warp(start + dur / 2);
        uint256 vested = VestingAllocation(grant).getVestedTokenAmount();
        uint256 unlocked = VestingAllocation(grant).getUnlockedTokenAmount();
        assertGt(vested, unlocked, "vesting outruns unlocking");
        assertEq(BaseAllocation(grant).getAmountWithdrawable(), unlocked, "withdrawable bound by the unlock schedule");

        // The grantee can claim only the unlocked portion now.
        vm.prank(grantee);
        BaseAllocation(grant).withdraw(unlocked);
        assertEq(IERC20(ventureToken).balanceOf(grantee), unlocked, "claims only the unlocked portion");

        // Once unlocking catches up, the remainder is claimable and the grantee holds the whole grant.
        vm.warp(start + 4 * dur);
        assertEq(VestingAllocation(grant).getUnlockedTokenAmount(), grantTotal, "unlock fully caught up");
        uint256 rest = BaseAllocation(grant).getAmountWithdrawable();
        vm.prank(grantee);
        BaseAllocation(grant).withdraw(rest);
        assertEq(IERC20(ventureToken).balanceOf(grantee), grantTotal, "grantee eventually receives the whole grant");
        assertEq(BaseAllocation(grant).tokensWithdrawn(), grantTotal, "all tokens withdrawn");
    }

    // ═══════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════

    /// @dev A price-gated + time-vesting grant: a linear stream (vesting AND unlocking over time)
    ///      plus one milestone gated by the TWAP condition and unlocked on completion.
    // ═══════════════════════════════════════════════════════════════
    // Grant administration: real controller, fully ABI-encoded replacement calldata
    // ═══════════════════════════════════════════════════════════════

    /// @dev The Hub owner appoints an operational vesting admin, a key deliberately distinct from the
    ///      upgrade owner.
    function _appointVestingAdmin() internal returns (address admin) {
        admin = makeAddr("vestingAdmin");
        vm.prank(umiaAdmin);
        hub.setVestingAdmin(admin);
    }

    /// @dev A milestone-free grant sized to `streamTotal`, vesting linearly from now.
    function _linearGrant(uint256 streamTotal) internal view returns (BaseAllocation.Allocation memory alloc) {
        alloc = BaseAllocation.Allocation({
            tokenStreamTotal: streamTotal,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: uint160(streamTotal / STREAM_DURATION),
            vestingStartTime: uint48(block.timestamp),
            unlockRate: uint160(streamTotal / STREAM_DURATION),
            unlockStartTime: uint48(block.timestamp),
            tokenContract: ventureToken
        });
    }

    /// @notice A real termination through the vendored controller: vesting stops, the vested portion
    ///         stays with the grantee, and the unvested remainder plus the unconfirmed milestone award
    ///         land in the treasury rather than parked on the adapter.
    function test_admin_terminateGrant_returnsRealClawbackToTreasury() public {
        address admin = _appointVestingAdmin();
        (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones) = _buildGrant();
        address grant = _createGrantViaExecutor(charlie, alloc, milestones, TOTAL);

        vm.warp(block.timestamp + STREAM_DURATION / 4);
        uint256 vested = VestingAllocation(grant).getVestedTokenAmount();
        assertGt(vested, 0, "some of the stream should have vested");
        uint256 treasuryBefore = IERC20(ventureToken).balanceOf(venture);

        vm.prank(admin);
        adapter.terminateGrant(grant);

        assertTrue(VestingAllocation(grant).terminated(), "grant terminated");
        assertEq(IERC20(ventureToken).balanceOf(grant), vested, "vested portion stays with the grantee");
        assertEq(
            IERC20(ventureToken).balanceOf(venture) - treasuryBefore,
            TOTAL - vested,
            "unvested stream + unconfirmed milestone award returned to the treasury"
        );
        assertEq(IERC20(ventureToken).balanceOf(address(adapter)), 0, "adapter parks nothing");
    }

    /// @notice A real reissue: the replacement grant is fully ABI-encoded for the vendored controller
    ///         and funded entirely out of the terminated grant's clawback.
    function test_admin_terminateAndReissue_fundsReplacementFromRealClawback() public {
        address admin = _appointVestingAdmin();
        address grant =
            _createGrantViaExecutor(charlie, _linearGrant(STREAM), new BaseAllocation.Milestone[](0), STREAM);

        vm.warp(block.timestamp + STREAM_DURATION / 4);
        uint256 clawback = STREAM - VestingAllocation(grant).getVestedTokenAmount();

        bytes memory createCalldata =
            _encodeCreateMetavest(dave, _linearGrant(clawback), new BaseAllocation.Milestone[](0));
        address predicted = vm.computeCreateAddress(vestingFactory, vm.getNonce(vestingFactory));

        vm.prank(admin);
        address created = adapter.terminateAndReissue(grant, createCalldata, _noProgram());

        assertEq(created, predicted, "replacement deployed by the real allocation factory");
        assertEq(BaseAllocation(created).grantee(), dave, "replacement is for the new grantee");
        assertEq(IERC20(ventureToken).balanceOf(created), clawback, "funded exactly by the clawback");
        assertEq(IERC20(ventureToken).balanceOf(address(adapter)), 0, "adapter parks nothing");
    }

    /// @notice The drain property against the real controller: idle adapter balance is flushed to the
    ///         treasury before the terminate, so a replacement larger than the clawback has nothing to
    ///         draw on and MetaVesT's own approval/balance validation rejects it.
    function test_Revert_admin_terminateAndReissue_cannotOutspendRealClawback() public {
        address admin = _appointVestingAdmin();
        address grant =
            _createGrantViaExecutor(charlie, _linearGrant(STREAM), new BaseAllocation.Milestone[](0), STREAM);

        // Idle balance sitting on the adapter, which a reissue must not be able to reach.
        address executor = hub.governanceExecutor(venture);
        vm.prank(executor);
        Venture(payable(venture)).mint(venture, STREAM);
        vm.prank(executor);
        Venture(payable(venture))
            .executeCall(ventureToken, 0, abi.encodeCall(IERC20.transfer, (address(adapter), STREAM)));

        vm.warp(block.timestamp + STREAM_DURATION / 4);
        uint256 clawback = STREAM - VestingAllocation(grant).getVestedTokenAmount();

        bytes memory tooBig =
            _encodeCreateMetavest(dave, _linearGrant(clawback + STREAM / 2), new BaseAllocation.Milestone[](0));

        vm.prank(admin);
        vm.expectRevert(); // MetaVesT_AmountNotApprovedForTransferFrom: only the clawback is reachable
        adapter.terminateAndReissue(grant, tooBig, _noProgram());
    }

    /// @notice Liquidation pays out pro-rata against a supply snapshot, so grant mutation stops where
    ///         governance stops. Sweeping stays open: it only ever returns assets to the estate.
    function test_admin_grantMutationFrozenOnceLiquidating() public {
        address admin = _appointVestingAdmin();
        address grant =
            _createGrantViaExecutor(charlie, _linearGrant(STREAM), new BaseAllocation.Milestone[](0), STREAM);

        vm.prank(hub.governanceExecutor(venture));
        Venture(payable(venture)).setLiquidator(makeAddr("liquidator"));

        assertEq(adapter.effectiveVestingAdmin(), address(0), "no admin can act during liquidation");

        vm.prank(admin);
        vm.expectRevert(IVentureVestingAuthority.LiquidationActive.selector);
        adapter.terminateGrant(grant);

        vm.prank(admin);
        vm.expectRevert(IVentureVestingAuthority.LiquidationActive.selector);
        adapter.terminateAndReissue(
            grant, _encodeCreateMetavest(dave, _linearGrant(STREAM), new BaseAllocation.Milestone[](0)), _noProgram()
        );
    }

    /// @notice The whole departure-and-replacement story on a live venture, end to end, with nothing
    ///         mocked: an employee grant is created post-launch through the real adapter funding
    ///         path, partially vests, the employee leaves, the Hub-appointed vesting admin terminates
    ///         and reissues to their replacement in a single call, the departing grantee still claims
    ///         exactly what they earned, and the replacement's freshly registered price ladder
    ///         unlocks against the live pool TWAP before they withdraw real tokens. Closes by having
    ///         the venture revoke the admin path through futarchy.
    function test_e2e_adminReplacesDepartingGranteeAndReplacementUnlocksAndWithdraws() public {
        address admin = _appointVestingAdmin();
        assertEq(adapter.effectiveVestingAdmin(), admin, "admin may act on this venture");

        // ── 1. An employee grant, funded post-launch through the real adapter path ──
        (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones) = _buildGrant();
        address leaverGrant = _createGrantViaExecutor(charlie, alloc, milestones, TOTAL);
        assertEq(IERC20(ventureToken).balanceOf(leaverGrant), TOTAL, "employee grant funded with TOTAL");

        // ── 2. They vest a quarter of the stream, then leave ──
        vm.warp(block.timestamp + STREAM_DURATION / 4);
        uint256 earned = VestingAllocation(leaverGrant).getVestedTokenAmount();
        assertGt(earned, 0, "some of the stream vested before they left");
        uint256 clawback = TOTAL - earned;

        // ── 3. One admin call: stop their vesting, recycle the remainder into the replacement's
        //       grant. The ladder is positional and write-once, so only a fresh allocation can carry
        //       one -- which is exactly what a reissue produces.
        (BaseAllocation.Allocation memory rAlloc, BaseAllocation.Milestone[] memory rMilestones) = _buildGrant();
        rAlloc.tokenStreamTotal = clawback - AWARD; // stream + milestone award == the clawback exactly
        rAlloc.vestingRate = uint160(rAlloc.tokenStreamTotal / STREAM_DURATION);
        rAlloc.unlockRate = rAlloc.vestingRate;
        rAlloc.vestingStartTime = uint48(block.timestamp);
        rAlloc.unlockStartTime = uint48(block.timestamp);

        uint256 treasuryBefore = IERC20(ventureToken).balanceOf(venture);
        address predicted = vm.computeCreateAddress(vestingFactory, vm.getNonce(vestingFactory));

        vm.prank(admin);
        address replacementGrant = adapter.terminateAndReissue(
            leaverGrant, _encodeCreateMetavest(dave, rAlloc, rMilestones), _relativeLadder(MILESTONE_MULTIPLE)
        );

        assertEq(replacementGrant, predicted, "replacement deployed by the real allocation factory");
        assertEq(BaseAllocation(replacementGrant).grantee(), dave, "replacement is for the new hire");
        assertEq(IERC20(ventureToken).balanceOf(replacementGrant), clawback, "funded entirely by the clawback");
        assertEq(IERC20(ventureToken).balanceOf(address(adapter)), 0, "adapter parks nothing");
        assertEq(
            IERC20(ventureToken).balanceOf(venture), treasuryBefore, "clawback was recycled, not returned to treasury"
        );

        // ── 4. The departing grantee keeps exactly what they earned, and can still claim it ──
        assertTrue(VestingAllocation(leaverGrant).terminated(), "leaver's vesting stopped");
        uint256 leaverWithdrawable = BaseAllocation(leaverGrant).getAmountWithdrawable();
        assertEq(leaverWithdrawable, earned, "leaver keeps precisely what vested before they left");

        uint256 charlieBefore = IERC20(ventureToken).balanceOf(charlie);
        vm.prank(charlie);
        BaseAllocation(leaverGrant).withdraw(leaverWithdrawable);
        assertEq(IERC20(ventureToken).balanceOf(charlie) - charlieBefore, earned, "leaver claims it for real");
        assertEq(IERC20(ventureToken).balanceOf(leaverGrant), 0, "nothing stranded in the terminated grant");

        // ── 5. The replacement's fresh ladder is live and genuinely unmet ──
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        uint160 threshold = adapter.effectiveThreshold(replacementGrant, 0);
        assertGt(threshold, 0, "a fresh ladder was registered on the new allocation");
        assertLt(_twapPriceX96(venture), threshold, "precondition: live TWAP below the replacement's threshold");
        vm.expectRevert(BaseAllocation.MetaVesT_ConditionNotSatisfied.selector);
        BaseAllocation(replacementGrant).confirmMilestone(0);

        // ── 6. A real spot move lifts the window average past it, and the milestone confirms ──
        _swapSpot(venture, 40_000e6, true);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        assertGt(_twapPriceX96(venture), threshold, "spot push clears the replacement's threshold");
        BaseAllocation(replacementGrant).confirmMilestone(0);
        assertEq(BaseAllocation(replacementGrant).milestoneUnlockedTotal(), AWARD, "price milestone unlocked");

        // ── 7. The replacement vests out and withdraws real tokens ──
        vm.warp(block.timestamp + 2 * STREAM_DURATION);
        uint256 daveWithdrawable = BaseAllocation(replacementGrant).getAmountWithdrawable();
        assertEq(daveWithdrawable, clawback, "replacement can claim the whole recycled grant");

        uint256 daveBefore = IERC20(ventureToken).balanceOf(dave);
        vm.prank(dave);
        BaseAllocation(replacementGrant).withdraw(daveWithdrawable);
        assertEq(IERC20(ventureToken).balanceOf(dave) - daveBefore, clawback, "replacement claims it for real");

        // Every token of the original grant ended up with one of the two grantees.
        assertEq(earned + clawback, TOTAL, "the original grant is fully accounted for");

        // ── 8. The venture can take the admin path away; futarchy keeps it ──
        vm.prank(hub.governanceExecutor(venture));
        Venture(payable(venture))
            .executeCall(address(adapter), 0, abi.encodeCall(IVentureVestingAuthority.setVestingAdminRevoked, (true)));
        assertEq(adapter.effectiveVestingAdmin(), address(0), "venture revoked the admin path");
        vm.prank(admin);
        vm.expectRevert(IVentureVestingAuthority.NotAuthorized.selector);
        adapter.terminateGrant(replacementGrant);
    }

    function _buildGrant()
        internal
        view
        returns (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones)
    {
        address[] memory conds = new address[](1);
        conds[0] = address(condition);

        milestones = new BaseAllocation.Milestone[](1);
        milestones[0] = BaseAllocation.Milestone({
            milestoneAward: AWARD, unlockOnCompletion: true, complete: false, conditionContracts: conds
        });

        alloc = BaseAllocation.Allocation({
            tokenStreamTotal: STREAM,
            vestingCliffCredit: 0,
            unlockingCliffCredit: 0,
            vestingRate: STREAM_RATE,
            vestingStartTime: uint48(block.timestamp),
            unlockRate: STREAM_RATE,
            unlockStartTime: uint48(block.timestamp),
            tokenContract: ventureToken
        });
    }

    /// @dev `controller.createMetavest` calldata for a grant with an explicit allocation + milestones.
    function _encodeCreateMetavest(
        address grantee,
        BaseAllocation.Allocation memory alloc,
        BaseAllocation.Milestone[] memory milestones
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            controller.createMetavest,
            (metavestController.metavestType.Vesting, grantee, alloc, milestones, 0, address(0), 0, 0)
        );
    }

    /// @dev `controller.createMetavest` calldata for the standard grant to `grantee`.
    function _createMetavestCalldata(address grantee) internal view returns (bytes memory) {
        (BaseAllocation.Allocation memory alloc, BaseAllocation.Milestone[] memory milestones) = _buildGrant();
        return _encodeCreateMetavest(grantee, alloc, milestones);
    }

    /// @dev The governance plan that funds + creates a grant entirely through the adapter:
    ///        1. MINT_TOKENS(treasury, TOTAL)                     — treasury prints the grant tokens
    ///        2. TRANSFER_TREASURY_ASSETS(ERC20 -> adapter, TOTAL) — funds the adapter (= authority)
    ///        3. CALL(adapter, forward(createMetavest(...)))       — adapter pulls TOTAL & deploys grant
    function _buildFundingPlan(address grantee) internal view returns (bytes memory) {
        bytes memory createCalldata = _createMetavestCalldata(grantee);

        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](3);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: venture, amount: TOTAL}))
        });
        actions[1] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS,
            actionVersion: 1,
            data: abi.encode(
                GovernanceTypes.TransferTreasuryAssets({
                    assetType: GovernanceTypes.AssetType.ERC20,
                    token: ventureToken,
                    to: address(adapter),
                    amount: TOTAL,
                    tokenId: 0,
                    data: ""
                })
            )
        });
        actions[2] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.CALL,
            actionVersion: 1,
            data: abi.encode(
                GovernanceTypes.Call({
                    target: address(adapter),
                    value: 0,
                    data: abi.encodeCall(
                        IVentureVestingAuthority.forward, (createCalldata, _relativeLadder(MILESTONE_MULTIPLE))
                    )
                })
            )
        });

        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }

    /// @dev Drives the funding plan through a REAL decision market (create -> trade -> settle ->
    ///      execute) and returns the freshly deployed allocation, captured via the vesting factory's
    ///      CREATE nonce just before execution.
    function _createGrantViaFutarchy(address grantee) internal returns (address) {
        uint256 _marketId = _createGrantMarket(_buildFundingPlan(grantee));

        _setupTrader(beneficiary);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(beneficiary);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 grantProposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(grantProposalId);

        uint256 virtualMoney = mm.balanceOf(beneficiary, proposal.virtualMoneyId);
        _swapExactIn(beneficiary, grantProposalId, virtualMoney / 2, false);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);
        assertEq(mm.winningProposalByMarketId(_marketId).proposalId, grantProposalId, "grant proposal should win");

        address predicted = vm.computeCreateAddress(vestingFactory, vm.getNonce(vestingFactory));
        vm.warp(block.timestamp + 1 hours);
        mm.executeWinningProposal(_marketId);
        return predicted;
    }

    function _createGrantMarket(bytes memory payload) internal returns (uint256 _marketId) {
        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "fund vesting grant", executionPayload: payload});

        _marketId = _createMarket(ventureId, proposals);
    }

    /// @dev The linear stream portion vested so far (capped at STREAM).
    function _expectedStreamVested() internal view returns (uint256) {
        uint48 start = VestingAllocation(allocation).getMetavestDetails().vestingStartTime;
        return _linearVested(STREAM, STREAM_RATE, start, 0);
    }

    /// @dev Mirrors `VestingAllocation.getVestedTokenAmount` for a milestone-free grant: a lump `cliff`
    ///      credited at `start`, then linear `rate`, capped at `streamTotal`; zero before `start`.
    function _linearVested(uint256 streamTotal, uint160 rate, uint48 start, uint256 cliff)
        internal
        view
        returns (uint256)
    {
        if (block.timestamp < start) return 0;
        uint256 vested = (block.timestamp - start) * rate + cliff;
        return vested > streamTotal ? streamTotal : vested;
    }

    /// @dev Funds + creates a grant with an arbitrary schedule through the real adapter path (mint ->
    ///      transfer to the adapter -> `forward(createMetavest)`), as a futarchy execution would, and
    ///      returns the freshly deployed allocation.
    function _createGrantViaExecutor(
        address grantee,
        BaseAllocation.Allocation memory alloc,
        BaseAllocation.Milestone[] memory milestones,
        uint256 fundAmount
    ) internal returns (address) {
        IVentureVestingAuthority.PriceProgramInput memory program =
            milestones.length == 0 ? _noProgram() : _relativeLadder(MILESTONE_MULTIPLE);
        return _createGrantViaExecutor(grantee, alloc, milestones, fundAmount, program);
    }

    function _createGrantViaExecutor(
        address grantee,
        BaseAllocation.Allocation memory alloc,
        BaseAllocation.Milestone[] memory milestones,
        uint256 fundAmount,
        IVentureVestingAuthority.PriceProgramInput memory program
    ) internal returns (address predicted) {
        address executor = hub.governanceExecutor(venture);
        bytes memory createCalldata = _encodeCreateMetavest(grantee, alloc, milestones);

        vm.prank(executor);
        Venture(payable(venture)).mint(venture, fundAmount);
        vm.prank(executor);
        Venture(payable(venture))
            .executeCall(ventureToken, 0, abi.encodeCall(IERC20.transfer, (address(adapter), fundAmount)));

        predicted = vm.computeCreateAddress(vestingFactory, vm.getNonce(vestingFactory));
        vm.prank(executor);
        Venture(payable(venture))
            .executeCall(
                address(adapter), 0, abi.encodeCall(IVentureVestingAuthority.forward, (createCalldata, program))
            );
    }

    /// @dev A single-milestone relative ladder: unlock when the TWAP reaches `multipleX1e6` times the
    ///      auction clearing price (1e6 scale). Written atomically with the grant through the adapter.
    function _relativeLadder(uint256 multipleX1e6)
        internal
        pure
        returns (IVentureVestingAuthority.PriceProgramInput memory)
    {
        uint256[] memory m = new uint256[](1);
        m[0] = multipleX1e6;
        return IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.Relative,
            absoluteThresholds: new uint160[](0),
            multiplesX1e6: m,
            cliffs: new uint48[](0)
        });
    }

    /// @dev A single-milestone relative ladder whose milestone also carries a time cliff: it confirms
    ///      only once `cliff` has elapsed AND the TWAP has reached the multiple.
    function _relativeLadderWithCliff(uint256 multipleX1e6, uint48 cliff)
        internal
        pure
        returns (IVentureVestingAuthority.PriceProgramInput memory program)
    {
        program = _relativeLadder(multipleX1e6);
        uint48[] memory c = new uint48[](1);
        c[0] = cliff;
        program.cliffs = c;
    }

    /// @dev No price program (a grant with no price-gated milestones).
    function _noProgram() internal pure returns (IVentureVestingAuthority.PriceProgramInput memory) {
        return IVentureVestingAuthority.PriceProgramInput({
            kind: IVentureVestingAuthority.PriceProgramKind.None,
            absoluteThresholds: new uint160[](0),
            multiplesX1e6: new uint256[](0),
            cliffs: new uint48[](0)
        });
    }
}
