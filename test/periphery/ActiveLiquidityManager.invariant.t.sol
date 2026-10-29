// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ActiveLiquidityManager} from "../../src/core/ActiveLiquidityManager.sol";
import {IActiveLiquidityManager} from "../../src/interfaces/IActiveLiquidityManager.sol";
import {SpotLiquidityV2TestBase} from "./ActiveLiquidityManager.t.sol";

/// @dev The ALM's book in each token: idle balance, principal (what removing every position would
///      return at the current price, as the pool computes it) and fees accrued but not yet collected
///      (from the pool's fee growth). At a fixed price this is token-exact up to a wei per position.
library AlmBook {
    using StateLibrary for IPoolManager;

    struct Snapshot {
        uint256 idle0;
        uint256 idle1;
        uint256 principal0;
        uint256 principal1;
        uint256 unrealized0;
        uint256 unrealized1;
        uint256 count;
    }

    function take(IPoolManager manager, PoolId id, ActiveLiquidityManager alm, address t0, address t1)
        internal
        view
        returns (Snapshot memory s)
    {
        s.idle0 = IERC20(t0).balanceOf(address(alm));
        s.idle1 = IERC20(t1).balanceOf(address(alm));
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        IActiveLiquidityManager.Position[] memory p = alm.positions();
        s.count = p.length;
        for (uint256 i = 0; i < p.length; i++) {
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(p[i].tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(p[i].tickUpper);
            if (sqrtPriceX96 <= sqrtA) {
                s.principal0 += SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, p[i].liquidity, false);
            } else if (sqrtPriceX96 >= sqrtB) {
                s.principal1 += SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, p[i].liquidity, false);
            } else {
                s.principal0 += SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, p[i].liquidity, false);
                s.principal1 += SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, p[i].liquidity, false);
            }
            (, uint256 last0, uint256 last1) =
                manager.getPositionInfo(id, address(alm), p[i].tickLower, p[i].tickUpper, bytes32(i));
            (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(id, p[i].tickLower, p[i].tickUpper);
            unchecked {
                s.unrealized0 += FullMath.mulDiv(p[i].liquidity, inside0 - last0, FixedPoint128.Q128);
                s.unrealized1 += FullMath.mulDiv(p[i].liquidity, inside1 - last1, FixedPoint128.Q128);
            }
        }
    }
}

