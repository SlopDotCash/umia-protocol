# GovernancePayloadValidator + GovernanceActions

Source: `src/libraries/GovernancePayloadValidator.sol`, `src/libraries/GovernanceActions.sol`

## Purpose

Stateless libraries for governance payload decoding, validation, and action dispatch:

- **GovernancePayloadValidator**: Decodes plan version, validates `ExecutionPlanV1` structure (at most 20 actions), and enforces `LIQUIDATE_TREASURY` as the final action.
- **GovernanceActions**: Validates individual action payloads and executes them against a `Venture`.

## Important functions

### GovernancePayloadValidator

- `decodePlanVersion(bytes calldata executionPayload)` - extracts `uint16 version`
- `validatePlanV1(ExecutionPlanV1 memory plan)` - validates plan version and all actions
- `decodeAndValidatePayload(bytes calldata executionPayload)` - combined decode + validate

### GovernanceActions

- `validateActionV1(ActionV1 memory action)` - validates a single action's payload
- `executeActionV1(IVenture venture, ActionV1 memory action)` - executes a single action (action version 1 only); payload validation runs beforehand in `validatePlanV1`

## Behavior notes

- Requires `action.actionVersion == 1` for all current actions.
- `UPDATE_PARAMS` reverts with `UnsupportedAction`.
- `LIQUIDATE_TREASURY` first redeems the venture's shares in the Hub's current vault (`withdraw(shares, 0, 0, venture)` via `executeCall`) and, when the vault exposes `activeManager()`, calls `ActiveLiquidityManager.withdrawAll()`. It then burns the treasury's venture-token balance (`venture.burn`), snapshots `claimableSupply = totalSupply`, calls `venture.setLiquidator(...)` and `ILiquidator.initialize(venture, assets, claimableSupply)`. Final-action enforcement is done in `GovernancePayloadValidator.validatePlanV1`.
- `SET_ALLOWANCE` and `SET_ALLOWANCE_SOURCE` delegate to `venture.setAllowance` and `venture.setAllowanceSource`.
- `CALL` blocks self-calls (`target == address(venture)`).
- `UPGRADE_IMPLEMENTATION` emits `ImplementationOptOut` for indexing.
