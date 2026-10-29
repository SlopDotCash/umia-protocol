// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PositionAmounts} from "../libraries/PositionAmounts.sol";
import {SpotTwapGuard} from "../libraries/SpotTwapGuard.sol";
import {ActiveSlices} from "../libraries/ActiveSlices.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {IActiveLiquidityManager} from "../interfaces/IActiveLiquidityManager.sol";
import {IUmiaMarketCore} from "../interfaces/IUmiaMarketCore.sol";

/// @title ActiveLiquidityManager
/// @notice The venture's second spot position: a few concentrated ranges near the price that a keeper
///         reshapes, so traders get better fills than the full-range anchor alone can give. The
///         treasury funds it by plain transfer. Decision markets never borrow from it.
/// @dev Why a keeper can be trusted with treasury capital:
///
///      - It can only reshape. Tokens leave this contract for the pool, the venture, or the protocol
///        fee recipient. The one other path is basket arbitrage, below, which must end with the
///        balances intact.
///      - It reshapes inside limits the venture sets (`Constraints`): how many ranges, how wide, how
///        often.
///      - It reshapes only while spot is close to two TWAPs: within `maxTwapDeviationTicks` of the
///        30-minute TWAP and within 500 ticks (about 5%) of the 12-hour TWAP. The short band is
///        capped at the pool fee, so a keeper who pushes spot, parks a range at the pushed price and
///        trades into it pays at least as much in fees as the band lets it take. Holding the push
///        until the 30-minute TWAP catches up does not help: the 12-hour TWAP takes hours to follow,
///        and the long band caps what a range placed in the meantime can lose at a few fees.
///
///      Position `i` is the V4 position under salt `i`. V4 keeps accrued swap fees apart from
///      principal; each reshape pays them to the venture, minus the protocol cut.
///
///      In its own venture's decision markets the ALM may run basket arbitrage: buy on spot and sell
///      the same reserve fraction into every proposal pool, or the reverse. Moving every proposal by
///      the same factor leaves their ranking alone, so MarketCore waives the decision-market fee and
///      no TWAP guard applies. The trade reverts if either real balance ends lower than it started or
///      the money gain falls short of the keeper's `minMoneyProfit`, so a bad keeper can cost the
///      venture only gas.
///
///      Registered on `UmiaHookV2` as the pool's active operator. V4 keys positions by owner, so the
///      ALM can never touch the anchor vault's position.
contract ActiveLiquidityManager is IActiveLiquidityManager, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Hard cap on `Constraints.maxPositions`.
    uint8 public constant MAX_POSITIONS = 8;
    uint16 internal constant MAX_BPS = 10_000;
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint32 internal constant LONG_TWAP_WINDOW = 12 hours;
    /// @dev Max |spot tick - 12-hour TWAP tick| (~5%) at which a rebalance may run.
    int24 internal constant MAX_LONG_TICK_DEVIATION = 500;

    /// @inheritdoc IActiveLiquidityManager
    address public immutable HUB;
    /// @inheritdoc IActiveLiquidityManager
    address public immutable venture;
    /// @notice The Uniswap v4 PoolManager.
    address public immutable poolManager;
    /// @inheritdoc IActiveLiquidityManager
    address public immutable hook;
    /// @notice May call `seed` once, before any rebalance (`SpotMigrator` for migrated pools).
    address public immutable bootstrapper;
    /// @notice The venture's token.
    address public immutable ventureToken;
    /// @notice The venture's money token, the pool's other side.
    address public immutable moneyToken;
    /// @notice Whether the venture token is `currency0` of the pool.
    bool public immutable ventureIsToken0;
    uint24 internal immutable _poolFee;
    int24 internal immutable _poolTickSpacing;
    PoolId internal immutable _poolId;

    /// @inheritdoc IActiveLiquidityManager
    bool public paused;
    /// @inheritdoc IActiveLiquidityManager
    uint64 public lastRebalance;
    /// @dev Zero falls back to the Hub's protocol-wide `activeLiquidityKeeper`.
    address internal _keeper;
    Constraints internal _constraints;
    Position[] internal _positions;
    /// @inheritdoc IActiveLiquidityManager
    /// @dev Protocol cut of swap fees, held until `claimProtocolFees` so a reverting recipient can
    ///      never block the venture's exits.
    uint256 public protocolOwedVenture;
    /// @inheritdoc IActiveLiquidityManager
    uint256 public protocolOwedMoney;

    modifier onlyVenture() {
        if (msg.sender != venture) revert CallerNotVenture();
        _;
    }

    modifier onlyActiveKeeper() {
        if (msg.sender != keeper()) revert CallerNotKeeper();
        if (paused) revert Paused();
        _;
    }

    constructor(
        address _hub,
        address _venture,
        address _poolManager,
        address _hook,
        uint24 _fee,
        int24 _tickSpacing,
        address _bootstrapper
    ) {
        if (_hub == address(0) || _venture == address(0) || _poolManager == address(0) || _hook == address(0)) {
            revert InvalidAddress();
        }
        HUB = _hub;
        venture = _venture;
        poolManager = _poolManager;
        hook = _hook;
        bootstrapper = _bootstrapper;
        _poolFee = _fee;
        _poolTickSpacing = _tickSpacing;

        address _ventureToken = IVenture(_venture).token();
        address _moneyToken = IVenture(_venture).moneyToken();
        ventureToken = _ventureToken;
        moneyToken = _moneyToken;
        ventureIsToken0 = _ventureToken < _moneyToken;
        _poolId = _poolKey().toId();

        // Three positions, 2 to 1000 spacings wide, hourly rebalances, band capped at the fee.
        _setConstraints(
            Constraints({
                maxPositions: 3,
                minWidthTicks: 2 * _tickSpacing,
                maxWidthTicks: int24(uint24(ActiveSlices.DEFAULT_MAX_WIDTH_SPACINGS)) * _tickSpacing,
                minRebalanceInterval: 1 hours,
                maxTwapDeviationTicks: _feeInTicks(_fee)
            })
        );
    }

    // ─────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IActiveLiquidityManager
    function keeper() public view returns (address) {
        address k = _keeper;
        return k != address(0) ? k : IUmiaHub(HUB).activeLiquidityKeeper();
    }

    /// @notice Largest allowed `maxTwapDeviationTicks`: the pool fee in ticks (1 tick ~ 1 bp).
    function maxTwapDeviationCap() public view returns (int24) {
        return _feeInTicks(_poolFee);
    }

    /// @inheritdoc IActiveLiquidityManager
    function positions() external view returns (Position[] memory) {
        return _positions;
    }

    /// @inheritdoc IActiveLiquidityManager
    function constraints() external view returns (Constraints memory) {
        return _constraints;
    }

    /// @notice Key of the venture's spot pool.
    function getPoolKey() external view returns (PoolKey memory) {
        return _poolKey();
    }

    /// @inheritdoc IActiveLiquidityManager
    function totalAssets() public view returns (uint256 ventureAssets, uint256 moneyAssets) {
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(_poolId);
        uint256 amount0;
        uint256 amount1;
        uint256 n = _positions.length;
        for (uint256 i = 0; i < n; i++) {
            Position memory p = _positions[i];
            (uint256 a0, uint256 a1) = PositionAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(p.tickLower),
                TickMath.getSqrtPriceAtTick(p.tickUpper),
                p.liquidity
            );
            amount0 += a0;
            amount1 += a1;
        }
        (ventureAssets, moneyAssets) = ventureIsToken0 ? (amount0, amount1) : (amount1, amount0);
        (uint256 idleVenture, uint256 idleMoney) = _idle();
        ventureAssets += idleVenture;
        moneyAssets += idleMoney;
    }

    // ─────────────────────────────────────────────────────────
    // Bootstrapper / Keeper
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IActiveLiquidityManager
    /// @dev Skips the TWAP guard: the migrator seeds in the migration transaction, at the price the
    ///      pool was just initialized to, before the new pool has any oracle history. Ignores the
    ///      pause, which would otherwise let the keeper or the Hub owner veto a passed migration.
    function seed(Position[] calldata target) external nonReentrant {
        if (msg.sender != bootstrapper) revert CallerNotBootstrapper();
        if (lastRebalance != 0) revert AlreadySeeded();
        if (target.length == 0) revert InvalidPosition(0);
        _validatePositions(target);
        _reshape(target);
        emit Seeded(target);
    }

    /// @inheritdoc IActiveLiquidityManager
    function rebalance(Position[] calldata target) external nonReentrant onlyActiveKeeper {
        uint256 availableAt = uint256(lastRebalance) + _constraints.minRebalanceInterval;
        if (block.timestamp < availableAt) revert RebalanceTooSoon(availableAt);
        _requireSpotWithinTwapDeviation();
        _validatePositions(target);
        _reshape(target);
        emit Rebalanced(msg.sender, target);
    }

    /// @inheritdoc IActiveLiquidityManager
    function basketArb(
        uint256 marketId,
        bool sellToMarkets,
        uint256 size,
        uint256 outFractionWad,
        uint160 sqrtPriceLimitX96,
        uint256 minMoneyProfit
    ) external nonReentrant onlyActiveKeeper returns (uint256 moneyProfit, uint256 ventureGain) {
        IUmiaMarketCore core = _ownMarketCore(marketId);
        // Raw balances: the protocol owed amounts don't move during a basket, so no gain can come from them.
        uint256 ventureBefore = IERC20(ventureToken).balanceOf(address(this));
        uint256 moneyBefore = IERC20(moneyToken).balanceOf(address(this));

        if (sellToMarkets) {
            _spotSwap(!ventureIsToken0, int256(size), sqrtPriceLimitX96);
            _split(core, marketId, size, 0);
            (uint256[] memory amountsIn, uint256[] memory amountsOut) =
                core.basketSwapExactOut(marketId, true, outFractionWad, size, block.timestamp);
            core.merge(marketId, size - _max(amountsIn), _min(amountsOut));
        } else {
            _split(core, marketId, 0, size);
            (uint256[] memory amountsIn, uint256[] memory amountsOut) =
                core.basketSwapExactOut(marketId, false, outFractionWad, size, block.timestamp);
            uint256 merged = _min(amountsOut);
            core.merge(marketId, merged, size - _max(amountsIn));
            _spotSwap(ventureIsToken0, -int256(merged), sqrtPriceLimitX96);
        }

        uint256 ventureAfter = IERC20(ventureToken).balanceOf(address(this));
        uint256 moneyAfter = IERC20(moneyToken).balanceOf(address(this));
        if (ventureAfter < ventureBefore || moneyAfter < moneyBefore + minMoneyProfit) revert BasketUnprofitable();
        moneyProfit = moneyAfter - moneyBefore;
        ventureGain = ventureAfter - ventureBefore;
        emit BasketArb(marketId, sellToMarkets, size, outFractionWad, moneyProfit, ventureGain);
    }

    /// @inheritdoc IActiveLiquidityManager
    function claimDecisionMarket(uint256 marketId) external nonReentrant {
        uint256 ventureBefore = IERC20(ventureToken).balanceOf(address(this));
        uint256 moneyBefore = IERC20(moneyToken).balanceOf(address(this));
        IUmiaMarketCore(IUmiaHub(HUB).umiaMarketCore()).claimSettlement(marketId);
        emit DecisionMarketClaimed(
            marketId,
            IERC20(ventureToken).balanceOf(address(this)) - ventureBefore,
            IERC20(moneyToken).balanceOf(address(this)) - moneyBefore
        );
    }

    /// @inheritdoc IActiveLiquidityManager
    function collectFees() external nonReentrant {
        _run(new Position[](0), false);
    }

    /// @inheritdoc IActiveLiquidityManager
    function claimProtocolFees() external nonReentrant {
        address recipient = IUmiaHub(HUB).protocolFeeRecipient();
        if (recipient == address(0)) revert InvalidAddress();
        (uint256 owedVenture, uint256 owedMoney) = (protocolOwedVenture, protocolOwedMoney);
        protocolOwedVenture = 0;
        protocolOwedMoney = 0;
        if (owedVenture != 0) IERC20(ventureToken).safeTransfer(recipient, owedVenture);
        if (owedMoney != 0) IERC20(moneyToken).safeTransfer(recipient, owedMoney);
        emit ProtocolFeesClaimed(recipient, owedVenture, owedMoney);
    }

    // ─────────────────────────────────────────────────────────
    // Venture
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IActiveLiquidityManager
    function defund(uint256 ventureAmount, uint256 moneyAmount) external onlyVenture nonReentrant {
        (uint256 idleVenture, uint256 idleMoney) = _idle();
        if (ventureAmount > idleVenture || moneyAmount > idleMoney) revert InsufficientIdle();
        if (ventureAmount != 0) IERC20(ventureToken).safeTransfer(venture, ventureAmount);
        if (moneyAmount != 0) IERC20(moneyToken).safeTransfer(venture, moneyAmount);
        emit Defunded(ventureAmount, moneyAmount);
    }

    /// @inheritdoc IActiveLiquidityManager
    function withdrawAll() external onlyVenture nonReentrant {
        _run(new Position[](0), true);
        delete _positions;
        (uint256 ventureAmount, uint256 moneyAmount) = _idle();
        if (ventureAmount != 0) IERC20(ventureToken).safeTransfer(venture, ventureAmount);
        if (moneyAmount != 0) IERC20(moneyToken).safeTransfer(venture, moneyAmount);
        emit WithdrawnAll(ventureAmount, moneyAmount);
    }

    /// @inheritdoc IActiveLiquidityManager
    function setKeeper(address newKeeper) external onlyVenture {
        _keeper = newKeeper;
        emit KeeperSet(newKeeper);
    }

    /// @inheritdoc IActiveLiquidityManager
    function setConstraints(Constraints calldata newConstraints) external onlyVenture {
        _setConstraints(newConstraints);
    }

    /// @inheritdoc IActiveLiquidityManager
    function setPaused(bool newPaused) external {
        if (msg.sender != venture && (!newPaused || (msg.sender != IUmiaHub(HUB).owner() && msg.sender != keeper()))) {
            revert CallerCannotPause();
        }
        paused = newPaused;
        emit PausedSet(msg.sender, newPaused);
    }

    // ─────────────────────────────────────────────────────────
    // PoolManager callback
    // ─────────────────────────────────────────────────────────

    /// @notice Runs the swap or position change this contract queued through `unlock`. PoolManager only.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != poolManager) revert CallerNotPoolManager();
        (bool isSwap, bytes memory params) = abi.decode(data, (bool, bytes));
        return isSwap ? _swapCallback(params) : _modifyCallback(params);
    }

    function _swapCallback(bytes memory params) internal returns (bytes memory) {
        (bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(params, (bool, int256, uint160));
        PoolKey memory key = _poolKey();
        BalanceDelta d = IPoolManager(poolManager)
            .swap(
                key,
                SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
                ""
            );
        _settleOrTake(key.currency0, d.amount0());
        _settleOrTake(key.currency1, d.amount1());
        return "";
    }

    /// @dev Collects every current position's fees (removing it when reshaping), then opens
    ///      `target`. Settles the net per currency and returns the fee part separately.
    function _modifyCallback(bytes memory params) internal returns (bytes memory) {
        (Position[] memory target, bool reshape) = abi.decode(params, (Position[], bool));

        PoolKey memory key = _poolKey();
        Position[] memory current = _positions;
        int256 fees0;
        int256 fees1;
        int256 net0;
        int256 net1;
        for (uint256 i = 0; i < current.length; i++) {
            int256 liquidityDelta = reshape ? -int256(uint256(current[i].liquidity)) : int256(0);
            (BalanceDelta d, BalanceDelta fees) = _modify(key, current[i], liquidityDelta, i);
            fees0 += fees.amount0();
            fees1 += fees.amount1();
            net0 += d.amount0();
            net1 += d.amount1();
        }
        if (reshape) {
            for (uint256 i = 0; i < target.length; i++) {
                (BalanceDelta d,) = _modify(key, target[i], int256(uint256(target[i].liquidity)), i);
                net0 += d.amount0();
                net1 += d.amount1();
            }
        }

        _settleOrTake(key.currency0, net0);
        _settleOrTake(key.currency1, net1);
        return abi.encode(uint256(fees0), uint256(fees1));
    }

    // ─────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────

    function _reshape(Position[] calldata target) internal {
        _run(target, true);
        // The PoolManager settles from the whole balance, so a target sized past the venture's
        // capital would silently spend the accrued protocol cut.
        if (
            IERC20(ventureToken).balanceOf(address(this)) < protocolOwedVenture
                || IERC20(moneyToken).balanceOf(address(this)) < protocolOwedMoney
        ) revert InsufficientIdle();
        delete _positions;
        for (uint256 i = 0; i < target.length; i++) {
            _positions.push(target[i]);
        }
        lastRebalance = uint64(block.timestamp);
    }

    function _run(Position[] memory target, bool reshape) internal {
        (uint256 fees0, uint256 fees1) = abi.decode(
            IPoolManager(poolManager).unlock(abi.encode(false, abi.encode(target, reshape))), (uint256, uint256)
        );
        (uint256 feeVenture, uint256 feeMoney) = ventureIsToken0 ? (fees0, fees1) : (fees1, fees0);
        if (feeVenture != 0 || feeMoney != 0) _payFees(feeVenture, feeMoney);
    }

    /// @dev Positive `amountSpecified` is exact output, negative exact input.
    function _spotSwap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) internal {
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        IPoolManager(poolManager).unlock(abi.encode(true, abi.encode(zeroForOne, amountSpecified, sqrtPriceLimitX96)));
    }

    function _split(IUmiaMarketCore core, uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) internal {
        if (ventureAmount != 0) IERC20(ventureToken).forceApprove(address(core), ventureAmount);
        if (moneyAmount != 0) IERC20(moneyToken).forceApprove(address(core), moneyAmount);
        core.split(marketId, ventureAmount, moneyAmount);
    }

    /// @dev MarketCore snapshots the venture's manager per market, so this also pins the market to
    ///      this venture.
    function _ownMarketCore(uint256 marketId) internal view returns (IUmiaMarketCore core) {
        core = IUmiaMarketCore(IUmiaHub(HUB).umiaMarketCore());
        if (core.activeManager(marketId) != address(this)) revert ForeignMarket();
    }

    function _max(uint256[] memory values) internal pure returns (uint256 m) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] > m) m = values[i];
        }
    }

    /// @dev Only used for MarketCore basket outputs. MarketCreationLib rejects empty proposal lists
    ///      and adds the no-op, so every successful basket returns a nonempty array.
    function _min(uint256[] memory values) internal pure returns (uint256 m) {
        m = type(uint256).max;
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] < m) m = values[i];
        }
    }

    /// @dev Pays the venture now and accrues the protocol cut for `claimProtocolFees`.
    function _payFees(uint256 feeVenture, uint256 feeMoney) internal {
        uint256 cutVenture;
        uint256 cutMoney;
        uint16 bps = IUmiaHub(HUB).spotProtocolFeeCutBps();
        if (bps != 0) {
            cutVenture = Math.mulDiv(feeVenture, bps, MAX_BPS);
            cutMoney = Math.mulDiv(feeMoney, bps, MAX_BPS);
            protocolOwedVenture += cutVenture;
            protocolOwedMoney += cutMoney;
        }
        if (feeVenture > cutVenture) IERC20(ventureToken).safeTransfer(venture, feeVenture - cutVenture);
        if (feeMoney > cutMoney) IERC20(moneyToken).safeTransfer(venture, feeMoney - cutMoney);
        emit FeesCollected(feeVenture - cutVenture, feeMoney - cutMoney, cutVenture, cutMoney);
    }

    /// @dev Balances held by this contract that belong to the venture.
    function _idle() internal view returns (uint256 ventureAmount, uint256 moneyAmount) {
        ventureAmount = IERC20(ventureToken).balanceOf(address(this)) - protocolOwedVenture;
        moneyAmount = IERC20(moneyToken).balanceOf(address(this)) - protocolOwedMoney;
    }

    /// @dev `delta` includes `feesAccrued`.
    function _modify(PoolKey memory key, Position memory p, int256 liquidityDelta, uint256 salt)
        internal
        returns (BalanceDelta delta, BalanceDelta feesAccrued)
    {
        (delta, feesAccrued) = IPoolManager(poolManager)
            .modifyLiquidity(
                key,
                ModifyLiquidityParams({
                tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(salt)
            }),
                ""
            );
    }

    function _settleOrTake(Currency currency, int256 amount) internal {
        if (amount < 0) {
            IPoolManager(poolManager).sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(poolManager, uint256(-amount));
            IPoolManager(poolManager).settle();
        } else if (amount > 0) {
            IPoolManager(poolManager).take(currency, address(this), uint256(amount));
        }
    }

    function _validatePositions(Position[] calldata target) internal view {
        Constraints memory c = _constraints;
        if (target.length > c.maxPositions) revert TooManyPositions();
        for (uint256 i = 0; i < target.length; i++) {
            Position calldata p = target[i];
            int24 width = p.tickUpper - p.tickLower;
            if (p.liquidity == 0 || width < c.minWidthTicks || width > c.maxWidthTicks) revert InvalidPosition(i);
        }
    }

    function _setConstraints(Constraints memory c) internal {
        if (
            c.maxPositions == 0 || c.maxPositions > MAX_POSITIONS || c.minWidthTicks < _poolTickSpacing
                || c.maxWidthTicks < c.minWidthTicks || c.maxTwapDeviationTicks <= 0
                || c.maxTwapDeviationTicks > maxTwapDeviationCap()
        ) revert InvalidConstraints();
        _constraints = c;
        emit ConstraintsSet(c);
    }

    /// @dev Same guard as the anchor vault, with a venture-set short band and a tighter long one:
    ///      the manager places concentrated ranges, so a mispriced rebalance costs far more than
    ///      a mispriced full-range pull.
    function _requireSpotWithinTwapDeviation() internal view {
        (bool ready, bool ok) = SpotTwapGuard.withinBands(
            IPoolManager(poolManager),
            hook,
            _poolKey(),
            TWAP_WINDOW,
            _constraints.maxTwapDeviationTicks,
            LONG_TWAP_WINDOW,
            MAX_LONG_TICK_DEVIATION
        );
        if (!ready) revert InsufficientOracleHistory();
        if (!ok) revert SpotPriceDeviationTooHigh();
    }

    function _feeInTicks(uint24 fee) internal pure returns (int24) {
        return int24(uint24(fee / 100));
    }

    function _poolKey() internal view returns (PoolKey memory) {
        (address c0, address c1) = ventureIsToken0 ? (ventureToken, moneyToken) : (moneyToken, ventureToken);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: _poolFee,
            tickSpacing: _poolTickSpacing,
            hooks: IHooks(hook)
        });
    }
}
