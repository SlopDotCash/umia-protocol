# GovernanceTypes

Source: `src/libraries/GovernanceTypes.sol`

## Purpose

Shared enums and ABI structs for governance execution payloads.

## Core payload format

- `ExecutionPlanV1 { uint16 version; ActionV1[] actions; }`
- `ActionV1 { ActionType actionType; uint16 actionVersion; bytes data; }`

## ActionType enum

New action types are appended at the end. Ordinals are part of the ABI of every
encoded `ExecutionPlanV1`, so existing values must never be reordered.

- `MINT_TOKENS`
- `BURN_TOKENS`
- `TRANSFER_TREASURY_ASSETS`
- `UPDATE_MONTHLY_ALLOWANCE`
- `UPDATE_TEAM_MEMBER`
- `UPDATE_PARAMS`
- `UPLOAD_DOCUMENT`
- `LIQUIDATE_TREASURY`
- `CALL`
- `UPGRADE_IMPLEMENTATION`
- `SET_ALLOWANCE`
- `SET_ALLOWANCE_SOURCE`

## AssetType enum

- `NATIVE`, `ERC20`, `ERC721`, `ERC1155`

## Notes

- These types are consumed by `GovernanceExecutor`, `GovernancePayloadValidator`, and `GovernanceActions`.