/// @dev Drives the ALM, the venture, a trader and the clock with random but well-formed actions.
///      Calls that the contract is meant to refuse (guard, pause, interval, protocol-owed) are
///      caught and counted; the invariants below are checked after every call.
contract AlmHandler is Test {
    using StateLibrary for IPoolManager;

    struct Opened {
        int24 lower;
        int24 upper;
        uint256 salt;
    }

    IPoolManager immutable manager;
    PoolSwapTest immutable router;
    ActiveLiquidityManager immutable alm;
    PoolKey key;
    PoolId immutable id;
    MockERC20 immutable token0;
    MockERC20 immutable token1;
    address immutable keeper;
    address immutable venture;
    int24 immutable spacing;

    Opened[] public opened;
    uint256 public rebalances;
    uint256 public refusedRebalances;
    /// @dev Refusals by error selector, so a campaign can show which guard did the refusing.
    mapping(bytes4 => uint256) public refusedBy;
    uint256 public funded0;
    uint256 public funded1;
    /// @dev Fees traders paid into the pool per token: the input leg times the pool fee, rounded up.
    uint256 public feesPaid0;
    uint256 public feesPaid1;
    uint256 public swaps;
    /// @dev Fees the ALM's positions have collected so far, measured as the uncollected fees each
    ///      liquidity operation found and took.
    uint256 public feesRealized0;
    uint256 public feesRealized1;
    /// @dev Set when a liquidity operation changed the ALM-plus-venture token total at a fixed price.
    bool public violated;
    string public violation;
    /// @dev Fees the seeded position had already accrued from the test's own oracle warm-up swaps.
    uint256 public immutable baselineUnrealized0;
    uint256 public immutable baselineUnrealized1;
    /// @dev V4 positions the ALM has added to or removed from; each rounds against it by at most a wei.
    uint256 public touched;

    constructor(
        IPoolManager _manager,
        PoolSwapTest _router,
        ActiveLiquidityManager _alm,
        PoolKey memory _key,
        address _keeper,
        address _venture
    ) {
        manager = _manager;
        router = _router;
        alm = _alm;
        key = _key;
        id = PoolIdLibrary.toId(_key);
        token0 = MockERC20(Currency.unwrap(_key.currency0));
        token1 = MockERC20(Currency.unwrap(_key.currency1));
        keeper = _keeper;
        venture = _venture;
        spacing = _key.tickSpacing;
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        AlmBook.Snapshot memory book = AlmBook.take(_manager, id, _alm, address(token0), address(token1));
        baselineUnrealized0 = book.unrealized0;
        baselineUnrealized1 = book.unrealized1;
    }

    function openedCount() external view returns (uint256) {
        return opened.length;
    }

    /// @dev Every action moves the clock a little and writes both oracle rings, so the guards keep
    ///      a live view of the price rather than failing on stale history.
    function _advance(uint256 seed) internal {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 5 minutes, 30 minutes));
        _swap(seed % 2 == 0, 1 ether);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        (zeroForOne ? token0 : token1).mint(address(this), amountIn);
        uint256 fee = (amountIn * key.fee + 999_999) / 1_000_000;
        if (zeroForOne) feesPaid0 += fee;
        else feesPaid1 += fee;
        swaps++;
        router.swap(
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

    function _book() internal view returns (AlmBook.Snapshot memory) {
        return AlmBook.take(manager, id, alm, address(token0), address(token1));
    }

    /// @dev A liquidity operation happens at one price, so per token the ALM and the venture together
    ///      hold exactly what they held before plus the fees the operation collected; only pool
    ///      rounding, a wei per position touched, may move the total.
    function _checkOp(AlmBook.Snapshot memory before, uint256 venture0Before, uint256 venture1Before, string memory op)
        internal
    {
        AlmBook.Snapshot memory after_ = _book();
        feesRealized0 += before.unrealized0;
        feesRealized1 += before.unrealized1;
        uint256 paid0 = token0.balanceOf(venture) - venture0Before;
        uint256 paid1 = token1.balanceOf(venture) - venture1Before;
        uint256 slack = 2 * (before.count + after_.count) + 4;
        _within(
            before.idle0 + before.principal0 + before.unrealized0, after_.idle0 + after_.principal0 + paid0, slack, op
        );
        _within(
            before.idle1 + before.principal1 + before.unrealized1, after_.idle1 + after_.principal1 + paid1, slack, op
        );
        touched += before.count + after_.count;
    }

    function _within(uint256 expected, uint256 actual, uint256 slack, string memory op) internal {
        uint256 diff = expected > actual ? expected - actual : actual - expected;
        if (diff > slack && !violated) {
            violated = true;
            violation = string.concat(op, " moved the ALM+venture token total beyond rounding");
        }
    }

    function trade(bool zeroForOne, uint256 amount, uint256 seed) external {
        _advance(seed);
        _swap(zeroForOne, bound(amount, 1 ether, 3_000 ether));
    }

    function fund(uint256 amount, uint256 seed) external {
        _advance(seed);
        amount = bound(amount, 1 ether, 50_000 ether);
        token0.mint(address(alm), amount);
        token1.mint(address(alm), amount);
        funded0 += amount;
        funded1 += amount;
    }

    function rebalance(uint256 count, uint256 widthSeed, uint256 shareBps, uint256 seed) external {
        _advance(seed);
        // Clear the interval most of the time, so the campaign reshapes the book rather than
        // bouncing off RebalanceTooSoon; one attempt in eight stays early to keep that path covered.
        uint256 availableAt = uint256(alm.lastRebalance()) + alm.constraints().minRebalanceInterval;
        if (seed % 8 != 0) {
            if (vm.getBlockTimestamp() < availableAt) vm.warp(availableAt);
            // Let the 30-minute TWAP settle on the current price, as a keeper waiting for a calm
            // window would; the raw path above keeps the guard refusals covered.
            for (uint256 w = 0; w < 7; w++) {
                vm.warp(vm.getBlockTimestamp() + 5 minutes);
                _swap(w % 2 == 0, 1 ether);
            }
        }
        count = bound(count, 1, 3);
        shareBps = bound(shareBps, 1_000, 9_000);
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);
        int24 center = tick / spacing * spacing;
        if (tick < 0 && tick % spacing != 0) center -= spacing;

        uint256 spend0 = (token0.balanceOf(address(alm)) - alm.protocolOwedVenture()) * shareBps / 10_000 / count;
        uint256 spend1 = (token1.balanceOf(address(alm)) - alm.protocolOwedMoney()) * shareBps / 10_000 / count;
        IActiveLiquidityManager.Position[] memory target = new IActiveLiquidityManager.Position[](count);
        for (uint256 i = 0; i < count; i++) {
            // Widths between the ALM's min (2 spacings) and well inside its max; ranges fan out from the price.
            int24 half = int24(int256(bound(uint256(keccak256(abi.encode(widthSeed, i))), 1, 60))) * spacing;
            int24 shift = int24(int256(i)) * half;
            int24 lower = center - half + shift;
            int24 upper = center + half + shift;
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), spend0, spend1
            );
            if (liquidity == 0) return;
            target[i] = IActiveLiquidityManager.Position(lower, upper, liquidity);
        }
        AlmBook.Snapshot memory before = _book();
        (uint256 v0, uint256 v1) = (token0.balanceOf(venture), token1.balanceOf(venture));
        vm.prank(keeper);
        try alm.rebalance(target) {
            rebalances++;
            _checkOp(before, v0, v1, "rebalance");
            for (uint256 i = 0; i < count; i++) {
                opened.push(Opened(target[i].tickLower, target[i].tickUpper, i));
            }
        } catch (bytes memory err) {
            refusedRebalances++;
            refusedBy[bytes4(err)]++;
        }
    }

    function defund(uint256 share, uint256 seed) external {
        _advance(seed);
        share = bound(share, 1, 10_000);
        uint256 idle0 = token0.balanceOf(address(alm));
        uint256 idle1 = token1.balanceOf(address(alm));
        vm.prank(venture);
        try alm.defund(idle0 * share / 10_000, idle1 * share / 10_000) {} catch {}
    }

    function collect(uint256 seed) external {
        _advance(seed);
        AlmBook.Snapshot memory before = _book();
        (uint256 v0, uint256 v1) = (token0.balanceOf(venture), token1.balanceOf(venture));
        try alm.collectFees() {
            _checkOp(before, v0, v1, "collectFees");
        } catch {}
    }

    function claimProtocol(uint256 seed) external {
        _advance(seed);
        try alm.claimProtocolFees() {} catch {}
    }

    /// @dev Pauses rarely and unpauses otherwise, so the book keeps moving most of the time.
    function pause(uint256 seed) external {
        _advance(seed);
        vm.prank(venture);
        alm.setPaused(seed % 6 == 0);
    }

    function withdrawAll(uint256 seed) external {
        _advance(seed);
        if (seed % 7 != 0) return;
        AlmBook.Snapshot memory before = _book();
        (uint256 v0, uint256 v1) = (token0.balanceOf(venture), token1.balanceOf(venture));
        vm.prank(venture);
        alm.withdrawAll();
        _checkOp(before, v0, v1, "withdrawAll");
    }
}

