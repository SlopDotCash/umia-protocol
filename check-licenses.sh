#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Umia contracts are dual-licensed: the integration surface is MIT so anyone can build
# against the protocol, and the implemented mechanism is BUSL-1.1. See licenses/.
MIT_DIRS=("src/interfaces/" "src/reclaim/")
MIT_FILES=(
    "src/core/VentureProxy.sol"
    "src/tokens/VentureToken.sol"
    "src/libraries/GovernanceTypes.sol"
    "src/libraries/MarketCoreTypes.sol"
    "src/libraries/SpotMarketOracle.sol"
    "src/libraries/TickSlew.sol"
    "src/libraries/PositionAmounts.sol"
    "src/libraries/TwapMath.sol"
    "src/libraries/CalendarLib.sol"
)

failed=0

expected_license() {
    local file="$1"
    for dir in "${MIT_DIRS[@]}"; do
        [[ "$file" == "$dir"* ]] && { echo "MIT"; return; }
    done
    for f in "${MIT_FILES[@]}"; do
        [[ "$file" == "$f" ]] && { echo "MIT"; return; }
    done
    echo "BUSL-1.1"
}

violations=$(find src -name "*.sol" -print0 | while IFS= read -r -d '' file; do
    expected=$(expected_license "$file")
    actual=$(sed -n '1s|^// SPDX-License-Identifier: *||p' "$file")

    if [ -z "$actual" ]; then
        echo "MISSING SPDX: $file (expected $expected on line 1)"
    elif [ "$actual" != "$expected" ]; then
        echo "WRONG LICENSE: $file is '$actual', expected '$expected'"
    fi
done | sort)

if [ -n "$violations" ]; then
    echo "$violations"
    failed=1
fi

# MetaVesT is AGPL-3.0. Production contracts declare minimal local interfaces instead of
# importing it, which keeps copyleft out of the deployed surface.
if grep -rn "@metavest" src/ 2>/dev/null; then
    echo "AGPL LEAK: src/ must not import @metavest — declare a minimal local interface instead"
    failed=1
fi

if grep -rqn "UMIA_LICENSOR_ENTITY" licenses/; then
    echo "PLACEHOLDER: licenses/ still contains UMIA_LICENSOR_ENTITY"
    echo "  Replace it with the registered entity that holds copyright in the contracts."
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "License check failed. See smart-contracts/licenses/ for the licensing scheme."
    exit 1
fi

echo "All contracts carry the expected SPDX identifier."
