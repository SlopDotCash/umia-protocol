# UmiaValidationHook

Source: `src/periphery/UmiaValidationHook.sol`, one contract that inherits the `HookServerPermits` base (`src/periphery/HookServerPermits.sol`) and calls two libraries: `HookStepSchedule` (decodes the CCA schedule at pairing) and `HookProofValidation` (signed context binding and bid-proof freshness), both in `src/periphery/libraries/`.

## Purpose

CCA validation hook that restricts bidding to verified users during auction steps. `validate()` is the only entry point for credentials; both kinds travel inline in the bid's `hookData`:

1. **zkTLS proof**: registers the wallet on an ordinary proof-gated step, or authorizes this one bid on a step that verifies every bid.
2. **Server permit (EIP-712)**: Server signs a single-use permit for `(wallet, step, nonce, deadline, amount)`, submitted inline in `hookData`; the signature covers the bid amount, so a permit only authorizes the exact amount the server approved.

Registration is monotonic across ordinary steps with a zkTLS proof gate: a user verified at step N can use that proof on later proof-gated steps. A later permit-only step still requires a fresh server permit for every bid, even from a previously verified user. Steps set to verify every bid (`setVerifyEveryBid(step, true)`) ignore that registration and require a current-step credential on every bid. A step with neither gate is open. Permit-only and open bids do not accrue toward the zkTLS bid caps.

## Verify every bid

A step that verifies every bid ignores standing verification: every bid must carry its own credential, a server permit or a bid proof. A permit issuer that hands permits to any wallet should require this flag on the step.

Activate a future step atomically with `multicall`: lead the batch with `requireStepNotStarted(step)`, then the ordinary setters (`setIdentityProvider` for any new provider hash, `enableStep` or `setStepProviders` when providers change, `enableStepPermit`/`disableStepPermit`, `setStepMaxBidAmount`) and finally `setVerifyEveryBid(step, true)`, which requires the step to be enabled with a credential gate. A batch mined at or after the step starts reverts entirely; retained providers need no provider call. With both providers and permits configured, either credential authorizes the bid. Prior early-bid verification, stored proofs, and whitelist status never bypass the check. Whether a permit is issued at all is the signer's policy, outside the contract.

- Bid proofs are made for one specific bid: they target the current step, use its provider allowlist, and have timestamps no more than `BID_PROOF_MAX_AGE` (600 seconds) old; future timestamps revert. Such a proof is valid only at its step, so it cannot authorize a bid at a later ordinary step either.
- Each proof request uses signed `bid:<chain>:<lowercase auction>:<step>:<amount in base units>:<random nonce>` context. The hook checks this domain and requires a nonempty nonce; repeated bids need distinct proof identifiers. The hook consumes each identifier atomically with a successful bid.
- Bid proofs emit `ProofVerified`, but never `Registered` and never touch `_registrations`.
- Proof bids use existing zkTLS caps. Permits retain amount binding, expiry and nonce consumption, and do not accrue zkTLS volume.
- An enabled step that verifies every bid fails closed once its credential gates are removed. Disable the step to make it Public, or clear its `setVerifyEveryBid` flag before reverting to ordinary verification. Disabling also clears the flag, so a step re-enabled after it starts verifies as ordinary.
- Early-bid steps default to `false`: inline registration and repeated bids with standing verification remain unchanged. The proof age limit applies only to bid proofs.

`setVerifyEveryBid` emits `VerifyEveryBidSet(stepIndex, required)`, and `verifiesEveryBid(step)` reads the flag back. On such a step a bidder uses a permit when the signer grants one; a fresh proof for the bid is accepted instead only when the step also has a proof gate (a non-empty provider list). A permit-only step takes permits and nothing else.

Proof authenticity is checked by the stateless `ReclaimProofVerifier` library against the configured beacon's witnesses. Calling the beacon's public `verifyProof` cannot burn a hook credential. Bid proofs are consumed once per hook; failed bids roll back consumption.

Registration proofs require a signed `register:<chain>:<lowercase auction>:<nonempty nonce>` context, so a proof for one auction cannot register the wallet in another. Within its auction a registration proof stays valid: `unregister` / `unregisterBatch` clear a wallet's standing registration, but any valid registration proof, including an earlier one, can register it again.

A registration proof is only read for an owner not yet registered at the current step, so it always records the owner as registered from the proof's step and emits `Registered`. Registered owners bid without a credential on later ordinary steps that take proofs, so their registration changes only through `unregister`. A permit-only step still takes a permit from them. Bid proofs remain bound to their auction, chain, step and amount. Both proofs and permits from verify-every-bid steps are restricted to their own step.

`authorizesWithoutCredential(step, user)` reports whether that wallet can pass the step's credential gate with empty hook data. The max bid price still applies, and a registered wallet's bids still count toward the zk caps. It is false on verify-every-bid steps and permit-only steps, even for registered wallets; disabled steps and ordinary steps without gates return true. Out-of-range step indexes return false.

Changing a step's gate does not revoke permits already signed for it; those expire normally.

