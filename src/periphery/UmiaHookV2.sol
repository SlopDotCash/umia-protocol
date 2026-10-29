// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IUmiaHookV2} from "../interfaces/IUmiaHookV2.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {SpotMarketOracle} from "../libraries/SpotMarketOracle.sol";
import {IUmiaOracleSource} from "../interfaces/IUmiaOracleSource.sol";
import {IUmiaLBPFactoryView} from "./UmiaHook.sol";

/// @title UmiaHookV2
/// @notice The Uniswap v4 hook every Umia spot pool runs on. It keeps each pool's price oracle and
///         decides who may add liquidity: two operators per pool, the venture's anchor vault and its
///         active liquidity manager.
/// @dev Same permission bits (0x3A80), oracle rings and read surface as `UmiaHook`. What changed:
///
///      - Two operators per pool. The anchor operator (the venture's spot vault) may hold full-range
///        liquidity only; the active operator (its active liquidity manager) may hold any range. V4
///        keys positions by owner, so neither can touch the other's position.
///      - A pool that replaces a V1 pool starts with its predecessor's last 30 days in the coarse
///        oracle ring, so long TWAPs read straight across the move.
///      - Migrated pools are registered by the Hub's `spotMigrator`; fresh pools by factory LBPs.
contract UmiaHookV2 is IHooks, IUmiaHookV2 {
    using PoolIdLibrary for PoolKey;
    using SpotMarketOracle for SpotMarketOracle.Observation[65535];
    using StateLibrary for IPoolManager;

    /// @notice The one address allowed to call `initialize`, fixed at deployment.
    address public immutable INITIAL_OWNER;

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public poolManager;
    /// @notice LBP factory whose deployments may call `registerPool`.
    address public factory;
    /// @notice Source of the `spotMigrator` allowed to call `registerMigratedPool`.
    address public hub;

    /// @inheritdoc IUmiaHookV2
    mapping(PoolId => PoolConfig) public pools;

    /// @inheritdoc IUmiaHookV2
    mapping(PoolId => ObservationState) public oracleStates;
    mapping(PoolId => SpotMarketOracle.Observation[65535]) internal observations;

    /// @inheritdoc IUmiaHookV2
    uint32 public constant COARSE_INTERVAL = 1 hours;
    /// @notice Gap between the predecessor checkpoints copied into a migrated pool's coarse ring.
    uint32 public constant BACKFILL_SPACING = 6 hours;
    /// @notice Most checkpoints copied at migration: 121 steps of `BACKFILL_SPACING`, about 30 days.
    uint16 public constant BACKFILL_STEPS = 121;
    /// @notice Coarse slots reserved past a migrated pool's backfill: 30 days of hourly checkpoints plus one,
    ///         since checkpoints are hour-bucketed and can sit up to an hour past the window edge.
    uint16 public constant BACKFILL_RESERVE = 721;

    /// @inheritdoc IUmiaHookV2
    mapping(PoolId => ObservationState) public coarseOracleStates;
    mapping(PoolId => SpotMarketOracle.Observation[65535]) internal coarseObservations;

    mapping(PoolId => uint16) internal tickAreaRemainders;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    constructor(address _initialOwner) {
        if (_initialOwner == address(0)) revert InvalidInitialOwner();
        INITIAL_OWNER = _initialOwner;
    }

    // ─────────────────────────────────────────────────────────
    // Initialization & Registration
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IUmiaHookV2
    function initialize(address _factory, IPoolManager _poolManager, address _hub) external {
        if (msg.sender != INITIAL_OWNER) revert NotInitialOwner();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (_factory == address(0)) revert InvalidFactory();
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();
        if (_hub == address(0)) revert InvalidHub();
        factory = _factory;
        poolManager = _poolManager;
        hub = _hub;
        emit Initialized(_factory, address(_poolManager), _hub);
    }

    /// @inheritdoc IUmiaHookV2
    function registerPool(PoolKey calldata key, PoolConfig calldata cfg) external {
        if (!IUmiaLBPFactoryView(factory).isLBP(msg.sender)) revert NotFactoryDeployedLBP(msg.sender);
        _register(key, cfg);
    }

    /// @inheritdoc IUmiaHookV2
    /// @dev Runs in the migration tx, right after the venture's liquidity leaves the predecessor pool.
    function registerMigratedPool(PoolKey calldata key, PoolConfig calldata cfg, PoolKey calldata predecessorKey)
        external
    {
        if (msg.sender != IUmiaHub(hub).spotMigrator()) {
            revert NotSpotMigrator(msg.sender);
        }
        PoolId id = _register(key, cfg);
        if (
            Currency.unwrap(predecessorKey.currency0) != Currency.unwrap(key.currency0)
                || Currency.unwrap(predecessorKey.currency1) != Currency.unwrap(key.currency1)
        ) revert InvalidPredecessor();
        PoolId predecessorId = predecessorKey.toId();
        address hubVault = IUmiaHub(hub).ventureLiquidityVault(cfg.venture);
        if (
            hubVault == address(0)
                || PoolId.unwrap(ISpotLiquidityVault(hubVault).getPoolKey().toId()) != PoolId.unwrap(predecessorId)
        ) revert InvalidPredecessor();
        IUmiaOracleSource source = IUmiaOracleSource(address(predecessorKey.hooks));
        (, address predecessorVenture) = source.pools(predecessorId);
        (uint16 coarseIndex, uint16 coarseCardinality,) = source.coarseOracleStates(predecessorId);
        if (predecessorVenture != cfg.venture || coarseCardinality == 0) revert InvalidPredecessor();

        (uint32 backfillStart, uint16 observationCount) = _backfillCoarse(
            id,
            source,
            predecessorKey,
            predecessorId,
            _oldestTimestamp(source, predecessorId, coarseIndex, coarseCardinality)
        );
        emit PoolPredecessorSet(id, address(source), predecessorId, backfillStart, observationCount);
    }

    function _backfillCoarse(
        PoolId id,
        IUmiaOracleSource source,
        PoolKey calldata predecessorKey,
        PoolId predecessorId,
        uint32 oldest
    ) private returns (uint32 backfillStart, uint16 observationCount) {
        uint32 time = uint32(block.timestamp);
        uint256 steps = (time - oldest) / BACKFILL_SPACING;
        if (steps > BACKFILL_STEPS) steps = BACKFILL_STEPS;

        uint32[] memory secondsAgos = new uint32[](steps + 1);
        for (uint256 i = 0; i <= steps; i++) {
            secondsAgos[i] = uint32((steps - i) * BACKFILL_SPACING);
        }
        (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidity) =
            source.observeLong(predecessorKey, secondsAgos);

        (, int24 tick,,) = poolManager.getSlot0(predecessorId);
        SpotMarketOracle.Observation[65535] storage ring = coarseObservations[id];
        unchecked {
            for (uint256 i = 0; i <= steps; i++) {
                ring[i] = SpotMarketOracle.Observation({
                    blockTimestamp: time - secondsAgos[i],
                    prevTick: tick,
                    tickCumulative: tickCumulatives[i] - tickCumulatives[steps],
                    secondsPerLiquidityCumulativeX128: secondsPerLiquidity[i] - secondsPerLiquidity[steps],
                    initialized: true
                });
            }
        }

        observationCount = uint16(steps + 1);
        coarseOracleStates[id] = ObservationState({
            index: observationCount - 1,
            cardinality: observationCount,
            // Reserved, not pre-written: each hourly writer pays its slot's first write instead.
            cardinalityNext: observationCount + BACKFILL_RESERVE
        });
        backfillStart = time - secondsAgos[0];
    }

    function _oldestTimestamp(IUmiaOracleSource source, PoolId id, uint16 index, uint16 cardinality)
        private
        view
        returns (uint32 timestamp)
    {
        bool initialized;
        (timestamp,,, initialized) = source.getCoarseObservation(id, uint16((uint256(index) + 1) % cardinality));
        if (!initialized) (timestamp,,,) = source.getCoarseObservation(id, 0);
    }

    /// @dev V4 hashes `hooks` into the PoolId, so a key pointing elsewhere would never route here.
    function _register(PoolKey calldata key, PoolConfig calldata cfg) private returns (PoolId id) {
        if (address(key.hooks) != address(this)) revert InvalidHooksAddress(address(key.hooks), address(this));
        id = key.toId();
        if (pools[id].launcher != address(0)) revert PoolAlreadyRegistered(id);
        if (cfg.venture == address(0)) revert InvalidVentureAddress();
        if (cfg.anchorOperator == address(0) || cfg.anchorOperator == cfg.activeOperator) revert InvalidOperator();

        pools[id] = PoolConfig({
            launcher: msg.sender,
            venture: cfg.venture,
            anchorOperator: cfg.anchorOperator,
            activeOperator: cfg.activeOperator
        });
        emit PoolRegistered(id, cfg.anchorOperator, pools[id]);
    }

    // ─────────────────────────────────────────────────────────
    // V4 Hook Permissions
    // ─────────────────────────────────────────────────────────

    /// @notice The permission bits this hook is deployed under: before and after initialize, before
    ///         add and remove liquidity, before swap.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────
    // V4 Hook Callbacks
    // ─────────────────────────────────────────────────────────

    /// @notice Lets only the pool's registered launcher initialize it. PoolManager only.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        address launcher = pools[key.toId()].launcher;
        if (sender != launcher) revert UnauthorizedLauncher(sender, launcher);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Seeds both oracle rings at the opening tick; a migrated pool keeps its backfilled
    ///         coarse ring. PoolManager only.
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        uint32 time = uint32(block.timestamp);
        (oracleStates[id].cardinality, oracleStates[id].cardinalityNext) = observations[id].initialize(time, tick);
        if (coarseOracleStates[id].cardinality == 0) {
            (coarseOracleStates[id].cardinality, coarseOracleStates[id].cardinalityNext) =
                coarseObservations[id].initialize(time, tick);
        }
        return IHooks.afterInitialize.selector;
    }

    /// @notice Anchor operator: full range only. Active operator: any range the PoolManager accepts.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        PoolConfig storage cfg = pools[key.toId()];
        if (sender == cfg.anchorOperator) {
            if (
                params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) revert OnlyFullRangePositions();
        } else if (sender != cfg.activeOperator) {
            revert UnauthorizedLiquidityOperator(sender);
        }
        _writeObservation(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice No-op kept for `IHooks`; its permission bit is off, so the PoolManager never routes here.
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Anyone may remove: only operators can ever add, and V4 keys positions by owner, so
    ///      nobody can remove an operator's positions but the operator.
    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        _writeObservation(key);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice No-op kept for `IHooks`; its permission bit is off, so the PoolManager never routes here.
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    /// @notice Writes an oracle observation ahead of every swap. PoolManager only.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _writeObservation(key);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice No-op kept for `IHooks`; its permission bit is off, so the PoolManager never routes here.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice No-op kept for `IHooks`; its permission bit is off, so the PoolManager never routes here.
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @notice No-op kept for `IHooks`; its permission bit is off, so the PoolManager never routes here.
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // ─────────────────────────────────────────────────────────
    // Oracle
    // ─────────────────────────────────────────────────────────

    /// @inheritdoc IUmiaHookV2
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId id = key.toId();
        ObservationState memory state = oracleStates[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        return observations[id].observe(
            uint32(block.timestamp),
            secondsAgos,
            tick,
            state.index,
            poolManager.getLiquidity(id),
            state.cardinality,
            tickAreaRemainders[id]
        );
    }

    /// @notice `observe` for month-scale lookbacks: coarse ring, except targets newer than the
    ///         newest coarse checkpoint, served from the per-block ring.
    function observeLong(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId id = key.toId();
        ObservationState memory fine = oracleStates[id];
        ObservationState memory coarse = coarseOracleStates[id];
        if (fine.cardinality == 0 || coarse.cardinality == 0) {
            revert SpotMarketOracle.OracleCardinalityCannotBeZero();
        }

        (, int24 tick,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        uint32 time = uint32(block.timestamp);
        uint32 newestCoarseAge;
        unchecked {
            newestCoarseAge = time - coarseObservations[id][coarse.index].blockTimestamp;
        }

        uint256 n = secondsAgos.length;
        tickCumulatives = new int48[](n);
        secondsPerLiquidityCumulativeX128s = new uint144[](n);
        for (uint256 i = 0; i < n; i++) {
            if (secondsAgos[i] < newestCoarseAge) {
                (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) = observations[id].observeSingle(
                    time, secondsAgos[i], tick, fine.index, liquidity, fine.cardinality, tickAreaRemainders[id]
                );
            } else {
                (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) = coarseObservations[id].observeSingle(
                    time, secondsAgos[i], tick, coarse.index, liquidity, coarse.cardinality, 0
                );
            }
        }
    }

    /// @inheritdoc IUmiaHookV2
    function getObservation(PoolId id, uint16 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int48 tickCumulative,
            uint144 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        return _observationAt(observations[id], index);
    }

    /// @inheritdoc IUmiaHookV2
    function getCoarseObservation(PoolId id, uint16 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int48 tickCumulative,
            uint144 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        return _observationAt(coarseObservations[id], index);
    }

    /// @inheritdoc IUmiaHookV2
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = key.toId();
        return _grow(observations[id], oracleStates[id], cardinalityNext);
    }

    /// @inheritdoc IUmiaHookV2
    function increaseCoarseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = key.toId();
        return _grow(coarseObservations[id], coarseOracleStates[id], cardinalityNext);
    }

    // ─────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────

    function _observationAt(SpotMarketOracle.Observation[65535] storage ring, uint16 index)
        private
        view
        returns (uint32, int48, uint144, bool)
    {
        SpotMarketOracle.Observation memory obs = ring[index];
        return (obs.blockTimestamp, obs.tickCumulative, obs.secondsPerLiquidityCumulativeX128, obs.initialized);
    }

    function _grow(SpotMarketOracle.Observation[65535] storage ring, ObservationState storage state, uint16 next)
        private
        returns (uint16 old, uint16 updated)
    {
        old = state.cardinalityNext;
        updated = ring.grow(old, next);
        state.cardinalityNext = updated;
    }

    function _writeObservation(PoolKey calldata key) internal {
        PoolId id = key.toId();
        ObservationState storage state = oracleStates[id];
        (, int24 tick,,) = poolManager.getSlot0(id);
        uint128 liquidity = poolManager.getLiquidity(id);
        uint16 tickAreaRemainder = tickAreaRemainders[id];
        (state.index, state.cardinality, tickAreaRemainder) = observations[id].write(
            state.index,
            uint32(block.timestamp),
            tick,
            liquidity,
            state.cardinality,
            state.cardinalityNext,
            tickAreaRemainder
        );
        tickAreaRemainders[id] = tickAreaRemainder;

        ObservationState storage coarseState = coarseOracleStates[id];
        uint32 lastCoarseTs = coarseObservations[id][coarseState.index].blockTimestamp;
        if (lastCoarseTs / COARSE_INTERVAL != uint32(block.timestamp) / COARSE_INTERVAL) {
            // Snapshot the per-block cumulative, not a resampled tick (must not be `write`).
            (coarseState.index, coarseState.cardinality) = coarseObservations[id].writeSnapshot(
                coarseState.index, observations[id][state.index], coarseState.cardinality, coarseState.cardinalityNext
            );
        }
    }
}
