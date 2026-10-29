// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GovernanceTypes} from "./GovernanceTypes.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {ILiquidator} from "../interfaces/ILiquidator.sol";
import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {ISpotLiquidityVaultV2} from "../interfaces/ISpotLiquidityVaultV2.sol";
import {IActiveLiquidityManager} from "../interfaces/IActiveLiquidityManager.sol";

/// @title GovernanceActions
/// @notice Stateless action validation and execution helpers for governance payloads.
library GovernanceActions {
    error InvalidActionVersion();
    error InvalidAction();
    error InvalidParams();
    error UnsupportedAction();

    event ImplementationOptOut(address indexed venture, address indexed newImplementation);

    function validateActionV1(GovernanceTypes.ActionV1 memory action) internal pure {
        if (action.actionVersion != 1) revert InvalidActionVersion();

        GovernanceTypes.ActionType actionType = action.actionType;
        if (actionType == GovernanceTypes.ActionType.MINT_TOKENS) return _validateMint(action.data);
        if (actionType == GovernanceTypes.ActionType.BURN_TOKENS) return _validateBurn(action.data);
        if (actionType == GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS) return _validateTransfer(action.data);
        if (actionType == GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE) return _validateAllowance(action.data);
        if (actionType == GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER) return _validateTeamMember(action.data);
        if (actionType == GovernanceTypes.ActionType.UPDATE_PARAMS) revert UnsupportedAction();
        if (actionType == GovernanceTypes.ActionType.UPLOAD_DOCUMENT) return _validateDocument(action.data);
        if (actionType == GovernanceTypes.ActionType.LIQUIDATE_TREASURY) return _validateLiquidation(action.data);
        if (actionType == GovernanceTypes.ActionType.CALL) return _validateCall(action.data);
        if (actionType == GovernanceTypes.ActionType.UPGRADE_IMPLEMENTATION) return _validateUpgrade(action.data);
        if (actionType == GovernanceTypes.ActionType.SET_ALLOWANCE) return _validateSetAllowance(action.data);
        if (actionType == GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE) {
            return _validateSetAllowanceSource(action.data);
        }

        revert InvalidAction();
    }

    function executeActionV1(IVenture venture, GovernanceTypes.ActionV1 memory action) internal {
        if (action.actionVersion != 1) revert InvalidActionVersion();

        GovernanceTypes.ActionType actionType = action.actionType;
        if (actionType == GovernanceTypes.ActionType.MINT_TOKENS) return _executeMint(venture, action.data);
        if (actionType == GovernanceTypes.ActionType.BURN_TOKENS) return _executeBurn(venture, action.data);
        if (actionType == GovernanceTypes.ActionType.TRANSFER_TREASURY_ASSETS) {
            return _executeTransfer(venture, action.data);
        }
        if (actionType == GovernanceTypes.ActionType.UPDATE_MONTHLY_ALLOWANCE) {
            return _executeAllowance(venture, action.data);
        }
        if (actionType == GovernanceTypes.ActionType.UPDATE_TEAM_MEMBER) {
            return _executeTeamMember(venture, action.data);
        }
        if (actionType == GovernanceTypes.ActionType.UPDATE_PARAMS) revert UnsupportedAction();
        if (actionType == GovernanceTypes.ActionType.UPLOAD_DOCUMENT) return _executeDocument(venture, action.data);
        if (actionType == GovernanceTypes.ActionType.LIQUIDATE_TREASURY) {
            return _executeLiquidation(venture, action.data);
        }
        if (actionType == GovernanceTypes.ActionType.CALL) return _executeCall(venture, action.data);
        if (actionType == GovernanceTypes.ActionType.UPGRADE_IMPLEMENTATION) {
            return _executeUpgrade(venture, action.data);
        }
        if (actionType == GovernanceTypes.ActionType.SET_ALLOWANCE) {
            return _executeSetAllowance(venture, action.data);
        }
        if (actionType == GovernanceTypes.ActionType.SET_ALLOWANCE_SOURCE) {
            return _executeSetAllowanceSource(venture, action.data);
        }

        revert InvalidAction();
    }

    function _validateMint(bytes memory data) private pure {
        GovernanceTypes.MintTokens memory params = abi.decode(data, (GovernanceTypes.MintTokens));
        if (params.to == address(0) || params.amount == 0) revert InvalidParams();
    }

    function _validateBurn(bytes memory data) private pure {
        GovernanceTypes.BurnTokens memory params = abi.decode(data, (GovernanceTypes.BurnTokens));
        if (params.amount == 0) revert InvalidParams();
    }

    function _validateTransfer(bytes memory data) private pure {
        GovernanceTypes.TransferTreasuryAssets memory params =
            abi.decode(data, (GovernanceTypes.TransferTreasuryAssets));
        if (params.to == address(0)) revert InvalidParams();

        if (params.assetType == GovernanceTypes.AssetType.NATIVE || params.assetType == GovernanceTypes.AssetType.ERC20)
        {
            if (params.amount == 0) revert InvalidParams();
            if (params.assetType == GovernanceTypes.AssetType.NATIVE && params.token != address(0)) {
                revert InvalidParams();
            }
            if (params.assetType == GovernanceTypes.AssetType.ERC20 && params.token == address(0)) {
                revert InvalidParams();
            }
            return;
        }

        if (params.assetType == GovernanceTypes.AssetType.ERC721) {
            if (params.token == address(0)) revert InvalidParams();
            return;
        }

        if (params.assetType == GovernanceTypes.AssetType.ERC1155) {
            if (params.amount == 0) revert InvalidParams();
            if (params.token == address(0)) revert InvalidParams();
            return;
        }

        revert InvalidParams();
    }

    function _validateAllowance(bytes memory data) private pure {
        GovernanceTypes.UpdateMonthlyAllowance memory params =
            abi.decode(data, (GovernanceTypes.UpdateMonthlyAllowance));
        if (params.token == address(0)) revert InvalidParams();
    }

    function _validateTeamMember(bytes memory data) private pure {
        GovernanceTypes.UpdateTeamMember memory params = abi.decode(data, (GovernanceTypes.UpdateTeamMember));
        if (params.member == address(0)) revert InvalidParams();
    }

    function _validateDocument(bytes memory data) private pure {
        GovernanceTypes.UploadDocument memory params = abi.decode(data, (GovernanceTypes.UploadDocument));
        if (bytes(params.name).length == 0 || bytes(params.uri).length == 0) revert InvalidParams();
        if (bytes(params.name).length > 256) revert InvalidParams();
        if (bytes(params.uri).length > 2048) revert InvalidParams();
    }

    function _validateLiquidation(bytes memory data) private pure {
        GovernanceTypes.LiquidationPlan memory params = abi.decode(data, (GovernanceTypes.LiquidationPlan));
        if (params.liquidator == address(0)) revert InvalidParams();
        if (params.assets.length == 0) revert InvalidParams();

        uint256 assetCount = params.assets.length;
        for (uint256 i = 0; i < assetCount; i++) {
            GovernanceTypes.LiquidationAsset memory asset = params.assets[i];
            if (asset.assetType == GovernanceTypes.AssetType.NATIVE) {
                if (asset.token != address(0)) revert InvalidParams();
                if (asset.tokenId != 0) revert InvalidParams();
            } else if (asset.assetType == GovernanceTypes.AssetType.ERC20) {
                if (asset.token == address(0)) revert InvalidParams();
                if (asset.tokenId != 0) revert InvalidParams();
            } else if (asset.assetType == GovernanceTypes.AssetType.ERC721) {
                if (asset.token == address(0)) revert InvalidParams();
            } else if (asset.assetType == GovernanceTypes.AssetType.ERC1155) {
                if (asset.token == address(0)) revert InvalidParams();
            } else {
                revert InvalidParams();
            }

            for (uint256 j = 0; j < i; j++) {
                if (
                    params.assets[i].assetType == params.assets[j].assetType
                        && params.assets[i].token == params.assets[j].token
                        && params.assets[i].tokenId == params.assets[j].tokenId
                ) revert InvalidParams();
            }
        }
    }

    function _validateCall(bytes memory data) private pure {
        GovernanceTypes.Call memory params = abi.decode(data, (GovernanceTypes.Call));
        if (params.target == address(0)) revert InvalidParams();
    }

    function _validateUpgrade(bytes memory data) private pure {
        GovernanceTypes.UpgradeImplementation memory params = abi.decode(data, (GovernanceTypes.UpgradeImplementation));
        if (params.newImplementation == address(0)) revert InvalidParams();
    }

    function _validateSetAllowance(bytes memory data) private pure {
        GovernanceTypes.SetAllowance memory params = abi.decode(data, (GovernanceTypes.SetAllowance));
        if (params.token == address(0) || params.spender == address(0)) revert InvalidParams();
    }

    function _validateSetAllowanceSource(bytes memory data) private pure {
        GovernanceTypes.SetAllowanceSource memory params = abi.decode(data, (GovernanceTypes.SetAllowanceSource));
        if (params.source == address(0)) revert InvalidParams();
        if (params.sourceKind > uint8(IVenture.AllowanceSourceKind.ERC4626)) revert InvalidParams();
        if (params.sourceKind == 0) return;
        if (params.underlying == address(0) || params.source == params.underlying) revert InvalidParams();
    }

    function _executeMint(IVenture venture, bytes memory data) private {
        GovernanceTypes.MintTokens memory params = abi.decode(data, (GovernanceTypes.MintTokens));
        venture.mint(params.to, params.amount);
    }

    function _executeBurn(IVenture venture, bytes memory data) private {
        GovernanceTypes.BurnTokens memory params = abi.decode(data, (GovernanceTypes.BurnTokens));
        venture.burn(params.amount);
    }

    function _executeTransfer(IVenture venture, bytes memory data) private {
        GovernanceTypes.TransferTreasuryAssets memory params =
            abi.decode(data, (GovernanceTypes.TransferTreasuryAssets));

        if (params.assetType == GovernanceTypes.AssetType.NATIVE || params.assetType == GovernanceTypes.AssetType.ERC20)
        {
            venture.withdraw(params.token, params.to, params.amount);
            return;
        }

        if (params.assetType == GovernanceTypes.AssetType.ERC721) {
            venture.withdrawERC721(params.token, params.to, params.tokenId);
            return;
        }

        if (params.assetType == GovernanceTypes.AssetType.ERC1155) {
            venture.withdrawERC1155(params.token, params.to, params.tokenId, params.amount, params.data);
            return;
        }

        revert InvalidParams();
    }

    function _executeAllowance(IVenture venture, bytes memory data) private {
        GovernanceTypes.UpdateMonthlyAllowance memory params =
            abi.decode(data, (GovernanceTypes.UpdateMonthlyAllowance));
        venture.updateMonthlyAllowance(params.token, params.amount);
    }

    function _executeTeamMember(IVenture venture, bytes memory data) private {
        GovernanceTypes.UpdateTeamMember memory params = abi.decode(data, (GovernanceTypes.UpdateTeamMember));
        venture.updateTeamMember(params.member, params.approved);
    }

    function _executeDocument(IVenture venture, bytes memory data) private {
        GovernanceTypes.UploadDocument memory params = abi.decode(data, (GovernanceTypes.UploadDocument));
        venture.uploadDocument(params.name, params.uri);
    }

    function _executeLiquidation(IVenture venture, bytes memory data) private {
        GovernanceTypes.LiquidationPlan memory params = abi.decode(data, (GovernanceTypes.LiquidationPlan));

        // Liquidation does not revoke standing ERC20 allowances; setLiquidator only flips the terminal
        // flag, after which they can no longer be cleared. The plan MUST zero every live allowance with
        // SET_ALLOWANCE(token, spender, 0) actions ordered before this action, else a spender can drain
        // claim-backing assets via transferFrom post-snapshot. See docs/GOVERNANCE_TREASURY_LAYER.md.
        address ventureToken = venture.token();

        // Redeem the venture's spot LP shares (pool reserves + its pro-rata idle) into the treasury
        // while still not liquidating — setLiquidator locks out this executeCall path, and the vault
        // has no liquidator path, so the shares are otherwise unreachable during the wind-down.
        // The redeemed money tokens become treasury balances the liquidator distributes; list the
        // money token (and any other real treasury assets) in the plan. Do NOT list the venture
        // token: it is the claim-burn token, and the liquidator excludes it from payouts.
        address vault = IUmiaHub(venture.HUB()).ventureLiquidityVault(address(venture));
        if (vault != address(0)) {
            uint256 shares = ISpotLiquidityVault(vault).shareBalance(address(venture));
            if (shares != 0) {
                venture.executeCall(
                    vault, 0, abi.encodeCall(ISpotLiquidityVault.withdraw, (shares, 0, 0, address(venture)))
                );
            }
            // Same for a V2 pool's active liquidity manager, whose withdrawAll is venture-only. V1
            // vaults have no manager getter.
            try ISpotLiquidityVaultV2(vault).activeManager() returns (address manager) {
                if (manager != address(0)) {
                    venture.executeCall(manager, 0, abi.encodeCall(IActiveLiquidityManager.withdrawAll, ()));
                }
            } catch {}
        }

        // Treasury-held venture tokens can never claim, and a standing approval could recirculate them
        // after the snapshot to over-draw holders. Must precede setLiquidator, which locks out burn.
        uint256 treasurySupply = IERC20(ventureToken).balanceOf(address(venture));
        if (treasurySupply != 0) venture.burn(treasurySupply);
        uint256 claimableSupply = IERC20(ventureToken).totalSupply();
        if (claimableSupply == 0) revert InvalidParams();

        venture.setLiquidator(params.liquidator);
        ILiquidator(params.liquidator).initialize(address(venture), params.assets, claimableSupply);
    }

    function _executeCall(IVenture venture, bytes memory data) private {
        GovernanceTypes.Call memory params = abi.decode(data, (GovernanceTypes.Call));
        if (params.target == address(venture)) revert InvalidParams();
        venture.executeCall(params.target, params.value, params.data);
    }

    function _executeUpgrade(IVenture venture, bytes memory data) private {
        GovernanceTypes.UpgradeImplementation memory params = abi.decode(data, (GovernanceTypes.UpgradeImplementation));
        UUPSUpgradeable(address(venture)).upgradeToAndCall(params.newImplementation, params.data);
        emit ImplementationOptOut(address(venture), params.newImplementation);
    }

    function _executeSetAllowance(IVenture venture, bytes memory data) private {
        GovernanceTypes.SetAllowance memory params = abi.decode(data, (GovernanceTypes.SetAllowance));
        venture.setAllowance(params.token, params.spender, params.amount);
    }

    function _executeSetAllowanceSource(IVenture venture, bytes memory data) private {
        GovernanceTypes.SetAllowanceSource memory params = abi.decode(data, (GovernanceTypes.SetAllowanceSource));
        venture.setAllowanceSource(params.source, params.underlying, IVenture.AllowanceSourceKind(params.sourceKind));
    }
}
