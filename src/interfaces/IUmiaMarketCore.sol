// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUmiaHub} from "./IUmiaHub.sol";

/// @title IUmiaMarketCore
/// @notice External ABI for UmiaMarketCore (the futarchy decision-market engine).
interface IUmiaMarketCore {
    // ── Types ──

    enum MarketStatus {
        PENDING,
        OPEN,
        ENDED
    }

    struct CreateMarketParams {
        uint256 ventureId;
        string title;
        uint256 startTimestamp;
        /// @dev Trading duration in seconds. 0 uses the protocol default; otherwise bounded to [1h, 96h].
        uint256 duration;
        CreateProposalParams[] proposals;
    }

    struct CreateProposalParams {
        string title;
        bytes executionPayload;
    }

    struct WinningProposal {
        uint256 proposalId;
        uint256 price;
    }

    struct SwapExactInPermit {
        uint256 proposalId;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 maxPriceImpactBps;
        bool zeroForOne;
        uint256 nonce;
        uint256 deadline;
    }

    struct SwapExactOutPermit {
        uint256 proposalId;
        uint256 amountOut;
        uint256 amountInMax;
        uint256 maxPriceImpactBps;
        bool zeroForOne;
        uint256 nonce;
        uint256 deadline;
    }

    // ── Errors ──

    error VentureNotFound();
    error MarketNotFound();
    error ProposalNotFound();
    error MarketNotEnded();
    error MarketNotOpen();
    error MarketNotActive();
    error InvalidDuration();
    error StartTimeTooFarInFuture();
    error NotEnoughProposals();
    error TooManyProposals();
    error NoClaimableTokens();
    error MarketNotSettled();
    error MarketAlreadySettled();
    error AlreadyClaimed();
    error InsufficientVirtualTokens();
    error InvalidAmount();
    error InvalidRecipient();
    error InsufficientLiquidityShares();
    error InvariantViolation();
    error InvalidSignature();
    error Unauthorized();
    error SignerNotConfigured();
    error DeadlineExpired();
    error WinningProposalNotFound();
    error AlreadyExecuted();
    error ExecutionDelayActive();
    error LPPositionNotRegistered();
    error EmptySeedLiquidity();
    error GovernanceExecutorNotSet();
    error DecisionMarketCircuitBreakerActive();
    error VentureMarketAlreadyActive();

    // ── Events ──