Permissionless relaying still allows someone to copy and **fund the full authorized bid amount for the same owner**, consuming that bid credential and potentially the owner's quota. These protections prevent proof-only consumption attacks; they do not guarantee transaction ordering in a public mempool.

Hooks are not upgradeable and the CCA stores its hook immutably, so a capability added to the hook only exists on newly deployed hook/auction pairs; a live auction cannot be retrofitted.

## Lifecycle

One hook per gated auction. The CCA takes its `validationHook` as an immutable constructor parameter, so the order is:

1. `new UmiaValidationHook(owner, reclaim, signer)`: the owner, the Reclaim verifier contract and the permit signer. The hook is unpaired and inert.
2. Create the venture with the hook address as the auction's `validationHook` (a field of the CCA `AuctionParameters`, encoded in the `auctionParams` bytes passed to `UmiaHub.createVenture` / `createVentureWithToken`; ungated auctions pass `address(0)`).
3. `setCCA(cca)` as owner: one-shot pairing that caches the CCA's step schedule.
4. Configure gates as owner, normally in one `multicall`: `setIdentityProvider(providerHash, namespace)` for each provider hash, then `enableStep(step, providerHashes, providerIds)` or `enableStepBatch(...)`, plus `enableStepPermit(step)`, `setStepMaxBidAmount(step, amount)` and `setVerifyEveryBid(step, true)` where wanted. Provider hashes and namespaces are those of the zkTLS provider recipes the Reclaim attestor signs for.

## Key state

