// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IConditionalMarketOracle} from "../interfaces/IConditionalMarketOracle.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {TickSlew} from "../libraries/TickSlew.sol";

/// @title ConditionalMarketOracle
/// @notice Prices decision markets for settlement. For each proposal it keeps a time-weighted
///         geometric mean of the money-per-venture price over the trading window; settlement compares
///         those means against the snapshotted threshold.
/// @dev The mean is not of the pool's raw tick but of an accepted tick that follows the pool at a
///      fixed speed in log-price space (`TickSlew`). The TWAP is the exact time integral of that path,
///      so a price counts only as fast as the speed allows, and once trading stops the accepted tick
///      settles on the pool's real tick.
///
///      The speed is low on purpose. Proposal pools are thin. If the mean followed the pool at once,
///      someone could crash a pool for a fraction of the venture's value in the last minutes of the
///      window and flip or block the winner. At 7 ticks per second (about 4% per minute), moving a
///      two-day mean across the 2% threshold takes a hold of at least about 52 minutes, longer for
///      smaller moves, in the open, where anyone can trade against it. An honest repricing of tens of percent still registers within
///      minutes. Markets short enough for the lag to matter get a faster speed, see `slewFor`.
///
///      Because the TWAP is a mean tick, settlement's fixed-ratio comparison between proposals is a
///      fixed tick offset applied to each. The Hub can swap this contract while no market is active.
contract ConditionalMarketOracle is IConditionalMarketOracle {
    struct OracleState {
        int64 tickCumulative; // ∫ accepted tick dt, scored from tradingStart
        int24 lastTick; // accepted tick at lastTimestamp
        uint16 tickAreaRemainder; // fractional tick area carried between updates
        uint32 tradingStart;
        uint32 tradingEnd;
        uint32 lastTimestamp; // last recorded time; anchored at tradingStart on init
        uint24 slewPerSecond; // max accepted-tick movement per second, fixed at initialize
        bool initialized;
    }

    /// @notice Slew floor: 7 ticks per second, 420 ticks (about 4.3%) per minute.
    uint24 public constant MIN_TICK_SLEW_PER_SECOND = 7;
    /// @notice Ticks in a price doubling, the move `slewFor` keeps traversable within a tenth of the window.
    uint32 public constant DOUBLING_TICKS = 6931;

    IUmiaHub public immutable HUB;

    mapping(uint256 proposalId => OracleState) public oracleStates;

    error OnlyMarketCore();
    error AlreadyInitialized();
    error ProposalNotInitialized();
    error InvalidReserves();
    error InvalidTradingWindow();
    error InvalidWinningThreshold();
    error TradingNotStarted();

    event OracleInitialized(
        uint256 indexed proposalId,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint256 initialPriceX112,
        uint16 winningThresholdBps
    );

    constructor(address _hub) {
        HUB = IUmiaHub(_hub);
    }

    modifier onlyMarketCore() {
        if (msg.sender != HUB.umiaMarketCore()) revert OnlyMarketCore();
        _;
    }

    /// @inheritdoc IConditionalMarketOracle
    function initialize(
        uint256 proposalId,
        uint256 reserve0,
        uint256 reserve1,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint16 winningThresholdBps
    ) external onlyMarketCore {
        OracleState storage oracle = oracleStates[proposalId];
        if (oracle.initialized) revert AlreadyInitialized();
        if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
        if (tradingEnd <= tradingStart) revert InvalidTradingWindow();
        // Unused here; validated so the creation path keeps the same revert surface across oracles.
        if (winningThresholdBps == 0 || winningThresholdBps > 10_000) revert InvalidWinningThreshold();

        int24 seedTick = _poolTick(reserve0, reserve1);
        oracle.lastTick = seedTick;
        oracle.tradingStart = tradingStart;
        oracle.tradingEnd = tradingEnd;
        oracle.slewPerSecond = slewFor(tradingEnd - tradingStart);
        // Anchor scoring at tradingStart: the cumulative stays 0 until the first post-start update,
        // and no price-changing operation can occur before then (swaps are gated on tradingStart).
        oracle.lastTimestamp = tradingStart;
        oracle.initialized = true;

        emit OracleInitialized(proposalId, tradingStart, tradingEnd, _priceX112(seedTick), winningThresholdBps);
    }

    /// @notice Slew rate for a market of `duration` seconds: the floor, raised just enough that a
    ///         doubling registers within a tenth of the window (20 ticks per second at one hour).
    function slewFor(uint32 duration) public pure returns (uint24) {
        uint256 fastest = (uint256(DOUBLING_TICKS) * 10 + duration - 1) / duration;
        return fastest > MIN_TICK_SLEW_PER_SECOND ? uint24(fastest) : MIN_TICK_SLEW_PER_SECOND;
    }

    /// @inheritdoc IConditionalMarketOracle
    function update(uint256 proposalId, uint256 reserve0, uint256 reserve1) external onlyMarketCore {
        OracleState storage oracle = oracleStates[proposalId];
        if (!oracle.initialized) return;
        oracleStates[proposalId] = _advanced(oracle, _effectiveTimestamp(oracle.tradingEnd), reserve0, reserve1);
    }

    /// @inheritdoc IConditionalMarketOracle
    function calculateTWAP(uint256 proposalId, uint256 reserve0, uint256 reserve1)
        external
        view
        returns (uint256 twapX112)
    {
        return _priceX112(_meanTick(proposalId, reserve0, reserve1));
    }

    /// @inheritdoc IConditionalMarketOracle
    function calculateTWAPTick(uint256 proposalId, uint256 reserve0, uint256 reserve1)
        external
        view
        returns (int24 meanTick)
    {
        return _meanTick(proposalId, reserve0, reserve1);
    }

    function _meanTick(uint256 proposalId, uint256 reserve0, uint256 reserve1) internal view returns (int24) {
        OracleState memory oracle = oracleStates[proposalId];
        if (!oracle.initialized) revert ProposalNotInitialized();
        if (block.timestamp < oracle.tradingStart) revert TradingNotStarted();

        uint32 effectiveTs = _effectiveTimestamp(oracle.tradingEnd);
        uint32 scored = effectiveTs - oracle.tradingStart;
        // Queried in the first second of the window there is nothing to average yet. Return the
        // accepted tick rather than the pool's, which is same-block manipulable.
        if (scored == 0) return oracle.lastTick;

        int256 cumulative = _advanced(oracle, effectiveTs, reserve0, reserve1).tickCumulative;
        int256 mean = cumulative / int256(uint256(scored));
        // Round toward negative infinity, as Uniswap's oracle does.
        if (cumulative < 0 && cumulative % int256(uint256(scored)) != 0) mean--;
        return int24(mean);
    }

    /// @dev The state after crediting the interval up to `effectiveTs` at the given reserves. Nothing is
    ///      credited before tradingStart, within the same second, after the end freeze, or for a
    ///      degenerate pool, whose interval stays open for the next well-formed update.
    function _advanced(OracleState memory oracle, uint32 effectiveTs, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (OracleState memory)
    {
        if (effectiveTs <= oracle.lastTimestamp || reserve0 == 0 || reserve1 == 0) return oracle;
        (int24 nextTick, int48 areaDelta, uint16 remainder) = TickSlew.advance(
            oracle.lastTick,
            _poolTick(reserve0, reserve1),
            effectiveTs - oracle.lastTimestamp,
            oracle.tickAreaRemainder,
            oracle.slewPerSecond
        );
        oracle.tickCumulative += areaDelta;
        oracle.lastTick = nextTick;
        oracle.tickAreaRemainder = remainder;
        oracle.lastTimestamp = effectiveTs;
        return oracle;
    }

    /// @dev Current time capped at the trading-end freeze.
    function _effectiveTimestamp(uint32 tradingEnd) internal view returns (uint32) {
        uint32 ts = uint32(block.timestamp);
        return ts > tradingEnd ? tradingEnd : ts;
    }

    /// @dev The pool's tick for money per venture (`reserve1 / reserve0`). The ratio is saturated before
    ///      any product that could overflow, and the result is clamped to the V4 tick range, so no
    ///      reserve pair can make an update or a settlement read revert.
    function _poolTick(uint256 reserve0, uint256 reserve1) internal pure returns (int24) {
        uint256 whole = reserve1 / reserve0;
        uint256 sqrtPriceX96;
        if (whole < 1 << 64) {
            sqrtPriceX96 = Math.sqrt(FullMath.mulDiv(reserve1, 1 << 192, reserve0));
        } else if (whole < 1 << 128) {
            sqrtPriceX96 = Math.sqrt(FullMath.mulDiv(reserve1, 1 << 64, reserve0)) << 64;
        } else {
            sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        }
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE) sqrtPriceX96 = TickMath.MIN_SQRT_PRICE;
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        return TickMath.getTickAtSqrtPrice(uint160(sqrtPriceX96));
    }

    /// @dev Money per venture at `tick`, in Q112.112.
    function _priceX112(int24 tick) internal pure returns (uint256) {
        uint256 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 80);
    }
}