    event MarketCreated(
        uint256 indexed marketId,
        uint256 indexed ventureId,
        string title,
        uint256 createdAt,
        uint256 tradingStart,
        uint256 tradingEnd,
        uint256[] proposalIds
    );
    event MarketSettled(
        uint256 indexed marketId,
        uint256 winningProposalId,
        uint256 winningPriceX112,
        uint256 noOpPriceX112,
        uint256 priceDeltaBps
    );
    event SettlementClaimed(
        uint256 indexed marketId, address indexed user, uint256 ventureTokenAmount, uint256 moneyTokenAmount
    );
    event LiquidityReAdded(uint256 indexed marketId, uint256 lpTokenId, uint128 liquidityAdded);
    event WinningProposalExecuted(uint256 indexed marketId, uint256 indexed proposalId);
    event Swap(
        uint256 indexed proposalId,
        address indexed trader,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        uint256 priceBeforeX96,
        uint256 priceAfterX96,
        uint256 priceImpactBps,
        uint256 protocolFee
    );
    event LiquidityAdded(uint256 indexed proposalId, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(uint256 indexed proposalId, address indexed user, uint256 amount0, uint256 amount1);
    event Split(uint256 indexed marketId, address indexed user, uint256 ventureAmount, uint256 moneyAmount);
    event Merge(uint256 indexed marketId, address indexed user, uint256 ventureAmount, uint256 moneyAmount);
    event ProtocolFeeAccrued(uint256 indexed proposalId, bool zeroForOne, uint256 feeAmount);
    event ProtocolFeesCollected(
        uint256 indexed marketId, address indexed feeRecipient, uint256 feeVenture, uint256 feeMoney
    );
    /// @notice One swap of the same reserve fraction in every proposal of a market, no-op included.
    event BasketSwap(
        uint256 indexed marketId, address indexed trader, bool zeroForOne, uint256 outFractionWad, bool feeExempt
    );
    /// @notice Emitted when virtual venture/money or LP-share tokens are minted, burned, or transferred.
    event VirtualTransfer(address indexed from, address indexed to, uint256 indexed id, uint256 amount);

    // ── Views ──

    function HUB() external view returns (IUmiaHub);
    function marketCounter() external view returns (uint256);
    /// @notice The venture's active liquidity manager at `marketId`'s creation, or zero. Its basket
    ///         swaps pay no fee, and executing the market redeems its leftovers.
    function activeManager(uint256 marketId) external view returns (address);
    function proposalCounter() external view returns (uint256);
    function marketInfo(uint256 marketId)
        external
        view
        returns (uint256 id, uint256 ventureId, uint256 tradingStart, uint256 tradingEnd);
    function marketProposalIds(uint256 marketId) external view returns (uint256[] memory proposalIds);
    function proposalInfo(uint256 proposalId)
        external
        view
        returns (uint256 id, string memory title, bool isNoOp, uint256 virtualVentureId, uint256 virtualMoneyId);
    function proposalExecutionPayload(uint256 proposalId) external view returns (bytes memory);
    function winningProposalByMarketId(uint256 marketId) external view returns (WinningProposal memory);
    function getMarketStatus(uint256 marketId) external view returns (MarketStatus);
    function getVirtualVentureId(uint256 proposalId) external pure returns (uint256);
    function getVirtualMoneyId(uint256 proposalId) external pure returns (uint256);
    function getLiquidityShareId(uint256 proposalId) external pure returns (uint256);
    function cpmmStates(uint256 proposalId) external view returns (uint256 reserve0, uint256 reserve1);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function transfer(address to, uint256 id, uint256 amount) external returns (bool);
    function totalSupply(uint256 tokenId) external view returns (uint256);
    function userVirtualVentureSupply(uint256 proposalId) external view returns (uint256);
    function userVirtualMoneySupply(uint256 proposalId) external view returns (uint256);
    function marketSettlementState(uint256 marketId)
        external
        view
        returns (
            uint256 realVenture,
            uint256 realMoney,
            uint256 lpTokenId,
            uint256 ventureRemoved,
            uint256 moneyRemoved,
            uint128 liquidityRemoved
        );
    function proposalToMarket(uint256 proposalId) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function SWAP_EXACT_IN_PERMIT_TYPEHASH() external view returns (bytes32);
    function SWAP_EXACT_OUT_PERMIT_TYPEHASH() external view returns (bytes32);
    function marketCreationNonces(address creator) external view returns (uint256);
    function swapNonces(address signer) external view returns (uint256);
    function marketExecuted(uint256 marketId) external view returns (bool);
    function activeMarketByVenture(uint256 ventureId) external view returns (uint256);
    function marketSettled(uint256 marketId) external view returns (bool);
    function activeUnsettledMarketCount() external view returns (uint256);
    function proposalFeeState(uint256 proposalId) external view returns (uint256 ventureFee, uint256 moneyFee);
    function getProposalTWAP(uint256 proposalId) external view returns (uint256 twapX112);
    function getPriceX96(uint256 proposalId, bool zeroForOne) external view returns (uint256 priceX96);
    function quoteSwapExactIn(uint256 proposalId, uint256 amountIn, bool zeroForOne)
        external
        view
        returns (uint256 amountOut, uint256 priceImpactBps);

    // ── State-Changing Functions ──

    function createMarket(CreateMarketParams calldata params, address creator, uint256 nonce, bytes calldata signature)
        external
        returns (uint256 id);
    function split(uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) external;
    function merge(uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) external;
    function settleMarket(uint256 marketId) external;
    function claimSettlement(uint256 marketId) external;
    function claimSettlementFor(uint256 marketId, address[] calldata users) external;
    function executeWinningProposal(uint256 marketId) external;
    function addLiquidity(uint256 proposalId, uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps)
        external;
    function collectProtocolFees(uint256 marketId) external;

    // ── Swaps ──

    function swapExactIn(
        uint256 proposalId,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function splitAndSwapExactIn(
        uint256 proposalId,
        uint256 ventureAmount,
        uint256 moneyAmount,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function swapExactOut(
        uint256 proposalId,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 deadline
    ) external returns (uint256 amountIn);

    function swapExactInWithPermit(SwapExactInPermit calldata permit, address signer, bytes calldata signature)
        external
        returns (uint256 amountOut);

    /// @dev Reverts with InvalidAmount if any leg's output rounds to zero.
    function basketSwapExactOut(
        uint256 marketId,
        bool zeroForOne,
        uint256 outFractionWad,
        uint256 amountInMaxPerLeg,
        uint256 deadline
    ) external returns (uint256[] memory amountsIn, uint256[] memory amountsOut);

    function swapExactOutWithPermit(SwapExactOutPermit calldata permit, address signer, bytes calldata signature)
        external
        returns (uint256 amountIn);

    function invalidateSwapNonce() external;
}