- `_cca` (paired CCA contract, set once via `setCCA`)
- `_steps` (cached block ranges parsed from CCA's SSTORE2 data)
- `_gates[stepIndex]` (one record per step: `enabled`, `permit`, `everyBid` and the required Reclaim `providers`)
- `_registrations[user]` (standing registration and the step it starts from)
- `_consumedBidProofs[identifier]` (bid proofs already spent)
- `_signer` and `_usedPermits` (permit signer and burned nonces, in the `HookServerPermits` base, which also owns the EIP-712 domain and permit errors)
- `_maxBidPrice` (optional bid price cap in Q96 format)
- `_stepMaxBidAmount`, `_zkBidTotal`, `_zkGlobalMaxBidAmount`, `_zkGlobalBidTotal` (zk bid caps and gross running totals)
- `_identityProviderByHash[providerHash]` (permanent account namespace assignment)
- `_identityToUser[identityKey]` (OPRF sybil gate shared across recipes)

## Access control

- `validate(...)` called by the paired CCA on every bid submission.
- `setCCA(address)` owner-only; idempotent after first set.
- `enableStep(...)` / `disableStep(...)` owner-only step toggle with provider configuration; disabling also clears the verify-every-bid flag.
- `setVerifyEveryBid(...)` owner-only toggle requiring a fresh credential on every bid; enabling requires an enabled step with a credential gate.
- `multicall(bytes[])` batches owner calls atomically; `requireStepNotStarted(step)` (view) makes a batch revert once that step has started.
- `enableStepBatch` / `disableStepBatch`, `setStepProviders` / `setStepProvidersBatch`, `addStepProviders` / `removeStepProviders`, `enableStepPermit` / `disableStepPermit` owner-only gate edits.
- `setSigner(address)` / `setMaxBidPrice(uint256)` / `setStepMaxBidAmount(...)` / `setZkGlobalMaxBidAmount(uint256)` owner-only configuration. `setMaxBidPrice` needs a paired CCA and a Q96 value on its tick grid (`floorPrice + k * tickSpacing`), else `PriceNotAlignedToTick`; `0` removes the cap.
- `setIdentityProvider(providerHash, namespace)` owner-only, write-once namespace assignment (`^[a-z][a-z0-9_]{0,63}$`, else `InvalidIdentityProvider`; a different value later reverts `IdentityProviderImmutable`).
- No credential is submitted on its own: proofs and permits are consumed inline by `validate()`.
- `unregister(...)` / `unregisterBatch(...)` / `clearIdentity(...)` owner-only user management.
- Everything except `setSigner`, `setZkGlobalMaxBidAmount`, `setCCA`, `setIdentityProvider`, `clearIdentity` and `multicall` reverts `NoCCA` before pairing.

## ERC165 introspection

Per [CIP-1](https://github.com/Uniswap/continuous-clearing-auction/blob/main/CIPs/cip-1.md), the hook inherits the CCA's `ValidationHookIntrospection` and advertises its own interface, `IUmiaValidationHook` (`src/interfaces/IUmiaValidationHook.sol`), so integrators can discover it through `supportsInterface` instead of trusting an address list.

| Interface                    | ID           |
| ---------------------------- | ------------ |
| `IERC165`                    | `0x01ffc9a7` |
| `IValidationHook`            | `0x22c44b5f` |
| `IUmiaValidationHook`        | `0x5084080f` |
| `IMaxBidPriceValidationHook` | `0x2268a4c3` |
| `IGatedValidationHook`       | `0x6d417064` |
| `IVerifyEveryBidHook`        | `0x98e51cb6` |

`IUmiaValidationHook` covers the permissionless surface: the gating config reads (`cca`, `getSteps`, `isStepEnabled`, `isStepPermitEnabled`, `getStepProviders`, `isVerified`, `signer`, `stepMaxBidAmount`, `zkBidTotal`, `isPermitNonceUsed`, `identityOwner`). Owner-only administration is excluded. `identityOwner(bytes32)` is part of the ID, so hooks deployed before identity-provider namespaces existed report a different `IUmiaValidationHook` ID.

`IMaxBidPriceValidationHook` is Uniswap's proposed interface for a price-capped hook; `src/interfaces/IMaxBidPriceValidationHook.sol` mirrors it locally so this tree does not depend on it being merged upstream. Our `maxBidPrice()` is signature-identical and, since Uniswap standardised `0` as "no effective cap", semantically identical too, so the claim is unconditional. The one thing that still differs is mutability: theirs is `immutable`, ours moves via `setMaxBidPrice`, so a consumer must not cache the value.

The cap's revert is `MaxBidPriceExceeded()`, deliberately bare so the selector (`0x77c99cf5`) matches theirs and generic CCA tooling can decode it without our ABI. `test_maxBidPriceExceeded_selectorMatchesUniswap` pins it.

`IGatedValidationHook` (`src/interfaces/IGatedValidationHook.sol`) is the gating half of Uniswap's [`IGatedERC1155ValidationHook`](https://github.com/Uniswap/continuous-clearing-auction/blob/main/src/periphery/validationHooks/GatedERC1155ValidationHook.sol). Their auction UI reads it to learn that early bidding is restricted and shows its allow-list treatment while `block.number < expirationBlock()`, lifting the restriction on its own once that block passes. We declare it locally rather than importing theirs because theirs extends `IBaseERC1155ValidationHook`, and we implement neither `erc1155()` nor `tokenId()`: our gate is zkTLS proofs and server permits, not token ownership. The ID is the same (`0x6d417064`) because Solidity excludes inherited selectors from `type().interfaceId`, so the ERC1155 half never enters the computation and their introspection check still passes; `test_gatedInterfaceId_matchesUniswap` pins that equality against the real upstream interface. `IBaseERC1155ValidationHook` (`0xc2b72dab`) is deliberately left unclaimed, since a consumer that saw it would call functions we do not have.

`IVerifyEveryBidHook` (`src/interfaces/IVerifyEveryBidHook.sol`) marks hooks that can require a fresh credential on every bid (`verifiesEveryBid`). It is a separate capability so adding it left the `IUmiaValidationHook` ID unchanged; tooling probes it to tell hooks that can verify every bid from earlier deployments.

`expirationBlock()` is derived on read, returning the `endBlock` of the highest-index step that actually gates, or `0` when nothing gates. "Actually gates" means enabled *and* carrying either a provider list, the permit toggle, or a fail-closed verify-every-bid flag; that is exactly the set of steps where `validate()` (via `_access`) does not return `Open`, so keep the two in step when adding a gate kind. It is not stored because `enableStep`/`disableStep` and the permit toggles move the gate at any time, and a cached block would then contradict what `validate()` enforces. Reporting the *highest* gated step means a gap between gated steps reads as gated throughout, which is the safe direction: under-reporting would let their UI build bids the hook rejects. Unlike Uniswap's `immutable` version, ours can move, so a consumer must not cache it.

`test_supportsInterface_idsAreStable` pins the four Umia-declared IDs (`IUmiaValidationHook`, `IMaxBidPriceValidationHook`, `IGatedValidationHook`, `IVerifyEveryBidHook`), so changing any of these interfaces fails the suite until the constants and this table are updated together.

## Notes

- If `_cca` is unset, `validate()` returns without enforcing. Bids sent between CCA creation and `setCCA` are therefore ungated; pair before the auction's first gated step.
- If the current block is outside all steps or the step is not enabled, the credential gate passes. The max bid price is checked first and still applies.
- The bid sender may differ from the owner (for example a Relay destination executor). Only the paired CCA can call `validate`; credentials, verification and cap accounting bind to the bid owner. The CCA collects native value or ERC20 funds (using Permit2 approvals) from the sender, stores the owner on the bid, and pays refunds/claims to that owner. A relayer cannot redirect another owner's proof or amount-bound permit to itself.
- Relaying does not add a new user-signed order: the permit still binds wallet/step/amount/nonce/deadline, not bid price. The sender supplies the price subject to the hook's price cap. Third-party-funded bids can consume the owner's allocation; this is inherent in allowing any sender to bid for an eligible owner.
- OPRF sybil gate binds one real-world identity to one wallet per identity namespace: the key is `keccak256(abi.encode(namespace, extractedParameters))`, so recipes sharing a namespace share one lock. A proof hash without an assigned namespace reverts `IdentityProviderMissing`; a signed `identityProvider` that differs reverts `IdentityProviderMismatch`; absent, empty or whitespace-only `extractedParameters` values revert `EmptyIdentityParameters`.
