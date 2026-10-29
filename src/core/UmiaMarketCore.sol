// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {CPMM} from "../libraries/CPMM.sol";
import {CPMMWithFee} from "../libraries/CPMMWithFee.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../interfaces/IUmiaMarketCore.sol";
import {IConditionalMarketOracle} from "../interfaces/IConditionalMarketOracle.sol";
import {IGovernanceExecutor} from "../interfaces/IGovernanceExecutor.sol";
import {ISpotLiquidityVaultV2} from "../interfaces/ISpotLiquidityVaultV2.sol";
import {MarketData, ProposalData, Pool, SettleAcct} from "../libraries/MarketCoreTypes.sol";
import {LedgerLib} from "../libraries/LedgerLib.sol";
import {MarketCreationLib} from "../libraries/MarketCreationLib.sol";
import {SettlementLib} from "../libraries/SettlementLib.sol";

/// @title UmiaMarketCore
/// @notice Futarchy decision-market engine for Umia ventures.
/// @dev For a venture, a market presents a set of competing proposals. Depositing the venture and
///      money tokens (`split`) mints a matching pair of virtual venture/money tokens for every
///      proposal, each backed 1:1 by the real deposit. Each proposal runs its own constant-product
///      market where those virtual tokens trade, producing a price signal. At the end of trading the
///      market settles to the proposal whose time-weighted price clears the winning threshold, and
///      that proposal's payload is executed against the venture treasury. Holders redeem the winning
///      proposal's virtual tokens 1:1 for the underlying (`claimSettlement`, or `claimSettlementFor` on
///      their behalf). Upgradeable via UUPS.
contract UmiaMarketCore is Initializable, UUPSUpgradeable, ReentrancyGuard, IUmiaMarketCore {
    using SafeTransferLib for address;

    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    /// @notice High-bit prefix distinguishing LP-share token IDs from virtual venture/money IDs.
    uint256 internal constant LP_SHARE_TOKEN_PREFIX = 1 << 255;
    uint256 internal constant WAD = 1e18;

    /// @notice EIP-712 domain type hash.
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 type hash for the market-creation approval signed by the market-creation signer.
    bytes32 internal constant CREATE_MARKET_APPROVAL_TYPEHASH = keccak256(
        "CreateMarketApproval(address creator,uint256 ventureId,bytes32 titleHash,uint256 startTimestamp,uint256 duration,bytes32 proposalsHash,uint256 nonce)"
    );
    /// @notice EIP-712 type hash for a relayed exact-input swap authorization.
    bytes32 public constant SWAP_EXACT_IN_PERMIT_TYPEHASH = keccak256(
        "SwapExactInPermit(uint256 proposalId,uint256 amountIn,uint256 amountOutMin,uint256 maxPriceImpactBps,bool zeroForOne,uint256 nonce,uint256 deadline)"
    );
    /// @notice EIP-712 type hash for a relayed exact-output swap authorization.
    bytes32 public constant SWAP_EXACT_OUT_PERMIT_TYPEHASH = keccak256(
        "SwapExactOutPermit(uint256 proposalId,uint256 amountOut,uint256 amountInMax,uint256 maxPriceImpactBps,bool zeroForOne,uint256 nonce,uint256 deadline)"
    );

    // ─────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────

    /// @notice The UmiaHub registry.
    IUmiaHub public HUB;

    /// @notice Number of markets created (also the ID of the most recent market).
    uint256 public marketCounter;
    /// @notice Number of proposals created (also the ID of the most recent proposal).
    uint256 public proposalCounter;
    /// @notice EIP-712 domain separator, bound to this contract's address and chain.
    bytes32 public DOMAIN_SEPARATOR;
    /// @notice Number of markets that have been created but not yet settled.
    uint256 public activeUnsettledMarketCount;

    /// @notice Per-proposal market state (reserves, fees, LP shares, virtual supplies).
    mapping(uint256 proposalId => Pool) internal _pools;
    /// @notice Per-market configuration and lifecycle flags.
    mapping(uint256 marketId => MarketData) internal _markets;
    /// @notice Per-market settlement accounting (real balances, removed liquidity, winner).
    mapping(uint256 marketId => SettleAcct) internal _settle;
    /// @notice Per-proposal metadata (title, no-op flag, virtual token IDs, execution payload).
    mapping(uint256 proposalId => ProposalData) internal _proposals;
    /// @notice Current EIP-712 nonce per market creator.
    mapping(address creator => uint256 nonce) public marketCreationNonces;
    /// @notice Market a proposal belongs to.
    mapping(uint256 proposalId => uint256 marketId) public proposalToMarket;
    /// @notice Tracks whether an address has already claimed a market's settlement.
    mapping(uint256 marketId => mapping(address => bool)) internal _hasClaimed;
    /// @notice The active (unsettled) market for a venture, or 0 if none.
    mapping(uint256 ventureId => uint256 marketId) public activeMarketByVenture;

    /// @notice Balance of a virtual venture/money or LP-share token held by an owner.
    /// @dev Argument order (owner, id) follows the ERC-6909 convention.
    mapping(address owner => mapping(uint256 id => uint256)) public balanceOf;
    /// @notice Total supply of a virtual venture/money or LP-share token.
    mapping(uint256 id => uint256) public totalSupply;

    /// @notice Current swap-permit nonce per signer (replay protection for relayed swaps).
    mapping(address signer => uint256 nonce) public swapNonces;

    /// @inheritdoc IUmiaMarketCore
    mapping(uint256 marketId => address) public activeManager;

    /// @notice Reserved storage slots for future upgrades.
    uint256[49] private __gap;

    // ─────────────────────────────────────────────────────────
    // Initialization & upgrades
    // ─────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the market core behind its proxy.
    /// @param _hub The address of the UmiaHub contract.
    function initialize(address _hub) external initializer {
        HUB = IUmiaHub(_hub);
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("UmiaMarketCore"), keccak256("1"), block.chainid, address(this))
        );
    }

    /// @notice Authorizes an implementation upgrade.
    /// @dev Restricted to the Hub owner.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != HUB.owner()) revert Unauthorized();
    }

    /// @notice Verifies an EIP-712 signature against a signer.
    /// @dev Supports both EOA signatures and EIP-1271 smart-contract wallets.
    /// @param structHash The hash of the signed struct.
    /// @param signer The expected signer.
    /// @param signature The signature to verify.
    function _verifySignature(bytes32 structHash, address signer, bytes calldata signature) internal view {
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) {
            revert InvalidSignature();
        }
    }

    // ─────────────────────────────────────────────────────────
    // Virtual-token ledger
    // ─────────────────────────────────────────────────────────

    function _mint(address to, uint256 id, uint256 amount) internal {
        LedgerLib.mint(balanceOf, totalSupply, to, id, amount);
    }

    function _burn(address from, uint256 id, uint256 amount) internal {
        LedgerLib.burn(balanceOf, totalSupply, from, id, amount);
    }

    function _move(address from, address to, uint256 id, uint256 amount) internal {
        LedgerLib.move(balanceOf, from, to, id, amount);
    }

    /// @notice Transfers virtual venture/money or LP-share tokens to another address.
    /// @dev The ledger has no approval or operator mechanism; only the owner can move their tokens.
    /// @param to The recipient.
    /// @param id The token ID.
    /// @param amount The amount to transfer.
    /// @return True on success.
    function transfer(address to, uint256 id, uint256 amount) external returns (bool) {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        _move(msg.sender, to, id, amount);
        return true;
    }

    // ─────────────────────────────────────────────────────────
    // Token ID derivation
    // ─────────────────────────────────────────────────────────

    /// @notice Returns the virtual venture token ID for a proposal.
    /// @param proposalId The proposal ID.
    /// @return The virtual venture token ID.
    function getVirtualVentureId(uint256 proposalId) public pure returns (uint256) {
        return proposalId * 2;
    }

    /// @notice Returns the virtual money token ID for a proposal.
    /// @param proposalId The proposal ID.
    /// @return The virtual money token ID.
    function getVirtualMoneyId(uint256 proposalId) public pure returns (uint256) {
        return proposalId * 2 + 1;
    }

    /// @notice Returns the LP-share token ID for a proposal's market.
    /// @param proposalId The proposal ID.
    /// @return The LP-share token ID.
    function getLiquidityShareId(uint256 proposalId) public pure returns (uint256) {
        return LP_SHARE_TOKEN_PREFIX | proposalId;
    }

    // ─────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────

    /// @notice Returns a market's lifecycle status.
    /// @param marketId The market ID.
    /// @return The market status: PENDING before trading, OPEN during trading, ENDED after.
    function getMarketStatus(uint256 marketId) public view returns (MarketStatus) {
        MarketData storage m = _markets[marketId];
        if (m.id == 0) revert MarketNotFound();
        if (block.timestamp < m.tradingStart) return MarketStatus.PENDING;
        if (block.timestamp < m.tradingEnd) return MarketStatus.OPEN;
        return MarketStatus.ENDED;
    }

    /// @notice Returns core information about a market.
    /// @param marketId The market ID.
    /// @return id The market ID.
    /// @return ventureId The venture the market belongs to.
    /// @return tradingStart The trading-window start timestamp.
    /// @return tradingEnd The trading-window end timestamp.
    function marketInfo(uint256 marketId)
        external
        view
        returns (uint256 id, uint256 ventureId, uint256 tradingStart, uint256 tradingEnd)
    {
        MarketData storage m = _markets[marketId];
        return (m.id, m.ventureId, m.tradingStart, m.tradingEnd);
    }

    /// @notice Returns the proposal IDs belonging to a market.
    /// @param marketId The market ID.
    /// @return The proposal IDs.
    function marketProposalIds(uint256 marketId) external view returns (uint256[] memory) {
        return _markets[marketId].proposalIds;
    }

    /// @notice Returns metadata for a proposal.
    /// @param proposalId The proposal ID.
    /// @return id The proposal ID.
    /// @return title The proposal title.
    /// @return isNoOp Whether the proposal is the no-op (do-nothing) option.
    /// @return virtualVentureId The proposal's virtual venture token ID.
    /// @return virtualMoneyId The proposal's virtual money token ID.
    function proposalInfo(uint256 proposalId)
        external
        view
        returns (uint256 id, string memory title, bool isNoOp, uint256 virtualVentureId, uint256 virtualMoneyId)
    {
        ProposalData storage p = _proposals[proposalId];
        return (proposalId, p.title, p.isNoOp, getVirtualVentureId(proposalId), getVirtualMoneyId(proposalId));
    }

    /// @notice Returns a proposal's stored governance execution payload (empty for a no-op).
    /// @dev Lets off-chain consumers (the indexer) read the payload directly instead of decoding
    ///      createMarket calldata, which fails when the market is created via a wrapper contract.
    /// @param proposalId The proposal ID.
    /// @return The ABI-encoded ExecutionPlanV1 payload, or empty bytes for a no-op proposal.
    function proposalExecutionPayload(uint256 proposalId) external view returns (bytes memory) {
        return _proposals[proposalId].executionPayload;
    }

    /// @notice Returns the winning proposal and its settlement price for a market.
    /// @param marketId The market ID.
    /// @return The winning proposal ID and price (0 until settled).
    function winningProposalByMarketId(uint256 marketId) external view returns (WinningProposal memory) {
        SettleAcct storage s = _settle[marketId];
        return WinningProposal({proposalId: s.winningProposalId, price: s.winningPriceX112});
    }

    /// @notice Returns a proposal market's current reserves.
    /// @param proposalId The proposal ID.
    /// @return reserve0 The virtual venture reserve.
    /// @return reserve1 The virtual money reserve.
    function cpmmStates(uint256 proposalId) external view returns (uint256 reserve0, uint256 reserve1) {
        CPMM.State storage c = _pools[proposalId].cpmm;
        return (c.reserve0, c.reserve1);
    }

    /// @notice Returns the total user-held virtual venture supply for a proposal.
    /// @param proposalId The proposal ID.
    /// @return The user-held virtual venture supply.
    function userVirtualVentureSupply(uint256 proposalId) external view returns (uint256) {
        return _pools[proposalId].userVirtualVentureSupply;
    }

    /// @notice Returns the total user-held virtual money supply for a proposal.
    /// @param proposalId The proposal ID.
    /// @return The user-held virtual money supply.
    function userVirtualMoneySupply(uint256 proposalId) external view returns (uint256) {
        return _pools[proposalId].userVirtualMoneySupply;
    }

    /// @notice Returns the protocol fees accrued by a proposal market.
    /// @param proposalId The proposal ID.
    /// @return ventureFee The accrued virtual venture fee.
    /// @return moneyFee The accrued virtual money fee.
    function proposalFeeState(uint256 proposalId) external view returns (uint256 ventureFee, uint256 moneyFee) {
        Pool storage p = _pools[proposalId];
        return (p.accruedFeeVenture, p.accruedFeeMoney);
    }

    /// @notice Returns a market's settlement accounting.
    /// @param marketId The market ID.
    /// @return realVenture Real venture tokens held for the market.
    /// @return realMoney Real money tokens held for the market.
    /// @return lpTokenId The spot LP position token ID associated with the market.
    /// @return ventureRemoved Venture tokens removed from the spot position at creation.
    /// @return moneyRemoved Money tokens removed from the spot position at creation.
    /// @return liquidityRemoved Spot liquidity removed at creation.
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
        )
    {
        SettleAcct storage s = _settle[marketId];
        return
            (
                s.realVentureBalance,
                s.realMoneyBalance,
                s.lpTokenId,
                s.ventureRemoved,
                s.moneyRemoved,
                s.liquidityRemoved
            );
    }

    /// @notice Returns whether a market's winning proposal has been executed.
    /// @param marketId The market ID.
    /// @return True if executed.
    function marketExecuted(uint256 marketId) external view returns (bool) {
        return _markets[marketId].executed;
    }

    /// @notice Returns whether a market has been settled.
    /// @param marketId The market ID.
    /// @return True if settled.
    function marketSettled(uint256 marketId) external view returns (bool) {
        return _markets[marketId].settled;
    }

    /// @notice Returns the current time-weighted average price for a proposal market.
    /// @param proposalId The proposal ID.
    /// @return twapX112 The TWAP as a Q112 fixed-point value.
    function getProposalTWAP(uint256 proposalId) external view returns (uint256 twapX112) {
        CPMM.State storage c = _pools[proposalId].cpmm;
        return IConditionalMarketOracle(HUB.conditionalMarketOracle()).calculateTWAP(proposalId, c.reserve0, c.reserve1);
    }

    /// @notice Returns a proposal market's current price as a Q96 fixed-point value.
    /// @param proposalId The proposal ID.
    /// @param zeroForOne If true, the price of virtual venture in terms of virtual money.
    /// @return priceX96 The price in Q96 format.
    function getPriceX96(uint256 proposalId, bool zeroForOne) external view returns (uint256 priceX96) {
        CPMM.State storage c = _pools[proposalId].cpmm;
        return CPMM._getPriceX96(c.reserve0, c.reserve1, zeroForOne);
    }

    /// @notice Quotes the expected output and price impact of an exact-input swap.
    /// @param proposalId The proposal ID.
    /// @param amountIn The input amount.
    /// @param zeroForOne The swap direction.
    /// @return amountOut The expected output amount.
    /// @return priceImpactBps The price impact in basis points.
    function quoteSwapExactIn(uint256 proposalId, uint256 amountIn, bool zeroForOne)
        external
        view
        returns (uint256 amountOut, uint256 priceImpactBps)
    {
        uint256 marketId = proposalToMarket[proposalId];
        if (marketId == 0) revert ProposalNotFound();
        CPMM.State storage c = _pools[proposalId].cpmm;
        return
            CPMMWithFee._quoteSwapExactIn(c.reserve0, c.reserve1, amountIn, zeroForOne, _markets[marketId].swapFeeBps);
    }

    // ─────────────────────────────────────────────────────────
    // Market creation
    // ─────────────────────────────────────────────────────────

    /// @notice Creates a decision market for a venture, authorized by a market-creation signature.
    /// @dev The signature is produced by the Hub's market-creation signer over the market
    ///      parameters and the creator's current nonce. Seeds a constant-product market for each
    ///      proposal from the venture's spot liquidity.
    /// @param params The market parameters (venture, title, timing, proposals).
    /// @param creator The address the signature authorizes to create the market.
    /// @param nonce The creator's expected market-creation nonce.
    /// @param signature The market-creation signer's EIP-712 approval.
    /// @return id The new market ID.
    function createMarket(CreateMarketParams calldata params, address creator, uint256 nonce, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 id)
    {
        address signer = HUB.marketCreationSigner();
        if (signer == address(0)) revert SignerNotConfigured();
        if (msg.sender != creator && msg.sender != HUB.owner()) revert Unauthorized();
        if (nonce != marketCreationNonces[creator]) revert InvalidSignature();

        bytes32 proposalsHash = keccak256(abi.encode(params.proposals));
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_MARKET_APPROVAL_TYPEHASH,
                creator,
                params.ventureId,
                keccak256(bytes(params.title)),
                params.startTimestamp,
                params.duration,
                proposalsHash,
                nonce
            )
        );
        _verifySignature(structHash, signer, signature);
        marketCreationNonces[creator]++;

        id = ++marketCounter;
        uint256[] memory proposalIds;
        (proposalIds, proposalCounter) = MarketCreationLib.create(
            HUB,
            params,
            creator,
            id,
            proposalCounter,
            _markets,
            _proposals,
            _pools,
            _settle,
            proposalToMarket,
            activeMarketByVenture,
            balanceOf,
            totalSupply
        );
        unchecked {
            ++activeUnsettledMarketCount;
        }
        activeManager[id] = _activeManager(params.ventureId);
    }

    /// @dev V1 vaults have no active manager, so their markets record none.
    function _activeManager(uint256 ventureId) private view returns (address) {
        address vault = HUB.ventureLiquidityVault(HUB.ventureById(ventureId).venture);
        try ISpotLiquidityVaultV2(vault).activeManager() returns (address manager) {
            return manager;
        } catch {
            return address(0);
        }
    }

    // ─────────────────────────────────────────────────────────
    // Settlement & claims
    // ─────────────────────────────────────────────────────────

    /// @notice Settles an ended market to its winning proposal.
    /// @dev Selects the proposal whose time-weighted price clears the winning threshold and
    ///      re-adds the venture's spot liquidity. Callable once, after trading ends.
    /// @param marketId The market ID.
    function settleMarket(uint256 marketId) external nonReentrant {
        if (_markets[marketId].id == 0) revert MarketNotFound();
        if (getMarketStatus(marketId) != MarketStatus.ENDED) revert MarketNotEnded();
        if (_markets[marketId].settled) revert MarketAlreadySettled();
        SettlementLib.settle(HUB, marketId, totalSupply, _markets, _pools, _settle);
        unchecked {
            --activeUnsettledMarketCount;
        }
    }

    /// @notice Redeems the caller's winning-proposal virtual tokens for the underlying real tokens.
    /// @dev Also redeems the caller's LP shares in the winning proposal's market.
    /// @param marketId The market ID.
    function claimSettlement(uint256 marketId) external nonReentrant {
        SettlementLib.claim(HUB, marketId, msg.sender, balanceOf, totalSupply, _markets, _pools, _settle, _hasClaimed);
    }

    /// @notice Redeems each user's winning-proposal position to that user, so anyone can clear
    ///         forgotten claims. Users who already claimed or hold nothing are skipped.
    /// @param marketId The market ID.
    /// @param users The holders to redeem for.
    function claimSettlementFor(uint256 marketId, address[] calldata users) external nonReentrant {
        SettlementLib.claimFor(HUB, marketId, users, balanceOf, totalSupply, _markets, _pools, _settle, _hasClaimed);
    }

    /// @notice Collects the protocol fees accrued by a settled market's winning proposal.
    /// @param marketId The market ID.
    function collectProtocolFees(uint256 marketId) external nonReentrant {
        SettlementLib.collectFees(HUB, marketId, _markets, _pools, _settle);
    }

    // ─────────────────────────────────────────────────────────
    // Winning-proposal execution
    // ─────────────────────────────────────────────────────────

    /// @notice Executes the winning proposal's payload against the venture treasury.
    /// @dev Callable after the execution delay elapses and while the Hub circuit breaker is
    ///      inactive. A no-op winner or an empty payload records execution without a treasury call.
    /// @param marketId The market ID.
    function executeWinningProposal(uint256 marketId) external nonReentrant {
        if (HUB.decisionMarketCircuitBreakerActive(marketId)) revert DecisionMarketCircuitBreakerActive();
        MarketData storage market = _markets[marketId];
        if (getMarketStatus(marketId) != MarketStatus.ENDED) revert MarketNotEnded();
        if (market.executed) revert AlreadyExecuted();

        SettleAcct storage acct = _settle[marketId];
        uint256 winningPid = acct.winningProposalId;
        if (winningPid == 0) revert WinningProposalNotFound();
        // The delay runs from settlement (when the winner is known), so governance always gets the
        // full window to trip the circuit breaker — settle + execute can never run in one block.
        if (block.timestamp < uint256(acct.settledAt) + market.executionDelay) {
            revert ExecutionDelayActive();
        }

        ProposalData storage proposal = _proposals[winningPid];

        market.executed = true;

        if (proposal.isNoOp || proposal.executionPayload.length == 0) {
            emit WinningProposalExecuted(marketId, winningPid);
            return;
        }

        address venture = HUB.ventureById(market.ventureId).venture;
        address executor = HUB.governanceExecutor(venture);
        if (executor == address(0) || executor.code.length == 0) revert GovernanceExecutorNotSet();

        IGovernanceExecutor(executor).executeProposal(venture, marketId, winningPid, proposal.executionPayload);
        emit WinningProposalExecuted(marketId, winningPid);
    }

    // ─────────────────────────────────────────────────────────
    // Split & merge
    // ─────────────────────────────────────────────────────────

    /// @notice Deposits venture and/or money tokens, minting a matching virtual pair per proposal.
    /// @param marketId The market ID.
    /// @param ventureAmount The amount of venture tokens to deposit.
    /// @param moneyAmount The amount of money tokens to deposit.
    function split(uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) external nonReentrant {
        _split(marketId, ventureAmount, moneyAmount, msg.sender);
    }

    /// @dev Shared implementation for `split`.
    function _split(uint256 marketId, uint256 ventureAmount, uint256 moneyAmount, address user) internal {
        MarketData storage market = _markets[marketId];
        if (market.id == 0) revert MarketNotFound();
        MarketStatus status = getMarketStatus(marketId);
        if (status != MarketStatus.OPEN && status != MarketStatus.PENDING) revert MarketNotActive();
        if (ventureAmount == 0 && moneyAmount == 0) revert InvalidAmount();

        uint256 ventureId = market.ventureId;
        uint256[] storage proposalIds = market.proposalIds;

        if (moneyAmount > 0) {
            HUB.ventureMoneyTokenById(ventureId).safeTransferFrom(user, address(this), moneyAmount);
            _settle[marketId].realMoneyBalance += moneyAmount;
        }
        if (ventureAmount > 0) {
            address ventureToken = HUB.ventureTokenById(ventureId);
            if (ventureToken == address(0)) revert VentureNotFound();
            ventureToken.safeTransferFrom(user, address(this), ventureAmount);
            _settle[marketId].realVentureBalance += ventureAmount;
        }

        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];
            if (moneyAmount > 0) {
                _mint(user, getVirtualMoneyId(proposalId), moneyAmount);
                _pools[proposalId].userVirtualMoneySupply += moneyAmount;
            }
            if (ventureAmount > 0) {
                _mint(user, getVirtualVentureId(proposalId), ventureAmount);
                _pools[proposalId].userVirtualVentureSupply += ventureAmount;
            }
        }

        _checkInvariant(marketId);
        emit Split(marketId, user, ventureAmount, moneyAmount);
    }

    /// @notice Burns a matching virtual pair across every proposal to redeem the real tokens.
    /// @param marketId The market ID.
    /// @param ventureAmount The amount of virtual venture tokens to burn per proposal.
    /// @param moneyAmount The amount of virtual money tokens to burn per proposal.
    function merge(uint256 marketId, uint256 ventureAmount, uint256 moneyAmount) external nonReentrant {
        MarketData storage market = _markets[marketId];
        if (market.id == 0) revert MarketNotFound();
        MarketStatus status = getMarketStatus(marketId);
        if (status != MarketStatus.OPEN && status != MarketStatus.PENDING) revert MarketNotActive();
        if (ventureAmount == 0 && moneyAmount == 0) revert InvalidAmount();

        uint256[] storage proposalIds = market.proposalIds;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];
            if (ventureAmount > 0) {
                _burn(msg.sender, getVirtualVentureId(proposalId), ventureAmount);
                _pools[proposalId].userVirtualVentureSupply -= ventureAmount;
            }
            if (moneyAmount > 0) {
                _burn(msg.sender, getVirtualMoneyId(proposalId), moneyAmount);
                _pools[proposalId].userVirtualMoneySupply -= moneyAmount;
            }
        }

        if (moneyAmount > 0) {
            _settle[marketId].realMoneyBalance -= moneyAmount;
            HUB.ventureMoneyTokenById(market.ventureId).safeTransfer(msg.sender, moneyAmount);
        }
        if (ventureAmount > 0) {
            _settle[marketId].realVentureBalance -= ventureAmount;
            HUB.ventureTokenById(market.ventureId).safeTransfer(msg.sender, ventureAmount);
        }

        _checkInvariant(marketId);
        emit Merge(marketId, msg.sender, ventureAmount, moneyAmount);
    }

    /// @dev Asserts per-proposal conservation: the market's real backing for each token must cover
    ///      that proposal's full outstanding virtual supply — user-held supply PLUS pool reserves
    ///      PLUS accrued fees. Including the pool reserves on the liability side is what makes this a
    ///      genuine solvency check rather than a tautology: it catches any accounting path that lets a
    ///      proposal's virtual tokens outrun the escrowed real backing. Holds with equality in normal
    ///      operation, so it never reverts a legitimate action.
    function _checkInvariant(uint256 marketId) internal view {
        uint256[] storage proposalIds = _markets[marketId].proposalIds;
        SettleAcct storage s = _settle[marketId];
        for (uint256 i = 0; i < proposalIds.length; i++) {
            Pool storage pool = _pools[proposalIds[i]];
            uint256 ventureLiability = pool.userVirtualVentureSupply + pool.cpmm.reserve0 + pool.accruedFeeVenture;
            uint256 moneyLiability = pool.userVirtualMoneySupply + pool.cpmm.reserve1 + pool.accruedFeeMoney;
            if (s.realVentureBalance < ventureLiability) revert InvariantViolation();
            if (s.realMoneyBalance < moneyLiability) revert InvariantViolation();
        }
    }

    // ─────────────────────────────────────────────────────────
    // Liquidity
    // ─────────────────────────────────────────────────────────

    /// @notice Adds virtual venture and money tokens as liquidity to a proposal market.
    /// @dev The caller must already hold the virtual tokens (via `split`). LP shares are minted
    ///      pro rata to the caller.
    /// @param proposalId The proposal ID.
    /// @param amount0 The desired virtual venture amount to add.
    /// @param amount1 The desired virtual money amount to add.
    /// @param priceX96 The expected pool price as a Q96 fixed-point value, for slippage bounding.
    /// @param slippageBps The maximum tolerated price deviation in basis points.
    function addLiquidity(uint256 proposalId, uint256 amount0, uint256 amount1, uint256 priceX96, uint256 slippageBps)
        external
        nonReentrant
    {
        uint256 marketId = proposalToMarket[proposalId];
        if (marketId == 0) revert ProposalNotFound();
        if (getMarketStatus(marketId) != MarketStatus.OPEN) revert MarketNotOpen();

        _syncOracle(proposalId);
        Pool storage pool = _pools[proposalId];
        uint256 reserve0Before = pool.cpmm.reserve0;
        uint256 reserve1Before = pool.cpmm.reserve1;
        uint256 totalSharesBefore = pool.totalLiquidityShares;

        CPMM.AddLiquidityResult memory result = CPMM._addLiquidity(pool.cpmm, amount0, amount1, priceX96, slippageBps);
        uint256 shares = _quoteLiquidityShares(
            reserve0Before, reserve1Before, totalSharesBefore, result.actualAmount0, result.actualAmount1
        );
        if (shares == 0) revert InsufficientLiquidityShares();

        _move(msg.sender, address(this), getVirtualVentureId(proposalId), result.actualAmount0);
        _move(msg.sender, address(this), getVirtualMoneyId(proposalId), result.actualAmount1);

        pool.userVirtualVentureSupply -= result.actualAmount0;
        pool.userVirtualMoneySupply -= result.actualAmount1;
        _mint(msg.sender, getLiquidityShareId(proposalId), shares);
        pool.totalLiquidityShares = totalSharesBefore + shares;

        emit LiquidityAdded(proposalId, result.actualAmount0, result.actualAmount1);
    }

    /// @dev Quotes LP shares for a liquidity add: the minimum of the venture- and money-sided ratios
    ///      against existing reserves, or the geometric mean when the pool has no user shares yet.
    function _quoteLiquidityShares(
        uint256 reserve0Before,
        uint256 reserve1Before,
        uint256 totalSharesBefore,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint256 shares) {
        if (amount0 == 0 || amount1 == 0) return 0;
        if (totalSharesBefore == 0) {
            return _initialLiquidityShares(amount0, amount1);
        }
        if (reserve0Before == 0 || reserve1Before == 0) return 0;
        uint256 shares0 = FullMath.mulDiv(amount0, totalSharesBefore, reserve0Before);
        uint256 shares1 = FullMath.mulDiv(amount1, totalSharesBefore, reserve1Before);
        shares = shares0 < shares1 ? shares0 : shares1;
    }

    /// @dev Initial LP shares equal the geometric mean of the two deposited amounts.
    function _initialLiquidityShares(uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        if (amount0 == 0 || amount1 == 0) return 0;
        return Math.sqrt(amount0 * amount1);
    }

    // ─────────────────────────────────────────────────────────
    // Swaps
    // ─────────────────────────────────────────────────────────

    /// @notice Swaps an exact input amount of virtual tokens in a proposal market.
    /// @param proposalId The proposal ID.
    /// @param amountIn The exact input amount.
    /// @param amountOutMin The minimum acceptable output amount (slippage protection).
    /// @param maxPriceImpactBps The maximum tolerated price impact in basis points.
    /// @param zeroForOne True to swap virtual venture for virtual money, false for the reverse.
    /// @param deadline The latest block timestamp at which the swap may execute.
    /// @return amountOut The output amount delivered to the caller.
    function swapExactIn(
        uint256 proposalId,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        amountOut = _swapExactIn(proposalId, amountIn, amountOutMin, maxPriceImpactBps, zeroForOne, msg.sender);
    }

    /// @notice Deposits real tokens (split) and swaps in a proposal market in a single transaction.
    /// @dev The split targets the proposal's own market via `proposalToMarket`. `amountIn` is the
    ///      total virtual amount to swap and may exceed the freshly split amount when the caller
    ///      already holds virtual tokens; passing zero for both split amounts swaps existing
    ///      balance only.
    /// @param proposalId The proposal ID to swap in.
    /// @param ventureAmount The amount of venture tokens to deposit.
    /// @param moneyAmount The amount of money tokens to deposit.
    /// @param amountIn The exact input amount.
    /// @param amountOutMin The minimum acceptable output amount (slippage protection).
    /// @param maxPriceImpactBps The maximum tolerated price impact in basis points.
    /// @param zeroForOne True to swap virtual venture for virtual money, false for the reverse.
    /// @param deadline The latest block timestamp at which the swap may execute.
    /// @return amountOut The output amount delivered to the caller.
    function splitAndSwapExactIn(
        uint256 proposalId,
        uint256 ventureAmount,
        uint256 moneyAmount,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (ventureAmount > 0 || moneyAmount > 0) {
            uint256 marketId = proposalToMarket[proposalId];
            if (marketId == 0) revert ProposalNotFound();
            _split(marketId, ventureAmount, moneyAmount, msg.sender);
        }
        amountOut = _swapExactIn(proposalId, amountIn, amountOutMin, maxPriceImpactBps, zeroForOne, msg.sender);
    }

    /// @notice Executes an exact-input swap on behalf of a signer who authorized it via EIP-712.
    /// @dev Attributes the swap to `signer`; anyone (e.g. a relayer) may submit the transaction.
    /// @param permit The signed swap parameters.
    /// @param signer The address that authorized the swap.
    /// @param signature The EIP-712 signature (supports EOA and EIP-1271 wallets).
    /// @return amountOut The output amount delivered to the signer.
    function swapExactInWithPermit(SwapExactInPermit calldata permit, address signer, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > permit.deadline) revert DeadlineExpired();
        if (permit.nonce != swapNonces[signer]) revert InvalidSignature();
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_EXACT_IN_PERMIT_TYPEHASH,
                permit.proposalId,
                permit.amountIn,
                permit.amountOutMin,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );
        _verifySignature(structHash, signer, signature);
        unchecked {
            swapNonces[signer]++;
        }
        amountOut = _swapExactIn(
            permit.proposalId, permit.amountIn, permit.amountOutMin, permit.maxPriceImpactBps, permit.zeroForOne, signer
        );
    }

    /// @notice Swaps for an exact output amount of virtual tokens in a proposal market.
    /// @param proposalId The proposal ID.
    /// @param amountOut The exact output amount.
    /// @param amountInMax The maximum acceptable input amount (slippage protection).
    /// @param maxPriceImpactBps The maximum tolerated price impact in basis points.
    /// @param zeroForOne True to swap virtual venture for virtual money, false for the reverse.
    /// @param deadline The latest block timestamp at which the swap may execute.
    /// @return amountIn The input amount taken from the caller.
    function swapExactOut(
        uint256 proposalId,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountIn) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        amountIn = _swapExactOut(proposalId, amountOut, amountInMax, maxPriceImpactBps, zeroForOne, msg.sender, false);
    }

    /// @notice Executes an exact-output swap on behalf of a signer who authorized it via EIP-712.
    /// @dev Attributes the swap to `signer`; anyone (e.g. a relayer) may submit the transaction.
    /// @param permit The signed swap parameters.
    /// @param signer The address that authorized the swap.
    /// @param signature The EIP-712 signature (supports EOA and EIP-1271 wallets).
    /// @return amountIn The input amount taken from the signer.
    function swapExactOutWithPermit(SwapExactOutPermit calldata permit, address signer, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 amountIn)
    {
        if (block.timestamp > permit.deadline) revert DeadlineExpired();
        if (permit.nonce != swapNonces[signer]) revert InvalidSignature();
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_EXACT_OUT_PERMIT_TYPEHASH,
                permit.proposalId,
                permit.amountOut,
                permit.amountInMax,
                permit.maxPriceImpactBps,
                permit.zeroForOne,
                permit.nonce,
                permit.deadline
            )
        );
        _verifySignature(structHash, signer, signature);
        unchecked {
            swapNonces[signer]++;
        }
        amountIn = _swapExactOut(
            permit.proposalId,
            permit.amountOut,
            permit.amountInMax,
            permit.maxPriceImpactBps,
            permit.zeroForOne,
            signer,
            false
        );
    }

    /// @notice Swaps the same fraction of each proposal pool's output reserve in every proposal of a
    ///         market, no-op included.
    /// @dev Every pool's price moves by the same factor, so no proposal gains on another and the
    ///      settlement comparison is unchanged. The market's `activeManager` pays no fee here;
    ///      everyone else pays the market's normal fee on every leg.
    /// @param marketId The market ID.
    /// @param zeroForOne True to sell virtual venture for virtual money in every proposal.
    /// @param outFractionWad Each leg's output as a fraction of its pool's output reserve, in 1e18.
    /// @param amountInMaxPerLeg The maximum input of each leg.
    /// @param deadline The latest block timestamp at which the swap may execute.
    /// @return amountsIn Each leg's input, in `marketProposalIds` order.
    /// @return amountsOut Each leg's output, in `marketProposalIds` order.
    function basketSwapExactOut(
        uint256 marketId,
        bool zeroForOne,
        uint256 outFractionWad,
        uint256 amountInMaxPerLeg,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amountsIn, uint256[] memory amountsOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (_markets[marketId].id == 0) revert MarketNotFound();
        if (outFractionWad == 0 || outFractionWad >= WAD) revert InvalidAmount();
        bool exempt = msg.sender == activeManager[marketId];
        uint256[] memory proposalIds = _markets[marketId].proposalIds;
        amountsIn = new uint256[](proposalIds.length);
        amountsOut = new uint256[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            CPMM.State storage cpmmState = _pools[proposalIds[i]].cpmm;
            amountsOut[i] = FullMath.mulDiv(zeroForOne ? cpmmState.reserve1 : cpmmState.reserve0, outFractionWad, WAD);
            if (amountsOut[i] == 0) revert InvalidAmount();
            amountsIn[i] = _swapExactOut(
                proposalIds[i], amountsOut[i], amountInMaxPerLeg, type(uint256).max, zeroForOne, msg.sender, exempt
            );
        }
        emit BasketSwap(marketId, msg.sender, zeroForOne, outFractionWad, exempt);
    }

    /// @notice Invalidates all outstanding swap permits for the caller by advancing their nonce.
    function invalidateSwapNonce() external {
        unchecked {
            swapNonces[msg.sender]++;
        }
    }

    /// @dev Shared exact-input swap implementation for direct and permit-authorized callers.
    function _swapExactIn(
        uint256 proposalId,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        address trader
    ) internal returns (uint256 amountOut) {
        (CPMM.State storage cpmmState, uint16 swapFeeBps, uint16 protocolCutBps) = _beforeSwap(proposalId);
        (CPMM.SwapResult memory result, uint256 protocolFee) = CPMMWithFee._swapExactIn(
            cpmmState, amountIn, amountOutMin, maxPriceImpactBps, zeroForOne, swapFeeBps, protocolCutBps
        );
        amountOut = _finalizeSwap(proposalId, zeroForOne, trader, result, protocolFee);
    }

    /// @dev Shared exact-output swap implementation for direct, permit-authorized and basket callers.
    function _swapExactOut(
        uint256 proposalId,
        uint256 amountOut,
        uint256 amountInMax,
        uint256 maxPriceImpactBps,
        bool zeroForOne,
        address trader,
        bool feeExempt
    ) internal returns (uint256 amountIn) {
        (CPMM.State storage cpmmState, uint16 swapFeeBps, uint16 protocolCutBps) = _beforeSwap(proposalId);
        if (feeExempt) (swapFeeBps, protocolCutBps) = (0, 0);
        (CPMM.SwapResult memory result, uint256 protocolFee) = CPMMWithFee._swapExactOut(
            cpmmState, amountOut, amountInMax, maxPriceImpactBps, zeroForOne, swapFeeBps, protocolCutBps
        );
        amountIn = result.amountIn;
        _finalizeSwap(proposalId, zeroForOne, trader, result, protocolFee);
    }

    /// @dev Validates the proposal market is open, syncs the oracle, and returns its reserves for a swap.
    function _beforeSwap(uint256 proposalId)
        private
        returns (CPMM.State storage cpmmState, uint16 swapFeeBps, uint16 protocolCutBps)
    {
        uint256 marketId = proposalToMarket[proposalId];
        if (marketId == 0) revert ProposalNotFound();
        if (getMarketStatus(marketId) != MarketStatus.OPEN) revert MarketNotOpen();
        swapFeeBps = _markets[marketId].swapFeeBps;
        protocolCutBps = _markets[marketId].protocolCutBps;
        cpmmState = _pools[proposalId].cpmm;
        _syncOracle(proposalId);
    }

    /// @dev Settles a swap: moves virtual tokens between trader and pool, updates supplies, accrues
    ///      the protocol fee, and emits the swap event.
    function _finalizeSwap(
        uint256 proposalId,
        bool zeroForOne,
        address trader,
        CPMM.SwapResult memory result,
        uint256 protocolFee
    ) private returns (uint256 traderAmount) {
        uint256 amountIn = result.amountIn;
        uint256 amountOut = result.amountOut;
        traderAmount = amountOut;

        uint256 tokenInId = zeroForOne ? getVirtualVentureId(proposalId) : getVirtualMoneyId(proposalId);
        uint256 tokenOutId = zeroForOne ? getVirtualMoneyId(proposalId) : getVirtualVentureId(proposalId);

        _move(trader, address(this), tokenInId, amountIn);
        _move(address(this), trader, tokenOutId, traderAmount);

        Pool storage pool = _pools[proposalId];
        if (zeroForOne) {
            pool.userVirtualVentureSupply -= amountIn;
            pool.userVirtualMoneySupply += traderAmount;
        } else {
            pool.userVirtualMoneySupply -= amountIn;
            pool.userVirtualVentureSupply += traderAmount;
        }

        if (protocolFee > 0) {
            if (zeroForOne) {
                pool.accruedFeeVenture += protocolFee;
            } else {
                pool.accruedFeeMoney += protocolFee;
            }
            emit ProtocolFeeAccrued(proposalId, zeroForOne, protocolFee);
        }

        emit Swap(
            proposalId,
            trader,
            zeroForOne,
            amountIn,
            traderAmount,
            result.priceBeforeX96,
            result.priceAfterX96,
            result.priceImpactBps,
            protocolFee
        );
    }

    /// @dev Pushes the proposal market's latest reserves to the conditional-market oracle.
    function _syncOracle(uint256 proposalId) private {
        CPMM.State storage c = _pools[proposalId].cpmm;
        IConditionalMarketOracle(HUB.conditionalMarketOracle()).update(proposalId, c.reserve0, c.reserve1);
    }
}
