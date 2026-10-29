// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {
    ILBPInitializer,
    LBPInitializationParams,
    ILBP_INITIALIZER_INTERFACE_ID
} from "@liquidity-launcher/interfaces/ILBPInitializer.sol";
import {IDistributor} from "@liquidity-launcher/interfaces/IDistributor.sol";
import {IDistributorFactory} from "@liquidity-launcher/interfaces/IDistributorFactory.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {TokenPricing} from "@liquidity-launcher/libraries/TokenPricing.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ContinuousClearingAuction} from "@continuous-clearing-auction/ContinuousClearingAuction.sol";
import {BlockNumberish} from "@blocknumberish/src/BlockNumberish.sol";
import {BipsLibrary} from "@uniswap/v4-periphery/src/libraries/BipsLibrary.sol";

import {ILBPMigrationCallback} from "../interfaces/ILBPMigrationCallback.sol";
import {IUmiaLBP} from "../interfaces/IUmiaLBP.sol";
import {IUmiaHook} from "../interfaces/IUmiaHook.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {IUmiaHookV2} from "../interfaces/IUmiaHookV2.sol";
import {SpotLiquidityV2Code} from "../periphery/SpotLiquidityV2Code.sol";
import {SpotLiquidityV2Deploy} from "../libraries/SpotLiquidityV2Deploy.sol";
import {ActiveSlices} from "../libraries/ActiveSlices.sol";
import {ActiveLiquidityManager} from "../core/ActiveLiquidityManager.sol";

