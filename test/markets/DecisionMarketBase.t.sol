// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PosmTestSetup} from "@uniswap/v4-periphery/test/shared/PosmTestSetup.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {VentureProxy} from "../../src/core/VentureProxy.sol";

import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {UmiaMarketStake} from "../../src/core/UmiaMarketStake.sol";
import {IUmiaMarketStake} from "../../src/interfaces/IUmiaMarketStake.sol";
import {ConditionalMarketOracle} from "../../src/periphery/ConditionalMarketOracle.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {UmiaLBP} from "../../src/launchpad/UmiaLBP.sol";
import {UmiaLBPFactory} from "../../src/launchpad/UmiaLBPFactory.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {ContinuousClearingAuctionFactory} from "@continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "@continuous-clearing-auction/../test/utils/AuctionStepsBuilder.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";

// Imports needed for tests to find the right artifact files.
// forge-lint: disable-next-line(unused-import)
import {PositionDescriptor} from "@uniswap/v4-periphery/src/PositionDescriptor.sol";
// forge-lint: disable-next-line(unused-import)
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";

/// @title DecisionMarketBase
/// @notice Shared test setup and helper functions for decision market tests
abstract contract DecisionMarketBase is Test, PosmTestSetup {
    using AuctionStepsBuilder for bytes;
    using FixedPointMathLib for *;

    address umiaAdmin = makeAddr("umiaAdmin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");
    address auctionBidder = makeAddr("auctionBidder");

    uint256 internal constant SIGNER_PRIVATE_KEY = 0xabc123;
    address marketCreationSigner;

    StateView stateView;

    UmiaHub hub;
    UmiaMarketCore mm;
    UmiaMarketStake marketStake;
    ConditionalMarketOracle conditionalMarketOracle;
    UmiaLBPFactory lbpFactory;
    UmiaHook umiaHook;
    ContinuousClearingAuctionFactory ccaFactory;

    MockERC20 usdc;

    uint256 ventureId;
    address payable venture;
    address ventureToken;
    uint256 marketId;

    uint256 internal constant MIN_MARKET_STAKE = 10_000e18;

    uint256 internal constant VENTURE_BPS = 2000;
    uint160 internal constant HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);
    uint256 internal constant AUCTION_FLOOR_PRICE = FixedPoint96.Q96 / 1e15;
    uint256 internal constant AUCTION_TARGET_PRICE = 2 * AUCTION_FLOOR_PRICE;

    struct LBPBlockConfig {
        uint64 startBlock;
        uint64 endBlock;
        uint64 migrationBlock;
        uint64 sweepBlock;
    }

    // Test-only read shapes assembled from the core's tuple getters.
    struct Market {
        uint256 id;
        string title;
        uint256 ventureId;
        uint256 tradingStart;
        uint256 tradingEnd;
        uint256[] proposalIds;
        uint16 winningThresholdBps;
    }

    struct Proposal {
        uint256 id;
        string title;
        bool isNoOp;
        uint256 virtualVentureId;
        uint256 virtualMoneyId;
        bytes executionPayload;
    }

    struct LiquidityRemovalInfo {
        uint256 lpTokenId;
        uint256 ventureRemoved;
        uint256 moneyRemoved;
        uint128 liquidityRemoved;
    }

    function setUp() public virtual {
        // Anchor the whole suite to a realistic unix time so time-relative tests (vesting, TWAP)
        // and the SpotMarketOracle's int48 tickCumulative operate from one consistent baseline. A
        // mid-setup warp would leave pool bootstrap and grant creation at different epochs, and a
        // multi-year gap between bootstrap and market creation overflows the oracle.
        vm.warp(1_700_000_000);
        marketCreationSigner = vm.addr(SIGNER_PRIVATE_KEY);

        deployFreshManagerAndRouters();
        deployPosm(manager);
        stateView = new StateView(manager);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.label(address(usdc), "USDC");
        usdc.mint(alice, 1_000_000 * 1e6);
        usdc.mint(bob, 1_000_000 * 1e6);
        usdc.mint(charlie, 1_000_000 * 1e6);
        usdc.mint(dave, 1_000_000 * 1e6);

        ccaFactory = new ContinuousClearingAuctionFactory(address(0));

        vm.startPrank(umiaAdmin);
        UmiaHub hubImpl = new UmiaHub();
        hub = UmiaHub(address(new ERC1967Proxy(address(hubImpl), abi.encodeCall(UmiaHub.initialize, (umiaAdmin)))));
        vm.stopPrank();

        umiaHook = _deployUmiaHook();
        lbpFactory = new UmiaLBPFactory(IPoolManager(address(manager)), address(umiaHook), address(hub));
        umiaHook.initialize(address(lbpFactory), IPoolManager(address(manager)));

        vm.startPrank(umiaAdmin);
        conditionalMarketOracle = new ConditionalMarketOracle(address(hub));
        UmiaMarketCore mmImpl = new UmiaMarketCore();
        mm = UmiaMarketCore(
            address(new ERC1967Proxy(address(mmImpl), abi.encodeCall(UmiaMarketCore.initialize, (address(hub)))))
        );
        marketStake = new UmiaMarketStake(address(hub));
        Venture ventureImpl = new Venture();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(ventureImpl), umiaAdmin);
        hub.setVentureBeacon(address(beacon));
        hub.setUmiaMarketCore(address(mm));
        hub.setUmiaMarketStake(address(marketStake));
        hub.setConditionalMarketOracle(address(conditionalMarketOracle));
        hub.setApprovedMoneyToken(address(usdc), true);
        hub.setMarketCreationSigner(marketCreationSigner);
        hub.setLbpStrategyFactory(address(lbpFactory));
        hub.setCcaFactory(address(ccaFactory));
        hub.setDefaultGovernanceExecutor(address(new GovernanceExecutor(address(hub))));
        // Shortest allowed execution delay by default; the delay behavior is covered explicitly.
        hub.setDecisionMarketExecutionDelay(hub.MIN_EXECUTION_DELAY());
        vm.stopPrank();

        vm.label(address(hub), "HUB");
        vm.label(address(mm), "MM");
        vm.label(address(marketStake), "MARKET_STAKE");
        vm.label(address(conditionalMarketOracle), "COND_ORACLE");
    }

    // ─────────────────────────────────────────────────────────
    // LBP Helpers
    // ─────────────────────────────────────────────────────────

    function _defaultBlockConfig() internal view returns (LBPBlockConfig memory) {
        return LBPBlockConfig({
            startBlock: uint64(block.number + 1),
            endBlock: uint64(block.number + 101),
            migrationBlock: uint64(block.number + 201),
            sweepBlock: uint64(block.number + 401)
        });
    }

    function _createVentureWithLBP(UmiaHub targetHub, address creator)
        internal
        returns (uint256 id, address payable ventureAddr)
    {
        return _createVentureWithLBP(targetHub, creator, "testVenture", "TEST", 1_000_000e18);
    }

    function _createVentureWithLBP(
        UmiaHub targetHub,
        address creator,
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) internal returns (uint256 id, address payable ventureAddr) {
        LBPBlockConfig memory blocks;
        (id, ventureAddr, blocks) = _createVentureWithPendingLBP(targetHub, creator, name, symbol, initialSupply);
        _runAuctionAndMigrate(Venture(payable(ventureAddr)).lbp(), blocks);
    }

    function _createVentureWithPendingLBP(
        UmiaHub targetHub,
        address creator,
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) internal returns (uint256 id, address payable ventureAddr, LBPBlockConfig memory blocks) {
        return _createVentureWithPendingLBP(targetHub, creator, name, symbol, initialSupply, 5_000_000);
    }

    function _createVentureWithPendingLBP(
        UmiaHub targetHub,
        address creator,
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 tokenSplitToAuction
    ) internal returns (uint256 id, address payable ventureAddr, LBPBlockConfig memory blocks) {
        return
            _createVentureWithPendingLBP(
                targetHub, creator, name, symbol, initialSupply, tokenSplitToAuction, address(0)
            );
    }

    function _createVentureWithPendingLBP(
        UmiaHub targetHub,
        address creator,
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 tokenSplitToAuction,
        address validationHook
    ) internal returns (uint256 id, address payable ventureAddr, LBPBlockConfig memory blocks) {
        blocks = _defaultBlockConfig();
        (id, ventureAddr) = _createVentureWithPendingLBP(
            targetHub, creator, name, symbol, initialSupply, tokenSplitToAuction, validationHook, blocks
        );
    }

    function _createVentureWithPendingLBP(
        UmiaHub targetHub,
        address creator,
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 tokenSplitToAuction,
        address validationHook,
        LBPBlockConfig memory blocks
    ) internal returns (uint256 id, address payable ventureAddr) {
        bytes memory auctionParams = _buildAuctionParams(blocks, validationHook);

        address[] memory teamMembers = new address[](1);
        teamMembers[0] = creator;

        vm.prank(targetHub.owner());
        (id, ventureAddr) = targetHub.createVenture(
            IUmiaHub.CreateVentureParams({
                name: name,
                symbol: symbol,
                initialSupply: initialSupply,
                moneyToken: address(usdc),
                tokenSplitToAuction: tokenSplitToAuction,
                auctionParams: auctionParams,
                ventureBps: VENTURE_BPS,
                lbpSalt: bytes32(0),
                teamMembers: teamMembers,
                tradingPauseDuration: 0,
                startingMonthlyAllowance: 0
            })
        );
    }

    function _buildAuctionParams(LBPBlockConfig memory blocks) internal view returns (bytes memory) {
        return _buildAuctionParams(blocks, address(0));
    }

    function _buildAuctionParams(LBPBlockConfig memory blocks, address validationHook)
        internal
        view
        returns (bytes memory)
    {
        bytes memory stepsData = AuctionStepsBuilder.init().addStep(100_000, 50).addStep(100_000, 50);

        uint256 floorPrice = AUCTION_FLOOR_PRICE;

        AuctionParameters memory auctionParams = AuctionParameters({
            currency: address(usdc),
            tokensRecipient: address(1),
            fundsRecipient: address(1),
            startBlock: blocks.startBlock,
            endBlock: blocks.endBlock,
            claimBlock: blocks.migrationBlock,
            tickSpacing: floorPrice,
            validationHook: validationHook,
            floorPrice: floorPrice,
            requiredCurrencyRaised: 0,
            auctionStepsData: stepsData
        });

        return abi.encode(auctionParams);
    }

    function _deployUmiaHook() internal returns (UmiaHook hook) {
        // INITIAL_OWNER is `address(this)` so the test can call initialize on the freshly deployed hook.
        (, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(UmiaHook).creationCode, abi.encode(address(this)));
        hook = new UmiaHook{salt: salt}(address(this));
    }

    function _runAuctionAndMigrate(address lbpAddr, LBPBlockConfig memory blocks) internal {
        _runAuctionAndMigrate(lbpAddr, blocks, 250_000e18);
    }

    /// @dev `tokensAtTargetPrice` sizes the bid. The auction clears at its floor whenever demand
    ///      falls short of supply, so the bidder ends up with twice that many tokens.
    function _runAuctionAndMigrate(address lbpAddr, LBPBlockConfig memory blocks, uint256 tokensAtTargetPrice)
        internal
    {
        _runAuctionAndMigrate(lbpAddr, blocks, tokensAtTargetPrice, bytes(""));
    }

    function _runAuctionAndMigrate(
        address lbpAddr,
        LBPBlockConfig memory blocks,
        uint256 tokensAtTargetPrice,
        bytes memory hookData
    ) internal {
        UmiaLBP _lbp = UmiaLBP(payable(lbpAddr));
        IContinuousClearingAuction auction = IContinuousClearingAuction(address(_lbp.initializer()));

        vm.roll(blocks.startBlock);

        uint128 bidAmount = _auctionBidAmount(tokensAtTargetPrice);
        _fundAuctionBidder(auctionBidder, address(auction), bidAmount);

        vm.prank(auctionBidder);
        auction.submitBid(AUCTION_TARGET_PRICE, bidAmount, auctionBidder, AUCTION_FLOOR_PRICE, hookData);

        vm.roll(blocks.endBlock);
        auction.checkpoint();

        vm.roll(uint256(blocks.endBlock) + _lbp.hub().migrationDelayBlocks());
        _lbp.migrate();
    }

    function _auctionBidAmount(uint256 tokensAtTargetPrice) internal pure returns (uint128) {
        return uint128(tokensAtTargetPrice.fullMulDivUp(AUCTION_TARGET_PRICE, FixedPoint96.Q96));
    }

    function _fundAuctionBidder(address bidder, address auction, uint128 amount) internal {
        usdc.mint(bidder, amount);
        vm.startPrank(bidder);
        usdc.approve(address(permit2), amount);
        permit2.approve(address(usdc), auction, uint160(amount), uint48(block.timestamp + 1000));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // Market Helpers
    // ─────────────────────────────────────────────────────────

    function _createVentureAndMarket() internal returns (uint256 _marketId) {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();
        vm.label(ventureToken, "ALICE");

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 10%", executionPayload: ""});
        proposals[1] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 15%", executionPayload: ""});

        _marketId = _createMarket(ventureId, proposals);
    }

    /// @dev Stakes, signs, and creates a market for `_ventureId` with the given `proposals`, mirroring
    ///      the staking + EIP-712 boilerplate. `alice` (a venture team member) is the creator.
    function _createMarket(uint256 _ventureId, IUmiaMarketCore.CreateProposalParams[] memory proposals)
        internal
        returns (uint256 _marketId)
    {
        // The vault's sandwich guard on the seed pull fails closed until the spot oracle can serve the
        // full TWAP window, so warm it before creating the market.
        _warmSpotOracle(venture);

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(_ventureId, MIN_MARKET_STAKE);

        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);

        vm.startPrank(alice);

        IERC20(ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(_ventureId);

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: _ventureId,
            title: "should we cut yearly emissions?",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        _marketId = mm.createMarket(params, alice, nonce, signature);
        marketId = _marketId;

        vm.stopPrank();
    }

    /// @dev True once the venture's spot oracle can serve the full 30-min TWAP window. Mirrors
    ///      SpotLiquidityVault._oracleHasFullWindow; below this the vault sandwich guard fails closed.
    function _spotOracleReady(address _venture) internal view returns (bool) {
        PoolKey memory key = ISpotLiquidityVault(hub.ventureLiquidityVault(_venture)).getPoolKey();
        PoolId id = PoolIdLibrary.toId(key);
        (uint16 cIndex, uint16 cardinality,) = umiaHook.oracleStates(id);
        if (cardinality < 2) return false;
        uint16 oldestIndex = (cIndex + 1) % cardinality;
        (uint32 oldestTs,,, bool oldestInit) = umiaHook.getObservation(id, oldestIndex);
        if (!oldestInit) {
            (oldestTs,,, oldestInit) = umiaHook.getObservation(id, 0);
            if (!oldestInit) return false;
        }
        return block.timestamp >= oldestTs + 30 minutes;
    }

    /// @dev Warm the venture's spot oracle so the vault sandwich guard passes: seed a second
    ///      observation via a small spot swap in a new block, then age it past the TWAP window.
    function _warmSpotOracle(address _venture) internal {
        if (hub.ventureLiquidityVault(_venture) == address(0)) return;
        if (_spotOracleReady(_venture)) return;
        vm.warp(block.timestamp + 1);
        _swapSpot(_venture, 100e18, false);
        vm.warp(block.timestamp + 30 minutes);
    }

    /// @dev Small exact-input spot swap on the venture's migrated V4 pool (records an oracle
    ///      observation). `buyVenture` raises the price; otherwise lowers it.
    function _swapSpot(address _venture, uint256 amountIn, bool buyVenture) internal {
        address token = Venture(payable(_venture)).token();
        PoolKey memory key = ISpotLiquidityVault(hub.ventureLiquidityVault(_venture)).getPoolKey();
        bool ventureIsCurrency0 = Currency.unwrap(key.currency0) == token;
        bool zeroForOne = buyVenture ? !ventureIsCurrency0 : ventureIsCurrency0;

        address inToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        address swapper = makeAddr("spotSwapper");
        if (inToken == token) {
            _mintVenture(hub, _venture, swapper, amountIn);
        } else {
            usdc.mint(swapper, amountIn);
        }

        vm.prank(swapper);
        IERC20(inToken).approve(address(swapRouter), amountIn);

        vm.prank(swapper);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Helper to setup a trader with approvals
    function _setupTrader(address trader) internal {
        vm.startPrank(trader);
        usdc.approve(address(mm), type(uint256).max);
        IERC20(ventureToken).approve(address(mm), type(uint256).max);
        vm.stopPrank();
    }

    function _mintVenture(UmiaHub targetHub, address ventureAddr, address to, uint256 amount) internal {
        address executor = targetHub.governanceExecutor(ventureAddr);
        vm.prank(executor);
        Venture(payable(ventureAddr)).mint(to, amount);
    }

    /// @dev Helper to sign market creation params
    function _signMarketCreation(address creator, IUmiaMarketCore.CreateMarketParams memory params, uint256 nonce)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 proposalsHash = keccak256(abi.encode(params.proposals));
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
                proposalsHash,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", mm.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PRIVATE_KEY, digest);
        signature = abi.encodePacked(r, s, v);
    }

    /// @dev Helper to perform a swap with slippage protection
    function _swapExactIn(address trader, uint256 proposalId, uint256 amountIn, bool zeroForOne)
        internal
        returns (uint256 amountOut)
    {
        vm.startPrank(trader);
        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, amountIn, zeroForOne);
        uint256 maxPriceImpact = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;
        amountOut = mm.swapExactIn(proposalId, amountIn, amountOutMin, maxPriceImpact, zeroForOne, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Get total virtual token supply for a proposal (user + CPMM reserves)
    function _getTotalVirtualSupply(uint256 proposalId)
        internal
        view
        returns (uint256 totalVenture, uint256 totalMoney)
    {
        uint256 virtualVentureId = mm.getVirtualVentureId(proposalId);
        uint256 virtualMoneyId = mm.getVirtualMoneyId(proposalId);
        totalVenture = mm.totalSupply(virtualVentureId);
        totalMoney = mm.totalSupply(virtualMoneyId);
    }

    function _marketById(uint256 _marketId) internal view returns (Market memory market) {
        (market.id, market.ventureId, market.tradingStart, market.tradingEnd) = mm.marketInfo(_marketId);
        market.proposalIds = mm.marketProposalIds(_marketId);
    }

    function _proposalById(uint256 proposalId) internal view returns (Proposal memory proposal) {
        (proposal.id, proposal.title, proposal.isNoOp, proposal.virtualVentureId, proposal.virtualMoneyId) =
            mm.proposalInfo(proposalId);
    }

    function _marketSettlementState(uint256 _marketId)
        internal
        view
        returns (uint256 realVenture, uint256 realMoney, LiquidityRemovalInfo memory removalInfo)
    {
        (
            realVenture,
            realMoney,
            removalInfo.lpTokenId,
            removalInfo.ventureRemoved,
            removalInfo.moneyRemoved,
            removalInfo.liquidityRemoved
        ) = mm.marketSettlementState(_marketId);
    }

    function _realVentureBalance(uint256 _marketId) internal view returns (uint256 realVenture) {
        (realVenture,,) = _marketSettlementState(_marketId);
    }

    function _realMoneyBalance(uint256 _marketId) internal view returns (uint256 realMoney) {
        (, realMoney,) = _marketSettlementState(_marketId);
    }

    function _liquidityRemovalInfo(uint256 _marketId) internal view returns (LiquidityRemovalInfo memory removalInfo) {
        (,, removalInfo) = _marketSettlementState(_marketId);
    }

    function _accruedFeeVenture(uint256 proposalId) internal view returns (uint256 feeVenture) {
        (feeVenture,) = mm.proposalFeeState(proposalId);
    }

    function _accruedFeeMoney(uint256 proposalId) internal view returns (uint256 feeMoney) {
        (, feeMoney) = mm.proposalFeeState(proposalId);
    }

    /// @dev Proposal `a`'s price over proposal `b`'s, in 1e18.
    function _priceRatio(uint256 a, uint256 b) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = mm.cpmmStates(a);
        (uint256 b0, uint256 b1) = mm.cpmmStates(b);
        return FullMath.mulDiv(a1 * b0, 1e18, a0 * b1);
    }

    /// @dev Verify the solvency invariant holds. Mirrors the contract's per-proposal conservation:
    ///      the market's real backing for each token must cover that proposal's full outstanding
    ///      virtual supply (user-held supply + pool reserves + accrued fees). The seed escrow is
    ///      folded into the real balance at creation, so it is not added again here.
    function _verifyInvariant(uint256 _marketId) internal view {
        Market memory market = _marketById(_marketId);

        uint256 realVenture = _realVentureBalance(_marketId);
        uint256 realMoney = _realMoneyBalance(_marketId);

        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 propId = market.proposalIds[i];
            (uint256 reserve0, uint256 reserve1) = mm.cpmmStates(propId);
            uint256 ventureLiability = mm.userVirtualVentureSupply(propId) + reserve0 + _accruedFeeVenture(propId);
            uint256 moneyLiability = mm.userVirtualMoneySupply(propId) + reserve1 + _accruedFeeMoney(propId);
            assertGe(realVenture, ventureLiability, "Invariant violated: venture backing < liability");
            assertGe(realMoney, moneyLiability, "Invariant violated: money backing < liability");
        }
    }

    /// @dev Ground-truth solvency: the core's ACTUAL ERC-20 balances (not its internal counters) must
    ///      cover the max per-proposal virtual liability. Only valid when the core holds tokens for a
    ///      single market (the fuzz/creation harness), since money token is shared across markets.
    function _verifyGroundTruthSolvency(uint256 _marketId) internal view {
        Market memory market = _marketById(_marketId);
        address ventureTokenAddr = hub.ventureTokenById(market.ventureId);
        address moneyToken = hub.ventureMoneyTokenById(market.ventureId);

        uint256 maxVenture;
        uint256 maxMoney;
        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 propId = market.proposalIds[i];
            (uint256 reserve0, uint256 reserve1) = mm.cpmmStates(propId);
            uint256 v = mm.userVirtualVentureSupply(propId) + reserve0 + _accruedFeeVenture(propId);
            uint256 m = mm.userVirtualMoneySupply(propId) + reserve1 + _accruedFeeMoney(propId);
            if (v > maxVenture) maxVenture = v;
            if (m > maxMoney) maxMoney = m;
        }

        assertGe(
            IERC20(ventureTokenAddr).balanceOf(address(mm)), maxVenture, "Ground truth: venture balance < liability"
        );
        assertGe(IERC20(moneyToken).balanceOf(address(mm)), maxMoney, "Ground truth: money balance < liability");
    }
}
