// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Minimal Aave v3 Pool surface (also matches Spark and other aToken forks).
interface IAaveV3Pool {
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @dev Minimal Morpho Blue surface. Withdrawal on behalf of the venture requires the venture to
///      have authorized this wrapper via setAuthorization (a governance CALL action).
interface IMorphoBlue {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
}

/// @title YieldPositionGuardian
/// @notice Per-venture emergency de-risking wrapper. Lets an appointed operator (EOA / Safe /
///         multisig) pull the venture's money-market positions back into the treasury without
///         waiting for a decision market (e.g. a fast depeg).
///
///         The safety invariant is enforced by this contract's code, not by the operator:
///         every exit path terminates with the funds at `venture`.
///
///         Wiring (no Venture upgrade needed):
///         - Aave-style: SET_ALLOWANCE(aToken, thisWrapper, type(uint256).max).
///         - Morpho Blue (direct market supply): CALL(morpho, setAuthorization(thisWrapper, true)).
///         - ERC-4626 vaults (Morpho vaults, sUSDC, ...): SET_ALLOWANCE(vaultShares, thisWrapper, type(uint256).max).
///
///         Notes:
///         - Stranded funds (dust, direct transfers) go home via the permissionless `sweep`.
///         - The operator (Ownable2Step owner) can rotate itself; two-step accept prevents
///           typo-locking, `renounceOwnership` hard-disables the emergency path. Rotation
///           covers proactive handover only: if the key is LOST, governance must zero the
///           allowances and redeploy.
///         - Standing aToken and vault-share allowances are NOT auto-revoked at liquidation.
///           Any LIQUIDATE_TREASURY plan MUST zero this wrapper's allowances first.
///         - Never make this upgradeable: the Morpho authorization breadth and standing
///           allowances are contained solely by this bytecode.
contract YieldPositionGuardian is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice The venture treasury this wrapper serves. All exits land here.
    address public immutable venture;

    error InvalidParams();

    event GuardianExitAave(address indexed pool, address indexed asset, uint256 assets, address indexed caller);
    event GuardianExitMorphoBlue(
        address indexed morpho, bytes32 indexed marketId, uint256 assets, address indexed caller
    );
    event GuardianExitVault(address indexed vault, uint256 shares, uint256 assets, address indexed caller);
    event Swept(address indexed token, uint256 amount);

    constructor(address _venture, address _operator) Ownable(_operator) {
        if (_venture == address(0) || _operator == address(0)) revert InvalidParams();
        venture = _venture;
    }

    /// @notice Pulls up to `amount` of the venture's aToken position and redeems exactly that
    ///         amount, sending the underlying back to the treasury.
    /// @dev Requires a standing SET_ALLOWANCE(aToken, this, >= amount) from the venture.
    ///      `type(uint256).max` exits the full position. `to` is hardcoded to the venture.
    /// @param amount Capped at the venture's aToken balance.
    function exitAave(address pool, address aToken, address asset, uint256 amount) external onlyOwner {
        if (pool == address(0) || aToken == address(0) || asset == address(0) || amount == 0) {
            revert InvalidParams();
        }

        uint256 balanceBefore = IERC20(aToken).balanceOf(address(this));
        uint256 pulled = IERC20(aToken).balanceOf(venture);
        if (amount < pulled) pulled = amount;
        IERC20(aToken).safeTransferFrom(venture, address(this), pulled);
        uint256 redeemable = IERC20(aToken).balanceOf(address(this)) - balanceBefore;

        uint256 received = IAaveV3Pool(pool).withdraw(asset, redeemable < pulled ? redeemable : pulled, venture);

        emit GuardianExitAave(pool, asset, received, msg.sender);
    }

    /// @notice Withdraws a Morpho Blue market position the venture supplied directly back to the
    ///         treasury. Does not cover Morpho vault shares; those are ERC-4626 and use `exitVault`.
    /// @dev `onBehalf` and `receiver` are hardcoded to the venture.
    /// @param assets Amount of loan token to withdraw (0 to withdraw by `shares` instead).
    /// @param shares Amount of supply shares to burn (0 to withdraw by `assets` instead).
    function exitMorphoBlue(
        address morpho,
        IMorphoBlue.MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares
    ) external onlyOwner {
        if (morpho == address(0) || (assets == 0 && shares == 0)) revert InvalidParams();

        (uint256 withdrawn,) = IMorphoBlue(morpho).withdraw(marketParams, assets, shares, venture, venture);

        emit GuardianExitMorphoBlue(morpho, keccak256(abi.encode(marketParams)), withdrawn, msg.sender);
    }

    /// @notice Redeems up to `shares` of the venture's ERC-4626 vault position, sending the
    ///         underlying back to the treasury.
    /// @dev Requires a standing SET_ALLOWANCE(vault, this, >= shares) from the venture on the share
    ///      token. Redeems by shares rather than assets so partial exits still work when a vault's
    ///      free liquidity is below the position. `receiver` and `owner` are hardcoded to the venture.
    /// @param shares Capped at the venture's share balance; `type(uint256).max` exits the full position.
    function exitVault(address vault, uint256 shares) external onlyOwner {
        if (vault == address(0) || shares == 0) revert InvalidParams();

        uint256 redeemed = IERC20(vault).balanceOf(venture);
        if (shares < redeemed) redeemed = shares;
        if (redeemed == 0) revert InvalidParams();

        uint256 received = IERC4626(vault).redeem(redeemed, venture, venture);

        emit GuardianExitVault(vault, redeemed, received, msg.sender);
    }

    /// @notice Returns this contract's entire balance of `token` to the venture. Permissionless.
    function sweep(address token) external {
        if (token == address(0)) revert InvalidParams();
        uint256 balance = _returnToken(token);
        emit Swept(token, balance);
    }

    function _returnToken(address token) internal returns (uint256 balance) {
        balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(venture, balance);
        }
    }
}