/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract ActiveLiquidityManagerInvariantTest is SpotLiquidityV2TestBase {
    using StateLibrary for IPoolManager;

    AlmHandler handler;
    uint128 anchorLiquidity;

    function setUp() public override {
        super.setUp();
        _fund(200_000 ether);
        alm.seed(_positions(-600, 600, 1e23));
        _ageOracle(13 hours);
        anchorLiquidity = vault.currentLiquidity();

        handler = new AlmHandler(manager, swapRouter, alm, poolKey, KEEPER, VENTURE);
        targetContract(address(handler));
    }

    function _poolLiquidity(int24 lower, int24 upper, uint256 salt) internal view returns (uint128 liquidity) {
        (liquidity,,) = manager.getPositionInfo(id, address(alm), lower, upper, bytes32(salt));
    }

    /// @notice Position `i` in the ALM's list is exactly the V4 position under salt `i`.
    function invariant_saltIHoldsPositionI() public view {
        IActiveLiquidityManager.Position[] memory p = alm.positions();
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(_poolLiquidity(p[i].tickLower, p[i].tickUpper, i), p[i].liquidity);
        }
    }

    /// @notice Every range the ALM ever opened and no longer lists holds no liquidity in the pool.
    function invariant_droppedRangesAreEmpty() public view {
        IActiveLiquidityManager.Position[] memory p = alm.positions();
        uint256 n = handler.openedCount();
        for (uint256 k = 0; k < n; k++) {
            (int24 lower, int24 upper, uint256 salt) = handler.opened(k);
            bool live = salt < p.length && p[salt].tickLower == lower && p[salt].tickUpper == upper;
            if (!live) assertEq(_poolLiquidity(lower, upper, salt), 0, "a closed range still holds liquidity");
        }
    }

    /// @notice The protocol's accrued cut is always covered by idle balance; no reshape or defund spends it.
    function invariant_protocolOwedIsBackedByIdle() public view {
        assertGe(_token0().balanceOf(address(alm)), alm.protocolOwedVenture());
        assertGe(_token1().balanceOf(address(alm)), alm.protocolOwedMoney());
    }

    /// @notice Nothing the ALM, the venture or a trader does touches the anchor vault's position.
    function invariant_anchorUntouched() public view {
        assertEq(vault.currentLiquidity(), anchorLiquidity);
    }

    /// @notice The live book always respects the venture's constraints.
    function invariant_bookWithinConstraints() public view {
        IActiveLiquidityManager.Position[] memory p = alm.positions();
        IActiveLiquidityManager.Constraints memory c = alm.constraints();
        assertLe(p.length, c.maxPositions);
        for (uint256 i = 0; i < p.length; i++) {
            int24 width = p[i].tickUpper - p[i].tickLower;
            assertGe(width, c.minWidthTicks);
            assertLe(width, c.maxWidthTicks);
            assertGt(p[i].liquidity, 0);
        }
    }

    /// @notice No rebalance, fee collection or withdrawal ever changes what the ALM and the venture hold
    ///         together, beyond the fees it collected and a wei of pool rounding per position.
    function invariant_liquidityOpsConserveTokens() public view {
        assertFalse(handler.violated(), handler.violation());
    }

    /// @notice Fees the ALM has collected plus fees still sitting in its positions never exceed what
    ///         traders paid into the pool in that token. The ALM cannot earn a token nobody paid.
    function invariant_feesWithinWhatTradersPaid() public view {
        AlmBook.Snapshot memory book = AlmBook.take(manager, id, alm, address(_token0()), address(_token1()));
        // The pool rounds its fee up per swap step; a few wei per swap covers it.
        uint256 slack = 4 * handler.swaps() + 4;
        assertLe(
            handler.feesRealized0() + book.unrealized0,
            handler.baselineUnrealized0() + handler.feesPaid0() + slack,
            "token0 fees exceed what traders paid"
        );
        assertLe(
            handler.feesRealized1() + book.unrealized1,
            handler.baselineUnrealized1() + handler.feesPaid1() + slack,
            "token1 fees exceed what traders paid"
        );
    }
}
