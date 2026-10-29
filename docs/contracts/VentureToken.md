# VentureToken

Source: `src/tokens/VentureToken.sol`

## Purpose

ERC20 token for an individual venture.

## Behavior

- OZ `ERC20Pausable`.
- `mint(to, amount)` and `burn(from, amount)` are `onlyOwner`.
- `pause()` and `unpause()` are `onlyOwner`.
- While paused, transfers revert but owner mint and burn still work, so liquidation burns proceed during the post-LBP trading pause.
- During venture creation, token ownership is transferred to the venture treasury contract.

## Notes

- Treasury/governance actions that mint or burn route through `Venture` into this contract.
