# Umia zkTLS verifier naming and compatibility

Umia's modified Reclaim-derived verifier is `ZkTlsVerifier` in
`src/zktls/ZkTlsVerifier.sol`. Context parsing is `ZkTlsContext`; `Claims.sol` and
`BytesUtils.sol` live in the same folder. The MIT SPDX identifiers and upstream
attribution remain intact. Reclaim is still the proof protocol and an upstream
dependency, rather than the name of Umia's deployed implementation for new builds.

## Contract and wire boundary

New `UmiaValidationHook` builds expose `zktlsVerifier()` instead of `reclaim()`.
That is an intentional getter-selector change. New hooks have no legacy getter
alias. Select an ABI by the reviewed deployment generation; do not try arbitrary
selectors until one returns an address.

The proof tuple, field order/types, claim identifier, EIP-191 signing bytes,
witness selection, and raw identity bytes are unchanged, and `validateProof` keeps
its selector. `ZkTlsCompatibility.t.sol` compares encoded calldata with an
independent legacy wire schema; existing signing and witness-seed fuzz tests
retain the legacy formatting oracle.

`validateProof` is the verifier's only proof entry point. It is stateless and
returns a typed context (`contextAddress` as an address, `providerHash` as
bytes32, both required at full hex width). The legacy stateful `verifyProof`,
its `usedProofs` registry and `fetchEpoch(0)` are gone: nothing called them, and a
public method that marks proofs used let anyone burn a credential.

Ownership, explicit initial witnesses, current-epoch revocation, strict JSON/key
guards, and hook-local replay/cap policy are unchanged. Rotating the verifier's
epoch revokes pending proofs from the old epoch; it does not clear standing hook
registrations. Bid proofs still require a nonempty domain-bound nonce and expire
after 600 seconds. OpenZeppelin ECDSA still rejects high-s signatures.

## Tooling

The rename has no compatibility aliases. Every in-repo reader moved to the new
names in the same change:

| Before | Now |
| --- | --- |
| `umia.reclaim` in `contracts.json` | `umia.zktlsVerifier` |
| `--reclaim-address` | `--zktls-verifier-address` |
| `RECLAIM_ADDRESS` | `ZKTLS_VERIFIER_ADDRESS` |

`RECLAIM_ADDRESS` set in an environment is an error in both the CLI and
`Deploy.s.sol`, so a stale shell cannot silently deploy against the wrong
verifier. The published ABI export is `zkTlsVerifierAbi`, and the API config
response publishes `contracts.umia.zktlsVerifier`; consumers of `reclaimAbi` or
the former `reclaim` field must update with this release.

The CLI takes the verifier from `--zktls-verifier-address`, then
`ZKTLS_VERIFIER_ADDRESS`, then the address book, and deploys a fresh one when
none is set. `--deploy-zktls-verifier` deploys a fresh verifier regardless. A
fresh verifier trusts only `ZKTLS_SHARED_ATTESTOR` and is advanced to its
`claimEpoch`; `Deploy.s.sol` does the same when given `ZKTLS_WITNESS_ADDRESS`,
`ZKTLS_WITNESS_HOST` and `ZKTLS_CLAIM_EPOCH`. Neither can replace an existing
hook's immutable verifier.

Before deploying a hook, the CLI compares the verifier's executable code with the
current `ZkTlsVerifier` artifact, ignoring the compiler's metadata trailer so a
comment or path change does not reject a deployed verifier. No legacy hash
allowlist is added. Zero-verifier seeder hooks remain explicitly permit-only.

## Existing deployments and authority evidence

Renaming an address-book key does not redeploy or upgrade any contract. All
committed addresses are preserved. Previously deployed Reclaim verifiers and
hooks continue exposing their original methods and behavior. Their existing CCA
and hook pointers are immutable; updating JSON cannot redirect them.

The authority capture/monitor CLI reads only the legacy hook getter `reclaim()`,
because its reviewed Monad devnet address and executable hash still describe that
historical deployment. Those pins are retained under `LEGACY_VERIFIER_*` names.
Monitoring a newly compiled verifier requires a separate review of the observed
deployment, its exact pins and the `zktlsVerifier()` getter; no new authority is
enabled automatically.

Version-1 raw captures keep `hookReclaimAddress` and their existing schema. These
are historical evidence, not files to rewrite during a source rename. The neutral
`beaconAddress` and network-authority fields are unchanged. Provider provenance
(`source: "reclaim"`), signed `reclaimSessionId`, extension `RECLAIM_*` messages,
upstream package names, patches and historical test vectors remain intentional.
No database or attestor wire migration is part of this change.

## Rollout preparation

1. Build the exact candidate SHA with the pinned compiler, regenerate ABIs and
   address exports, rebuild the Safe console, and record the verifier/hook
   runtime hashes. Source paths and metadata change hashes even where wire
   behavior is preserved; never copy old hash pins onto new artifacts.
2. Review each environment's existing addresses, owner, witnesses/threshold,
   current epoch and immutable hook/CCA pairs at a pinned block. The address-book
   rename alone is bookkeeping and makes no claim that a compatible deployment
   already exists there.
3. Rehearse a new verifier/hook/CCA pair locally. Initialize only approved
   witnesses, align the attestor epoch, pair once, and exercise valid registration
   and bid proofs plus the rejection paths. Test explicit legacy reads separately.
4. For a replacement generation, plan new addresses and new auction/hook pairs.
   Owner, witnesses/epochs, registrations, replay records and caps do not migrate
   to new contracts automatically. Arrange multisig ownership handover and
   re-verification requirements explicitly.
5. Present the exact environment, SHA, commands, address/hash diff, material risks
   and rollback plan before any mainnet/production mutation, and obtain fresh
   human approval immediately before executing it. Shared devnet resets belong
   only in Deployor. This source change performs no deployment or reset.

Rollback of tooling means restoring the previous client/config generation for
the previous deployments. Old auctions remain on their old immutable pairs. A
newly deployed immutable pair cannot be rolled back by changing its address book;
leave it unused or plan a separately reviewed replacement.

See [issue #2985](https://github.com/umiafinance/umia/issues/2985) for the scoped
inventory and implementation plan.