/// @title UmiaLBPV2
/// @notice `UmiaLBP` for pools on `UmiaHookV2`. When it moves the auction's proceeds into the spot
///         pool it also deploys the venture's `SpotLiquidityVaultV2` and an empty
///         `ActiveLiquidityManager`, registers both as the pool's operators, and bootstraps the vault.
///         The venture funds the ALM later, by proposal.
/// @dev A copy of `UmiaLBP`, kept separate so V1's deployed bytecode keeps matching the repo. Only
///      the constructor's code pointers and migration steps 8 and 9 differ.
///      Built on the liquidity-launcher interfaces directly rather than `LBPStrategyBase`, which does
///      not fit this flow. Inherits `BlockNumberish` so every block read uses the auction's clock: on
///      Nitro and Orbit chains the auction's `endBlock` is an ArbSys L2 block number that raw
///      `block.number` never reaches.
contract UmiaLBPV2 is IDistributor, ReentrancyGuard, IUmiaLBP, BlockNumberish {
    using SafeERC20 for IERC20;
    using TokenPricing for *;
    using CurrencyLibrary for Currency;

    // ─────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────

    uint256 public constant MAX_BPS = 9_999;
    uint256 public constant TOKEN_SPLIT_DENOMINATOR = 10_000_000;

    // ─────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────

    address public immutable venture;
    uint256 public immutable ventureBps;
    address public immutable token;
    uint128 public immutable totalSupply;
    uint128 public immutable reserveTokenAmount;
    address public immutable currency;
    uint256 public immutable tokenSplitToAuction;
    IPoolManager public immutable poolManager;
    IUmiaHook public immutable umiaHook;
    IUmiaHub public immutable hub;
    /// @notice Shared vault and ALM creation code; keeps both initcodes out of this contract's
    ///         EIP-170 budget.
    SpotLiquidityV2Code public immutable spotLiquidityCode;

    // ─────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────

    // Auction state
    bytes public auctionParams;
    ILBPInitializer public initializer;
    bool public migrated;
    /// @notice Block (BlockNumberish domain) at which migrate() ran; 0 until migrated. Anchors the sweep delay.
    uint64 public migratedAtBlock;

    // ─────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────

    /// @notice Constructor
    /// @param _token The token to be distributed
    /// @param _totalSupply The total supply of the token
    /// @param _tokenSplitToAuction The fraction of supply auctioned (of TOKEN_SPLIT_DENOMINATOR)
    /// @param _moneyToken The venture's money token (pool + auction currency)
    /// @param _auctionParams The auction parameters
    /// @param _poolManager The uniswap v4 pool manager address
    /// @param _umiaHook The singleton UmiaHookV2 address
    /// @param _venture The venture treasury address
    /// @param _ventureBps The venture treasury basis points
    /// @param _spotLiquidityCode Shared SpotLiquidityVaultV2 and ActiveLiquidityManager creation code
    constructor(
        address _token,
        uint128 _totalSupply,
        uint256 _tokenSplitToAuction,
        address _moneyToken,
        bytes memory _auctionParams,
        IPoolManager _poolManager,
        IUmiaHook _umiaHook,
        address _venture,
        uint256 _ventureBps,
        SpotLiquidityV2Code _spotLiquidityCode
    ) {
        if (_venture == address(0)) revert InvalidVentureAddress();
        if (_ventureBps > MAX_BPS) revert InvalidVentureBps();
        if (_tokenSplitToAuction >= TOKEN_SPLIT_DENOMINATOR) revert TokenSplitTooHigh();
        if ((uint256(_totalSupply) * _tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR == 0) {
            revert InitializerTokenSplitIsZero();
        }

        venture = _venture;
        ventureBps = _ventureBps;
        token = _token;
        totalSupply = _totalSupply;
        uint256 auctionSupply = (uint256(_totalSupply) * _tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR;
        reserveTokenAmount = _totalSupply - uint128(auctionSupply);
        currency = _moneyToken;
        tokenSplitToAuction = _tokenSplitToAuction;
        auctionParams = _auctionParams;
        poolManager = _poolManager;
        umiaHook = _umiaHook;
        hub = IUmiaHub(IVenture(_venture).HUB());
        spotLiquidityCode = _spotLiquidityCode;
    }

    // ─────────────────────────────────────────────────────────
    // External Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Called when tokens are transferred to this contract to initialize the auction
    /// @dev Implements IDistributor - creates the auction initializer
    function onTokensReceived() external override {
        // Validate at least totalSupply tokens received
        if (IERC20(token).balanceOf(address(this)) < totalSupply) {
            revert InvalidAmountReceived(totalSupply, IERC20(token).balanceOf(address(this)));
        }

        // Ensure initializer hasn't been created yet
        if (address(initializer) != address(0)) {
            revert InitializerAlreadyCreated();
        }

        // Calculate supply for auction (totalSupply - reserve)
        uint128 supply = totalSupply - reserveTokenAmount;

        // Deploy auction initializer via factory
        ILBPInitializer _initializer = ILBPInitializer(
            address(IDistributorFactory(hub.ccaFactory()).create(token, supply, auctionParams, bytes32(0)))
        );

        // Validate initializer implements correct interface
        if (!ERC165Checker.supportsInterface(address(_initializer), ILBP_INITIALIZER_INTERFACE_ID)) {
            revert InitializerMustImplementInterface();
        }

        // Validate initializer parameters
        _validateInitializerParams(_initializer);

        // Transfer tokens to auction
        Currency.wrap(token).transfer(address(_initializer), supply);

        // Store initializer
        initializer = _initializer;

        // Notify auction it received tokens
        _initializer.onTokensReceived();

        emit InitializerCreated(address(_initializer));
    }

    /// @notice Migrates auction funds to Uniswap V4 pool with venture distribution
    /// @dev Custom implementation (not extending base)
    function migrate() external nonReentrant {
        if (migrated) revert AlreadyMigrated();
        if (address(initializer) == address(0)) revert MigrationNotAllowed();

        // 1. Validate migration timing: the auction must have ended and the Hub's migration delay
        //    (blocks) must have elapsed since its end block.
        if (_getBlockNumberish() < uint256(initializer.endBlock()) + hub.migrationDelayBlocks()) {
            revert MigrationNotAllowed();
        }

        // 2. Get initialization params from initializer
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        // 3. Sweep CCA funds to this contract (skips if already swept)
        ContinuousClearingAuction cca = ContinuousClearingAuction(address(initializer));
        if (cca.sweepCurrencyBlock() == 0) {
            cca.sweepCurrency();
        }
        if (cca.sweepUnsoldTokensBlock() == 0) {
            cca.sweepUnsoldTokens();
        }

        // 4. Validate currency raised
        if (lbpParams.currencyRaised > type(uint128).max) {
            revert CurrencyAmountTooHigh();
        }
        uint128 currencyRaised = uint128(lbpParams.currencyRaised);
        if (currencyRaised == 0) revert NoCurrencyRaised();

        // 5. Calculate and distribute venture share BEFORE pool creation
        uint128 ventureShare = uint128(BipsLibrary.calculatePortion(uint256(currencyRaised), ventureBps));
        uint128 remainingCurrency = currencyRaised - ventureShare;

        // 6. Validate we have enough currency
        uint256 contractBalance = Currency.wrap(currency).balanceOf(address(this));
        if (contractBalance < currencyRaised) {
            revert InsufficientCurrency();
        }

        // 7. Transfer venture share of currency
        if (ventureShare > 0) {
            Currency.wrap(currency).transfer(venture, ventureShare);
            emit VentureFundsDistributed(ventureShare, 0);
        }

        // 8. Read the canonical pool params from the Hub, deploy the venture's anchor vault and its ALM
        //    (this LBP may seed it once, below), and register the vault with the Hub.
        // V4 fees are in pips (1e-6), the Hub's spot fee is in bps, so scale by 100.
        uint24 poolLPFee = uint24(hub.spotSwapFeeBps()) * 100;
        int24 poolTickSpacing = hub.defaultPoolTickSpacing();
        (address vaultAddress, address alm) = SpotLiquidityV2Deploy.deploy(
            spotLiquidityCode,
            address(hub),
            venture,
            address(poolManager),
            address(umiaHook),
            poolLPFee,
            poolTickSpacing,
            address(this)
        );
        ISpotLiquidityVault vault = ISpotLiquidityVault(vaultAddress);
        hub.registerSpotLiquidityVault(venture, address(vault));

        // 9. Register the pool with the singleton hook: launcher = this LBP (gates initialize),
        //    anchor = the vault (full range), active = the ALM (any range).
        PoolKey memory key = PoolKey({
            currency0: _currency0(),
            currency1: _currency1(),
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(umiaHook))
        });
        IUmiaHookV2(address(umiaHook))
            .registerPool(
                key,
                IUmiaHookV2.PoolConfig({
                launcher: address(this), venture: venture, anchorOperator: address(vault), activeOperator: alm
            })
            );

        // 10. Convert the auction's discovered price into a v4 pool sqrt price and initialize the
        //     pool. beforeInitialize gates to the launcher, so the LBP must be the initializer.
        bool currencyIsCurrency0 = _currencyIsCurrency0();
        uint160 sqrtPriceX96 = lbpParams.initialPriceX96.convertToPriceX192(currencyIsCurrency0).convertToSqrtPriceX96();
        int24 tick = poolManager.initialize(key, sqrtPriceX96);

        // 11. Fund the pool's two operators from the raised liquidity by the Hub's launch split.
        _fundOperators(vault, alm, key, sqrtPriceX96, tick, remainingCurrency);

        // 12. Notify the venture about migration (trading pause). No LP NFT in the vault model.
        ILBPMigrationCallback(venture).onLBPMigrated();

        // 13. Set migrated flag + anchor the sweep delay to this block
        migrated = true;
        migratedAtBlock = uint64(_getBlockNumberish());

        // 14. Emit Migrated event
        emit Migrated(key, sqrtPriceX96);
    }

    /// @dev The anchor vault bootstraps with `launchAnchorBps` of the tokens and currency. The ALM gets
    ///      the rest and opens one range of `launchActiveHalfWidthTicks` each side of the clearing tick;
    ///      it cannot rebalance until the pool has oracle history, so that range is its whole book at first.
    function _fundOperators(
        ISpotLiquidityVault vault,
        address alm,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tick,
        uint256 currencyAmount
    ) private {
        uint16 anchorBps = hub.launchAnchorBps();
        int24 halfWidth = hub.launchActiveHalfWidthTicks();
        if (anchorBps == 0 || halfWidth == 0) revert LaunchSplitUnset();

        uint256 tokenAmount = IERC20(token).balanceOf(address(this));
        uint256 anchorTokens = BipsLibrary.calculatePortion(tokenAmount, anchorBps);
        uint256 anchorCurrency = BipsLibrary.calculatePortion(currencyAmount, anchorBps);
        IERC20(token).forceApprove(address(vault), anchorTokens);
        IERC20(currency).forceApprove(address(vault), anchorCurrency);
        vault.bootstrapFromLBP(anchorTokens, anchorCurrency, venture);
        if (anchorBps == ActiveSlices.MAX_BPS) return;

        IERC20(token).safeTransfer(alm, tokenAmount - anchorTokens);
        IERC20(currency).safeTransfer(alm, currencyAmount - anchorCurrency);
        ActiveSlices.Slice[] memory range = new ActiveSlices.Slice[](1);
        range[0] = ActiveSlices.Slice(-halfWidth, halfWidth, ActiveSlices.MAX_BPS);
        ActiveLiquidityManager(alm).seed(ActiveSlices.toPositions(key, alm, sqrtPriceX96, tick, range));
    }

    // ─────────────────────────────────────────────────────────
    // Internal Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Get currency0 of the pool
    /// @return currency0 The currency0 of the pool
    function _currency0() internal view returns (Currency) {
        return Currency.wrap(_currencyIsCurrency0() ? currency : token);
    }

    /// @notice Get currency1 of the pool
    /// @return currency1 The currency1 of the pool
    function _currency1() internal view returns (Currency) {
        return Currency.wrap(_currencyIsCurrency0() ? token : currency);
    }

    /// @notice Returns true if currency is currency0 of the pool
    /// @return isCurrency0 True if currency is currency0 of the pool
    function _currencyIsCurrency0() internal view returns (bool) {
        return currency < token;
    }

    /// @notice Validates initializer parameters
    /// @dev Ensures currency flows back to this contract and timing is correct
    function _validateInitializerParams(ILBPInitializer _initializer) internal view {
        // Require this contract to receive the raised currency from the initializer
        if (_initializer.fundsRecipient() != address(this)) {
            revert InvalidFundsRecipient();
        }
        // Require this contract to receive unsold tokens from the initializer
        if (_initializer.tokensRecipient() != address(this)) {
            revert InvalidTokensRecipient();
        }
        // Require the currency used by the initializer to be the same as the currency used by this strategy
        if (_initializer.currency() != currency) {
            revert InvalidCurrency();
        }
    }

    // ─────────────────────────────────────────────────────────
    // Sweep Functions
    // ─────────────────────────────────────────────────────────

    /// @notice Sweeps leftover tokens to venture
    /// @dev Callable by anyone once the Hub's sweep delay has elapsed since migration.
    function sweepToken() external {
        if (!migrated || _getBlockNumberish() < uint256(migratedAtBlock) + hub.sweepDelayBlocks()) {
            revert SweepNotAllowed();
        }

        uint256 tokenBalance = Currency.wrap(token).balanceOf(address(this));
        if (tokenBalance > 0) {
            Currency.wrap(token).transfer(venture, tokenBalance);
            emit TokensSwept(venture, tokenBalance);
        }
    }

    /// @notice Sweeps leftover currency to venture
    /// @dev Callable by anyone once the Hub's sweep delay has elapsed since migration.
    function sweepCurrency() external {
        if (!migrated || _getBlockNumberish() < uint256(migratedAtBlock) + hub.sweepDelayBlocks()) {
            revert SweepNotAllowed();
        }

        uint256 currencyBalance = Currency.wrap(currency).balanceOf(address(this));
        if (currencyBalance > 0) {
            Currency.wrap(currency).transfer(venture, currencyBalance);
            emit CurrencySwept(venture, currencyBalance);
        }
    }
}
