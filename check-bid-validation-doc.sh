#!/usr/bin/env bash
# Fails when the validation hook changes without its Bid Validation docs page.
# After updating the page's flow charts, run with --update to record the new sources.
# The page lives in the monorepo only; checkouts without it skip the check.
set -euo pipefail
export LC_ALL=C

cd "$(dirname "$0")"

DOC=../web/site/content/docs/technical-reference/bid-validation.mdx
SOURCES=(
    src/periphery/UmiaValidationHook.sol
    src/periphery/HookServerPermits.sol
    src/periphery/libraries/*.sol
    src/interfaces/IUmiaValidationHook.sol
    src/interfaces/IVerifyEveryBidHook.sol
    src/reclaim/ReclaimProofVerifier.sol
)

if [ ! -f "$DOC" ]; then
    echo "skipped: $DOC not found (the Bid Validation docs page lives in the monorepo)"
    exit 0
fi

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi
}

# Paths are hashed with the monorepo prefix so the digest recorded in the page stays valid.
current=$(for f in "${SOURCES[@]}"; do printf 'smart-contracts/%s\n' "$f"; cat "$f"; done | sha256 | cut -d' ' -f1)
recorded=$(sed -n 's/.*bid-validation-source: \([0-9a-f]\{64\}\).*/\1/p' "$DOC")

if [[ "${1:-}" == "--update" ]]; then
    sed -i.bak "s/bid-validation-source: [0-9a-f]\{64\}/bid-validation-source: $current/" "$DOC"
    rm "$DOC.bak"
    echo "Recorded the hook sources in $DOC"
    exit 0
fi

if [[ "$recorded" != "$current" ]]; then
    echo "UmiaValidationHook changed since $DOC was last reviewed."
    echo "Update its flow charts to match the contract, then run: $0 --update"
    exit 1
fi

echo "Bid Validation docs match the hook sources."
