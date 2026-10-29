// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IActiveLiquidityManager
/// @notice Per-venture manager of concentrated positions in the venture's canonical V2 spot pool.
/// @dev Holds venture capital only. Every token exit goes to the pool, the venture treasury, the
///      protocol fee recipient (its cut of swap fees), or its own venture's decision markets. Decision
///      markets never draw from it; it trades them only through outcome-neutral baskets.
interface IActiveLiquidityManager {
    /// @notice A concentrated range and the liquidity it holds.
    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice Venture-settable bounds on what the keeper may do.
    struct Constraints {
        uint8 maxPositions;
        int24 minWidthTicks;
        int24 maxWidthTicks;
        uint32 minRebalanceInterval;
        /// @dev Max |spot tick - 30-minute TWAP tick| at which a rebalance may run. Capped at the
        ///      pool fee in ticks (`maxTwapDeviationCap`).
        int24 maxTwapDeviationTicks;
    }

    error CallerNotVenture();
    error CallerNotKeeper();
    error CallerNotBootstrapper();
    error CallerNotPoolManager();
    error CallerCannotPause();
    error InvalidAddress();
    error InvalidConstraints();
    error InvalidPosition(uint256 index);
    error TooManyPositions();
    error Paused();
    error RebalanceTooSoon(uint256 availableAt);
    error AlreadySeeded();
    error SpotPriceDeviationTooHigh();
    error InsufficientOracleHistory();
    error InsufficientIdle();
    error ForeignMarket();
    error BasketUnprofitable();

    event Seeded(Position[] positions);
    event Rebalanced(address indexed keeper, Position[] positions);
    event FeesCollected(
        uint256 ventureToVenture, uint256 moneyToVenture, uint256 ventureToProtocol, uint256 moneyToProtocol
    );
    event Defunded(uint256 ventureAmount, uint256 moneyAmount);
    event WithdrawnAll(uint256 ventureAmount, uint256 moneyAmount);
    event KeeperSet(address keeper);
    event ConstraintsSet(Constraints constraints);
    event PausedSet(address indexed by, bool paused);
    event ProtocolFeesClaimed(address indexed recipient, uint256 ventureAmount, uint256 moneyAmount);
    event BasketArb(
        uint256 indexed marketId,
        bool sellToMarkets,
        uint256 size,
        uint256 outFractionWad,
        uint256 moneyProfit,
        uint256 ventureGain
    );
    event DecisionMarketClaimed(uint256 indexed marketId, uint256 ventureAmount, uint256 moneyAmount);

    /// @notice The Umia Hub: source of the default keeper, the protocol fee recipient and MarketCore.
    function HUB() external view returns (address);
    /// @notice The venture whose capital this manager holds; the only caller of the venture-only functions.
    function venture() external view returns (address);
    /// @notice The `UmiaHookV2` of the venture's spot pool, where this manager is the active operator.
    function hook() external view returns (address);
    /// @notice May call `seed` once, before any rebalance (`SpotMigrator` for migrated pools).
    function bootstrapper() external view returns (address);
    /// @notice Who may rebalance and run baskets: the venture-set keeper, or the Hub's protocol-wide
    ///         keeper while none is set.
    function keeper() external view returns (address);
    /// @notice While true the keeper can neither rebalance nor run baskets; venture exits still work.
    function paused() external view returns (bool);
    /// @notice Timestamp of the last seed or rebalance; zero until seeded.
    function lastRebalance() external view returns (uint64);
    /// @notice The open positions, in V4 salt order.
    function positions() external view returns (Position[] memory);
    /// @notice The keeper bounds in force.
    function constraints() external view returns (Constraints memory);

    /// @notice Idle balances plus position principal at the current price (excludes unclaimed fees).
    function totalAssets() external view returns (uint256 ventureAssets, uint256 moneyAssets);

    /// @notice Opens the first positions without the TWAP guard. Bootstrapper only, before any rebalance.
    function seed(Position[] calldata target) external;

    /// @notice Replaces every position with `target`. Keeper only.
    function rebalance(Position[] calldata target) external;

    /// @notice Spot <-> decision-market arbitrage through a basket that takes the same fraction of
    ///         every proposal pool's output reserve. Keeper only, in markets where this manager is
    ///         the `activeManager`.
    /// @dev Sell direction (every proposal priced above spot): buy `size` venture tokens on spot, split
    ///      them, sell for `outFractionWad` of each pool's virtual money, merge. Buy direction: split
    ///      `size` money, buy `outFractionWad` of each pool's virtual venture, merge, sell on spot.
    ///      Merging takes the smallest leg; the rest stays as conditional remainders. Reverts unless
    ///      real balances end with no less venture token and at least `minMoneyProfit` more money;
    ///      remainders count as zero.
    /// @param sqrtPriceLimitX96 Spot price the spot leg may not cross; zero for none.
    function basketArb(
        uint256 marketId,
        bool sellToMarkets,
        uint256 size,
        uint256 outFractionWad,
        uint160 sqrtPriceLimitX96,
        uint256 minMoneyProfit
    ) external returns (uint256 moneyProfit, uint256 ventureGain);

    /// @notice Redeems the winning proposal's basket leftovers after settlement. Permissionless.
    function claimDecisionMarket(uint256 marketId) external;

    /// @notice Sends accrued swap fees to the venture and accrues the protocol cut. Permissionless.
    function collectFees() external;

    /// @notice Sends the accrued protocol cut to the Hub's fee recipient. Permissionless.
    function claimProtocolFees() external;

    /// @notice Protocol cut of collected swap fees, in venture tokens, waiting for `claimProtocolFees`.
    function protocolOwedVenture() external view returns (uint256);
    /// @notice Protocol cut of collected swap fees, in money tokens, waiting for `claimProtocolFees`.
    function protocolOwedMoney() external view returns (uint256);
    /// @notice Largest allowed `maxTwapDeviationTicks`: the pool fee in ticks (1 tick is about 1 bp).
    function maxTwapDeviationCap() external view returns (int24);

    /// @notice Returns idle capital to the venture. Venture only.
    function defund(uint256 ventureAmount, uint256 moneyAmount) external;

    /// @notice Closes every position and returns everything to the venture. Venture only; never paused.
    function withdrawAll() external;

    /// @notice Sets the keeper; zero falls back to the Hub's protocol-wide keeper. Venture only.
    function setKeeper(address keeper) external;
    /// @notice Replaces the keeper bounds; see `Constraints` and `maxTwapDeviationCap`. Venture only.
    function setConstraints(Constraints calldata constraints) external;

    /// @notice Venture may pause or unpause. Keeper and the Hub owner may only pause.
    function setPaused(bool paused) external;
}
